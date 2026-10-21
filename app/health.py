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
