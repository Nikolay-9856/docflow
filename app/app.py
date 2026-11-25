"""ЦИТР.Документ — веб-приложение для автоматизации документооборота ООО «ЦИТР»."""
from datetime import date, timedelta

import psycopg2
from flask import Flask, flash, g, redirect, render_template, request, url_for

from db import DBConnection
from security import PasswordHelper
from session import AppSession, login_required, permission_required

import os

DBConnection.init(os.path.join(os.path.dirname(__file__), ".env"))
app = Flask(__name__)
app.secret_key = os.environ["SECRET_KEY"]
app.permanent_session_lifetime = timedelta(hours=8)


# --- до версии v3.0 представлений в БД нет: тот же SQL как подзапросы ---
DOCS_SQL = """(
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
LEFT JOIN counterparties c ON c.cp_id = d.cp_id
) v"""

STATS_SQL = """(
SELECT dp.dept_name,
       COUNT(d.doc_id)                                          AS docs_total,
       COUNT(d.doc_id) FILTER (WHERE d.status = 'На согласовании') AS on_approval,
       COUNT(d.doc_id) FILTER (WHERE d.status IN ('Исполнен','В архиве')) AS completed,
       COUNT(d.doc_id) FILTER (WHERE d.due_date < current_date
                               AND d.status NOT IN ('Исполнен','В архиве')) AS overdue,
       ROUND(AVG(d.due_date - d.reg_date), 1)                   AS avg_term_days
FROM departments dp
LEFT JOIN documents d ON d.dept_id = dp.dept_id
GROUP BY dp.dept_name
) s"""

TASKS_SQL = """(
SELECT r.route_id, r.doc_id, d.reg_number, d.title, r.stage_no, r.action,
       r.executor_id, u.full_name AS executor, r.assigned_at,
       (current_date - r.assigned_at::date) AS waiting_days
FROM doc_routes r
JOIN documents d ON d.doc_id = r.doc_id
JOIN users     u ON u.user_id = r.executor_id
WHERE r.decision = 'Ожидает'
) t"""

STATUSES = ["Черновик", "На согласовании", "На доработке", "Согласован", "Исполнен", "В архиве"]

PG_MESSAGES = {
    "23505": "Запись с таким значением уже существует",
    "23503": "Запись связана с другими данными и не может быть изменена",
    "42501": "Недостаточно прав для операции",
}


def db_error_text(exc: psycopg2.Error) -> str:
    """Текст для пользователя: из RAISE EXCEPTION процедуры или по коду SQLSTATE."""
    app.logger.warning("DB error %s: %s", exc.pgcode, exc.diag.message_primary)
    if exc.pgcode in ("P0001", "P0002", "22023", "42501", "23505") and exc.diag.message_primary:
        if exc.pgcode != "42501" or "исполнителем" in exc.diag.message_primary:
            return exc.diag.message_primary
    return PG_MESSAGES.get(exc.pgcode, "Ошибка базы данных")


def load_lookup(table, key, label, where="", app_role="VIEWER"):
    """Универсальная загрузка справочника для выпадающих списков."""
    sql = f"SELECT {key} AS id, {label} AS name FROM {table} {where} ORDER BY 2"
    return DBConnection.query(sql, app_role=app_role)


@app.context_processor
def inject_user():
    return {"me": AppSession.current(), "can": AppSession.can}


# ---------------- аутентификация ----------------
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        login_name = request.form.get("login", "").strip().lower()
        password = request.form.get("password", "")
        user = DBConnection.query_one(
            """SELECT u.user_id, u.login, u.full_name, u.dept_id, u.is_active,
                      u.password_hash, u.password_salt, r.role_code, r.role_name
               FROM users u JOIN roles r ON r.role_id = u.role_id
               WHERE u.login = %s""", (login_name,))
        if user and user["is_active"] and PasswordHelper.verify_password(
                password, user["password_salt"], user["password_hash"]):
            AppSession.start(user)
            return redirect(url_for("dashboard"))
        flash("Неверный логин или пароль", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    AppSession.end()
    return redirect(url_for("login"))


# ---------------- главная ----------------
@app.route("/")
@login_required
def dashboard():
    stats = DBConnection.query(f"SELECT * FROM {STATS_SQL} ORDER BY docs_total DESC, dept_name")
    totals = DBConnection.query_one(
        """SELECT COUNT(*) AS total,
                  COUNT(*) FILTER (WHERE status='На согласовании') AS on_approval,
                  COUNT(*) FILTER (WHERE is_overdue) AS overdue,
                  COUNT(*) FILTER (WHERE status IN ('Исполнен','В архиве')) AS done
           FROM """ + DOCS_SQL)
    my_tasks = DBConnection.query(
        f"SELECT * FROM {TASKS_SQL} WHERE executor_id = %s ORDER BY assigned_at",
        (AppSession.current()["user_id"],))
    recent = DBConnection.query(
        """SELECT l.changed_at, d.reg_number, l.old_status, l.new_status, u.full_name
           FROM doc_status_log l JOIN documents d ON d.doc_id = l.doc_id
           LEFT JOIN users u ON u.user_id = l.changed_by
           ORDER BY l.changed_at DESC LIMIT 6""")
    return render_template("dashboard.html", stats=stats, totals=totals,
                           my_tasks=my_tasks, recent=recent)


# ---------------- документы: READ ----------------
@app.route("/documents")
@login_required
def documents():
    status = request.args.get("status", "")
    type_name = request.args.get("type", "")
    text = request.args.get("q", "").strip()
    sql = f"SELECT * FROM {DOCS_SQL} WHERE TRUE"
    params = []
    if status:
        sql += " AND status = %s"
        params.append(status)
    if type_name:
        sql += " AND type_name = %s"
        params.append(type_name)
    if text:
        sql += " AND (reg_number ILIKE %s OR title ILIKE %s)"
        params += [f"%{text}%", f"%{text}%"]
    sql += " ORDER BY reg_date DESC, reg_number DESC"
    rows = DBConnection.query(sql, params)
    types = load_lookup("doc_types", "type_id", "type_name")
    return render_template("documents.html", rows=rows, statuses=STATUSES, types=types,
                           f_status=status, f_type=type_name, f_q=text)


@app.route("/documents/<int:doc_id>")
@login_required
def document_card(doc_id):
    doc = DBConnection.query_one(f"SELECT * FROM {DOCS_SQL} WHERE doc_id = %s", (doc_id,))
    if not doc:
        flash("Документ не найден", "error")
        return redirect(url_for("documents"))
    routes = DBConnection.query(
        """SELECT r.*, u.full_name FROM doc_routes r JOIN users u ON u.user_id = r.executor_id
           WHERE r.doc_id = %s ORDER BY r.stage_no""", (doc_id,))
    files = DBConnection.query(
        """SELECT f.*, u.full_name FROM doc_files f JOIN users u ON u.user_id = f.uploaded_by
           WHERE f.doc_id = %s ORDER BY f.version_no DESC""", (doc_id,))
    history = DBConnection.query(
        """SELECT l.*, u.full_name FROM doc_status_log l LEFT JOIN users u ON u.user_id = l.changed_by
           WHERE l.doc_id = %s ORDER BY l.changed_at""", (doc_id,))
    executors = load_lookup("users", "user_id", "full_name",
                            "WHERE is_active AND role_id IN (SELECT role_id FROM roles WHERE role_code IN ('MANAGER','ADMIN'))")
    return render_template("card.html", doc=doc, routes=routes, files=files,
                           history=history, executors=executors)


# ---------------- документы: CREATE ----------------
@app.route("/documents/new", methods=["GET", "POST"])
@permission_required("doc_create")
def document_new():
    form = request.form
    if request.method == "POST":
        try:
            user = AppSession.current()
            with DBConnection.cursor() as cur:
                cur.execute("SELECT reg_prefix FROM doc_types WHERE type_id = %s", (int(form["type_id"]),))
                prefix = cur.fetchone()["reg_prefix"]
                cur.execute(
                    """SELECT COALESCE(MAX(split_part(reg_number, '-', 3)::INT), 0) + 1 AS n
                       FROM documents WHERE type_id = %s
                       AND split_part(reg_number, '-', 2) = to_char(current_date, 'YYYY')""",
                    (int(form["type_id"]),))
                reg_number = f"{prefix}-{date.today():%Y}-{cur.fetchone()['n']:04d}"
                cur.execute(
                    """INSERT INTO documents (reg_number, title, type_id, author_id, dept_id, cp_id, due_date)
                       VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING doc_id""",
                    (reg_number, form["title"].strip(), int(form["type_id"]), user["user_id"],
                     user["dept_id"], int(form["cp_id"]) if form.get("cp_id") else None,
                     form.get("due_date") or None))
                doc_id = cur.fetchone()["doc_id"]
            flash(f"Документ зарегистрирован под номером {reg_number}", "ok")
            return redirect(url_for("document_card", doc_id=doc_id))
        except psycopg2.Error as exc:
            flash(db_error_text(exc), "error")
    return render_template("doc_form.html", doc=None, form=form,
                           types=load_lookup("doc_types", "type_id", "type_name"),
                           cps=load_lookup("counterparties", "cp_id", "cp_name"),
                           statuses=STATUSES)


# ---------------- документы: UPDATE ----------------
@app.route("/documents/<int:doc_id>/edit", methods=["GET", "POST"])
@permission_required("doc_edit")
def document_edit(doc_id):
    doc = DBConnection.query_one("SELECT * FROM documents WHERE doc_id = %s", (doc_id,))
    if request.method == "POST":
        f = request.form
        try:
            with DBConnection.cursor(AppSession.role()) as cur:
                # идентификатор пользователя для триггера аудита статусов
                cur.execute("SELECT set_config('app.user_id', %s, true)",
                            (str(AppSession.current()["user_id"]),))
                cur.execute(
                    """UPDATE documents
                          SET title = %s, type_id = %s, cp_id = %s, due_date = %s, status = %s
                        WHERE doc_id = %s""",
                    (f["title"].strip(), int(f["type_id"]), int(f["cp_id"]) if f.get("cp_id") else None,
                     f.get("due_date") or None, f["status"], doc_id))
            flash("Изменения сохранены", "ok")
            return redirect(url_for("document_card", doc_id=doc_id))
        except psycopg2.Error as exc:
            flash(db_error_text(exc), "error")
    return render_template("doc_form.html", doc=doc, form=request.form,
                           types=load_lookup("doc_types", "type_id", "type_name"),
                           cps=load_lookup("counterparties", "cp_id", "cp_name"),
                           statuses=STATUSES)


# ---------------- документы: DELETE ----------------
@app.route("/documents/<int:doc_id>/delete", methods=["POST"])
@permission_required("doc_delete")
def document_delete(doc_id):
    try:
        n = DBConnection.execute(
            "DELETE FROM documents WHERE doc_id = %s AND status IN ('Черновик','На доработке')",
            (doc_id,), app_role=AppSession.role())
        if n:
            flash("Документ удалён вместе с маршрутом и файлами", "ok")
        else:
            flash("Удалять можно только черновики и документы на доработке", "warn")
    except psycopg2.Error as exc:
        flash(db_error_text(exc), "error")
    return redirect(url_for("documents"))


# ---------------- отчёты ----------------
@app.route("/reports")
@login_required
def reports():
    executors = DBConnection.query(
        """SELECT u.full_name, r.role_name, COUNT(rt.route_id) AS stages,
                  COUNT(rt.route_id) FILTER (WHERE rt.decision = 'Ожидает') AS pending
           FROM doc_routes rt RIGHT JOIN users u ON u.user_id = rt.executor_id
           JOIN roles r ON r.role_id = u.role_id
           GROUP BY u.full_name, r.role_name ORDER BY stages DESC, u.full_name""")
    by_type = DBConnection.query(
        """SELECT t.type_name, COUNT(d.doc_id) AS docs
           FROM documents d RIGHT JOIN doc_types t ON t.type_id = d.type_id
           GROUP BY t.type_name ORDER BY docs DESC, t.type_name""")
    no_files = DBConnection.query(
        """SELECT d.reg_number, d.title, d.status FROM documents d
           LEFT JOIN doc_files f ON f.doc_id = d.doc_id
           WHERE f.file_id IS NULL ORDER BY d.reg_number""")
    return render_template("reports.html", executors=executors, by_type=by_type, no_files=no_files)


# ---------------- справочник контрагентов ----------------
@app.route("/counterparties", methods=["GET", "POST"])
@login_required
def counterparties():
    if request.method == "POST" and AppSession.can("doc_create"):
        try:
            DBConnection.execute(
                "INSERT INTO counterparties (cp_name, inn, cp_kind) VALUES (%s, %s, %s)",
                (request.form["cp_name"].strip(), request.form["inn"].strip(), request.form["cp_kind"]),
                app_role=AppSession.role())
            flash("Контрагент добавлен", "ok")
        except psycopg2.Error as exc:
            flash("ИНН должен содержать 10 или 12 цифр" if exc.pgcode == "23514" else db_error_text(exc), "error")
    rows = DBConnection.query(
        """SELECT c.*, COUNT(d.doc_id) AS docs FROM counterparties c
           LEFT JOIN documents d ON d.cp_id = c.cp_id GROUP BY c.cp_id ORDER BY c.cp_name""")
    return render_template("counterparties.html", rows=rows)


@app.errorhandler(403)
def forbidden(_):
    return render_template("message.html", title="Доступ запрещён",
                           text="Для вашей роли эта страница недоступна."), 403


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5050, debug=False)
