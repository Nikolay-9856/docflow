-- ============================================================
-- База данных: citr_docflow
-- Система: «ЦИТР.Документ» — автоматизация документооборота
-- Организация: ООО «ЦИТР» (ИНН 7735192830)
-- СУБД: PostgreSQL 16
-- ============================================================

DROP TABLE IF EXISTS doc_status_log, doc_files, doc_routes, documents,
                     counterparties, doc_types, users, departments, roles CASCADE;

-- 1. Роли пользователей приложения
CREATE TABLE roles (
    role_id     SMALLSERIAL  PRIMARY KEY,
    role_code   VARCHAR(20)  NOT NULL UNIQUE,
    role_name   VARCHAR(60)  NOT NULL
);

-- 2. Подразделения ООО «ЦИТР»
CREATE TABLE departments (
    dept_id     SERIAL       PRIMARY KEY,
    dept_code   VARCHAR(10)  NOT NULL UNIQUE,
    dept_name   VARCHAR(120) NOT NULL,
    created_at  TIMESTAMP    NOT NULL DEFAULT now()
);

-- 3. Пользователи системы
CREATE TABLE users (
    user_id        SERIAL       PRIMARY KEY,
    login          VARCHAR(40)  NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL,
    email          VARCHAR(120) NOT NULL UNIQUE,
    position       VARCHAR(100),
    role_id        SMALLINT     NOT NULL REFERENCES roles(role_id),
    dept_id        INT          NOT NULL REFERENCES departments(dept_id),
    password_hash  CHAR(64)     NOT NULL,
    password_salt  CHAR(32)     NOT NULL,
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at     TIMESTAMP    NOT NULL DEFAULT now()
);

-- 4. Виды документов
CREATE TABLE doc_types (
    type_id          SMALLSERIAL  PRIMARY KEY,
    type_name        VARCHAR(80)  NOT NULL UNIQUE,
    reg_prefix       VARCHAR(5)   NOT NULL UNIQUE,
    retention_years  SMALLINT     NOT NULL CHECK (retention_years > 0)
);

-- 5. Контрагенты (внешние корреспонденты)
CREATE TABLE counterparties (
    cp_id       SERIAL       PRIMARY KEY,
    cp_name     VARCHAR(150) NOT NULL,
    inn         VARCHAR(12)  NOT NULL UNIQUE CHECK (inn ~ '^[0-9]{10}([0-9]{2})?$'),
    cp_kind     VARCHAR(20)  NOT NULL CHECK (cp_kind IN ('Заказчик','Поставщик','Госорган','Партнёр')),
    created_at  TIMESTAMP    NOT NULL DEFAULT now()
);

-- 6. Документы (основная сущность)
CREATE TABLE documents (
    doc_id      SERIAL       PRIMARY KEY,
    reg_number  VARCHAR(20)  NOT NULL UNIQUE,
    title       VARCHAR(200) NOT NULL,
    author_id   INT          NOT NULL REFERENCES users(user_id),
    type_id     SMALLINT     NOT NULL REFERENCES doc_types(type_id),
    dept_id     INT          NOT NULL REFERENCES departments(dept_id),
    cp_id       INT          REFERENCES counterparties(cp_id) ON DELETE SET NULL,
    status      VARCHAR(20)  NOT NULL DEFAULT 'Черновик'
                CHECK (status IN ('Черновик','На согласовании','На доработке',
                                  'Согласован','Исполнен','В архиве')),
    reg_date    DATE         NOT NULL DEFAULT current_date,
    due_date    DATE,
    created_at  TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at  TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT chk_due CHECK (due_date IS NULL OR due_date >= reg_date)
);

-- 7. Маршрут согласования документа
CREATE TABLE doc_routes (
    route_id     SERIAL       PRIMARY KEY,
    doc_id       INT          NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    stage_no     SMALLINT     NOT NULL,
    executor_id  INT          NOT NULL REFERENCES users(user_id),
    action       VARCHAR(20)  NOT NULL CHECK (action IN ('Согласование','Подписание','Исполнение','Ознакомление')),
    decision     VARCHAR(15)  NOT NULL DEFAULT 'Ожидает'
                 CHECK (decision IN ('Ожидает','Согласовано','Отклонено')),
    comment      VARCHAR(300),
    assigned_at  TIMESTAMP    NOT NULL DEFAULT now(),
    decided_at   TIMESTAMP,
    UNIQUE (doc_id, stage_no)
);

-- 8. Файлы (версии) документа
CREATE TABLE doc_files (
    file_id      SERIAL       PRIMARY KEY,
    doc_id       INT          NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    file_name    VARCHAR(160) NOT NULL,
    size_kb      INT          NOT NULL CHECK (size_kb > 0),
    version_no   SMALLINT     NOT NULL DEFAULT 1,
    uploaded_by  INT          NOT NULL REFERENCES users(user_id),
    uploaded_at  TIMESTAMP    NOT NULL DEFAULT now()
);

-- 9. Журнал смены статусов (заполняется триггером)
CREATE TABLE doc_status_log (
    log_id      BIGSERIAL    PRIMARY KEY,
    doc_id      INT          NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    old_status  VARCHAR(20),
    new_status  VARCHAR(20)  NOT NULL,
    changed_by  INT          REFERENCES users(user_id),
    changed_at  TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX ix_documents_status  ON documents(status);
CREATE INDEX ix_documents_dept    ON documents(dept_id);
CREATE INDEX ix_routes_executor   ON doc_routes(executor_id, decision);
CREATE INDEX ix_status_log_doc    ON doc_status_log(doc_id, changed_at);

COMMENT ON TABLE roles          IS 'Роли пользователей приложения';
COMMENT ON TABLE departments    IS 'Подразделения ООО «ЦИТР»';
COMMENT ON TABLE users          IS 'Пользователи системы';
COMMENT ON TABLE doc_types      IS 'Виды документов';
COMMENT ON TABLE counterparties IS 'Контрагенты-корреспонденты';
COMMENT ON TABLE documents      IS 'Регистрационные карточки документов';
COMMENT ON TABLE doc_routes     IS 'Этапы маршрута согласования';
COMMENT ON TABLE doc_files      IS 'Файлы и версии документов';
COMMENT ON TABLE doc_status_log IS 'Журнал смены статусов';
