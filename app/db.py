"""Opslag in PostgreSQL (DATABASE_URL van Railway).

- docs: de documenten van de handelsplan-pagina op een pad, bijv. 'plan/current'
- mails, documents: verwerkte e-mails en bijlagen met de analyse van Grok
- quotes, watchlist: koersen van wat je volgt
- notes: notities; events: logboek; kv: kleine instellingen; ai_usage: verbruik

Is de database even niet bereikbaar, dan geeft elke functie een DBError en blijft de site draaien.
"""
import json
import logging
import os
import threading
from contextlib import contextmanager

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

log = logging.getLogger("handelsplan.db")
URL = os.environ.get("DATABASE_URL", "")


class DBError(Exception):
    """Database niet ingesteld of niet bereikbaar."""


SCHEMA = """
CREATE TABLE IF NOT EXISTS docs(
  path TEXT PRIMARY KEY, col TEXT NOT NULL, data JSONB NOT NULL, updated TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS docs_col ON docs(col);
CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS mails(
  id BIGSERIAL PRIMARY KEY, folder TEXT NOT NULL, uid BIGINT NOT NULL, message_id TEXT,
  from_addr TEXT, subject TEXT, received_at TIMESTAMPTZ, body_text TEXT, attachments INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE(folder, uid));
CREATE TABLE IF NOT EXISTS documents(
  id BIGSERIAL PRIMARY KEY, mail_id BIGINT REFERENCES mails(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, filename TEXT NOT NULL DEFAULT '', content_type TEXT, size INT, sha256 TEXT,
  text_content TEXT, blob BYTEA, status TEXT NOT NULL DEFAULT 'nieuw',
  doc_type TEXT, summary TEXT, companies JSONB, tickers JSONB, amounts JSONB, dates JSONB,
  relevance TEXT, actions JSONB, analysis JSONB, error TEXT, attempts INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(), analyzed_at TIMESTAMPTZ,
  UNIQUE(mail_id, kind, filename));
CREATE INDEX IF NOT EXISTS documents_status ON documents(status);
CREATE TABLE IF NOT EXISTS watchlist(
  symbol TEXT PRIMARY KEY, name TEXT, kind TEXT NOT NULL DEFAULT 'aandeel', position INT NOT NULL DEFAULT 0,
  added_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS quotes(
  symbol TEXT PRIMARY KEY, price DOUBLE PRECISION, change_pct DOUBLE PRECISION, prev_close DOUBLE PRECISION,
  source TEXT, fetched_at TIMESTAMPTZ, error TEXT);
CREATE TABLE IF NOT EXISTS notes(
  id BIGSERIAL PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS events(
  id BIGSERIAL PRIMARY KEY, at TIMESTAMPTZ NOT NULL DEFAULT now(), level TEXT NOT NULL, source TEXT NOT NULL, message TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS events_at ON events(at DESC);
CREATE TABLE IF NOT EXISTS ai_usage(
  at TIMESTAMPTZ NOT NULL DEFAULT now(), provider TEXT, model TEXT, input_tokens INT, output_tokens INT);
"""

_ready = False
_lock = threading.Lock()


def configured():
    return bool(URL)


def _connect():
    if not URL:
        raise DBError("DATABASE_URL is niet ingesteld")
    try:
        return psycopg.connect(URL, connect_timeout=10, row_factory=dict_row, autocommit=False)
    except psycopg.Error as e:
        raise DBError(f"Database niet bereikbaar: {e.__class__.__name__}") from e


def init():
    """Maakt de tabellen aan (veilig om vaker te draaien)."""
    global _ready
    with _lock:
        if _ready:
            return
        with _connect() as c:
            c.execute(SCHEMA)
        _ready = True
        log.info("Database klaar")


@contextmanager
def conn():
    if not _ready:
        init()
    c = _connect()
    try:
        yield c
        c.commit()
    except psycopg.Error as e:
        c.rollback()
        raise DBError(f"Databasefout: {e.__class__.__name__}: {str(e).strip()[:200]}") from e
    finally:
        c.close()


def ping():
    try:
        with conn() as c:
            c.execute("SELECT 1")
        return True
    except DBError:
        return False


# ---------------- documenten van de pagina ----------------
def _split(path: str):
    parts = [p for p in str(path).strip("/").split("/") if p]
    if len(parts) < 2 or len(parts) % 2:
        raise ValueError(f"Ongeldig documentpad: {path}")
    return "/".join(parts), "/".join(parts[:-1])


def get_doc(path):
    p, _ = _split(path)
    with conn() as c:
        r = c.execute("SELECT data FROM docs WHERE path=%s", (p,)).fetchone()
    return r["data"] if r else None


def set_doc(path, data: dict):
    p, col = _split(path)
    with conn() as c:
        c.execute("INSERT INTO docs(path,col,data,updated) VALUES(%s,%s,%s,now()) "
                  "ON CONFLICT(path) DO UPDATE SET data=excluded.data, updated=now()", (p, col, Jsonb(data)))


def _merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            _merge(a[k], v)
        else:
            a[k] = v
    return a


def update_doc(path, patch: dict) -> bool:
    cur = get_doc(path)
    if cur is None:
        return False
    set_doc(path, _merge(cur, patch))
    return True


def list_col(col, order="", direction="asc", limit=100):
    with conn() as c:
        rows = c.execute("SELECT path, data FROM docs WHERE col=%s", (col.strip("/"),)).fetchall()
    docs = [{"id": r["path"].rsplit("/", 1)[1], "data": r["data"]} for r in rows]
    if order:
        docs.sort(key=lambda d: (d["data"].get(order) is None, str(d["data"].get(order, ""))), reverse=(direction == "desc"))
    else:
        docs.sort(key=lambda d: d["id"])
    return docs[:limit]


def all_docs():
    with conn() as c:
        return {r["path"]: r["data"] for r in c.execute("SELECT path, data FROM docs").fetchall()}


def replace_docs(docs: dict):
    with conn() as c:
        c.execute("DELETE FROM docs")
        for path, data in docs.items():
            p, col = _split(path)
            c.execute("INSERT INTO docs(path,col,data) VALUES(%s,%s,%s)", (p, col, Jsonb(data)))


# ---------------- kleine instellingen ----------------
def get_kv(k, default=None):
    with conn() as c:
        r = c.execute("SELECT v FROM kv WHERE k=%s", (k,)).fetchone()
    return r["v"] if r else default


def set_kv(k, v):
    with conn() as c:
        c.execute("INSERT INTO kv(k,v) VALUES(%s,%s) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))


def get_json(k, default=None):
    v = get_kv(k)
    try:
        return json.loads(v) if v is not None else default
    except ValueError:
        return default


def set_json(k, v):
    set_kv(k, json.dumps(v, ensure_ascii=False))


# ---------------- logboek ----------------
def event(level, source, message):
    """Schrijft naar het logboek in de database én naar de Railway-logs; mislukt nooit hardop."""
    getattr(log, {"fout": "error", "let op": "warning"}.get(level, "info"))(f"[{source}] {message}")
    try:
        with conn() as c:
            c.execute("INSERT INTO events(level,source,message) VALUES(%s,%s,%s)", (level, source, str(message)[:1000]))
            c.execute("DELETE FROM events WHERE id < (SELECT COALESCE(MAX(id),0) - 2000 FROM events)")
    except DBError:
        pass


def events(limit=50):
    with conn() as c:
        return c.execute("SELECT id, at, level, source, message FROM events ORDER BY id DESC LIMIT %s", (limit,)).fetchall()


def log_usage(provider, model, usage: dict):
    try:
        with conn() as c:
            c.execute("INSERT INTO ai_usage(provider,model,input_tokens,output_tokens) VALUES(%s,%s,%s,%s)",
                      (provider, model, int(usage.get("input_tokens", 0) or 0), int(usage.get("output_tokens", 0) or 0)))
    except DBError:
        pass
