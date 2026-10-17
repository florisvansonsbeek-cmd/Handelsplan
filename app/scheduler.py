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
