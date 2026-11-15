"""Dagelijkse briefing: Grok vat de cijfers, signalen en planregels samen in gewone taal.

Grok krijgt alleen wat in de database staat (cijfers met tijdstip, signalen, planregels, scenario's, kalender en de
brillen van TradersReality en Rebel Capitalist) en mag geen eigen cijfers verzinnen. Naast de dagbriefing schrijft
hij het verhaal voor de pagina Vandaag (wat speelt er, wat betekent het, wat doe je), een vooruitblik per positie en
een vergelijking van de bronnen met de AI-analyse. Het resultaat staat in 'briefing/latest' en in 'briefings/<tijd>'.
"""
import json
from datetime import datetime, timedelta

from . import ai, db, jobs, planstatus

PROMPT = """Je schrijft de korte dagbriefing voor het persoonlijke beleggingsplan van Floris (educatief gebruik, geen advies).
Schrijf in helder Nederlands, zonder jargon waar dat kan, kort en concreet. Hij wil in één oogopslag het verhaal zien:
wat er speelt, wat het voor zijn posities betekent en wat hij volgens zijn eigen regels doet.

Harde regels:
- Gebruik ALLEEN de cijfers en feiten hieronder. Verzin geen koersen, data of nieuws. Noem een cijfer alleen als het hieronder staat.
- Is een cijfer oud (zie 'opgehaald'), zeg dat dan in plaats van te doen alsof het actueel is.
- Volg zijn planregels: noem een actie alleen als een regel hieronder 'GERAAKT' is. Anders: 'geen actie volgens je plan'.
- Geen koop- of verkoopadvies buiten zijn eigen planregels. De vooruitblik is een verwachting op basis van de scenario's, geen voorspelling.
- Bronnen: vergelijk de visie van elke bron (hun bril hieronder) met de AI-analyse van het plan (regime, marktbeeld,
  scenario's en effect per positie). oordeel = eens (zelfde conclusie voor zijn posities), deels (zelfde richting, ander
  accent of andere timing), oneens (andere conclusie), onbekend (de bril komt niet uit hun eigen woorden: basis begint met
  'Startversie', of de bril is ouder dan 30 dagen). Zeg bij onbekend eerlijk dat er nog geen recent transcript is verwerkt.

Antwoord met ALLEEN dit JSON-object:
{{"kop":"één zin van max 12 woorden: het verhaal van nu",
 "samenvatting":"3 tot 4 zinnen: wat er gebeurde en wat het betekent voor zijn posities",
 "veranderd":"1 à 2 zinnen: wat er veranderd is sinds de vorige briefing (of 'Eerste briefing.')",
 "posities":{{{pos_ids}}},
 "letop":["max 3 korte punten: wat de komende dagen telt, met datum"],
 "risico":"laag|gemiddeld|hoog",
 "verhaal":{{"wat":"max 2 zinnen: wat er nu speelt in de markt, met de belangrijkste cijfers",
   "betekenis":"max 2 zinnen: wat dat voor zijn posities betekent (welke hebben wind mee, welke tegen)",
   "doen":"1 zin: wat hij volgens zijn planregels doet; alleen GERAAKTE regels, anders vasthouden aan het plan"}},
 "vooruitblik":{{"periode":"de periode, bijv. 'tot het Fed-besluit van 9 december'",
   "pad":"max 2 zinnen: het meest waarschijnlijke pad volgens de scenario's en de kalender",
   "zeker":["max 3 dingen die de komende weken ZEER WAARSCHIJNLIJK zijn, met de kans als die hieronder staat"],
   "kantelpunten":["max 3: datum of niveau + wat het beeld kan doen kantelen"],
   "posities":{{{vb_ids}}},
   "lang":{{"periode":"de langere termijn, bijv. '3 tot 12 maanden'",
     "pad":"max 2 zinnen: het waarschijnlijkste pad op de langere termijn volgens de scenario's, met kans en het grootste risico",
     "posities":{{{lang_ids}}}}}}},
 "bronnen":{{"kern":"1 zin: waar de AI en de bronnen het over eens en oneens zijn",
   "tr":{{"oordeel":"eens|deels|oneens|onbekend","verschil":"1 à 2 zinnen: hoe Tino (TradersReality) ernaar kijkt t.o.v. de AI-analyse"}},
   "rebel":{{"oordeel":"eens|deels|oneens|onbekend","verschil":"1 à 2 zinnen: hoe George Gammon (Rebel Capitalist) ernaar kijkt t.o.v. de AI-analyse"}}}}}}

Nu: {nu} (Nederlandse tijd)
Regime volgens het plan: {regime}

AI-analyse van het plan (marktbeeld):
{marktbeeld}

Cijfers (waarde · verandering · tijdstip · bron · opgehaald):
{cijfers}

Signalen (rood = planregel controleren, oranje = let op):
{signalen}

Planregels per positie:
{regels}

Scenario's (kans · horizon · effect per positie van -2 tot +2):
{scenarios}

Brillen van de bronnen (HUN visie, niet die van het plan):
{brillen}

Komende momenten (30 dagen):
{kalender}

Vorige briefing ({vorige_at}):
{vorige}
"""

DAYS = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"]
KEYS = ["spx", "spxDD", "ndx", "vix", "kospiDay", "us10y", "us2y", "realYield10", "curve", "fedFunds", "dxy", "eurusd", "usdjpy",
        "gold", "silver", "brent", "wti", "hySpread", "btc", "vwce", "smh", "crcl", "cpiYoY", "nfp3m", "unrate", "claims", "sahm",
        "netLiq", "fedAssets", "cape"]
LENS_WHO = {"tr": "Tino (TradersReality)", "rebel": "George Gammon (Rebel Capitalist)"}
VERDICTS = ("eens", "deels", "oneens", "onbekend")


def _ago(iso):
    try:
        t = datetime.fromisoformat(iso)
        h = (datetime.now(t.tzinfo) - t).total_seconds() / 3600
    except (TypeError, ValueError):
        return "onbekend"
    return f"{int(h * 60)} min geleden" if h < 1 else f"{h:.0f} uur geleden" if h < 48 else f"{h / 24:.0f} dagen geleden"


def _short(pos):
    return pos.get("short") or pos.get("name") or pos.get("id")


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
    positions = plan.get("positions", []) or []
    names = {p.get("id"): _short(p) for p in positions}
    sc = []
    for s in sorted(plan.get("scenarios", []) or [], key=lambda s: -(s.get("prob") or 0)):
        eff = ", ".join(f"{names.get(k, k)} {v:+d}" for k, v in (s.get("impact") or {}).items() if isinstance(v, int) and k in names)
        sc.append(f"- {s.get('name')} ({s.get('prob')}%, {s.get('horizon', '')}): {eff}. {str(s.get('desc', ''))[:260]}")
    macro = plan.get("macro") or {}
    pi = macro.get("positionImpact") or {}
    mb = [f"Kop: {macro.get('headline', '')}", f"Samenvatting: {str(macro.get('summary', ''))[:700]}"]
    mb += [f"- {names.get(k, k)}: richting {v.get('dir')}, {v.get('why', '')}" for k, v in pi.items() if isinstance(v, dict) and k in names]
    lenses = []
    for ln in macro.get("lenses", []) or []:
        if ln.get("id") not in LENS_WHO:
            continue
        lenses.append(f"- {ln['id']} = {LENS_WHO[ln['id']]}: {ln.get('take', '')} (basis: {ln.get('basis', 'onbekend')}; "
                      f"bijgewerkt {str(ln.get('updatedAt', '?'))[:10]})")
    today = jobs.now_nl().date()
    cal = [c for c in plan.get("calendar", []) or [] if today.isoformat() <= str(c.get("date", "")) <= (today + timedelta(days=30)).isoformat()]
    kal = "\n".join(f"- {c.get('date')} {c.get('time', '')}: {c.get('event')} – {c.get('why', '')}" for c in cal[:10]) or "- (niets in de komende 30 dagen)"
    pos_ids = ",".join(f'"{p.get("id")}":"één zin voor {_short(p)}"' for p in positions)
    vb_ids = ",".join(f'"{p.get("id")}":{{"richting":"getal van -2 (sterk negatief) tot 2 (sterk positief)",'
                      f'"tekst":"1 zin: wat je de komende weken voor {_short(p)} mag verwachten",'
                      f'"kantel":"het niveau of moment dat dit verandert"}}' for p in positions)
    lang_ids = ",".join(f'"{p.get("id")}":"1 zin: wat je op de langere termijn (maanden) voor {_short(p)} mag verwachten"'
                        for p in positions)
    reg = plan.get("regime") or {}
    return PROMPT.format(
        pos_ids=pos_ids, vb_ids=vb_ids, lang_ids=lang_ids, nu=f"{DAYS[jobs.now_nl().weekday()]} {jobs.now_nl():%d-%m-%Y %H:%M}",
        regime=f"{reg.get('name', '')}: {reg.get('thesis', '')}"[:900],
        marktbeeld="\n".join(mb), cijfers="\n".join(lines) or "- (geen cijfers)",
        signalen="\n".join(sig) or "- geen rode of oranje signalen",
        regels="\n".join(rules) or "- (geen posities)", scenarios="\n".join(sc) or "- (geen scenario's)",
        brillen="\n".join(lenses) or "- (geen brillen)", kalender=kal,
        vorige_at=(prev or {}).get("at", "geen"),
        vorige=json.dumps({k: (prev or {}).get(k) for k in ("kop", "samenvatting")}, ensure_ascii=False) if prev else "geen")


def _txt(v, n):
    return str(v or "").strip()[:n]


def _dir(v):
    try:
        return max(-2, min(2, int(round(float(v)))))
    except (TypeError, ValueError):
        return 0


def clean(res, plan):
    if not isinstance(res, dict):
        raise ai.AIError("antwoord was geen bruikbare JSON")
    ids = [p.get("id") for p in plan.get("positions", []) or []]
    pos = res.get("posities") if isinstance(res.get("posities"), dict) else {}
    risk = str(res.get("risico") or "gemiddeld").lower().strip()
    out = {
        "kop": _txt(res.get("kop"), 160),
        "samenvatting": _txt(res.get("samenvatting"), 1400),
        "veranderd": _txt(res.get("veranderd"), 500),
        "posities": {i: _txt(pos.get(i), 300) for i in ids if pos.get(i)},
        "letop": [_txt(x, 220) for x in (res.get("letop") or []) if str(x).strip()][:3] if isinstance(res.get("letop"), list) else [],
        "risico": risk if risk in ("laag", "gemiddeld", "hoog") else "gemiddeld",
    }
    vh = res.get("verhaal") if isinstance(res.get("verhaal"), dict) else {}
    if any(vh.get(k) for k in ("wat", "betekenis", "doen")):
        out["verhaal"] = {k: _txt(vh.get(k), 420) for k in ("wat", "betekenis", "doen")}
    vb = res.get("vooruitblik") if isinstance(res.get("vooruitblik"), dict) else {}
    vp = vb.get("posities") if isinstance(vb.get("posities"), dict) else {}
    vpos = {i: {"richting": _dir(vp[i].get("richting")), "tekst": _txt(vp[i].get("tekst"), 260), "kantel": _txt(vp[i].get("kantel"), 200)}
            for i in ids if isinstance(vp.get(i), dict) and vp[i].get("tekst")}
    lg = vb.get("lang") if isinstance(vb.get("lang"), dict) else {}
    lp = lg.get("posities") if isinstance(lg.get("posities"), dict) else {}
    lpos = {i: _txt(lp[i].get("tekst") if isinstance(lp.get(i), dict) else lp.get(i), 260) for i in ids if lp.get(i)}
    lst = lambda v, n: [_txt(x, n) for x in v if str(x).strip()][:3] if isinstance(v, list) else []
    if vb.get("pad") or vpos or lg.get("pad"):
        out["vooruitblik"] = {"periode": _txt(vb.get("periode"), 80), "pad": _txt(vb.get("pad"), 420),
                              "zeker": lst(vb.get("zeker"), 200), "kantelpunten": lst(vb.get("kantelpunten"), 200),
                              "posities": vpos}
        if lg.get("pad") or lpos:
            out["vooruitblik"]["lang"] = {"periode": _txt(lg.get("periode"), 80), "pad": _txt(lg.get("pad"), 420),
                                          "posities": {k: v for k, v in lpos.items() if v}}
    br = res.get("bronnen") if isinstance(res.get("bronnen"), dict) else {}
    src = {}
    for k in ("tr", "rebel"):
        x = br.get(k) if isinstance(br.get(k), dict) else {}
        if not x.get("verschil"):
            continue
        o = str(x.get("oordeel") or "onbekend").lower().strip()
        src[k] = {"oordeel": o if o in VERDICTS else "onbekend", "verschil": _txt(x.get("verschil"), 360)}
    if src:
        lens_at = {ln.get("id"): ln.get("updatedAt") for ln in ((plan.get("macro") or {}).get("lenses") or []) if ln.get("id") in src}
        out["bronnen"] = {"kern": _txt(br.get("kern"), 300), **src, "lensAt": lens_at}
    return out


def make():
    if not ai.provider():
        raise RuntimeError("geen AI-sleutel ingesteld (XAI_API_KEY)")
    plan = db.get_doc("plan/current") or {}
    market = db.get_doc("market/latest") or {}
    prev = db.get_doc("briefing/latest")
    prompt = build_prompt(plan, market, prev)
    try:
        raw, _ = ai.complete(prompt, tier="complex", max_tokens=8000, timeout=280)
    except ai.AIError as e:
        raise RuntimeError(f"briefing mislukt: {e}") from e
    out = clean(ai.parse_json(raw), plan)
    out.update(at=jobs.now_iso(), model=ai.resolved_model("complex"), basedOn=market.get("updatedAt"),
               planVersion=(plan.get("meta") or {}).get("version"))
    db.set_doc("briefing/latest", out)
    db.set_doc(f"briefings/{jobs.now_nl():%Y%m%d-%H%M}", out)
    db.event("info", "briefing", out["kop"] or "nieuwe briefing")
    return out
