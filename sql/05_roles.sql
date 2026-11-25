-- ============================================================
-- Роли СУБД и пользователи (PostgreSQL 16)
-- Принцип минимальных привилегий
-- ============================================================

-- Журнал статусов пишет только триггер: функция выполняется
-- с правами владельца, прямой INSERT в журнал ролям не выдаётся
ALTER FUNCTION fn_documents_status_audit() SECURITY DEFINER SET search_path = public;

-- ---------- групповые роли (без права входа) ----------
CREATE ROLE citr_reader NOLOGIN;
CREATE ROLE citr_clerk  NOLOGIN;
CREATE ROLE citr_admin  NOLOGIN;

REVOKE ALL ON DATABASE citr_docflow FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA public FROM PUBLIC;

-- citr_reader: только чтение
GRANT CONNECT ON DATABASE citr_docflow TO citr_reader;
GRANT USAGE   ON SCHEMA public        TO citr_reader;
GRANT SELECT  ON ALL TABLES IN SCHEMA public TO citr_reader;   -- таблицы и VIEW

-- citr_clerk: чтение + работа с документами (наследует reader)
GRANT citr_reader TO citr_clerk;
GRANT INSERT, UPDATE, DELETE ON documents, doc_routes, doc_files TO citr_clerk;
GRANT INSERT, UPDATE         ON counterparties              TO citr_clerk;
GRANT USAGE ON SEQUENCE documents_doc_id_seq, doc_routes_route_id_seq,
                         doc_files_file_id_seq, counterparties_cp_id_seq TO citr_clerk;
GRANT EXECUTE ON PROCEDURE sp_register_document(VARCHAR, SMALLINT, INT, INT, DATE, INT, VARCHAR),
                           sp_send_for_approval(INT, INT, VARCHAR, INT),
                           sp_decide_route(INT, VARCHAR, VARCHAR, INT) TO citr_clerk;
-- служебная колонка для проверки входа доступна всем ролям приложения
-- (сами хэши читаются, но без соли/алгоритма бесполезны; изменять users clerk не может)

-- citr_admin: полный доступ к объектам БД
GRANT citr_clerk TO citr_admin;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO citr_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO citr_admin;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO citr_admin;
GRANT ALL PRIVILEGES ON DATABASE citr_docflow TO citr_admin;

-- ---------- пользователи СУБД ----------
CREATE ROLE db_reader LOGIN PASSWORD 'Rd#Citr2026' CONNECTION LIMIT 10;
CREATE ROLE db_clerk  LOGIN PASSWORD 'Cl#Citr2026' CONNECTION LIMIT 20;
CREATE ROLE db_admin  LOGIN PASSWORD 'Ad#Citr2026' CONNECTION LIMIT 5;

GRANT citr_reader TO db_reader;
GRANT citr_clerk  TO db_clerk;
GRANT citr_admin  TO db_admin;
