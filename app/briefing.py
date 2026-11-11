"""Dagelijkse briefing: Grok vat de cijfers, signalen en planregels samen in gewone taal.

Grok krijgt alleen wat in de database staat (cijfers met tijdstip, signalen, planregels, kalender)
en mag geen eigen cijfers verzinnen. Het resultaat staat in 'briefing/latest' en in 'briefings/<tijd>'.
"""
import json
from datetime import datetime, timedelta

from . import ai, db, jobs, planstatus

PROMPT = """Je schrijft de korte dagbriefing voor het persoonlijke beleggingsplan van Floris (educatief gebruik, geen advies).
Schrijf in helder Nederlands, zonder jargon waar dat kan, kort en concreet.

Harde regels:
- Gebruik ALLEEN de cijfers en feiten hieronder. Verzin geen koersen, data of nieuws. Noem een cijfer alleen als het hieronder staat.
- Is een cijfer oud (zie 'opgehaald'), zeg dat dan in plaats van te doen alsof het actueel is.
- Volg zijn planregels: noem een actie alleen als een regel hieronder 'GERAAKT' is. Anders: 'geen actie volgens je plan'.
- Geen koop- of verkoopadvies buiten zijn eigen planregels.

Antwoord met ALLEEN dit JSON-object:
{{"kop":"één zin van max 12 woorden over de dag",
 "samenvatting":"3 tot 4 zinnen: wat er gebeurde en wat het betekent voor zijn posities",
 "veranderd":"1 à 2 zinnen: wat er veranderd is sinds de vorige briefing (of 'Eerste briefing.')",
 "posities":{{{pos_ids}}},
 "letop":["max 3 korte punten: wat de komende dagen telt, met datum"],
 "risico":"laag|gemiddeld|hoog"}}

Nu: {nu} (Nederlandse tijd)
Regime volgens het plan: {regime}

Cijfers (waarde · verandering · tijdstip · bron · opgehaald):
{cijfers}

Signalen (rood = planregel controleren, oranje = let op):
{signalen}

Planregels per positie:
{regels}

Komende momenten:
{kalender}

Vorige briefing ({vorige_at}):
{vorige}
"""

DAYS = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"]
KEYS = ["spx", "spxDD", "ndx", "vix", "kospiDay", "us10y", "us2y", "realYield10", "curve", "fedFunds", "dxy", "eurusd", "usdjpy",
        "gold", "silver", "brent", "wti", "hySpread", "btc", "vwce", "smh", "crcl", "cpiYoY", "nfp3m", "unrate", "claims", "sahm",
        "netLiq", "fedAssets", "cape"]


def _ago(iso):
    try:
        t = datetime.fromisoformat(iso)
        h = (datetime.now(t.tzinfo) - t).total_seconds() / 3600
    except (TypeError, ValueError):
        return "onbekend"
    return f"{int(h * 60)} min geleden" if h < 1 else f"{h:.0f} uur geleden" if h < 48 else f"{h / 24:.0f} dagen geleden"


def build_prompt(plan, market, prev):
    items = {i["key"]: i for i in (market or {}).get("items", []) if isinstance(i, dict) and i.get("key")}
    lines = []
    for k in KEYS:
        it = items.get(k)
        if not it or not isinstance(it.get("value"), (int, float)):
            continue
        lines.append(f"- {it.get('label', k)}: {jobs.fmt_value(it)} · {it.get('change') or '–'} · {it.get('asOf') or '?'} · "
                     f"{it.get('src') or '?'} · {_ago(it['at']) if it.get('at') else 'handmatig/onbekend'}")
    sig = []
    for t in plan.get("triggers", []) or []:
        v = items.get(t.get("marketKey"), {}).get("value") if t.get("marketKey") else t.get("current")
        lv = jobs.trigger_status(t, v) if isinstance(v, (int, float)) else None
        if lv in ("rood", "oranje"):
            sig.append(f"- {lv.upper()}: {t.get('label')} = {v} (grens {t.get('warn')}/{t.get('danger')}) – {t.get('meaning', '')}")
    rules = []
    for st in planstatus.evaluate(plan, items):
        n = st.get("next")
        if n and n["hit"]:
            rules.append(f"- {st['name']}: GERAAKT – {n['check'].get('label')}: {n['check'].get('action')}. {n['check'].get('then', '')}")
        elif n:
            rules.append(f"- {st['name']}: {st['why']} Volgende stap bij {n['check'].get('label')} ({n['check'].get('action')}); "
                         f"nu {n['value']}{' – DICHTBIJ' if n['near'] else ''}.")
        else:
            rules.append(f"- {st['name']}: {st['why']}")
    today = jobs.now_nl().date()
    cal = [c for c in plan.get("calendar", []) or [] if today.isoformat() <= str(c.get("date", "")) <= (today + timedelta(days=14)).isoformat()]
    kal = "\n".join(f"- {c.get('date')} {c.get('time', '')}: {c.get('event')} – {c.get('why', '')}" for c in cal[:8]) or "- (niets in de komende 14 dagen)"
    pos_ids = ",".join(f'"{p.get("id")}":"één zin voor {p.get("short") or p.get("name")}"' for p in plan.get("positions", []) or [])
    reg = plan.get("regime") or {}
    return PROMPT.format(
        pos_ids=pos_ids, nu=f"{DAYS[jobs.now_nl().weekday()]} {jobs.now_nl():%d-%m-%Y %H:%M}",
        regime=f"{reg.get('name', '')}: {reg.get('thesis', '')}"[:900],
        cijfers="\n".join(lines) or "- (geen cijfers)", signalen="\n".join(sig) or "- geen rode of oranje signalen",
        regels="\n".join(rules) or "- (geen posities)", kalender=kal,
        vorige_at=(prev or {}).get("at", "geen"),
        vorige=json.dumps({k: (prev or {}).get(k) for k in ("kop", "samenvatting")}, ensure_ascii=False) if prev else "geen")


def clean(res, plan):
    if not isinstance(res, dict):
        raise ai.AIError("antwoord was geen bruikbare JSON")
    ids = [p.get("id") for p in plan.get("positions", []) or []]
    pos = res.get("posities") if isinstance(res.get("posities"), dict) else {}
    risk = str(res.get("risico") or "gemiddeld").lower().strip()
    return {
        "kop": str(res.get("kop") or "")[:160],
        "samenvatting": str(res.get("samenvatting") or "")[:1400],
        "veranderd": str(res.get("veranderd") or "")[:500],
        "posities": {i: str(pos.get(i) or "")[:300] for i in ids if pos.get(i)},
        "letop": [str(x)[:220] for x in (res.get("letop") or []) if str(x).strip()][:3] if isinstance(res.get("letop"), list) else [],
        "risico": risk if risk in ("laag", "gemiddeld", "hoog") else "gemiddeld",
    }


def make():
    if not ai.provider():
        raise RuntimeError("geen AI-sleutel ingesteld (XAI_API_KEY)")
    plan = db.get_doc("plan/current") or {}
    market = db.get_doc("market/latest") or {}
    prev = db.get_doc("briefing/latest")
    prompt = build_prompt(plan, market, prev)
    try:
        raw, _ = ai.complete(prompt, tier="complex", max_tokens=1600, timeout=280)
    except ai.AIError as e:
        raise RuntimeError(f"briefing mislukt: {e}") from e
    out = clean(ai.parse_json(raw), plan)
    out.update(at=jobs.now_iso(), model=ai.resolved_model("complex"), basedOn=market.get("updatedAt"))
    db.set_doc("briefing/latest", out)
    db.set_doc(f"briefings/{jobs.now_nl():%Y%m%d-%H%M}", out)
    db.event("info", "briefing", out["kop"] or "nieuwe briefing")
    return out
