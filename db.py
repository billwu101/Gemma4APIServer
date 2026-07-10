"""SQLite 用量記錄：每次請求記一列，附一個彙總查詢。"""
import sqlite3
import threading
from datetime import datetime, timezone

from config import DB_PATH

_lock = threading.Lock()


def _conn() -> sqlite3.Connection:
    c = sqlite3.connect(DB_PATH, check_same_thread=False)
    c.row_factory = sqlite3.Row
    return c


def init_db() -> None:
    with _conn() as c:
        c.execute(
            """
            CREATE TABLE IF NOT EXISTS usage (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                ts                TEXT    NOT NULL,
                key_name          TEXT,
                api_format        TEXT,
                model             TEXT,
                prompt_tokens     INTEGER,
                completion_tokens INTEGER,
                total_tokens      INTEGER,
                stream            INTEGER,
                status            INTEGER
            )
            """
        )


def log_usage(key_name, api_format, model, prompt_tokens, completion_tokens, stream, status) -> None:
    prompt_tokens = prompt_tokens or 0
    completion_tokens = completion_tokens or 0
    total = prompt_tokens + completion_tokens
    with _lock, _conn() as c:
        c.execute(
            "INSERT INTO usage (ts, key_name, api_format, model, prompt_tokens, "
            "completion_tokens, total_tokens, stream, status) VALUES (?,?,?,?,?,?,?,?,?)",
            (
                datetime.now(timezone.utc).isoformat(),
                key_name,
                api_format,
                model,
                prompt_tokens,
                completion_tokens,
                total,
                int(bool(stream)),
                status,
            ),
        )


def summary() -> dict:
    with _conn() as c:
        rows = c.execute(
            "SELECT key_name, api_format, model, COUNT(*) AS requests, "
            "SUM(prompt_tokens) AS prompt_tokens, SUM(completion_tokens) AS completion_tokens, "
            "SUM(total_tokens) AS total_tokens "
            "FROM usage GROUP BY key_name, api_format, model ORDER BY total_tokens DESC"
        ).fetchall()
    return {"usage": [dict(r) for r in rows]}
