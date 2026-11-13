"""Lange AI-verzoeken als achtergrondtaak.

De pagina start een taak (POST /api/ai/jobs) en vraagt daarna om de paar seconden of hij klaar is
(GET /api/ai/jobs/<id>). Zo staat er nooit een verzoek minutenlang open: Railway kapt een verzoek
na 5 minuten af, en een lang transcript kost Grok soms meer tijd dan dat.

De stand van elke taak staat ook in de database (kv 'aijob:<id>'). Sluit je de pagina, dan loopt de
taak door en haalt de pagina het resultaat later op. Herstart de server tijdens een taak, dan meldt
de taak dat netjes ('restarted'), zodat de pagina hem opnieuw kan starten.
"""
import json
import logging
import secrets
import threading
import time

from . import ai, db

log = logging.getLogger("handelsplan.aijobs")

MAX_RUNNING = 2            # tegelijk lopende analyses
KEEP_SECONDS = 24 * 3600   # zo lang blijft een resultaat op te halen
TIMEOUT = 900              # Grok krijgt per taak maximaal 15 minuten

_jobs = {}
_lock = threading.Lock()


def _key(jid):
    return f"aijob:{jid}"


def _save(job):
    try:
        db.set_json(_key(job["id"]), job)
    except db.DBError:
        pass


def _cleanup():
    now = time.time()
    with _lock:
        for jid in [j for j, v in _jobs.items() if v["status"] != "bezig" and now - v.get("endedAt", now) > KEEP_SECONDS]:
            _jobs.pop(jid, None)
    try:
        with db.conn() as c:
            rows = c.execute("SELECT k, v FROM kv WHERE k LIKE 'aijob:%%'").fetchall()
            old = []
            for r in rows:
                try:
                    v = json.loads(r["v"])
                except ValueError:
                    old.append(r["k"])
                    continue
                if now - float(v.get("startedAt") or 0) > KEEP_SECONDS:
                    old.append(r["k"])
            for k in old:
                c.execute("DELETE FROM kv WHERE k=%s", (k,))
    except db.DBError:
        pass


def start(prompt, tier="default", max_tokens=6000):
    """Start een taak en geeft meteen de id terug."""
    with _lock:
        running = sum(1 for j in _jobs.values() if j["status"] == "bezig")
        if running >= MAX_RUNNING:
            raise ai.AIRateLimit("Er lopen al twee analyses tegelijk; wacht tot er een klaar is.")
        jid = secrets.token_hex(8)
        job = {"id": jid, "status": "bezig", "tier": tier, "startedAt": time.time(), "chars": len(prompt)}
        _jobs[jid] = job
    _save(dict(job))
    threading.Thread(target=_run, args=(jid, prompt, tier, max_tokens), daemon=True, name=f"ai-{jid}").start()
    log.info("[ai-taak] %s gestart (%s, %s tekens)", jid, tier, f"{len(prompt):,}".replace(",", "."))
    return jid


def _run(jid, prompt, tier, max_tokens):
    t0 = time.time()
    try:
        text, truncated = ai.complete(prompt, None, tier, max_tokens, TIMEOUT)
        upd = {"status": "klaar", "text": text, "truncated": truncated}
    except ai.AIError as e:
        upd = {"status": "fout", "error": str(e), "code": e.code}
    except Exception as e:  # een taak mag de server nooit laten crashen
        log.exception("AI-taak %s mislukt", jid)
        upd = {"status": "fout", "error": f"onverwachte fout ({e.__class__.__name__})", "code": "upstream_error"}
    upd.update(endedAt=time.time(), seconds=round(time.time() - t0, 1))
    try:
        upd["model"] = ai.resolved_model(tier)
    except Exception:
        pass
    with _lock:
        _jobs[jid].update(upd)
        job = dict(_jobs[jid])
    _save(job)
    log.info("[ai-taak] %s %s in %.0f s", jid, upd["status"], upd["seconds"])
    _cleanup()


def get(jid):
    """De stand van een taak, of None als hij onbekend is."""
    with _lock:
        j = _jobs.get(jid)
        if j:
            return dict(j)
    try:
        j = db.get_json(_key(jid))
    except db.DBError:
        j = None
    if j and j.get("status") == "bezig":  # liep nog toen de server herstartte: deze taak komt niet meer af
        j.update(status="fout", code="restarted", error="De server is herstart tijdens de analyse.")
    return j
