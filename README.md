# ЦИТР.Документ — автоматизация документооборота (ПМ.07)

Учебный проект производственной практики, ООО «ЦИТР». PostgreSQL 16 + Python 3 / Flask 3.

## Версия v4.0 — триггеры и роли СУБД

### Что вошло в версию
- триггеры: `trg_documents_status_audit` (журнал статусов), `trg_documents_updated_at`, `trg_users_updated_at`, `trg_doc_files_version`
- `sql/05_roles.sql`: групповые роли `citr_reader`, `citr_clerk`, `citr_admin` и пользователи `db_reader`, `db_clerk`, `db_admin`
- приложение подключается под учётной записью СУБД, соответствующей роли пользователя (`APP_ROLE_TO_DB` в `app/db.py`)
- функция аудита — SECURITY DEFINER, прямой записи в журнал у рабочих ролей нет

### Развёртывание
1. Выполнить по порядку: `sql/01_schema.sql`, `sql/02_data.sql`, `sql/03_objects.sql`, `sql/05_roles.sql` (пароли пользователей СУБД задать свои)
2. В `pg_hba.conf` для 127.0.0.1 указать `scram-sha-256`
3. `pip install flask psycopg2-binary`
4. `app/.env` по образцу `app/.env.example`
5. `cd app && python app.py`
