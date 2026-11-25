# ЦИТР.Документ — автоматизация документооборота (ПМ.07)

Учебный проект производственной практики, ООО «ЦИТР». PostgreSQL 16 + Python 3 / Flask 3.

## Версия v1.0 — DDL и тестовые данные

### Что вошло в версию
- `sql/01_schema.sql` — 9 таблиц, PK/FK, UNIQUE, CHECK, индексы, комментарии
- `sql/02_data.sql` — тестовые данные (roles, departments, users, doc_types, counterparties, documents, doc_routes, doc_files, doc_status_log)
- `docs/` — ER-диаграмма 

### Развёртывание
1. `createdb citr_docflow`
2. `psql -d citr_docflow -f sql/01_schema.sql`
3. `psql -d citr_docflow -f sql/02_data.sql`
