"""Inhoudelijke updates van het plan en de marktcijfers (seed/updates/*.json).

Elke update wordt één keer toegepast, bij het starten van de server, en daarna onthouden
(kv 'updates:applied'). Voor het plan komt er een stap in Historie met de oude stand erbij,
zodat je hem met één klik kunt terugzetten. Cijfers die de server zelf live ophaalt
(Finnhub, CoinGecko, Twelve Data, FRED) worden niet overschreven met oudere waarden.
"""
import copy
import json
import secrets
from datetime import datetime, timezone
from pathlib import Path

from . import db

UPD_DIR = Path(__file__).resolve().parent.parent / "seed" / "updates"
LIVE_SOURCES = ("Finnhub", "CoinGecko", "Twelve Data", "FRED", "Yahoo")


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _apply_market(u):
    m = u.get("market") or {}
    if not m:
        return 0
    doc = db.get_doc("market/latest") or {"items": []}
    items = {i.get("key"): i for i in doc.get("items", []) if isinstance(i, dict)}
    n = 0
    for key, vals in (m.get("set") or {}).items():
        cur = items.get(key)
        if cur and any(str(cur.get("src", "")).startswith(s) for s in LIVE_SOURCES) and key not in (m.get("force") or []):
            continue
        if cur is None:
            cur = {"key": key, "prefix": "", "suffix": "", "decimals": 2, "group": "Macro"}
            items[key] = cur
        cur.update(copy.deepcopy(vals))
        cur["display"] = vals.get("display")
        n += 1
    doc["items"] = list(items.values())
    doc["updatedAt"] = m.get("updatedAt") or _now()
    doc["updatedBy"] = m.get("updatedBy") or "Update door Claude"
    if m.get("note"):
        doc["note"] = m["note"]
    db.set_doc("market/latest", doc)
    return n


def _apply_plan(u):
    p = u.get("plan") or {}
    plan = db.get_doc("plan/current")
    if not p or plan is None:
        return None
    before = copy.deepcopy(plan)
    for k, v in (p.get("replace") or {}).items():
        plan[k] = copy.deepcopy(v)
    for pid, fields in (p.get("positionsPatch") or {}).items():
        for pos in plan.get("positions", []):
            if pos.get("id") == pid:
                pos.update(copy.deepcopy(fields))
    sp = p.get("scenarioPatch") or {}
    # 'ifProb': alleen toepassen als de kansen nog zo staan als verwacht (allemaal of geen), zodat kansen die jij
    # intussen zelf hebt aangepast niet worden overschreven en het totaal 100% blijft.
    cur = {sc.get("id"): sc.get("prob") for sc in plan.get("scenarios", [])}
    if all(cur.get(pid) == f["ifProb"] for pid, f in sp.items() if "ifProb" in f):
        for pid, fields in sp.items():
            for sc in plan.get("scenarios", []):
                if sc.get("id") == pid:
                    sc.update({k: copy.deepcopy(v) for k, v in fields.items() if k != "ifProb"})
    for i, c in enumerate(p.get("calendarSet") or []):
        cal = plan.setdefault("calendar", [])
        hit = next((x for x in cal if x.get("date") == c.get("date") and x.get("event", "")[:12] == c.get("match", c.get("event", ""))[:12]), None)
        if hit:
            hit.update({k: v for k, v in c.items() if k != "match"})
        else:
            cal.append({k: v for k, v in c.items() if k != "match"})
            cal.sort(key=lambda x: str(x.get("date", "")))
    if p.get("macro"):
        macro = plan.setdefault("macro", {})
        for k, v in p["macro"].items():
            if k == "cycle" and isinstance(v, dict) and isinstance(macro.get("cycle"), dict):
                macro["cycle"].update(copy.deepcopy(v))
            else:
                macro[k] = copy.deepcopy(v)
    for lid, fields in (p.get("lensPatch") or {}).items():
        _patch_lens(plan, lid, copy.deepcopy(fields))
    plan.setdefault("claims", [])
    for c in p.get("claimsUpdate", []):
        for x in plan["claims"]:
            if x.get("text") == c.get("text"):
                x.update(c)
    if p.get("claimsAdd"):
        have = {c.get("text") for c in plan["claims"]}
        plan["claims"] = [c for c in p["claimsAdd"] if c.get("text") not in have] + plan["claims"]
    if p.get("sourcesAdd"):
        srcs = plan.setdefault("sources", [])
        urls = {s.get("url") for s in srcs}
        plan["sources"] = [s for s in p["sourcesAdd"] if s.get("url") not in urls] + srcs
    meta = plan.setdefault("meta", {})
    version = int(meta.get("version") or 1) + 1
    meta.update({"version": version, "updatedAt": u.get("at") or _now(), "asOf": u.get("asOf") or meta.get("asOf"),
                 "lastSource": u.get("title") or "Update"})
    db.set_doc("plan/current", plan)
    db.set_doc(f"history/{u['id']}-{secrets.token_hex(3)}", {
        "at": u.get("at") or _now(), "version": version, "source": u.get("source") or "Update door Claude",
        "title": u.get("title") or "", "inboxId": "", "changelog": u.get("changelog") or [],
        "summary": u.get("summary") or "", "planBefore": before})
    return version


def _when(iso):
    try:
        t = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def _patch_lens(plan, lid, fields):
    """Werkt een bril (TradersReality, Rebel Capitalist) bij, maar nooit over een visie die jij uit hun eigen
    transcript haalde: is de bril sinds 'skipIfTranscriptSince' uit een transcript bijgewerkt, dan blijft hij staan."""
    lenses = (plan.get("macro") or {}).get("lenses") or []
    ln = next((x for x in lenses if x.get("id") == lid), None)
    if ln is None:
        return False
    since = _when(fields.pop("skipIfTranscriptSince", "") or "")
    own = str(ln.get("basis", "")).startswith("Bijgewerkt uit")
    at = _when(ln.get("updatedAt") or "")
    if own and (since is None or (at and at >= since)):
        return False
    checks = fields.pop("checks", None) or []
    ln.update(fields)
    for c in checks:
        hit = next((x for x in ln.get("checks", []) if x.get("id") == c.get("id")), None)
        if hit:
            hit.update({k: v for k, v in c.items() if k in ("answer", "status")})
    return True


def _apply_watchlist(u):
    add = u.get("watchlistAdd") or []
    remove = [str(x).upper() for x in (u.get("watchlistRemove") or [])]
    if remove:
        with db.conn() as c:
            c.execute("DELETE FROM watchlist WHERE symbol = ANY(%s)", (remove,))
            c.execute("DELETE FROM quotes WHERE symbol = ANY(%s)", (remove,))
    if not add:
        return 0
    with db.conn() as c:
        pos = c.execute("SELECT COALESCE(MAX(position),0) AS p FROM watchlist").fetchone()["p"]
        for i, w in enumerate(add, 1):
            c.execute("INSERT INTO watchlist(symbol,name,kind,position) VALUES(%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                      (w["symbol"].upper(), w.get("name", ""), w.get("kind", "aandeel"), pos + i))
    return len(add)


def apply_all():
    """Past nieuwe updates toe. Geeft een lijst met korte meldingen terug."""
    if not UPD_DIR.exists():
        return []
    done = set(db.get_json("updates:applied") or [])
    notes = []
    for f in sorted(UPD_DIR.glob("*.json")):
        u = json.loads(f.read_text(encoding="utf-8"))
        uid = u.get("id") or f.stem
        if uid in done:
            continue
        u["id"] = uid
        n = _apply_market(u)
        v = _apply_plan(u)
        w = _apply_watchlist(u)
        done.add(uid)
        db.set_json("updates:applied", sorted(done))
        notes.append(f"update {uid}: {n} cijfers" + (f", plan v{v}" if v else "") + (f", {w} op de volglijst" if w else ""))
    return notes
