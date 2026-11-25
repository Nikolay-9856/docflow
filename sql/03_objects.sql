-- ============================================================
-- Объекты БД citr_docflow: представления и хранимые процедуры
-- ============================================================

-- ---------- ПРЕДСТАВЛЕНИЯ ----------

-- Реестр документов: собирает карточку документа из 5 таблиц
CREATE OR REPLACE VIEW v_documents_full AS
SELECT d.doc_id,
       d.reg_number,
       d.title,
       t.type_name,
       d.status,
       d.reg_date,
       d.due_date,
       u.full_name                         AS author,
       dp.dept_name                        AS department,
       COALESCE(c.cp_name, '— внутренний —') AS counterparty,
       (d.due_date < current_date
        AND d.status NOT IN ('Исполнен','В архиве')) AS is_overdue,
       d.updated_at
FROM documents d
JOIN doc_types   t  ON t.type_id  = d.type_id
JOIN users       u  ON u.user_id  = d.author_id
JOIN departments dp ON dp.dept_id = d.dept_id
LEFT JOIN counterparties c ON c.cp_id = d.cp_id;

-- Сводка по подразделениям: агрегаты по документам и маршрутам
CREATE OR REPLACE VIEW v_dept_doc_stats AS
SELECT dp.dept_name,
       COUNT(d.doc_id)                                          AS docs_total,
       COUNT(d.doc_id) FILTER (WHERE d.status = 'На согласовании') AS on_approval,
       COUNT(d.doc_id) FILTER (WHERE d.status IN ('Исполнен','В архиве')) AS completed,
       COUNT(d.doc_id) FILTER (WHERE d.due_date < current_date
                               AND d.status NOT IN ('Исполнен','В архиве')) AS overdue,
       ROUND(AVG(d.due_date - d.reg_date), 1)                   AS avg_term_days
FROM departments dp
LEFT JOIN documents d ON d.dept_id = dp.dept_id
GROUP BY dp.dept_name;

-- Входящие задачи согласующих (используется на странице «Мои задачи»)
CREATE OR REPLACE VIEW v_pending_tasks AS
SELECT r.route_id, r.doc_id, d.reg_number, d.title, r.stage_no, r.action,
       r.executor_id, u.full_name AS executor, r.assigned_at,
       (current_date - r.assigned_at::date) AS waiting_days
FROM doc_routes r
JOIN documents d ON d.doc_id = r.doc_id
JOIN users     u ON u.user_id = r.executor_id
WHERE r.decision = 'Ожидает';

-- ---------- ХРАНИМЫЕ ПРОЦЕДУРЫ ----------

-- 1) Регистрация документа с автоматическим присвоением номера
CREATE OR REPLACE PROCEDURE sp_register_document(
    IN    p_title      VARCHAR,
    IN    p_type_id    SMALLINT,
    IN    p_author_id  INT,
    IN    p_cp_id      INT,
    IN    p_due_date   DATE,
    INOUT p_doc_id     INT     DEFAULT NULL,
    INOUT p_reg_number VARCHAR DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_prefix VARCHAR(5);
    v_dept   INT;
    v_seq    INT;
BEGIN
    SELECT reg_prefix INTO v_prefix FROM doc_types WHERE type_id = p_type_id;
    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'Вид документа % не найден', p_type_id USING ERRCODE = 'P0002';
    END IF;

    SELECT dept_id INTO v_dept FROM users WHERE user_id = p_author_id AND is_active;
    IF v_dept IS NULL THEN
        RAISE EXCEPTION 'Автор % не найден или заблокирован', p_author_id USING ERRCODE = 'P0002';
    END IF;

    -- сквозная нумерация в пределах вида документа и года
    PERFORM pg_advisory_xact_lock(p_type_id);
    SELECT COALESCE(MAX(split_part(reg_number, '-', 3)::INT), 0) + 1
      INTO v_seq
      FROM documents
     WHERE type_id = p_type_id
       AND split_part(reg_number, '-', 2) = to_char(current_date, 'YYYY');

    p_reg_number := v_prefix || '-' || to_char(current_date, 'YYYY') || '-' || lpad(v_seq::TEXT, 4, '0');

    INSERT INTO documents (reg_number, title, type_id, author_id, dept_id, cp_id, due_date)
    VALUES (p_reg_number, p_title, p_type_id, p_author_id, v_dept, p_cp_id, p_due_date)
    RETURNING doc_id INTO p_doc_id;
END;
$$;

-- 2) Отправка документа на этап маршрута
CREATE OR REPLACE PROCEDURE sp_send_for_approval(
    IN p_doc_id      INT,
    IN p_executor_id INT,
    IN p_action      VARCHAR,
    IN p_sender_id   INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_status VARCHAR(20);
    v_stage  SMALLINT;
BEGIN
    SELECT status INTO v_status FROM documents WHERE doc_id = p_doc_id FOR UPDATE;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Документ % не найден', p_doc_id USING ERRCODE = 'P0002';
    ELSIF v_status IN ('Исполнен', 'В архиве') THEN
        RAISE EXCEPTION 'Документ в статусе «%» нельзя направить по маршруту', v_status
              USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(MAX(stage_no), 0) + 1 INTO v_stage FROM doc_routes WHERE doc_id = p_doc_id;

    INSERT INTO doc_routes (doc_id, stage_no, executor_id, action)
    VALUES (p_doc_id, v_stage, p_executor_id, p_action);

    PERFORM set_config('app.user_id', p_sender_id::TEXT, TRUE);
    UPDATE documents SET status = 'На согласовании'
     WHERE doc_id = p_doc_id AND status <> 'На согласовании';
END;
$$;

-- 3) Решение согласующего по этапу маршрута
CREATE OR REPLACE PROCEDURE sp_decide_route(
    IN p_route_id INT,
    IN p_decision VARCHAR,
    IN p_comment  VARCHAR,
    IN p_user_id  INT)
LANGUAGE plpgsql AS $$
DECLARE
    r doc_routes%ROWTYPE;
    v_left INT;
BEGIN
    SELECT * INTO r FROM doc_routes WHERE route_id = p_route_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Этап маршрута % не найден', p_route_id USING ERRCODE = 'P0002';
    ELSIF r.decision <> 'Ожидает' THEN
        RAISE EXCEPTION 'По этапу % решение уже принято: %', p_route_id, r.decision USING ERRCODE = 'P0001';
    ELSIF r.executor_id <> p_user_id THEN
        RAISE EXCEPTION 'Пользователь % не является исполнителем этапа', p_user_id USING ERRCODE = '42501';
    ELSIF p_decision NOT IN ('Согласовано', 'Отклонено') THEN
        RAISE EXCEPTION 'Недопустимое решение: %', p_decision USING ERRCODE = '22023';
    ELSIF p_decision = 'Отклонено' AND COALESCE(trim(p_comment), '') = '' THEN
        RAISE EXCEPTION 'При отклонении комментарий обязателен' USING ERRCODE = '22023';
    END IF;

    UPDATE doc_routes
       SET decision = p_decision, comment = p_comment, decided_at = now()
     WHERE route_id = p_route_id;

    PERFORM set_config('app.user_id', p_user_id::TEXT, TRUE);

    IF p_decision = 'Отклонено' THEN
        UPDATE documents SET status = 'На доработке' WHERE doc_id = r.doc_id;
    ELSE
        SELECT COUNT(*) INTO v_left FROM doc_routes
         WHERE doc_id = r.doc_id AND decision = 'Ожидает';
        IF v_left = 0 THEN
            UPDATE documents SET status = 'Согласован' WHERE doc_id = r.doc_id;
        END IF;
    END IF;
END;
$$;

-- 4) Регистрация пользователя (соль и хэш вычисляет приложение)
CREATE OR REPLACE PROCEDURE sp_register_user(
    IN    p_login     VARCHAR,
    IN    p_full_name VARCHAR,
    IN    p_email     VARCHAR,
    IN    p_position  VARCHAR,
    IN    p_dept_id   INT,
    IN    p_role_code VARCHAR,
    IN    p_hash      CHAR(64),
    IN    p_salt      CHAR(32),
    INOUT p_user_id   INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_role SMALLINT;
BEGIN
    IF EXISTS (SELECT 1 FROM users WHERE lower(login) = lower(p_login)) THEN
        RAISE EXCEPTION 'Логин «%» уже занят', p_login USING ERRCODE = '23505';
    END IF;
    SELECT role_id INTO v_role FROM roles WHERE role_code = p_role_code;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'Роль % не существует', p_role_code USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO users (login, full_name, email, position, dept_id, role_id, password_hash, password_salt)
    VALUES (lower(p_login), p_full_name, lower(p_email), p_position, p_dept_id, v_role, p_hash, p_salt)
    RETURNING user_id INTO p_user_id;
END;
$$;
