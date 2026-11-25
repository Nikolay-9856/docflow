# ЦИТР.Документ — автоматизация документооборота (ПМ.07)

Учебный проект производственной практики, ООО «ЦИТР». PostgreSQL 16 + Python 3 / Flask 3.

## Версия v3.0 — представления и хранимые процедуры

### Что вошло в версию
- `sql/03_objects.sql`: VIEW `v_documents_full`, `v_dept_doc_stats`, `v_pending_tasks`; процедуры `sp_register_document`, `sp_send_for_approval`, `sp_decide_route`, `sp_register_user`
- приложение читает данные из VIEW, регистрирует документы и ведёт маршрут согласования через процедуры
- новые страницы: «Мои задачи», «Пользователи» (администратор)
- обработка ошибок RAISE EXCEPTION по коду SQLSTATE

### Развёртывание
1. Выполнить `sql/01_schema.sql`, `sql/02_data.sql`, `sql/03_objects.sql`
2. `pip install flask psycopg2-binary`
3. `app/.env` по образцу `app/.env.example`
4. `cd app && python app.py`
