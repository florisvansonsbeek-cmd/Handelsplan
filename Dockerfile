# syntax=docker/dockerfile:1

# =============================================================================
#  Handelsplan 2027 — de hele server-app in één bestand, klaar voor Railway
#  API's, PostgreSQL, IMAP-mail en Grok draaien op Railway; niets draait los in Chrome.
# =============================================================================
#  ZO ZET JE HEM LIVE
#  1. GitHub (repo Handelsplan, branch main): Add file -> Upload files ->
#     sleep dit bestand erin -> Commit changes. Het moet precies "Dockerfile"
#     heten (zonder .txt) en vervangt de oude Dockerfile.
#     De losse "handelsplan (1).html" mag je verwijderen; die wordt niet gebruikt.
#  2. Railway -> je website-dienst -> Variables. Deze moeten erin staan:
#        APP_PASSWORD=een-lang-uniek-wachtwoord      (verplicht, anders blijft inloggen dicht)
#        DATABASE_URL=${{Postgres.DATABASE_URL}}     (via Add Variable Reference)
#        XAI_API_KEY=
#        EMAIL_HOST=imap.mail.me.com
#        EMAIL_PORT=993
#        EMAIL_USER=                                 (je iCloud-adres)
#        EMAIL_PASS=                                 (app-specifiek wachtwoord van Apple)
#        FINNHUB_API_KEY=                            (optioneel)
#     Optioneel: EMAIL_FOLDER, XAI_MODEL, NTFY_TOPIC, FRED_API_KEY, TWELVEDATA_API_KEY.
#  3. Railway bouwt vanzelf. Open je site: het inlogscherm laat zien of de server
#     en de database verbonden zijn. Na inloggen staat bovenin "Railway verbonden"
#     (groen) of welke koppeling nog mist (oranje/rood). Klik erop voor details.
#
#  Sleutels en wachtwoorden alleen in Railway -> Variables, nooit in GitHub.
#  Zet de repository op privé (GitHub -> Settings -> Change visibility).
#  Eén exemplaar (geen replicas), Serverless uit: de planner draait in de site.
#  Persoonlijk educatief plan. Geen beleggingsadvies.
# =============================================================================
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
RUN pip install 'fastapi==0.115.6' 'uvicorn==0.32.1' 'itsdangerous==2.2.0' 'httpx==0.28.1' 'psycopg[binary]==3.2.3' 'pypdf==5.1.0' 'tzdata==2026.4'
RUN mkdir -p app/static app/pages scripts seed && touch app/__init__.py scripts/__init__.py

# ---- app/ai.py ----
COPY <<"HP_EINDE_APP_AI_PY" /app/app/ai.py
"""AI-koppeling: Grok via de xAI-API (XAI_API_KEY). Claude (ANTHROPIC_API_KEY) kan als alternatief.

complete(prompt, images=[...]) geeft de tekst terug; fouten worden nette AIError-uitzonderingen,
zodat een API-limiet of storing nooit de site laat crashen.
"""
import base64
import json
import os
import re

import httpx

from . import db

XAI_KEY = os.environ.get("XAI_API_KEY", "")
XAI_BASE = os.environ.get("XAI_BASE_URL", "https://api.x.ai/v1").rstrip("/")
XAI_MODEL = os.environ.get("XAI_MODEL", "grok-4.7")
XAI_MODEL_COMPLEX = os.environ.get("XAI_MODEL_COMPLEX", XAI_MODEL)
ANTHROPIC_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-5-5")
CLAUDE_MODEL_COMPLEX = os.environ.get("CLAUDE_MODEL_COMPLEX", "claude-opus-5-5")


class AIError(Exception):
    code = "upstream_error"


class AIRateLimit(AIError):
    code = "rate_limited"


class AIAuthError(AIError):
    code = "not_granted"


class AINotConfigured(AIError):
    code = "not_declared"


def provider():
    pref = os.environ.get("AI_PROVIDER", "").lower()
    if pref == "claude" and ANTHROPIC_KEY:
        return "claude"
    if XAI_KEY:
        return "grok"
    if ANTHROPIC_KEY:
        return "claude"
    return None


def model_name(tier="default"):
    p = provider()
    if p == "grok":
        return XAI_MODEL_COMPLEX if tier == "complex" else XAI_MODEL
    if p == "claude":
        return CLAUDE_MODEL_COMPLEX if tier == "complex" else CLAUDE_MODEL
    return None


def _raise_for(r, who):
    if r.status_code == 429:
        raise AIRateLimit(f"{who}: limiet bereikt, later opnieuw")
    if r.status_code in (401, 403):
        raise AIAuthError(f"{who}: sleutel wordt niet geaccepteerd")
    if r.status_code >= 400:
        raise AIError(f"{who} gaf fout {r.status_code}: {r.text[:200]}")


def complete(prompt: str, images=None, tier="default", max_tokens=4000, timeout=180):
    """images: lijst van (mime, bytes) voor JPG/PNG."""
    p = provider()
    if not p:
        raise AINotConfigured("Geen XAI_API_KEY ingesteld")
    model = model_name(tier)
    images = images or []
    try:
        if p == "grok":
            content = prompt if not images else (
                [{"type": "image_url", "image_url": {"url": f"data:{m};base64,{base64.b64encode(b).decode()}", "detail": "high"}}
                 for m, b in images] + [{"type": "text", "text": prompt}])
            r = httpx.post(f"{XAI_BASE}/chat/completions", timeout=timeout,
                           headers={"Authorization": f"Bearer {XAI_KEY}", "Content-Type": "application/json"},
                           json={"model": model, "messages": [{"role": "user", "content": content}],
                                 "max_tokens": max_tokens, "temperature": 0.2, "stream": False})
            _raise_for(r, "Grok")
            data = r.json()
            text = ((data.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
            u = data.get("usage") or {}
            db.log_usage("grok", model, {"input_tokens": u.get("prompt_tokens"), "output_tokens": u.get("completion_tokens")})
            truncated = ((data.get("choices") or [{}])[0].get("finish_reason") == "length")
        else:
            content = prompt if not images else (
                [{"type": "image", "source": {"type": "base64", "media_type": m, "data": base64.b64encode(b).decode()}}
                 for m, b in images] + [{"type": "text", "text": prompt}])
            r = httpx.post("https://api.anthropic.com/v1/messages", timeout=timeout,
                           headers={"x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01"},
                           json={"model": model, "max_tokens": max_tokens, "messages": [{"role": "user", "content": content}]})
            _raise_for(r, "Claude")
            data = r.json()
            text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
            db.log_usage("claude", model, data.get("usage") or {})
            truncated = data.get("stop_reason") == "max_tokens"
    except httpx.HTTPError as e:
        raise AIError(f"{'Grok' if p == 'grok' else 'Claude'} niet bereikbaar: {e.__class__.__name__}") from e
    return text, truncated


def parse_json(text: str):
    """Haalt JSON uit een antwoord, ook als het in ```-blokken of tussen tekst staat."""
    t = (text or "").strip()
    for cand in (t, *(m.group(1) for m in re.finditer(r"```(?:json)?\s*([\s\S]*?)```", t))):
        try:
            return json.loads(cand)
        except ValueError:
            pass
    a, b = t.find("{"), t.rfind("}")
    if a >= 0 and b > a:
        try:
            return json.loads(t[a:b + 1])
        except ValueError:
            pass
    return None
HP_EINDE_APP_AI_PY

# ---- app/analyze.py ----
COPY <<"HP_EINDE_APP_ANALYZE_PY" /app/app/analyze.py
"""Grok leest e-mails en bijlagen en haalt de handelsinformatie eruit.

Per document: soort, korte samenvatting, bedrijven, tickers, bedragen, datums, belang en acties.
Een API-limiet stopt de ronde netjes (de rest gaat de volgende keer); na 3 mislukte pogingen
krijgt een document de status 'fout' met de reden erbij.
"""
from datetime import date

from . import ai, db

DOC_TYPES = ["transactiebevestiging", "factuur", "rekeningoverzicht", "jaaropgave", "dividend", "koersalert",
             "insider-melding", "nieuwsbrief", "analyse", "overig"]
MAX_PROMPT_TEXT = 60_000

PROMPT = """Je bent de analist achter het persoonlijke handelsplan van Floris (educatief gebruik). Zijn posities: goud- en zilvermijnen, het aandeel Circle (CRCL), de Magnificent 7 en kleine aandelen op basis van politieke transactiemeldingen (Wolf of Washington).
Lees het {wat} hieronder en haal de handelsinformatie eruit. Gebruik alleen wat er echt staat; laat lijsten leeg als iets ontbreekt. Verzin geen bedragen of datums.

Antwoord met ALLEEN dit JSON-object:
{{"doc_type":"een van: {types}",
 "summary":"2 tot 3 zinnen in het Nederlands: wat is het en wat betekent het voor Floris",
 "companies":["bedrijfsnamen"],
 "tickers":["beurssymbolen, bijv. CRCL"],
 "amounts":[{{"value":123.45,"currency":"EUR","what":"waar het bedrag voor is"}}],
 "dates":[{{"date":"JJJJ-MM-DD","what":"wat er op die datum gebeurt"}}],
 "relevance":"hoog|middel|laag",
 "actions":["korte actie of aandachtspunt voor zijn plan, of leeg"]}}

Vandaag: {vandaag}
{meta}
---
{tekst}
---"""


def _clean_list(v, n=20):
    return [str(x).strip()[:120] for x in (v or []) if str(x).strip()][:n] if isinstance(v, list) else []


def _clean_amounts(v):
    out = []
    for a in v if isinstance(v, list) else []:
        if not isinstance(a, dict):
            continue
        try:
            val = float(str(a.get("value")).replace(",", "."))
        except (TypeError, ValueError):
            continue
        out.append({"value": val, "currency": str(a.get("currency") or "")[:8].upper(), "what": str(a.get("what") or "")[:160]})
    return out[:20]


def _clean_dates(v):
    out = []
    for d in v if isinstance(v, list) else []:
        if isinstance(d, dict) and d.get("date"):
            out.append({"date": str(d["date"])[:10], "what": str(d.get("what") or "")[:160]})
    return out[:20]


def analyze_one(doc):
    """doc: rij uit documents met mail-gegevens erbij. Geeft het opgeschoonde resultaat terug."""
    wat = "e-mailbericht" if doc["kind"] == "email" else f"bijlage '{doc['filename']}'"
    meta = f"Van: {doc.get('from_addr') or ''}\nOnderwerp: {doc.get('subject') or ''}\nOntvangen: {doc.get('received_at') or ''}"
    images = []
    text = (doc.get("text_content") or "")[:MAX_PROMPT_TEXT]
    if doc.get("blob"):
        ctype = (doc.get("content_type") or "image/jpeg").replace("image/jpg", "image/jpeg")
        images = [(ctype if ctype in ("image/jpeg", "image/png") else "image/jpeg", bytes(doc["blob"]))]
        text = text or "(afbeelding: lees de tekst en cijfers in de afbeelding)"
    prompt = PROMPT.format(wat=wat, types=", ".join(DOC_TYPES), vandaag=date.today().isoformat(), meta=meta, tekst=text)
    raw, _ = ai.complete(prompt, images=images, max_tokens=1500)
    res = ai.parse_json(raw)
    if not isinstance(res, dict):
        raise ai.AIError("antwoord was geen bruikbare JSON")
    dt = str(res.get("doc_type") or "overig").lower().strip()
    rel = str(res.get("relevance") or "laag").lower().strip()
    return {"doc_type": dt if dt in DOC_TYPES else "overig", "summary": str(res.get("summary") or "")[:1200],
            "companies": _clean_list(res.get("companies")), "tickers": [t.upper() for t in _clean_list(res.get("tickers"))],
            "amounts": _clean_amounts(res.get("amounts")), "dates": _clean_dates(res.get("dates")),
            "relevance": rel if rel in ("hoog", "middel", "laag") else "laag",
            "actions": _clean_list(res.get("actions"), 8), "raw": res}


def analyze_pending(limit=20):
    """Analyseert documenten met status nieuw/wacht. Stopt netjes bij een API-limiet."""
    if not ai.provider():
        return {"skipped": "XAI_API_KEY ontbreekt"}
    from psycopg.types.json import Jsonb
    with db.conn() as c:
        docs = c.execute(
            "SELECT d.*, m.from_addr, m.subject, m.received_at FROM documents d LEFT JOIN mails m ON m.id=d.mail_id "
            "WHERE d.status IN ('nieuw','wacht') ORDER BY d.id LIMIT %s", (limit,)).fetchall()
    out = {"analyzed": 0, "failed": 0, "stopped": None}
    for d in docs:
        try:
            r = analyze_one(d)
        except ai.AIRateLimit as e:
            with db.conn() as c:
                c.execute("UPDATE documents SET status='wacht', error=%s WHERE id=%s", (str(e), d["id"]))
            out["stopped"] = "API-limiet bereikt; de rest volgt bij de volgende ronde"
            break
        except ai.AIAuthError as e:
            out["stopped"] = str(e)
            break
        except ai.AIError as e:
            tries = d["attempts"] + 1
            with db.conn() as c:
                c.execute("UPDATE documents SET attempts=%s, status=%s, error=%s WHERE id=%s",
                          (tries, "fout" if tries >= 3 else "wacht", str(e)[:300], d["id"]))
            out["failed"] += 1
            continue
        with db.conn() as c:
            c.execute("UPDATE documents SET status='geanalyseerd', doc_type=%s, summary=%s, companies=%s, tickers=%s, amounts=%s, "
                      "dates=%s, relevance=%s, actions=%s, analysis=%s, error=NULL, attempts=attempts+1, analyzed_at=now() WHERE id=%s",
                      (r["doc_type"], r["summary"], Jsonb(r["companies"]), Jsonb(r["tickers"]), Jsonb(r["amounts"]),
                       Jsonb(r["dates"]), r["relevance"], Jsonb(r["actions"]), Jsonb(r["raw"]), d["id"]))
        out["analyzed"] += 1
    return out
HP_EINDE_APP_ANALYZE_PY

# ---- app/db.py ----
COPY <<"HP_EINDE_APP_DB_PY" /app/app/db.py
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
HP_EINDE_APP_DB_PY

# ---- app/health.py ----
COPY <<"HP_EINDE_APP_HEALTH_PY" /app/app/health.py
"""Test of de koppelingen echt werken, niet alleen of de variabelen ingevuld zijn.

- Database: een SELECT 1 (elke keer, kost niets).
- AI (Grok/Claude): de modellijst opvragen met je sleutel; kost geen tokens.
- E-mail: inloggen bij IMAP en de map openen (alleen lezen).
- Finnhub: één koers opvragen (1 van je 60 per minuut).

De externe tests worden 5 minuten onthouden, zodat de site je mailserver en API's niet bestookt.
Verandert een koppeling van werkend naar kapot (of terug), dan komt dat in het logboek.
"""
import imaplib
import os
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import httpx

from . import ai, db, mail, quotes

TTL = 300           # seconden dat een externe test geldig blijft
FORCE_GAP = 20      # minimaal zoveel seconden tussen twee handmatige tests
STARTED = datetime.now(timezone.utc).isoformat(timespec="seconds")

_cache = {}         # naam -> (tijd, resultaat)
_prev = {}          # naam -> vorige state, voor het logboek
_lock = threading.Lock()
_last_force = [0.0]


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _res(state, detail, ms=None, **extra):
    """state: ok | let-op | fout | uit (niet ingesteld)."""
    return {"state": state, "detail": detail, "ms": ms, "checkedAt": _now(), **extra}


def _ms(t0):
    return int((time.monotonic() - t0) * 1000)


# ---------------- de tests ----------------
def check_database():
    if not db.configured():
        return _res("fout", "DATABASE_URL ontbreekt. Koppel in Railway de PostgreSQL-dienst aan deze app.")
    t0 = time.monotonic()
    if db.ping():
        return _res("ok", "PostgreSQL bereikbaar", _ms(t0))
    return _res("fout", "PostgreSQL niet bereikbaar. Draait de database-dienst in Railway?", _ms(t0))


def check_ai():
    p = ai.provider()
    if not p:
        return _res("uit", "XAI_API_KEY ontbreekt; zonder sleutel worden mails en bijlagen niet geanalyseerd.")
    model = ai.model_name()
    t0 = time.monotonic()
    try:
        if p == "grok":
            r = httpx.get(f"{ai.XAI_BASE}/models", timeout=10, headers={"Authorization": f"Bearer {ai.XAI_KEY}"})
            who = "Grok"
        else:
            r = httpx.get("https://api.anthropic.com/v1/models", timeout=10,
                          headers={"x-api-key": ai.ANTHROPIC_KEY, "anthropic-version": "2023-06-01"})
            who = "Claude"
    except httpx.HTTPError as e:
        return _res("fout", f"{'Grok' if p == 'grok' else 'Claude'} niet bereikbaar ({e.__class__.__name__})", _ms(t0), provider=p, model=model)
    ms = _ms(t0)
    if r.status_code in (401, 403):
        return _res("fout", f"{who} accepteert de sleutel niet. Controleer {'XAI_API_KEY' if p == 'grok' else 'ANTHROPIC_API_KEY'} in Railway.", ms, provider=p, model=model)
    if r.status_code == 429:
        return _res("let-op", f"{who} is bereikbaar, maar je limiet is even bereikt.", ms, provider=p, model=model)
    if r.status_code >= 400:
        return _res("fout", f"{who} gaf fout {r.status_code}", ms, provider=p, model=model)
    ids = set()
    try:
        body = r.json()
        for m in (body.get("data") or []) if isinstance(body, dict) else []:
            if isinstance(m, dict):
                ids.add(m.get("id"))
                ids.update(a for a in (m.get("aliases") or []) if isinstance(a, str))
    except ValueError:
        pass
    ids.discard(None)
    if ids and model not in ids:
        sample = ", ".join(sorted(i for i in ids if i)[:4])
        return _res("let-op", f"Sleutel werkt, maar model '{model}' staat niet in je account. "
                              f"Zet {'XAI_MODEL' if p == 'grok' else 'CLAUDE_MODEL'} in Railway op bijv. {sample}.",
                    ms, provider=p, model=model)
    return _res("ok", f"{who} verbonden · model {model}", ms, provider=p, model=model)


def check_mail(client_factory=None):
    if not mail.configured():
        return _res("uit", "EMAIL_HOST, EMAIL_USER of EMAIL_PASS ontbreekt.")
    s = mail.settings()
    t0 = time.monotonic()
    try:
        M = (client_factory or (lambda: imaplib.IMAP4_SSL(s["host"], s["port"], timeout=12)))()
    except (OSError, socket.timeout, imaplib.IMAP4.error) as e:
        return _res("fout", f"Mailserver {s['host']}:{s['port']} niet bereikbaar ({e.__class__.__name__})", _ms(t0))
    try:
        try:
            M.login(s["user"], s["password"])
        except imaplib.IMAP4.error:
            return _res("fout", "Inloggen bij de mailserver mislukt. Bij iCloud heb je een app-specifiek wachtwoord nodig "
                                "(appleid.apple.com → Inloggen en beveiliging).", _ms(t0))
        typ, data = M.select(mail._quote(s["folder"]), readonly=True)
        if typ != "OK":
            return _res("let-op", f"Ingelogd, maar de map '{s['folder']}' bestaat niet. Controleer EMAIL_FOLDER.", _ms(t0))
        try:
            n = int((data or [b"0"])[0])
        except (TypeError, ValueError):
            n = None
        return _res("ok", f"Ingelogd · map {s['folder']}" + (f" · {n} berichten" if n is not None else ""), _ms(t0),
                    host=s["host"], folder=s["folder"])
    except (OSError, socket.timeout, imaplib.IMAP4.error) as e:
        return _res("fout", f"Verbinding met de mailserver verbroken ({e.__class__.__name__})", _ms(t0))
    finally:
        try:
            M.logout()
        except Exception:  # afsluiten mag nooit de test laten mislukken
            pass


def check_finnhub():
    key = quotes.finnhub_key()
    if not key:
        return _res("uit", "Optioneel: zet FINNHUB_API_KEY voor koersen van aandelen en ETF's.")
    t0 = time.monotonic()
    try:
        r = httpx.get("https://finnhub.io/api/v1/quote", params={"symbol": "SPY", "token": key}, timeout=10)
    except httpx.HTTPError as e:
        return _res("fout", f"Finnhub niet bereikbaar ({e.__class__.__name__})", _ms(t0))
    ms = _ms(t0)
    if r.status_code in (401, 403):
        return _res("fout", "Finnhub accepteert de sleutel niet. Controleer FINNHUB_API_KEY.", ms)
    if r.status_code == 429:
        return _res("let-op", "Finnhub is bereikbaar, maar de limiet (60 per minuut) is even bereikt.", ms)
    if r.status_code >= 400:
        return _res("fout", f"Finnhub gaf fout {r.status_code}", ms)
    return _res("ok", "Finnhub verbonden", ms)


CHECKS = {"database": check_database, "ai": check_ai, "mail": check_mail, "finnhub": check_finnhub}
REQUIRED = ("database", "ai", "mail")
NAMES = {"database": "Database", "ai": "AI", "mail": "E-mail", "finnhub": "Finnhub"}


# ---------------- samenvoegen ----------------
def _activity():
    """Wanneer elke koppeling voor het laatst echt iets deed (uit de database)."""
    out = {}
    try:
        jobs_last = db.get_doc("system/jobs") or {}
        with db.conn() as c:
            ai_last = c.execute("SELECT max(at) AS at FROM ai_usage").fetchone()["at"]
            mail_last = c.execute("SELECT max(created_at) AS at FROM mails").fetchone()["at"]
            backlog = c.execute("SELECT status, COUNT(*) AS n FROM documents WHERE status IN ('nieuw','wacht','fout') "
                                "GROUP BY status").fetchall()
        q = db.get_json("quotes:last") or {}
        out["ai"] = {"lastUse": ai_last.isoformat() if ai_last else None,
                     "backlog": {r["status"]: r["n"] for r in backlog}}
        out["mail"] = {"lastMail": mail_last.isoformat() if mail_last else None, "lastRun": jobs_last.get("post")}
        out["finnhub"] = {"lastRun": jobs_last.get("koersen"), "quotesAt": q.get("at"), "quoteErrors": (q.get("errors") or [])[:3]}
    except db.DBError:
        pass
    return out


def _log_changes(results):
    for k, r in results.items():
        before = _prev.get(k)
        _prev[k] = r["state"]
        if before is None or before == r["state"]:
            continue
        if r["state"] in ("fout", "let-op"):
            db.event("let op", "verbinding", f"{NAMES[k]}: {r['detail']}")
        elif r["state"] == "ok":
            db.event("info", "verbinding", f"{NAMES[k]} weer verbonden")


def connections(force=False):
    now = time.monotonic()
    if force and now - _last_force[0] < FORCE_GAP:
        force = False
    if force:
        _last_force[0] = now
    with _lock:
        todo = [k for k in CHECKS if k == "database" or force or k not in _cache or now - _cache[k][0] > TTL]
    with ThreadPoolExecutor(max_workers=len(todo) or 1) as ex:
        futs = {k: ex.submit(CHECKS[k]) for k in todo}
        fresh = {}
        for k, f in futs.items():
            try:
                fresh[k] = f.result(timeout=25)
            except Exception as e:  # een test die zelf crasht is een fout, geen kapotte pagina
                fresh[k] = _res("fout", f"Test mislukt ({e.__class__.__name__})")
    with _lock:
        for k, r in fresh.items():
            _cache[k] = (now, r)
        results = {k: _cache[k][1] for k in CHECKS}
    _log_changes(fresh)
    act = _activity() if results["database"]["state"] == "ok" else {}
    for k, a in act.items():
        results[k] = {**results[k], **a}
    bad = [k for k in REQUIRED if results[k]["state"] != "ok"]
    overall = "fout" if results["database"]["state"] == "fout" else ("deels" if bad else "ok")
    return {"overall": overall, "missing": bad, "services": results, "server": server_info()}


def server_info():
    sha = os.environ.get("RAILWAY_GIT_COMMIT_SHA", "")
    return {"ok": True, "startedAt": STARTED, "railway": bool(os.environ.get("RAILWAY_ENVIRONMENT_NAME") or os.environ.get("RAILWAY_PROJECT_ID")),
            "environment": os.environ.get("RAILWAY_ENVIRONMENT_NAME", ""), "version": sha[:7], "now": _now()}
HP_EINDE_APP_HEALTH_PY

# ---- app/jobs.py ----
COPY <<"HP_EINDE_APP_JOBS_PY" /app/app/jobs.py
"""Geplande taken. De ingebouwde planner (app/scheduler.py) start ze vanzelf; met de hand kan ook:
python -m app.jobs post | koersen | markt | dagelijks | melding

- markt     : elk halfuur. Actuele koersen (Twelve Data, CoinGecko), triggers, melding bij nieuw rood.
- dagelijks : na slot van de beurs. Macrocijfers uit FRED (rente, reële rente, inflatie, banen,
              liquiditeit, kredietspread), daggrafieken voor sparklines en het niveaubord
              (50/200-daags gemiddelde, weekhoog/-laag, gemiddelde dagbeweging).
- post      : e-mail ophalen (IMAP) en documenten laten analyseren door Grok.
- koersen   : koersen van je volglijst (Finnhub, CoinGecko).
- melding   : stuurt een testmelding naar je telefoon of mail.
"""
import os
import smtplib
import sys
from datetime import date, datetime
from email.message import EmailMessage
from zoneinfo import ZoneInfo

import httpx

from . import db

TZ = ZoneInfo("Europe/Amsterdam")
TD_KEY = os.environ.get("TWELVEDATA_API_KEY", "")
FRED_KEY = os.environ.get("FRED_API_KEY", "")
MONTHS = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]

# Cijfers die de taken zelf mogen aanmaken als ze nog niet bestaan
META = {
    "mags": dict(label="Mag 7-mand (ETF MAGS)", group="Jouw posities", pillar="sentiment", prefix="$", suffix="", decimals=2),
    "netLiqChg": dict(label="Netto liquiditeit, 4 weken", group="Macro", pillar="liquiditeit", prefix="$", suffix=" mld", decimals=0),
    "spxDD": dict(label="S&P 500 t.o.v. record", group="Aandelen", pillar="sentiment", prefix="", suffix="%", decimals=1),
    "sahm": dict(label="Sahm-regel (recessiesignaal)", group="Macro", pillar="groei", prefix="", suffix="", decimals=2),
}

# Elk halfuur (Twelve Data /price, max 8 symbolen per minuut op het gratis niveau)
PRICE_TD = {"gold": "XAU/USD", "silver": "XAG/USD", "usdjpy": "USD/JPY", "crcl": "CRCL", "mags": "MAGS"}

# Dagelijks: daggrafieken voor niveaus en sparklines
LEVEL_TD = {"gold": "XAU/USD", "silver": "XAG/USD", "spy": "SPY", "qqq": "QQQ", "mags": "MAGS", "crcl": "CRCL", "usdjpy": "USD/JPY"}
LEVEL_META = {
    "gold": ("Goud", "$", "", 0), "silver": ("Zilver", "$", "", 2), "spy": ("S&P 500 (SPY)", "$", "", 2),
    "qqq": ("Nasdaq 100 (QQQ)", "$", "", 2), "mags": ("Mag 7 (MAGS)", "$", "", 2), "crcl": ("Circle (CRCL)", "$", "", 2),
    "usdjpy": ("USD/JPY", "", "", 2), "btc": ("Bitcoin", "$", "", 0), "us10y": ("US 10-jaars", "", "%", 2),
    "wti": ("WTI-olie", "$", "", 2),
}
LEVEL_ORDER = ["gold", "silver", "crcl", "mags", "qqq", "spy", "btc", "us10y", "wti", "usdjpy"]

# FRED-reeksen (gratis). Dagreeksen: laatste waarde + sparkline.
FRED_DAILY = {
    "us10y": "DGS10", "us2y": "DGS2", "us30y": "DGS30", "realYield10": "DFII10", "breakeven10": "T10YIE",
    "curve": "T10Y2Y", "wti": "DCOILWTICO", "brent": "DCOILBRENTEU", "vix": "VIXCLS", "hySpread": "BAMLH0A0HYM2",
    "fedFunds": "DFF", "spx": "SP500", "ndx": "NASDAQCOM",
}
LONG_HISTORY = {"spx": 2600}  # ca. 10 jaar handelsdagen, om het record te vinden
RATE_LIKE = {"us10y", "us2y", "us30y", "realYield10", "breakeven10", "curve", "hySpread", "fedFunds"}


# ---------------------------------------------------------------- helpers
def now_nl():
    return datetime.now(TZ)


def stamp():
    n = now_nl()
    return f"{n.day} {MONTHS[n.month - 1]} {n:%H:%M}"


def nl_date(iso):
    d = date.fromisoformat(iso[:10])
    return f"{d.day} {MONTHS[d.month - 1]}"


def nl_month(iso):
    d = date.fromisoformat(iso[:10])
    return MONTHS[d.month - 1]


def fmt_num(v, dec=1):
    s = f"{abs(v):,.{dec}f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return ("−" if v < 0 else "") + s


def signed(v, dec=1, unit=""):
    return ("+" if v > 0 else "") + fmt_num(v, dec) + unit


def fred_obs(series, limit=260):
    if not FRED_KEY:
        return []
    r = httpx.get("https://api.stlouisfed.org/fred/series/observations",
                  params={"series_id": series, "api_key": FRED_KEY, "file_type": "json",
                          "sort_order": "desc", "limit": limit}, timeout=30)
    r.raise_for_status()
    out = []
    for o in r.json().get("observations", []):
        try:
            out.append((o["date"], float(o["value"])))
        except (ValueError, KeyError):
            continue
    return list(reversed(out))


def ema(values, n):
    if len(values) < n:
        return None
    k = 2 / (n + 1)
    e = sum(values[:n]) / n
    for v in values[n:]:
        e = v * k + e * (1 - k)
    return e


def levels_row(key, bars, src):
    """bars: oplopende lijst van (datum, open, hoog, laag, slot)."""
    if len(bars) < 20:
        return None
    label, prefix, suffix, dec = LEVEL_META[key]
    closes = [b[4] for b in bars]
    last = closes[-1]
    e50, e200 = ema(closes, 50), ema(closes, 200)
    if e50 is not None and last > e50 and (e200 is None or e50 > e200):
        trend = "op"
    elif e50 is not None and last < e50 and (e200 is None or e50 < e200):
        trend = "neer"
    else:
        trend = "gemengd"
    weeks = {}
    for b in bars:
        y, w, _ = date.fromisoformat(b[0][:10]).isocalendar()
        weeks.setdefault((y, w), []).append(b)
    wk = sorted(weeks)
    cur = weeks[wk[-1]]
    prev = weeks[wk[-2]] if len(wk) > 1 else None
    has_hl = any(b[2] != b[3] for b in bars[-20:])
    if has_hl:
        adr = sum(b[2] - b[3] for b in bars[-14:]) / min(14, len(bars))
    else:
        adr = sum(abs(closes[i] - closes[i - 1]) for i in range(len(closes) - 14, len(closes))) / 14
    row = dict(key=key, label=label, prefix=prefix, suffix=suffix, decimals=dec, last=last,
               ema50=e50, ema200=e200, trend=trend,
               wkHigh=max(b[2] for b in cur), wkLow=min(b[3] for b in cur),
               prevWkHigh=max(b[2] for b in prev) if prev else None,
               prevWkLow=min(b[3] for b in prev) if prev else None,
               adr=adr, adrPct=adr / last * 100 if last else None, adrKind="hoog-laag" if has_hl else "slot-slot",
               asOf=nl_date(bars[-1][0]), src=src)
    return row


def ensure_item(items, key):
    if key not in items:
        m = META.get(key, dict(label=key, group="Macro", pillar="", prefix="", suffix="", decimals=2))
        items[key] = dict(key=key, value=None, change="", asOf="", src="", **m)
    return items[key]


# ---------------------------------------------------------------- triggers & mail
def trigger_status(t, v):
    if v is None:
        return None
    if t.get("dir") == "up":
        return "rood" if v >= t["danger"] else "oranje" if v >= t["warn"] else "groen"
    return "rood" if v <= t["danger"] else "oranje" if v <= t["warn"] else "groen"


def site_url():
    if os.environ.get("SITE_URL"):
        return os.environ["SITE_URL"].rstrip("/")
    if os.environ.get("RAILWAY_PUBLIC_DOMAIN"):
        return "https://" + os.environ["RAILWAY_PUBLIC_DOMAIN"]
    return "https://plan.vsonsbeek.nl"


def channels():
    """Welke meldingskanalen zijn ingesteld (zonder de sleutels zelf)."""
    env = os.environ.get
    return {
        "ntfy": bool(env("NTFY_TOPIC")),
        "resend": bool(env("RESEND_API_KEY") and env("ALERT_TO")),
        "smtp": all(env(k) for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD", "ALERT_TO")),
    }


def send_mail(subject, body):
    """Mail via SMTP. Let op: Railway blokkeert SMTP op het Hobby-abonnement; gebruik daar ntfy of Resend."""
    host, user, pw, to = (os.environ.get(k, "") for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD", "ALERT_TO"))
    m = EmailMessage()
    m["From"], m["To"], m["Subject"] = os.environ.get("SMTP_FROM", user), to, subject
    m.set_content(body)
    with smtplib.SMTP(host, int(os.environ.get("SMTP_PORT", "587")), timeout=30) as s:
        s.starttls()
        s.login(user, pw)
        s.send_message(m)


def notify(subject, body, url=None):
    """Stuurt een melding via elk ingesteld kanaal. Geeft terug welke kanalen gelukt zijn."""
    env = os.environ.get
    ch, done = channels(), []
    if ch["ntfy"]:
        try:
            payload = {"topic": env("NTFY_TOPIC").strip(), "title": subject, "message": body,
                       "tags": ["chart_with_downwards_trend"], "priority": 4}
            if url:
                payload["click"] = url
            headers = {"Authorization": f"Bearer {env('NTFY_TOKEN')}"} if env("NTFY_TOKEN") else {}
            r = httpx.post(env("NTFY_SERVER", "https://ntfy.sh").rstrip("/"), json=payload, headers=headers, timeout=20)
            r.raise_for_status()
            done.append("ntfy")
        except Exception as e:
            print("ntfy-melding mislukt:", e)
    if ch["resend"]:
        try:
            r = httpx.post("https://api.resend.com/emails", timeout=20,
                           headers={"Authorization": f"Bearer {env('RESEND_API_KEY')}"},
                           json={"from": env("RESEND_FROM", "Handelsplan <onboarding@resend.dev>"), "to": [env("ALERT_TO")],
                                 "subject": subject, "text": body + (f"\n\n{url}" if url else "")})
            r.raise_for_status()
            done.append("e-mail (Resend)")
        except Exception as e:
            print("Resend-mail mislukt:", e)
    if ch["smtp"]:
        try:
            send_mail(subject, body + (f"\n\n{url}" if url else ""))
            done.append("e-mail (SMTP)")
        except Exception as e:
            print("SMTP-mail mislukt:", e)
    if not any(ch.values()):
        print("Geen meldingskanaal ingesteld; melding overgeslagen:", subject)
    return done


def melding():
    done = notify("Handelsplan: testmelding", "Je meldingen werken. Springt een signaal op rood, dan krijg je zo'n bericht.", site_url())
    print("Testmelding verstuurd via:", ", ".join(done) if done else "geen kanaal")
    if any(channels().values()) and not done:
        raise RuntimeError("Testmelding mislukt; zie de logs")
    return done


def check_triggers(items):
    plan = db.get_doc("plan/current") or {}
    state = db.get_doc("system/alerts") or {"red": []}
    vals = {k: i.get("value") for k, i in items.items()}
    nowred = []
    for t in plan.get("triggers", []):
        if t.get("computed") == "gold/wti":
            v = vals["gold"] / vals["wti"] if vals.get("gold") and vals.get("wti") else None
        else:
            v = vals.get(t.get("marketKey")) if vals.get(t.get("marketKey")) is not None else t.get("current")
        if trigger_status(t, v) == "rood":
            nowred.append(t["id"])
            if t["id"] not in state.get("red", []):
                notify(f"Handelsplan: {t['label']} staat op rood",
                       f"{t['label']}: {v}\n\n{t.get('meaning', '')}", site_url())
    db.set_doc("system/alerts", {"red": nowred, "checkedAt": now_nl().isoformat(timespec="seconds")})


# ---------------------------------------------------------------- elk halfuur
def markt():
    doc = db.get_doc("market/latest") or {"items": []}
    items = {i["key"]: i for i in doc.get("items", [])}
    series = (db.get_doc("market/series") or {}).get("series", {})
    today = now_nl().date().isoformat()

    def prev_close(key):
        s = [p for p in series.get(key, []) if p[0] < today]
        return s[-1][1] if s else None

    if TD_KEY:
        try:
            syms = list(PRICE_TD.values())
            r = httpx.get("https://api.twelvedata.com/price",
                          params={"symbol": ",".join(syms), "apikey": TD_KEY}, timeout=30).json()
            if len(syms) == 1:
                r = {syms[0]: r}
            for key, sym in PRICE_TD.items():
                v = r.get(sym, {})
                if isinstance(v, dict) and "price" in v:
                    it = ensure_item(items, key)
                    price = float(v["price"])
                    pc = prev_close(key)
                    it.update(value=price, asOf=stamp(), src="Twelve Data", display=None,
                              change=f"vs slot: {signed((price / pc - 1) * 100, 1, '%')}" if pc else "")
                else:
                    print(f"Twelve Data gaf geen prijs voor {sym}: {v}")
        except Exception as e:
            print("Twelve Data mislukt:", e)
    try:
        cg = httpx.get("https://api.coingecko.com/api/v3/simple/price",
                       params={"ids": "bitcoin", "vs_currencies": "usd", "include_24hr_change": "true"}, timeout=30).json()
        it = ensure_item(items, "btc")
        it.update(value=float(cg["bitcoin"]["usd"]), asOf=stamp(), src="CoinGecko",
                  change=f"24u: {signed(cg['bitcoin'].get('usd_24h_change', 0), 1, '%')}")
    except Exception as e:
        print("CoinGecko mislukt:", e)

    doc["items"] = list(items.values())
    doc["updatedAt"] = now_nl().isoformat(timespec="seconds")
    doc["updatedBy"] = "Server (automatisch)"
    db.set_doc("market/latest", doc)
    check_triggers(items)
    print("Koersen bijgewerkt", stamp())


# ---------------------------------------------------------------- dagelijks
def dagelijks():
    doc = db.get_doc("market/latest") or {"items": []}
    items = {i["key"]: i for i in doc.get("items", [])}
    series = (db.get_doc("market/series") or {}).get("series", {})
    bars_by_key = {}
    errors = []

    # 1. FRED dagreeksen
    for key, sid in FRED_DAILY.items():
        try:
            obs = fred_obs(sid, LONG_HISTORY.get(key, 260))
        except Exception as e:
            errors.append(f"{sid}: {e}")
            continue
        if not obs:
            continue
        d, v = obs[-1]
        it = ensure_item(items, key)
        chg = ""
        if len(obs) > 1:
            pv = obs[-2][1]
            chg = f"dag: {signed((v - pv) * 100, 0, ' bp')}" if key in RATE_LIKE else f"dag: {signed((v / pv - 1) * 100, 1, '%')}"
        it.update(value=v, asOf=nl_date(d), src="FRED", change=chg, display=None)
        if key == "fedFunds":
            it["label"] = "Fed-rente (effectief)"
        if key == "spx":
            ath_d, ath_v = max(obs, key=lambda o: o[1])
            dd = ensure_item(items, "spxDD")
            dd.update(value=round((v / ath_v - 1) * 100, 2), ath=ath_v, athDate=ath_d[:10], asOf=nl_date(d),
                      src="FRED (berekend)", change=f"record {fmt_num(ath_v, 0)} op {nl_date(ath_d)}")
        series[key] = [[a, b] for a, b in obs[-130:]]
        if key in ("us10y", "wti"):
            bars_by_key[key] = ([(a, b, b, b, b) for a, b in obs], "FRED")

    # 2. Maandcijfers en weekcijfers
    try:
        sa = fred_obs("SAHMREALTIME", 13)
        if sa:
            it = ensure_item(items, "sahm")
            it.update(value=round(sa[-1][1], 2), asOf=nl_month(sa[-1][0]), src="FRED",
                      change=f"vorige mnd {fmt_num(sa[-2][1], 2)} · alarm vanaf 0,50" if len(sa) > 1 else "alarm vanaf 0,50")
            series["sahm"] = [[a, b] for a, b in sa]
    except Exception as e:
        errors.append(f"Sahm-regel: {e}")
    try:
        un = fred_obs("UNRATE", 24)
        if un:
            it = ensure_item(items, "unrate")
            it.update(value=un[-1][1], asOf=nl_month(un[-1][0]), src="FRED (BLS)",
                      change=f"vorige mnd {fmt_num(un[-2][1], 1)}%" if len(un) > 1 else "")
            series["unrate"] = [[a, b] for a, b in un]
        cl = fred_obs("ICSA", 60)
        if cl:
            ks = [(a, b / 1000) for a, b in cl]
            avg4 = sum(b for _, b in ks[-4:]) / min(4, len(ks))
            it = ensure_item(items, "claims")
            it.update(value=round(ks[-1][1]), asOf="week " + nl_date(ks[-1][0]), src="FRED (DoL)",
                      change=f"4-wk gem. {fmt_num(avg4, 1)}k")
            series["claims"] = [[a, round(b, 1)] for a, b in ks]
        for key, sid in (("cpiYoY", "CPIAUCSL"), ("coreCpi", "CPILFESL")):
            cp = fred_obs(sid, 40)
            if len(cp) > 13:
                yoy = [(cp[i][0], (cp[i][1] / cp[i - 12][1] - 1) * 100) for i in range(12, len(cp))]
                it = ensure_item(items, key)
                it.update(value=round(yoy[-1][1], 1), asOf=nl_month(yoy[-1][0]), src="FRED (BLS)",
                          change=f"vorige mnd {fmt_num(yoy[-2][1], 1)}%")
                series[key] = [[a, round(b, 2)] for a, b in yoy]
        pay = fred_obs("PAYEMS", 18)
        if len(pay) > 4:
            diffs = [(pay[i][0], pay[i][1] - pay[i - 1][1]) for i in range(1, len(pay))]
            last3 = diffs[-3:]
            it = ensure_item(items, "nfp3m")
            it.update(value=round(sum(b for _, b in last3) / 3), asOf=nl_month(last3[-1][0]), src="FRED (BLS)",
                      change=" · ".join(f"{nl_month(a)} {signed(b, 0, 'k')}" for a, b in last3))
            series["nfp3m"] = [[a, b] for a, b in diffs]
    except Exception as e:
        errors.append(f"maandcijfers: {e}")

    # 3. Netto liquiditeit = Fed-balans (WALCL, mln) − TGA (WTREGEN, mln) − reverse repo (RRPONTSYD, mld)
    try:
        walcl, tga, rrp = fred_obs("WALCL", 60), fred_obs("WTREGEN", 60), fred_obs("RRPONTSYD", 400)

        def at(obs, d):
            vals = [v for a, v in obs if a <= d]
            return vals[-1] if vals else None

        net = []
        for d, w in walcl:
            t, r = at(tga, d), at(rrp, d)
            if t is not None:
                net.append((d, (w - t) / 1000 - (r or 0)))
        if net:
            it = ensure_item(items, "netLiq")
            it.update(value=round(net[-1][1]), asOf=nl_date(net[-1][0]), src="FRED (berekend)",
                      change="Fed-balans − TGA − RRP")
            series["netLiq"] = [[a, round(b)] for a, b in net]
            if len(net) > 4:
                chg = net[-1][1] - net[-5][1]
                it2 = ensure_item(items, "netLiqChg")
                it2.update(value=round(chg), asOf=nl_date(net[-1][0]), src="FRED (berekend)",
                           change="verandering over 4 weken")
    except Exception as e:
        errors.append(f"liquiditeit: {e}")

    # 4. Daggrafieken Twelve Data (één verzoek, ≤ 8 credits)
    if TD_KEY:
        try:
            syms = list(LEVEL_TD.values())
            r = httpx.get("https://api.twelvedata.com/time_series",
                          params={"symbol": ",".join(syms), "interval": "1day", "outputsize": 260, "apikey": TD_KEY},
                          timeout=60).json()
            if len(syms) == 1:
                r = {syms[0]: r}
            for key, sym in LEVEL_TD.items():
                data = r.get(sym, {})
                vals = data.get("values") if isinstance(data, dict) else None
                if not vals:
                    errors.append(f"Twelve Data {sym}: {data.get('message', 'geen data') if isinstance(data, dict) else data}")
                    continue
                bars = [(v["datetime"][:10], float(v["open"]), float(v["high"]), float(v["low"]), float(v["close"]))
                        for v in reversed(vals)]
                bars_by_key[key] = (bars, "Twelve Data")
                series[key] = [[b[0], b[4]] for b in bars[-130:]]
        except Exception as e:
            errors.append(f"Twelve Data: {e}")

    # 5. Bitcoin daggrafiek
    try:
        cg = httpx.get("https://api.coingecko.com/api/v3/coins/bitcoin/market_chart",
                       params={"vs_currency": "usd", "days": 260, "interval": "daily"}, timeout=30).json()
        pts = []
        for ms, p in cg.get("prices", []):
            d = datetime.fromtimestamp(ms / 1000, TZ).date().isoformat()
            if pts and pts[-1][0] == d:
                pts[-1] = (d, p)
            else:
                pts.append((d, p))
        if pts:
            bars_by_key["btc"] = ([(d, p, p, p, p) for d, p in pts], "CoinGecko")
            series["btc"] = [[d, round(p)] for d, p in pts[-130:]]
    except Exception as e:
        errors.append(f"CoinGecko: {e}")

    # 6. Niveaubord
    rows = []
    for key in LEVEL_ORDER:
        if key in bars_by_key:
            bars, src = bars_by_key[key]
            row = levels_row(key, bars, src)
            if row:
                rows.append(row)

    doc["items"] = list(items.values())
    doc["updatedAt"] = now_nl().isoformat(timespec="seconds")
    doc["updatedBy"] = "Server (dagelijks)"
    db.set_doc("market/latest", doc)
    db.set_doc("market/series", {"updatedAt": doc["updatedAt"], "series": series})
    if rows:
        db.set_doc("market/levels", {"updatedAt": doc["updatedAt"], "rows": rows})
    db.set_doc("system/daily", {"at": doc["updatedAt"], "errors": errors[:20], "levels": len(rows), "series": len(series)})
    check_triggers(items)
    print(f"Dagelijkse update klaar: {len(series)} reeksen, {len(rows)} niveaus.")
    for e in errors:
        print("  let op:", e)


# ---------------------------------------------------------------- back-up
def post():
    """E-mail ophalen en daarna nieuwe documenten door Grok laten analyseren."""
    from . import analyze, mail
    mail_error = None
    if not mail.configured():
        db.event("info", "mail", "overgeslagen: EMAIL_HOST, EMAIL_USER of EMAIL_PASS ontbreekt")
    else:
        try:
            r = mail.fetch_new()
            msg = f"{r['messages']} nieuwe berichten, {r['documents']} documenten"
            if r.get("remaining"):
                msg += f"; nog {r['remaining']} te gaan in de volgende ronde"
            db.event("info", "mail", msg)
            for e in r["errors"][:5]:
                db.event("let op", "mail", e)
        except RuntimeError as e:  # mailserver weg of inlog fout: wel de wachtrij analyseren
            mail_error = str(e)
    a = analyze.analyze_pending()
    if a.get("skipped"):
        db.event("let op", "grok", "analyse overgeslagen: " + a["skipped"])
    else:
        if a["analyzed"] or a["failed"]:
            db.event("info", "grok", f"{a['analyzed']} geanalyseerd, {a['failed']} mislukt")
        if a.get("stopped"):
            db.event("let op", "grok", a["stopped"])
    db.set_json("post:last", {"at": now_nl().isoformat(timespec="seconds"), "error": mail_error})
    if mail_error:
        raise RuntimeError(mail_error)


def koersen():
    from . import quotes
    r = quotes.refresh()
    db.event("info" if not r["errors"] else "let op", "koersen",
             f"{r['updated']} koersen bijgewerkt" + (": " + "; ".join(r["errors"][:3]) if r["errors"] else ""))


JOBS = {"post": post, "koersen": koersen, "markt": markt, "dagelijks": dagelijks, "melding": melding}

if __name__ == "__main__":
    JOBS[sys.argv[1] if len(sys.argv) > 1 else "markt"]()
HP_EINDE_APP_JOBS_PY

# ---- app/mail.py ----
COPY <<"HP_EINDE_APP_MAIL_PY" /app/app/mail.py
"""E-mail ophalen via IMAP (iCloud) en bijlagen omzetten naar tekst.

- Alleen lezen: berichten blijven ongelezen en worden niet verplaatst (BODY.PEEK, readonly).
- Bij de eerste keer de laatste EMAIL_SINCE_DAYS dagen (standaard 14), daarna alleen nieuwe berichten.
- Per ronde maximaal EMAIL_MAX_PER_RUN berichten (standaard 40).
- Map instelbaar met EMAIL_FOLDER (standaard INBOX). Tip: maak in iCloud Mail een map "Handelsplan"
  met een regel, dan analyseert Grok alleen wat daarin komt.
"""
import email
import email.policy
import hashlib
import html
import imaplib
import io
import os
import re
import socket
import zipfile
from datetime import datetime, timedelta, timezone
from email.utils import parseaddr, parsedate_to_datetime

from . import db

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
MAX_ATTACHMENT = 15 * 1024 * 1024
MAX_IMAGE_BLOB = 5 * 1024 * 1024
MAX_TEXT = 200_000


def settings():
    env = os.environ.get
    return {"host": env("EMAIL_HOST", ""), "port": int(env("EMAIL_PORT", "993") or 993), "user": env("EMAIL_USER", ""),
            "password": env("EMAIL_PASS", ""), "folder": env("EMAIL_FOLDER", "INBOX") or "INBOX",
            "since_days": int(env("EMAIL_SINCE_DAYS", "14") or 14), "max": int(env("EMAIL_MAX_PER_RUN", "40") or 40)}


def configured():
    s = settings()
    return bool(s["host"] and s["user"] and s["password"])


# ---------------- tekst uit bijlagen ----------------
def _strip_html(s):
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s)
    s = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>|</h\d>|</li>", "\n", s)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    s = re.sub(r"[ \t\r\f\v]+", " ", s)
    return re.sub(r"\n\s*\n+", "\n\n", s).strip()


def _decode(b: bytes):
    for enc in ("utf-8", "cp1252", "latin-1"):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            continue
    return b.decode("utf-8", "replace")


def _xml_text(z, name):
    try:
        return _strip_html(z.read(name).decode("utf-8", "replace").replace("</w:p>", "\n").replace("</a:p>", "\n"))
    except KeyError:
        return ""


def extract_text(filename: str, ctype: str, data: bytes):
    """Geeft (tekst, soort) terug. soort: 'tekst', 'afbeelding' of 'overgeslagen'."""
    name = (filename or "").lower()
    ctype = (ctype or "").lower()
    if ctype == "application/pdf" or name.endswith(".pdf"):
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(data))
        parts = []
        for page in reader.pages[:60]:
            try:
                parts.append(page.extract_text() or "")
            except Exception:  # één kapotte pagina mag de rest niet tegenhouden
                continue
        return "\n".join(parts).strip(), "tekst"
    if name.endswith(".docx") or "wordprocessingml" in ctype:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            return _xml_text(z, "word/document.xml"), "tekst"
    if name.endswith(".xlsx") or "spreadsheetml" in ctype:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            sheets = sorted(n for n in z.namelist() if n.startswith("xl/worksheets/sheet"))
            return (_xml_text(z, "xl/sharedStrings.xml") + "\n" + "\n".join(_xml_text(z, s) for s in sheets[:5])).strip(), "tekst"
    if name.endswith(".pptx") or "presentationml" in ctype:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            slides = sorted(n for n in z.namelist() if re.match(r"ppt/slides/slide\d+\.xml$", n))
            return "\n".join(_xml_text(z, s) for s in slides[:40]).strip(), "tekst"
    if ctype in ("text/html", "application/xhtml+xml") or name.endswith((".html", ".htm")):
        return _strip_html(_decode(data)), "tekst"
    if ctype.startswith("text/") or name.endswith((".txt", ".csv", ".md", ".json", ".xml", ".tsv", ".eml")):
        return _decode(data), "tekst"
    if ctype in ("image/jpeg", "image/png", "image/jpg") or name.endswith((".jpg", ".jpeg", ".png")):
        return "", "afbeelding"
    return "", "overgeslagen"


def _body_text(msg):
    plain = msg.get_body(preferencelist=("plain",))
    if plain is not None:
        try:
            return plain.get_content().strip()
        except (LookupError, UnicodeDecodeError):
            return _decode(plain.get_payload(decode=True) or b"").strip()
    htmlpart = msg.get_body(preferencelist=("html",))
    if htmlpart is not None:
        try:
            return _strip_html(htmlpart.get_content())
        except (LookupError, UnicodeDecodeError):
            return _strip_html(_decode(htmlpart.get_payload(decode=True) or b""))
    return ""


def _attachments(msg):
    """Echte bijlagen; kleine inline-afbeeldingen (logo's, handtekeningen) slaan we over."""
    for part in msg.walk():
        if part.is_multipart():
            continue
        disp = (part.get_content_disposition() or "").lower()
        fname = part.get_filename() or ""
        ctype = part.get_content_type()
        if disp != "attachment" and not fname:
            continue
        data = part.get_payload(decode=True) or b""
        if disp == "inline" and ctype.startswith("image/") and len(data) < 40_000:
            continue
        yield fname or f"bijlage.{ctype.split('/')[-1]}", ctype, data


# ---------------- opslaan ----------------
def store_message(folder, uid, raw: bytes):
    """Slaat één bericht op met zijn bijlagen als documenten. Geeft het aantal nieuwe documenten terug."""
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    try:
        received = parsedate_to_datetime(msg["Date"]) if msg["Date"] else None
        if received and received.tzinfo is None:
            received = received.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        received = None
    subject = str(msg["Subject"] or "")[:500]
    sender = parseaddr(str(msg["From"] or ""))
    from_addr = (f"{sender[0]} <{sender[1]}>" if sender[0] else sender[1])[:300]
    body = _body_text(msg)[:MAX_TEXT]
    atts = list(_attachments(msg))
    with db.conn() as c:
        row = c.execute(
            "INSERT INTO mails(folder,uid,message_id,from_addr,subject,received_at,body_text,attachments) "
            "VALUES(%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(folder,uid) DO NOTHING RETURNING id",
            (folder, uid, str(msg["Message-ID"] or "")[:300], from_addr, subject, received, body, len(atts))).fetchone()
        if not row:
            return 0
        mail_id, n = row["id"], 0
        if len(body) > 40 or not atts:
            c.execute("INSERT INTO documents(mail_id,kind,filename,content_type,size,text_content,status) "
                      "VALUES(%s,'email','',%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                      (mail_id, "text/plain", len(body), body, "nieuw" if body else "overgeslagen"))
            n += 1
        seen = set()
        for fname, ctype, data in atts:
            base, k = fname, 2
            while fname in seen:  # twee bijlagen met dezelfde naam
                fname = f"{base} ({k})"
                k += 1
            seen.add(fname)
            sha = hashlib.sha256(data).hexdigest()
            text, kind, err, blob, status = "", "overgeslagen", None, None, "nieuw"
            if len(data) > MAX_ATTACHMENT:
                status, err = "overgeslagen", "bijlage groter dan 15 MB"
            else:
                try:
                    text, kind = extract_text(fname, ctype, data)
                except Exception as e:  # kapotte of beveiligde bijlage: vastleggen en doorgaan
                    status, err = "fout", f"kon de bijlage niet lezen: {e.__class__.__name__}"
                if status == "nieuw":
                    if kind == "afbeelding":
                        if len(data) <= MAX_IMAGE_BLOB:
                            blob = data
                        else:
                            status, err = "overgeslagen", "afbeelding groter dan 5 MB"
                    elif kind == "overgeslagen":
                        status, err = "overgeslagen", f"bestandstype {ctype} wordt niet gelezen"
                    elif not text.strip():
                        status, err = "overgeslagen", "geen leesbare tekst (bijv. een gescande PDF)"
            c.execute("INSERT INTO documents(mail_id,kind,filename,content_type,size,sha256,text_content,blob,status,error) "
                      "VALUES(%s,'bijlage',%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                      (mail_id, fname[:300], ctype, len(data), sha, text[:MAX_TEXT], blob, status, err))
            n += 1
    return n


def _since(days):
    d = datetime.now(timezone.utc) - timedelta(days=days)
    return f"{d.day:02d}-{MONTHS[d.month - 1]}-{d.year}"


def _quote(folder):
    return '"' + folder.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fetch_new(client_factory=None):
    """Haalt nieuwe berichten op. client_factory is er alleen voor tests."""
    s = settings()
    if not configured():
        return {"skipped": "EMAIL_HOST, EMAIL_USER of EMAIL_PASS ontbreekt"}
    folder = s["folder"]
    out = {"messages": 0, "documents": 0, "errors": []}
    try:
        M = (client_factory or (lambda: imaplib.IMAP4_SSL(s["host"], s["port"], timeout=30)))()
    except (OSError, socket.timeout, imaplib.IMAP4.error) as e:
        raise RuntimeError(f"mailserver {s['host']}:{s['port']} niet bereikbaar ({e.__class__.__name__})") from e
    try:
        try:
            M.login(s["user"], s["password"])
        except imaplib.IMAP4.error as e:
            raise RuntimeError("inloggen bij de mailserver mislukt: controleer EMAIL_USER en EMAIL_PASS "
                               "(bij iCloud een app-specifiek wachtwoord)") from e
        typ, data = M.select(_quote(folder), readonly=True)
        if typ != "OK":
            raise RuntimeError(f"map '{folder}' bestaat niet op de mailserver")
        typ, resp = M.response("UIDVALIDITY")
        validity = (resp[0].decode() if resp and resp[0] else "")
        state = db.get_json(f"mail:{folder}", {}) or {}
        if state.get("validity") and validity and state["validity"] != validity:
            state = {}  # map is opnieuw opgebouwd: opnieuw beginnen
        last = int(state.get("last_uid", 0))
        if last:
            typ, data = M.uid("SEARCH", None, f"UID {last + 1}:*")
        else:
            typ, data = M.uid("SEARCH", None, "SINCE", _since(s["since_days"]))
        uids = sorted(int(x) for x in (data[0].split() if data and data[0] else []) if int(x) > last)
        for uid in uids[: s["max"]]:
            try:
                typ, parts = M.uid("FETCH", str(uid), "(BODY.PEEK[])")
                raw = next((p[1] for p in parts if isinstance(p, tuple) and len(p) > 1), None)
                if raw:
                    out["documents"] += store_message(folder, uid, raw)
                    out["messages"] += 1
            except db.DBError:
                raise
            except Exception as e:  # één vreemd bericht mag de rest niet blokkeren
                out["errors"].append(f"bericht {uid}: {e.__class__.__name__}: {str(e)[:120]}")
            last = max(last, uid)
            db.set_json(f"mail:{folder}", {"validity": validity, "last_uid": last})
        out["remaining"] = max(0, len(uids) - s["max"])
    finally:
        try:
            M.logout()
        except Exception:
            pass
    return out
HP_EINDE_APP_MAIL_PY

# ---- app/main.py ----
COPY <<"HP_EINDE_APP_MAIN_PY" /app/app/main.py
"""Handelsplan-server voor Railway: inlog met één wachtwoord, PostgreSQL, Grok, e-mail en koersen.

Alle geheimen komen uit environment variables (Railway → Variables):
  APP_PASSWORD   het wachtwoord om in te loggen (verplicht; zonder dit blijft de site dicht)
  DATABASE_URL   PostgreSQL
  XAI_API_KEY    Grok
  EMAIL_HOST, EMAIL_PORT, EMAIL_USER, EMAIL_PASS   iCloud IMAP
  FINNHUB_API_KEY (optioneel)   live koersen
"""
import asyncio
import hmac
import json
import logging
import os
import secrets
import threading
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.middleware.gzip import GZipMiddleware
from starlette.middleware.sessions import SessionMiddleware

from . import ai, db, health, jobs, mail, patch, quotes, scheduler

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("handelsplan")
BASE = Path(__file__).resolve().parent
APP_PASSWORD = os.environ.get("APP_PASSWORD", "")
INBOX_TOKEN = os.environ.get("INBOX_TOKEN", "")
FORCE_HTTPS = os.environ.get("FORCE_HTTPS", "1") == "1"
SECURE_COOKIE = os.environ.get("SECURE_COOKIE", "1") == "1"
SEED = BASE.parent / "seed"


def _session_secret():
    if os.environ.get("SESSION_SECRET"):
        return os.environ["SESSION_SECRET"]
    try:
        s = db.get_kv("session_secret")
        if not s:
            s = secrets.token_hex(32)
            db.set_kv("session_secret", s)
        return s
    except db.DBError:
        log.warning("Database nog niet bereikbaar: tijdelijke sessiesleutel (opnieuw inloggen na herstart)")
        return secrets.token_hex(32)


# ---------------- opstarten: tabellen, startgegevens, planner ----------------
def _seed():
    load = lambda fn: json.loads((SEED / fn).read_text(encoding="utf-8"))
    placed = []
    for path, fn in {"plan/current": "plan.json", "market/latest": "market.json",
                     "inbox/juli-plan": "inbox_juli.json", "history/v1-start": "history_v1.json"}.items():
        if db.get_doc(path) is None:
            data = load(fn)
            if path == "plan/current":
                patch.apply(data, None)
            if path == "market/latest":
                patch.apply(None, data)
            db.set_doc(path, data)
            placed.append(path)
    plan, market, notes = patch.apply(db.get_doc("plan/current"), db.get_doc("market/latest"))
    if notes:
        db.set_doc("plan/current", plan)
        db.set_doc("market/latest", market)
    quotes.ensure_watchlist()
    return placed, notes


def _startup_worker():
    """Wacht tot de database er is (Railway start Postgres soms later) en start dan de rest."""
    delay = 2
    while True:
        try:
            db.init()
            placed, notes = _seed()
            db.event("info", "server", "gestart" + (f"; startgegevens geplaatst: {', '.join(placed)}" if placed else "")
                     + (f"; bijgewerkt: {'; '.join(notes)}" if notes else ""))
            break
        except db.DBError as e:
            log.error("Database nog niet klaar (%s); opnieuw over %s s", e, delay)
            time.sleep(delay)
            delay = min(delay * 2, 60)
    if os.environ.get("SCHEDULER", "1") != "0":
        scheduler.start()


@asynccontextmanager
async def lifespan(_app):
    if not APP_PASSWORD:
        log.error("APP_PASSWORD ontbreekt: niemand kan inloggen tot je die in Railway → Variables zet")
    if not db.configured():
        log.error("DATABASE_URL ontbreekt: koppel een PostgreSQL-database in Railway")
    else:
        threading.Thread(target=_startup_worker, daemon=True, name="opstart").start()
    yield


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
app.add_middleware(GZipMiddleware, minimum_size=1024)
app.add_middleware(SessionMiddleware, secret_key=_session_secret() if db.configured() else secrets.token_hex(32),
                   https_only=SECURE_COOKIE, same_site="strict", max_age=60 * 60 * 24 * 14)
app.mount("/static", StaticFiles(directory=BASE / "static"), name="static")


@app.middleware("http")
async def https_and_headers(request: Request, call_next):
    proto = request.headers.get("x-forwarded-proto", "")
    if FORCE_HTTPS and proto and proto.split(",")[0].strip() != "https" and request.url.path != "/health":
        return RedirectResponse(str(request.url.replace(scheme="https")), status_code=308)
    try:
        resp = await call_next(request)
    except db.DBError as e:
        resp = JSONResponse({"detail": "De database is tijdelijk niet bereikbaar. Probeer het zo opnieuw.", "error": str(e)}, 503)
    h = resp.headers
    h.setdefault("X-Frame-Options", "DENY")
    h.setdefault("X-Content-Type-Options", "nosniff")
    h.setdefault("Referrer-Policy", "same-origin")
    if proto == "https" or (FORCE_HTTPS and SECURE_COOKIE):
        h.setdefault("Strict-Transport-Security", "max-age=31536000")
    return resp


@app.exception_handler(db.DBError)
async def db_down(_request, exc):
    return JSONResponse({"detail": "De database is tijdelijk niet bereikbaar. Probeer het zo opnieuw.", "error": str(exc)}, 503)


@app.exception_handler(ai.AIError)
async def ai_failed(_request, exc):
    status = 429 if isinstance(exc, ai.AIRateLimit) else 503 if isinstance(exc, ai.AINotConfigured) else 502
    return JSONResponse({"detail": str(exc), "code": exc.code}, status)


# ---------------- inloggen met alleen een wachtwoord ----------------
_fails: dict[str, list[float]] = {}


def _blocked(*keys, limit=8):
    now = time.time()
    for k in keys:
        _fails[k] = [t for t in _fails.get(k, []) if now - t < 900]
    return any(len(_fails[k]) >= limit for k in keys)


def require_login(request: Request):
    if not request.session.get("ok"):
        raise HTTPException(401, "Niet ingelogd")


async def _json(request: Request):
    try:
        b = await request.json()
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise HTTPException(400, "Ongeldige invoer")
    if not isinstance(b, dict):
        raise HTTPException(400, "Ongeldige invoer")
    return b


@app.get("/login", response_class=HTMLResponse)
def login_page():
    return (BASE / "static" / "login.html").read_text(encoding="utf-8")


@app.post("/login")
async def login(request: Request):
    ip = request.headers.get("x-forwarded-for", "").split(",")[0].strip() or (request.client.host if request.client else "?")
    keys = ("ip:" + ip, "alle")
    if _blocked("ip:" + ip) or _blocked("alle", limit=30):
        return JSONResponse({"error": "Te veel pogingen. Probeer het over 15 minuten opnieuw."}, 429)
    if not APP_PASSWORD:
        return JSONResponse({"error": "Inloggen is nog niet ingesteld: zet APP_PASSWORD in Railway → Variables."}, 503)
    form = await _json(request)
    if not hmac.compare_digest(str(form.get("password", "")).encode(), APP_PASSWORD.encode()):
        for k in keys:
            _fails.setdefault(k, []).append(time.time())
        await asyncio.sleep(0.5)
        return JSONResponse({"error": "Dat wachtwoord klopt niet."}, 401)
    _fails.pop("ip:" + ip, None)
    request.session.clear()
    request.session["ok"] = True
    request.session["at"] = int(time.time())
    return {"ok": True}


@app.post("/logout")
def logout(request: Request):
    request.session.clear()
    return {"ok": True}


# ---------------- pagina ----------------
@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    if not request.session.get("ok"):
        return RedirectResponse("/login", 303)
    return FileResponse(BASE / "pages" / "index.html", headers={"Cache-Control": "no-store"})


@app.get("/health")
def health_check():
    """Openbaar (ook zonder inlog): alleen of de server draait, de database bereikbaar is en inloggen is ingesteld."""
    return {"ok": True, "database": db.ping() if db.configured() else False, "login": bool(APP_PASSWORD),
            "version": health.server_info()["version"]}


# ---------------- opslag van de pagina ----------------
@app.get("/api/doc")
def get_doc(path: str, request: Request):
    require_login(request)
    return {"exists": (d := db.get_doc(path)) is not None, "data": d}


@app.put("/api/doc")
async def set_doc(path: str, request: Request):
    require_login(request)
    db.set_doc(path, await _json(request))
    return {"ok": True}


@app.patch("/api/doc")
async def update_doc(path: str, request: Request):
    require_login(request)
    if not db.update_doc(path, await _json(request)):
        raise HTTPException(404, "Document bestaat niet")
    return {"ok": True}


@app.get("/api/col")
def list_col(path: str, request: Request, order: str = "", dir: str = "asc", limit: int = 100):
    require_login(request)
    return {"docs": db.list_col(path, order, dir, min(limit, 1000))}


# ---------------- AI voor de pagina (transcripts, vragen, marktstatus) ----------------
@app.post("/api/ai")
async def ai_endpoint(request: Request):
    require_login(request)
    body = await _json(request)
    prompt = str(body.get("prompt", ""))[:250_000]
    tier = "complex" if body.get("tier") == "complex" else "default"
    text, truncated = await asyncio.to_thread(ai.complete, prompt, None, tier, 6000, 300)
    return {"text": text, "truncated": truncated}


# ---------------- post: verwerkte e-mails en documenten ----------------
def _doc_row(r):
    out = {k: r[k] for k in ("id", "kind", "filename", "content_type", "size", "status", "doc_type", "summary", "companies",
                            "tickers", "amounts", "dates", "relevance", "actions", "error", "subject", "from_addr", "mail_id")}
    for k in ("created_at", "analyzed_at", "received_at"):
        out[k] = r[k].isoformat() if r.get(k) else None
    return out


@app.get("/api/documents")
def documents(request: Request, q: str = "", type: str = "", relevance: str = "", status: str = "", limit: int = 100):
    require_login(request)
    where, args = [], []
    if type:
        where.append("d.doc_type=%s"); args.append(type)
    if relevance:
        where.append("d.relevance=%s"); args.append(relevance)
    if status:
        where.append("d.status=%s"); args.append(status)
    if q:
        where.append("(d.summary ILIKE %s OR m.subject ILIKE %s OR d.filename ILIKE %s OR d.companies::text ILIKE %s OR d.tickers::text ILIKE %s)")
        args += [f"%{q}%"] * 5
    sql = ("SELECT d.id, d.kind, d.filename, d.content_type, d.size, d.status, d.doc_type, d.summary, d.companies, d.tickers, "
           "d.amounts, d.dates, d.relevance, d.actions, d.error, d.created_at, d.analyzed_at, d.mail_id, m.subject, m.from_addr, m.received_at "
           "FROM documents d LEFT JOIN mails m ON m.id=d.mail_id" + (" WHERE " + " AND ".join(where) if where else "") +
           " ORDER BY COALESCE(m.received_at, d.created_at) DESC, d.id DESC LIMIT %s")
    with db.conn() as c:
        rows = c.execute(sql, (*args, min(max(limit, 1), 500))).fetchall()
        counts = c.execute("SELECT status, COUNT(*) AS n FROM documents GROUP BY status").fetchall()
        hoog = c.execute("SELECT COUNT(*) AS n FROM documents WHERE relevance='hoog'").fetchone()["n"]
        mails = c.execute("SELECT COUNT(*) AS n FROM mails").fetchone()["n"]
    return {"documents": [_doc_row(r) for r in rows], "counts": {r["status"]: r["n"] for r in counts},
            "important": hoog, "mails": mails, "last": db.get_json("post:last")}


@app.get("/api/documents/{doc_id}")
def document(doc_id: int, request: Request):
    require_login(request)
    with db.conn() as c:
        r = c.execute("SELECT d.*, m.subject, m.from_addr, m.received_at FROM documents d LEFT JOIN mails m ON m.id=d.mail_id "
                      "WHERE d.id=%s", (doc_id,)).fetchone()
    if not r:
        raise HTTPException(404, "Document niet gevonden")
    out = _doc_row(r)
    out["text"] = (r["text_content"] or "")[:20000]
    return out


@app.post("/api/documents/{doc_id}/reanalyze")
def reanalyze(doc_id: int, request: Request):
    require_login(request)
    with db.conn() as c:
        n = c.execute("UPDATE documents SET status='nieuw', attempts=0, error=NULL WHERE id=%s AND (text_content<>'' OR blob IS NOT NULL)",
                      (doc_id,)).rowcount
    if not n:
        raise HTTPException(400, "Dit document heeft geen tekst om te analyseren")
    started = scheduler.run_in_background("post", "opnieuw analyseren")
    return {"ok": True, "started": started}


@app.post("/api/documents/{doc_id}/to-inbox")
def to_inbox(doc_id: int, request: Request):
    """Zet een document in de Inbox van je plan, zodat je er plan-voorstellen van kunt laten maken."""
    require_login(request)
    with db.conn() as c:
        r = c.execute("SELECT d.*, m.subject, m.from_addr, m.received_at FROM documents d LEFT JOIN mails m ON m.id=d.mail_id "
                      "WHERE d.id=%s", (doc_id,)).fetchone()
    if not r:
        raise HTTPException(404, "Document niet gevonden")
    text = (r["text_content"] or r["summary"] or "")[:180_000]
    db.set_doc(f"inbox/mail-{doc_id}", {
        "source": "E-mail", "title": (r["subject"] or r["filename"] or "E-mail")[:300], "url": "",
        "date": (r["received_at"] or r["created_at"]).date().isoformat(),
        "text": (f"Van: {r['from_addr'] or ''}\nSamenvatting (Grok): {r['summary'] or ''}\n\n" + text)[:180_000],
        "status": "nieuw", "addedBy": "mail", "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds")})
    return {"ok": True, "id": f"mail-{doc_id}"}


# ---------------- koersen, notities, logboek ----------------
@app.get("/api/quotes")
def get_quotes(request: Request):
    require_login(request)
    rows = quotes.watchlist()
    for r in rows:
        r["fetched_at"] = r["fetched_at"].isoformat() if r.get("fetched_at") else None
    return {"quotes": rows, "finnhub": bool(quotes.finnhub_key()), "last": db.get_json("quotes:last")}


@app.post("/api/watchlist")
async def add_watch(request: Request):
    require_login(request)
    b = await _json(request)
    sym = str(b.get("symbol", "")).strip().upper()[:20]
    kind = b.get("kind") if b.get("kind") in ("aandeel", "etf", "crypto") else "aandeel"
    if not sym or not all(ch.isalnum() or ch in ".:-^" for ch in sym):
        raise HTTPException(400, "Ongeldig symbool")
    with db.conn() as c:
        pos = c.execute("SELECT COALESCE(MAX(position),0)+1 AS p FROM watchlist").fetchone()["p"]
        c.execute("INSERT INTO watchlist(symbol,name,kind,position) VALUES(%s,%s,%s,%s) ON CONFLICT(symbol) DO UPDATE SET name=excluded.name, kind=excluded.kind",
                  (sym, str(b.get("name") or sym)[:80], kind, pos))
    scheduler.run_in_background("koersen", "volglijst gewijzigd")
    return {"ok": True}


@app.delete("/api/watchlist/{symbol}")
def del_watch(symbol: str, request: Request):
    require_login(request)
    with db.conn() as c:
        c.execute("DELETE FROM watchlist WHERE symbol=%s", (symbol.upper(),))
        c.execute("DELETE FROM quotes WHERE symbol=%s", (symbol.upper(),))
    return {"ok": True}


@app.get("/api/notes")
def get_notes(request: Request):
    require_login(request)
    with db.conn() as c:
        rows = c.execute("SELECT id, title, body, created_at, updated_at FROM notes ORDER BY updated_at DESC LIMIT 200").fetchall()
    for r in rows:
        r["created_at"], r["updated_at"] = r["created_at"].isoformat(), r["updated_at"].isoformat()
    return {"notes": rows}


@app.post("/api/notes")
async def add_note(request: Request):
    require_login(request)
    b = await _json(request)
    body = str(b.get("body", "")).strip()
    if not body:
        raise HTTPException(400, "Een notitie mag niet leeg zijn")
    with db.conn() as c:
        if b.get("id"):
            c.execute("UPDATE notes SET title=%s, body=%s, updated_at=now() WHERE id=%s", (str(b.get("title") or "")[:200], body[:20000], int(b["id"])))
        else:
            c.execute("INSERT INTO notes(title, body) VALUES(%s,%s)", (str(b.get("title") or "")[:200], body[:20000]))
    return {"ok": True}


@app.delete("/api/notes/{note_id}")
def del_note(note_id: int, request: Request):
    require_login(request)
    with db.conn() as c:
        c.execute("DELETE FROM notes WHERE id=%s", (note_id,))
    return {"ok": True}


@app.get("/api/events")
def get_events(request: Request, limit: int = 50):
    require_login(request)
    rows = db.events(min(max(limit, 1), 500))
    for r in rows:
        r["at"] = r["at"].isoformat()
    return {"events": rows}


# ---------------- inbox vanaf je laptop ----------------
@app.post("/api/inbox")
async def inbox_push(request: Request):
    """Voor het transcript-script: header 'Authorization: Bearer <INBOX_TOKEN>'."""
    auth = request.headers.get("authorization", "")
    if not INBOX_TOKEN or not hmac.compare_digest(auth.encode(), f"Bearer {INBOX_TOKEN}".encode()):
        raise HTTPException(401, "Ongeldige token")
    b = await _json(request)
    doc_id = "auto-" + secrets.token_hex(6)
    db.set_doc(f"inbox/{doc_id}", {
        "source": str(b.get("source", "Overig"))[:80], "title": str(b.get("title", ""))[:300],
        "url": str(b.get("url", ""))[:500], "date": str(b.get("date", ""))[:10],
        "text": str(b.get("text", ""))[:180_000], "status": "nieuw" if b.get("text") else "transcript nodig",
        "addedBy": "automatisch", "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds")})
    return {"ok": True, "id": doc_id}


# ---------------- status, taken, back-up ----------------
@app.get("/api/status")
def status(request: Request):
    """Welke koppelingen actief zijn, zonder de sleutels zelf te tonen."""
    require_login(request)
    ok_db = db.ping()
    try:
        daily = db.get_doc("system/daily") or {} if ok_db else {}
        jobs_st = scheduler.status() if ok_db else {}
        market_at = (db.get_doc("market/latest") or {}).get("updatedAt") if ok_db else None
    except db.DBError:
        daily, jobs_st, market_at = {}, {}, None
    ms = mail.settings()
    return {
        "ai": {"provider": ai.provider(), "model": ai.model_name()}, "database": ok_db,
        "mail": {"configured": mail.configured(), "host": ms["host"], "folder": ms["folder"]},
        "finnhub": bool(quotes.finnhub_key()), "twelvedata": bool(jobs.TD_KEY), "fred": bool(jobs.FRED_KEY),
        "notify": {**jobs.channels(), "any": any(jobs.channels().values())}, "inboxToken": bool(INBOX_TOKEN),
        "marketAt": market_at, "dailyAt": daily.get("at"), "dailyErrors": daily.get("errors", []),
        "jobs": jobs_st, "site": jobs.site_url(),
    }


@app.get("/api/connections")
def connections(request: Request, force: int = 0):
    """Echte verbindingstest per koppeling (database, AI, e-mail, Finnhub)."""
    require_login(request)
    return health.connections(force=bool(force))


@app.post("/api/run/{name}")
def run_job(name: str, request: Request):
    require_login(request)
    if name not in jobs.JOBS:
        raise HTTPException(404, "Onbekende taak")
    started = scheduler.run_in_background(name, "handmatig")
    return {"started": started, "running": scheduler._state["running"]}


@app.get("/api/export")
def export(request: Request):
    """Back-up van je plan, notities en volglijst als JSON (ook terug te zetten in de losse Chrome-versie)."""
    require_login(request)
    with db.conn() as c:
        notes = c.execute("SELECT title, body, created_at::text, updated_at::text FROM notes").fetchall()
        watch = c.execute("SELECT symbol, name, kind, position FROM watchlist").fetchall()
    data = {"app": "handelsplan-2026", "format": 1, "exportedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "docs": db.all_docs(), "notes": notes, "watchlist": watch}
    name = f"handelsplan-backup-{datetime.now():%Y%m%d-%H%M}.json"
    return Response(json.dumps(data, ensure_ascii=False, default=str), media_type="application/json",
                    headers={"Content-Disposition": f'attachment; filename="{name}"'})


@app.post("/api/import")
async def import_backup(request: Request):
    """Zet een JSON-back-up terug (van deze site of van de losse Chrome-versie)."""
    require_login(request)
    raw = await request.body()
    if len(raw) > 30 * 1024 * 1024:
        raise HTTPException(413, "Dit bestand is te groot")
    try:
        j = json.loads(raw)
    except ValueError:
        raise HTTPException(400, "Dit is geen back-upbestand (.json) van je handelsplan")
    docs = j.get("docs") if isinstance(j, dict) else None
    if j.get("app") != "handelsplan-2026" or not isinstance(docs, dict) or "plan/current" not in docs:
        raise HTTPException(400, "In dit bestand staat geen handelsplan")
    clean = {}
    for p, d in docs.items():
        try:
            db._split(p)
        except ValueError:
            continue
        if isinstance(d, dict):
            clean[p] = d
    db.set_doc("system/voor-herstel", {"at": datetime.now(timezone.utc).isoformat(), "docs": db.all_docs()})
    keep = {"system/voor-herstel": db.get_doc("system/voor-herstel")}
    db.replace_docs({**clean, **keep})
    plan, market, notes = patch.apply(db.get_doc("plan/current"), db.get_doc("market/latest"))
    db.set_doc("plan/current", plan)
    if market is not None:
        db.set_doc("market/latest", market)
    with db.conn() as c:
        for n in j.get("notes") or []:
            if isinstance(n, dict) and n.get("body"):
                c.execute("INSERT INTO notes(title, body) VALUES(%s,%s)", (str(n.get("title") or "")[:200], str(n["body"])[:20000]))
    db.event("info", "server", f"back-up teruggezet: {len(clean)} onderdelen")
    return {"ok": True, "docs": len(clean)}
HP_EINDE_APP_MAIN_PY

# ---- app/pages/index.html ----
COPY <<"HP_EINDE_APP_PAGES_INDEX_HTML" /app/app/pages/index.html
<!doctype html>
<html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<script src="/static/shim.js"></script>
<title>Handelsplan 2027</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,700&family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
<style>
/* Layout: a dark instrument strip (live status, ticker, six tabs) over a cool working surface.
   "Markt" reads top-down like the economy itself: verdict + regime compass → six things that matter →
   the macro machine (causes → price of money → transmission → your positions) → two lenses → every number. */
:root{
  --bg:#EDF0F4; --surface:#FFFFFF; --surface-2:#F4F6F9; --surface-3:#E8ECF1;
  --ink:#111C27; --muted:#55616D; --faint:#8692A0; --line:#D3D9E0; --line-2:#E4E8ED;
  --band:#0F1923; --band-2:#172532; --band-ink:#EDF2F6; --band-muted:#93A2B0; --band-line:#243443;
  --accent:#8B5A0A; --accent-2:#B07A1C; --accent-soft:#F5E8D0; --on-accent:#FFFFFF;
  --good:#1A7848; --good-soft:#DAEFE2; --warn:#9A5A05; --warn-soft:#F8EAD1; --bad:#AE2E28; --bad-soft:#F7DDDA;
  --info:#1F4F7C; --info-soft:#E1EBF5;
  --sc1:#B07A1C; --sc2:#B0412F; --sc3:#2B5F92; --sc4:#2E8A6E;
  --font-display:"Bricolage Grotesque","Segoe UI",system-ui,sans-serif;
  --font-body:"IBM Plex Sans","Segoe UI",system-ui,-apple-system,sans-serif;
  --font-mono:"IBM Plex Mono",ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace;
  --r:12px; --gap:clamp(14px,2vw,22px);
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --bg:#0B1117; --surface:#121A22; --surface-2:#17212B; --surface-3:#1D2935;
    --ink:#E4EAF0; --muted:#97A5B2; --faint:#6E7D8B; --line:#25313D; --line-2:#1E2933;
    --band:#070B0F; --band-2:#0E151C; --band-ink:#E4EAF0; --band-muted:#8697A6; --band-line:#1D2833;
    --accent:#DDA64B; --accent-2:#E8BC6C; --accent-soft:#3A2B12; --on-accent:#141006;
    --good:#4FC48B; --good-soft:#12301F; --warn:#E8A53F; --warn-soft:#382811; --bad:#F06B60; --bad-soft:#3B1916;
    --info:#86B6E3; --info-soft:#172A3C;
    --sc1:#DDA64B; --sc2:#E26A55; --sc3:#6FA3D6; --sc4:#4DBA97;
    color-scheme:dark;
  }
}
:root[data-theme="dark"]{
  --bg:#0B1117; --surface:#121A22; --surface-2:#17212B; --surface-3:#1D2935;
  --ink:#E4EAF0; --muted:#97A5B2; --faint:#6E7D8B; --line:#25313D; --line-2:#1E2933;
  --band:#070B0F; --band-2:#0E151C; --band-ink:#E4EAF0; --band-muted:#8697A6; --band-line:#1D2833;
  --accent:#DDA64B; --accent-2:#E8BC6C; --accent-soft:#3A2B12; --on-accent:#141006;
  --good:#4FC48B; --good-soft:#12301F; --warn:#E8A53F; --warn-soft:#382811; --bad:#F06B60; --bad-soft:#3B1916;
  --info:#86B6E3; --info-soft:#172A3C;
  --sc1:#DDA64B; --sc2:#E26A55; --sc3:#6FA3D6; --sc4:#4DBA97;
  color-scheme:dark;
}
*{box-sizing:border-box}
[hidden]{display:none!important}
body{background:var(--bg);color:var(--ink);font-family:var(--font-body);font-size:15px;line-height:1.55;-webkit-font-smoothing:antialiased}
body::before{content:"";position:fixed;inset:0 0 auto;height:env(safe-area-inset-top,0px);z-index:10;background:var(--band)}
a{color:var(--info)}
h1,h2,h3{font-family:var(--font-display);text-wrap:balance;margin:0;line-height:1.15;letter-spacing:-.012em}
h2{font-size:1.35rem;font-weight:700}
h3{font-size:1.05rem;font-weight:700}
p{margin:0}
.num,.mono{font-family:var(--font-mono);font-variant-numeric:tabular-nums}
.eyebrow{font-family:var(--font-mono);font-size:.7rem;letter-spacing:.09em;text-transform:uppercase;color:var(--muted)}
.muted{color:var(--muted)} .small{font-size:.84rem} .faint{color:var(--faint)}
.wrap{max-width:1240px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px))}

/* ---------- instrument strip ---------- */
.top{position:sticky;top:env(safe-area-inset-top,0px);z-index:5;background:var(--band);color:var(--band-ink);border-bottom:1px solid var(--band-line)}
.top .wrap{display:flex;flex-direction:column;gap:4px;padding-block:10px 0}
.brandrow{display:flex;align-items:center;gap:10px 14px;flex-wrap:wrap}
.brand{font-family:var(--font-display);font-weight:700;font-size:1.12rem;letter-spacing:-.01em;white-space:nowrap}
.brand span{color:var(--accent)}
.live{display:inline-flex;align-items:center;gap:6px;font:500 .74rem var(--font-mono);color:var(--band-muted);white-space:nowrap}
.live i{width:8px;height:8px;border-radius:50%;background:var(--band-muted)}
.live.on i{background:var(--good);box-shadow:0 0 0 3px color-mix(in srgb,var(--good) 25%,transparent)}
.live.old i{background:var(--warn)}
.connbtn{appearance:none;display:inline-flex;align-items:center;gap:7px;border:1px solid var(--band-line);background:var(--band-2);color:var(--band-ink);font:500 .76rem var(--font-body);border-radius:999px;padding:4px 11px 4px 9px;cursor:pointer;white-space:nowrap}
.connbtn:hover{border-color:var(--band-muted)}
.connbtn > i{width:9px;height:9px;border-radius:50%;background:var(--band-muted);flex:none}
.connbtn.ok > i{background:#3FB871;box-shadow:0 0 0 3px rgba(63,184,113,.22)}
.connbtn.deels > i,.connbtn.lokaal > i{background:#E0A93A;box-shadow:0 0 0 3px rgba(224,169,58,.22)}
.connbtn.fout > i{background:#EE5D52;box-shadow:0 0 0 3px rgba(238,93,82,.25)}
.connbtn.busy > i{animation:cpulse 1s ease-in-out infinite alternate}
@keyframes cpulse{to{opacity:.35}}
@media (prefers-reduced-motion:reduce){.connbtn.busy > i{animation:none}}
.cdots{display:inline-flex;gap:3px;margin-left:2px}
.cdots b{width:6px;height:6px;border-radius:50%;background:var(--band-muted)}
.cdots b.ok{background:#3FB871}.cdots b.let-op{background:#E0A93A}.cdots b.fout{background:#EE5D52}.cdots b.uit{background:transparent;box-shadow:inset 0 0 0 1px var(--band-muted)}
@media (max-width:560px){.cdots{display:none}}
.connpanel{margin-top:14px;display:flex;flex-direction:column;gap:12px}
.cgrid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}
@media (max-width:1000px){.cgrid{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width:560px){.cgrid{grid-template-columns:minmax(0,1fr)}}
.csvc{background:var(--surface-2);border-radius:10px;padding:12px 14px;display:flex;flex-direction:column;gap:6px;font-size:.86rem;border-left:4px solid var(--line)}
.csvc.ok{border-left-color:var(--good)}.csvc.let-op{border-left-color:var(--warn)}.csvc.fout{border-left-color:var(--bad)}
.csvc .sechead{gap:6px}.csvc h3{font-size:.98rem}
.csvc .act{color:var(--muted);font-size:.8rem}
.cfoot{display:flex;flex-wrap:wrap;align-items:center;gap:8px 14px;font-size:.8rem;color:var(--muted)}
.cfoot .btnrow{margin-left:auto}
.ticker{display:flex;gap:6px 16px;flex-wrap:wrap;font:400 .76rem var(--font-mono);color:var(--band-muted);margin-left:auto}
.ticker b{color:var(--band-ink);font-weight:500}
.iconbtn{appearance:none;border:1px solid var(--band-line);background:var(--band-2);color:var(--band-muted);font:500 .76rem var(--font-body);border-radius:7px;padding:4px 9px;cursor:pointer}
.iconbtn:hover{color:var(--band-ink)}
.tabs{display:flex;gap:2px;overflow-x:auto;scrollbar-width:none;margin:0 -6px}
.tabs::-webkit-scrollbar{display:none}
.tab{appearance:none;border:0;background:none;color:var(--band-muted);font:500 .92rem var(--font-body);padding:10px 12px 11px;cursor:pointer;white-space:nowrap;border-bottom:2px solid transparent}
.tab:hover{color:var(--band-ink)}
.tab[aria-selected="true"]{color:var(--band-ink);border-bottom-color:var(--accent)}
.tab:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
@media (max-width:620px){.ticker{display:none}#logoutBtn{display:none}.tab{padding:9px 8px 10px;font-size:.88rem}.top .wrap{gap:2px}}
.tab .count{font:500 .7rem var(--font-mono);background:var(--accent);color:var(--on-accent);border-radius:999px;padding:1px 6px;margin-left:6px}

main{padding-block:var(--gap) 72px}
section.panel{display:flex;flex-direction:column;gap:var(--gap)}
.grid{display:grid;gap:var(--gap);grid-template-columns:minmax(0,1fr)}
.g-2{grid-template-columns:minmax(0,1.5fr) minmax(0,1fr)}
.g-2e{grid-template-columns:repeat(2,minmax(0,1fr))}
@media (max-width:900px){.g-2,.g-2e{grid-template-columns:minmax(0,1fr)}}
.panel > *,.grid > *,.box{min-width:0}
.box{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);padding:clamp(16px,2.2vw,22px)}
.stack{display:flex;flex-direction:column;gap:12px}
.sechead{display:flex;align-items:baseline;justify-content:space-between;gap:8px 14px;flex-wrap:wrap}
.secintro{max-width:72ch;color:var(--muted);font-size:.93rem}

/* ---------- pills, chips, buttons ---------- */
.pill{display:inline-flex;align-items:center;gap:6px;font:500 .76rem var(--font-body);padding:3px 10px;border-radius:999px;white-space:nowrap}
.pill::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.pill.plain::before{display:none}
.t-good{background:var(--good-soft);color:var(--good)} .t-warn{background:var(--warn-soft);color:var(--warn)}
.t-bad{background:var(--bad-soft);color:var(--bad)} .t-neutral{background:var(--info-soft);color:var(--info)}
.t-accent{background:var(--accent-soft);color:var(--accent)}
.chips{display:flex;gap:6px;flex-wrap:wrap}
.chip{font:500 .74rem var(--font-mono);padding:2px 8px;border-radius:6px;background:var(--surface-2);border:1px solid var(--line);color:var(--muted);white-space:nowrap}
.btn{appearance:none;font:600 .9rem var(--font-body);border-radius:9px;padding:9px 15px;cursor:pointer;border:1px solid var(--line);background:var(--surface);color:var(--ink);display:inline-flex;align-items:center;gap:8px}
.btn:hover{border-color:var(--faint)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--on-accent)}
.btn.primary:hover{filter:brightness(1.07)}
.btn.sm{padding:5px 11px;font-size:.8rem;border-radius:7px}
.btn:disabled{opacity:.5;cursor:not-allowed}
.btnrow{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
.status{font-size:.86rem;color:var(--muted)} .status.err{color:var(--bad)}
button:focus-visible,input:focus-visible,select:focus-visible,textarea:focus-visible,[tabindex]:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--faint);flex:none}
.dot.rustig{background:var(--good)} .dot.gespannen{background:var(--warn)} .dot.stress{background:var(--bad)} .dot.info{background:var(--info)}
.dir{font:600 1rem var(--font-mono);line-height:1}
.dir.pos{color:var(--good)} .dir.neg{color:var(--bad)} .dir.flat{color:var(--faint)}

/* ---------- Markt: hero ---------- */
.hero{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(0,1fr);gap:clamp(18px,3vw,40px);align-items:center;background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:clamp(18px,3vw,34px)}
@media (max-width:900px){.hero{grid-template-columns:minmax(0,1fr)}}
.hero h1{font-size:clamp(1.85rem,3.9vw,2.85rem);font-weight:700;margin-top:10px}
.hero .lede{font-size:1.04rem;max-width:62ch;margin-top:12px;color:var(--ink)}
.hero .pills{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
.hero .btnrow{margin-top:18px}
.compass{margin:0;display:flex;flex-direction:column;gap:10px;align-items:center}
.compass svg{width:100%;max-width:380px;height:auto}
.compass figcaption{font-size:.86rem;color:var(--muted);max-width:44ch;text-align:center}
.cq-stag{fill:var(--bad-soft)} .cq-refl{fill:var(--warn-soft)} .cq-gold{fill:var(--good-soft)} .cq-krimp{fill:var(--info-soft)}
.c-axis{stroke:var(--line);stroke-width:1} .c-frame{fill:none;stroke:var(--line);stroke-width:1}
.c-qn{font:700 12.5px var(--font-body);fill:var(--ink)} .c-qa{font:400 10.5px var(--font-body);fill:var(--muted)}
.c-ax{font:500 10px var(--font-mono);fill:var(--faint);letter-spacing:.06em}
.c-halo{fill:var(--accent);opacity:.18} .c-dot{fill:var(--accent);stroke:var(--surface);stroke-width:2}
.c-now{font:600 11px var(--font-mono);fill:var(--accent)} .c-head{stroke:var(--accent);stroke-width:1.6;stroke-dasharray:4 3;fill:none}
.c-arrow{fill:var(--accent)}
@media (prefers-reduced-motion:no-preference){.c-halo{animation:pulse 2.4s ease-in-out infinite;transform-origin:center;transform-box:fill-box}@keyframes pulse{50%{opacity:.06;transform:scale(1.5)}}}

/* ---------- Markt: six points ---------- */
.points{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:0}
.pt{padding:14px 18px;border-top:1px solid var(--line-2);display:grid;grid-template-columns:12px minmax(0,1fr);gap:4px 10px;align-content:start}
.pt:nth-child(-n+3){border-top:0}
.pt:not(:nth-child(3n+1)){border-left:1px solid var(--line-2)}
.pt .dot{margin-top:6px}
.pt b{font-weight:600;font-size:.97rem}
.pt p{grid-column:2;color:var(--muted);font-size:.89rem}
.dot.bad{background:var(--bad)} .dot.warn{background:var(--warn)} .dot.good{background:var(--good)}
@media (max-width:980px){.points{grid-template-columns:repeat(2,minmax(0,1fr))}.pt:nth-child(-n+3){border-top:1px solid var(--line-2)}.pt:nth-child(-n+2){border-top:0}.pt:not(:nth-child(3n+1)){border-left:0}.pt:nth-child(2n){border-left:1px solid var(--line-2)}}
@media (max-width:620px){.points{grid-template-columns:minmax(0,1fr)}.pt:nth-child(2){border-top:1px solid var(--line-2)}.pt:nth-child(2n){border-left:0}.pt{padding:12px 4px}}

/* ---------- Markt: machine ---------- */
.machine{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:34px;position:relative}
.stage{position:relative;display:flex;flex-direction:column;gap:10px;min-width:0}
.stage:not(:last-child)::after{content:"";position:absolute;right:-23px;top:50%;width:11px;height:11px;border-top:2px solid var(--faint);border-right:2px solid var(--faint);transform:translateY(-50%) rotate(45deg)}
.stage-h{display:flex;gap:10px;align-items:center;min-height:42px}
.stage-n{font:500 .78rem var(--font-mono);width:24px;height:24px;border-radius:50%;display:grid;place-items:center;background:var(--band);color:var(--band-ink);flex:none}
.stage-h b{display:block;font-family:var(--font-display);font-size:1rem}
.stage-h small{display:block;color:var(--muted);font-size:.78rem}
.pl{background:var(--surface-2);border:1px solid var(--line);border-radius:10px;padding:12px 13px;display:flex;flex-direction:column;gap:8px;cursor:pointer;transition:border-color .15s, box-shadow .15s}
.pl:hover{border-color:var(--faint)}
.pl.sel{border-color:var(--accent);box-shadow:0 0 0 2px color-mix(in srgb,var(--accent) 35%,transparent)}
.pl-top{display:flex;justify-content:space-between;align-items:flex-start;gap:8px}
.pl-name{font-weight:600;font-size:.95rem;line-height:1.25}
.pl-q{font-size:.78rem;color:var(--muted);margin-top:1px}
.kv{display:grid;grid-template-columns:minmax(0,1fr) auto auto;gap:8px;align-items:center;font-size:.8rem}
.kv span{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.kv b{font:500 .84rem var(--font-mono);text-align:right}
.pl-read{font-size:.82rem;color:var(--ink);line-height:1.45}
.pl-hint{font-size:.74rem;color:var(--faint)}
.pc{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:11px 13px;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 10px;align-items:center;transition:opacity .15s, border-color .15s}
.pc .nm{font-weight:600;font-size:.95rem}
.pc .why{grid-column:1/-1;font-size:.8rem;color:var(--muted);line-height:1.4}
.pc .eff{display:flex;align-items:center;gap:6px}
.machine.focus .pc{opacity:.45}
.machine.focus .pc.hit{opacity:1}
.pc.hit.neg{border-color:var(--bad)} .pc.hit.pos{border-color:var(--good)}
.selnote{font-size:.85rem;color:var(--muted);min-height:1.3em}
@media (max-width:1100px){
  .machine{grid-template-columns:minmax(0,1fr);gap:30px}
  .stage-body{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:10px}
  .stage:not(:last-child)::after{right:auto;top:auto;left:50%;bottom:-21px;transform:translateX(-50%) rotate(135deg)}
}
.stage-body{display:flex;flex-direction:column;gap:10px}

/* ---------- sparkline ---------- */
.spark{display:block;overflow:visible}
.sp-a{fill:var(--accent-soft)} .sp-l{fill:none;stroke:var(--muted);stroke-width:1.3;stroke-linejoin:round} .sp-d{fill:var(--accent)}

/* ---------- lenses ---------- */
.lenses{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--gap)}
@media (max-width:980px){.lenses{grid-template-columns:minmax(0,1fr)}}
.lens{display:flex;flex-direction:column;gap:14px}
.lens-who{font-size:.86rem;color:var(--muted)}
.lens-who b{color:var(--ink);font-weight:600}
.lens-method{font-size:.86rem;color:var(--muted)}
.lens-q{font-family:var(--font-display);font-size:1.08rem;font-weight:600;line-height:1.3}
.ck{display:grid;grid-template-columns:12px minmax(0,1fr) auto;gap:3px 10px;padding:11px 0;border-top:1px solid var(--line-2);align-items:start}
.ck .dot{margin-top:6px}
.ck b{font-weight:600;font-size:.92rem}
.ck p{grid-column:2/-1;font-size:.86rem;color:var(--muted)}
.ck .val{font:500 .8rem var(--font-mono);color:var(--ink);background:var(--surface-2);border:1px solid var(--line);border-radius:6px;padding:1px 7px;white-space:nowrap}
.take{background:var(--accent-soft);border-radius:10px;padding:14px 16px}
.take .eyebrow{color:var(--accent)}
.take p{margin-top:6px;font-size:.95rem;line-height:1.5}
.basis{font-size:.78rem;color:var(--faint)}
.lvl{overflow-x:auto}
.lvl table{min-width:860px}
.trend{font:600 .78rem var(--font-mono)}
.trend.op{color:var(--good)} .trend.neer{color:var(--bad)} .trend.gemengd{color:var(--warn)} .trend.range{color:var(--muted)}

/* ---------- indicators ---------- */
.ind{columns:2 380px;column-gap:34px}
.ind-g{padding:6px 0 14px;break-inside:avoid;display:inline-block;width:100%}
.ind-gh{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 0 6px;border-bottom:1px solid var(--line)}
.ind-gh h3{font-size:.98rem}
.ir{display:grid;grid-template-columns:minmax(0,1.35fr) 78px minmax(0,.9fr);grid-template-areas:"l s v" "c c m";gap:1px 12px;padding:8px 0;border-bottom:1px solid var(--line-2);align-items:center}
.ir .l{grid-area:l;font-size:.9rem}
.ir .s{grid-area:s}
.ir .v{grid-area:v;font:500 .95rem var(--font-mono);text-align:right;white-space:nowrap}
.ir .c{grid-area:c;font-size:.76rem;color:var(--muted)}
.ir .m{grid-area:m;font-size:.72rem;color:var(--faint);text-align:right;white-space:nowrap}
.ir .v.bad{color:var(--bad)} .ir .v.warn{color:var(--warn)}
.ir .l{overflow-wrap:break-word;min-width:0}
@media (max-width:620px){
  .ir{grid-template-columns:minmax(0,1fr) auto;grid-template-areas:"l v" "c s" "m m"}
  .ir .m{text-align:left;white-space:normal}
}

/* ---------- tables ---------- */
.tbl{overflow-x:auto;max-width:100%}
table{border-collapse:collapse;width:100%;font-size:.89rem}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line-2);vertical-align:top}
th{font:500 .7rem var(--font-mono);letter-spacing:.06em;text-transform:uppercase;color:var(--muted);white-space:nowrap}
td.r,th.r{text-align:right} td.c,th.c{text-align:center}
td .num{white-space:nowrap}
.cell{display:inline-grid;place-items:center;min-width:42px;height:26px;border-radius:6px;font:500 .8rem var(--font-mono)}
.i2{background:var(--good);color:var(--surface)} .i1{background:var(--good-soft);color:var(--good)}
.i0{background:var(--surface-2);color:var(--muted)} .im1{background:var(--bad-soft);color:var(--bad)} .im2{background:var(--bad);color:var(--surface)}

/* ---------- calendar ---------- */
.cal{list-style:none;padding:0;margin:0}
.cal li{display:grid;grid-template-columns:96px minmax(0,1fr);gap:4px 14px;padding:11px 0;border-top:1px solid var(--line-2)}
.cal li:first-child{border-top:0}
.cal .d{font:400 .84rem var(--font-mono)}
.cal .d small{display:block;color:var(--muted);font-size:.72rem}
.cal li.past{opacity:.45}
.cal li.soon .d{color:var(--accent);font-weight:500}
.cal b{font-weight:600}

/* ---------- plan ---------- */
.actions{list-style:none;padding:0;margin:0}
.actions li{display:grid;grid-template-columns:22px minmax(0,1fr);gap:8px;padding:9px 0;border-top:1px solid var(--line-2)}
.actions li:first-child{border-top:0}
.actions li::before{content:"→";font-family:var(--font-mono);color:var(--accent)}
.sbar{display:flex;height:32px;border-radius:8px;overflow:hidden}
.sbar div{display:flex;align-items:center;justify-content:center;font:500 .78rem var(--font-mono);color:var(--surface);min-width:0;overflow:hidden;white-space:nowrap}
.slegend{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:8px 18px}
.slegend .it{display:grid;grid-template-columns:12px minmax(0,1fr) auto;gap:8px;align-items:baseline;font-size:.9rem}
.slegend .sw{width:12px;height:12px;border-radius:3px;transform:translateY(2px)}
details.pos{background:var(--surface);border:1px solid var(--line);border-radius:var(--r)}
details.pos > summary{list-style:none;cursor:pointer;padding:16px 18px;display:grid;grid-template-columns:minmax(0,1fr) auto auto;gap:6px 14px;align-items:center}
details.pos > summary::-webkit-details-marker{display:none}
details.pos > summary .chev{width:9px;height:9px;border-right:2px solid var(--faint);border-bottom:2px solid var(--faint);transform:rotate(45deg);transition:transform .15s;margin-right:4px}
details.pos[open] > summary .chev{transform:rotate(225deg)}
details.pos .sumwhy{grid-column:1/-1;font-size:.86rem;color:var(--muted);display:flex;gap:8px;align-items:baseline}
.posbody{padding:4px 18px 18px;display:grid;gap:16px;border-top:1px solid var(--line-2)}
.cols2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}
@media (max-width:700px){.cols2{grid-template-columns:minmax(0,1fr)}}
.blist{list-style:none;padding:0;margin:6px 0 0;display:flex;flex-direction:column;gap:5px;font-size:.9rem}
.blist li{display:grid;grid-template-columns:16px minmax(0,1fr);gap:6px}
.blist.plus li::before{content:"+";color:var(--good);font-family:var(--font-mono);font-weight:500}
.blist.minus li::before{content:"−";color:var(--bad);font-family:var(--font-mono);font-weight:500}
.rules{list-style:none;padding:0;margin:4px 0 0;counter-reset:r}
.rules li{counter-increment:r;display:grid;grid-template-columns:30px minmax(0,1fr);gap:8px;padding:8px 0;border-top:1px solid var(--line-2);font-size:.92rem}
.rules li::before{content:"R" counter(r);font:500 .76rem var(--font-mono);color:var(--accent);padding-top:3px}
.levels{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px;margin-top:6px}
.level{background:var(--surface-2);border-radius:8px;padding:9px 11px}
.level b{font:500 .86rem var(--font-mono);display:block}
.level span{font-size:.8rem;color:var(--muted)}
.scrow{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:6px;margin-top:8px}
.scrow div{display:flex;flex-direction:column;align-items:center;gap:4px;font-size:.72rem;color:var(--muted);text-align:center}
.weight{display:flex;align-items:center;gap:8px;font-size:.86rem;color:var(--muted)}
.weight input{width:80px}
.sc{border-top:4px solid var(--c)}
.sc .prob{font:500 2.1rem var(--font-mono);color:var(--c);line-height:1}
.sc .hd{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
.check ul{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:6px}

/* ---------- signals ---------- */
.sigsum{display:flex;gap:8px;flex-wrap:wrap}
.trig{display:grid;grid-template-columns:minmax(0,1.25fr) minmax(0,1fr) auto;gap:6px 16px;align-items:center;padding:13px 0;border-top:1px solid var(--line-2)}
.trig .name{font-weight:600}
.trig .meaning{grid-column:1/-1;font-size:.85rem;color:var(--muted)}
.gauge{height:9px;border-radius:5px;overflow:hidden;display:flex}
.gauge i{display:block;height:100%}
.gwrap{position:relative;padding-top:2px}
.gwrap .gd{position:absolute;top:-3px;width:4px;height:15px;border-radius:2px;background:var(--ink);transform:translateX(-50%)}
.gwrap .lab{display:flex;justify-content:space-between;font:400 .68rem var(--font-mono);color:var(--muted);margin-top:4px}
.trig .val{font:500 1rem var(--font-mono);text-align:right;white-space:nowrap}
@media (max-width:640px){.trig{grid-template-columns:minmax(0,1fr) auto}.trig .gwrap{grid-column:1/-1;order:3}}

/* ---------- forms, inbox ---------- */
label{font-size:.82rem;font-weight:500;color:var(--muted);display:block;margin-bottom:4px}
input,select,textarea{font:inherit;font-size:.92rem;color:var(--ink);background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:8px 10px;width:100%}
textarea{min-height:200px;resize:vertical;font-family:var(--font-mono);font-size:.82rem;line-height:1.5}
.frow{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.item{padding:14px 0;border-top:1px solid var(--line-2);display:grid;gap:6px}
.item:first-child{border-top:0}
.item .h{display:flex;gap:8px 12px;align-items:center;flex-wrap:wrap}
.item details summary{cursor:pointer;font-size:.85rem;color:var(--info)}
.pre{white-space:pre-wrap}
.pending{border:1px solid var(--accent);background:var(--accent-soft)}
.chg{display:grid;grid-template-columns:22px minmax(0,1fr);gap:8px;padding:9px 0;border-top:1px solid color-mix(in srgb,var(--accent) 25%,transparent);align-items:start;cursor:pointer;margin:0;color:var(--ink);font-weight:400;font-size:.92rem}
.chg input{width:16px;height:16px;margin-top:3px;accent-color:var(--accent)}
.chg .from{color:var(--muted);text-decoration:line-through}
.empty{border:1px dashed var(--line);border-radius:var(--r);padding:26px;text-align:center;color:var(--muted);display:grid;gap:6px;justify-items:center}
.notice{border-radius:10px;padding:12px 14px;font-size:.92rem;background:var(--good-soft);color:var(--good)}
.notice.bad{background:var(--bad-soft);color:var(--bad)}
#notice:not([hidden]),#pendingPanel:not([hidden]){margin-bottom:var(--gap)}
.kv .sk{display:block;width:54px;height:16px}
.answer{white-space:pre-wrap;background:var(--surface-2);border-radius:8px;padding:12px 14px;font-size:.93rem}

/* ---------- cyclus ---------- */
:root{--viz-now:#b8650f;--viz-now-ink:#ffffff;--viz-x:#2a78d6;--viz-mute:#8692A0}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--viz-now:#c98500;--viz-now-ink:#141006;--viz-x:#3987e5;--viz-mute:#6E7D8B}}
:root[data-theme="dark"]{--viz-now:#c98500;--viz-now-ink:#141006;--viz-x:#3987e5;--viz-mute:#6E7D8B}
.cyhero{align-items:start}
@media (min-width:901px){.cyhero{grid-template-columns:minmax(0,1.4fr) minmax(0,1fr)}}
.cy-like{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin-top:16px}
@media (max-width:560px){.cy-like{grid-template-columns:minmax(0,1fr)}}
.cy-like .lk{display:grid;gap:2px;align-content:start;background:var(--surface-2);border:1px solid var(--line);border-radius:10px;padding:8px 12px;font-size:.84rem}
.cy-like .lk b{font-weight:600}
.cy-like .lk span{color:var(--muted);font-size:.78rem;line-height:1.35}
.cy-stats{display:grid;gap:10px}
.cy-stat{background:var(--surface-2);border-radius:12px;padding:14px 16px;display:grid;gap:2px}
.cy-stat b{font:600 2rem/1.1 var(--font-body);letter-spacing:-.015em}
.cy-stat span{font-size:.92rem;font-weight:500}
.cy-stat small{font-size:.78rem;color:var(--muted)}
@media (max-width:900px){.cy-stats{grid-template-columns:repeat(3,minmax(0,1fr))}}
@media (max-width:600px){.cy-stats{grid-template-columns:minmax(0,1fr)}.cy-stat b{font-size:1.7rem}}
.cy-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:var(--gap)}
.cy-card{display:flex;flex-direction:column;gap:12px}
.cy-head h3{margin-top:2px}
.cy-fig{margin:0}
.cy-fig svg{display:block;width:100%;height:auto;overflow:visible}
.cy-txt{display:flex;flex-direction:column;gap:8px}
.cy-now{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.cy-txt p{font-size:.88rem;line-height:1.5}
.cy-txt .xline{color:var(--muted)}
.cy-txt .xline i{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--viz-x);margin-right:6px}
@media (max-width:1100px){
  .cy-grid{grid-template-columns:minmax(0,1fr)}
  .cy-card{display:grid;grid-template-columns:minmax(0,430px) minmax(0,1fr);gap:10px 26px;align-items:start}
  .cy-head{grid-column:1/-1}
}
@media (max-width:680px){.cy-card{display:flex;flex-direction:column}}
svg .cy-past{fill:none;stroke:var(--ink);stroke-width:2;stroke-linecap:round;stroke-linejoin:round;opacity:.72}
svg .cy-future{fill:none;stroke:var(--viz-mute);stroke-width:2;stroke-dasharray:3 5;stroke-linecap:round}
svg .cy-guide{stroke:var(--line-2);stroke-width:1}
svg .cy-col{fill:var(--accent-soft)}
svg .cy-ph{font:500 10.5px var(--font-body);fill:var(--muted)}
svg .cy-ph.on{font-weight:700;fill:var(--accent)}
svg .cy-hit{fill:transparent}
svg .cy-gdot{fill:var(--surface);stroke:var(--viz-mute);stroke-width:2}
svg .cy-glab{font:500 10.5px var(--font-mono);fill:var(--muted)}
svg .cy-halo{fill:var(--viz-now);opacity:.2}
svg .cy-dot{fill:var(--viz-now);stroke:var(--surface);stroke-width:2.5}
svg .cy-pill{fill:var(--viz-now)}
svg .cy-pilltx{font:700 10.5px var(--font-body);fill:var(--viz-now-ink);letter-spacing:.08em}
svg .cy-xdot{fill:var(--viz-x);stroke:var(--surface);stroke-width:2}
svg .cy-xlab{font:600 11px var(--font-body);fill:var(--ink)}
svg [tabindex]{cursor:help;outline:none}
svg [tabindex]:focus-visible .cy-hit{stroke:var(--accent);stroke-width:2}
@media (prefers-reduced-motion:no-preference){svg .cy-halo{animation:pulse 2.4s ease-in-out infinite;transform-origin:center;transform-box:fill-box}}
.cy-key{display:flex;gap:6px 18px;flex-wrap:wrap;font-size:.82rem;color:var(--muted);align-items:center}
.cy-key i{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;vertical-align:-1px}
.cy-key .k-now{background:var(--viz-now)} .cy-key .k-ghost{border:2px solid var(--viz-mute);width:10px;height:10px;box-sizing:border-box}
.cy-key .k-x{background:var(--viz-x)} .cy-key .k-line{width:18px;height:0;border-radius:0;border-top:2px dashed var(--viz-mute)}
.tl-row{display:grid;grid-template-columns:minmax(0,.8fr) minmax(0,1.25fr) minmax(0,1.35fr);gap:6px 20px;padding:12px 10px;border-top:1px solid var(--line-2);align-items:start;border-radius:0}
.tl-row.head{border-top:0;padding-top:2px;padding-bottom:6px}
.tl-row.head span{font:500 .7rem var(--font-mono);letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.tl-row.cur{background:var(--accent-soft);border-top-color:transparent;border-radius:10px}
.tl-step{display:flex;gap:10px;align-items:flex-start;font-weight:600;font-size:.95rem}
.tl-n{font:500 .74rem var(--font-mono);width:22px;height:22px;border-radius:50%;display:grid;place-items:center;background:var(--surface-3);flex:none}
.tl-row.cur .tl-n{background:var(--viz-now);color:var(--viz-now-ink)}
.tl-then{font-size:.88rem;color:var(--muted)}
.tl-now{font-size:.88rem;display:flex;flex-direction:column;gap:4px;align-items:flex-start}
@media (max-width:760px){
  .tl-row{grid-template-columns:minmax(0,1fr)}
  .tl-row.head{display:none}
  .tl-then::before{content:"2007–09: ";font-weight:600;color:var(--ink)}
}
.cr-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--gap)}
@media (max-width:900px){.cr-grid{grid-template-columns:minmax(0,1fr)}}
.cr{display:flex;flex-direction:column;gap:12px}
.cr-top{display:flex;justify-content:space-between;align-items:flex-start;gap:10px}
.cr-like{background:var(--accent-soft);border-radius:10px;padding:10px 12px;font-size:.88rem}
.cr-like b{color:var(--accent)}
.cr-stats{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}
.cr-stat{background:var(--surface-2);border-radius:8px;padding:9px 11px;display:grid;gap:1px}
.cr-stat b{font:600 1.2rem/1.15 var(--font-body)}
.cr-stat span{font-size:.76rem;color:var(--muted);line-height:1.3}
.cr-diff{font-size:.84rem;color:var(--muted)}
.hbars{display:grid;gap:6px}
.hb{display:grid;grid-template-columns:70px minmax(0,1fr) 54px;grid-template-areas:"l t v" ". s s";gap:2px 10px;align-items:center;padding:4px 6px;margin:0 -6px;border-radius:8px;cursor:help;outline:none}
.hb:hover,.hb:focus-visible{background:var(--surface-2)}
.hb:focus-visible{box-shadow:0 0 0 2px var(--accent)}
.hb-l{grid-area:l;font:500 .8rem var(--font-mono);color:var(--muted)}
.hb.now .hb-l{color:var(--ink);font-weight:600}
.hb-t{grid-area:t;position:relative;height:16px;border-left:1px solid var(--line)}
.hb-t i{display:block;height:100%;background:var(--viz-mute);border-radius:0 4px 4px 0;min-width:3px}
.hb.now .hb-t i{background:var(--viz-now)}
.hb-v{grid-area:v;font:600 .9rem var(--font-body);text-align:right}
.hb-s{grid-area:s;font-size:.74rem;color:var(--muted)}
.hb-t .med{position:absolute;top:-6px;bottom:-6px;width:0;border-left:1px solid var(--muted);opacity:.55}
.hb-medlab{display:grid;grid-template-columns:70px minmax(0,1fr) 54px;gap:0 10px;font-size:.72rem;color:var(--muted);margin-bottom:-2px}
.hb-medlab span{position:relative;height:14px}
.hb-medlab em{position:absolute;transform:translateX(-50%);font-style:normal;white-space:nowrap}
.cmp table{min-width:780px}
.cmp th,.cmp td{font-size:.86rem}
.cmp td:first-child,.cmp th:first-child{position:sticky;left:0;background:var(--surface);z-index:1;min-width:170px;font-weight:500}
.cmp th.nu,.cmp td.nu{background:var(--accent-soft);font-weight:600}
.tp{display:grid;grid-template-columns:12px minmax(0,1fr) auto;gap:4px 12px;padding:12px 0;border-top:1px solid var(--line-2);align-items:start}
.tp:first-child{border-top:0}
.tp .dot{margin-top:6px}
.tp p{grid-column:2/-1;font-size:.84rem;color:var(--muted)}
.tp-r{display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:flex-end}
.c4{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:var(--gap)}
@media (max-width:1100px){.c4{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width:640px){.c4{grid-template-columns:minmax(0,1fr)}}
.c4 .box{display:flex;flex-direction:column;gap:10px;border-top:4px solid var(--c4,var(--line))}
.c4 .lv-rood{--c4:var(--bad)} .c4 .lv-oranje{--c4:var(--warn)} .c4 .lv-groen{--c4:var(--good)}
.c4-kv{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 10px;font-size:.84rem}
.c4-kv span{color:var(--muted)} .c4-kv b{font:500 .86rem var(--font-mono);text-align:right}
.c4 .vs{font-size:.82rem;background:var(--surface-2);border-radius:8px;padding:8px 10px;display:grid;gap:3px}
.kort{background:var(--accent-soft);border-radius:12px;padding:14px 16px;font-size:.98rem;line-height:1.5}
.kort b{color:var(--accent)}
.lc{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--gap)}
@media (max-width:900px){.lc{grid-template-columns:minmax(0,1fr)}}
.lc .box{display:flex;flex-direction:column;gap:10px}
.segs{display:flex;gap:3px}
.segs span{flex:1 1 0;min-width:0;background:var(--surface-3);color:var(--muted);font:500 .7rem/1.2 var(--font-body);text-align:center;padding:6px 2px;border-radius:5px;overflow-wrap:normal;hyphens:auto}
.segs span.on{background:var(--viz-now);color:var(--viz-now-ink);font-weight:700}
.segs span.past{background:color-mix(in srgb,var(--viz-mute) 35%,var(--surface-3))}
.hold{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px}
.hold article{background:var(--surface-2);border-radius:10px;padding:12px 14px;display:flex;flex-direction:column;gap:6px;font-size:.86rem}
.hold h3{font-size:1rem}
.hold .lbl{font:500 .68rem var(--font-mono);letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.hold .rule{border-top:1px solid var(--line);padding-top:6px;font-weight:500}
.wl td,.wl th{font-size:.86rem}
@media (max-width:640px){.wl td:first-child,.wl th:first-child{display:none}.wl td:last-child{min-width:130px}}
.you{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px}
@media (max-width:1100px){.you{grid-template-columns:repeat(3,minmax(0,1fr))}}
@media (max-width:760px){.you{grid-template-columns:repeat(2,minmax(0,1fr))}.you div:last-child:nth-child(odd){grid-column:1/-1}}
@media (max-width:480px){.you{grid-template-columns:minmax(0,1fr)}}
.you div{background:var(--surface-2);border-radius:10px;padding:12px 14px;font-size:.88rem}
.you b{display:block;margin-bottom:3px}
#tip{position:fixed;z-index:40;max-width:300px;background:var(--band);color:var(--band-ink);font:400 .82rem/1.45 var(--font-body);padding:9px 12px;border-radius:9px;pointer-events:none;white-space:pre-line;box-shadow:0 8px 28px rgba(0,0,0,.22)}

/* ---------- post ---------- */
.po-stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}
@media (max-width:760px){.po-stats{grid-template-columns:repeat(2,minmax(0,1fr))}}
.po-stat{background:var(--surface-2);border-radius:10px;padding:12px 14px;display:grid;gap:2px}
.po-stat b{font:600 1.5rem/1.1 var(--font-body)} .po-stat span{font-size:.8rem;color:var(--muted)}
.po-filters{display:flex;gap:10px;flex-wrap:wrap;align-items:end}
.po-filters > div{flex:1 1 160px}
.po-doc{padding:14px 0;border-top:1px solid var(--line-2);display:grid;gap:6px}
.po-doc:first-child{border-top:0}
.po-h{display:flex;gap:6px 10px;align-items:center;flex-wrap:wrap}
.po-meta{font-size:.8rem;color:var(--muted)}
.po-amts{display:flex;gap:6px;flex-wrap:wrap}
.po-amt{font:500 .8rem var(--font-mono);background:var(--surface-2);border:1px solid var(--line);border-radius:6px;padding:2px 8px}
.po-dates{margin:0;padding-left:18px;font-size:.84rem;color:var(--muted)}
.qt{display:grid;grid-template-columns:minmax(0,1fr) auto 86px 22px;gap:4px 10px;align-items:center;padding:8px 0;border-top:1px solid var(--line-2);font-size:.9rem}
.qt:first-child{border-top:0}
.qt .num{text-align:right;white-space:nowrap}
.qt .up{color:var(--good)} .qt .down{color:var(--bad)}
.ev{display:grid;grid-template-columns:auto minmax(0,1fr);gap:2px 10px;font-size:.82rem;padding:7px 0;border-top:1px solid var(--line-2)}
.ev:first-child{border-top:0}
.ev p{grid-column:1/-1;color:var(--muted);margin:0;overflow-wrap:anywhere}
.xbtn{appearance:none;border:0;background:none;color:var(--faint);cursor:pointer;font-size:1.1rem;line-height:1;padding:2px}
.xbtn:hover{color:var(--bad)}
.note{padding:10px 0;border-top:1px solid var(--line-2);display:grid;grid-template-columns:minmax(0,1fr) auto;gap:2px 8px}
.note:first-child{border-top:0}
.note p{grid-column:1/-1;white-space:pre-wrap;font-size:.88rem;margin:0}

/* ---------- uitleg ---------- */
.flow{display:flex;gap:8px;align-items:stretch;flex-wrap:wrap}
.flow .st{flex:1 1 150px;background:var(--surface-2);border:1px solid var(--line);border-radius:10px;padding:12px}
.flow .st b{display:block;font-family:var(--font-display);margin-bottom:2px}
.flow .ar{align-self:center;font-family:var(--font-mono);color:var(--accent)}
@media (max-width:640px){.flow .ar{display:none}}
.conn{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 12px;padding:10px 0;border-top:1px solid var(--line-2);align-items:center}
.conn:first-child{border-top:0}
.conn p{grid-column:1/-1;font-size:.82rem;color:var(--muted)}
pre.cmd{background:var(--band);color:var(--band-ink);font:400 .8rem/1.6 var(--font-mono);border-radius:8px;padding:12px 14px;overflow-x:auto;margin:0;white-space:pre}
code{font-family:var(--font-mono);font-size:.85em;background:var(--surface-2);border:1px solid var(--line);border-radius:4px;padding:1px 5px;word-break:break-word}
footer{color:var(--muted);font-size:.82rem;display:grid;gap:10px;padding-top:6px}
footer ul{margin:6px 0 0;padding-left:18px;columns:2 280px;column-gap:28px}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
</style>
</head><body>

<header class="top">
  <div class="wrap">
    <div class="brandrow">
      <div class="brand">Handelsplan <span>2027</span></div>
      <span class="live" id="live"><i></i><span id="liveText">laden…</span></span>
      <button class="connbtn" type="button" id="connBtn" hidden aria-expanded="false" aria-controls="connPanel"><i></i><span id="connText">Railway…</span><span class="cdots" id="connDots" aria-hidden="true"></span></button>
      <div class="ticker" id="ticker"></div>
      <button class="iconbtn" type="button" id="logoutBtn" hidden>Uitloggen</button>
    </div>
    <nav class="tabs" role="tablist" aria-label="Onderdelen">
      <button class="tab" role="tab" id="tb-markt" data-tab="markt">Markt</button>
      <button class="tab" role="tab" id="tb-cyclus" data-tab="cyclus">Cyclus</button>
      <button class="tab" role="tab" id="tb-plan" data-tab="plan">Plan</button>
      <button class="tab" role="tab" id="tb-signalen" data-tab="signalen">Signalen</button>
      <button class="tab" role="tab" id="tb-inbox" data-tab="inbox">Inbox<span class="count" id="inboxCount" hidden></span></button>
      <button class="tab" role="tab" id="tb-post" data-tab="post" hidden>Post</button>
      <button class="tab" role="tab" id="tb-historie" data-tab="historie">Historie</button>
      <button class="tab" role="tab" id="tb-uitleg" data-tab="uitleg">Uitleg</button>
    </nav>
  </div>
</header>

<main class="wrap">
  <section class="box connpanel" id="connPanel" hidden aria-label="Verbinding met Railway"></section>
  <div id="notice" hidden></div>
  <div id="pendingPanel" hidden></div>

  <!-- MARKT -->
  <section class="panel" id="p-markt" role="tabpanel" aria-labelledby="tb-markt">
    <div id="mk-hero"><div class="empty"><b>Marktstatus laden…</b><span>Je macro-overzicht, cijfers en signalen verschijnen zodra de opslag antwoordt.</span></div></div>
    <div id="mk-points"></div>
    <div id="mk-machine"></div>
    <div id="mk-lenses"></div>
    <div id="mk-ind"></div>
    <div id="mk-cal"></div>
  </section>

  <!-- CYCLUS -->
  <section class="panel" id="p-cyclus" role="tabpanel" aria-labelledby="tb-cyclus" hidden>
    <div id="cy-body" class="grid"><div class="empty"><b>Cyclus laden…</b><span>De cyclusgrafieken en de crashvergelijking verschijnen zodra de opslag antwoordt.</span></div></div>
  </section>

  <!-- PLAN -->
  <section class="panel" id="p-plan" role="tabpanel" aria-labelledby="tb-plan" hidden>
    <div id="pl-top"></div>
    <div id="pl-pos"></div>
    <div id="pl-sc"></div>
    <div id="pl-check"></div>
    <div class="box stack" id="askBox">
      <div class="sechead"><h2>Vraag het plan</h2><span class="muted small">Claude antwoordt met je plan, het marktbeeld en de laatste cijfers als context.</span></div>
      <form id="askForm" class="btnrow" autocomplete="off">
        <input id="askQ" placeholder="Bijv. Wat doe ik volgens mijn plan als goud deze week onder $4.000 sluit?" style="flex:1 1 280px" aria-label="Je vraag">
        <button class="btn primary" type="submit" id="askBtn" disabled>Vraag</button>
        <button class="btn" type="button" id="askStop" hidden>Stop</button>
      </form>
      <div id="askOut" class="answer" hidden></div>
      <span class="status" id="askStatus" role="status"></span>
    </div>
  </section>

  <!-- SIGNALEN -->
  <section class="panel" id="p-signalen" role="tabpanel" aria-labelledby="tb-signalen" hidden>
    <div id="sig-body" class="grid"></div>
  </section>

  <!-- INBOX -->
  <section class="panel" id="p-inbox" role="tabpanel" aria-labelledby="tb-inbox" hidden>
    <div class="grid g-2">
      <form class="box stack" id="inForm" autocomplete="off">
        <div class="sechead"><h2>Nieuw transcript of notitie</h2><span class="muted small" id="inWords"></span></div>
        <div class="frow">
          <div><label for="inSource">Bron</label>
            <select id="inSource">
              <option>TradersReality</option><option>Rebel Capitalist</option><option>Wolf of Washington</option>
              <option>Eigen video</option><option>Eigen notitie</option><option>Overig</option>
            </select></div>
          <div><label for="inDate">Datum video of notitie</label><input id="inDate" type="date"></div>
        </div>
        <div class="frow">
          <div><label for="inTitle">Titel</label><input id="inTitle" placeholder="Bijv. Weekly outlook: Fed, olie, goud"></div>
          <div><label for="inUrl">Link (optioneel)</label><input id="inUrl" type="url" placeholder="https://youtube.com/watch?v=…"></div>
        </div>
        <div><label for="inText">Transcript of tekst</label>
          <textarea id="inText" placeholder="Plak hier het transcript, je eigen aantekeningen of een Wolf of Washington-melding (ticker, politicus, transactiedatum, meldingsdatum, bedrag)."></textarea></div>
        <div class="btnrow">
          <button class="btn primary" type="submit" id="inAnalyze">Analyseer en stel wijzigingen voor</button>
          <button class="btn" type="button" id="inSave">Alleen bewaren</button>
          <button class="btn" type="button" id="inStop" hidden>Stop</button>
          <span class="status" id="inStatus" role="status"></span>
        </div>
      </form>
      <div class="box stack">
        <h3>Wat er gebeurt</h3>
        <ul class="actions">
          <li><span>Claude leest het transcript naast je plan, het marktbeeld en de laatste cijfers.</span></li>
          <li><span>Feiten, meningen en voorspellingen worden gescheiden; claims gaan het claimregister in.</span></li>
          <li><span>Is de bron TradersReality of Rebel Capitalist, dan wordt hun <b>bril</b> op de Markt-pagina bijgewerkt met hún visie.</span></li>
          <li><span>Je krijgt voorstellen voor scenario's, posities, triggers, kalender en marktbeeld. Jij vinkt aan wat je overneemt; alles is terug te draaien.</span></li>
        </ul>
        <p class="muted small">Een analyse duurt meestal 30–90 seconden.</p>
      </div>
    </div>
    <div class="box">
      <div class="sechead"><h2>Inbox</h2><span class="muted small" id="inboxMeta"></span></div>
      <div id="inboxList"></div>
    </div>
  </section>

  <!-- HISTORIE -->
  <!-- POST: verwerkte e-mails en documenten -->
  <section class="panel" id="p-post" role="tabpanel" aria-labelledby="tb-post" hidden>
    <div id="po-body"><div class="empty"><b>Post laden…</b></div></div>
  </section>

  <section class="panel" id="p-historie" role="tabpanel" aria-labelledby="tb-historie" hidden>
    <div class="sechead"><h2>Historie</h2><span class="muted small">Elke planwijziging, met reden. Terugzetten kan per stap.</span></div>
    <div class="box" id="hist-body"></div>
  </section>

  <!-- UITLEG -->
  <section class="panel" id="p-uitleg" role="tabpanel" aria-labelledby="tb-uitleg" hidden>
    <div id="ux-body" class="grid"></div>
  </section>

  <footer id="footer"></footer>
</main>

<script>
(() => {
"use strict";
/* ================= constants ================= */
const POS_IDS = ["miners","crcl","mag7","insider"];
const POS_SHORT = {miners:"Mijnen", crcl:"Circle", mag7:"Mag 7", insider:"Insider"};
const STANCES = {opbouwen:{label:"Opbouwen",tone:"t-good"}, aanhouden:{label:"Aanhouden",tone:"t-neutral"}, voorzichtig:{label:"Voorzichtig",tone:"t-warn"}, afbouwen:{label:"Afbouwen",tone:"t-bad"}};
const LV = {rustig:{tone:"t-good",label:"Rustig",rank:0}, gespannen:{tone:"t-warn",label:"Gespannen",rank:1}, stress:{tone:"t-bad",label:"Stress",rank:2}, info:{tone:"t-neutral",label:"Info",rank:-1}};
const RISK = {"risk-on":{tone:"t-good",label:"Risk-on"}, neutraal:{tone:"t-neutral",label:"Neutraal"}, defensief:{tone:"t-warn",label:"Defensief"}, "risk-off":{tone:"t-bad",label:"Risk-off"}};
const PILLAR_ORDER = ["inflatie","groei","rente","liquiditeit","dollar","krediet","sentiment","posities"];
const PILLAR_NAME = {inflatie:"Inflatie & energie", groei:"Groei & werk", rente:"Rente & obligaties", liquiditeit:"Liquiditeit", dollar:"Dollar & yen", krediet:"Krediet", sentiment:"Sentiment & AI", posities:"Jouw posities"};
const STAGES = [{n:1,title:"Oorzaken",sub:"Wat zet de toon?"},{n:2,title:"Prijs van geld",sub:"Rente en liquiditeit"},{n:3,title:"Doorgifte",sub:"Dollar, krediet en sentiment"},{n:4,title:"Jouw posities",sub:"Wat het voor jou betekent"}];
const SC_COLORS = {s1:"var(--sc1)", s2:"var(--sc2)", s3:"var(--sc3)", s4:"var(--sc4)"};
const IMPACT = {"-2":["im2","↓↓"],"-1":["im1","↓"],"0":["i0","→"],"1":["i1","↑"],"2":["i2","↑↑"]};
const TABS = ["markt","cyclus","plan","signalen","inbox","post","historie","uitleg"];
const SIGNED = new Set(["nfp3m","netLiqChg","kospiDay","curve"]);
const LENS_SOURCE = {tr:"TradersReality", rebel:"Rebel Capitalist"};
const SOURCE_LENS = {"TradersReality":"tr", "Rebel Capitalist":"rebel"};
const MAX_TEXT = 180000;
const HIDE_CODES = ["not_granted","sampling_disabled","not_declared","capability_disabled","capability_removed"];

const S = {plan:null, planLoaded:false, market:null, series:{}, levels:null, inbox:[], history:[], db:null, sample:null, downloads:null, server:null, srvStatus:null,
  canWrite:true, offline:false, pending:null, anaCtl:null, askCtl:null, histConfirm:null, sel:null, tab:"markt"};

/* ================= helpers ================= */
const $ = (id) => document.getElementById(id);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const nf = (v, d=0) => (typeof v === "number" && isFinite(v)) ? new Intl.NumberFormat("nl-NL",{minimumFractionDigits:d,maximumFractionDigits:d}).format(v) : "–";
const clone = (o) => JSON.parse(JSON.stringify(o));
const arr = v => Array.isArray(v) ? v : [];
const clamp = (v,a,b) => Math.max(a, Math.min(b, v));
const todayISO = () => { const d = new Date(); return new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,10); };
function fmtDate(iso, opts={day:"numeric",month:"short"}){ if(!iso) return ""; const d=new Date(iso.length===10? iso+"T12:00:00" : iso); return isNaN(d)? String(iso) : new Intl.DateTimeFormat("nl-NL",opts).format(d); }
function fmtDT(iso){ if(!iso) return ""; const d=new Date(iso); return isNaN(d)? "" : new Intl.DateTimeFormat("nl-NL",{day:"numeric",month:"short",hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"}).format(d); }
function daysFrom(iso){ const a=new Date(todayISO()+"T12:00:00"), b=new Date(iso+"T12:00:00"); return Math.round((b-a)/864e5); }
function ago(iso){ const h=(Date.now()-new Date(iso).getTime())/36e5; if(!isFinite(h)) return ""; if(h<1) return Math.max(1,Math.round(h*60))+" min geleden"; if(h<36) return Math.round(h)+" uur geleden"; return Math.round(h/24)+" dagen geleden"; }
function setStatus(el, msg, err=false){ if(!el) return; el.textContent = msg||""; el.classList.toggle("err", !!err); }
function lvPill(lv, extra=""){ const L=LV[lv]; return L? `<span class="pill ${L.tone}"${extra}>${L.label}</span>` : ""; }
function stancePill(s){ const st=STANCES[s]||STANCES.aanhouden; return `<span class="pill ${st.tone}">${st.label}</span>`; }
function dirMark(d){ const v=Math.round(+d||0); return v>0? `<span class="dir pos" aria-label="positief">${v>1?"↑↑":"↑"}</span>` : v<0? `<span class="dir neg" aria-label="negatief">${v<-1?"↓↓":"↓"}</span>` : `<span class="dir flat" aria-label="neutraal">→</span>`; }
function impactCell(v){ const k=IMPACT[String(clamp(Math.round(v||0),-2,2))]; return `<span class="cell ${k[0]}">${k[1]}</span>`; }
function posName(id){ return S.plan?.positions?.find(x=>x.id===id)?.name || POS_SHORT[id] || id; }
function chipsFor(ids){ return arr(ids).map(id=>`<span class="chip">${esc(POS_SHORT[id]||id)}</span>`).join(""); }

/* market items */
function item(key){ return S.market?.items?.find(i=>i.key===key); }
function itemText(it){
  if(!it) return "–";
  if(it.display) return it.display;
  if(typeof it.value!=="number") return "–";
  const sign = it.value<0 ? "−" : (SIGNED.has(it.key) && it.value>0 ? "+" : "");
  return sign + (it.prefix||"") + nf(Math.abs(it.value), it.decimals ?? 2) + (it.suffix||"");
}

/* triggers */
function trigValue(t){
  if(t.computed==="gold/wti"){ const g=item("gold"), w=item("wti"); return (g&&w&&w.value)? {v:g.value/w.value, asOf:"goud ÷ WTI"} : {v:null}; }
  const m = t.marketKey ? item(t.marketKey) : null;
  if(m && typeof m.value==="number") return {v:m.value, asOf:m.asOf};
  return {v: typeof t.current==="number"? t.current : null, asOf:t.asOf};
}
function trigLevel(t, v){
  if(v==null) return null;
  if(t.dir==="up") return v>=t.danger? "stress" : v>=t.warn? "gespannen" : "rustig";
  return v<=t.danger? "stress" : v<=t.warn? "gespannen" : "rustig";
}
function fmtTrig(t, v){
  if(v==null) return "–";
  const u=t.unit||"";
  if(u==="$") return "$"+nf(v, Math.abs(v)>=1000?0:2);
  if(u==="k") return nf(v,0)+"k";
  if(u==="Δk") return (v>0?"+":"")+nf(v,0)+"k";
  if(u==="Δ$mld") return (v>0?"+":"−")+"$"+nf(Math.abs(v),0)+" mld";
  if(u==="×") return nf(v,1)+"×";
  if(u==="%") return nf(v, Number.isInteger(v)?0:(Math.abs(v)>=10?1:2))+"%";
  return nf(v, Math.abs(v)>=1000?0:2)+u;
}
function pillarLevel(p){
  const ts = arr(S.plan?.triggers).filter(t=>t.pillar===p.id);
  let worst=null, n=0;
  ts.forEach(t=>{ const {v}=trigValue(t); const l=trigLevel(t,v); if(l){ n++; if(!worst || LV[l].rank>LV[worst].rank) worst=l; } });
  return worst ? {lv:worst, auto:true, n} : {lv:p.status||"info", auto:false, n:0};
}

/* sparkline */
function spark(key, w=72, h=22){
  const s = arr(S.series?.[key]).slice(-90).map(p=>+p[1]).filter(isFinite);
  if(s.length<5) return "";
  const mn=Math.min(...s), mx=Math.max(...s), rg=(mx-mn)||1;
  const X=i=> (i/(s.length-1))*(w-4)+2, Y=v=> h-2-((v-mn)/rg)*(h-5);
  const line = s.map((v,i)=>(i?"L":"M")+X(i).toFixed(1)+" "+Y(v).toFixed(1)).join(" ");
  const area = line+` L${X(s.length-1).toFixed(1)} ${h} L${X(0).toFixed(1)} ${h} Z`;
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" aria-hidden="true"><path class="sp-a" d="${area}"/><path class="sp-l" d="${line}"/><circle class="sp-d" cx="${X(s.length-1).toFixed(1)}" cy="${Y(s[s.length-1]).toFixed(1)}" r="2.4"/></svg>`;
}

/* ================= tabs & global events ================= */
function showTab(name){
  if(!TABS.includes(name)) name="markt";
  S.tab=name;
  TABS.forEach(t=>{ $("p-"+t).hidden = t!==name; $("tb-"+t).setAttribute("aria-selected", String(t===name)); });
  if(name==="post" && typeof loadPost==="function") loadPost();
  try{ localStorage.setItem("hp-tab2", name); }catch(e){}
}
let startTab=(location.hash||"").replace("#","");
if(!TABS.includes(startTab)){ try{ startTab=localStorage.getItem("hp-tab2")||"markt"; }catch(e){ startTab="markt"; } }
showTab(startTab);

document.addEventListener("click", (ev)=>{
  const t = ev.target.closest("[data-tab],[data-goto],[data-pillar],[data-act],[data-ana],[data-undo]");
  if(!t) return;
  if(t.dataset.tab || t.dataset.goto){ showTab(t.dataset.tab||t.dataset.goto); window.scrollTo({top:0}); return; }
  if(t.dataset.pillar){ S.sel = S.sel===t.dataset.pillar? null : t.dataset.pillar; renderMachine(); return; }
  if(t.dataset.ana){ const it=S.inbox.find(x=>x.id===t.dataset.ana); if(it) runAnalysis(it.id,{source:it.source,title:it.title,url:it.url,date:it.date}, it.text); return; }
  if(t.dataset.undo){ undo(t.dataset.undo); return; }
  const a=t.dataset.act;
  if(a==="paste"){ $("inSource").value=t.dataset.source||"Overig"; showTab("inbox"); window.scrollTo({top:0}); $("inText").focus(); }
  if(a==="refresh-macro") refreshMacro();
  if(a==="export") exportMd();
  if(a==="apply") applyPending();
  if(a==="dismiss") dismissPending();
  if(a==="logout") S.server?.logout();
});
document.addEventListener("keydown", (ev)=>{
  const t=ev.target.closest?.("[data-pillar]");
  if(t && (ev.key==="Enter"||ev.key===" ")){ ev.preventDefault(); t.click(); }
});
$("logoutBtn").addEventListener("click", ()=>S.server?.logout());

/* ================= header ================= */
function renderHeader(){
  const m=S.market, live=$("live");
  if(m?.updatedAt){
    const h=(Date.now()-new Date(m.updatedAt).getTime())/36e5;
    const auto=/Server|Automatisch/.test(m.updatedBy||"");
    live.className = "live " + (auto && h<3 ? "on" : "old");
    $("liveText").textContent = (auto && h<3 ? "Live · " : "Cijfers ") + ago(m.updatedAt);
  } else { live.className="live"; $("liveText").textContent = S.offline? "geen opslag" : "laden…"; }
  const keys=[["realYield10","Reële rente"],["us10y","10j"],["gold","Goud"],["brent","Brent"],["crcl","CRCL"]];
  $("ticker").innerHTML = keys.map(([k,l])=>{ const it=item(k); return it&&typeof it.value==="number"? `<span>${l} <b>${esc(itemText(it))}</b></span>` : ""; }).join("");
}

/* ================= MARKT ================= */
function compassSVG(c){
  const W=360, pad=26, r=(W-2*pad)/2, cx=W/2, cy=W/2;
  const g=clamp(+c.growth||0,-1,1), inf=clamp(+c.inflation||0,-1,1);
  const x=cx+g*r*.86, y=cy-inf*r*.86;
  const hd=c.heading||{}; const hx=x+clamp(+hd.growth||0,-1,1)*r*.86, hy=y-clamp(+hd.inflation||0,-1,1)*r*.86;
  const hasHead = Math.hypot(hx-x,hy-y)>8;
  const ang = Math.atan2(hy-y,hx-x);
  const ah = hasHead? `<path class="c-arrow" d="M${hx.toFixed(1)} ${hy.toFixed(1)} l${(-9*Math.cos(ang-0.45)).toFixed(1)} ${(-9*Math.sin(ang-0.45)).toFixed(1)} l${(9*Math.cos(ang-0.45)-9*Math.cos(ang+0.45)).toFixed(1)} ${(9*Math.sin(ang-0.45)-9*Math.sin(ang+0.45)).toFixed(1)} Z"/>` : "";
  const q=(cls,qx,qy,anchor,name,l1,l2)=>{
    const tx = anchor==="start"? qx+12 : qx-12;
    return `<text class="c-qn" x="${tx}" y="${qy}" text-anchor="${anchor}">${name}</text><text class="c-qa" x="${tx}" y="${qy+15}" text-anchor="${anchor}">${l1}</text><text class="c-qa" x="${tx}" y="${qy+28}" text-anchor="${anchor}">${l2}</text>`;
  };
  return `<svg viewBox="0 0 ${W} ${W+22}" role="img" aria-label="Regimekompas: groei ${g<0?"zwak":"sterk"}, inflatie ${inf>0?"stijgend":"dalend"}">
    <rect class="cq-stag" x="${pad}" y="${pad}" width="${r}" height="${r}" rx="10"/>
    <rect class="cq-refl" x="${cx}" y="${pad}" width="${r}" height="${r}" rx="10"/>
    <rect class="cq-krimp" x="${pad}" y="${cy}" width="${r}" height="${r}" rx="10"/>
    <rect class="cq-gold" x="${cx}" y="${cy}" width="${r}" height="${r}" rx="10"/>
    <line class="c-axis" x1="${pad}" y1="${cy}" x2="${W-pad}" y2="${cy}"/><line class="c-axis" x1="${cx}" y1="${pad}" x2="${cx}" y2="${W-pad}"/>
    ${q("",pad,pad+24,"start","Stagflatie","goud, energie, cash","aandelen vaak zwak")}
    ${q("",W-pad,pad+24,"end","Reflatie","grondstoffen, value","small caps, cyclisch")}
    ${q("",pad,W-pad-40,"start","Krimp","staatsobligaties","dollar; goud na Fed")}
    ${q("",W-pad,W-pad-40,"end","Goldilocks","tech en groei","brede aandelenmarkt")}
    <text class="c-ax" x="${cx}" y="${pad-9}" text-anchor="middle">INFLATIE ↑</text>
    <text class="c-ax" x="${cx}" y="${W-pad+16}" text-anchor="middle">INFLATIE ↓</text>
    <text class="c-ax" x="${pad}" y="${W+16}" text-anchor="start">← GROEI ZWAKT</text>
    <text class="c-ax" x="${W-pad}" y="${W+16}" text-anchor="end">GROEI STERK →</text>
    ${hasHead? `<line class="c-head" x1="${x.toFixed(1)}" y1="${y.toFixed(1)}" x2="${hx.toFixed(1)}" y2="${hy.toFixed(1)}"/>${ah}` : ""}
    <circle class="c-halo" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="15"/>
    <circle class="c-dot" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="7"/>
    <text class="c-now" x="${(x+12).toFixed(1)}" y="${(y-11).toFixed(1)}">NU</text>
  </svg>`;
}

function renderMarkt(){
  const p=S.plan, m=p?.macro;
  if(!p){
    $("mk-hero").innerHTML = S.offline
      ? `<div class="empty"><b>Opslag niet bereikbaar in deze weergave</b><span>Open je plan via plan.vsonsbeek.nl of in de Claude-app.</span></div>`
      : S.planLoaded ? `<div class="empty"><b>Nog geen plan opgeslagen</b><span>Plak een transcript in de Inbox om te beginnen.</span></div>`
      : `<div class="empty"><b>Marktstatus laden…</b><span>Je macro-overzicht, cijfers en signalen verschijnen zodra de opslag antwoordt.</span></div>`;
    ["mk-points","mk-machine","mk-lenses","mk-ind","mk-cal"].forEach(id=>$(id).innerHTML="");
    return;
  }
  if(!m){
    $("mk-hero").innerHTML = `<div class="empty"><b>Het macro-overzicht ontbreekt nog in je plan</b><span>Werk je site bij (zie Uitleg); daarna verschijnt het hier vanzelf.</span></div>`;
  } else {
    const rk=RISK[m.riskMode]||RISK.neutraal;
    $("mk-hero").innerHTML = `<div class="hero">
      <div>
        <span class="eyebrow">Marktstatus · ${esc(fmtDT(m.updatedAt))}</span>
        <div class="pills"><span class="pill ${rk.tone}">${rk.label}</span>${m.regime? `<span class="pill t-accent plain">Regime: ${esc(m.regime)}</span>`:""}</div>
        <h1>${esc(m.headline||"")}</h1>
        <p class="lede">${esc(m.summary||"")}</p>
        <div class="btnrow">
          ${m.cycle? `<button class="btn primary" type="button" data-goto="cyclus">Waar staan we in de cyclus?</button>`:""}
          <button class="btn" type="button" data-act="refresh-macro" id="refreshBtn" ${S.sample?"":"disabled"}>Marktstatus bijwerken met Claude</button>
          <span class="status" id="refreshStatus" role="status">${S.sample? "Herschrijft dit overzicht op basis van de cijfers hieronder; jij keurt goed." : ""}</span>
        </div>
        <p class="faint small" style="margin-top:10px">${esc(m.source||"")}</p>
      </div>
      <figure class="compass">${compassSVG(m.compass||{})}<figcaption>${esc(m.compass?.why||"")}</figcaption></figure>
    </div>`;
  }

  $("mk-points").innerHTML = arr(m?.keyPoints).length ? `<div class="box">
    <div class="sechead" style="margin-bottom:6px"><h2>Wat nu het verschil maakt</h2><span class="muted small">De kern van het marktbeeld in zes punten</span></div>
    <div class="points">${arr(m.keyPoints).slice(0,6).map(k=>`<div class="pt"><span class="dot ${esc(k.tone)}"></span><b>${esc(k.title)}</b><p>${esc(k.text)}</p></div>`).join("")}</div></div>` : "";

  renderMachine();
  renderLenses();
  renderIndicators();
  renderMiniCal();
}

function renderMachine(){
  const p=S.plan, m=p?.macro; const el=$("mk-machine");
  if(!m){ el.innerHTML=""; return; }
  const pillars=arr(m.pillars);
  const sel = pillars.find(x=>x.id===S.sel);
  const effects = sel?.effects||{};
  const stageHTML = (st)=>{
    if(st.n===4){
      return arr(p.positions).map(x=>{
        const pi=m.positionImpact?.[x.id]||{};
        const e = sel? (effects[x.id]||0) : null;
        const cls = sel? (e? "hit "+(e>0?"pos":"neg") : "") : "";
        return `<div class="pc ${cls}"><span class="nm">${esc(POS_SHORT[x.id]||x.name)}</span><span class="eff">${sel? (e? dirMark(e) : `<span class="dir flat">·</span>`) : dirMark(pi.dir)}${stancePill(x.stance)}</span>
          <span class="why">${sel? (e? (e>0? "Profiteert van ":"Last van ")+esc(sel.name.toLowerCase()) : "Weinig effect") : esc(pi.why||"")}</span></div>`;
      }).join("");
    }
    return pillars.filter(x=>x.stage===st.n).map(x=>{
      const pl=pillarLevel(x);
      const vals = arr(x.keys).map(k=>{ const it=item(k); if(!it || (typeof it.value!=="number" && !it.display)) return ""; return `<div class="kv"><span>${esc(it.label)}</span><i class="sk">${spark(k,54,16)}</i><b>${esc(itemText(it))}</b></div>`; }).join("");
      return `<article class="pl ${S.sel===x.id?"sel":""}" data-pillar="${esc(x.id)}" tabindex="0" role="button" aria-pressed="${S.sel===x.id}">
        <div class="pl-top"><div><div class="pl-name">${esc(x.name)}</div><div class="pl-q">${esc(x.q||"")}</div></div>${lvPill(pl.lv, pl.auto? ` title="Automatisch op basis van ${pl.n} signalen"`:"")}</div>
        ${vals? `<div class="stack" style="gap:4px">${vals}</div>`:""}
        <p class="pl-read">${esc(x.reading||"")}</p>
      </article>`;
    }).join("");
  };
  const note = sel ? `Je bekijkt <b>${esc(sel.name)}</b>: groen omrande posities profiteren, rood omrande hebben er last van. Klik nogmaals om te sluiten.` : `Klik op een blok om te zien welke van je posities erdoor geraakt worden.`;
  el.innerHTML = `<div class="box stack">
    <div class="sechead"><h2>Hoe het in elkaar zit</h2><span class="muted small">Van oorzaak naar jouw portefeuille · status volgt automatisch uit je signalen</span></div>
    <p class="selnote">${note}</p>
    <div class="machine ${sel?"focus":""}">${STAGES.map(st=>`<div class="stage"><div class="stage-h"><span class="stage-n">${st.n}</span><div><b>${st.title}</b><small>${st.sub}</small></div></div><div class="stage-body">${stageHTML(st)}</div></div>`).join("")}</div>
  </div>`;
}

function lensCheckValue(c){ if(!c.key) return ""; const it=item(c.key); return it&&(typeof it.value==="number"||it.display)? `<span class="val">${esc(itemText(it))}</span>` : ""; }
function rangePos(r){
  if(r.prevWkHigh==null || r.prevWkLow==null) return {t:"–", cls:""};
  if(r.last>r.prevWkHigh) return {t:"Boven vorige-week hoog", cls:"op"};
  if(r.last<r.prevWkLow) return {t:"Onder vorige-week laag", cls:"neer"};
  const pct=(r.last-r.prevWkLow)/((r.prevWkHigh-r.prevWkLow)||1)*100;
  return {t:`In de range (${nf(pct,0)}%)`, cls:"range"};
}
function renderLevels(){
  const L=S.levels;
  const head = `<div class="sechead"><div><span class="eyebrow">Niveaubord · in de stijl van TradersReality</span><h3 style="margin-top:3px">Trend en liquiditeitszones per markt</h3></div><span class="muted small">${L?.updatedAt? "Berekend "+esc(fmtDT(L.updatedAt))+" uit daggrafieken" : ""}</span></div>`;
  if(!L?.rows?.length) return `<div class="box stack">${head}<div class="empty small"><b>Nog geen niveaus berekend</b><span>Trend (50- en 200-daags gemiddelde), het hoog en laag van vorige week en de gemiddelde dagbeweging worden elke handelsdag na slot berekend zodra Twelve Data en FRED gekoppeld zijn.</span></div></div>`;
  const f=(r,v)=> v==null? "–" : (r.prefix||"")+nf(v, r.decimals)+(r.suffix||"");
  return `<div class="box stack">${head}
  <p class="secintro">Rond het hoog en laag van vorige week liggen vaak stops: daar zit liquiditeit waar grote partijen op mikken. Breekt de prijs zo'n niveau, kijk dan of het een echte uitbraak is of een stop-run die terugvalt.</p>
  <div class="lvl"><table><thead><tr><th>Markt</th><th class="r">Slot</th><th>Trend</th><th class="r">50-daags</th><th class="r">200-daags</th><th class="r">Vorige week hoog</th><th class="r">Vorige week laag</th><th>Positie</th><th class="r">Gem. dagbeweging</th></tr></thead><tbody>
  ${L.rows.map(r=>{ const rp=rangePos(r); return `<tr><td style="white-space:nowrap"><b style="font-weight:600">${esc(r.label)}</b><div class="faint small">${esc(r.asOf)} · ${esc(r.src)}</div></td><td class="r"><span class="num">${f(r,r.last)}</span></td>
    <td style="white-space:nowrap"><span class="trend ${esc(r.trend)}">${r.trend==="op"?"▲ op":r.trend==="neer"?"▼ neer":"◆ gemengd"}</span></td>
    <td class="r"><span class="num">${f(r,r.ema50)}</span></td><td class="r"><span class="num">${f(r,r.ema200)}</span></td>
    <td class="r"><span class="num">${f(r,r.prevWkHigh)}</span></td><td class="r"><span class="num">${f(r,r.prevWkLow)}</span></td>
    <td style="white-space:nowrap"><span class="trend ${rp.cls}" style="font-weight:500">${esc(rp.t)}</span></td>
    <td class="r"><span class="num">${f(r,r.adr)}</span> <span class="num faint">${r.adrPct!=null? "("+nf(r.adrPct,1)+"%)":""}</span></td></tr>`; }).join("")}
  </tbody></table></div>
  <p class="faint small">Trend: ▲ slot boven het 50-daags en 50 boven 200 · ▼ omgekeerd · ◆ gemengd. Gem. dagbeweging = gemiddelde afstand tussen dag-hoog en -laag over 14 dagen (bij FRED-reeksen: slot tot slot).</p></div>`;
}
function renderLenses(){
  const m=S.plan?.macro; const el=$("mk-lenses");
  if(!arr(m?.lenses).length){ el.innerHTML=""; return; }
  el.innerHTML = `<div class="stack">
    <div class="sechead"><h2>Twee brillen op dezelfde markt</h2><span class="muted small">Plak een transcript van de bron en hun bril wordt bijgewerkt met hún visie</span></div>
    <div class="lenses">${m.lenses.map(l=>`<article class="box lens">
      <div><span class="eyebrow">Bril</span><h2 style="margin-top:4px">${esc(l.name)}</h2><p class="lens-who">Zoals <b>${esc(l.who)}</b> ernaar kijkt</p></div>
      <p class="lens-method">${esc(l.method||"")}</p>
      <p class="lens-q">${esc(l.question||"")}</p>
      <div>${arr(l.checks).map(c=>`<div class="ck"><span class="dot ${esc(c.status||"info")}"></span><b>${esc(c.q)}</b>${lensCheckValue(c)}<p>${esc(c.auto==="levels" && levelsSummary()? levelsSummary() : (c.answer||""))}</p></div>`).join("")}</div>
      <div class="take"><span class="eyebrow">Conclusie van deze bril</span><p>${esc(l.take||"")}</p></div>
      <div class="sechead"><span class="basis">${esc(l.basis||"")} · ${esc(fmtDT(l.updatedAt))}</span>
        <button class="btn sm" type="button" data-act="paste" data-source="${esc(LENS_SOURCE[l.id]||"Overig")}">Plak een ${esc(LENS_SOURCE[l.id]||"")}-transcript</button></div>
    </article>`).join("")}</div>
    ${renderLevels()}</div>`;
}
function levelsSummary(){
  const rows=arr(S.levels?.rows); if(!rows.length) return "";
  const by=t=>rows.filter(r=>r.trend===t).map(r=>r.label.replace(/ \(.*\)$/,""));
  const parts=[["Op",by("op")],["Neer",by("neer")],["Gemengd",by("gemengd")]].filter(x=>x[1].length).map(x=>`${x[0]}: ${x[1].join(", ")}`);
  return parts.join(" · ")+". Zie het niveaubord hieronder.";
}
function renderIndicators(){
  const items=arr(S.market?.items); const el=$("mk-ind");
  if(!items.length){ el.innerHTML=""; return; }
  const pillars=arr(S.plan?.macro?.pillars);
  const trigByKey={}; arr(S.plan?.triggers).forEach(t=>{ if(t.marketKey) trigByKey[t.marketKey]=t; });
  const groups = PILLAR_ORDER.map(pid=>({pid, rows: items.filter(i=>(i.pillar||"posities")===pid)})).filter(g=>g.rows.length);
  const m=S.market; const stale = m?.updatedAt ? (Date.now()-new Date(m.updatedAt).getTime())/36e5 > 36 : true;
  el.innerHTML = `<div class="box stack">
    <div class="sechead"><h2>Alle cijfers</h2><span class="small ${stale?"":"muted"}">${m?.updatedAt? (stale? `<span class="pill t-warn">Verouderd</span> `:"")+"Bijgewerkt "+esc(fmtDT(m.updatedAt))+" · "+esc(m.updatedBy||"") : ""}</span></div>
    <div class="ind">${groups.map(g=>{
      const pl=pillars.find(x=>x.id===g.pid); const lv = pl? pillarLevel(pl).lv : null;
      return `<div class="ind-g"><div class="ind-gh"><h3>${esc(PILLAR_NAME[g.pid]||g.pid)}</h3>${lv? lvPill(lv):""}</div>
      ${g.rows.map(it=>{ const t=trigByKey[it.key]; const l = t? trigLevel(t, typeof it.value==="number"? it.value : null) : null;
        return `<div class="ir"><span class="l">${esc(it.label)}</span><span class="s">${spark(it.key)}</span><span class="v ${l==="stress"?"bad":l==="gespannen"?"warn":""}">${esc(itemText(it))}</span><span class="c">${esc(it.change||"")}</span><span class="m">${esc(it.asOf||"")} · ${esc(it.src||"")}</span></div>`; }).join("")}
      </div>`; }).join("")}</div>
    <details id="mEdit"><summary class="muted small" style="cursor:pointer">Cijfers handmatig aanpassen (bijv. S&P 500, Kospi)</summary><div id="mEditBody" style="margin-top:10px"></div></details>
  </div>`;
  const det=$("mEdit"); det.open=!!S.mEditOpen; det.addEventListener("toggle",()=>{ S.mEditOpen=det.open; if(det.open) renderMarketEditor(); });
  if(det.open) renderMarketEditor();
}
function renderMiniCal(){
  const p=S.plan; const el=$("mk-cal");
  const up=arr(p?.calendar).filter(c=>daysFrom(c.date)>=0).sort((a,b)=>a.date.localeCompare(b.date)).slice(0,6);
  el.innerHTML = up.length? `<div class="box"><div class="sechead"><h2>Komende momenten</h2><span class="muted small">Tijden in Nederlandse tijd</span></div><ul class="cal" style="margin-top:6px">${up.map(calItem).join("")}</ul>
    ${arr(p.calendar).length>up.length? `<details style="margin-top:8px"><summary class="muted small" style="cursor:pointer">Volledige kalender (${p.calendar.length})</summary><ul class="cal">${p.calendar.slice().sort((a,b)=>a.date.localeCompare(b.date)).map(calItem).join("")}</ul></details>`:""}</div>` : "";
}
function calItem(c){
  const dd=daysFrom(c.date), rel = dd===0? "vandaag" : dd===1? "morgen" : dd>1? "over "+dd+" dagen" : Math.abs(dd)+" dagen geleden";
  return `<li class="${dd<0?"past":dd<=3?"soon":""}"><div class="d">${esc(fmtDate(c.date,{weekday:"short",day:"numeric",month:"short"}))}<small>${esc(c.time||"")}${c.time?" · ":""}${esc(rel)}</small></div>
    <div><b>${esc(c.event)}</b><div class="muted small">${esc(c.why||"")}</div><div class="chips" style="margin-top:5px">${chipsFor(c.affects)}</div></div></li>`;
}
function renderMarketEditor(){
  const body=$("mEditBody"); if(!body) return;
  const items=arr(S.market?.items);
  body.innerHTML = `<div class="tbl"><table><thead><tr><th>Cijfer</th><th>Waarde</th><th>Tijdstip</th></tr></thead><tbody>${items.map((i,ix)=>`
    <tr><td>${esc(i.label)}</td><td><input id="me-v-${ix}" inputmode="decimal" value="${esc(i.value??"")}" style="max-width:130px" aria-label="Waarde ${esc(i.label)}"></td><td><input id="me-a-${ix}" value="${esc(i.asOf||"")}" style="max-width:200px" aria-label="Tijdstip ${esc(i.label)}"></td></tr>`).join("")}</tbody></table></div>
    <div class="btnrow" style="margin-top:10px"><button class="btn primary sm" type="button" id="meSave" ${S.canWrite&&S.db?"":"disabled"}>Cijfers opslaan</button><span class="status" id="meStatus"></span></div>`;
  $("meSave").addEventListener("click", async ()=>{
    const st=$("meStatus"); const next=clone(items);
    for(let ix=0; ix<next.length; ix++){
      const raw=$("me-v-"+ix).value.trim().replace(/\s/g,"").replace(",",".");
      if(raw===""){ continue; }
      const v=Number(raw); if(!isFinite(v)){ setStatus(st,"Ongeldige waarde bij "+next[ix].label+". Gebruik alleen cijfers.",true); return; }
      if(v!==next[ix].value){ next[ix].value=v; next[ix].change=""; next[ix].src="Handmatig"; next[ix].display=null; }
      next[ix].asOf=$("me-a-"+ix).value.trim();
    }
    setStatus(st,"Opslaan…");
    try{ await S.db.doc("market/latest").update({items:next, updatedAt:new Date().toISOString(), updatedBy:"Handmatig"}); S.mEditOpen=false; notice("Cijfers opgeslagen."); }
    catch(e){ setStatus(st, dbErrText(e), true); }
  });
}

/* ================= CYCLUS ================= */
const CYCLE_ORDER=["sentiment","credit","economy"];
const CYCLE_DEF={
  sentiment:{n:1, name:"Euforie-cyclus", sub:"Hoe beleggers zich voelen (Amerikaanse aandelen)",
    phases:[["Hoop",.16],["Optimisme",.18],["Euforie",.20],["Onrust",.14],["Paniek",.16],["Wanhoop",.16]],
    ghosts:[
      {pos:.54,label:"okt '07",when:"okt 2007",tip:"9 okt 2007: S&P 500 op record (1.565), een maand na de eerste renteverlaging. De angst was laag."},
      {pos:.79,label:"sep '08",when:"sep 2008",tip:"15 sep 2008: Lehman Brothers failliet. Paniek op alle markten."},
      {pos:.97,label:"mrt '09",when:"mrt 2009",tip:"9 mrt 2009: bodem op 677 (−57%). Wanhoop, en daarna een sterk herstel."}]},
  credit:{n:2, name:"Kredietcyclus", sub:"Hoe makkelijk bedrijven geld lenen, inclusief private credit",
    phases:[["Herstel",.17],["Groei",.19],["Losse normen",.20],["Stress",.14],["Crisis",.17],["Opruimen",.13]],
    ghosts:[
      {pos:.47,label:"2006",when:"2005–06",tip:"2005–06: subprimehypotheken en complexe kredietproducten op hun hoogtepunt. De leennormen waren nooit zo los."},
      {pos:.58,label:"aug '07",when:"aug 2007",tip:"Jun–aug 2007: twee Bear Stearns-hedgefondsen klappen; BNP Paribas bevriest op 9 augustus drie fondsen."},
      {pos:.80,label:"sep '08",when:"sep 2008",tip:"Sep 2008: Lehman failliet, de kredietmarkt bevriest. De junk-spread loopt op tot ca. 20% (dec 2008)."}]},
  economy:{n:3, name:"Economische cyclus", sub:"Groei, banen, inflatie en de Fed",
    phases:[["Herstel",.17],["Groei",.19],["Laat",.20],["Afkoeling",.14],["Recessie",.30]],
    ghosts:[
      {pos:.58,label:"aug '07",when:"zomer 2007",tip:"Zomer 2007: de groei vlakt af en de werkloosheid begint op te lopen (vanaf 4,4%). De Fed staat op 5,25% en verlaagt in september voor het eerst."},
      {pos:.72,label:"dec '07",when:"dec 2007",tip:"Dec 2007: begin van de recessie (achteraf vastgesteld)."},
      {pos:.98,label:"jun '09",when:"jun 2009",tip:"Jun 2009: einde van de recessie. De werkloosheid loopt nog door tot 10,0% (okt 2009)."}]},
};
const TIMELINE_2008=[
  {step:"Goedkoop geld en euforie", then:"2003–06: Fed-rente op 1%, huizenprijzen schieten omhoog, banken verpakken subprimehypotheken in complexe producten.", now:"2023–26: AI-boom. S&P 500 +119% sinds okt 2022, margin debt $1,45 bln (+37% in een jaar), private credit gegroeid tot ca. $2 bln.", st:"done"},
  {step:"Rente omhoog", then:"2004–06: de Fed verhoogt van 1% naar 5,25%.", now:"De Fed verlaagde eind 2025, maar verhoogt weer (sep 2026: 3,75–4,00%). De 30-jaarsrente piekte op 5,73%, het hoogste sinds 2002.", st:"done"},
  {step:"Eerste barsten in de schaduw", then:"Jun–aug 2007: twee Bear Stearns-hedgefondsen klappen; BNP Paribas bevriest drie fondsen (9 aug).", now:"Private-creditfondsen laten maar 5% per kwartaal uitstappen terwijl 17% (Blue Owl) tot 39% (techfonds) eruit wil. Wanbetalingen op een record (Fitch: 6,0%).", st:"now"},
  {step:"Beurs nog op de top, angst laag", then:"9 okt 2007: S&P 500 record (1.565), kort na de eerste renteverlaging.", now:"6 okt 2026: S&P 500 record (7.819); nu ca. 1% lager. Angstindex VIX 16,9.", st:"now"},
  {step:"Olie en inflatie pieken", then:"Jul 2008: olie $147, inflatie 5,6%.", now:"Brent ca. $105 (top $126 in maart), inflatie 3,7% en oplopend.", st:"part"},
  {step:"Het breekpunt", then:"15 sep 2008: Lehman Brothers failliet. De kredietmarkt bevriest.", now:"Geen groot faillissement; de kredietmarkt werkt nog.", st:"no"},
  {step:"Bodem en redding", then:"9 mrt 2009: S&P 500 op 677 (−57%), Fed-rente op 0%, werkloosheid op weg naar 10%.", now:"", st:"no"},
];
const TL_ST={done:["t-neutral","Gebeurd"], now:["t-accent","Hier staan we"], part:["t-warn","Deels"]};
const DIFF_2008=[
  "Banken zijn sterker. Het risico zit nu vooral bij fondsen, pensioenfondsen en verzekeraars (Amerikaanse levensverzekeraars hebben zo'n 10% in private credit). Wel lenen banken samen ca. $300 mld aan deze fondsen.",
  "Een fonds met een uitstapplafond loopt niet in één dag leeg. Dat maakt het eerder een langzaam lek dan een bankrun, maar het kan wel lang duren.",
  "In 2008 vluchtte iedereen naar staatsobligaties. Nu is de obligatiemarkt zelf een zwakke plek (30-jaarsrente 5,73%), dus die veilige haven werkt mogelijk minder goed.",
  "De inflatie is hoger dan in de zomer van 2007 (3,7% tegen ca. 2%). Daardoor kan de Fed minder makkelijk snel redden zonder de inflatie aan te wakkeren.",
];
const CRASHES=[
  {years:"1973–74", name:"Oliecrisis en stagflatie", like:"olie",
   why:"Een olie-embargo (okt 1973) maakte olie vier keer zo duur. De inflatie liep op naar ruim 12% en de Fed zette de rente op ca. 13%. De populaire groeiaandelen van toen, de 'Nifty Fifty', stortten in.",
   likeNow:"een oorlog maakt olie duur, de inflatie loopt op en de Fed verhoogt.",
   diff:"olie is nu ca. 1,5 keer zo duur in plaats van 4 keer, en de economie gebruikt veel minder olie per euro groei.",
   stats:[["−48%","S&P 500 in 21 maanden"],["7,5 jaar","tot het oude record"],["+189%","goudaandelen (goud +139%)"],["−70 à −87%","groeiaandelen zoals Coca-Cola en Avon"]]},
  {years:"2000–02", name:"Dotcom-crash", like:"euforie",
   why:"Beleggers betaalden recordprijzen voor internetbedrijven, vaak zonder winst (CAPE 44). De Fed verhoogde naar 6,5%. Toen de groei tegenviel, verdampten de winsten en kwam er in 2001 een recessie.",
   likeNow:"een bijna-record waardering en een markt die leunt op een paar techreuzen.",
   diff:"de grootste techbedrijven maken nu flinke winst; in 2000 hadden veel internetbedrijven die niet.",
   stats:[["−49%","S&P 500 in 31 maanden"],["−78%","Nasdaq; herstel duurde 15 jaar"],["+65%","goudaandelen in dezelfde periode"],["3,8 → 6,3%","werkloosheid"]]},
  {years:"2007–09", name:"Kredietcrisis", like:"krediet",
   why:"Slechte hypotheken (subprime) zaten verpakt in complexe producten met veel schuld. Toen de huizenprijzen daalden, raakten fondsen klem (zomer 2007). Na het faillissement van Lehman Brothers (sep 2008) bevroor de kredietmarkt.",
   likeNow:"fondsen in een schaduwhoek van de kredietmarkt raken klem terwijl de beurs op de top staat.",
   diff:"banken zijn sterker en fondsen kunnen niet in één dag leeglopen. Maar nu is de obligatiemarkt zelf een zwakke plek.",
   stats:[["−57%","S&P 500 in 17 maanden"],["5,5 jaar","tot het oude record"],["−71%","goudaandelen in 2008 (maart–oktober)"],["4,4 → 10%","werkloosheid"]]},
  {years:"2022", name:"Renteschok", like:"rente",
   why:"De inflatie liep op naar 9,1%. De Fed verhoogde in één jaar van 0% naar 4,5%. Aandelen én obligaties daalden, vooral dure tech en crypto. Er kwam geen recessie: de banenmarkt bleef sterk.",
   likeNow:"een stijgende reële rente drukt goud(mijnen), tech en crypto.",
   diff:"de Fed begon toen op 0% en staat nu al op ca. 4%: minder ruimte om te verhogen, meer om te verlagen.",
   stats:[["−25%","S&P 500 in 9 maanden"],["2 jaar","tot het oude record"],["−46%","goudmijnen (GDX); goud −18%"],["−77%","bitcoin"]]},
];
const DD_HIST=[
  {y:"1929–32", dd:86, m:"33 mnd", rec:"25 jaar", tip:"Sep 1929 → jun 1932. Pas in 1954 terug op het oude record."},
  {y:"1973–74", dd:48, m:"21 mnd", rec:"7,5 jaar", tip:"120 (11 jan 1973) → 62 (3 okt 1974)."},
  {y:"2000–02", dd:49, m:"31 mnd", rec:"7 jaar", tip:"1.527 (24 mrt 2000) → 777 (9 okt 2002). De Nasdaq viel 78%."},
  {y:"2007–09", dd:57, m:"17 mnd", rec:"5,5 jaar", tip:"1.565 (9 okt 2007) → 677 (9 mrt 2009)."},
  {y:"2020", dd:34, m:"1 mnd", rec:"6 mnd", tip:"3.386 (19 feb) → 2.237 (23 mrt). De snelste daling en het snelste herstel."},
  {y:"2022", dd:25, m:"9 mnd", rec:"2 jaar", tip:"4.797 (3 jan) → 3.577 (12 okt)."},
];
const CAPE_PEAKS=[
  {y:"1929", v:32.6, sub:"sep 1929", tip:"Vlak voor de grote crash."},
  {y:"1973", v:18.7, sub:"jan 1973", tip:"Niet duur, toch −48%: de oorzaak was olie en inflatie, geen waardering."},
  {y:"2000", v:44.2, sub:"dec 1999 · record", tip:"Het hoogste niveau ooit gemeten."},
  {y:"2007", v:27.2, sub:"2007", tip:"Matig duur; het probleem zat in het krediet."},
  {y:"2021", v:38.6, sub:"nov 2021", tip:"Vlak voor de renteschok van 2022."},
];
const CMP_COLS=["1973–74","2000–02","2007–09","2022"];
const CMP_ROWS=[
  {l:"Beurs op de top (S&P 500)", v:["120","1.527","1.565","4.797"], now:()=>{ const d=item("spxDD"); return d?.ath? `${nf(d.ath,0)} (${fmtDate(d.athDate)})` : "–"; }},
  {l:"Stijging sinds de vorige bodem", v:["+74% (sinds 1970)","+417% (sinds 1990)","+101% (sinds 2002)","+114% (sinds 2020)"], now:()=>{ const d=item("spxDD"); return d?.ath? `+${nf((d.ath/3577.03-1)*100,0)}% (sinds 2022)` : "–"; }},
  {l:"Waardering (CAPE) op de top", v:["18,7","44,2","ca. 27","38,6"], now:()=>itemText(item("cape"))},
  {l:"Daling top → bodem", v:["−48%","−49%","−57%","−25%"], now:()=>{ const d=item("spxDD"); return d && typeof d.value==="number"? itemText(d)+" tot nu" : "–"; }},
  {l:"Tijd tot bodem · tot oud record", v:["21 mnd · 7,5 jr","31 mnd · 7 jr","17 mnd · 5,5 jr","9 mnd · 2 jr"], now:()=>"–"},
  {l:"Fed-rente op het hoogst", v:["ca. 13%","6,5%","5,25%","4,5% (5,5% in 2023)"], now:()=>itemText(item("fedFunds"))},
  {l:"Inflatie op het hoogst", v:["12,2%","ca. 3,8%","5,6%","9,1%"], now:()=>itemText(item("cpiYoY"))},
  {l:"Werkloosheid begin → piek", v:["4,6 → 9,0%","3,8 → 6,3%","4,4 → 10,0%","3,5 → 3,7%"], now:()=>{ const u=item("unrate"), s=item("sahm"); return `${itemText(u)}${s&&typeof s.value==="number"? " · Sahm "+itemText(s):""}`; }},
  {l:"Olie", v:["×4","×3 (naar ca. $35)","$147 (jul 2008)","Brent $128"], now:()=>`Brent ${itemText(item("brent"))} (top $126)`},
  {l:"Goud · goudaandelen", v:["+139% · +189%","licht hoger · +65%","+26% · −46% (−71% in 2008)","−18% · −46%"], now:()=>{ const g=item("gold"); if(!g||typeof g.value!=="number") return "–"; const pct=(g.value/5590-1)*100; return pct>=0? "goud op record" : `goud ${nf(pct,0).replace("-","−")}% t.o.v. record (jan 2026)`; }},
];
const YOU=[
  {pos:"Goud- en zilvermijnen", t:"Het soort crash bepaalt alles. Bij olie en inflatie (1973) stegen goudaandelen 189% en na de dotcom-top 65%. In een kredietpaniek vielen ze eerst 71% (2008), in een renteschok 46% (2022). Het herstel kwam toen de paniek voorbij was en de Fed de rente hard verlaagde."},
  {pos:"Mag 7", t:"Na de dotcom-top viel de Nasdaq 78% en duurde het herstel 15 jaar; in 2022 ca. −35%. De markt leunt nu nog zwaarder op de grootste bedrijven (top-10 ca. 40% van de S&P 500, tegen ca. 27% in 2000), maar die maken wel echte winst."},
  {pos:"Circle (CRCL)", t:"Heeft als beursfonds nog geen crash meegemaakt. In 2022 viel bitcoin 77%. In een crisis verlaagt de Fed de rente, en dat raakt Circles rente-inkomsten direct."},
  {pos:"Insider-aandelen (small caps)", t:"Kleine bedrijven voelen dure leningen het eerst. Zolang de kredietcyclus op 'stress' staat: klein houden."},
  {pos:"Cash", t:"Na elke bodem kwam een sterk herstel: +37% in 1975 en ruim +60% tussen maart en december 2009. Wie dan droog kruit heeft, profiteert."},
];
const FOUR=[
  {id:"waardering", name:"Waarderingscyclus", lv:"rood", tag:"Hardste rode signaal",
   what:"Hoe duur aandelen zijn ten opzichte van winst en economie.",
   rows:[["Shiller-CAPE","cape"],["Buffett-indicator","buffett"],["Top-10 in S&P 500","top10"]],
   vs:["2000: zeer vergelijkbaar. CAPE 44 en een tech-hype (toen internet, nu AI en chips). Daarna S&P −49%, Nasdaq −78%.","2008: minder. CAPE stond rond 27, de Buffett-indicator op 131% (nu 288%)."],
   note:"Een dure beurs voorspelt lage rendementen over 10 jaar, niet de datum van een crash. Markten kunnen jaren duur blijven."},
  {id:"krediet", name:"Kredietcyclus", lv:"oranje", tag:"Stress aan de randen",
   what:"Hoe makkelijk bedrijven en beleggers geld lenen.",
   rows:[["Junk-spread (HY OAS)","hySpread"],["Margin debt","marginDebt"],["Wanbetaling private credit","pcDefault"]],
   vs:["2008: een pure krediet- en bankencrisis (subprime). Junk-spread piekte rond 20%; in 2020 rond 11%.","Nu: spread laag (3,2%), geen huizen- of bankenbubbel. Wel stress bij de zwakste leners (CCC) en in private credit."],
   note:"Kantelpunt: een junk-spread boven 5% en fondsen die uitstappen stoppen."},
  {id:"liquiditeit", name:"Liquiditeitscyclus", lv:"oranje", tag:"Gemengd",
   what:"Hoeveel geld er door het systeem stroomt en wat geld kost.",
   rows:[["Fed-balans","fedAssets"],["Netto liquiditeit","netLiq"],["Reële rente 10 jaar","realYield10"]],
   vs:["De Fed-balans groeit weer langzaam (+$159 mld in een jaar): de krimp (QT) is grotendeels voorbij.","Maar de reële rente is hoog (bijna 3%): geld is duur. Dat drukt groeiaandelen, goud en bitcoin."],
   note:"Lagere rente helpt bitcoin en goud, maar kost Circle direct inkomsten."},
  {id:"bedrijf", name:"Bedrijfscyclus", lv:"groen", tag:"Nog geen recessie",
   what:"Banen, groei en de signalen die een recessie aankondigen.",
   rows:[["Rentecurve 10j − 2j","curve"],["Sahm-regel","sahm"],["Werkloosheid","unrate"],["WW-aanvragen","claims"],["VIX (angst)","vix"]],
   vs:["2008: duidelijke inversie van de curve en een snel verslechterende arbeidsmarkt.","Nu: curve weer positief, Sahm 0,0, werkloosheid 4,2%. Een lage VIX wijst wel op zelfgenoegzaamheid."],
   note:"Let op: een curve die na een inversie weer steil wordt, ging in 2001 en 2007 aan de recessie vooraf."},
];
const LONG=[
  {name:"18-jaars vastgoed- en economiecyclus", segs:["Herstel","Groei","Middencrisis","Speculatie","Crash"], on:3, src:"Fred Harrison, Phillip Anderson",
   t:"Grondprijzen en krediet stijgen ca. 14 jaar en vallen dan in een recessie. Vorige pieken: 1973–74, 1989–90, 2006–07. Vanaf de bodem van 2011–12 valt de volgende piek in 2026–2028, met 2027 als vaak genoemd jaar.",
   now:"We zitten in de laatste, speculatieve fase ('winner's curse'): de hoogste prijzen en de meeste schuld.",
   caveat:"Een theorie van praktijkbeleggers, geen wetmatigheid. Het blijft een gemiddelde."},
  {name:"Bitcoin 4-jaarscyclus", segs:["Halvering apr '24","Stijging","Top okt '25","Daling","Bodem?"], on:3, src:"halvering elke 4 jaar; volgende in 2028",
   t:"Na elke halvering kwam een top na 12 tot 18 maanden en daarna een daling van 75–85% over ongeveer een jaar. Deze keer: top boven $126.000 in oktober 2025.",
   now:"Bitcoin staat rond $82.000 (−35%), het dieptepunt dit jaar lag ca. 54% onder de top. Als het patroon klopt, ligt de bodem rond het najaar van 2026; daarna ruim een jaar opbouw tot de halvering van 2028.",
   caveat:"Met ETF's en grote fondsen kan het patroon zwakker worden."},
  {name:"Aandelencyclus: verkiezingsjaren (VS)", segs:["Jaar 1","Midterm '26","Jaar 3 '27","Verkiezing '28"], on:1, src:"S&P 500 sinds 1950",
   t:"In een midterm-jaar daalde de S&P 500 gemiddeld 19% van top tot dal; in 11 van de 16 midterm-jaren 15% of meer. Na het dal volgde gemiddeld +31% in 12 maanden, en het derde jaar is meestal het sterkste.",
   now:"2026 is een midterm-jaar (verkiezingen 3 november). Historisch valt het dal in de zomer of het najaar en komt daarna herstel in 2027.",
   caveat:"Een seizoenspatroon: het weegt minder zwaar dan waardering of krediet."},
  {name:"Grondstoffencyclus", segs:["Bodem","Opbouw","Piek","Correctie","Nieuwe golf?"], on:3, src:"Kitco, Discovery Alert, S&P Global",
   t:"Metalen piekten in januari 2026: goud $5.590, zilver $121. Koper zette in september nog een record (LME $14.875 per ton).",
   now:"Goud ca. $4.200 (−25%), zilver ca. $57 (−53%). De hoge reële rente is de rem; centrale banken kopen wel recordhoeveelheden goud. Koper valt in een beurscorrectie vaak twee keer zo hard als aandelen.",
   caveat:"Sommigen zien een nieuwe supercyclus; dat is een verwachting, geen feit."},
];
const HOLD=[
  {pos:"VWCE (wereldwijde aandelen)", risk:"Hoog", tone:"t-bad", cycles:"Waardering, bedrijfscyclus, liquiditeit",
   vs:"Lijkt het meest op 2000: breed blootgesteld aan de dure Amerikaanse beurs (ca. 60–65% VS).",
   watch:"CAPE, Buffett-indicator, Sahm-regel", rule:"Beurs 20% onder het record of Sahm boven 0,5: dan is het geen dip meer."},
  {pos:"SMH (chips en AI)", risk:"Zeer hoog", tone:"t-bad", cycles:"Waardering, AI-investeringen, chipcyclus",
   vs:"De sterkste parallel met 2000: de Nasdaq viel toen 78% en had 15 jaar nodig om terug te komen.",
   watch:"AI-investeringen van de grote techbedrijven en of die winst opleveren; voorraden en orders bij chipmakers", rule:"Snijden de grote techbedrijven in hun AI-uitgaven, dan is dat het moment om dit te verkleinen."},
  {pos:"Circle (CRCL)", risk:"Anders", tone:"t-warn", cycles:"Rente, liquiditeit, adoptie van stablecoins",
   vs:"Meer een rente- en stablecoinverhaal dan een gewoon aandeel. Een crash met renteverlagingen raakt de winst direct.",
   watch:"Fed-rente, hoeveelheid USDC in omloop", rule:"Elke 1% renteverlaging kost een groot deel van de rente-inkomsten; groei van USDC moet dat goedmaken."},
  {pos:"Bitcoin", risk:"Gemengd", tone:"t-warn", cycles:"Liquiditeit, risk-on/off, 4-jaarscyclus",
   vs:"Valt mee met risico in paniek, maar kan profiteren als de Fed weer geld bijdrukt. Nu laat in de dalende fase van de eigen cyclus.",
   watch:"Fed-balans, netto liquiditeit, reële rente", rule:"Een bodem na de 4-jaarscyclus valt vaak samen met de eerste renteverlagingen."},
  {pos:"Goud (en goudmijnen)", risk:"Beschermend", tone:"t-good", cycles:"Reële rente, dollar, vlucht uit risico",
   vs:"In 2000–02 en na 2008 relatief sterk. In een acute paniek (zoals okt 2008) daalt het eerst mee; mijnen ongeveer twee keer zo hard.",
   watch:"Reële rente 10 jaar, dollar", rule:"Daalt de reële rente onder 2%, dan krijgt goud weer wind mee."},
];
const WATCH=[
  {g:"Waardering", l:"Shiller-CAPE", key:"cape", band:v=>v>35?"rood":v>25?"oranje":"groen", rule:"groen < 25 · rood > 35"},
  {g:"Waardering", l:"Buffett-indicator", key:"buffett", band:v=>v>180?"rood":v>120?"oranje":"groen", rule:"groen < 120% · rood > 180%"},
  {g:"Krediet", l:"Junk-spread (HY OAS)", key:"hySpread", band:v=>v>=5?"rood":v>=4?"oranje":"groen", rule:"oranje ≥ 4% · rood ≥ 5%"},
  {g:"Krediet", l:"Margin debt", key:"marginDebt", band:v=>v>=1.3?"oranje":"groen", rule:"record = veel geleend geld in de markt"},
  {g:"Liquiditeit", l:"Fed-balans", key:"fedAssets", band:()=>"groen", rule:"groeit = steun; krimpt = rem"},
  {g:"Liquiditeit", l:"Reële rente 10 jaar", key:"realYield10", band:v=>v>2.5?"rood":v>1.5?"oranje":"groen", rule:"groen < 1,5% · rood > 2,5%"},
  {g:"Bedrijfscyclus", l:"Rentecurve 10j − 2j", key:"curve", band:v=>v<0?"oranje":v<0.75?"oranje":"groen", rule:"weer steil worden na inversie = let op"},
  {g:"Bedrijfscyclus", l:"Sahm-regel", key:"sahm", band:v=>v>=0.5?"rood":v>=0.3?"oranje":"groen", rule:"oranje ≥ 0,3 · rood ≥ 0,5"},
  {g:"Bedrijfscyclus", l:"WW-aanvragen (per week)", key:"claims", band:v=>v>=300?"rood":v>=250?"oranje":"groen", rule:"oranje ≥ 250k · rood ≥ 300k"},
  {g:"Sentiment", l:"VIX", key:"vix", band:v=>v>=30?"rood":v<15?"oranje":"groen", rule:"< 15 zelfgenoegzaam · ≥ 30 paniek"},
  {g:"Sentiment", l:"S&P 500 t.o.v. record", key:"spxDD", band:v=>v<=-20?"rood":v<=-10?"oranje":"groen", rule:"oranje ≤ −10% · rood ≤ −20%"},
];
const WL_DOT={rood:"stress", oranje:"gespannen", groen:"rustig"};
const CRASH_SOURCES=[
  ["GuruFocus: Buffett-indicator","https://www.gurufocus.com/economic_indicators/4602/usa-ratio-of-total-market-cap-over-gdp"],
  ["thetrading.tools: Buffett-indicator (Fed Z.1), 2000 en 2007","https://www.thetrading.tools/buffett-indicator"],
  ["Federal Reserve H.4.1: balans 14 okt 2026","https://www.federalreserve.gov/releases/h41/current/"],
  ["Progress.org: de 18,6-jaarscyclus","https://www.progress.org/wiki/progress-18-6-year-cycle/"],
  ["Baltex: bitcoin-bearmarkt 2026","https://baltex.io/blog/ecosystem/price-prediction-bitcoin-october-2026-bear-market"],
  ["Sequoia: het midterm-jaar 2026","https://www.sequoia-financial.com/insights/the-midterm-year-roadmap-what-history-tells-us-about-2026/"],
  ["Discovery Alert: goud, zilver en koper okt 2026","https://discoveryalert.com/analysis/gold-silver-copper-stock-market-correlation-october-2026/"],
  ["Wikipedia: Amerikaanse beursdaling 2007–2009","https://en.wikipedia.org/wiki/United_States_bear_market_of_2007%E2%80%932009"],
  ["Vantage Markets: S&P 500-record op 6 okt 2026","https://www.vantagemarkets.com/market-analysis/sp500-today-record-yields-earnings-cpi-october-12-2026/"],
  ["Multpl: CAPE per jaar","https://www.multpl.com/shiller-pe/table/by-year"],
  ["thetrading.tools: CAPE-pieken 1929, 1999, 2021 en nu","https://www.thetrading.tools/manuals/shiller-cape"],
  ["Zeal: goudaandelen tijdens 2000–02","https://zealllc.com/2008/huibears2.htm"],
  ["Zeal: paniek in goudaandelen 2008","https://zealllc.com/2008/huipanic.htm"],
  ["Zeal: goudmijnen in 2022","https://www.zealllc.com/2022/gmq322fn.htm"],
  ["Mining.com: goud en goudaandelen in 1973–74 en 2008","https://www.mining.com/web/will-next-market-crash-like-2008-1973-history-predicts-amazing-run-gold-gold-stocks/"],
  ["Gainesville Coins: goud in 2008","https://gainesvillecoins.com/blog/gold-price-2008-what-we-can-learn"],
  ["Jason Zweig: de beursdaling van 1973–74","https://jasonzweig.com/?p=7006"],
  ["Show-Me Banker: de Fed in 1973–74","https://the-show-me-banker.thenewslinkgroup.org/monetary-policy-for-the-win-the-fed-was-battling-inflation-50-years-ago-too/"],
  ["HedgeNordic: de bodem van 1974","https://hedgenordic.com/2022/12/will-equities-bottom-out-like-in-1974"],
  ["eco3min: recordniveau junk-spread (2008)","https://eco3min.fr/en/credit-spreads-recession-risk-dataset/"],
  ["Forbes: wanbetalingen in private credit (2026)","https://www.forbes.com/sites/mayrarodriguezvalladares/2026/05/24/rising-private-credit-defaults-are-testing-banks-and-insurers/"],
  ["Advisor Perspectives: margin debt augustus 2026","https://www.advisorperspectives.com/dshort/updates/2026/09/17/margin-debt-finra-august-2026.pdf"],
  ["PrimeXBT: gewicht top-10 in de S&P 500","https://primexbt.com/news/sp-500-hits-its-most-concentrated-top-10-weighting-since-the-mid-1960s/"],
  ["FRED: Sahm-regel","https://fred.stlouisfed.org/series/SAHMREALTIME"],
];
const TP_LABEL={rustig:"Nog niet", gespannen:"Dichtbij", stress:"Bereikt", info:"Onbekend"};

function phaseAt(id,pos){ const D=CYCLE_DEF[id]; if(!D) return ""; let acc=0; for(const [n,w] of D.phases){ acc+=w; if(pos<acc-1e-9) return n; } return D.phases[D.phases.length-1][0]; }
function nearestGhost(id,pos){ return CYCLE_DEF[id].ghosts.reduce((a,g)=>Math.abs(g.pos-pos)<Math.abs(a.pos-pos)? g : a); }
function tipLevel(t){
  if(t.key){ const it=item(t.key); const v=(it && typeof it.value==="number")? it.value : null;
    if(v!=null) return t.dir==="down"? (v<=t.hit?"stress":v<=t.near?"gespannen":"rustig") : (v>=t.hit?"stress":v>=t.near?"gespannen":"rustig"); }
  return LV[t.status]? t.status : "info";
}
function cycleSVG(id, c){
  // golf: 0 = bodem, 0,5 = top, 1 = volgende bodem; fasenamen staan onder de golf, de huidige fase is gemarkeerd
  const D=CYCLE_DEF[id], W=340, H=180, x0=14, x1=326, yT=42, yB=124, yLab=161;
  const X=f=>x0+f*(x1-x0), Y=f=>(yT+yB)/2 + Math.cos(2*Math.PI*f)*(yB-yT)/2;
  const seg=(a,b)=>{ const N=Math.max(2,Math.round((b-a)*90)); let d=""; for(let i=0;i<=N;i++){ const f=a+(b-a)*i/N; d+=(i?"L":"M")+X(f).toFixed(1)+" "+Y(f).toFixed(1); } return d; };
  const pos=clamp(+c.pos||0,0,1), ph=phaseAt(id,pos);
  let acc=0, col="", labels="", guides="";
  D.phases.forEach(([n,w],i)=>{ const a=acc, b=acc+w; acc=b; const xa=X(a), xb=X(b), xm=(xa+xb)/2, on=n===ph;
    if(on) col=`<rect class="cy-col" x="${(xa+1).toFixed(1)}" y="2" width="${(xb-xa-2).toFixed(1)}" height="${H-4}" rx="8"/>`;
    if(i<D.phases.length-1) guides+=`<line class="cy-guide" x1="${xb.toFixed(1)}" y1="12" x2="${xb.toFixed(1)}" y2="${yLab-14}"/>`;
    const words=n.split(" ");
    labels+=`<text class="cy-ph${on?" on":""}" x="${xm.toFixed(1)}" y="${yLab}" text-anchor="middle">${words.length>1? words.map((t,k)=>`<tspan x="${xm.toFixed(1)}" dy="${k? 12 : 0}">${esc(t)}</tspan>`).join("") : esc(n)}</text>`; });
  const mark=(cls, x, y, r, tip, inner)=>`<g class="${cls}" tabindex="0" role="button" data-tip="${esc(tip)}" aria-label="${esc(tip)}"><circle class="cy-hit" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${r}"/>${inner}</g>`;
  const ghosts=D.ghosts.map(g=>{ const gx=X(g.pos), gy=Y(g.pos), w=String(g.label||"").length*6.4, nearNow=Math.abs(g.pos-pos)<0.05;
    // label aan de kant waar de lijn niet loopt: dalend → linksonder, stijgend → rechtsonder, top/bodem → eronder
    let anchor="middle", tx=gx, ty=gy+(nearNow? 28 : 19);
    // vlak bij NU: label linksonder NU, tenzij daar al een ander 2007–09-label staat
    if(nearNow && !D.ghosts.some(o=>o!==g && o.pos<g.pos && g.pos-o.pos<0.14)){ anchor="end"; tx=X(pos)-2; }
    if(!nearNow && g.pos>0.58 && g.pos<0.95){ anchor="end"; tx=gx-7; ty=gy+16; }
    else if(!nearNow && g.pos>0.05 && g.pos<0.42){ anchor="start"; tx=gx+7; ty=gy+16; }
    if(anchor==="middle" && gx+w/2>W){ anchor="end"; tx=gx+7; }
    if(anchor==="middle" && gx-w/2<0){ anchor="start"; tx=gx-7; }
    if(anchor==="end" && tx-w<0){ anchor="start"; tx=gx+7; }
    if(anchor==="start" && tx+w>W){ anchor="end"; tx=gx-7; }
    return mark("cy-g", gx, gy, 13, g.tip, `<circle class="cy-gdot" cx="${gx.toFixed(1)}" cy="${gy.toFixed(1)}" r="4.5"/><text class="cy-glab" x="${tx.toFixed(1)}" y="${ty.toFixed(1)}" text-anchor="${anchor}">${esc(g.label)}</text>`); }).join("");
  const extras=arr(c.extra).map(e=>{ const ep=clamp(+e.pos||0,0,1), ex=X(ep), ey=Y(ep), w=String(e.label||"").length*6.2;
    // dalend deel: label rechtsboven (daar ligt de lijn lager); stijgend deel: linksboven
    let right = ep>0.5; if(right && ex+9+w>W+2) right=false; else if(!right && ex-9-w<-2) right=true;
    return mark("cy-x", ex, ey, 13, `${e.label}: ${e.why||""}`, `<circle class="cy-xdot" cx="${ex.toFixed(1)}" cy="${ey.toFixed(1)}" r="6"/><text class="cy-xlab" x="${(right? ex+9 : ex-9).toFixed(1)}" y="${(ey-9).toFixed(1)}" text-anchor="${right?"start":"end"}">${esc(e.label)}</text>`); }).join("");
  const nx=X(pos), ny=Y(pos), ng=D.ghosts.find(g=>Math.abs(g.pos-pos)<0.05);
  const now=mark("cy-n", nx, ny, 16, `Nu: ${ph}. ${c.why||""}${ng? `\n\nToen op deze plek: ${ng.tip}` : ""}`, `<circle class="cy-halo" cx="${nx.toFixed(1)}" cy="${ny.toFixed(1)}" r="15"/><circle class="cy-dot" cx="${nx.toFixed(1)}" cy="${ny.toFixed(1)}" r="7"/><rect class="cy-pill" x="${(nx-17).toFixed(1)}" y="${(ny-36).toFixed(1)}" width="34" height="18" rx="9"/><text class="cy-pilltx" x="${nx.toFixed(1)}" y="${(ny-23.5).toFixed(1)}" text-anchor="middle">NU</text>`);
  return `<svg viewBox="0 0 ${W} ${H}" role="group" aria-label="${esc(`${D.name}: nu in de fase ${ph}. Fasen: ${D.phases.map(p=>p[0]).join(", ")}`)}">${col}${guides}${labels}<path class="cy-future" d="${seg(pos,1)}"/><path class="cy-past" d="${seg(0,pos)}"/>${ghosts}${extras}${now}</svg>`;
}
function hbarsHTML(rows, max, med){
  const mp = med? (med.v/max*100).toFixed(1) : null;
  return `<div class="hbars">${med? `<div class="hb-medlab" aria-hidden="true"><span></span><span><em style="left:${mp}%">${esc(med.label)}</em></span><span></span></div>`:""}${rows.map(r=>`<div class="hb ${r.now?"now":""}" tabindex="0" data-tip="${esc(r.tip)}"><span class="hb-l">${esc(r.y)}</span><span class="hb-t"><i style="width:${clamp(Math.abs(r.v)/max*100,0.8,100).toFixed(1)}%"></i>${med? `<b class="med" style="left:${mp}%"></b>`:""}</span><span class="hb-v">${esc(r.vt)}</span><span class="hb-s">${esc(r.sub||"")}</span></div>`).join("")}</div>`;
}
function renderCyclus(){
  const el=$("cy-body"), p=S.plan, cy=p?.macro?.cycle;
  if(!p){ el.innerHTML = S.offline? `<div class="empty"><b>Opslag niet bereikbaar in deze weergave</b><span>Open je plan via plan.vsonsbeek.nl of in de Claude-app.</span></div>` : `<div class="empty"><b>Cyclus laden…</b><span>De cyclusgrafieken en de crashvergelijking verschijnen zodra de opslag antwoordt.</span></div>`; return; }
  if(!cy){ el.innerHTML=`<div class="empty"><b>De cyclus-analyse ontbreekt nog in je plan</b><span>Werk je site bij (zie Uitleg); daarna verschijnt hij hier vanzelf.</span></div>`; return; }
  const tps=arr(cy.tipping).map(t=>({...t, lv:tipLevel(t)}));
  const hit=tps.filter(t=>t.lv==="stress").length, near=tps.filter(t=>t.lv==="gespannen").length;
  const dd=item("spxDD"), cape=item("cape");
  const hasDD = dd && typeof dd.value==="number";

  const hero=`<div class="hero cyhero">
    <div>
      <span class="eyebrow">Cyclus · waar staan we ten opzichte van een crash? · ${esc(fmtDT(cy.updatedAt))}</span>
      <h1>${esc(cy.verdict||"")}</h1>
      <p class="lede">${esc(cy.summary||"")}</p>
      <div class="cy-like">${arr(cy.analogs).map(a=>`<div class="lk"><b>Lijkt op ${esc(a.label)} · ${esc(a.what)}</b><span>${esc(a.why)}</span></div>`).join("")}</div>
    </div>
    <div class="cy-stats">
      <div class="cy-stat"><b>${esc(hasDD? itemText(dd) : "–")}</b><span>S&amp;P 500 ten opzichte van het record</span><small>${esc(dd?.change||"")}${dd?.asOf? " · "+esc(dd.asOf):""}</small></div>
      <div class="cy-stat"><b>${esc(cape? itemText(cape) : "–")}</b><span>Waardering (Shiller-CAPE)</span><small>Alleen eind 1999 was de beurs duurder (44,2); normaal is 16,6</small></div>
      <div class="cy-stat"><b>${hit} van ${tps.length}</b><span>Kantelpunten naar een crash bereikt</span><small>${near} dichtbij · <a href="#cy-tp">bekijk ze</a></small></div>
    </div>
  </div>`;

  const cards=CYCLE_ORDER.map(id=>{ const D=CYCLE_DEF[id], c=arr(cy.cycles).find(x=>x.id===id); if(!c) return "";
    const pos=clamp(+c.pos||0,0,1), ph=phaseAt(id,pos), g=nearestGhost(id,pos);
    return `<article class="box cy-card">
      <div class="cy-head"><span class="eyebrow">Cyclus ${D.n}</span><h3>${esc(D.name)}</h3><p class="muted small">${esc(D.sub)}</p></div>
      <figure class="cy-fig">${cycleSVG(id,c)}</figure>
      <div class="cy-txt">
        <div class="cy-now"><span class="pill t-accent">Nu: ${esc(ph)}</span><span class="muted small">${Math.abs(g.pos-pos)<=0.03? "zelfde plek als "+esc(g.when) : "het dichtst bij "+esc(g.when)}</span></div>
        <p>${esc(c.why||"")}</p>
        ${arr(c.extra).map(e=>`<p class="xline"><i></i><b style="color:var(--ink)">${esc(e.label)}:</b> ${esc(e.why||"")}</p>`).join("")}
      </div>
    </article>`; }).join("");
  const cycles=`<div class="stack">
    <div class="sechead"><h2>Waar in de cyclus?</h2><span class="muted small">Drie cycli die aan elke grote crash vooraf gingen. De cirkel is waar we nu staan.</span></div>
    <div class="cy-key"><span><i class="k-now"></i>Nu</span><span><i class="k-ghost"></i>Zo liep 2007–09 (beweeg of tik voor uitleg)</span><span><i class="k-line"></i>Mogelijk verder verloop</span><span><i class="k-x"></i>Goud &amp; zilver</span></div>
    <div class="cy-grid">${cards}</div>
  </div>`;

  const tl=`<div class="box stack">
    <div class="sechead"><div><span class="eyebrow">Eén op één</span><h2 style="margin-top:3px">Zo ging het in 2008, stap voor stap</h2></div><span class="muted small">En waar we nu staan (half oktober 2026)</span></div>
    <div>
      <div class="tl-row head"><span>Fase</span><span>2007–2009</span><span>Nu</span></div>
      ${TIMELINE_2008.map((r,i)=>{ const s=TL_ST[r.st]; return `<div class="tl-row ${r.st==="now"?"cur":""}"><div class="tl-step"><span class="tl-n">${i+1}</span><span>${esc(r.step)}</span></div><div class="tl-then">${esc(r.then)}</div><div class="tl-now">${s? `<span class="pill ${s[0]}">${s[1]}</span>` : `<span class="chip">Nog niet</span>`}${r.now? `<span>${esc(r.now)}</span>`:""}</div></div>`; }).join("")}
    </div>
    <div class="stack" style="gap:6px"><h3>Wat is anders dan in 2008?</h3><ul class="actions">${DIFF_2008.map(x=>`<li><span>${esc(x)}</span></li>`).join("")}</ul></div>
  </div>`;

  const tipping=`<div class="box stack" id="cy-tp" style="scroll-margin-top:120px">
    <div class="sechead"><div><span class="eyebrow">Waar je op let</span><h2 style="margin-top:3px">Kantelpunten van 'laat' naar 'crash'</h2></div><span class="pill ${hit? "t-bad" : near? "t-warn" : "t-good"}">${hit} van ${tps.length} bereikt · ${near} dichtbij</span></div>
    <p class="secintro">Deze signalen markeerden in 2007–08 de overgang van de eerste barsten naar de echte klap. Waar het kan, worden ze automatisch bijgewerkt.</p>
    <div>${tps.map(t=>{ const it=t.key? item(t.key) : null; const val=(it && typeof it.value==="number")? itemText(it) : "";
      return `<div class="tp"><span class="dot ${esc(t.lv)}"></span><b>${esc(t.label)}</b><span class="tp-r">${val? `<span class="num small">${esc(val)}</span>`:""}<span class="pill ${LV[t.lv]?.tone||"t-neutral"}">${TP_LABEL[t.lv]||"Onbekend"}</span></span>
        <p>${t.now? `<b style="color:var(--ink);font-weight:500">Nu:</b> ${esc(t.now)}. `:""}${t.rule? `<b style="color:var(--ink);font-weight:500">Grens:</b> ${esc(t.rule)}. `:""}<b style="color:var(--ink);font-weight:500">Toen:</b> ${esc(t.then||"")}</p></div>`; }).join("")}</div>
  </div>`;

  const crashes=`<div class="stack">
    <div class="sechead"><h2>Vier grote crashes, vier oorzaken</h2><span class="muted small">Van elk zien we nu een stukje terug</span></div>
    <div class="cr-grid">${CRASHES.map(c=>`<article class="box cr">
      <div class="cr-top"><div><span class="eyebrow">${esc(c.years)}</span><h3 style="margin-top:2px">${esc(c.name)}</h3></div><span class="pill t-accent plain">Lijkt op nu: ${esc(c.like)}</span></div>
      <p class="small">${esc(c.why)}</p>
      <div class="cr-stats">${c.stats.map(s=>`<div class="cr-stat"><b>${esc(s[0])}</b><span>${esc(s[1])}</span></div>`).join("")}</div>
      <div class="cr-like"><b>Nu ook:</b> ${esc(c.likeNow)}</div>
      <p class="cr-diff"><b style="color:var(--ink)">Nu anders:</b> ${esc(c.diff)}</p>
    </article>`).join("")}</div>
  </div>`;

  const ddRows=DD_HIST.map(d=>({y:d.y, v:d.dd, vt:"−"+d.dd+"%", sub:`${d.m} tot de bodem · herstel ${d.rec}`, tip:`${d.y}: −${d.dd}% in ${d.m}, terug op het oude record na ${d.rec}. ${d.tip}`}));
  if(hasDD) ddRows.push({y:"Nu", v:Math.min(0,dd.value), vt:itemText(dd), sub:dd.change||"ten opzichte van het record", tip:`Nu: ${itemText(dd)} ten opzichte van het record. ${dd.change||""}`, now:true});
  const capeRows=CAPE_PEAKS.map(c=>({y:c.y, v:c.v, vt:nf(c.v,1), sub:c.sub, tip:`${c.y}: CAPE ${nf(c.v,1)} (${c.sub}). ${c.tip}`}));
  if(cape && typeof cape.value==="number") capeRows.push({y:"Nu", v:cape.value, vt:nf(cape.value,1), sub:cape.asOf||"", tip:`Nu: CAPE ${nf(cape.value,1)} (${cape.asOf||""}). Alleen eind 1999 was hoger.`, now:true});
  const charts=`<div class="grid g-2e">
    <div class="box stack"><div><h3>Hoe diep viel de beurs?</h3><p class="muted small">S&amp;P 500 van top tot bodem</p></div>${hbarsHTML(ddRows, 90)}</div>
    <div class="box stack"><div><h3>Hoe duur was de beurs op de top?</h3><p class="muted small">Shiller-CAPE: de koers gedeeld door de gemiddelde winst van 10 jaar</p></div>${hbarsHTML(capeRows, 48, {v:16.6, label:"normaal 16,6"})}<p class="faint small">Een hoge CAPE voorspelt geen datum, wel lagere rendementen in de jaren erna.</p></div>
  </div>`;

  const nowCol=CMP_ROWS.map(r=>{ try{ return r.now(); }catch(e){ return "–"; } });
  const table=`<div class="box stack"><div class="sechead"><h2>Toen en nu in cijfers</h2><span class="muted small">Op je telefoon: scroll opzij</span></div>
    <div class="tbl cmp"><table><thead><tr><th></th>${CMP_COLS.map(c=>`<th>${esc(c)}</th>`).join("")}<th class="nu">Nu</th></tr></thead>
    <tbody>${CMP_ROWS.map((r,i)=>`<tr><td>${esc(r.l)}</td>${r.v.map(v=>`<td>${esc(v)}</td>`).join("")}<td class="nu">${esc(nowCol[i])}</td></tr>`).join("")}</tbody></table></div></div>`;

  const lvPillC=(lv,tag)=>`<span class="pill ${lv==="rood"?"t-bad":lv==="oranje"?"t-warn":"t-good"}">${esc(tag)}</span>`;
  const valOf=(k)=>{ const it=item(k); return it&&(typeof it.value==="number"||it.display)? itemText(it) : "–"; };
  const four=`<div class="stack">
    <div class="sechead"><h2>De vier cycli die nu tellen</h2><span class="muted small">Samen geven ze het beste beeld van het crashrisico</span></div>
    <div class="kort"><b>Kort gezegd:</b> de waardering staat op rood en lijkt het meest op 2000. De klassieke signalen van 2008 (krediet en recessie) zijn er nog niet. Het risico is vooral een dure beurs die hard kan corrigeren, geen bankencrisis.</div>
    <div class="c4">${FOUR.map(f=>`<article class="box lv-${f.lv}">
      <div class="sechead"><h3>${esc(f.name)}</h3>${lvPillC(f.lv,f.tag)}</div>
      <p class="small muted">${esc(f.what)}</p>
      <div class="c4-kv">${f.rows.map(([l,k])=>`<span>${esc(l)}</span><b>${esc(valOf(k))}</b>`).join("")}</div>
      <div class="vs">${f.vs.map(v=>`<span>${esc(v)}</span>`).join("")}</div>
      <p class="small">${esc(f.note)}</p></article>`).join("")}</div>
  </div>`;
  const longc=`<div class="stack">
    <div class="sechead"><h2>Lange cycli</h2><span class="muted small">Ritmes van jaren; ze zeggen iets over de richting, niet over de dag</span></div>
    <div class="lc">${LONG.map(c=>`<article class="box">
      <h3>${esc(c.name)}</h3>
      <div class="segs" role="img" aria-label="${esc(c.name)}: nu ${esc(c.segs[c.on])}">${c.segs.map((g,i)=>`<span class="${i===c.on?"on":i<c.on?"past":""}">${esc(g)}</span>`).join("")}</div>
      <p class="small">${esc(c.t)}</p>
      <p class="small"><b>Nu:</b> ${esc(c.now)}</p>
      <p class="faint small">${esc(c.caveat)} Bron: ${esc(c.src)}.</p></article>`).join("")}</div>
  </div>`;
  const you=`<div class="box stack"><div class="sechead"><h2>Wat dit betekent voor jouw beleggingen</h2><span class="muted small">Elke belegging reageert op andere cycli</span></div>
    <div class="hold">${HOLD.map(h=>`<article><div class="sechead"><h3>${esc(h.pos)}</h3><span class="pill ${h.tone}">${esc(h.risk)}</span></div>
      <span class="lbl">Beweegt op</span><span>${esc(h.cycles)}</span>
      <span class="lbl">Vergeleken met 2000 en 2008</span><span>${esc(h.vs)}</span>
      <span class="lbl">Let op</span><span>${esc(h.watch)}</span>
      <span class="rule">${esc(h.rule)}</span></article>`).join("")}</div></div>`;
  const watch=`<div class="box stack"><div class="sechead"><h2>Wat je bijhoudt</h2><span class="muted small">Waar het kan, worden de cijfers automatisch bijgewerkt</span></div>
    <div class="tbl wl"><table><thead><tr><th>Cyclus</th><th>Cijfer</th><th class="r">Nu</th><th>Stand</th><th>Grenzen</th></tr></thead><tbody>
    ${WATCH.map(w=>{ const it=item(w.key), v=it&&typeof it.value==="number"? it.value : null, lv=v==null? null : w.band(v);
      return `<tr><td class="muted">${esc(w.g)}</td><td><b style="font-weight:500">${esc(w.l)}</b>${it?.asOf? `<div class="faint small">${esc(it.asOf)}</div>`:""}</td><td class="r"><span class="num">${esc(valOf(w.key))}</span></td>
        <td>${lv? `<span class="pill ${LV[WL_DOT[lv]].tone}">${lv==="rood"?"Rood":lv==="oranje"?"Let op":"Rustig"}</span>` : `<span class="pill t-neutral">Onbekend</span>`}</td><td class="muted small">${esc(w.rule)}</td></tr>`; }).join("")}
    </tbody></table></div>
    <p class="faint small">Specifiek voor jou: AI-investeringen en de chipcyclus (SMH), USDC in omloop en de rente (Circle).</p></div>`;

  const src=`<details class="box"><summary style="cursor:pointer"><b>Bronnen voor de cijfers</b> <span class="muted small">(${CRASH_SOURCES.length})</span></summary>
    <ul class="small" style="margin:10px 0 0;padding-left:18px;columns:2 300px;column-gap:28px">${CRASH_SOURCES.map(([l,u])=>`<li><a href="${esc(u)}" target="_blank" rel="noopener">${esc(l)}</a></li>`).join("")}</ul>
    <p class="faint small" style="margin-top:10px">Geschiedenis herhaalt zich niet precies. Dit overzicht laat zien hoe kwetsbaar de markt is, niet wanneer het misgaat. Geen beleggingsadvies.</p></details>`;

  el.innerHTML = hero + four + you + watch + cycles + longc + tl + tipping + crashes + charts + table + src;
  if(tipFor && !document.body.contains(tipFor)) hideTip();
}

/* ================= tooltip ================= */
const tipEl=document.createElement("div"); tipEl.id="tip"; tipEl.setAttribute("role","tooltip"); tipEl.hidden=true; document.body.appendChild(tipEl);
let tipFor=null;
function showTip(el, x, y){
  tipEl.textContent=el.getAttribute("data-tip")||""; tipEl.hidden=false; tipFor=el;
  const r=tipEl.getBoundingClientRect(), vw=window.innerWidth, vh=window.innerHeight;
  let left=x+14, top=y+14;
  if(left+r.width>vw-8) left=Math.max(8, x-r.width-14);
  if(top+r.height>vh-8) top=Math.max(8, y-r.height-14);
  tipEl.style.left=left+"px"; tipEl.style.top=top+"px";
}
function hideTip(){ tipEl.hidden=true; tipFor=null; }
function tipAt(el){ const r=el.getBoundingClientRect(); showTip(el, r.left+r.width/2, r.top+r.height/2); }
document.addEventListener("pointermove", (ev)=>{ if(ev.pointerType==="touch") return; const el=ev.target.closest?.("[data-tip]"); if(el) showTip(el, ev.clientX, ev.clientY); else if(tipFor) hideTip(); });
document.addEventListener("focusin", (ev)=>{ const el=ev.target.closest?.("[data-tip]"); let kb=false; try{ kb=el && el.matches(":focus-visible"); }catch(e){} if(kb) tipAt(el); });
document.addEventListener("focusout", ()=>hideTip());
document.addEventListener("click", (ev)=>{ const el=ev.target.closest?.("[data-tip]"); if(!el){ if(tipFor) hideTip(); return; } if(ev.pointerType==="mouse") return; if(tipFor===el) hideTip(); else tipAt(el); });
window.addEventListener("scroll", ()=>{ if(tipFor) hideTip(); }, {passive:true});

/* ================= PLAN ================= */
function renderPlan(){
  const p=S.plan;
  if(!p){ ["pl-top","pl-pos","pl-sc","pl-check"].forEach(id=>$(id).innerHTML=""); return; }
  const sc=arr(p.scenarios);
  $("pl-top").innerHTML = `<div class="grid g-2">
    <div class="box stack"><div class="sechead"><h2>Nu doen</h2><span class="eyebrow">Plan v${esc(p.meta?.version||1)} · ${esc(fmtDT(p.meta?.updatedAt))}</span></div>
      <ul class="actions">${arr(p.actionsNow).map(a=>`<li><span>${esc(a)}</span></li>`).join("")}</ul></div>
    <div class="box stack"><div class="sechead"><h2>Scenario's</h2><span class="muted small">kans</span></div>
      <div class="sbar" role="img" aria-label="${esc(sc.map(s=>s.name+" "+s.prob+"%").join(", "))}">${sc.map(s=>`<div style="flex-grow:${Math.max(0,+s.prob||0)};background:${SC_COLORS[s.id]||"var(--faint)"}">${s.prob>=10? esc(s.prob)+"%":""}</div>`).join("")}</div>
      <div class="slegend">${sc.map(s=>`<div class="it"><span class="sw" style="background:${SC_COLORS[s.id]||"var(--faint)"}"></span><span>${esc(s.name)}</span><span class="num">${esc(s.prob)}%</span></div>`).join("")}</div></div>
  </div>`;
  if(!document.activeElement?.closest?.("#pl-pos")) renderPositions();
  $("pl-sc").innerHTML = `<div class="stack"><div class="sechead"><h2>Scenario's in detail</h2><span class="muted small">Kansen zijn inschattingen; een bron kan ze per keer met maximaal 10 punt verschuiven</span></div>
    <div class="grid g-2e">${sc.map(s=>`<article class="box sc stack" style="--c:${SC_COLORS[s.id]||"var(--faint)"}">
      <div class="hd"><div><span class="eyebrow">${esc(s.horizon||"")}</span><h3 style="margin-top:3px">${esc(s.name)}</h3></div><div class="prob">${esc(s.prob)}%</div></div>
      <p class="small">${esc(s.desc)}</p>
      <div><span class="eyebrow">Herken je aan</span><div class="chips" style="margin-top:5px">${arr(s.signals).map(x=>`<span class="chip">${esc(x)}</span>`).join("")}</div></div>
      <div><span class="eyebrow">Effect op je posities</span><div class="scrow">${POS_IDS.map(id=>`<div>${impactCell(s.impact?.[id])}<span>${esc(POS_SHORT[id])}</span></div>`).join("")}</div></div>
      <div><span class="eyebrow">Wat je dan doet</span><ul class="actions">${arr(s.actions).map(a=>`<li><span>${esc(a)}</span></li>`).join("")}</ul></div>
    </article>`).join("")}</div>
    <details class="box"><summary style="cursor:pointer"><b>Gewogen impact per positie</b> <span class="muted small">(kans × effect)</span></summary>
      <div class="tbl" style="margin-top:10px"><table><thead><tr><th>Scenario</th><th class="c">Kans</th>${POS_IDS.map(id=>`<th class="c">${esc(POS_SHORT[id])}</th>`).join("")}</tr></thead>
      <tbody>${sc.map(s=>`<tr><td>${esc(s.name)}</td><td class="c num">${esc(s.prob)}%</td>${POS_IDS.map(id=>`<td class="c">${impactCell(s.impact?.[id])}</td>`).join("")}</tr>`).join("")}
      <tr><td><b>Gewogen</b></td><td class="c num">100%</td>${POS_IDS.map(id=>{ const w=sc.reduce((a,s)=>a+(s.prob||0)*(s.impact?.[id]||0),0)/100; return `<td class="c"><span class="num">${w>0?"+":""}${nf(w,2)}</span></td>`; }).join("")}</tr></tbody></table></div>
    </details></div>`;
  const pc=p.portfolioCheck, r=p.regime||{};
  $("pl-check").innerHTML = pc? `<div class="grid g-2e">
    <div class="box stack check"><span class="eyebrow">Portefeuille-check</span><h2>${esc(pc.headline)}</h2><ul>${arr(pc.points).map(x=>`<li>${esc(x)}</li>`).join("")}</ul></div>
    <div class="box stack"><span class="eyebrow">Veranderd sinds het juli-plan</span><ul class="actions">${arr(r.changesSinceJuly).map(x=>`<li><span>${esc(x)}</span></li>`).join("")}</ul></div></div>` : "";
}
function renderPositions(){
  const p=S.plan, m=p.macro;
  const sc=arr(p.scenarios);
  const ws=arr(p.positions).map(x=>x.myWeight).filter(v=>typeof v==="number"), sum=ws.reduce((a,b)=>a+b,0);
  $("pl-pos").innerHTML = `<div class="stack"><div class="sechead"><h2>Posities</h2><span class="muted small">Klik open voor regels, niveaus en scenario's. Je weging wordt bewaard.</span></div>
  ${arr(p.positions).map((x,ix)=>{ const pi=m?.positionImpact?.[x.id]||{}; return `<details class="pos" ${S.openPos===x.id?"open":""} data-pos="${esc(x.id)}">
    <summary><div><span class="eyebrow">${esc(x.role||"")}</span><h3 style="margin-top:2px">${esc(x.name)}</h3></div><span style="display:flex;gap:8px;align-items:center">${dirMark(pi.dir)}${stancePill(x.stance)}</span><span class="chev" aria-hidden="true"></span>
      <span class="sumwhy"><b style="color:var(--ink);font-weight:600">${esc(x.stanceNote||"")}</b></span></summary>
    <div class="posbody">
      <div class="sechead" style="padding-top:12px"><span class="muted mono small">${esc(x.tickers||"")}</span>
        <div class="weight"><label for="w-${ix}" style="margin:0">Mijn weging</label><input id="w-${ix}" data-ix="${ix}" class="wIn" inputmode="decimal" placeholder="%" value="${x.myWeight==null?"":esc(x.myWeight)}" ${S.canWrite&&S.db?"":"disabled"}><span>%</span></div></div>
      ${pi.why? `<p><b>Marktbeeld nu:</b> ${esc(pi.why)}</p>`:""}
      <p>${esc(x.now||"")}</p>
      <div class="cols2"><div><span class="eyebrow">Wind mee</span><ul class="blist plus">${arr(x.bull).map(b=>`<li><span>${esc(b)}</span></li>`).join("")}</ul></div>
        <div><span class="eyebrow">Wind tegen</span><ul class="blist minus">${arr(x.bear).map(b=>`<li><span>${esc(b)}</span></li>`).join("")}</ul></div></div>
      <div><span class="eyebrow">Niveaus</span><div class="levels">${arr(x.levels).map(l=>`<div class="level"><b>${esc(l.label)}</b><span>${esc(l.meaning)}</span></div>`).join("")}</div></div>
      <div><span class="eyebrow">Planregels</span><ol class="rules">${arr(x.rules).map(r=>`<li><span>${esc(r)}</span></li>`).join("")}</ol></div>
      <div class="cols2"><div><span class="eyebrow">Per scenario</span><div class="scrow">${sc.map(s=>`<div>${impactCell(s.impact?.[x.id])}<span>${esc(s.name)}</span></div>`).join("")}</div></div>
        <div><span class="eyebrow">Momenten</span><div class="chips" style="margin-top:8px">${arr(x.catalysts).map(c=>`<span class="chip">${esc(c)}</span>`).join("")}</div></div></div>
    </div></details>`; }).join("")}
  ${ws.length? `<div class="notice ${sum>100?"bad":""}">Ingevulde wegingen samen: <b class="num">${nf(sum,1)}%</b>. ${sum<100? "De rest ("+nf(100-sum,1)+"%) is cash of overig: je droog kruit." : sum>100? "Meer dan 100%: controleer je invoer." : "Geen cashbuffer."}</div>`:""}</div>`;
  $("pl-pos").querySelectorAll("details.pos").forEach(d=>d.addEventListener("toggle",()=>{ if(d.open) S.openPos=d.dataset.pos; else if(S.openPos===d.dataset.pos) S.openPos=null; }));
  $("pl-pos").querySelectorAll(".wIn").forEach(inp=>inp.addEventListener("change", ()=>saveWeight(+inp.dataset.ix, inp.value)));
}
async function saveWeight(ix, raw){
  const v = raw.trim()==="" ? null : Number(raw.replace(",","."));
  if(v!==null && (!isFinite(v)||v<0||v>100)){ notice("Weging moet een getal tussen 0 en 100 zijn.", true); return; }
  const positions=clone(S.plan.positions); positions[ix].myWeight=v;
  try{ await S.db.doc("plan/current").update({positions}); }catch(e){ notice(dbErrText(e), true); }
}

/* ================= SIGNALEN ================= */
function renderSignals(){
  const p=S.plan, el=$("sig-body");
  if(!p){ el.innerHTML=""; return; }
  const all=arr(p.triggers).map(t=>{ const {v,asOf}=trigValue(t); return {t,v,asOf,lv:trigLevel(t,v)}; });
  const cnt={stress:0,gespannen:0,rustig:0}; all.forEach(x=>{ if(cnt[x.lv]!=null) cnt[x.lv]++; });
  const groups=PILLAR_ORDER.map(pid=>({pid, rows: all.filter(x=>(x.t.pillar||"posities")===pid)})).filter(g=>g.rows.length);
  const ex=p.exposure;
  el.innerHTML = `<div class="box stack">
    <div class="sechead"><h2>Signalen</h2><div class="sigsum"><span class="pill t-bad">${cnt.stress} rood</span><span class="pill t-warn">${cnt.gespannen} oranje</span><span class="pill t-good">${cnt.rustig} groen</span></div></div>
    <p class="secintro">Groen = geen actie. Oranje = let op. Rood = de bijbehorende planregel controleren. ${S.local? "Ze worden bijgewerkt zodra je koersen of macrocijfers ververst (zie Uitleg)." : "Met meldingen aan (zie Uitleg) krijg je een bericht zodra een signaal op rood springt."}</p>
    ${groups.map(g=>`<div><div class="ind-gh"><h3>${esc(PILLAR_NAME[g.pid]||g.pid)}</h3></div>${g.rows.map(({t,v,asOf,lv})=>`
      <div class="trig"><div><div class="name">${esc(t.label)}</div><div class="faint small">${esc(asOf||"")}</div></div>${gauge(t,v)}
      <div class="val">${esc(fmtTrig(t,v))} ${lv? lvPill(lv) : `<span class="pill t-neutral">Onbekend</span>`}</div>
      <div class="meaning">${esc(t.meaning||"")} <span class="chips" style="display:inline-flex;margin-left:4px">${chipsFor(t.affects)}</span></div></div>`).join("")}</div>`).join("")}
  </div>
  ${ex? `<div class="box stack"><h2>Factorkaart</h2><p class="secintro">Hoe elke positie reageert als een factor stijgt. Kijk naar de kolom <b>Rente ↑</b>: drie van de vier posities lijden, alleen Circle profiteert.</p>
    <div class="tbl"><table><thead><tr><th>Positie</th>${ex.factors.map(f=>`<th class="c">${esc(f)}</th>`).join("")}</tr></thead>
    <tbody>${ex.rows.map(r=>`<tr><td>${esc(posName(r.id))}</td>${r.values.map(v=>`<td class="c">${impactCell(v)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>
    <p class="muted small">${esc(ex.note||"")}</p></div>`:""}
  <div class="box stack"><div class="sechead"><h2>Claimregister</h2><span class="muted small">Wat bronnen beweren, en of het uitkomt</span></div>
    <div class="tbl"><table><thead><tr><th>Claim</th><th>Bron</th><th>Status</th><th>Toelichting</th></tr></thead><tbody>
    ${arr(p.claims).map(c=>{ const tone=c.status==="bevestigd"?"t-good":c.status==="weerlegd"?"t-bad":"t-neutral"; return `<tr><td style="min-width:220px">${esc(c.text)}</td><td><span class="muted small">${esc(c.source||"")}<br>${esc(fmtDate(c.date))}</span></td><td><span class="pill ${tone}">${esc(c.status||"open")}</span></td><td class="muted small">${esc(c.note||"")}</td></tr>`; }).join("")}
    </tbody></table></div></div>`;
}
function gauge(t, v){
  const lo=Math.min(t.warn,t.danger), hi=Math.max(t.warn,t.danger), span=(hi-lo)||1;
  const min=lo-span*1.6, max=hi+span*1.0, pct=x=>clamp((x-min)/(max-min)*100,0,100);
  const a=pct(lo), b=pct(hi);
  const z = t.dir==="up" ? [["var(--good-soft)",a],["var(--warn-soft)",b-a],["var(--bad-soft)",100-b]] : [["var(--bad-soft)",a],["var(--warn-soft)",b-a],["var(--good-soft)",100-b]];
  const lab = t.dir==="up" ? [fmtTrig(t,t.warn)+" let op", fmtTrig(t,t.danger)+" alarm"] : [fmtTrig(t,t.danger)+" alarm", fmtTrig(t,t.warn)+" let op"];
  return `<div class="gwrap"><div class="gauge">${z.map(q=>`<i style="background:${q[0]};width:${q[1].toFixed(1)}%"></i>`).join("")}</div>${v==null?"":`<span class="gd" style="left:${pct(v).toFixed(1)}%"></span>`}<div class="lab"><span>${esc(lab[0])}</span><span>${esc(lab[1])}</span></div></div>`;
}

/* ================= UITLEG ================= */
/* ---------- verbinding met Railway ---------- */
const CONN={data:null, err:null, busy:false, at:0, open:false, auto:false};
const CONN_SVC=[["database","Database","PostgreSQL op Railway"],["ai","AI","Analyseert mail en bijlagen"],["mail","E-mail","Leest je mail via IMAP"],["finnhub","Koersen","Finnhub (optioneel)"]];
const CONN_ST={ok:["t-good","Verbonden"],"let-op":["t-warn","Let op"],fout:["t-bad","Fout"],uit:["t-neutral","Niet ingesteld"]};
async function loadConn(force=false){
  if(!S.server) return;
  CONN.busy=true; renderConn();
  try{ CONN.data=await S.server.api("GET","/api/connections"+(force?"?force=1":"")); CONN.err=null; }
  catch(e){ CONN.err = e?.code==="unavailable"? "De server antwoordt met een fout. Kijk in Railway bij Deployments → Logs." : "Geen verbinding met je Railway-site. Draait de dienst, en heb je internet?"; }
  CONN.busy=false; CONN.at=Date.now();
  const bad = CONN.err || CONN.data?.overall==="fout";
  if(bad && !CONN.auto){ CONN.auto=true; CONN.open=true; }
  renderConn(); renderUitleg();
}
function connSummary(){
  if(S.local) return ["lokaal","Lokaal · niet op Railway"];
  if(CONN.err) return ["fout","Geen verbinding met Railway"];
  const d=CONN.data; if(!d) return ["", "Railway controleren…"];
  if(d.overall==="ok") return ["ok","Railway verbonden"];
  if(d.overall==="fout") return ["fout","Database niet bereikbaar"];
  const n=d.missing.length; return ["deels", n===1? `${CONN_SVC.find(x=>x[0]===d.missing[0])?.[1]||d.missing[0]} niet verbonden` : `${n} koppelingen niet verbonden`];
}
function connAct(k,v){
  const out=[];
  if(k==="database" && v.ms!=null && v.state==="ok") out.push(`antwoord in ${v.ms} ms`);
  if(k==="ai"){ if(v.lastUse) out.push("laatste analyse "+ago(v.lastUse)); const b=v.backlog||{}; const w=(b.nieuw||0)+(b.wacht||0); if(w) out.push(`${w} wachten op analyse`); if(b.fout) out.push(`${b.fout} mislukt (zie Post)`); }
  if(k==="mail"){ const r=v.lastRun; if(r) if(r.ok || v.state==="ok") out.push(r.ok? "laatst opgehaald "+ago(r.at) : "laatste ronde mislukt: "+String(r.error||"zie logs").replace(/^\w+Error: /,"")); if(v.lastMail) out.push("laatste nieuwe mail "+ago(v.lastMail)); }
  if(k==="finnhub"){ if(v.quotesAt) out.push("koersen "+ago(v.quotesAt)); arr(v.quoteErrors).slice(0,1).forEach(e=>out.push(e)); }
  return out;
}
function renderConn(){
  const b=$("connBtn"), p=$("connPanel"); if(!b) return;
  if(!S.server && !S.local){ b.hidden=true; p.hidden=true; return; }
  const [cls,txt]=connSummary();
  b.hidden=false; b.className="connbtn "+cls+(CONN.busy&&!CONN.data&&!CONN.err?" busy":""); $("connText").textContent=txt;
  const sv=CONN.data?.services;
  $("connDots").innerHTML = sv && !CONN.err ? CONN_SVC.map(([k])=>`<b class="${esc(sv[k]?.state||"")}"></b>`).join("") : "";
  b.setAttribute("aria-expanded", CONN.open? "true":"false");
  b.title = sv && !CONN.err ? CONN_SVC.map(([k,n])=>`${n}: ${(CONN_ST[sv[k]?.state]||["","?"])[1]}`).join(" · ") : txt;
  p.hidden=!CONN.open; if(!CONN.open) return;
  if(S.local){ p.innerHTML=`<div class="sechead"><h2>Lokale versie</h2><button class="btn sm" type="button" data-conn="close">Sluiten</button></div>
    <p>Dit bestand draait helemaal in Chrome en is <b>niet verbonden met Railway</b>: geen database, geen mail en geen Grok. Open je Railway-site om alles via de server te laten lopen.</p>`; bindConn(); return; }
  const srv=CONN.data?.server;
  const cards = CONN.err? `<div class="notice bad"><b>${esc(CONN.err)}</b> De site laat de laatst geladen gegevens zien; zodra de server weer antwoordt, wordt alles vanzelf bijgewerkt.</div>`
    : !sv? `<p class="muted">Koppelingen testen…</p>`
    : `<div class="cgrid">${CONN_SVC.map(([k,name,sub])=>{ const v=sv[k]||{}; const [tone,lab]=CONN_ST[v.state]||["t-neutral","Onbekend"]; const act=connAct(k,v);
        return `<article class="csvc ${esc(v.state||"")}"><div class="sechead"><h3>${esc(name)}</h3><span class="pill ${tone}">${lab}</span></div>
          <span class="muted small">${esc(sub)}</span><span>${esc(v.detail||"")}</span>${act.length? `<span class="act">${act.map(esc).join(" · ")}</span>`:""}</article>`; }).join("")}</div>`;
  p.innerHTML = `<div class="sechead"><h2>Verbinding met Railway</h2><span class="btnrow"><button class="btn sm" type="button" data-conn="test" ${CONN.busy?"disabled":""}>${CONN.busy?"Testen…":"Opnieuw testen"}</button><button class="btn sm" type="button" data-conn="close">Sluiten</button></span></div>
    ${cards}
    <div class="cfoot"><span>${srv? `Server ${srv.railway? "op Railway"+(srv.environment? " ("+esc(srv.environment)+")":"") : "draait"}${srv.version? " · versie "+esc(srv.version):""} · gestart ${esc(fmtDT(srv.startedAt))}` : ""}</span>
      <span>${CONN.at? "Getest om "+esc(new Intl.DateTimeFormat("nl-NL",{hour:"2-digit",minute:"2-digit",timeZone:"Europe/Amsterdam"}).format(new Date(CONN.at))) : ""}</span>
      <span>Verbindingen worden elke minuut gecontroleerd; mail en API's elke 5 minuten echt getest.</span></div>`;
  bindConn();
}
function bindConn(){
  $("connPanel").querySelectorAll("[data-conn]").forEach(x=>x.addEventListener("click",()=>{
    if(x.dataset.conn==="close"){ CONN.open=false; renderConn(); $("connBtn").focus(); }
    if(x.dataset.conn==="test") loadConn(true);
  }));
}
async function loadServerStatus(){ if(!S.server) return; try{ S.srvStatus = await S.server.status(); }catch(e){ S.srvStatus=null; } renderUitleg(); if(S.tab==="post" && PO.docs && !poBusyTyping()) renderPost(); }
const JOB_NAME={post:"mail ophalen en analyseren", koersen:"koersen ophalen", markt:"koersen ophalen (Twelve Data)", dagelijks:"macrocijfers ophalen", melding:"testmelding sturen"};
function renderUitleg(){
  if(document.activeElement?.closest?.("#kForm")) return;   // niet wissen wat je aan het typen bent
  const st=S.srvStatus;
  const row=(ok,name,desc,extra="",off="Nog niet gekoppeld",key="")=>{ const v=key && !CONN.err ? CONN.data?.services?.[key] : null;
    const pill = v? `<span class="pill ${(CONN_ST[v.state]||["t-neutral"])[0]}">${(CONN_ST[v.state]||["","Onbekend"])[1]}</span>` : ok? `<span class="pill t-good">Ingesteld</span>` : `<span class="pill t-warn">${off}</span>`;
    return `<div class="conn"><b>${name}</b>${pill}<p>${desc}${extra}${v && v.state!=="ok" && v.detail? ` <b style="font-weight:500">${esc(v.detail)}</b>`:""}</p></div>`; };
  const J=st?.jobs||{};
  const last=(k)=>{ const l=J.last?.[k]; return l? ` Laatste run: ${esc(fmtDT(l.at))}${l.ok? "" : " (mislukt: "+esc(l.error||"zie logs")+")"}.` : ""; };
  const nx=(k)=> J.next?.[k]? ` Volgende: ${esc(fmtDT(J.next[k]))}.` : "";
  const ch=st?.notify||{}, chName=[ch.ntfy&&"de ntfy-app", ch.resend&&"e-mail (Resend)", ch.smtp&&"e-mail (SMTP)"].filter(Boolean).join(" en ");
  const conn = S.local ? localBox() : S.server ? (st? `<div class="box stack"><div class="sechead"><h2>Koppelingen</h2><span class="btnrow"><button class="btn sm" type="button" id="stRefresh">Opnieuw testen</button><button class="btn sm" type="button" data-act="logout">Uitloggen</button></span></div>
      ${!st.database? `<div class="notice bad"><b>De database is niet bereikbaar.</b> Controleer in Railway of de PostgreSQL-dienst draait en DATABASE_URL gekoppeld is.</div>`:""}
      <div>${row(st.database,"Database · PostgreSQL","Je plan, verwerkte mails, documenten, koersen en notities (DATABASE_URL).", "", "Niet bereikbaar", "database")}
      ${row(!!st.ai?.provider, st.ai?.provider==="claude"? "AI · Claude" : "AI · Grok", st.ai?.provider? `Analyseert e-mails, bijlagen en transcripts en beantwoordt vragen (model ${esc(st.ai.model||"")}).` : "Zet XAI_API_KEY in Railway om e-mails, bijlagen en transcripts te laten analyseren.", "", "Nog niet gekoppeld", "ai")}
      ${row(st.mail?.configured,"E-mail · IMAP", st.mail?.configured? `Leest map ${esc(st.mail.folder)} op ${esc(st.mail.host)}, alleen lezen; bijlagen worden omgezet naar tekst.` : "Zet EMAIL_HOST, EMAIL_PORT, EMAIL_USER en EMAIL_PASS in Railway.", last("post")+nx("post"), "Nog niet gekoppeld", "mail")}
      ${row(st.finnhub,"Koersen · Finnhub","Aandelen en ETF's van je volglijst elk kwartier; crypto via CoinGecko.", last("koersen")+nx("koersen"), "Optioneel", "finnhub")}
      ${row(st.fred||st.twelvedata,"Macrocijfers · FRED / Twelve Data","Rente, inflatie, banen en kredietspread voor de Markt-pagina (FRED_API_KEY, TWELVEDATA_API_KEY).", last("dagelijks"), "Optioneel")}
      ${row(ch.any,"Meldingen", ch.any? `Bericht via ${esc(chName)} zodra een signaal op rood springt.` : "Push naar je telefoon met de app ntfy: zet NTFY_TOPIC in Railway.", "", "Optioneel")}
      ${row(st.inboxToken,"Transcripts vanaf je laptop","Het script stuurt nieuwe video's automatisch naar je Inbox (INBOX_TOKEN).", "", "Optioneel")}</div>
      <div class="btnrow">
        <button class="btn sm" type="button" data-run="post" ${st.mail?.configured||st.ai?.provider?"":"disabled"}>Mail nu ophalen</button>
        <button class="btn sm" type="button" data-run="koersen">Koersen nu ophalen</button>
        <button class="btn sm" type="button" data-run="dagelijks" ${(st.fred||st.twelvedata)?"":"disabled"}>Macrocijfers nu ophalen</button>
        <button class="btn sm" type="button" data-run="melding" ${ch.any?"":"disabled"}>Testmelding sturen</button>
        <a class="btn sm" style="text-decoration:none" href="${esc(S.server.backupUrl||"/api/export")}" download>Back-up downloaden</a>
        <label class="btn sm" style="margin:0">Back-up terugzetten<input type="file" id="restoreIn" accept=".json,application/json" hidden></label>
      </div>
      <span class="status" id="runStatus" role="status">${J.running? "Bezig: "+esc(JOB_NAME[J.running]||J.running)+"…" : ""}</span>
      ${S.restoreFile? `<div class="notice bad stack" style="gap:8px"><span>Je plan en gegevens worden vervangen door <b>${esc(S.restoreFile.name)}</b>. De huidige stand wordt eerst apart bewaard.</span><span class="btnrow"><button class="btn sm primary" type="button" id="restoreGo">Terugzetten</button><button class="btn sm" type="button" id="restoreNo">Annuleren</button></span></div>`:""}
      ${arr(st.dailyErrors).length? `<details><summary class="muted small" style="cursor:pointer">Meldingen van de laatste macro-run (${st.dailyErrors.length})</summary><ul class="small muted">${st.dailyErrors.map(e=>`<li>${esc(e)}</li>`).join("")}</ul></details>`:""}
    </div>` : `<div class="box"><p class="muted">Status van koppelingen laden…</p></div>`)
    : `<div class="box"><p class="muted">Dit is de voorbeeldversie in Claude. Op plan.vsonsbeek.nl zie je hier welke koppelingen actief zijn.</p></div>`;
  $("ux-body").innerHTML = `${conn}
  <div class="box stack"><h2>Zo stroomt informatie door je site</h2>
    <div class="flow"><div class="st"><b>Bronnen</b><span class="muted small">${S.local? "Koersen (automatisch), macrocijfers (Claude zoekt ze op), transcripts (plakken)" : "Koersen en macrocijfers (automatisch), transcripts (plakken of laptop-script)"}</span></div><div class="ar">→</div>
    <div class="st"><b>${S.local? "Chrome" : "Server"}</b><span class="muted small">${S.local? "Bewaart alles op deze computer en rekent signalen uit" : "Slaat alles op en rekent signalen, trends en niveaus uit"}</span></div><div class="ar">→</div>
    <div class="st"><b>Claude</b><span class="muted small">Leest transcripts en cijfers, stelt wijzigingen voor</span></div><div class="ar">→</div>
    <div class="st"><b>Jij</b><span class="muted small">Keurt goed; alles komt in de historie en is terug te draaien</span></div></div></div>
  <div class="grid g-2e">
    <div class="box stack"><h3>Transcript toevoegen</h3><ul class="actions">
      <li><span>Open de video op YouTube (computer) → <b>…meer</b> → <b>Transcript weergeven</b> → alles selecteren en kopiëren.</span></li>
      <li><span>Ga naar <b>Inbox</b>, kies de bron, plak en klik <b>Analyseer</b>.</span></li>
      <li><span>Bron TradersReality of Rebel Capitalist? Dan wordt hun bril op de Markt-pagina bijgewerkt.</span></li></ul></div>
    <div class="box stack"><h3>${S.local? "Een nieuwe versie gebruiken" : "Je site bijwerken"}</h3>${S.local? `<ul class="actions">
        <li><span>Nieuwe versie van Claude gekregen? Open het nieuwe bestand gewoon in Chrome.</span></li>
        <li><span>Je plan, inbox en sleutels staan in Chrome, niet in het bestand, dus ze blijven staan.</span></li>
        <li><span>Gebruik steeds dezelfde Chrome op deze computer. Op een andere computer zet je eerst een back-up terug.</span></li></ul>` : `<ul class="actions">
        <li><span>Claude zet een nieuwe versie als pull request in je GitHub-repo.</span></li>
        <li><span>Open hem op github.com en klik <b>Merge pull request</b>.</span></li>
        <li><span>Railway zet de nieuwe versie binnen een paar minuten live. Je plan, gegevens en sleutels blijven staan.</span></li></ul>`}</div>
  </div>
  <div class="box stack"><h3>Exporteren</h3><div class="btnrow"><button class="btn sm" type="button" data-act="export" ${S.downloads?"":"disabled"}>Plan exporteren als Markdown</button><span class="status" id="exStatus"></span></div></div>`;
  $("stRefresh")?.addEventListener("click", ()=>{ loadServerStatus(); loadConn(true); });
  $("ux-body").querySelectorAll("[data-run]").forEach(b=>b.addEventListener("click", ()=>runJob(b.dataset.run)));
  $("restoreIn")?.addEventListener("change", (ev)=>{ const f=ev.target.files?.[0]; if(f){ S.restoreFile=f; renderUitleg(); } });
  $("restoreNo")?.addEventListener("click", ()=>{ S.restoreFile=null; renderUitleg(); });
  $("restoreGo")?.addEventListener("click", doRestore);
  if(S.local) bindLocal();
}


/* ================= POST: verwerkte e-mails en documenten ================= */
const PO={docs:null, quotes:null, notes:null, events:null, f:{q:"",type:"",relevance:""}, open:null, openText:"", msg:"", err:"", noteDel:null};
const DOC_TYPE_LABEL={transactiebevestiging:"Transactie", factuur:"Factuur", rekeningoverzicht:"Rekeningoverzicht", jaaropgave:"Jaaropgave", dividend:"Dividend", koersalert:"Koersalert", "insider-melding":"Insidermelding", nieuwsbrief:"Nieuwsbrief", analyse:"Analyse", overig:"Overig"};
const DOC_ST={nieuw:["t-warn","Wacht op analyse"], wacht:["t-warn","Wacht op analyse"], fout:["t-bad","Analyse mislukt"], overgeslagen:["t-neutral","Niet geanalyseerd"]};
const REL={hoog:["t-accent","Belangrijk"], middel:["t-warn","Middel"], laag:["t-neutral","Laag"]};
function money(a){ try{ return a.currency && /^[A-Z]{3}$/.test(a.currency)? new Intl.NumberFormat("nl-NL",{style:"currency",currency:a.currency}).format(a.value) : nf(a.value,2)+(a.currency? " "+a.currency:""); }catch(e){ return nf(a.value,2)+" "+(a.currency||""); } }
function poBusyTyping(){ const a=document.activeElement; return !!(a && a.closest && a.closest("#po-body") && /INPUT|TEXTAREA|SELECT/.test(a.tagName)); }
async function loadPost(quiet){
  if(!S.server) return;
  if(quiet && poBusyTyping()) return;
  const qs=new URLSearchParams(Object.entries(PO.f).filter(([,v])=>v));
  try{
    const [d,q,n,e]=await Promise.all([S.server.api("GET","/api/documents?"+qs), S.server.api("GET","/api/quotes"), S.server.api("GET","/api/notes"), S.server.api("GET","/api/events?limit=40")]);
    Object.assign(PO,{docs:d, quotes:q, notes:n.notes, events:e.events, err:""});
  }catch(err){ PO.err=err?.message||"De gegevens konden niet worden geladen. Probeer het zo opnieuw."; }
  if(quiet && poBusyTyping()) return;
  renderPost();
}
function poDoc(d){
  const title=d.kind==="email"? (d.subject||"(geen onderwerp)") : (d.filename||"bijlage");
  const rel=REL[d.relevance], st=d.status!=="geanalyseerd"? DOC_ST[d.status] : null;
  const chips=[...arr(d.tickers).map(t=>`<span class="chip">${esc(t)}</span>`), ...arr(d.companies).map(c=>`<span class="chip">${esc(c)}</span>`)].join("");
  return `<article class="po-doc">
    <div class="po-h">${rel? `<span class="pill ${rel[0]}">${rel[1]}</span>`:""}${st? `<span class="pill ${st[0]}">${st[1]}</span>`:""}${d.doc_type? `<span class="chip">${esc(DOC_TYPE_LABEL[d.doc_type]||d.doc_type)}</span>`:""}<b>${esc(title)}</b></div>
    <div class="po-meta">${d.kind==="bijlage"? "Bijlage bij “"+esc(d.subject||"")+"” · ":""}${esc(d.from_addr||"")}${d.received_at||d.created_at? " · "+esc(fmtDT(d.received_at||d.created_at)):""}</div>
    ${d.summary? `<p class="small">${esc(d.summary)}</p>`:""}
    ${d.error && d.status!=="geanalyseerd"? `<p class="small muted">${esc(d.error)}</p>`:""}
    ${chips? `<div class="chips">${chips}</div>`:""}
    ${arr(d.amounts).length? `<div class="po-amts">${d.amounts.map(a=>`<span class="po-amt">${esc(money(a))}${a.what? " · "+esc(a.what):""}</span>`).join("")}</div>`:""}
    ${arr(d.dates).length? `<ul class="po-dates">${d.dates.map(x=>`<li>${esc(fmtDate(x.date,{day:"numeric",month:"short",year:"numeric"}))}: ${esc(x.what||"")}</li>`).join("")}</ul>`:""}
    ${arr(d.actions).length? `<ul class="actions">${d.actions.map(x=>`<li><span>${esc(x)}</span></li>`).join("")}</ul>`:""}
    <div class="btnrow"><button class="btn sm" type="button" data-po="inbox" data-id="${d.id}">Naar plan-inbox</button><button class="btn sm" type="button" data-po="again" data-id="${d.id}">Opnieuw analyseren</button><button class="btn sm" type="button" data-po="text" data-id="${d.id}">${PO.open===d.id? "Tekst verbergen":"Tekst bekijken"}</button></div>
    ${PO.open===d.id? `<div class="answer small" style="max-height:340px;overflow:auto">${esc(PO.openText||"Laden…")}</div>`:""}
  </article>`;
}
function renderPost(){
  const el=$("po-body"); if(!el) return;
  if(!S.server){ el.innerHTML=`<div class="empty"><b>Alleen op je eigen site</b><span>Post en documenten werken op je Railway-site met e-mail en Grok.</span></div>`; return; }
  if(!PO.docs){ el.innerHTML = PO.err? `<div class="notice bad">${esc(PO.err)}</div>` : `<div class="empty"><b>Post laden…</b></div>`; return; }
  const D=PO.docs, c=D.counts||{}, st=S.srvStatus, Q=PO.quotes||{quotes:[]};
  const wait=(c.nieuw||0)+(c.wacht||0);
  const types=Object.keys(DOC_TYPE_LABEL);
  el.innerHTML = `${PO.err? `<div class="notice bad">${esc(PO.err)}</div>`:""}
  <div class="box stack">
    <div class="sechead"><div><span class="eyebrow">Post · e-mail en bijlagen</span><h2 style="margin-top:3px">Wat er binnenkwam</h2></div>
      <button class="btn sm primary" type="button" id="poRun">Mail nu ophalen</button></div>
    ${st && !st.mail?.configured? `<div class="notice bad">E-mail is nog niet gekoppeld: zet EMAIL_HOST, EMAIL_PORT, EMAIL_USER en EMAIL_PASS in Railway.</div>`:""}
    ${st && !st.ai?.provider? `<div class="notice bad">Grok is nog niet gekoppeld: zet XAI_API_KEY in Railway. Mails worden wel bewaard.</div>`:""}
    <div class="po-stats">
      <div class="po-stat"><b>${nf(c.geanalyseerd||0)}</b><span>Geanalyseerd</span></div>
      <div class="po-stat"><b>${nf(D.important||0)}</b><span>Belangrijk voor je plan</span></div>
      <div class="po-stat"><b>${nf(wait)}</b><span>Wacht op analyse</span></div>
      <div class="po-stat"><b>${nf(c.fout||0)}</b><span>Mislukt</span></div>
    </div>
    <p class="po-meta">${nf(D.mails||0)} e-mails gelezen${D.last?.at? " · laatste controle "+esc(fmtDT(D.last.at)):""}${st?.mail?.folder? " · map "+esc(st.mail.folder):""}</p>
    <span class="status" id="poStatus" role="status">${esc(PO.msg||"")}</span>
  </div>
  <div class="grid g-2">
    <div class="box stack">
      <form class="po-filters" id="poF" autocomplete="off">
        <div><label for="poQ">Zoeken</label><input id="poQ" value="${esc(PO.f.q)}" placeholder="Bedrijf, ticker of onderwerp"></div>
        <div><label for="poT">Soort</label><select id="poT"><option value="">Alle soorten</option>${types.map(t=>`<option value="${t}" ${PO.f.type===t?"selected":""}>${DOC_TYPE_LABEL[t]}</option>`).join("")}</select></div>
        <div><label for="poR">Belang</label><select id="poR"><option value="">Alles</option>${["hoog","middel","laag"].map(r=>`<option value="${r}" ${PO.f.relevance===r?"selected":""}>${REL[r][1]}</option>`).join("")}</select></div>
      </form>
      <div>${arr(D.documents).length? D.documents.map(poDoc).join("") : `<div class="empty"><b>${PO.f.q||PO.f.type||PO.f.relevance? "Niets gevonden met deze filters" : "Nog geen e-mails verwerkt"}</b><span>${st?.mail?.configured? "Nieuwe mails worden elk kwartier opgehaald. Klik op Mail nu ophalen om niet te wachten." : "Koppel eerst je e-mail in Railway."}</span></div>`}</div>
    </div>
    <div class="stack">
      <div class="box stack"><div class="sechead"><h3>Koersen</h3><span class="muted small">${Q.last?.at? "bijgewerkt "+esc(fmtDT(Q.last.at)):""}</span></div>
        ${!Q.finnhub? `<p class="small muted">Zet FINNHUB_API_KEY in Railway voor aandelen en ETF's. Crypto komt van CoinGecko.</p>`:""}
        <div>${arr(Q.quotes).map(r=>{ const ch=r.change_pct; return `<div class="qt"><span><b>${esc(r.symbol)}</b> <span class="muted small">${esc(r.name||"")}</span></span>
          <span class="num">${r.price!=null? "$"+nf(r.price, r.price>=1000?0:2) : "–"}</span>
          <span class="num small ${ch>0?"up":ch<0?"down":"muted"}">${ch!=null? (ch>0?"▲ +":ch<0?"▼ −":"")+nf(Math.abs(ch),2)+"%" : esc(r.error||"")}</span>
          <button class="xbtn" type="button" data-qdel="${esc(r.symbol)}" aria-label="${esc(r.symbol)} verwijderen">×</button></div>`; }).join("")}</div>
        <form class="btnrow" id="qAdd" autocomplete="off"><input id="qSym" placeholder="Symbool, bijv. AMD" aria-label="Symbool" style="flex:1 1 110px;width:auto"><select id="qKind" aria-label="Soort" style="flex:0 0 auto;width:auto"><option value="aandeel">Aandeel</option><option value="etf">ETF</option><option value="crypto">Crypto</option></select><button class="btn sm" type="submit">Toevoegen</button></form>
        <button class="btn sm" type="button" id="qRun" style="align-self:flex-start">Koersen nu ophalen</button>
      </div>
      <div class="box stack"><h3>Notities</h3>
        <form class="stack" id="nAdd" style="gap:8px" autocomplete="off"><textarea id="nBody" style="min-height:90px;font-family:var(--font-body);font-size:.9rem" placeholder="Bijv. CRCL bijkopen als hij onder de $80 sluit"></textarea><button class="btn sm primary" type="submit" style="align-self:flex-start">Notitie opslaan</button></form>
        <div>${arr(PO.notes).map(n=>`<div class="note"><span class="muted small">${esc(fmtDT(n.updated_at))}</span><button class="xbtn" type="button" data-ndel="${n.id}" aria-label="Notitie verwijderen">${PO.noteDel===n.id? "zeker?":"×"}</button><p>${esc(n.body)}</p></div>`).join("") || `<p class="muted small">Nog geen notities.</p>`}</div>
      </div>
      <div class="box stack"><h3>Logboek</h3>
        <div>${arr(PO.events).map(e=>`<div class="ev"><span class="pill ${e.level==="fout"?"t-bad":e.level==="let op"?"t-warn":"t-neutral"}">${esc(e.source)}</span><span class="muted">${esc(fmtDT(e.at))}</span><p>${esc(e.message)}</p></div>`).join("") || `<p class="muted small">Nog niets gebeurd.</p>`}</div>
      </div>
    </div>
  </div>`;
  const msg=(t,bad)=>{ PO.msg=t; setStatus($("poStatus"), t, bad); };
  $("poRun").addEventListener("click", async ()=>{ try{ const r=await S.server.run("post"); msg(r.started? "Mail wordt opgehaald en geanalyseerd; dit duurt meestal 10 seconden tot een paar minuten." : "Er loopt al een taak; probeer het zo opnieuw."); setTimeout(()=>loadPost(true), 15000); setTimeout(()=>loadPost(true), 60000); }catch(e){ msg("Starten lukte niet.", true); } });
  let tmr; const refilter=()=>{ PO.f={q:$("poQ").value.trim(), type:$("poT").value, relevance:$("poR").value}; clearTimeout(tmr); tmr=setTimeout(()=>loadPost(), 300); };
  $("poQ").addEventListener("input", refilter); $("poT").addEventListener("change", refilter); $("poR").addEventListener("change", refilter);
  $("poF").addEventListener("submit", ev=>ev.preventDefault());
  el.querySelectorAll("[data-po]").forEach(b=>b.addEventListener("click", async ()=>{
    const id=+b.dataset.id, what=b.dataset.po;
    try{
      if(what==="text"){ if(PO.open===id){ PO.open=null; renderPost(); return; } PO.open=id; PO.openText=""; renderPost(); const r=await S.server.api("GET","/api/documents/"+id); PO.openText=r.text||"(geen tekst)"; renderPost(); }
      if(what==="again"){ await S.server.api("POST","/api/documents/"+id+"/reanalyze"); msg("Opnieuw in de wachtrij; Grok analyseert hem zo."); setTimeout(()=>loadPost(true), 12000); }
      if(what==="inbox"){ await S.server.api("POST","/api/documents/"+id+"/to-inbox"); msg("In je plan-inbox gezet. Ga naar Inbox en klik Analyseer om plan-voorstellen te krijgen."); }
    }catch(e){ msg(e?.message||"Dat lukte niet.", true); }
  }));
  $("qAdd").addEventListener("submit", async ev=>{ ev.preventDefault(); const sym=$("qSym").value.trim(); if(!sym) return; try{ await S.server.api("POST","/api/watchlist",{symbol:sym, kind:$("qKind").value}); msg(sym.toUpperCase()+" toegevoegd; de koers volgt zo."); document.activeElement?.blur?.(); setTimeout(()=>loadPost(true), 6000); loadPost(); }catch(e){ msg(e?.message||"Toevoegen lukte niet.", true); } });
  el.querySelectorAll("[data-qdel]").forEach(b=>b.addEventListener("click", async ()=>{ try{ await S.server.api("DELETE","/api/watchlist/"+encodeURIComponent(b.dataset.qdel)); loadPost(); }catch(e){ msg("Verwijderen lukte niet.", true); } }));
  $("qRun").addEventListener("click", async ()=>{ try{ const r=await S.server.run("koersen"); msg(r.started? "Koersen worden opgehaald." : "Er loopt al een taak; probeer het zo opnieuw."); setTimeout(()=>loadPost(true), 8000); }catch(e){ msg("Starten lukte niet.", true); } });
  $("nAdd").addEventListener("submit", async ev=>{ ev.preventDefault(); const body=$("nBody").value.trim(); if(!body) return; try{ await S.server.api("POST","/api/notes",{body}); document.activeElement?.blur?.(); msg("Notitie opgeslagen."); loadPost(); }catch(e){ msg("Opslaan lukte niet.", true); } });
  el.querySelectorAll("[data-ndel]").forEach(b=>b.addEventListener("click", async ()=>{ const id=+b.dataset.ndel; if(PO.noteDel!==id){ PO.noteDel=id; renderPost(); return; } PO.noteDel=null; try{ await S.server.api("DELETE","/api/notes/"+id); loadPost(); }catch(e){ msg("Verwijderen lukte niet.", true); } }));
}

/* ================= losse Chrome-versie: instellingen ================= */
async function loadLocalStatus(){ if(!S.local) return; try{ S.localSt=await S.local.status(); }catch(e){ S.localSt=null; } renderUitleg(); }
function localBox(){
  const L=S.localSt;
  if(!L) return `<div class="box"><p class="muted">Instellingen laden…</p></div>`;
  const row=(ok,name,desc,off="Niet ingesteld")=>`<div class="conn"><b>${name}</b>${ok? `<span class="pill t-good">Actief</span>` : `<span class="pill t-warn">${off}</span>`}<p>${desc}</p></div>`;
  const lp=L.lastPrices, lm=L.lastMacro, M=S.macroProp;
  const store = L.storage==="idb"? `In Chrome op deze computer${L.persisted? " (blijvend bewaard)":""}. Maak af en toe een back-up.` : L.storage==="ls"? "In Chrome, met beperkte ruimte. Maak af en toe een back-up." : "Chrome bewaart op deze pagina niets: je wijzigingen verdwijnen als je hem sluit.";
  return `<div class="box stack">
    <div class="sechead"><h2>Instellingen</h2><span class="muted small">Deze versie draait helemaal in Chrome op deze computer</span></div>
    <div>${row(L.keys.anthropic,"Claude API","Analyseert transcripts, beantwoordt vragen en zoekt nieuwe macrocijfers op. Sleutel maken: platform.claude.com → API Keys."+(L.usage? ` Verbruik tot nu: ${nf(L.usage.input)} invoer- en ${nf(L.usage.output)} uitvoertokens${L.usage.searches? ", "+nf(L.usage.searches)+" zoekopdrachten":""}.`:""))}
    ${row(L.keys.twelvedata,"Koersen · Twelve Data",`Goud, zilver, USD/JPY, CRCL en de Mag 7-mand, elk halfuur zolang deze pagina open staat. Bitcoin komt van CoinGecko (zonder sleutel).${lp? " Laatst: "+esc(fmtDT(lp.at))+(lp.errors?.length? " · "+esc(lp.errors[0]):"")+"." : ""}`)}
    ${row(!!lm,"Macrocijfers",`Rente, inflatie, banen, kredietspread en de S&P 500: Claude zoekt ze online op en jij kiest wat je overneemt.${lm? " Laatst: "+esc(fmtDT(lm.at))+".":""}`,"Nog niet bijgewerkt")}
    ${row(L.storage!=="mem","Opslag",store,"Let op")}</div>
    <form class="stack" id="kForm" autocomplete="off" style="gap:10px">
      <div class="frow">
        <div><label for="kA">Claude API-sleutel</label><input id="kA" type="password" autocomplete="off" spellcheck="false" placeholder="${L.keys.anthropic? "ingesteld · plak een nieuwe om te vervangen" : "sk-ant-…"}"></div>
        <div><label for="kT">Twelve Data-sleutel</label><input id="kT" type="password" autocomplete="off" spellcheck="false" placeholder="${L.keys.twelvedata? "ingesteld · plak een nieuwe om te vervangen" : "gratis via twelvedata.com"}"></div>
      </div>
      <div class="btnrow"><button class="btn primary sm" type="submit">Sleutels opslaan</button>${(L.keys.anthropic||L.keys.twelvedata)? `<button class="btn sm" type="button" id="kClear">${S.kClearArm? "Zeker? Klik nogmaals" : "Sleutels wissen"}</button>`:""}<span class="status" id="kStatus" role="status"></span></div>
    </form>
    <div class="btnrow">
      <button class="btn sm" type="button" data-l="prices">Koersen nu ophalen</button>
      <button class="btn sm" type="button" data-l="macro" ${L.keys.anthropic?"":"disabled"}>Macrocijfers bijwerken met Claude</button>
      <button class="btn sm" type="button" data-l="export">Back-up downloaden</button>
      <label class="btn sm" style="margin:0">Back-up terugzetten<input type="file" id="lImport" accept=".json,application/json" hidden></label>
    </div>
    <span class="status" id="lStatus" role="status">${esc(S.localMsg||"")}</span>
    ${S.importFile? `<div class="notice bad stack" style="gap:8px"><span>Je huidige gegevens in Chrome worden vervangen door <b>${esc(S.importFile.name)}</b>. Download eerst een back-up als je de huidige stand wilt bewaren.</span><span class="btnrow"><button class="btn sm primary" type="button" id="imGo">Terugzetten</button><button class="btn sm" type="button" id="imNo">Annuleren</button></span></div>`:""}
    ${M? `<div class="box pending stack" style="gap:6px"><b>Nieuwe cijfers van Claude (${M.rows.length})</b>${M.note? `<p class="small muted">${esc(M.note)}</p>`:""}
      <div>${M.rows.map((r,i)=>`<label class="chg" for="mp-${i}"><input type="checkbox" id="mp-${i}" data-mp="${i}" ${r.on?"checked":""}><span><b>${esc(r.label)}</b> <span class="from">${esc(r.fromT)}</span> → <b>${esc(r.toT)}</b><br><span class="muted small">${esc([r.asOf,r.src].filter(Boolean).join(" · "))}</span></span></label>`).join("")}</div>
      <div class="btnrow"><button class="btn primary sm" type="button" id="mpApply" ${M.rows.length?"":"disabled"}>Overnemen</button><button class="btn sm" type="button" id="mpNo">Niet overnemen</button></div></div>`:""}
    <p class="faint small">Je sleutels staan alleen in deze browser. Gebruik dit bestand op je eigen computer en zet het niet openbaar online: er zit geen inlog op.</p>
  </div>`;
}
function bindLocal(){
  $("kForm")?.addEventListener("submit", async (ev)=>{
    ev.preventDefault();
    const a=$("kA").value.trim(), t=$("kT").value.trim();
    if(!a && !t){ setStatus($("kStatus"),"Plak eerst een sleutel.",true); return; }
    if(a && !/^sk-ant-/.test(a)){ setStatus($("kStatus"),"Een Claude-sleutel begint met sk-ant-.",true); return; }
    await S.local.saveKeys({anthropic:a||null, twelvedata:t||null});
    document.activeElement?.blur?.();
    S.sample=await window.claude.use("sample"); $("askBtn").disabled=!S.sample;
    S.localMsg="Sleutels opgeslagen."; await loadLocalStatus(); renderAll(); renderInbox();
    if(t) localAct("prices");
  });
  $("kClear")?.addEventListener("click", async ()=>{
    document.activeElement?.blur?.();
    if(!S.kClearArm){ S.kClearArm=true; renderUitleg(); return; }
    S.kClearArm=false; await S.local.clearKeys(); S.sample=null; $("askBtn").disabled=true;
    S.localMsg="Sleutels gewist."; await loadLocalStatus(); renderAll(); renderInbox();
  });
  $("ux-body").querySelectorAll("[data-l]").forEach(b=>b.addEventListener("click", ()=>localAct(b.dataset.l)));
  $("lImport")?.addEventListener("change", (ev)=>{ const f=ev.target.files?.[0]; if(f){ S.importFile=f; renderUitleg(); } });
  $("imNo")?.addEventListener("click", ()=>{ S.importFile=null; renderUitleg(); });
  $("imGo")?.addEventListener("click", doImport);
  $("ux-body").querySelectorAll("[data-mp]").forEach(cb=>cb.addEventListener("change", ()=>{ S.macroProp.rows[+cb.dataset.mp].on=cb.checked; }));
  $("mpApply")?.addEventListener("click", applyMacroProp);
  $("mpNo")?.addEventListener("click", ()=>{ S.macroProp=null; S.localMsg=""; renderUitleg(); });
}
function localMsg(msg, bad=false){ S.localMsg=msg; setStatus($("lStatus"), msg, bad); }
async function localAct(what){
  if(S.localBusy) return;
  S.localBusy=true;
  try{
    if(what==="export"){ const n=await S.local.exportBackup(); localMsg("Back-up gedownload: "+n+". Bewaar hem bijvoorbeeld in iCloud Drive."); }
    if(what==="prices"){ localMsg("Koersen ophalen…"); const r=await S.local.refreshPrices(); await loadLocalStatus(); localMsg(r.updated.length? `Bijgewerkt: ${r.updated.length} koers${r.updated.length===1?"":"en"}.${r.errors.length? " Let op: "+r.errors.join("; ")+".":""}` : (r.errors.length? r.errors.join("; ")+"." : "Geen koersen opgehaald."), !r.updated.length); }
    if(what==="macro"){ localMsg("Claude zoekt de nieuwste cijfers op. Dit duurt meestal 30 tot 90 seconden…"); const p=await S.local.findMacro(); S.macroProp=p; S.localMsg=p.rows.length? "Kies hieronder wat je overneemt." : "Claude vond geen nieuwere cijfers."; renderUitleg(); }
  }catch(e){ localMsg(e?.message||sampleErrText(e), true); }
  finally{ S.localBusy=false; }
}
async function applyMacroProp(){
  const P=S.macroProp; if(!P) return;
  const rows=P.rows.filter(r=>r.on); if(!rows.length){ localMsg("Vink minstens één cijfer aan.", true); return; }
  try{ const n=await S.local.applyMacro(rows); S.macroProp=null; S.localMsg=`${n} cijfer${n===1?"":"s"} bijgewerkt. Klik op Markt → "Marktstatus bijwerken met Claude" als je ook het oordeel wilt laten herzien.`; await loadLocalStatus(); }
  catch(e){ localMsg("Opslaan lukte niet.", true); }
}
async function doImport(){
  const f=S.importFile; if(!f) return;
  try{ const r=await S.local.importBackup(f); S.importFile=null; notice(`Back-up teruggezet (${r.docs} onderdelen). De pagina wordt ververst…`); setTimeout(()=>location.reload(), 1500); }
  catch(e){ S.importFile=null; renderUitleg(); notice(e?.message||"Terugzetten mislukt.", true); }
}
async function runJob(name){
  try{
    const r=await S.server.run(name);
    setStatus($("runStatus"), r.started? `Gestart: ${JOB_NAME[name]||name}. Dit duurt meestal 10 tot 90 seconden.` : `Er loopt al een taak (${JOB_NAME[r.running]||r.running}). Probeer het zo opnieuw.`);
    if(r.started){ setTimeout(loadServerStatus, 15000); setTimeout(loadServerStatus, 80000); }
  }catch(e){ setStatus($("runStatus"), "Starten lukte niet. Probeer het opnieuw.", true); }
}
async function doRestore(){
  const f=S.restoreFile; if(!f||!S.server?.restore) return;
  const btn=$("restoreGo"); if(btn) btn.disabled=true;
  setStatus($("runStatus"), "Terugzetten…");
  try{
    const r=await S.server.restore(f);
    S.restoreFile=null;
    notice(`Back-up teruggezet (${r.docs} onderdelen). De vorige stand is apart bewaard. De pagina wordt ververst…`);
    setTimeout(()=>location.reload(), 2500);
  }catch(e){ S.restoreFile=null; renderUitleg(); notice(e?.message||"Terugzetten mislukt.", true); }
}

/* ================= FOOTER ================= */
function renderFooter(){
  const p=S.plan;
  $("footer").innerHTML = `<p>${esc(p?.meta?.disclaimer || "Persoonlijk educatief plan. Geen beleggingsadvies.")} De brillen zijn een samenvatting van de aanpak van deze bronnen, geen eigen uitspraken van hen, tenzij ze uit een geplakt transcript komen.</p>
    ${arr(p?.sources).length? `<details><summary style="cursor:pointer">Bronnen bij dit plan (${p.sources.length})</summary><ul>${p.sources.map(s=>`<li><a href="${esc(s.url)}" target="_blank" rel="noopener">${esc(s.label)}</a></li>`).join("")}</ul></details>`:""}`;
}
async function exportMd(){
  const p=S.plan, st=$("exStatus"); if(!p||!S.downloads) return;
  const m=p.macro||{}, L=[];
  L.push(`# Handelsplan 2026 — v${p.meta?.version||1} (${fmtDate(p.meta?.updatedAt,{day:"numeric",month:"long",year:"numeric"})})`,"");
  if(m.headline){ L.push(`## Marktstatus: ${m.headline}`,"",`Regime: ${m.regime||""} · ${RISK[m.riskMode]?.label||""}`,"",m.summary||"","");
    arr(m.keyPoints).forEach(k=>L.push(`- **${k.title}** — ${k.text}`)); L.push("");
    L.push("### Pijlers",...arr(m.pillars).map(x=>`- **${x.name}** (${LV[pillarLevel(x).lv]?.label||""}): ${x.reading}`),"");
    arr(m.lenses).forEach(l=>{ L.push(`### Bril: ${l.name} (${l.who})`,"",...arr(l.checks).map(c=>`- ${c.q}: ${c.answer}`),"",`**Conclusie:** ${l.take}`,""); }); }
  if(m.cycle){ const cc=m.cycle; L.push(`## Cyclus: ${cc.verdict||""}`,"",cc.summary||"","",...arr(cc.cycles).filter(c=>CYCLE_DEF[c.id]).map(c=>`- **${CYCLE_DEF[c.id].name}**: ${phaseAt(c.id,+c.pos||0)} — ${c.why||""}`),"",
    "Kantelpunten:",...arr(cc.tipping).map(t=>`- ${t.label}: ${TP_LABEL[tipLevel(t)]||""}${t.now? " ("+t.now+")":""}`),""); }
  L.push("## Nu doen",...arr(p.actionsNow).map(a=>"- "+a),"");
  L.push("## Scenario's",...arr(p.scenarios).map(s=>`- **${s.name}** (${s.prob}%): ${s.desc}`),"");
  arr(p.positions).forEach(x=>{ L.push(`## ${x.name} — ${STANCES[x.stance]?.label||x.stance}`,"",x.stanceNote||"","",x.now||"","","Planregels:",...arr(x.rules).map((r,i)=>`${i+1}. ${r}`),""); });
  L.push("## Signalen",...arr(p.triggers).map(t=>{ const {v}=trigValue(t); return `- ${t.label}: ${fmtTrig(t,v)} (${LV[trigLevel(t,v)]?.label||"onbekend"}) — ${t.meaning}`; }),"");
  L.push("## Kalender",...arr(p.calendar).map(c=>`- ${c.date} ${c.time||""}: ${c.event} — ${c.why}`),"","---",p.meta?.disclaimer||"");
  try{ const r=await S.downloads.save({filename:`handelsplan-v${p.meta?.version||1}.md`, data:L.join("\n")}); setStatus(st, r?.status==="saved"?"Opgeslagen.":""); }
  catch(e){ if(e?.code!=="cancelled") setStatus(st,"Exporteren lukte niet.",true); }
}

/* ================= prompts ================= */
function planForPrompt(p){
  const q=clone(p); delete q.sources;
  q.triggers=arr(q.triggers).map(t=>{ const {v,asOf}=trigValue(t); return {...t, currentValue:v, currentAsOf:asOf, status:LV[trigLevel(t,v)]?.label||"onbekend"}; });
  return q;
}
function marketForPrompt(){ return arr(S.market?.items).map(i=>`${i.label}: ${itemText(i)} (${i.asOf||"?"}${i.change? "; "+i.change:""})`).join("\n") || "geen cijfers"; }
function levelsForPrompt(){ return arr(S.levels?.rows).map(r=>`${r.label}: slot ${r.last}, trend ${r.trend}, 50d ${r.ema50?.toFixed?.(2)}, 200d ${r.ema200?.toFixed?.(2)}, vorige week H ${r.prevWkHigh} / L ${r.prevWkLow}`).join("\n"); }
const MACRO_SCHEMA = `"macro":{"headline":null,"summary":null,"riskMode":null,"regime":null,"keyPoints":null,"compass":null,"pillars":[{"id":"rente","status":"stress","reading":"…"}],"positionImpact":null,"lens":null,"cycle":null}`;
const MACRO_RULES = `MARKTBEELD (changes.macro)
- headline/summary/regime/keyPoints alleen bij een echt ander beeld. keyPoints = precies 6 objecten {"tone":"bad|warn|good","title":"…","text":"…"}.
- riskMode: risk-on | neutraal | defensief | risk-off. compass: {"growth":-1..1,"inflation":-1..1,"why":"…"} (groei <0 = zwakker, inflatie >0 = stijgend).
- pillars: bestaande ids (inflatie, groei, rente, liquiditeit, dollar, krediet, sentiment); status rustig|gespannen|stress; reading 1–2 zinnen met cijfers.
- positionImpact: {"miners":{"dir":-1|0|1,"why":"…"},"crcl":…,"mag7":…,"insider":…}.
- cycle (optioneel): {"verdict":"…","summary":"…","cycles":[{"id":"sentiment|credit|economy","pos":0.57,"why":"…"}],"tipping":[{"id":"tp_fund|tp_fed","status":"rustig|gespannen|stress","now":"…"}]}. pos = plek op de golf: 0 = bodem, 0,5 = top, 1 = volgende bodem. Verschuif pos hooguit 0,08 per keer en alleen met een concrete reden uit de cijfers of de bron. Wees eerlijk over onzekerheid: een late fase kan jaren duren.`;
function analysisPrompt(meta, text){
  const lensId = SOURCE_LENS[meta.source]||null;
  const ids = {scenarios:arr(S.plan.scenarios).map(s=>s.id), macroTriggers:arr(S.plan.triggers).filter(t=>!t.computed && !(t.marketKey && item(t.marketKey))).map(t=>t.id)};
  const lens = lensId? arr(S.plan.macro?.lenses).find(l=>l.id===lensId) : null;
  return `Je bent de macro-analist achter het persoonlijke handelsplan van Floris (Nederlandse belegger, educatief gebruik). Posities: goud- en zilvermijnen (grootste), het aandeel Circle (CRCL), de Magnificent 7, en kleine aandelen op basis van politieke transactiemeldingen (Wolf of Washington).

TAAK: lees het nieuwe transcript of de notitie, haal eruit wat relevant is, en stel kleine, onderbouwde wijzigingen voor.

REGELS
- Scheid feiten (controleerbaar, met datum), meningen en voorspellingen van de spreker. Neem claims niet over als feit.
- De ACTUELE CIJFERS hieronder zijn de waarheid. Noemt de spreker andere cijfers, dan is het transcript waarschijnlijk ouder: weeg het lichter en zeg dat in caveats.
- Scenariokansen alleen bij nieuwe, concrete informatie; max ±10 procentpunt per scenario; totaal 100. Anders null.
- Houding per positie alleen wijzigen met een reden die naar een signaal of planregel verwijst (opbouwen, aanhouden, voorzichtig, afbouwen).
- Triggers met handmatige waarde bijwerken mag alleen voor: ${ids.macroTriggers.join(", ")}, met een recenter cijfer uit het transcript.
- Bij een Wolf of Washington-melding: toets aan de insider-planregels (leeftijd melding, positiegrootte, liquiditeit) en noem dat in keyPoints.
${lens? `- BRIL: de bron is ${meta.source}. Vul changes.macro.lens in met HUN visie uit dit transcript (niet de jouwe): {"id":"${lensId}","take":"hun conclusie in 2-3 zinnen","checks":[{"id":"bestaande-id","answer":"…","status":"rustig|gespannen|stress|info"}],"newChecks":[{"q":"…","answer":"…","status":"…"}]}. Bestaande check-ids: ${arr(lens.checks).map(c=>c.id).join(", ")}. Zegt het transcript niets over een check, laat die dan weg.` : `- changes.macro.lens = null (deze bron heeft geen eigen bril).`}
${MACRO_RULES}
- Schrijf in het Nederlands, kort en concreet. Lege lijsten zijn prima.

Antwoord met ALLEEN dit JSON-object:
{"summary":"3-5 zinnen: kernboodschap en wat het betekent voor Floris","keyPoints":["max 8 korte punten"],"claims":[{"text":"…","type":"feit|mening|voorspelling","note":"…"}],"signals":[{"indicator":"…","reading":"…","direction":"positief|negatief|neutraal","affects":["miners"]}],"changes":{"scenarioProbabilities":null,"positionStances":[{"id":"miners","stance":"aanhouden","note":"…","reason":"…"}],"triggers":[{"id":"t_fed","current":20,"asOf":"…","reason":"…"}],"calendarAdd":[{"date":"YYYY-MM-DD","time":"","event":"…","why":"…","affects":["mag7"]}],"actionsNow":null,${MACRO_SCHEMA}},"confidence":"laag|middel|hoog","caveats":["…"]}

VANDAAG: ${todayISO()}
HUIDIG PLAN (JSON):
${JSON.stringify(planForPrompt(S.plan))}

ACTUELE CIJFERS:
${marketForPrompt()}
${levelsForPrompt()? "\nNIVEAUBORD:\n"+levelsForPrompt() : ""}

NIEUW: bron "${meta.source}", titel "${meta.title||"(geen titel)"}", datum ${meta.date||"onbekend"}${meta.url? ", link "+meta.url:""}
---
${text}
---`;
}
function macroPrompt(){
  return `Je bent de macro-analist achter het handelsplan van Floris (posities: goud- en zilvermijnen, Circle/CRCL, Magnificent 7, kleine insider-aandelen). Werk het MARKTOVERZICHT bij op basis van de ACTUELE CIJFERS en SIGNALEN hieronder. Verander de brillen (lenses) niet. Wees precies met cijfers en noem ze.

${MACRO_RULES}
- Vul alleen in wat echt verandert; de rest null.

Antwoord met ALLEEN dit JSON-object:
{"summary":"wat er veranderd is in 2-3 zinnen","keyPoints":[],"claims":[],"signals":[],"changes":{${MACRO_SCHEMA}},"confidence":"laag|middel|hoog","caveats":["…"]}

VANDAAG: ${todayISO()}
HUIDIG MARKTOVERZICHT (JSON):
${JSON.stringify({...S.plan.macro, lenses:undefined})}

SIGNALEN:
${arr(S.plan.triggers).map(t=>{ const {v,asOf}=trigValue(t); return `${t.label}: ${fmtTrig(t,v)} (${LV[trigLevel(t,v)]?.label||"onbekend"}; ${asOf||""}) — drempels let op ${t.warn}, alarm ${t.danger}`; }).join("\n")}

ACTUELE CIJFERS:
${marketForPrompt()}
${levelsForPrompt()? "\nNIVEAUBORD:\n"+levelsForPrompt() : ""}`;
}

/* ================= ask the plan ================= */
$("askForm").addEventListener("submit", async (ev)=>{
  ev.preventDefault();
  const q=$("askQ").value.trim(); if(!q||!S.sample||!S.plan) return;
  const out=$("askOut"), st=$("askStatus"), btn=$("askBtn"), stop=$("askStop");
  S.askCtl=new AbortController(); btn.disabled=true; stop.hidden=false; out.hidden=false; out.textContent="Claude denkt na…"; setStatus(st,"");
  stop.onclick=()=>S.askCtl?.abort();
  const prompt = `Je bent de analist achter Floris' persoonlijke handelsplan (educatief, geen beleggingsadvies). Beantwoord zijn vraag in het Nederlands, kort en concreet (max ~180 woorden), op basis van ZIJN plan en het marktbeeld hieronder. Verwijs naar planregels (R1, R2…) en signalen die van toepassing zijn. Zeg het eerlijk als het plan er niets over zegt.\n\nPLAN (JSON):\n${JSON.stringify(planForPrompt(S.plan))}\n\nCIJFERS:\n${marketForPrompt()}\n\nVRAAG: ${q}`;
  try{ await S.sample(prompt,{signal:S.askCtl.signal, cache:false, onText:({text})=>{ out.textContent=text; }}); }
  catch(e){ if(e?.code!=="cancelled"){ out.textContent=e?.text||""; out.hidden=!e?.text; setStatus(st, sampleErrText(e), true); if(HIDE_CODES.includes(e?.code)) S.sample=null; } }
  finally{ btn.disabled=!S.sample; stop.hidden=true; }
});

/* ================= inbox ================= */
const inText=$("inText");
inText.addEventListener("input", ()=>{ const n=(inText.value.trim().match(/\S+/g)||[]).length; $("inWords").textContent = n? nf(n)+" woorden" : ""; });
$("inDate").value = todayISO();
function formMeta(){ return {source:$("inSource").value, title:$("inTitle").value.trim(), url:$("inUrl").value.trim(), date:$("inDate").value}; }
async function saveInbox(meta, text){
  const ref=S.db.collection("inbox").doc();
  await ref.set({...meta, text:text.slice(0,MAX_TEXT), truncated:text.length>MAX_TEXT, createdAt:new Date().toISOString(), status:"nieuw", addedBy:"hand"});
  return ref.id;
}
function clearForm(){ inText.value=""; $("inTitle").value=""; $("inUrl").value=""; $("inWords").textContent=""; }
$("inSave").addEventListener("click", async ()=>{
  const st=$("inStatus"), text=inText.value.trim();
  if(!S.db){ setStatus(st,"Opslag is niet beschikbaar in deze weergave.",true); return; }
  if(!text){ setStatus(st,"Plak eerst een transcript of notitie.",true); return; }
  setStatus(st,"Bewaren…");
  try{ await saveInbox(formMeta(), text); clearForm(); setStatus(st,"Bewaard in de inbox."); }catch(e){ setStatus(st, dbErrText(e), true); }
});
$("inForm").addEventListener("submit", async (ev)=>{
  ev.preventDefault();
  const st=$("inStatus"), text=inText.value.trim();
  if(!S.db){ setStatus(st,"Opslag is niet beschikbaar in deze weergave.",true); return; }
  if(!text){ setStatus(st,"Plak eerst een transcript of notitie.",true); return; }
  if(!S.plan){ setStatus(st,"Het plan is nog niet geladen.",true); return; }
  const meta=formMeta(); let id;
  try{ id=await saveInbox(meta, text); clearForm(); }catch(e){ setStatus(st, dbErrText(e), true); return; }
  runAnalysis(id, meta, text.slice(0,MAX_TEXT));
});
async function runAnalysis(inboxId, meta, text){
  const st=$("inStatus"), btn=$("inAnalyze"), stop=$("inStop");
  if(!S.sample){ setStatus(st,"Analyse met Claude is hier niet beschikbaar. Het transcript staat wel in de inbox.",true); return; }
  if(S.anaCtl){ setStatus(st,"Er loopt al een analyse.",true); return; }
  showTab("inbox");
  S.anaCtl=new AbortController(); btn.disabled=true; stop.hidden=false; stop.onclick=()=>S.anaCtl?.abort();
  setStatus(st,"Claude leest het transcript… meestal 30–90 seconden.");
  try{
    const res=await S.sample.json(analysisPrompt(meta, text), {modelTier:"complex", signal:S.anaCtl.signal, cache:false});
    if(!res || typeof res!=="object" || !res.summary) throw {code:"invalid_json"};
    const analysis=normalizeAnalysis(res);
    try{ await S.db.doc("inbox/"+inboxId).update({status:"geanalyseerd", analysis}); }catch(e){}
    S.pending={inboxId, meta, analysis, items:buildChangeItems(analysis, meta)};
    renderPending(); setStatus(st,"Analyse klaar. Kies bovenaan wat je overneemt.");
    window.scrollTo({top:0, behavior:"smooth"});
  }catch(e){
    if(e?.code==="cancelled") setStatus(st,"Gestopt. Het transcript staat in de inbox.");
    else { setStatus(st, sampleErrText(e), true); if(HIDE_CODES.includes(e?.code)) S.sample=null; }
  }finally{ S.anaCtl=null; btn.disabled=false; stop.hidden=true; }
}
async function refreshMacro(){
  const st=$("refreshStatus"), btn=$("refreshBtn");
  if(!S.sample||!S.plan?.macro) return;
  if(S.anaCtl){ setStatus(st,"Er loopt al een analyse.",true); return; }
  S.anaCtl=new AbortController(); if(btn) btn.disabled=true;
  setStatus(st,"Claude leest de cijfers… meestal 30–60 seconden.");
  try{
    const res=await S.sample.json(macroPrompt(), {modelTier:"complex", signal:S.anaCtl.signal, cache:false});
    if(!res || typeof res!=="object") throw {code:"invalid_json"};
    const analysis=normalizeAnalysis({summary:"", ...res});
    const meta={source:"Marktdata", title:"Marktstatus bijgewerkt", date:todayISO()};
    S.pending={inboxId:null, meta, analysis, items:buildChangeItems(analysis, meta)};
    renderPending(); setStatus($("refreshStatus"),"Voorstel klaar: zie bovenaan.");
    window.scrollTo({top:0, behavior:"smooth"});
  }catch(e){ setStatus($("refreshStatus"), sampleErrText(e), true); if(HIDE_CODES.includes(e?.code)) S.sample=null; }
  finally{ S.anaCtl=null; const b=$("refreshBtn"); if(b) b.disabled=!S.sample; }
}
function normalizeAnalysis(res){
  return {summary:String(res.summary||""), keyPoints:arr(res.keyPoints).map(String).slice(0,10), claims:arr(res.claims).slice(0,12), signals:arr(res.signals).slice(0,12),
    confidence:String(res.confidence||""), caveats:arr(res.caveats).map(String).slice(0,6), changes:res.changes||{}, at:new Date().toISOString()};
}

/* ================= change proposals ================= */
function buildChangeItems(a, meta){
  const p=S.plan, c=a.changes||{}, items=[];
  if(c.scenarioProbabilities && typeof c.scenarioProbabilities==="object"){
    const next={};
    arr(p.scenarios).forEach(s=>{ const raw=c.scenarioProbabilities[s.id]; const v=(typeof raw==="number"&&isFinite(raw))? raw : s.prob; next[s.id]=clamp(v, s.prob-10, s.prob+10); });
    const tot=Object.values(next).reduce((x,y)=>x+Math.max(0,y),0);
    if(tot>0){ let acc=0; const ids=Object.keys(next); ids.forEach((id,i)=>{ next[id]= i<ids.length-1? Math.round(Math.max(0,next[id])/tot*100) : 0; acc+=next[id]; }); next[ids[ids.length-1]]=100-acc;
      if(arr(p.scenarios).some(s=>next[s.id]!==s.prob)) items.push({kind:"probs", on:true, label:"Scenariokansen", from:arr(p.scenarios).map(s=>s.prob+"%").join(" / "), to:arr(p.scenarios).map(s=>next[s.id]+"%").join(" / "), detail:arr(p.scenarios).map(s=>s.name).join(" / "), data:next}); }
  }
  arr(c.positionStances).forEach(x=>{ const pos=arr(p.positions).find(q=>q.id===x?.id); if(!pos||!STANCES[x.stance]) return; if(x.stance===pos.stance && !x.note) return;
    items.push({kind:"stance", on:true, label:"Houding "+pos.name, from:STANCES[pos.stance]?.label, to:STANCES[x.stance].label, detail:[x.note,x.reason].filter(Boolean).join(" — "), data:{id:pos.id, stance:x.stance, note:x.note}}); });
  arr(c.triggers).forEach(x=>{ const t=arr(p.triggers).find(q=>q.id===x?.id); if(!t||t.computed) return; if(t.marketKey && item(t.marketKey)) return; const v=Number(x.current); if(!isFinite(v)) return;
    items.push({kind:"trigger", on:true, label:"Signaal "+t.label, from:fmtTrig(t,t.current), to:fmtTrig(t,v), detail:[x.asOf,x.reason].filter(Boolean).join(" — "), data:{id:t.id, current:v, asOf:x.asOf}}); });
  arr(c.calendarAdd).forEach(x=>{ if(!x||!/^\d{4}-\d{2}-\d{2}$/.test(String(x.date))||!x.event) return; if(arr(p.calendar).some(q=>q.date===x.date&&q.event===x.event)) return;
    items.push({kind:"calendar", on:true, label:"Kalender "+fmtDate(x.date), from:"", to:String(x.event), detail:String(x.why||""), data:{date:x.date, time:String(x.time||""), event:String(x.event), why:String(x.why||""), affects:arr(x.affects).filter(id=>POS_IDS.includes(id))}}); });
  if(Array.isArray(c.actionsNow) && c.actionsNow.length) items.push({kind:"actions", on:false, label:"‘Nu doen’-lijst vervangen", from:arr(p.actionsNow).length+" punten", to:c.actionsNow.length+" punten", detail:c.actionsNow.map(String).join(" · "), data:c.actionsNow.map(String).slice(0,6)});
  const m=c.macro||{}, pm=p.macro||{};
  if(p.macro){
    const kp = Array.isArray(m.keyPoints)&&m.keyPoints.length? m.keyPoints.filter(k=>k&&k.title).slice(0,6).map(k=>({tone:["bad","warn","good"].includes(k.tone)?k.tone:"warn", title:String(k.title), text:String(k.text||"")})) : null;
    const rm = RISK[m.riskMode]? m.riskMode : null;
    if(m.headline||m.summary||rm||m.regime||kp) items.push({kind:"macroText", on:true, label:"Marktstatus", from:pm.headline, to:m.headline||pm.headline, detail:[m.summary, rm? "Modus: "+RISK[rm].label:"", m.regime? "Regime: "+m.regime:"", kp? "6 nieuwe kernpunten":""].filter(Boolean).join(" · "), data:{headline:m.headline?String(m.headline):null, summary:m.summary?String(m.summary):null, riskMode:rm, regime:m.regime?String(m.regime):null, keyPoints:kp}});
    if(m.compass && isFinite(+m.compass.growth) && isFinite(+m.compass.inflation)) items.push({kind:"compass", on:true, label:"Regimekompas", from:`groei ${nf(pm.compass?.growth,2)} · inflatie ${nf(pm.compass?.inflation,2)}`, to:`groei ${nf(+m.compass.growth,2)} · inflatie ${nf(+m.compass.inflation,2)}`, detail:String(m.compass.why||""), data:{growth:clamp(+m.compass.growth,-1,1), inflation:clamp(+m.compass.inflation,-1,1), why:m.compass.why?String(m.compass.why):null}});
    arr(m.pillars).forEach(x=>{ const pl=arr(pm.pillars).find(q=>q.id===x?.id); if(!pl) return; const auto=pillarLevel(pl).auto;
      const st=(!auto && LV[x.status] && x.status!=="info" && x.status!==pl.status)? x.status : null; if(!st && !x.reading) return;
      items.push({kind:"pillar", on:true, label:"Pijler "+pl.name, from:st? LV[pl.status]?.label : "", to:st? LV[st].label : "nieuwe toelichting", detail:String(x.reading||""), data:{id:pl.id, status:st, reading:x.reading?String(x.reading):null}}); });
    if(m.positionImpact && typeof m.positionImpact==="object"){ const pi={}; POS_IDS.forEach(id=>{ const v=m.positionImpact[id]; if(v&&typeof v==="object") pi[id]={dir:clamp(Math.round(+v.dir||0),-1,1), why:String(v.why||"")}; });
      if(Object.keys(pi).length) items.push({kind:"impact", on:true, label:"Effect op je posities", from:"", to:"bijgewerkt", detail:Object.entries(pi).map(([k,v])=>`${POS_SHORT[k]} ${v.dir>0?"↑":v.dir<0?"↓":"→"}`).join(" · "), data:pi}); }
    const lensId=SOURCE_LENS[meta?.source]; const ln=m.lens;
    if(lensId && ln && typeof ln==="object" && (ln.take || arr(ln.checks).length || arr(ln.newChecks).length)){
      const lens=arr(pm.lenses).find(l=>l.id===lensId);
      if(lens) items.push({kind:"lens", on:true, label:"Bril "+lens.name, from:"", to:"bijgewerkt vanuit "+meta.source, detail:String(ln.take||""), data:{id:lensId, take:ln.take?String(ln.take):null,
        checks:arr(ln.checks).filter(x=>x&&x.id).map(x=>({id:String(x.id), answer:x.answer?String(x.answer):null, status:LV[x.status]?x.status:null})),
        newChecks:arr(ln.newChecks).filter(x=>x&&x.q).slice(0,3).map(x=>({id:"n"+Math.random().toString(36).slice(2,7), q:String(x.q), answer:String(x.answer||""), status:LV[x.status]?x.status:"info"}))}});
    }
    const cy=m.cycle, pcy=pm.cycle;
    if(cy && pcy && typeof cy==="object"){
      const cycles=arr(cy.cycles).map(x=>{ const o=arr(pcy.cycles).find(q=>q.id===x?.id); if(!o||!CYCLE_DEF[o.id]) return null;
        const old=+o.pos||0, raw=+x.pos; const pos=isFinite(raw)? clamp(clamp(raw, old-0.08, old+0.08),0,1) : null;
        if((pos===null || Math.abs(pos-old)<0.005) && !x.why) return null;
        return {id:o.id, pos, why:x.why?String(x.why):null, from:phaseAt(o.id,old), to:phaseAt(o.id, pos ?? old)}; }).filter(Boolean);
      const tips=arr(cy.tipping).map(x=>{ const t=arr(pcy.tipping).find(q=>q.id===x?.id); if(!t||t.key) return null;
        const st=(LV[x.status] && x.status!=="info")? x.status : null; if(!st && !x.now) return null; return {id:t.id, status:st, now:x.now?String(x.now):null}; }).filter(Boolean);
      if(cy.verdict||cy.summary||cycles.length||tips.length) items.push({kind:"cycle", on:true, label:"Cyclus", from:cy.verdict? pcy.verdict : "", to:cy.verdict? String(cy.verdict) : "bijgewerkt",
        detail:[cy.summary? String(cy.summary) : "", ...cycles.map(x=>`${CYCLE_DEF[x.id].name}: ${x.from} → ${x.to}`), tips.length? `${tips.length} kantelpunt(en) bijgewerkt` : ""].filter(Boolean).join(" · "),
        data:{verdict:cy.verdict?String(cy.verdict):null, summary:cy.summary?String(cy.summary):null, cycles, tips}});
    }
  }
  if(a.claims.length && meta?.source!=="Marktdata") items.push({kind:"claims", on:true, label:"Claimregister", from:"", to:a.claims.length+" claims toevoegen", detail:a.claims.map(x=>x?.text).filter(Boolean).slice(0,4).join(" · "), data:a.claims});
  return items;
}
function renderPending(){
  const P=S.pending, el=$("pendingPanel");
  if(!P){ el.hidden=true; el.innerHTML=""; return; }
  const a=P.analysis; el.hidden=false;
  el.innerHTML = `<div class="box pending stack">
    <div class="sechead"><div><span class="eyebrow">Voorstel · ${esc(P.meta.source)} · ${esc(fmtDate(P.meta.date))}</span><h2 style="margin-top:3px">${esc(P.meta.title||"Zonder titel")}</h2></div>
      ${a.confidence? `<span class="pill ${a.confidence==="hoog"?"t-good":a.confidence==="laag"?"t-bad":"t-warn"}">Betrouwbaarheid ${esc(a.confidence)}</span>`:""}</div>
    ${a.summary? `<p>${esc(a.summary)}</p>`:""}
    ${a.keyPoints.length? `<ul class="actions">${a.keyPoints.map(k=>`<li><span>${esc(k)}</span></li>`).join("")}</ul>`:""}
    ${a.signals.length? `<div class="tbl"><table><tbody>${a.signals.map(s=>`<tr><td>${esc(s?.indicator)}</td><td>${esc(s?.reading)}</td><td><span class="pill ${s?.direction==="positief"?"t-good":s?.direction==="negatief"?"t-bad":"t-neutral"}">${esc(s?.direction||"neutraal")}</span></td><td><div class="chips">${chipsFor(arr(s?.affects))}</div></td></tr>`).join("")}</tbody></table></div>`:""}
    ${a.caveats.length? `<div class="notice bad">${a.caveats.map(esc).join("<br>")}</div>`:""}
    <div><span class="eyebrow">Voorgestelde wijzigingen</span>
      ${P.items.length? P.items.map((it,ix)=>`<label class="chg" for="chg-${ix}"><input type="checkbox" id="chg-${ix}" data-ix="${ix}" ${it.on?"checked":""}>
        <span><b>${esc(it.label)}</b> ${it.from? `<span class="from">${esc(it.from)}</span> → `:""}<b>${esc(it.to)}</b><br><span class="muted small">${esc(it.detail)}</span></span></label>`).join("") : `<p class="muted">Geen wijzigingen voorgesteld: het plan blijft zoals het is.</p>`}
    </div>
    <div class="btnrow"><button class="btn primary" type="button" data-act="apply" id="apApply" ${S.canWrite&&S.db&&P.items.length?"":"disabled"}>Toepassen op plan</button><button class="btn" type="button" data-act="dismiss">Niet toepassen</button><span class="status" id="apStatus"></span></div>
  </div>`;
  el.querySelectorAll(".chg input").forEach(cb=>cb.addEventListener("change",()=>{ P.items[+cb.dataset.ix].on=cb.checked; }));
}
async function dismissPending(){ const P=S.pending; if(P?.inboxId){ try{ await S.db.doc("inbox/"+P.inboxId).update({status:"bewaard"}); }catch(e){} } S.pending=null; renderPending(); }
async function applyPending(){
  const P=S.pending, st=$("apStatus"); if(!P) return;
  const chosen=P.items.filter(i=>i.on); if(!chosen.length){ setStatus(st,"Vink minstens één wijziging aan.",true); return; }
  const before=clone(S.plan), p=clone(S.plan), log=[], now=new Date().toISOString();
  chosen.forEach(it=>{
    const d=it.data;
    if(it.kind==="probs"){ p.scenarios.forEach(s=>{ s.prob=d[s.id]; }); log.push(`Scenariokansen ${it.from} → ${it.to}`); }
    if(it.kind==="stance"){ const x=p.positions.find(q=>q.id===d.id); if(x){ x.stance=d.stance; if(d.note) x.stanceNote=String(d.note); log.push(`${x.name}: ${it.from} → ${it.to}`); } }
    if(it.kind==="trigger"){ const t=p.triggers.find(q=>q.id===d.id); if(t){ t.current=d.current; if(d.asOf) t.asOf=String(d.asOf); log.push(`${t.label}: ${it.from} → ${it.to}`); } }
    if(it.kind==="calendar"){ p.calendar=arr(p.calendar).concat([d]).sort((a,b)=>a.date.localeCompare(b.date)); log.push(`Kalender: ${d.date} ${d.event}`); }
    if(it.kind==="actions"){ p.actionsNow=d; log.push("‘Nu doen’-lijst vernieuwd"); }
    if(it.kind==="claims"){ const add=d.filter(c=>c&&c.text).map(c=>({text:String(c.text), source:P.meta.source+(P.meta.title? " · "+P.meta.title:""), date:P.meta.date||todayISO(), status:"open", note:[c.type,c.note].filter(Boolean).map(String).join(" — ")})); p.claims=add.concat(arr(p.claims)).slice(0,60); log.push(`${add.length} claims toegevoegd`); }
    if(p.macro){
      if(it.kind==="macroText"){ ["headline","summary","riskMode","regime","keyPoints"].forEach(k=>{ if(d[k]) p.macro[k]=d[k]; }); log.push("Marktstatus: "+(d.headline||p.macro.headline)); }
      if(it.kind==="compass"){ p.macro.compass={...(p.macro.compass||{}), growth:d.growth, inflation:d.inflation, ...(d.why? {why:d.why}:{})}; log.push(`Regimekompas: ${it.to}`); }
      if(it.kind==="pillar"){ const pl=p.macro.pillars.find(q=>q.id===d.id); if(pl){ if(d.status) pl.status=d.status; if(d.reading) pl.reading=d.reading; log.push(`Pijler ${pl.name}: ${it.to}`); } }
      if(it.kind==="impact"){ p.macro.positionImpact={...(p.macro.positionImpact||{}), ...d}; log.push("Effect op posities bijgewerkt"); }
      if(it.kind==="lens"){ const l=p.macro.lenses.find(q=>q.id===d.id); if(l){ if(d.take) l.take=d.take;
        d.checks.forEach(c=>{ const ck=l.checks.find(q=>q.id===c.id); if(ck){ if(c.answer) ck.answer=c.answer; if(c.status) ck.status=c.status; } });
        l.checks=l.checks.concat(d.newChecks).slice(0,9); l.updatedAt=now; l.basis=`Bijgewerkt uit ${P.meta.source}${P.meta.title? ": “"+P.meta.title+"”":""} (${fmtDate(P.meta.date)})`; log.push(`Bril ${l.name} bijgewerkt`); } }
      if(it.kind==="cycle" && p.macro.cycle){ const cc=p.macro.cycle; if(d.verdict) cc.verdict=d.verdict; if(d.summary) cc.summary=d.summary;
        d.cycles.forEach(x=>{ const o=arr(cc.cycles).find(q=>q.id===x.id); if(o){ if(x.pos!=null) o.pos=x.pos; if(x.why) o.why=x.why; } });
        d.tips.forEach(x=>{ const t=arr(cc.tipping).find(q=>q.id===x.id); if(t){ if(x.status) t.status=x.status; if(x.now) t.now=x.now; } });
        cc.updatedAt=now; log.push("Cyclus bijgewerkt"+(d.verdict? ": "+d.verdict : "")); }
    }
  });
  if(p.macro && chosen.some(i=>["macroText","compass","pillar","impact"].includes(i.kind))){ p.macro.updatedAt=now; p.macro.source = P.meta.source==="Marktdata"? "Bijgewerkt door Claude op basis van de cijfers" : `Bijgewerkt uit ${P.meta.source}`; }
  p.meta={...(p.meta||{}), version:(+p.meta?.version||1)+1, updatedAt:now, lastSource:`${P.meta.source}${P.meta.title? ": "+P.meta.title:""}`};
  setStatus(st,"Plan bijwerken…"); $("apApply").disabled=true;
  try{
    await S.db.doc("plan/current").set(p);
    await S.db.collection("history").doc().set({at:now, version:p.meta.version, source:P.meta.source, title:P.meta.title||"", inboxId:P.inboxId||"", changelog:log, summary:P.analysis.summary, planBefore:before});
    if(P.inboxId){ try{ await S.db.doc("inbox/"+P.inboxId).update({status:"verwerkt", appliedAt:now, appliedVersion:p.meta.version}); }catch(e){} }
    S.pending=null; renderPending(); notice(`Plan bijgewerkt naar v${p.meta.version}: ${log.length} wijziging${log.length===1?"":"en"}.`);
  }catch(e){ setStatus(st, dbErrText(e), true); $("apApply").disabled=false; }
}

/* ================= inbox list & history ================= */
const INBOX_STATUS={nieuw:["t-warn","Nieuw"], "transcript nodig":["t-warn","Transcript nodig"], geanalyseerd:["t-neutral","Geanalyseerd"], verwerkt:["t-good","Verwerkt"], bewaard:["t-neutral","Bewaard"]};
function renderInbox(){
  const el=$("inboxList"), list=S.inbox;
  const open=list.filter(i=>i.status==="nieuw"||i.status==="transcript nodig").length;
  const c=$("inboxCount"); c.hidden=!open; c.textContent=open;
  $("inboxMeta").textContent = list.length? `${list.length} item${list.length===1?"":"s"}` : "";
  if(!S.db && !S.offline){ el.innerHTML=`<p class="muted">Inbox laden…</p>`; return; }
  if(!list.length){ el.innerHTML=`<div class="empty"><b>De inbox is leeg</b><span>Plak hierboven je eerste transcript, of laat het laptop-script nieuwe video's toevoegen.</span></div>`; return; }
  el.innerHTML = list.map(i=>{ const s=INBOX_STATUS[i.status]||["t-neutral",i.status||"–"]; const a=i.analysis; return `
    <div class="item"><div class="h"><span class="pill ${s[0]}">${esc(s[1])}</span><b>${esc(i.title||"Zonder titel")}</b><span class="chip">${esc(i.source||"")}</span><span class="muted small">${esc(fmtDate(i.date))}${i.addedBy==="automatisch"?" · automatisch":""}</span>
      ${i.url? `<a href="${esc(i.url)}" target="_blank" rel="noopener" class="small">bron</a>`:""}
      ${(i.text && i.status!=="verwerkt")? `<button class="btn sm" type="button" data-ana="${esc(i.id)}" ${S.sample?"":"disabled"}>${i.status==="geanalyseerd"||i.status==="bewaard"?"Opnieuw analyseren":"Analyseer"}</button>`:""}</div>
      ${a?.summary? `<p class="small">${esc(a.summary)}</p>`:""}
      ${i.text? `<details><summary>Tekst bekijken (${nf((i.text.match(/\S+/g)||[]).length)} woorden${i.truncated?", ingekort":""})</summary><div class="pre muted small" style="max-height:320px;overflow:auto;margin-top:6px">${esc(i.text.slice(0,20000))}${i.text.length>20000?"\n…":""}</div></details>`:""}
    </div>`; }).join("");
}
function renderHistory(){
  const el=$("hist-body"), list=S.history;
  if(!list.length){ el.innerHTML=`<div class="empty"><b>Nog geen wijzigingen</b><span>Elke keer dat je een voorstel toepast of iets terugzet, verschijnt het hier.</span></div>`; return; }
  el.innerHTML = list.map(h=>`<div class="item"><div class="h"><span class="pill t-accent plain">v${esc(h.version)}</span><b>${esc(h.title||h.source||"")}</b><span class="muted small">${esc(fmtDT(h.at))} · ${esc(h.source||"")}</span>
      ${h.planBefore? `<button class="btn sm" type="button" data-undo="${esc(h.id)}" ${S.canWrite&&S.db?"":"disabled"}>${S.histConfirm===h.id?"Zeker? Klik nogmaals":"Terugzetten naar vóór deze stap"}</button>`:""}</div>
    ${h.summary? `<p class="muted small">${esc(h.summary)}</p>`:""}
    <ul class="blist plus">${arr(h.changelog).map(x=>`<li><span>${esc(x)}</span></li>`).join("")}</ul></div>`).join("");
}
async function undo(id){
  if(S.histConfirm!==id){ S.histConfirm=id; renderHistory(); return; }
  S.histConfirm=null;
  const h=S.history.find(x=>x.id===id); if(!h?.planBefore) return;
  const p=clone(h.planBefore), before=clone(S.plan);
  p.meta={...(p.meta||{}), version:(+S.plan?.meta?.version||1)+1, updatedAt:new Date().toISOString(), lastSource:`Teruggezet naar vóór v${h.version}`};
  try{ await S.db.doc("plan/current").set(p);
    await S.db.collection("history").doc().set({at:p.meta.updatedAt, version:p.meta.version, source:"Terugzetten", title:`Teruggezet naar vóór v${h.version}`, changelog:[`Plan teruggezet naar de stand vóór v${h.version}`], planBefore:before});
    notice(`Plan teruggezet (nu v${p.meta.version}).`);
  }catch(e){ notice(dbErrText(e), true); }
}

/* ================= notices & errors ================= */
let noticeTimer;
function notice(msg, bad=false){ const el=$("notice"); el.className="notice"+(bad?" bad":""); el.textContent=msg; el.hidden=false; clearTimeout(noticeTimer); noticeTimer=setTimeout(()=>{ el.hidden=true; }, 7000); }
function dbErrText(e){
  switch(e?.code){
    case "invalid_argument": return "Opslaan werd geweigerd. Mogelijk heb je alleen leesrechten, of is de tekst te lang.";
    case "quota_exceeded": return "De opslag is vol. Verwijder oude inbox-items en probeer opnieuw.";
    case "resource_exhausted": return "Te veel bewerkingen tegelijk. Wacht even en probeer opnieuw.";
    case "unavailable": return "Opslag tijdelijk niet bereikbaar. Probeer het zo opnieuw.";
    default: return "Opslaan lukte niet. Probeer het opnieuw.";
  }
}
function sampleErrText(e){
  switch(e?.code){
    case "not_granted": return "Claude-toegang voor deze pagina is niet toegestaan.";
    case "sampling_disabled": case "not_declared": case "capability_disabled": case "capability_removed": return "Claude is hier niet beschikbaar.";
    case "rate_limited": return "Je Claude-limiet of API-tegoed is even op. Probeer het later opnieuw.";
    case "prompt_too_large": return "De tekst is te lang. Plak hem in delen.";
    case "invalid_json": return "Het antwoord was onleesbaar. Probeer het opnieuw.";
    case "refused": return "Claude wilde deze tekst niet verwerken.";
    case "session_expired": return "Je sessie is verlopen. Log opnieuw in.";
    default: return "De analyse is onderbroken. Controleer of je Claude API-sleutel is ingevuld en probeer het opnieuw.";
  }
}

/* ================= render & boot ================= */
function renderAll(){
  renderHeader();
  if(!document.activeElement?.closest?.("#mEditBody")) renderMarkt();
  renderCyclus(); renderPlan(); renderSignals(); renderUitleg(); renderFooter();
}
renderAll(); renderInbox(); renderHistory();

(async function boot(){
  if(!window.claude || typeof window.claude.use!=="function"){ S.offline=true; renderAll(); return; }
  const db=await window.claude.use("db");
  if(!db){ S.offline=true; renderAll(); renderInbox(); return; }
  S.db=db;
  const onErr=(e)=>{ if(e?.code==="revoked"){ S.offline=true; renderAll(); } else notice(dbErrText(e), true); };
  const seen={}; const changed=(k,d)=>{ const j=JSON.stringify(d??null); if(seen[k]===j) return false; seen[k]=j; return true; };
  db.doc("plan/current").onSnapshot(s=>{ const d=s.exists? s.data() : null; S.planLoaded=true; if(!changed("plan",d) && S.plan) return; S.plan=d; renderAll(); }, onErr);
  db.doc("market/latest").onSnapshot(s=>{ const d=s.exists? s.data() : null; if(!changed("market",d)) return; S.market=d; renderAll(); }, onErr);
  db.doc("market/series").onSnapshot(s=>{ const d=s.exists? (s.data().series||{}) : {}; if(!changed("series",d)) return; S.series=d; renderAll(); }, onErr);
  db.doc("market/levels").onSnapshot(s=>{ const d=s.exists? s.data() : null; if(!changed("levels",d)) return; S.levels=d; renderAll(); }, onErr);
  db.collection("inbox").orderBy("createdAt","desc").limit(60).onSnapshot(q=>{ const d=q.docs.map(x=>({id:x.id, ...x.data()})); if(!changed("inbox",d)) return; S.inbox=d; renderInbox(); }, onErr);
  db.collection("history").orderBy("at","desc").limit(40).onSnapshot(q=>{ const d=q.docs.map(x=>({id:x.id, ...x.data()})); if(!changed("history",d)) return; S.history=d; renderHistory(); }, onErr);
  window.claude.use("sample").then(s=>{ S.sample=s; $("askBtn").disabled=!s; renderAll(); renderInbox(); }).catch(()=>{});
  window.claude.use("downloads").then(d=>{ S.downloads=d; renderUitleg(); }).catch(()=>{});
  $("connBtn").addEventListener("click",()=>{ CONN.open=!CONN.open; renderConn(); if(CONN.open){ window.scrollTo({top:0,behavior:matchMedia("(prefers-reduced-motion: reduce)").matches?"auto":"smooth"}); if(S.server && Date.now()-CONN.at>20000) loadConn(); } });
  window.claude.use("server").then(sv=>{ if(sv){ S.server=sv; $("logoutBtn").hidden=false; $("tb-post").hidden=false; loadServerStatus(); loadConn(); if(S.tab==="post") loadPost();
    setInterval(()=>{ if(!document.hidden) loadConn(); }, 60000);
    document.addEventListener("visibilitychange",()=>{ if(!document.hidden && Date.now()-CONN.at>30000) loadConn(); });
    window.addEventListener("online",()=>loadConn()); window.addEventListener("offline",()=>{ CONN.err="Je bent offline."; renderConn(); });
    setInterval(()=>{ if(S.tab==="post" && !document.hidden) loadPost(true); }, 60000); } }).catch(()=>{});
  window.claude.use("local").then(l=>{ if(l){ S.local=l; renderConn(); loadLocalStatus(); window.addEventListener("hp-local", loadLocalStatus); } }).catch(()=>{});
  window.claude.use("user").then(async u=>{ if(!u) return; const c=await u.can("data.write"); if(c===false){ S.canWrite=false; renderAll(); } }).catch(()=>{});
})();
})();
</script>

</body></html>
HP_EINDE_APP_PAGES_INDEX_HTML

# ---- app/patch.py ----
COPY <<"HP_EINDE_APP_PATCH_PY" /app/app/patch.py
"""Voegt nieuwe onderdelen (macro-overzicht, extra triggers en cijfers) toe aan een bestaand plan,
zonder iets te overschrijven wat je zelf al hebt aangepast."""
import copy
import json
from pathlib import Path

PATCH_FILE = Path(__file__).resolve().parent.parent / "seed" / "macro_patch.json"


def load_patch():
    return json.loads(PATCH_FILE.read_text(encoding="utf-8"))


def apply(plan: dict | None, market: dict | None, patch: dict | None = None):
    patch = patch or load_patch()
    notes = []
    if plan is not None:
        if "macro" not in plan:
            plan["macro"] = copy.deepcopy(patch["macro"])
            notes.append("macro-overzicht toegevoegd")
        elif "cycle" not in plan["macro"] and "cycle" in patch["macro"]:
            plan["macro"]["cycle"] = copy.deepcopy(patch["macro"]["cycle"])
            notes.append("cyclus-analyse toegevoegd")
        trig = plan.setdefault("triggers", [])
        have = {t.get("id") for t in trig}
        for t in patch.get("triggersAdd", []):
            if t["id"] not in have:
                trig.append(copy.deepcopy(t))
                notes.append(f"trigger {t['id']} toegevoegd")
        for t in trig:
            p = patch.get("triggerPatch", {}).get(t.get("id"))
            if not p:
                continue
            for k, v in p.items():
                if k == "unit":
                    if t.get("unit") == "k" and v == "Δk":
                        t["unit"] = v
                elif not t.get(k):
                    t[k] = v
        srcs = plan.setdefault("sources", [])
        urls = {s.get("url") for s in srcs}
        for s in patch.get("sourcesAdd", []):
            if s["url"] not in urls:
                srcs.append(s)
    if market is not None:
        items = market.setdefault("items", [])
        keys = {i.get("key") for i in items}
        for it in patch.get("itemsAdd", []):
            if it["key"] not in keys:
                items.append(copy.deepcopy(it))
                notes.append(f"cijfer {it['key']} toegevoegd")
        for it in items:
            pil = patch.get("itemPillars", {}).get(it.get("key"))
            if pil and not it.get("pillar"):
                it["pillar"] = pil
    return plan, market, notes
HP_EINDE_APP_PATCH_PY

# ---- app/quotes.py ----
COPY <<"HP_EINDE_APP_QUOTES_PY" /app/app/quotes.py
"""Live koersen van wat je volgt: Finnhub (FINNHUB_API_KEY) voor aandelen en ETF's, CoinGecko voor crypto.

Werkt ook zonder Finnhub-sleutel: dan alleen crypto. Een limiet of storing wordt per symbool
vastgelegd; de andere koersen gaan gewoon door.
"""
import os
from datetime import datetime, timezone

import httpx

from . import db

DEFAULT_WATCHLIST = [
    ("CRCL", "Circle", "aandeel"), ("MAGS", "Mag 7-mand (ETF)", "etf"),
    ("NVDA", "Nvidia", "aandeel"), ("MSFT", "Microsoft", "aandeel"), ("AAPL", "Apple", "aandeel"),
    ("GOOGL", "Alphabet", "aandeel"), ("AMZN", "Amazon", "aandeel"), ("META", "Meta", "aandeel"), ("TSLA", "Tesla", "aandeel"),
    ("GDX", "Goudmijnen (ETF)", "etf"), ("SIL", "Zilvermijnen (ETF)", "etf"), ("BTC", "Bitcoin", "crypto"),
]
COINGECKO_IDS = {"BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana", "XRP": "ripple", "USDC": "usd-coin",
                 "ADA": "cardano", "DOGE": "dogecoin", "LINK": "chainlink", "AVAX": "avalanche-2", "DOT": "polkadot"}
# koppeling met de cijfers op de Markt-pagina
MARKET_KEYS = {"CRCL": "crcl", "MAGS": "mags", "BTC": "btc"}


def finnhub_key():
    return os.environ.get("FINNHUB_API_KEY", "")


def ensure_watchlist():
    with db.conn() as c:
        if c.execute("SELECT COUNT(*) AS n FROM watchlist").fetchone()["n"] == 0:
            for i, (s, n, k) in enumerate(DEFAULT_WATCHLIST):
                c.execute("INSERT INTO watchlist(symbol,name,kind,position) VALUES(%s,%s,%s,%s) ON CONFLICT DO NOTHING", (s, n, k, i))


def watchlist():
    with db.conn() as c:
        return c.execute("SELECT w.symbol, w.name, w.kind, q.price, q.change_pct, q.prev_close, q.source, q.fetched_at, q.error "
                         "FROM watchlist w LEFT JOIN quotes q ON q.symbol=w.symbol ORDER BY w.position, w.symbol").fetchall()


def _save(symbol, price=None, change=None, prev=None, source=None, error=None):
    with db.conn() as c:
        if error:
            c.execute("INSERT INTO quotes(symbol,error,fetched_at) VALUES(%s,%s,now()) "
                      "ON CONFLICT(symbol) DO UPDATE SET error=excluded.error", (symbol, error[:200]))
        else:
            c.execute("INSERT INTO quotes(symbol,price,change_pct,prev_close,source,fetched_at,error) VALUES(%s,%s,%s,%s,%s,now(),NULL) "
                      "ON CONFLICT(symbol) DO UPDATE SET price=excluded.price, change_pct=excluded.change_pct, "
                      "prev_close=excluded.prev_close, source=excluded.source, fetched_at=now(), error=NULL",
                      (symbol, price, change, prev, source))


def refresh():
    ensure_watchlist()
    rows = watchlist()
    out = {"updated": 0, "errors": []}
    key = finnhub_key()
    got = {}
    with httpx.Client(timeout=20) as h:
        for r in rows:
            sym, kind = r["symbol"], r["kind"]
            if kind == "crypto":
                continue
            if not key:
                continue
            try:
                resp = h.get("https://finnhub.io/api/v1/quote", params={"symbol": sym, "token": key})
                if resp.status_code == 429:
                    out["errors"].append("Finnhub: limiet bereikt (60 per minuut op het gratis abonnement)")
                    break
                if resp.status_code in (401, 403):
                    out["errors"].append("Finnhub: sleutel ongeldig of symbool niet in je abonnement")
                    _save(sym, error="geen toegang")
                    continue
                resp.raise_for_status()
                q = resp.json()
                if not q or not q.get("c"):
                    _save(sym, error="geen koers gevonden")
                    out["errors"].append(f"{sym}: geen koers")
                    continue
                _save(sym, q["c"], q.get("dp"), q.get("pc"), "Finnhub")
                got[sym] = (q["c"], q.get("dp"))
                out["updated"] += 1
            except (httpx.HTTPError, ValueError) as e:
                _save(sym, error=e.__class__.__name__)
                out["errors"].append(f"{sym}: {e.__class__.__name__}")
        crypto = [r["symbol"] for r in rows if r["kind"] == "crypto"]
        ids = {s: COINGECKO_IDS.get(s.upper(), s.lower()) for s in crypto}
        if ids:
            try:
                resp = h.get("https://api.coingecko.com/api/v3/simple/price",
                             params={"ids": ",".join(ids.values()), "vs_currencies": "usd", "include_24hr_change": "true"})
                resp.raise_for_status()
                data = resp.json()
                for s, cid in ids.items():
                    d = data.get(cid)
                    if d and d.get("usd"):
                        _save(s, d["usd"], d.get("usd_24h_change"), None, "CoinGecko")
                        got[s] = (d["usd"], d.get("usd_24h_change"))
                        out["updated"] += 1
                    else:
                        _save(s, error="onbekende munt bij CoinGecko")
            except (httpx.HTTPError, ValueError) as e:
                out["errors"].append(f"CoinGecko: {e.__class__.__name__}")
    _update_market(got)
    db.set_json("quotes:last", {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"), **out})
    return out


def _update_market(got):
    """Zet CRCL, MAGS en bitcoin ook in de cijfers van de Markt-pagina."""
    keys = {MARKET_KEYS[s]: v for s, v in got.items() if s in MARKET_KEYS}
    if not keys:
        return
    from .jobs import ensure_item, signed, stamp
    doc = db.get_doc("market/latest") or {"items": []}
    items = {i["key"]: i for i in doc.get("items", [])}
    for k, (price, chg) in keys.items():
        it = ensure_item(items, k)
        it.update(value=float(price), asOf=stamp(), display=None, src="Finnhub" if k != "btc" else "CoinGecko",
                  change=(("24u: " if k == "btc" else "dag: ") + signed(float(chg), 1, "%")) if chg is not None else "")
    doc["items"] = list(items.values())
    doc["updatedAt"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    doc["updatedBy"] = "Server (automatisch)"
    db.set_doc("market/latest", doc)
HP_EINDE_APP_QUOTES_PY

# ---- app/scheduler.py ----
COPY <<"HP_EINDE_APP_SCHEDULER_PY" /app/app/scheduler.py
"""Ingebouwde planner: start de taken uit app/jobs.py op vaste tijden (Nederlandse tijd).

Railway heeft geen systemd-timers en een volume hoort bij één dienst, dus de taken draaien
in hetzelfde proces als de website. Draai daarom maar één exemplaar (geen replicas).

  post       elk kwartier: e-mail ophalen en documenten laten analyseren door Grok
  koersen    elk kwartier: koersen van je volglijst (Finnhub, CoinGecko)
  markt      werkdagen 08:00–23:30, elk halfuur (alleen met TWELVEDATA_API_KEY)
  dagelijks  maandag t/m zaterdag 23:20 (alleen met FRED_API_KEY of TWELVEDATA_API_KEY)

Bij het opstarten worden verouderde cijfers één keer bijgewerkt (net als 'Persistent=true' bij systemd).
"""
import os
import threading
import time
import traceback
from datetime import datetime, timedelta

from . import db, jobs

TZ = jobs.TZ
_every = max(5, int(os.environ.get("EMAIL_INTERVAL_MIN", "15") or 15))
RULES = {
    "post": lambda n: n.minute % _every == 0,
    "koersen": lambda n: n.minute % 15 == 7,
    "markt": lambda n: n.weekday() < 5 and 8 <= n.hour <= 23 and n.minute in (0, 30),
    "dagelijks": lambda n: n.weekday() < 6 and n.hour == 23 and n.minute == 20,
}


def enabled(name):
    from . import ai, mail
    if name == "post":
        return mail.configured() or bool(ai.provider())
    if name == "markt":
        return bool(jobs.TD_KEY)
    if name == "dagelijks":
        return bool(jobs.FRED_KEY or jobs.TD_KEY)
    return True


USES_TWELVEDATA = {"markt", "dagelijks"}
TD_GAP = 65  # seconden tussen Twelve Data-taken (gratis: max 8 verzoeken per minuut)

_lock = threading.Lock()
_state = {"running": None, "next": {}, "started": None}
_last_td = [0.0]


def next_run(rule, after):
    t = after.replace(second=0, microsecond=0) + timedelta(minutes=1)
    for _ in range(60 * 24 * 8):
        if rule(t):
            return t
        t += timedelta(minutes=1)
    return None


def _record(name, ok, secs, why, error=""):
    try:
        st = db.get_doc("system/jobs") or {}
        st[name] = {"at": datetime.now(TZ).isoformat(timespec="seconds"), "ok": ok, "secs": round(secs, 1),
                    "why": why, "error": error[:300]}
        db.set_doc("system/jobs", st)
    except Exception as e:  # status bijhouden mag een taak nooit laten mislukken
        print("Taakstatus opslaan mislukt:", e)


def run(name, why="gepland"):
    """Draait één taak; nooit twee tegelijk. Geeft True terug als het gelukt is."""
    fn = jobs.JOBS[name]
    with _lock:
        _state["running"] = name
        if name in USES_TWELVEDATA and jobs.TD_KEY:
            wait = _last_td[0] + TD_GAP - time.time()
            if wait > 0:
                time.sleep(wait)
        t0 = time.time()
        print(f"==> Taak {name} gestart ({why})", flush=True)
        try:
            fn()
            ok, err = True, ""
        except RuntimeError as e:  # verwachte fout (bijv. mailserver weg): kort melden
            ok, err = False, str(e)
        except Exception as e:
            ok, err = False, f"{type(e).__name__}: {e}"
            traceback.print_exc()
        finally:
            if name in USES_TWELVEDATA:
                _last_td[0] = time.time()
            _state["running"] = None
        _record(name, ok, time.time() - t0, why, err)
        if not ok:
            db.event("fout", name, err)
        print(f"==> Taak {name} {'klaar' if ok else 'MISLUKT'} in {time.time() - t0:.0f} s", flush=True)
        return ok


def run_in_background(name, why="handmatig"):
    if _state["running"]:
        return False
    threading.Thread(target=run, args=(name, why), daemon=True, name=f"taak-{name}").start()
    return True


def _hours_since(iso):
    if not iso:
        return 1e9
    try:
        t = datetime.fromisoformat(iso)
        if t.tzinfo is None:
            t = t.replace(tzinfo=TZ)
        return (datetime.now(TZ) - t).total_seconds() / 3600
    except ValueError:
        return 1e9


def _catch_up():
    """Na een herstart of nieuwe versie: meteen mail en koersen ophalen, oude macrocijfers verversen."""
    time.sleep(15)
    for name in ("post", "koersen"):
        if enabled(name):
            run(name, "na opstart")
    if jobs.FRED_KEY or jobs.TD_KEY:
        try:
            stale = _hours_since((db.get_doc("system/daily") or {}).get("at")) > 20
        except db.DBError:
            stale = False
        if stale:
            run("dagelijks", "inhalen na opstart")


def _loop():
    now = datetime.now(TZ)
    nxt = {k: next_run(r, now) for k, r in RULES.items()}
    _state["next"] = {k: v.isoformat(timespec="minutes") for k, v in nxt.items() if v}
    while True:
        try:
            now = datetime.now(TZ)
            for k in sorted(nxt, key=lambda k: nxt[k] or now):
                if nxt[k] and now >= nxt[k]:
                    if enabled(k):
                        run(k)
                    nxt[k] = next_run(RULES[k], datetime.now(TZ))
                    _state["next"][k] = nxt[k].isoformat(timespec="minutes") if nxt[k] else None
        except Exception:
            traceback.print_exc()
        time.sleep(20)


def start():
    if _state["started"]:
        return
    _state["started"] = datetime.now(TZ).isoformat(timespec="seconds")
    threading.Thread(target=_loop, daemon=True, name="planner").start()
    threading.Thread(target=_catch_up, daemon=True, name="inhalen").start()
    print(f"==> Planner gestart (mail elke {_every} min, koersen elk kwartier)", flush=True)


def status():
    return {"started": _state["started"], "running": _state["running"], "next": dict(_state["next"]),
            "last": db.get_doc("system/jobs") or {}}
HP_EINDE_APP_SCHEDULER_PY

# ---- app/static/login.html ----
COPY <<"HP_EINDE_APP_STATIC_LOGIN_HTML" /app/app/static/login.html
<!doctype html>
<html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Inloggen · Handelsplan</title>
<style>
:root{--bg:#EDF0F3;--card:#fff;--ink:#13202C;--muted:#56636F;--line:#D3DAE1;--accent:#8A580A;--bad:#AF2F29;--good:#2D7A4B;--warn:#9A6A00}
@media (prefers-color-scheme:dark){:root{--bg:#0C1217;--card:#131B23;--ink:#E3E9EF;--muted:#95A3B0;--line:#25313C;--accent:#D9A347;--bad:#F06A5F;--good:#5FBF84;--warn:#E0B04A;color-scheme:dark}}
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;padding:16px}
form{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:28px;width:100%;max-width:340px;display:grid;gap:14px}
h1{margin:0;font-size:1.4rem}h1 span{color:var(--accent)}label{font-size:.85rem;color:var(--muted);display:grid;gap:4px}
input{font:inherit;padding:10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--ink)}
button{font:600 1rem system-ui;padding:11px;border:0;border-radius:8px;background:var(--accent);color:var(--card);cursor:pointer}
button:disabled{opacity:.6}.err{color:var(--bad);font-size:.9rem;min-height:1.2em}
.conn{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:.8rem;color:var(--muted);border-top:1px solid var(--line);padding-top:12px}
.conn span{display:inline-flex;align-items:center;gap:6px}.conn i{width:8px;height:8px;border-radius:50%;background:var(--line)}
.conn .ok i{background:var(--good)}.conn .bad i{background:var(--bad)}.conn .bad{color:var(--bad)}
</style></head><body>
<form id="f" autocomplete="on">
  <h1>Handelsplan <span>2027</span></h1>
  <input type="text" name="username" autocomplete="username" value="handelsplan" hidden>
  <label>Wachtwoord<input id="p" name="password" type="password" autocomplete="current-password" required autofocus></label>
  <button type="submit" id="b">Inloggen</button>
  <div class="err" id="e" role="alert"></div>
  <div class="conn" id="c" aria-live="polite"><span><i></i>Verbinding met Railway controleren…</span></div>
</form>
<script>
(async () => {
  const c = document.getElementById("c");
  const dot = (ok, t) => `<span class="${ok ? "ok" : "bad"}"><i></i>${t}</span>`;
  try {
    const r = await fetch("/health", {cache: "no-store"});
    const j = await r.json();
    c.innerHTML = dot(true, "Server verbonden") + dot(j.database, j.database ? "Database verbonden" : "Database niet bereikbaar")
      + (j.login ? "" : dot(false, "APP_PASSWORD ontbreekt in Railway"));
  } catch (x) { c.innerHTML = dot(false, "Server niet bereikbaar"); }
})();
document.getElementById("f").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const e = document.getElementById("e"), b = document.getElementById("b"), p = document.getElementById("p");
  e.textContent = ""; b.disabled = true;
  try {
    const r = await fetch("/login", {method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify({password:p.value})});
    if (r.ok) { location.href = "/"; return; }
    let j = {}; try { j = await r.json(); } catch (x) {}
    e.textContent = j.error || "Inloggen mislukt."; p.value = ""; p.focus();
  } catch (x) { e.textContent = "De site is even niet bereikbaar. Probeer het zo opnieuw."; }
  finally { b.disabled = false; }
});
</script></body></html>
HP_EINDE_APP_STATIC_LOGIN_HTML

# ---- app/static/shim.js ----
COPY <<"HP_EINDE_APP_STATIC_SHIM_JS" /app/app/static/shim.js
// Laat de handelsplan-pagina op je eigen server draaien: vervangt claude.use(...) door je eigen API.
(function () {
  "use strict";
  const listeners = new Set();
  const api = async (method, url, body) => {
    const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined, credentials: "same-origin" });
    if (r.status === 401) { location.href = "/login"; throw { code: "revoked" }; }
    if (!r.ok) { let m = ""; try { const j = await r.json(); m = j.detail || ""; } catch (e) {} throw { code: r.status === 404 ? "invalid_argument" : r.status === 429 ? "resource_exhausted" : "unavailable", message: m }; }
    return r.json();
  };
  const refreshAll = () => listeners.forEach((fn) => fn());
  setInterval(() => { if (!document.hidden) refreshAll(); }, 30000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refreshAll(); });
  const freeze = (o) => o;
  const snap = (id, exists, data) => ({ id, exists, data: () => data, metadata: { fromCache: false, hasPendingWrites: false } });
  const newId = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);

  function docRef(path) {
    const id = path.split("/").pop();
    return {
      id, path,
      get: async () => { const r = await api("GET", "/api/doc?path=" + encodeURIComponent(path)); return snap(id, r.exists, r.data); },
      set: async (d) => { await api("PUT", "/api/doc?path=" + encodeURIComponent(path), d); refreshAll(); },
      update: async (d) => { await api("PATCH", "/api/doc?path=" + encodeURIComponent(path), d); refreshAll(); },
      delete: async () => {},
      onSnapshot(next, err) {
        const run = async () => { try { const r = await api("GET", "/api/doc?path=" + encodeURIComponent(path)); next(snap(id, r.exists, r.data)); } catch (e) { err && err(e); } };
        listeners.add(run); run(); return () => listeners.delete(run);
      },
    };
  }
  function query(path, order, dir, lim) {
    const q = {
      where: () => q,
      orderBy: (f, d) => query(path, f, d || "asc", lim),
      limit: (n) => query(path, order, dir, n),
      get: async () => fetchQ(),
      onSnapshot(next, err) {
        const run = async () => { try { next(await fetchQ()); } catch (e) { err && err(e); } };
        listeners.add(run); run(); return () => listeners.delete(run);
      },
      doc: (id) => docRef(path + "/" + (id || newId())),
      add: async (d) => { const r = docRef(path + "/" + newId()); await r.set(d); return r; },
      path,
    };
    async function fetchQ() {
      const r = await api("GET", `/api/col?path=${encodeURIComponent(path)}&order=${encodeURIComponent(order || "")}&dir=${dir || "asc"}&limit=${lim || 100}`);
      const docs = r.docs.map((d) => snap(d.id, true, d.data));
      return { docs, size: docs.length, empty: !docs.length, docChanges: () => [], metadata: { fromCache: false, hasPendingWrites: false } };
    }
    return q;
  }
  const db = { doc: docRef, collection: (p) => query(p, "", "asc", 100) };

  async function sample(input, opts = {}) {
    const prompt = typeof input === "string" ? input : input.map((m) => m.content).join("\n\n");
    let r;
    try {
      r = await fetch("/api/ai", { method: "POST", headers: { "Content-Type": "application/json" }, credentials: "same-origin",
        body: JSON.stringify({ prompt, tier: opts.modelTier || "default" }), signal: opts.signal });
    } catch (e) { throw { code: e && e.name === "AbortError" ? "cancelled" : "upstream_error" }; }
    if (r.status === 401) { location.href = "/login"; throw { code: "session_expired" }; }
    if (r.status === 429) throw { code: "rate_limited" };
    if (!r.ok) { let m = ""; try { const j = await r.json(); m = j.detail || ""; } catch (e) {} throw { code: r.status === 503 ? "upstream_error" : "upstream_error", message: m }; }
    const data = await r.json();
    opts.onText && opts.onText({ text: data.text, delta: data.text });
    return { text: data.text, truncated: !!data.truncated, modelTierApplied: opts.modelTier || "default" };
  }
  sample.json = async (input, opts) => {
    const { text } = await sample(input, opts);
    const tryParse = (s) => { try { return JSON.parse(s); } catch { return undefined; } };
    let v = tryParse(text.trim());
    if (v === undefined) { const m = text.match(/```(?:json)?\s*([\s\S]*?)```/); if (m) v = tryParse(m[1]); }
    if (v === undefined) { const a = text.search(/[\[{]/), b = Math.max(text.lastIndexOf("}"), text.lastIndexOf("]")); if (a >= 0 && b > a) v = tryParse(text.slice(a, b + 1)); }
    if (v === undefined) throw { code: "invalid_json", text };
    return v;
  };
  sample.limits = async () => ({ maxPromptBytes: 262144 });

  const downloads = {
    save: async ({ filename, data }) => {
      const url = URL.createObjectURL(data instanceof Blob ? data : new Blob([data]));
      const a = document.createElement("a"); a.href = url; a.download = filename; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 2000);
      return { status: "saved" };
    },
  };
  const user = { can: async () => true, canEdit: async () => true, isOwner: async () => true, id: async () => "me" };
  const server = {
    api: (method, url, body) => api(method, url, body),
    status: () => api("GET", "/api/status"),
    run: (job) => api("POST", "/api/run/" + encodeURIComponent(job)),
    backupUrl: "/api/export",
    restore: async (file) => {
      const r = await fetch("/api/import", { method: "POST", body: file, credentials: "same-origin", headers: { "Content-Type": "application/json" } });
      if (r.status === 401) { location.href = "/login"; throw { code: "revoked" }; }
      let j = {}; try { j = await r.json(); } catch (e) {}
      if (!r.ok) throw { code: "restore_failed", message: j.detail || "Terugzetten mislukt." };
      return j;
    },
    logout: async () => { await fetch("/logout", { method: "POST", credentials: "same-origin" }); location.href = "/login"; },
  };
  const caps = { db, sample, downloads, user, server };
  window.claude = { use: async (name) => caps[name] || null };
})();
HP_EINDE_APP_STATIC_SHIM_JS

# ---- scripts/migrate.py ----
COPY <<"HP_EINDE_SCRIPTS_MIGRATE_PY" /app/scripts/migrate.py
"""Werkt een bestaande database bij met nieuwe onderdelen: python -m scripts.migrate
Je eigen wijzigingen blijven staan; alleen ontbrekende onderdelen worden toegevoegd."""
from app import db, patch

plan = db.get_doc("plan/current")
market = db.get_doc("market/latest")
plan, market, notes = patch.apply(plan, market)
if plan is not None:
    db.set_doc("plan/current", plan)
if market is not None:
    db.set_doc("market/latest", market)
print("Bijgewerkt:" if notes else "Niets bij te werken.", "; ".join(notes))
HP_EINDE_SCRIPTS_MIGRATE_PY

# ---- scripts/seed.py ----
COPY <<"HP_EINDE_SCRIPTS_SEED_PY" /app/scripts/seed.py
"""Zet je startplan, koersen, inbox en historie in de database: python -m scripts.seed
Bestaande documenten worden NIET overschreven (gebruik scripts.migrate om bij te werken)."""
import json
from pathlib import Path

from app import db, patch

S = Path(__file__).resolve().parent.parent / "seed"
items = {"plan/current": "plan.json", "market/latest": "market.json",
         "inbox/juli-plan": "inbox_juli.json", "history/v1-start": "history_v1.json"}
for path, fn in items.items():
    if db.get_doc(path) is None:
        data = json.loads((S / fn).read_text(encoding="utf-8"))
        if path == "plan/current":
            patch.apply(data, None)
        if path == "market/latest":
            patch.apply(None, data)
        db.set_doc(path, data)
        print("Geplaatst:", path)
    else:
        print("Bestaat al, overgeslagen:", path)
HP_EINDE_SCRIPTS_SEED_PY

# ---- scripts/transcripts_ophalen.py ----
COPY <<"HP_EINDE_SCRIPTS_TRANSCRIPTS_OPHALEN_PY" /app/scripts/transcripts_ophalen.py
#!/usr/bin/env python3
"""
transcripts_ophalen.py

Haalt de ondertitels (transcripts) van de nieuwste video's van je YouTube-kanalen op
en zet ze als .txt-bestand in een map. Die bestanden plak je in de Inbox van je
Handelsplan, of je laat een geplande Claude-taak de map uitlezen en verwerken.

Eenmalig installeren:   pip install -U yt-dlp
Draaien:                python transcripts_ophalen.py

Tip: laat dit dagelijks draaien met Taakplanner (Windows) of cron/launchd (Mac).
Werk yt-dlp af en toe bij (pip install -U yt-dlp): YouTube verandert regelmatig.
"""
import html
import json
import re
import urllib.request
import sys
from datetime import datetime
from pathlib import Path

try:
    import yt_dlp
except ImportError:
    sys.exit("yt-dlp ontbreekt. Installeer het met:  pip install -U yt-dlp")

# ------------------------------------------------------------------
# INSTELLINGEN: vul hier de kanaallinks in (tabblad 'Video's' van het kanaal)
# ------------------------------------------------------------------
KANALEN = {
    # "Naam zoals in je inbox": "https://www.youtube.com/@kanaalnaam/videos",
    "Rebel Capitalist": "https://www.youtube.com/@VUL-IN/videos",
    "TradersReality": "https://www.youtube.com/@VUL-IN/videos",
    "Eigen video": "https://www.youtube.com/@VUL-IN/videos",
}
AANTAL_NIEUWSTE = 3            # hoeveel recente video's per kanaal controleren
TALEN = ["en", "nl"]           # voorkeursvolgorde van ondertiteltalen
MAP = Path.home() / "Handelsplan" / "transcripts"
# Automatisch doorsturen naar je site (laat leeg om alleen bestanden te maken)
SERVER_URL = "https://plan.vsonsbeek.nl/api/inbox"
INBOX_TOKEN = ""  # dezelfde waarde als de variabele INBOX_TOKEN in Railway
# ------------------------------------------------------------------

STATUSBESTAND = MAP / ".al_opgehaald.json"


def schone_naam(s: str) -> str:
    return re.sub(r'[\\/:*?"<>|\n\r\t]+', "", s).strip()[:80] or "video"


def vtt_naar_tekst(vtt: str) -> str:
    """Zet WebVTT-ondertitels om naar lopende tekst zonder tijdcodes en dubbele regels."""
    regels, vorige = [], ""
    for r in vtt.splitlines():
        r = r.strip()
        if (not r or r == "WEBVTT" or "-->" in r or r.isdigit()
                or r.startswith(("Kind:", "Language:", "NOTE", "STYLE"))):
            continue
        r = html.unescape(re.sub(r"<[^>]+>", "", r)).strip()
        if r and r != vorige:          # automatische ondertitels herhalen regels
            regels.append(r)
            vorige = r
    return re.sub(r"\s+", " ", " ".join(regels)).strip()


def nieuwste_videos(kanaal_url: str, n: int):
    opties = {"quiet": True, "no_warnings": True, "extract_flat": True, "playlistend": n}
    with yt_dlp.YoutubeDL(opties) as ydl:
        info = ydl.extract_info(kanaal_url, download=False)
    return [(e["id"], e.get("title") or e["id"]) for e in (info.get("entries") or []) if e.get("id")]


def kies_ondertitel(info: dict):
    """Eerst handgemaakte ondertitels, dan automatische; in de volgorde van TALEN."""
    for soort in ("subtitles", "automatic_captions"):
        subs = info.get(soort) or {}
        for taal in TALEN:
            for sleutel, formaten in subs.items():
                if sleutel == taal or sleutel.startswith(taal + "-"):
                    for f in formaten:
                        if f.get("ext") == "vtt" and f.get("url"):
                            return f["url"], sleutel
    return None, None


def haal_transcript(video_id: str):
    url = f"https://www.youtube.com/watch?v={video_id}"
    with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True}) as ydl:
        info = ydl.extract_info(url, download=False)
        sub_url, taal = kies_ondertitel(info)
        if not sub_url:
            return info, None, None
        vtt = ydl.urlopen(sub_url).read().decode("utf-8", "replace")
    return info, vtt_naar_tekst(vtt), taal


def main():
    MAP.mkdir(parents=True, exist_ok=True)
    try:
        gezien = json.loads(STATUSBESTAND.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        gezien = {}

    nieuw = 0
    for bron, kanaal_url in KANALEN.items():
        if "VUL-IN" in kanaal_url:
            print(f"- {bron}: nog geen kanaallink ingevuld, overgeslagen.")
            continue
        try:
            videos = nieuwste_videos(kanaal_url, AANTAL_NIEUWSTE)
        except Exception as e:  # netwerk, verkeerde link, YouTube-wijziging
            print(f"- {bron}: kanaal niet op te halen ({e}).")
            continue

        for video_id, titel in videos:
            if video_id in gezien:
                continue
            try:
                info, tekst, taal = haal_transcript(video_id)
            except Exception as e:
                print(f"- {bron}: '{titel}' overgeslagen ({e}).")
                continue
            if not tekst:
                print(f"- {bron}: '{titel}' heeft nog geen ondertitels; volgende keer opnieuw.")
                continue

            ud = info.get("upload_date") or datetime.now().strftime("%Y%m%d")
            datum = f"{ud[:4]}-{ud[4:6]}-{ud[6:]}"
            bestand = MAP / f"{datum}_{schone_naam(bron)}_{schone_naam(titel)}.txt"
            kop = (f"Bron: {bron}\nTitel: {titel}\nLink: https://www.youtube.com/watch?v={video_id}\n"
                   f"Datum: {datum}\nOndertiteltaal: {taal}\n---\n")
            bestand.write_text(kop + tekst + "\n", encoding="utf-8")
            gezien[video_id] = {"bron": bron, "titel": titel, "datum": datum, "bestand": bestand.name,
                                "opgehaald": datetime.now().isoformat(timespec="seconds")}
            if SERVER_URL and INBOX_TOKEN:
                try:
                    req = urllib.request.Request(SERVER_URL, method="POST", data=json.dumps(
                        {"source": bron, "title": titel, "url": f"https://www.youtube.com/watch?v={video_id}",
                         "date": datum, "text": tekst}).encode(), headers={
                        "Content-Type": "application/json", "Authorization": f"Bearer {INBOX_TOKEN}"})
                    urllib.request.urlopen(req, timeout=30)
                    print("  -> naar je inbox gestuurd")
                except Exception as e:
                    print(f"  -> doorsturen mislukt ({e}); bestand staat wel in de map")
            nieuw += 1
            print(f"+ {bron}: {titel}  ({len(tekst.split())} woorden)")

    STATUSBESTAND.write_text(json.dumps(gezien, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nKlaar: {nieuw} nieuw transcript(s) in {MAP}")


if __name__ == "__main__":
    main()
HP_EINDE_SCRIPTS_TRANSCRIPTS_OPHALEN_PY

# ---- seed/history_v1.json ----
COPY <<"HP_EINDE_SEED_HISTORY_V1_JSON" /app/seed/history_v1.json
{"at": "2026-10-16T09:00:00+02:00", "version": 1, "source": "Startversie", "title": "Juli-plan herzien met marktdata t/m 16 okt", "inboxId": "juli-plan", "summary": "Plan opnieuw opgebouwd rond je werkelijke posities, met vier nieuwe scenario's, planregels per positie, 14 triggers met drempels, factorkaart, claimregister en kalender tot eind november.", "changelog": ["Regime: van 'Mud Through + credit stress' naar 'Stagflatie met renteschok'", "Scenario's herzien: Stagflatie-grind 45% · Olieschok 20% · Groeischok 20% · Zachte landing 15%", "Posities: goud/USDC vervangen door mijnen, CRCL, Mag 7 en insider-trades, elk met planregels", "10-jaarsrente aangewezen als hoofdvariabele", "Claimregister gestart met de 8 kernclaims uit juli"]}
HP_EINDE_SEED_HISTORY_V1_JSON

# ---- seed/inbox_juli.json ----
COPY <<"HP_EINDE_SEED_INBOX_JULI_JSON" /app/seed/inbox_juli.json
{"title": "Handel Plan 2026 – update juli (oud plan)", "source": "Eigen notitie", "date": "2026-07-22", "url": "", "createdAt": "2026-10-16T09:00:00+02:00", "status": "verwerkt", "addedBy": "hand", "appliedVersion": 1, "text": "Juli-plan (PDF, 4 pagina's): allocatie goud + Circle/USDC als defensieve kern; scenario's Mud Through + Credit Stress (50–60%), Bull (15–20%), Bear (20–30%); monitoring Iran/Hormuz, Fed, BOJ, private credit, margin debt, Kospi. Volledig verwerkt in versie 1 van het nieuwe plan.", "analysis": {"summary": "Het juli-plan ging uit van een defensieve portefeuille (fysiek goud + USDC). Twee risicoscenario's zijn deels uitgekomen (Fed-verhoging, olie boven $100), maar goud reageerde zwakker dan verwacht door de hoge reële rente. Belangrijkste correctie: je echte posities (mijnen, CRCL-aandeel, Mag 7, small caps) zijn aandelen met hoge beweeglijkheid, geen defensieve kern.", "keyPoints": ["Fed-verhoging en olie $100+ bevestigd", "Goud als veilige haven: weerlegd voor nu", "USDC ≠ CRCL-aandeel", "Mijnen ≠ fysiek goud (1,5–2× hefboom, energiekosten)"], "at": "2026-10-16T09:00:00+02:00"}}
HP_EINDE_SEED_INBOX_JULI_JSON

# ---- seed/macro_patch.json ----
COPY <<"HP_EINDE_SEED_MACRO_PATCH_JSON" /app/seed/macro_patch.json
{
 "macro": {
  "updatedAt": "2026-10-16T22:45:00+02:00",
  "source": "Startversie door Claude, cijfers t/m 15 okt 2026",
  "riskMode": "defensief",
  "regime": "Stagflatie-light",
  "headline": "De obligatiemarkt is de stressplek",
  "summary": "Inflatie loopt op door de olieschok (CPI 3,7%), de Fed verhoogde in september en de 30-jaarsrente piekte op het hoogste niveau sinds 2002. Opvallend: de inflatieverwachting is maar 2,32%, dus de rentestijging komt van de reële rente (2,78%). Die drukt tegelijk op goud, tech en kleine bedrijven. Aandelen en junk-obligaties zijn nog rustig, en de arbeidsmarkt koelt af zonder ontslagen.",
  "compass": {
   "growth": -0.35,
   "inflation": 0.55,
   "heading": {
    "growth": -0.2,
    "inflation": 0
   },
   "why": "Groei koelt af (banen +29k, werkloosheid 4,2%) en inflatie stijgt (3,4% → 3,7%). Anders dan in de jaren 70 is de reële rente hoog. Daarom krijgt goud nog geen wind mee."
  },
  "keyPoints": [
   {
    "tone": "bad",
    "title": "Rente stijgt om de verkeerde reden",
    "text": "Reële rente 2,78% (een jaar geleden 1,76%), inflatieverwachting maar 2,32%. Schuld en termijnpremie drijven de lange rente, geen inflatieangst."
   },
   {
    "tone": "warn",
    "title": "Inflatie is een energieschok",
    "text": "CPI 3,7%, maar de kern is 2,6%. Olie blijft boven $95 door de Hormuz-blokkade; groothandelsprijzen +6,3%."
   },
   {
    "tone": "warn",
    "title": "Werk: weinig aannemen, weinig ontslaan",
    "text": "Banen +29k in september en werkloosheid 4,2%, maar WW-aanvragen laag (199k). Afkoeling, nog geen recessiesignaal."
   },
   {
    "tone": "warn",
    "title": "Liquiditeit vlak, buffer leeg",
    "text": "Netto liquiditeit ~$5,87 bln. QT is voorbij, maar de reverse repo is leeg en Warsh wil een kleinere Fed-balans."
   },
   {
    "tone": "good",
    "title": "Krediet rustig aan de oppervlakte",
    "text": "Junk-spread 3,16%: rustig. Wel klem in private credit, waar uitstapverzoeken ver boven het plafond liggen."
   },
   {
    "tone": "bad",
    "title": "AI-chips kraken, de VIX slaapt",
    "text": "Kospi −7,6% in één dag en chips onder druk, maar de angstindex staat op 16,9. De techcijfers van 21–29 okt beslissen."
   }
  ],
  "pillars": [
   {
    "id": "inflatie",
    "stage": 1,
    "name": "Inflatie & energie",
    "q": "Wordt geld minder waard?",
    "status": "gespannen",
    "keys": [
     "cpiYoY",
     "breakeven10",
     "brent"
    ],
    "reading": "Headline-inflatie 3,7% door olie, kern 2,6%. De obligatiemarkt ziet het als tijdelijk: inflatieverwachting 2,32%.",
    "effects": {
     "miners": -1,
     "crcl": 0,
     "mag7": -1,
     "insider": -1
    }
   },
   {
    "id": "groei",
    "stage": 1,
    "name": "Groei & werk",
    "q": "Draait de economie?",
    "status": "gespannen",
    "keys": [
     "nfp3m",
     "unrate",
     "claims"
    ],
    "reading": "Banengroei bijna nul en werkloosheid 4,2%, maar weinig ontslagen. Afkoeling, geen krimp.",
    "effects": {
     "miners": 1,
     "crcl": -1,
     "mag7": -1,
     "insider": -1
    }
   },
   {
    "id": "rente",
    "stage": 2,
    "name": "Rente & obligaties",
    "q": "Wat kost geld?",
    "status": "stress",
    "keys": [
     "us10y",
     "us30y",
     "realYield10"
    ],
    "reading": "Fed-rente 3,75–4,00% na de verhoging in september. 10-jaars 5,1%, 30-jaars 5,4% (piek 5,73%). De reële rente van 2,78% is de grootste rem op goud en tech.",
    "effects": {
     "miners": -2,
     "crcl": 2,
     "mag7": -2,
     "insider": -2
    }
   },
   {
    "id": "liquiditeit",
    "stage": 2,
    "name": "Liquiditeit",
    "q": "Is er geld in het systeem?",
    "status": "gespannen",
    "keys": [
     "netLiq",
     "netLiqChg"
    ],
    "reading": "De Fed koopt weer T-bills (~$40 mld per maand), maar de netto liquiditeit is vlak (~$5,87 bln) en de reverse-repobuffer is op.",
    "effects": {
     "miners": 0,
     "crcl": 0,
     "mag7": -1,
     "insider": -1
    }
   },
   {
    "id": "dollar",
    "stage": 3,
    "name": "Dollar & yen",
    "q": "Is de dollar schaars?",
    "status": "rustig",
    "keys": [
     "dxy",
     "usdjpy"
    ],
    "reading": "Dollar neutraal rond 102. De yen staat bij 158: boven 160 grijpt Japan in. De BOJ beslist op 30 oktober.",
    "effects": {
     "miners": 0,
     "crcl": 0,
     "mag7": 0,
     "insider": 0
    }
   },
   {
    "id": "krediet",
    "stage": 3,
    "name": "Krediet",
    "q": "Breekt er iets?",
    "status": "gespannen",
    "keys": [
     "hySpread"
    ],
    "reading": "Junk-obligaties rustig (spread 3,16%). Private credit staat onder druk: uitstapverzoeken liggen ver boven het plafond.",
    "effects": {
     "miners": 0,
     "crcl": 0,
     "mag7": 0,
     "insider": -1
    }
   },
   {
    "id": "sentiment",
    "stage": 3,
    "name": "Sentiment & AI",
    "q": "Hoe zit de markt erin?",
    "status": "stress",
    "keys": [
     "vix",
     "kospi",
     "btc"
    ],
    "reading": "AI-chips zitten in een uitverkoop, maar de angstindex is laag. Fragiel: een tegenvaller bij de techcijfers kan snel doorslaan.",
    "effects": {
     "miners": 0,
     "crcl": -1,
     "mag7": -2,
     "insider": -1
    }
   }
  ],
  "positionImpact": {
   "miners": {
    "dir": -1,
    "why": "Hoge reële rente en dure olie: dubbele tegenwind voor goud én marges."
   },
   "crcl": {
    "dir": 1,
    "why": "Hoge korte rente betekent meer rente-inkomsten; crypto-sentiment is de rem."
   },
   "mag7": {
    "dir": -1,
    "why": "Reële rente drukt waarderingen; de AI-investeringen worden getest."
   },
   "insider": {
    "dir": -1,
    "why": "Kleine bedrijven betalen de hoge rente bij herfinanciering."
   }
  },
  "lenses": [
   {
    "id": "rebel",
    "name": "Liquiditeit & schuld",
    "who": "Rebel Capitalist (George Gammon)",
    "method": "Kijkt eerst naar het geldsysteem: de Fed-balans, de schatkistrekening (TGA), reverse repo, staatsschuld en tekort ten opzichte van de nominale groei, en de wereldwijde vraag naar dollars.",
    "question": "Is er genoeg geld in het systeem, en breekt er iets in de obligatiemarkt?",
    "checks": [
     {
      "id": "fed",
      "q": "Wat doet de Fed met haar balans?",
      "status": "gespannen",
      "answer": "QT is sinds eind 2025 gestopt; de Fed koopt ~$40 mld per maand aan T-bills om de reserves op peil te houden. Maar de rente ging in september omhoog, en Warsh wil een kleinere balans."
     },
     {
      "id": "netliq",
      "q": "Netto liquiditeit (Fed-balans − TGA − reverse repo)",
      "status": "gespannen",
      "key": "netLiq",
      "answer": "Ongeveer $5,87 bln (9 okt) en vlak. De reverse-repobuffer is leeg: elke opbouw van de schatkistrekening haalt nu direct geld uit de markt."
     },
     {
      "id": "bonds",
      "q": "Wat zegt de obligatiemarkt?",
      "status": "stress",
      "key": "realYield10",
      "answer": "De 30-jaarsrente piekte op 5,73% (hoogste sinds 2002) en de reële rente is 2,78%, een procentpunt hoger dan een jaar geleden, terwijl de inflatieverwachting maar 2,32% is. De stijging komt van reële rente en termijnpremie."
     },
     {
      "id": "fiscal",
      "q": "Schuld en tekort versus rente",
      "status": "stress",
      "answer": "Oorlog, hoge rentelasten en een groot tekort betekenen veel nieuwe staatsleningen. Gammon waarschuwde begin oktober dat de volatiliteit in obligaties snel oploopt."
     },
     {
      "id": "dollar",
      "q": "Is de dollar schaars?",
      "status": "rustig",
      "key": "dxy",
      "answer": "Nee: de dollarindex rond 102 is neutraal. Wereldwijde schulden in dollars houden de vraag hoog. Let op USD/JPY: boven 160 dreigt ingrijpen en het afbouwen van carry-trades."
     },
     {
      "id": "credit",
      "q": "Breekt er iets in krediet?",
      "status": "gespannen",
      "key": "hySpread",
      "answer": "De junk-spread van 3,16% is rustig, maar private credit zit klem: uitstapverzoeken liggen ver boven het plafond van 5%. Gammon waarschuwt al maanden voor een nieuwe subprime-crisis."
     }
    ],
    "take": "De stress zit in de obligatiemarkt, niet in aandelen. Zolang de lange rente oploopt door termijnpremie, hebben risico-assets én goud tegenwind. Het kantelpunt komt als de Fed of de schatkist moet ingrijpen (renteverlaging, meer staatsleningen opkopen). Dan daalt de reële rente, en dan zijn goud en mijnen de grootste winnaars.",
    "basis": "Startversie door Claude, opgebouwd uit de onderwerpen die Gammon in 2026 volgt: obligatievolatiliteit, tekort versus rente, Fed-balans, TGA, de dollar en kredietrisico. Nog geen eigen transcript verwerkt.",
    "updatedAt": "2026-10-16T22:45:00+02:00"
   },
   {
    "id": "tr",
    "name": "Geldstromen & marktstructuur",
    "who": "TradersReality",
    "method": "Hun Hybrid System combineert prijsactie, marktpsychologie en liquiditeitszones. Met PVSRA-volumekaarsen (vector candles) zoeken ze de voetafdruk van grote partijen, en ze bekijken de hele markt tegelijk: indices, Mag 7, obligaties, dollar en crypto.",
    "question": "Waar gaat het grote geld naartoe, en bij welke niveaus?",
    "checks": [
     {
      "id": "flow",
      "q": "Risk-on of risk-off?",
      "status": "gespannen",
      "answer": "Risk-off rotatie: geld trekt uit AI-chips (Kospi −7,6%, TSMC −4%, Nvidia −3,2%) naar obligaties en defensieve sectoren (zorg +2,4% op 14 okt). De VIX blijft laag (16,9): herpositionering, geen paniek."
     },
     {
      "id": "intermarket",
      "q": "Bevestigen de markten elkaar?",
      "status": "gespannen",
      "answer": "Nee. De dollar is stabiel, maar goud en zilver dalen mee met tech terwijl olie hoog blijft. Dat wijst op hoge reële rente en het afbouwen van posities, niet op een klassieke vluchthavenbeweging."
     },
     {
      "id": "levels",
      "q": "Waar liggen de liquiditeitszones?",
      "status": "info",
      "answer": "Goud: onder $4.000 (psychologisch niveau, stops) en boven $4.200–4.450 (eerdere weerstand). Zilver: $55 en $60. CRCL: $75 en $90–93. 10-jaars: 5,36% (top vorige week)."
     },
     {
      "id": "trend",
      "q": "Trend ten opzichte van het 50- en 200-daags gemiddelde",
      "status": "info",
      "auto": "levels",
      "answer": "Wordt na elke handelsdag automatisch berekend (zie het niveaubord)."
     },
     {
      "id": "mm",
      "q": "Wat doen de market makers deze week?",
      "status": "info",
      "answer": "Nog geen TradersReality-transcript verwerkt. Plak hun weekoutlook of livestream om dit in te vullen."
     }
    ],
    "take": "Het grote geld verlaat de AI-hoek en zoekt veiligheid, maar goud krijgt (nog) geen vluchthavenvraag. Voor mijnen: wacht op een herovering van $4.200 met volume voordat je bijkoopt. Een weekslot onder $4.000 is het signaal om af te bouwen.",
    "basis": "Startversie door Claude op basis van hun publieke methode (Hybrid System, TradingView-indicator Traders Reality Main) en de marktcijfers. Nog geen eigen call van TradersReality.",
    "updatedAt": "2026-10-16T22:45:00+02:00"
   }
  ],
  "cycle": {
   "updatedAt": "2026-10-17T00:30:00+02:00",
   "verdict": "Laat in de cyclus: de eerste barsten, nog geen crash",
   "summary": "We staan ongeveer waar de markt in de zomer en het najaar van 2007 stond. In een hoek van de kredietmarkt gaat het mis (toen subprimefondsen, nu private credit), terwijl de beurs vlak bij zijn record staat en de angst laag is. In 2007 duurde het vanaf hier nog een jaar tot de echte klap. Maar een late fase kan ook jaren duren: Greenspan waarschuwde in december 1996 al voor 'irrationele uitbundigheid', en daarna verdubbelde de beurs nog.",
   "analogs": [
    {
     "label": "zomer 2007",
     "what": "krediet",
     "why": "Stress in een schaduwhoek van de kredietmarkt, terwijl de beurs op de top staat."
    },
    {
     "label": "1999–2000",
     "what": "euforie",
     "why": "Bijna-record waardering en een markt die leunt op een paar techreuzen."
    },
    {
     "label": "1973",
     "what": "olie",
     "why": "Een oorlog maakt olie duur en de inflatie loopt op terwijl de Fed verhoogt."
    },
    {
     "label": "2022",
     "what": "rente",
     "why": "De reële rente stijgt: lastig voor goud(mijnen), tech en crypto."
    }
   ],
   "cycles": [
    {
     "id": "sentiment",
     "pos": 0.56,
     "why": "De S&P 500 staat ca. 1% onder zijn record van 6 oktober, de waardering (CAPE 40,5) zit dicht bij het record van 2000 en er is $1,45 bln geleend om aandelen te kopen. Toch is de angst laag (VIX 16,9) terwijl AI-chips onderuitgaan: het patroon van net over de top.",
     "extra": [
      {
       "label": "Goud & zilver",
       "pos": 0.76,
       "why": "Hun euforie was in januari (goud $5.590, zilver boven $121). Sindsdien goud −25% en zilver −53%: ze zitten al in de dalende helft van hun eigen cyclus."
      }
     ]
    },
    {
     "id": "credit",
     "pos": 0.57,
     "why": "De junk-spread is nog laag (3,2%), maar private credit kraakt: wanbetalingen op een record (Fitch: 6,0%) en fondsen laten maar 5% per kwartaal uitstappen terwijl 17 tot 39% eruit wil."
    },
    {
     "id": "economy",
     "pos": 0.55,
     "why": "De inflatie loopt op (3,7%) en de Fed verhoogt, terwijl de banengroei bijna stilvalt (+29k in september). Ontslagen blijven laag (Sahm-regel 0,0): laat in de cyclus, op de grens met afkoeling."
    }
   ],
   "tipping": [
    {
     "id": "tp_hy",
     "label": "Junk-spread boven 5%",
     "key": "hySpread",
     "dir": "up",
     "near": 4,
     "hit": 5,
     "rule": "bereikt vanaf 5%",
     "then": "in 2007–08 liep de spread op van het laagste niveau ooit (juni 2007) naar ca. 20% (dec 2008)"
    },
    {
     "id": "tp_sahm",
     "label": "Ontslagen nemen toe (Sahm-regel 0,5 of hoger)",
     "key": "sahm",
     "dir": "up",
     "near": 0.3,
     "hit": 0.5,
     "rule": "bereikt vanaf 0,50",
     "then": "sloeg sinds 1970 bij elke recessie vroeg aan (in 2024 één keer vals alarm)"
    },
    {
     "id": "tp_fund",
     "label": "Een groot fonds stopt uitstappen helemaal of gaat om",
     "status": "gespannen",
     "now": "uitstappen beperkt tot 5% per kwartaal, nog niet helemaal gestopt",
     "then": "9 aug 2007 bevroor BNP Paribas drie fondsen; in maart 2008 moest Bear Stearns worden gered"
    },
    {
     "id": "tp_fed",
     "label": "De Fed verlaagt in paniek",
     "status": "rustig",
     "now": "de Fed verhoogt juist (sep 2026)",
     "then": "sep 2007 −0,5%; jan 2008 een noodverlaging van −0,75% buiten het vaste schema"
    },
    {
     "id": "tp_dd",
     "label": "Beurs 20% onder het record",
     "key": "spxDD",
     "dir": "down",
     "near": -10,
     "hit": -20,
     "rule": "bereikt bij 20% onder het record",
     "then": "jun–jul 2008, ca. 2,5 maand vóór Lehman"
    },
    {
     "id": "tp_oil",
     "label": "Olie boven $120",
     "key": "brent",
     "dir": "up",
     "near": 100,
     "hit": 120,
     "rule": "bereikt boven $120 (Brent)",
     "then": "jul 2008 olie $147; kort daarna begon de echte val"
    }
   ]
  }
 },
 "triggersAdd": [
  {
   "id": "t_30y",
   "label": "US 30-jaarsrente",
   "marketKey": "us30y",
   "unit": "%",
   "dir": "up",
   "warn": 5.4,
   "danger": 5.7,
   "pillar": "rente",
   "meaning": "Bond vigilantes: boven 5,7% (de piek sinds 2002) breekt er iets in de obligatiemarkt.",
   "affects": [
    "miners",
    "mag7",
    "insider"
   ]
  },
  {
   "id": "t_real",
   "label": "Reële rente 10j (TIPS)",
   "marketKey": "realYield10",
   "unit": "%",
   "dir": "up",
   "warn": 2.0,
   "danger": 2.5,
   "pillar": "rente",
   "meaning": "Grootste rem op goud. Boven 2,5% is historisch zware tegenwind; een daling is het startsein voor mijnen.",
   "affects": [
    "miners",
    "mag7"
   ]
  },
  {
   "id": "t_be",
   "label": "Inflatieverwachting 10j",
   "marketKey": "breakeven10",
   "unit": "%",
   "dir": "up",
   "warn": 2.6,
   "danger": 3.0,
   "pillar": "inflatie",
   "meaning": "Stijgt deze, dan gaat de markt de inflatie wél geloven: slecht voor obligaties, goed voor goud.",
   "affects": [
    "miners",
    "mag7"
   ]
  },
  {
   "id": "t_hy",
   "label": "Junk-spread (HY OAS)",
   "marketKey": "hySpread",
   "unit": "%",
   "dir": "up",
   "warn": 4.0,
   "danger": 5.0,
   "pillar": "krediet",
   "meaning": "Boven 5% is er kredietstress: risk-off voor small caps en tech.",
   "affects": [
    "insider",
    "mag7"
   ]
  },
  {
   "id": "t_claims",
   "label": "WW-aanvragen (wekelijks)",
   "marketKey": "claims",
   "unit": "k",
   "dir": "up",
   "warn": 260,
   "danger": 300,
   "pillar": "groei",
   "meaning": "Loopt dit op, dan beginnen de ontslagen en wordt het groeischok-scenario actueel.",
   "affects": [
    "miners",
    "crcl",
    "mag7"
   ]
  },
  {
   "id": "t_netliq",
   "label": "Netto liquiditeit, 4 weken",
   "marketKey": "netLiqChg",
   "unit": "Δ$mld",
   "dir": "down",
   "warn": -50,
   "danger": -150,
   "pillar": "liquiditeit",
   "meaning": "Daalt de liquiditeit hard, dan verliezen risico-assets hun steun.",
   "affects": [
    "mag7",
    "insider",
    "crcl"
   ]
  },
  {
   "id": "t_sahm",
   "label": "Sahm-regel (recessiesignaal)",
   "marketKey": "sahm",
   "unit": "",
   "dir": "up",
   "warn": 0.3,
   "danger": 0.5,
   "pillar": "groei",
   "meaning": "Vanaf 0,5 nemen de ontslagen echt toe: sinds 1970 een vroeg recessiesignaal.",
   "affects": [
    "miners",
    "crcl",
    "mag7",
    "insider"
   ]
  },
  {
   "id": "t_dd",
   "label": "S&P 500 onder het record",
   "marketKey": "spxDD",
   "unit": "%",
   "dir": "down",
   "warn": -10,
   "danger": -20,
   "pillar": "sentiment",
   "meaning": "−10% is een correctie, −20% een bear market: dan begint de crashfase.",
   "affects": [
    "mag7",
    "insider"
   ]
  }
 ],
 "triggerPatch": {
  "t_10y": {
   "pillar": "rente"
  },
  "t_brent": {
   "pillar": "inflatie"
  },
  "t_goldoil": {
   "pillar": "posities"
  },
  "t_gold": {
   "pillar": "posities"
  },
  "t_silver": {
   "pillar": "posities"
  },
  "t_cpi": {
   "pillar": "inflatie",
   "marketKey": "cpiYoY"
  },
  "t_jobs": {
   "pillar": "groei",
   "marketKey": "nfp3m",
   "unit": "Δk"
  },
  "t_fed": {
   "pillar": "rente"
  },
  "t_dxy": {
   "pillar": "dollar"
  },
  "t_jpy": {
   "pillar": "dollar"
  },
  "t_vix": {
   "pillar": "sentiment"
  },
  "t_btc": {
   "pillar": "sentiment"
  },
  "t_credit": {
   "pillar": "krediet"
  },
  "t_chips": {
   "pillar": "sentiment",
   "marketKey": "kospiDay"
  }
 },
 "itemPillars": {
  "gold": "posities",
  "silver": "posities",
  "crcl": "posities",
  "wti": "inflatie",
  "brent": "inflatie",
  "us10y": "rente",
  "us2y": "rente",
  "dxy": "dollar",
  "usdjpy": "dollar",
  "spx": "sentiment",
  "ndx": "sentiment",
  "kospi": "sentiment",
  "vix": "sentiment",
  "btc": "sentiment"
 },
 "itemsAdd": [
  {
   "key": "fedFunds",
   "label": "Fed-rente",
   "group": "Rente & valuta",
   "pillar": "rente",
   "value": 4.0,
   "display": "3,75–4,00%",
   "prefix": "",
   "suffix": "%",
   "decimals": 2,
   "change": "+25 bp op 16 sep",
   "asOf": "sinds 16 sep",
   "src": "Federal Reserve"
  },
  {
   "key": "us30y",
   "label": "US 30-jaars",
   "group": "Rente & valuta",
   "pillar": "rente",
   "value": 5.43,
   "prefix": "",
   "suffix": "%",
   "decimals": 2,
   "change": "piek 5,73% vorige week",
   "asOf": "15 okt",
   "src": "Benzinga"
  },
  {
   "key": "realYield10",
   "label": "Reële rente 10j (TIPS)",
   "group": "Rente & valuta",
   "pillar": "rente",
   "value": 2.78,
   "prefix": "",
   "suffix": "%",
   "decimals": 2,
   "change": "1 mnd: 2,60% · 1 jr: 1,76%",
   "asOf": "15 okt",
   "src": "TreasuryRateWatch"
  },
  {
   "key": "curve",
   "label": "Rentecurve 10j − 2j",
   "group": "Rente & valuta",
   "pillar": "rente",
   "value": 0.35,
   "prefix": "",
   "suffix": " pp",
   "decimals": 2,
   "change": "positief",
   "asOf": "15 okt",
   "src": "berekend"
  },
  {
   "key": "breakeven10",
   "label": "Inflatieverwachting 10j",
   "group": "Macro",
   "pillar": "inflatie",
   "value": 2.32,
   "prefix": "",
   "suffix": "%",
   "decimals": 2,
   "change": "10-jaars minus reële rente",
   "asOf": "15 okt",
   "src": "TreasuryRateWatch"
  },
  {
   "key": "cpiYoY",
   "label": "CPI-inflatie (j/j)",
   "group": "Macro",
   "pillar": "inflatie",
   "value": 3.7,
   "prefix": "",
   "suffix": "%",
   "decimals": 1,
   "change": "aug 3,4%",
   "asOf": "sep",
   "src": "BLS"
  },
  {
   "key": "coreCpi",
   "label": "Kerninflatie (j/j)",
   "group": "Macro",
   "pillar": "inflatie",
   "value": 2.6,
   "prefix": "",
   "suffix": "%",
   "decimals": 1,
   "change": "boven verwachting (2,5%)",
   "asOf": "sep",
   "src": "BLS"
  },
  {
   "key": "ppiYoY",
   "label": "Producentenprijzen (j/j)",
   "group": "Macro",
   "pillar": "inflatie",
   "value": 6.3,
   "prefix": "",
   "suffix": "%",
   "decimals": 1,
   "change": "hoogste sinds 2022",
   "asOf": "sep",
   "src": "BLS"
  },
  {
   "key": "nfp3m",
   "label": "Banengroei, gem. 3 mnd",
   "group": "Macro",
   "pillar": "groei",
   "value": 51,
   "prefix": "",
   "suffix": "k",
   "decimals": 0,
   "change": "jul −10k · aug +133k · sep +29k",
   "asOf": "sep",
   "src": "BLS"
  },
  {
   "key": "unrate",
   "label": "Werkloosheid",
   "group": "Macro",
   "pillar": "groei",
   "value": 4.2,
   "prefix": "",
   "suffix": "%",
   "decimals": 1,
   "change": "aug 4,1%",
   "asOf": "sep",
   "src": "BLS"
  },
  {
   "key": "claims",
   "label": "WW-aanvragen",
   "group": "Macro",
   "pillar": "groei",
   "value": 199,
   "prefix": "",
   "suffix": "k",
   "decimals": 0,
   "change": "4-wk gem. 198,5k",
   "asOf": "week 10 okt",
   "src": "US Dept. of Labor"
  },
  {
   "key": "netLiq",
   "label": "Netto liquiditeit",
   "group": "Macro",
   "pillar": "liquiditeit",
   "value": 5867,
   "prefix": "$",
   "suffix": " mld",
   "decimals": 0,
   "change": "Fed-balans − TGA − RRP",
   "asOf": "9 okt",
   "src": "eco3min (FRED-data)"
  },
  {
   "key": "hySpread",
   "label": "Junk-spread (HY OAS)",
   "group": "Macro",
   "pillar": "krediet",
   "value": 3.16,
   "prefix": "",
   "suffix": "%",
   "decimals": 2,
   "change": "rustige zone 3–5%",
   "asOf": "13 okt",
   "src": "ICE BofA via MacroRadar"
  },
  {
   "key": "kospiDay",
   "label": "Kospi dagbeweging",
   "group": "Aandelen",
   "pillar": "sentiment",
   "value": -7.57,
   "prefix": "",
   "suffix": "%",
   "decimals": 1,
   "change": "handelsstop",
   "asOf": "15 okt",
   "src": "economy.com.pk (Reuters)"
  },
  {
   "key": "spxDD",
   "label": "S&P 500 t.o.v. record",
   "group": "Aandelen",
   "pillar": "sentiment",
   "value": -2.05,
   "prefix": "",
   "suffix": "%",
   "decimals": 1,
   "ath": 7818.93,
   "athDate": "2026-10-06",
   "change": "record 7.819 op 6 okt",
   "asOf": "16 okt",
   "src": "berekend (TheStreet, Vantage)"
  },
  {
   "key": "cape",
   "label": "Waardering (Shiller-CAPE)",
   "group": "Aandelen",
   "pillar": "sentiment",
   "value": 40.5,
   "prefix": "",
   "suffix": "",
   "decimals": 1,
   "change": "record 44,2 (dec 1999) · normaal 16,6",
   "asOf": "16 okt",
   "src": "Multpl / GuruFocus"
  },
  {
   "key": "marginDebt",
   "label": "Margin debt (geleend voor aandelen)",
   "group": "Aandelen",
   "pillar": "sentiment",
   "value": 1.45,
   "prefix": "$",
   "suffix": " bln",
   "decimals": 2,
   "change": "+37% in een jaar",
   "asOf": "aug",
   "src": "FINRA via Advisor Perspectives"
  },
  {
   "key": "top10",
   "label": "Gewicht top-10 in de S&P 500",
   "group": "Aandelen",
   "pillar": "sentiment",
   "value": 40,
   "prefix": "",
   "suffix": "%",
   "decimals": 0,
   "change": "dotcom-top: ca. 27%",
   "asOf": "jul",
   "src": "S&P DJI via PrimeXBT"
  },
  {
   "key": "pcDefault",
   "label": "Wanbetaling private credit (Fitch)",
   "group": "Macro",
   "pillar": "krediet",
   "value": 6.0,
   "prefix": "",
   "suffix": "%",
   "decimals": 1,
   "change": "record · Proskauer-index 2,5% (Q2)",
   "asOf": "apr",
   "src": "Fitch via Forbes / Proskauer"
  },
  {
   "key": "sahm",
   "label": "Sahm-regel (recessiesignaal)",
   "group": "Macro",
   "pillar": "groei",
   "value": 0.0,
   "prefix": "",
   "suffix": "",
   "decimals": 2,
   "change": "alarm vanaf 0,50",
   "asOf": "sep",
   "src": "FRED"
  },
  {
   "key": "buffett",
   "label": "Buffett-indicator (beurswaarde / bbp)",
   "group": "Aandelen",
   "pillar": "sentiment",
   "value": 288,
   "display": null,
   "prefix": "",
   "suffix": "%",
   "decimals": 0,
   "change": "2000: 172% · 2007: 131% · GuruFocus-methode 235%",
   "asOf": "Q2 2026",
   "src": "Fed Z.1 via thetrading.tools"
  },
  {
   "key": "fedAssets",
   "label": "Fed-balans",
   "group": "Macro",
   "pillar": "liquiditeit",
   "value": 6.76,
   "display": null,
   "prefix": "$",
   "suffix": " bln",
   "decimals": 2,
   "change": "+$159 mld in een jaar · QT gestopt",
   "asOf": "14 okt",
   "src": "Fed H.4.1"
  }
 ],
 "sourcesAdd": [
  {
   "label": "TreasuryRateWatch: reële rente en inflatieverwachting",
   "url": "https://treasuryratewatch.com/daily/tips-real-yields"
  },
  {
   "label": "MacroRadar: junk-spread (HY OAS)",
   "url": "https://www.macroradar.io/high-yield-spread"
  },
  {
   "label": "FXStreet: WW-aanvragen week 10 okt",
   "url": "https://www.fxstreet.com/news/us-initial-jobless-claims-rose-to-199k-last-week-202610151242"
  },
  {
   "label": "eco3min: Net Liquidity Index",
   "url": "https://eco3min.fr/en/net-liquidity-index-dataset/"
  },
  {
   "label": "Equiti: Fed-balans en Warsh",
   "url": "https://www.equiti.com/sc-en/news/global-macro-analysis/kevin-warsh-fed-balance-sheet-reserves-qt/"
  },
  {
   "label": "TradersUnion: George Gammon in 2026",
   "url": "https://tradersunion.com/news/tag/georgegammon/"
  },
  {
   "label": "TradingView: Traders Reality Main (methode)",
   "url": "https://www.tradingview.com/script/Etj1ixAs-Traders-Reality-Main"
  },
  {
   "label": "Vantage Markets: S&P 500-record 6 okt 2026",
   "url": "https://www.vantagemarkets.com/market-analysis/sp500-today-record-yields-earnings-cpi-october-12-2026/"
  },
  {
   "label": "Multpl: Shiller-CAPE",
   "url": "https://www.multpl.com/shiller-pe/table/by-year"
  },
  {
   "label": "Forbes: wanbetalingen private credit 2026",
   "url": "https://www.forbes.com/sites/mayrarodriguezvalladares/2026/05/24/rising-private-credit-defaults-are-testing-banks-and-insurers/"
  },
  {
   "label": "Advisor Perspectives: margin debt aug 2026",
   "url": "https://www.advisorperspectives.com/dshort/updates/2026/09/17/margin-debt-finra-august-2026.pdf"
  },
  {
   "label": "PrimeXBT: concentratie top-10 S&P 500",
   "url": "https://primexbt.com/news/sp-500-hits-its-most-concentrated-top-10-weighting-since-the-mid-1960s/"
  },
  {
   "label": "FRED: Sahm-regel",
   "url": "https://fred.stlouisfed.org/series/SAHMREALTIME"
  },
  {
   "label": "Zeal: goudaandelen in crashes (2000–02, 2008)",
   "url": "https://zealllc.com/2008/huipanic.htm"
  },
  {
   "label": "Mining.com: goud in 1973–74 en 2008",
   "url": "https://www.mining.com/web/will-next-market-crash-like-2008-1973-history-predicts-amazing-run-gold-gold-stocks/"
  },
  {
   "label": "thetrading.tools: Buffett-indicator (Fed Z.1)",
   "url": "https://www.thetrading.tools/buffett-indicator"
  },
  {
   "label": "Federal Reserve H.4.1: balans",
   "url": "https://www.federalreserve.gov/releases/h41/current/"
  }
 ]
}
HP_EINDE_SEED_MACRO_PATCH_JSON

# ---- seed/market.json ----
COPY <<"HP_EINDE_SEED_MARKET_JSON" /app/seed/market.json
{
  "updatedAt": "2026-10-16T09:00:00+02:00",
  "updatedBy": "Claude (webzoekopdracht)",
  "note": "Momentopnames uit nieuwsbronnen, geen live feed. Elke regel toont zijn eigen tijdstip.",
  "items": [
    { "key": "gold", "label": "Goud", "group": "Metalen", "value": 4185, "prefix": "$", "suffix": "", "decimals": 0, "change": "+0,7%", "asOf": "16 okt, vroege handel", "src": "Benzinga" },
    { "key": "silver", "label": "Zilver", "group": "Metalen", "value": 56.78, "prefix": "$", "suffix": "", "decimals": 2, "change": "+1,6% · −10% in 1 mnd", "asOf": "15 okt, vroege handel", "src": "TheStreet / Fortune" },
    { "key": "wti", "label": "WTI-olie", "group": "Energie", "value": 97.0, "prefix": "$", "suffix": "", "decimals": 1, "change": "+1,0%", "asOf": "16 okt, vroege handel", "src": "Benzinga" },
    { "key": "brent", "label": "Brent-olie", "group": "Energie", "value": 104.6, "prefix": "$", "suffix": "", "decimals": 1, "change": "−1,3%", "asOf": "15 okt, vroege handel", "src": "TheStreet" },
    { "key": "us10y", "label": "US 10-jaars", "group": "Rente & valuta", "value": 5.085, "prefix": "", "suffix": "%", "decimals": 2, "change": "−10 bp · top 5,36% vorige week", "asOf": "15 okt", "src": "TheStreet / Benzinga" },
    { "key": "us2y", "label": "US 2-jaars", "group": "Rente & valuta", "value": 4.74, "prefix": "", "suffix": "%", "decimals": 2, "change": "", "asOf": "15 okt", "src": "Benzinga" },
    { "key": "dxy", "label": "Dollarindex", "group": "Rente & valuta", "value": 101.77, "prefix": "", "suffix": "", "decimals": 2, "change": "−0,3%", "asOf": "16 okt, vroege handel", "src": "Benzinga" },
    { "key": "usdjpy", "label": "USD/JPY", "group": "Rente & valuta", "value": 157.88, "prefix": "", "suffix": "", "decimals": 2, "change": "", "asOf": "16 okt", "src": "FXStreet" },
    { "key": "spx", "label": "S&P 500", "group": "Aandelen", "value": 7659, "prefix": "", "suffix": "", "decimals": 0, "change": "−1,1%", "asOf": "16 okt, slot", "src": "TheStreet" },
    { "key": "ndx", "label": "Nasdaq Comp.", "group": "Aandelen", "value": 26713.02, "prefix": "", "suffix": "", "decimals": 0, "change": "+0,1% · −1,9% op 14 okt", "asOf": "15 okt, slot", "src": "TheStreet / Yahoo" },
    { "key": "kospi", "label": "Kospi", "group": "Aandelen", "value": 5554.22, "prefix": "", "suffix": "", "decimals": 0, "change": "−7,6%", "asOf": "15 okt, slot", "src": "economy.com.pk (Reuters)" },
    { "key": "vix", "label": "VIX", "group": "Aandelen", "value": 16.87, "prefix": "", "suffix": "", "decimals": 1, "change": "+10,5%", "asOf": "14 okt, slot", "src": "Yahoo Finance" },
    { "key": "crcl", "label": "Circle (CRCL)", "group": "Jouw posities", "value": 84.4, "prefix": "$", "suffix": "", "decimals": 2, "change": "+6,2% intraday", "asOf": "15 okt, intraday", "src": "StocksToTrade" },
    { "key": "btc", "label": "Bitcoin", "group": "Jouw posities", "value": 82100, "prefix": "$", "suffix": "", "decimals": 0, "change": "+0,9% (24u)", "asOf": "16 okt", "src": "Benzinga" }
  ]
}
HP_EINDE_SEED_MARKET_JSON

# ---- seed/plan.json ----
COPY <<"HP_EINDE_SEED_PLAN_JSON" /app/seed/plan.json
{
  "meta": {
    "asOf": "2026-10-16",
    "updatedAt": "2026-10-16T09:00:00+02:00",
    "version": 1,
    "lastSource": "Startversie door Claude: juli-plan herzien met marktdata t/m 16 okt 2026",
    "disclaimer": "Persoonlijk educatief plan. Geen beleggingsadvies; kansen zijn inschattingen, geen voorspellingen."
  },
  "regime": {
    "name": "Stagflatie met renteschok",
    "phase": "Late cyclus",
    "riskLevel": "verhoogd",
    "thesis": "Inflatie versnelt weer (CPI 3,7%, groothandelsprijzen +6,3%) terwijl de banenmarkt stilvalt (+29k in september). De Fed verhoogde in september en sluit een volgende stap niet uit. Olie staat boven $100 door de Hormuz-blokkade, de 10-jaarsrente raakte vorige week 5,36%, en de AI-chiprally kreeg een flinke tik (Kospi −7,6% op 15 okt). In deze mix is de rente de spil van je hele portefeuille.",
    "masterVariable": {
      "name": "US 10-jaarsrente",
      "why": "Drie van je vier pijlers (mijnen, Mag 7, small caps) dalen als de rente stijgt. Alleen Circle verdient méér aan hoge rente. Kijk hier eerst naar, elke dag."
    },
    "changesSinceJuly": [
      "Fed: van 'mogelijk een verhoging' naar daadwerkelijk +25 bp (16 sep), range nu 3,75–4,00%.",
      "10-jaarsrente: van ~4,5% naar ~5,1% (top 5,36%).",
      "Olie: het risicoscenario uit juli ($100+) is uitgekomen: Brent ~$104.",
      "Goud: niet de verwachte veilige haven, −4% in een maand en 25% onder het record van $5.590 (28 jan).",
      "AI: chip-uitverkoop in Azië en de VS; de 'AI houdt alles overeind'-these wordt nu getest."
    ]
  },
  "portfolioCheck": {
    "headline": "Je portefeuille is niet defensief meer",
    "points": [
      "Het juli-plan ging uit van fysiek goud + USDC (stabiel). Je grootste posities nu zijn mijnaandelen, het Circle-aandeel, Mag 7 en small caps: allemaal aandelen, met hogere beweeglijkheid dan goud of cash.",
      "Mijnen bewegen 1,5 à 2× zo hard als goud, in beide richtingen, en lijden onder hoge olieprijzen (energiekosten).",
      "Het CRCL-aandeel is geen USDC: het aandeel schommelt als een groeiaandeel, ook al is de stablecoin stabiel.",
      "Er zit geen cash- of kortlopende obligatiebuffer in. Zonder droog kruit kun je de 'koop bij de dip'-regels in dit plan niet uitvoeren.",
      "Natuurlijke hedge: CRCL profiteert van hoge rente, mijnen van dalende rente. Bij een scenario-omslag schuif je tussen deze twee in plaats van alles tegelijk te verkopen."
    ]
  },
  "actionsNow": [
    "Geen nieuwe grote aankopen vóór de Fed (28 okt) en de techcijfers (21–29 okt), tenzij een planregel hieronder afgaat.",
    "Mijnen: aanhouden, niet bijkopen. Let op goud $4.000 (weekslot) en de goud/olie-ratio onder 40.",
    "Circle: aanhouden tot de kwartaalcijfers van 4 nov; beslis daarna op USDC-groei.",
    "Mag 7: wachten. Eerste toets is Meta op 21 okt: houdt de AI-investeringsbegroting stand?",
    "Insider-trades: alleen meldingen jonger dan 30 dagen, maximaal 1–2% per positie, harde stop.",
    "Beslis bewust hoeveel droog kruit (cash/T-bills) je wilt aanhouden voor de dip-regels."
  ],
  "scenarios": [
    {
      "id": "s1",
      "name": "Stagflatie-grind",
      "prob": 45,
      "horizon": "3–6 maanden",
      "desc": "Olie blijft $95–115, CPI 3,5–4%, de Fed pauzeert in oktober maar verhoogt nog één keer voor het eind van het jaar. 10-jaarsrente schommelt tussen 4,9 en 5,4%. Banengroei zwak maar positief. Aandelen bewegen zijwaarts met dalingen van 5–10%.",
      "signals": ["CPI blijft boven 3,5%", "Brent tussen $95 en $115", "NFP tussen 0 en +100k", "10j tussen 4,9% en 5,4%"],
      "impact": { "miners": -1, "crcl": 1, "mag7": -1, "insider": -1 },
      "actions": [
        "Mijnen houden zonder bij te kopen; hoge olie drukt marges.",
        "CRCL is hier je sterkste pijler: hoge rente = meer rente-inkomsten op reserves.",
        "Mag 7 alleen selectief bijkopen na sterke cijfers, in drie stappen.",
        "Small caps klein houden; herfinanciering is duur."
      ]
    },
    {
      "id": "s2",
      "name": "Olieschok en escalatie",
      "prob": 20,
      "horizon": "0–3 maanden",
      "desc": "Hormuz escaleert verder (meer tankeraanvallen, bredere blokkade), Brent boven $120, CPI boven 4%. De Fed verhoogt in oktober of december, de 10-jaarsrente breekt door 5,4%. Risk-off op de aandelenmarkt.",
      "signals": ["Brent > $115", "CPI > 4%", "10j > 5,36% (nieuwe top)", "Kans op Fed-verhoging > 50%"],
      "impact": { "miners": 0, "crcl": 0, "mag7": -2, "insider": -2 },
      "actions": [
        "Mijnen: eerst geraakt door liquidatie en energiekosten, daarna kan goud als veilige haven aantrekken. Niet in paniek verkopen; wacht op goud boven $4.450.",
        "Mag 7 en small caps afbouwen volgens de stopregels.",
        "CRCL houden: hogere rente compenseert crypto-zwakte deels."
      ]
    },
    {
      "id": "s3",
      "name": "Groeischok en kredietbreuk",
      "prob": 20,
      "horizon": "1–6 maanden",
      "desc": "De banenmarkt kantelt naar krimp, private credit-fondsen beperken uitstappen verder, AI-investeringen worden teruggeschroefd. De rente daalt snel, de Fed draait naar renteverlagingen. Vergelijk 7 augustus: −23k banen en GDX +21% in één week.",
      "signals": ["NFP negatief", "10j < 4,8%", "Nieuwe gating bij grote kredietfondsen", "Hyperscalers verlagen capex-guidance"],
      "impact": { "miners": 2, "crcl": -2, "mag7": -2, "insider": -2 },
      "actions": [
        "Mijnen bijkopen in drie tranches: dit is hun beste scenario.",
        "CRCL afbouwen of afdekken: renteverlagingen raken de kern van het verdienmodel.",
        "Mag 7 en small caps afbouwen; wachten op capitulatie voor herinstap."
      ]
    },
    {
      "id": "s4",
      "name": "De-escalatie en zachte landing",
      "prob": 15,
      "horizon": "3–9 maanden",
      "desc": "Hormuz gaat weer open, olie zakt onder $85, inflatie koelt af, de 10-jaarsrente daalt richting 4,5%, de Fed is klaar met verhogen. Aandelen herstellen, techleiders voorop.",
      "signals": ["Brent < $85", "CPI richting 3%", "10j < 4,7%", "Akkoord VS–Iran"],
      "impact": { "miners": 1, "crcl": 1, "mag7": 2, "insider": 2 },
      "actions": [
        "Mag 7 opbouwen; dit is hun scenario.",
        "Mijnen houden: goud vlakker, maar lagere energiekosten verbeteren de marges.",
        "CRCL houden: rente iets lager, maar crypto-sentiment beter."
      ]
    }
  ],
  "positions": [
    {
      "id": "miners",
      "name": "Goud- en zilvermijnen",
      "tickers": "Jouw mijnaandelen/ETF's (bijv. GDX, GDXJ, SIL, SILJ)",
      "role": "Grootste positie · inflatie- en crisishefboom",
      "stance": "aanhouden",
      "stanceNote": "Houden, niet bijkopen tot goud en de rente een richting kiezen.",
      "myWeight": null,
      "now": "Goud ~$4.185, 25% onder het record ($5.590, 28 jan). Zilver ~$56,8, ruim 50% onder de top (boven $121, 29 jan) en −10% in een maand. WTI ~$97 drukt de marges: een analyse van begin september waarschuwde dat goud richting $4.000 met olie boven $95 de margewinst binnen twee kwartalen kan wegvagen. Daar zitten we nu dicht tegenaan.",
      "bull": ["Fed draait naar renteverlagingen (groeischok)", "Dalende reële rente", "Olie omlaag = hogere marges", "Geopolitieke escalatie trekt veilige-havenvraag"],
      "bear": ["10j boven 5% houdt reële rente hoog", "Olie > $100 verhoogt kosten", "Sterke dollar", "Gedwongen verkopen bij een brede aandelendaling"],
      "levels": [
        { "label": "Goud $4.000", "meaning": "Cruciale steun. Weekslot eronder = afbouwsignaal." },
        { "label": "Goud $4.200–4.450", "meaning": "Herovering op volume = bevestiging nieuwe opwaartse trend." },
        { "label": "Zilver $55", "meaning": "Steun; eronder versnelt de daling in zilvermijnen." },
        { "label": "Zilver $60–65", "meaning": "Herstelzone; boven $64 is de trend weer positief." },
        { "label": "Goud/olie < 40", "meaning": "Margedruk: energie eet de winst op." }
      ],
      "rules": [
        "Niet bijkopen zolang goud op weekbasis onder $4.200 sluit én WTI boven $95 staat.",
        "Weekslot goud onder $4.000: verklein met een derde, junior- en zilvermijnen eerst (hoogste hefboom).",
        "Bijkopen in drie tranches zodra NFP negatief is, óf de 10j onder 4,8% zakt, óf goud boven $4.450 sluit.",
        "Stel zelf een maximum voor deze positie vast (bijvoorbeeld 25–35% van je vermogen) en houd je eraan."
      ],
      "catalysts": ["FOMC 28 okt", "NFP 6 nov", "CPI 10 nov", "Kwartaalcijfers mijnbouwers (kosten per ounce)"]
    },
    {
      "id": "crcl",
      "name": "Circle (CRCL)",
      "tickers": "CRCL",
      "role": "Rente- en stablecoinpositie",
      "stance": "aanhouden",
      "stanceNote": "Houden tot de cijfers van 4 nov; dan beslissen op USDC-groei.",
      "myWeight": null,
      "now": "Rond $84 (15 okt, +6% intraday op CFTC-nieuws over crypto-marktstructuur), na een terugval van de lage $90. USDC-circulatie $73,3 mrd per 30 juni (+19% j/j). Circa 95% van de omzet is rente op de reserves ($667,7 mln van $701,3 mln in Q2). Eigen vuistregel: elke 0,25% renteverschil is ruwweg $45 mln per kwartaal aan rente-inkomsten.",
      "bull": ["Rente blijft langer hoog", "USDC-circulatie groeit", "Duidelijke Amerikaanse regels (CFTC, marktstructuur)", "Circle Payments Network groeit snel (+76% k/k in Q2)"],
      "bear": ["Fed draait naar renteverlagingen", "Crypto risk-off (BTC < $75k)", "USDC-groei stokt", "Concurrentie van Tether en bank-stablecoins"],
      "levels": [
        { "label": "$90–93", "meaning": "Weerstand: recente top van waar het aandeel terugviel." },
        { "label": "$80", "meaning": "Steun in de huidige range." },
        { "label": "$75", "meaning": "Openingsniveau 15 okt; weekslot eronder = trendbreuk." }
      ],
      "rules": [
        "Niet bijkopen vóór de cijfers van 4 nov.",
        "Na de cijfers alleen bijkopen als USDC-circulatie kwartaal-op-kwartaal groeit.",
        "Weekslot onder $75 terwijl BTC onder $75k staat: verklein met een derde.",
        "Draait de Fed naar verlagingen (scenario 3), schuif dan geleidelijk van CRCL naar mijnen."
      ],
      "catalysts": ["FOMC 28 okt", "Q3-cijfers 4 nov", "CFTC-regelgeving", "BTC-trend"]
    },
    {
      "id": "mag7",
      "name": "Magnificent 7",
      "tickers": "AAPL · MSFT · GOOGL · AMZN · META · NVDA · TSLA",
      "role": "Groei- en AI-positie",
      "stance": "voorzichtig",
      "stanceNote": "Wachten op de cijfers; AI-investeringen zijn de toets.",
      "myWeight": null,
      "now": "Chip-uitverkoop: Kospi −7,6% op 15 okt (handel tijdelijk stilgelegd), TSMC −4% ondanks recordwinst, Nvidia −3,2% en techsector −2,6% op 14 okt. Een 10-jaarsrente boven 5% drukt de waardering van langlopende groeiwinsten. Nasdaq ~26.713.",
      "bull": ["Hyperscalers houden AI-capex hoog", "Rente zakt onder 5%", "Sterke cloud- en advertentiecijfers", "De-escalatie Hormuz"],
      "bear": ["Capex-verlaging of twijfel over AI-rendement", "10j > 5,36%", "Verdere chip-uitverkoop in Azië", "Nieuwe Fed-verhoging"],
      "levels": [
        { "label": "S&P 500 ~7.700", "meaning": "Huidig niveau; −10% vanaf de top = risk-off-regel." },
        { "label": "10j 5,0%", "meaning": "Boven deze grens geen nieuwe techaankopen." }
      ],
      "rules": [
        "Niet bijkopen vóór 28–29 okt (Microsoft, Alphabet, Amazon en de Fed).",
        "Na de cijfers in drie stappen bijkopen, alleen als de capex-guidance stand houdt én de 10j onder 5% staat.",
        "Verlaagt een bedrijf zijn AI-investeringen of mist het de omzetverwachting, verklein dan die naam.",
        "Nvidia (17 nov) pas beoordelen na de hyperscaler-cijfers; die bepalen de vraag."
      ],
      "catalysts": ["META en TSLA 21 okt", "MSFT en GOOGL 28 okt", "AMZN 29 okt", "AAPL 2 nov", "NVDA 17 nov"]
    },
    {
      "id": "insider",
      "name": "Insider-trades (Wolf of Washington)",
      "tickers": "Kleine aandelen uit politieke transactiemeldingen",
      "role": "Satelliet · hoog risico, klein houden",
      "stance": "voorzichtig",
      "stanceNote": "Klein houden met strikte regels; hoge rente is slecht voor small caps.",
      "myWeight": null,
      "now": "Wolf of Washington volgt aandelentransacties van Amerikaanse politici op basis van de verplichte STOCK Act-meldingen. Die meldingen mogen tot 45 dagen na de transactie komen, dus je stapt vaak weken later in dan de politicus. De claim van 3–5% outperformance komt van de app zelf en is niet onafhankelijk getoetst. Kleine bedrijven hebben het extra zwaar bij een rente van 5% (dure herfinanciering).",
      "bull": ["Clusters: meerdere politici of commissieleden in hetzelfde aandeel", "Rente daalt", "Sectorwind mee (defensie, energie bij escalatie)"],
      "bear": ["Late melding (koers al gelopen)", "Lage liquiditeit en brede spreads", "Kredietstress raakt kleine bedrijven eerst"],
      "levels": [
        { "label": "Max 1–2% per positie", "meaning": "Een mislukte trade mag je plan niet raken." },
        { "label": "Max ~10% totaal", "meaning": "Satelliet blijft satelliet." },
        { "label": "Stop −15 à −20%", "meaning": "Harde stop, geen uitzonderingen." }
      ],
      "rules": [
        "Check transactiedatum tegen meldingsdatum: ouder dan 30 dagen = halve positie of overslaan.",
        "Alleen aandelen met voldoende dagvolume (vuistregel > $5 mln per dag).",
        "Nooit bijkopen in een verliezer.",
        "Weeg clusters en commissie-relevantie zwaarder dan losse trades."
      ],
      "catalysts": ["Nieuwe meldingen in de app", "Rentebesluit 28 okt", "Small-cap-index vs. 10j"]
    }
  ],
  "triggers": [
    { "id": "t_10y", "label": "US 10-jaarsrente", "marketKey": "us10y", "unit": "%", "dir": "up", "warn": 5.0, "danger": 5.36, "meaning": "Hoofdvariabele. Boven 5% staan mijnen, Mag 7 en small caps onder druk; alleen Circle profiteert.", "affects": ["miners", "mag7", "insider", "crcl"] },
    { "id": "t_brent", "label": "Brent-olie", "marketKey": "brent", "unit": "$", "dir": "up", "warn": 95, "danger": 115, "meaning": "Boven $100 = inflatiedruk en hogere kosten voor mijnen.", "affects": ["miners", "mag7"] },
    { "id": "t_goldoil", "label": "Goud/olie-ratio", "computed": "gold/wti", "unit": "×", "dir": "down", "warn": 45, "danger": 40, "meaning": "Grove maat voor mijnmarges: onder 40 eten energiekosten de winst op.", "affects": ["miners"] },
    { "id": "t_gold", "label": "Goud", "marketKey": "gold", "unit": "$", "dir": "down", "warn": 4200, "danger": 4000, "meaning": "Weekslot onder $4.000 = afbouwregel mijnen.", "affects": ["miners"] },
    { "id": "t_silver", "label": "Zilver", "marketKey": "silver", "unit": "$", "dir": "down", "warn": 60, "danger": 55, "meaning": "Onder $55 versnelt de daling in zilvermijnen.", "affects": ["miners"] },
    { "id": "t_cpi", "label": "CPI-inflatie (j/j)", "current": 3.7, "asOf": "sep, gepubliceerd 14 okt", "unit": "%", "dir": "up", "warn": 3.5, "danger": 4.0, "meaning": "Boven 4% wordt een extra Fed-verhoging waarschijnlijk.", "affects": ["mag7", "insider", "crcl"] },
    { "id": "t_jobs", "label": "Banengroei, gem. 3 mnd", "current": 51, "asOf": "jul −10k, aug +133k, sep +29k", "unit": "k", "dir": "down", "warn": 75, "danger": 0, "meaning": "Onder nul = groeischok: goed voor mijnen, slecht voor CRCL en Mag 7.", "affects": ["miners", "crcl", "mag7"] },
    { "id": "t_fed", "label": "Kans Fed-verhoging 28 okt", "current": 15, "asOf": "CME FedWatch ~85% pauze, 16 okt", "unit": "%", "dir": "up", "warn": 40, "danger": 70, "meaning": "Een verhoging zou de rente verder opdrijven: risk-off.", "affects": ["mag7", "insider", "miners", "crcl"] },
    { "id": "t_dxy", "label": "Dollarindex", "marketKey": "dxy", "unit": "", "dir": "up", "warn": 103, "danger": 105, "meaning": "Sterke dollar drukt goud en grondstoffen.", "affects": ["miners"] },
    { "id": "t_jpy", "label": "USD/JPY", "marketKey": "usdjpy", "unit": "", "dir": "up", "warn": 158, "danger": 160, "meaning": "Boven 160 dreigt ingrijpen door Japan: carry-trades worden snel afgebouwd.", "affects": ["mag7", "insider"] },
    { "id": "t_vix", "label": "VIX (angstindex)", "marketKey": "vix", "unit": "", "dir": "up", "warn": 22, "danger": 30, "meaning": "Boven 30 = paniekmodus; dan geen nieuwe posities openen.", "affects": ["mag7", "insider"] },
    { "id": "t_btc", "label": "Bitcoin", "marketKey": "btc", "unit": "$", "dir": "down", "warn": 75000, "danger": 65000, "meaning": "Crypto-sentiment stuurt CRCL mee.", "affects": ["crcl"] },
    { "id": "t_credit", "label": "Private credit: uitstapverzoeken", "current": 16.8, "asOf": "Blue Owl OCIC Q3 (Q2: 18,8%), plafond 5%", "unit": "%", "dir": "up", "warn": 10, "danger": 25, "meaning": "Hoe ver de vraag naar uitstap boven het plafond ligt: maat voor kredietstress.", "affects": ["insider", "mag7"] },
    { "id": "t_chips", "label": "Chip-stress: Kospi dagbeweging", "current": -7.6, "asOf": "15 okt", "unit": "%", "dir": "down", "warn": -3, "danger": -6, "meaning": "Een grote daling in Korea ging eerder vooraf aan druk op Nvidia en de Nasdaq.", "affects": ["mag7"] }
  ],
  "exposure": {
    "factors": ["Rente ↑", "Olie ↑", "Dollar ↑", "Goud ↑", "AI-capex ↑", "Crypto ↑", "Kredietstress ↑"],
    "rows": [
      { "id": "miners", "values": [-2, -1, -1, 2, 0, 0, 1] },
      { "id": "crcl", "values": [2, 0, 0, 0, 0, 2, -1] },
      { "id": "mag7", "values": [-2, -1, -1, 0, 2, 0, -1] },
      { "id": "insider", "values": [-2, -1, 0, 0, 0, 0, -2] }
    ],
    "note": "+2 = profiteert sterk, −2 = lijdt sterk als die factor stijgt. Eigen inschatting."
  },
  "calendar": [
    { "date": "2026-10-21", "time": "nabeurs", "event": "Cijfers Meta en Tesla", "why": "Eerste toets van de AI-investeringsbegroting.", "affects": ["mag7"] },
    { "date": "2026-10-28", "time": "19:00", "event": "Fed-rentebesluit", "why": "Markt prijst ~85% pauze. Let op de toon over een volgende verhoging.", "affects": ["miners", "crcl", "mag7", "insider"] },
    { "date": "2026-10-28", "time": "nabeurs", "event": "Cijfers Microsoft en Alphabet", "why": "Cloudgroei en capex-guidance bepalen de vraag naar chips.", "affects": ["mag7"] },
    { "date": "2026-10-29", "time": "13:30", "event": "BBP Q3 (eerste raming) en PCE-inflatie sep", "why": "Groei vs. inflatie: welk scenario wint terrein?", "affects": ["miners", "crcl", "mag7"] },
    { "date": "2026-10-29", "time": "nabeurs", "event": "Cijfers Amazon (verwacht)", "why": "AWS-groei en investeringen.", "affects": ["mag7"] },
    { "date": "2026-10-30", "time": "04:00", "event": "Bank of Japan-besluit", "why": "Leunt tegen een tweede verhoging op rij; een verrassing raakt de yen-carry.", "affects": ["mag7", "insider"] },
    { "date": "2026-11-02", "time": "nabeurs", "event": "Cijfers Apple (verwacht)", "why": "Minder AI-capex-gevoelig; consumentenvraag.", "affects": ["mag7"] },
    { "date": "2026-11-04", "time": "", "event": "Kwartaalcijfers Circle (Q3)", "why": "USDC-groei, rente-inkomsten, distributiekosten. Beslismoment CRCL.", "affects": ["crcl"] },
    { "date": "2026-11-06", "time": "14:30", "event": "Banenrapport oktober (NFP)", "why": "Negatief cijfer = groeischok-scenario.", "affects": ["miners", "crcl", "mag7", "insider"] },
    { "date": "2026-11-10", "time": "14:30", "event": "CPI oktober", "why": "Boven 4% maakt een decemberverhoging waarschijnlijk.", "affects": ["miners", "crcl", "mag7", "insider"] },
    { "date": "2026-11-13", "time": "14:30", "event": "PPI oktober", "why": "Groothandelsprijzen liepen in sep op met 6,3% j/j.", "affects": ["mag7"] },
    { "date": "2026-11-17", "time": "", "event": "Cijfers Nvidia", "why": "Bevestigt of ontkracht de AI-chipvraag.", "affects": ["mag7"] },
    { "date": "2026-11-25", "time": "14:30", "event": "PCE-inflatie oktober", "why": "De inflatiemaat waar de Fed op stuurt.", "affects": ["miners", "crcl", "mag7"] }
  ],
  "claims": [
    { "text": "De Fed blijft hawkish en verhoogt mogelijk.", "source": "Handelsplan juli", "date": "2026-07-22", "status": "bevestigd", "note": "+25 bp op 16 sep; notulen wijzen op nog een stap dit jaar." },
    { "text": "Olie naar $100+ bij escalatie rond Hormuz.", "source": "Handelsplan juli", "date": "2026-07-22", "status": "bevestigd", "note": "Brent ~$104–106 half oktober; blokkade sinds 14 juli hersteld." },
    { "text": "Goud is de ultieme veilige haven in deze fase.", "source": "Handelsplan juli", "date": "2026-07-22", "status": "weerlegd", "note": "Goud −4% in een maand ondanks oorlog en inflatie; de hoge reële rente weegt zwaarder." },
    { "text": "Private credit is de nieuwe junkbondmarkt; fondsen beperken uitstappen.", "source": "Monetary Matters / Ed Dowd (via juli-plan)", "date": "2026-07-22", "status": "bevestigd", "note": "Blue Owl Q3: $4,2 mrd aan uitstapverzoeken (Q2 $4,7 mrd), techfonds 39%; 5%-plafond. Stress licht afnemend." },
    { "text": "Verzekeraars hebben via CLO-tranches 90–100× effectieve hefboom.", "source": "Monetary Matters / Ed Dowd (via juli-plan)", "date": "2026-07-22", "status": "open", "note": "Bron-claim, niet onafhankelijk bevestigd." },
    { "text": "Korea is de waarschuwing: hefboomproducten veroorzaken crashes.", "source": "Handelsplan juli", "date": "2026-07-22", "status": "open", "note": "Kospi −7,6% op 15 okt met handelsstop na chip-uitverkoop; rol van hefboom-ETF's niet bevestigd in de bronnen." },
    { "text": "Record margin debt ($1,42 bln) maakt de markt kwetsbaar.", "source": "Handelsplan juli (FINRA, mei)", "date": "2026-07-22", "status": "open", "note": "Nieuwere FINRA-cijfers nog niet verwerkt." },
    { "text": "AI-euforie houdt de aandelenmarkt overeind.", "source": "Handelsplan juli", "date": "2026-07-22", "status": "open", "note": "Onder druk: chip-uitverkoop half oktober. Cijfers 21 okt–17 nov beslissen." }
  ],
  "sources": [
    { "label": "TheStreet, slot 15 okt", "url": "https://www.thestreet.com/stock-market-today/stock-market-today-dow-jones-sp-500-nasdaq-updates-oct-15-2026" },
    { "label": "Benzinga, 16 okt (rente, dollar, olie, goud, BTC, FedWatch)", "url": "https://www.benzinga.com/markets/equities/26/10/62404483/stock-market-today-dow-sp-500-futures-rise-as-bessent-intensifies-economic-pressure-on-iran-treasury-yields-cool-off-tsla-aa-ibkr-in-focus" },
    { "label": "Chase: Fed sep-verhoging en CPI sep", "url": "https://www.chase.com/personal/investments/learning-and-insights/article/will-the-federal-reserve-hike-rates-at-october-2026-fomc-meeting" },
    { "label": "FXMacroData: banenrapport september", "url": "https://fxmacrodata.com/articles/september-2026-nfp-jobs-report-why-it-matters" },
    { "label": "Fortune: zilver 15 okt", "url": "https://fortune.com/article/current-price-of-silver-10-15-2026/" },
    { "label": "Metalcharts: goudrecord", "url": "https://metalcharts.org/gold-all-time-high" },
    { "label": "Faruzo: zilverrecord en daling", "url": "https://www.faruzo.com/blog/silver-price-statistics-2026/" },
    { "label": "Discovery Alert: mijnen vs. goud (sep)", "url": "https://discoveryalert.com/analysis/gold-miners-outperform-bullion-september-2026/" },
    { "label": "Mining.com: mijnen +20% (7 aug)", "url": "https://www.mining.com/gold-miners-surge-more-than-20-in-breakout-week/" },
    { "label": "StocksToTrade: CRCL 15 okt", "url": "https://stockstotrade.com/news/circle-internet-group-inc-crcl-news-2026_10_15/" },
    { "label": "Forex Crunch: Circle en rente", "url": "https://www.forexcrunch.com/blog/2026/10/10/circle-usdc-earnings-bet-us-interest-rates/" },
    { "label": "Circle: cijfers Q3 op 4 nov", "url": "https://www.circle.com/pressroom/circle-to-announce-q3-2026-financial-results-on-november-4-2026" },
    { "label": "Smart Calendars: Mag 7-cijferdata", "url": "https://www.smartcalendars.ai/en/feeds/magnificent-7-earnings-calendar" },
    { "label": "FedRateCalc: macrokalender", "url": "https://fedratecalc.com/us-economic-calendar/" },
    { "label": "Wikipedia: Hormuz-crisis 2026", "url": "https://en.wikipedia.org/wiki/2026_Strait_of_Hormuz_crisis" },
    { "label": "24/7 Wall St.: private credit (Blue Owl)", "url": "https://247wallst.com/investing/2026/10/05/the-2-trillion-private-credit-market-just-got-some-good-news-but-its-biggest-test-may-still-be-coming/" },
    { "label": "FinanceCalendar: BOJ 30 okt", "url": "https://www.financecalendar.com/event/bank-of-japan-rate-decision-october-2026/" },
    { "label": "Wolf of Washington (App Store)", "url": "https://apps.apple.com/app/id6744653240" }
  ]
}
HP_EINDE_SEED_PLAN_JSON

EXPOSE 8080
# Tabellen, startgegevens en de planner regelt de app zelf zodra PostgreSQL bereikbaar is.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --proxy-headers --forwarded-allow-ips='*'"]
