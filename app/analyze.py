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
