"""Контекст текущего пользователя (AppSession) и проверка прав."""
from functools import wraps

from flask import abort, flash, redirect, session, url_for


class AppSession:
    KEYS = ("user_id", "login", "full_name", "role_code", "role_name", "dept_id")

    @staticmethod
    def start(user_row: dict):
        session.clear()
        for key in AppSession.KEYS:
            session[key] = user_row[key]
        session.permanent = True

    @staticmethod
    def end():
        session.clear()

    @staticmethod
    def current():
        return {k: session.get(k) for k in AppSession.KEYS} if session.get("user_id") else None

    @staticmethod
    def role():
        return session.get("role_code", "VIEWER")

    @staticmethod
    def can(action: str) -> bool:
        rules = {
            "doc_create": {"ADMIN", "CLERK"},
            "doc_edit":   {"ADMIN", "CLERK"},
            "doc_delete": {"ADMIN", "CLERK"},
            "doc_route":  {"ADMIN", "CLERK", "MANAGER"},
            "decide":     {"ADMIN", "MANAGER"},
            "users":      {"ADMIN"},
        }
        return AppSession.role() in rules.get(action, set())


def login_required(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        if not session.get("user_id"):
            flash("Войдите в систему", "warn")
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapper


def permission_required(action):
    def decorator(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if not AppSession.can(action):
                abort(403)
            return view(*args, **kwargs)
        return login_required(wrapper)
    return decorator
