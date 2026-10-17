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

from . import ai, db, jobs, mail, patch, quotes, scheduler

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
def health():
    return {"ok": True, "database": db.ping() if db.configured() else False}


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
