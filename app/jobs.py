"""Geplande taken. De ingebouwde planner (app/scheduler.py) start ze vanzelf; met de hand kan ook:
python -m app.jobs post | koersen | markt | dagelijks | melding

- markt     : elk kwartier op werkdagen. Koersen van indexen, metalen, olie, valuta en rente
              (Yahoo Finance zonder sleutel, of Twelve Data met sleutel), bitcoin (CoinGecko),
              triggers en planregels, melding bij nieuw rood of een planregel die afgaat.
- dagelijks : 's ochtends en 's avonds. Macrocijfers uit FRED (werkt zonder sleutel via de
              CSV-download; met FRED_API_KEY via de API): rente, reële rente, inflatie, banen,
              liquiditeit, kredietspread, Fed-balans. Daggrafieken voor sparklines en het niveaubord
              (50/200-daags gemiddelde, weekhoog/-laag, gemiddelde dagbeweging).
- briefing  : 's ochtends en na slot van Wall Street: Grok schrijft een korte briefing uit de cijfers.
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

from . import db, sources

TZ = ZoneInfo("Europe/Amsterdam")
TD_KEY = os.environ.get("TWELVEDATA_API_KEY", "")
FRED_KEY = os.environ.get("FRED_API_KEY", "")
MONTHS = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]

# Cijfers die de taken zelf mogen aanmaken als ze nog niet bestaan
META = {
    "mags": dict(label="Mag 7-mand (ETF MAGS)", group="Jouw posities", pillar="sentiment", prefix="$", suffix="", decimals=2),
    "smh": dict(label="Chips-ETF (SMH)", group="Jouw posities", pillar="sentiment", prefix="$", suffix="", decimals=2),
    "netLiqChg": dict(label="Netto liquiditeit, 4 weken", group="Macro", pillar="liquiditeit", prefix="$", suffix=" mld", decimals=0),
    "spxDD": dict(label="S&P 500 t.o.v. record", group="Aandelen", pillar="sentiment", prefix="", suffix="%", decimals=1),
    "sahm": dict(label="Sahm-regel (recessiesignaal)", group="Macro", pillar="groei", prefix="", suffix="", decimals=2),
    "eurusd": dict(label="EUR/USD", group="Rente & valuta", pillar="dollar", prefix="", suffix="", decimals=4),
    "vwce": dict(label="VWCE (wereldaandelen)", group="Jouw posities", pillar="sentiment", prefix="€", suffix="", decimals=2),
    "fedAssets": dict(label="Fed-balans", group="Macro", pillar="liquiditeit", prefix="$", suffix=" bln", decimals=2),
    "kospi": dict(label="Kospi", group="Aandelen", pillar="sentiment", prefix="", suffix="", decimals=0),
    "kospiDay": dict(label="Kospi dagbeweging", group="Aandelen", pillar="sentiment", prefix="", suffix="%", decimals=1),
    "unrate": dict(label="Werkloosheid", group="Macro", pillar="groei", prefix="", suffix="%", decimals=1),
    "claims": dict(label="WW-aanvragen", group="Macro", pillar="groei", prefix="", suffix="k", decimals=0),
    "cpiYoY": dict(label="CPI-inflatie (j/j)", group="Macro", pillar="inflatie", prefix="", suffix="%", decimals=1),
    "coreCpi": dict(label="Kerninflatie (j/j)", group="Macro", pillar="inflatie", prefix="", suffix="%", decimals=1),
    "nfp3m": dict(label="Banengroei, gem. 3 mnd", group="Macro", pillar="groei", prefix="", suffix="k", decimals=0),
    "netLiq": dict(label="Netto liquiditeit", group="Macro", pillar="liquiditeit", prefix="$", suffix=" mld", decimals=0),
}

# Elk kwartier zonder sleutel: Yahoo Finance (±15 min vertraagd). Sleutel in het plan -> Yahoo-symbool.
YAHOO_LIVE = {
    "spx": "^GSPC", "ndx": "^IXIC", "vix": "^VIX", "kospi": "^KS11", "vwce": "VWCE.DE",
    "gold": "GC=F", "silver": "SI=F", "brent": "BZ=F", "wti": "CL=F",
    "dxy": "DX-Y.NYB", "usdjpy": "JPY=X", "eurusd": "EURUSD=X", "us10y": "^TNX",
}
YAHOO_IF_NO_FINNHUB = {"smh": "SMH", "crcl": "CRCL"}
# Dagelijks zonder Twelve Data: daggrafieken (met hoog/laag) voor het niveaubord
LEVEL_YAHOO = {"spy": "SPY", "vwce": "VWCE.DE", "smh": "SMH", "crcl": "CRCL", "gold": "GC=F", "silver": "SI=F",
               "qqq": "QQQ", "usdjpy": "JPY=X"}

# Elk halfuur (Twelve Data /price, max 8 symbolen per minuut op het gratis niveau)
PRICE_TD = {"gold": "XAU/USD", "silver": "XAG/USD", "usdjpy": "USD/JPY", "crcl": "CRCL", "smh": "SMH"}

# Dagelijks: daggrafieken voor niveaus en sparklines
LEVEL_TD = {"gold": "XAU/USD", "silver": "XAG/USD", "spy": "SPY", "qqq": "QQQ", "smh": "SMH", "crcl": "CRCL", "usdjpy": "USD/JPY"}
LEVEL_META = {
    "gold": ("Goud", "$", "", 0), "silver": ("Zilver", "$", "", 2), "spy": ("S&P 500 (SPY)", "$", "", 2),
    "qqq": ("Nasdaq 100 (QQQ)", "$", "", 2), "mags": ("Mag 7 (MAGS)", "$", "", 2), "smh": ("Chips (SMH)", "$", "", 2), "crcl": ("Circle (CRCL)", "$", "", 2),
    "usdjpy": ("USD/JPY", "", "", 2), "btc": ("Bitcoin", "$", "", 0), "us10y": ("US 10-jaars", "", "%", 2),
    "wti": ("WTI-olie", "$", "", 2), "vwce": ("VWCE", "€", "", 2),
}
LEVEL_ORDER = ["spy", "vwce", "smh", "crcl", "gold", "btc", "silver", "qqq", "us10y", "wti", "usdjpy"]

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


def stamp(when=None):
    n = when.astimezone(TZ) if when else now_nl()
    return f"{n.day} {MONTHS[n.month - 1]} {n:%H:%M}"


def stamp_iso(iso):
    try:
        return stamp(datetime.fromisoformat(iso))
    except (TypeError, ValueError):
        return stamp()


def now_iso():
    return now_nl().isoformat(timespec="seconds")


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


def fred_obs(series, limit=260, freq="d"):
    """Laatste `limit` waarnemingen van een FRED-reeks, oplopend.
    Met FRED_API_KEY via de officiële API, anders via de CSV-download. Bij time-outs pauzeert FRED even."""
    if not FRED_KEY:
        return sources.fred_csv(series, sources.fred_start(limit, freq))[-limit:]
    left = sources.paused("fred")
    if left:
        raise sources.SourceError(f"FRED {series}: niet bereikbaar, nieuwe poging over {max(1, left // 60)} min")
    try:
        r = httpx.get("https://api.stlouisfed.org/fred/series/observations",
                      params={"series_id": series, "api_key": FRED_KEY, "file_type": "json",
                              "sort_order": "desc", "limit": limit}, timeout=20)
    except httpx.HTTPError as e:
        sources._fail("fred")
        raise sources.SourceError(f"FRED {series}: {e.__class__.__name__}") from e
    if r.status_code >= 400:
        if r.status_code in (403, 429) or r.status_code >= 500:
            sources._fail("fred")
        raise sources.SourceError(f"FRED {series}: HTTP {r.status_code}")
    sources._ok("fred")
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


LIVE_SRC = ("Yahoo", "Twelve Data", "CoinGecko", "Finnhub")


def put(items, key, value, src, asOf, obs=None, change="", weak=False, **extra):
    """Zet een automatisch cijfer, maar nooit over een nieuwere waarneming heen.
    obs = datum (JJJJ-MM-DD) waar de waarde bij hoort; `at` = wanneer de server hem ophaalde.
    weak = reservebron (FRED): een live koers van dezelfde dag blijft dan staan."""
    it = ensure_item(items, key)
    if obs and (it.get("obsDate") or "") > obs:
        return False
    if weak and obs and it.get("obsDate") == obs and str(it.get("src") or "").startswith(LIVE_SRC):
        return False
    it.update(value=value, src=src, asOf=asOf, change=change, display=None, at=now_iso(), **extra)
    if obs:
        it["obsDate"] = obs
    return True


def put_series(series, key, d, v, keep=130):
    s = series.setdefault(key, [])
    if s and s[-1][0] == d:
        s[-1] = [d, v]
    elif not s or s[-1][0] < d:
        s.append([d, v])
    del s[:-keep]


def update_drawdown(items):
    """S&P 500 ten opzichte van het record; het record wordt vanzelf bijgehouden."""
    spx = items.get("spx")
    if not spx or not isinstance(spx.get("value"), (int, float)):
        return
    dd = ensure_item(items, "spxDD")
    v, ath = float(spx["value"]), float(dd.get("ath") or 0)
    if v > ath:
        dd["ath"], dd["athDate"] = v, spx.get("obsDate") or now_nl().date().isoformat()
        ath = v
    if not ath:
        return
    dd.update(value=round((v / ath - 1) * 100, 2), src="berekend", asOf=spx.get("asOf", ""), display=None, at=now_iso(),
              change=f"record {fmt_num(ath, 0)} op {nl_date(dd.get('athDate') or now_nl().date().isoformat())}")
    if spx.get("obsDate"):
        dd["obsDate"] = spx["obsDate"]


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


def fmt_value(it):
    if not it or not isinstance(it.get("value"), (int, float)):
        return "–"
    v = it["value"]
    dec = 0 if abs(v) >= 1000 else (it.get("decimals") if it.get("decimals") is not None else 2)
    return ("−" if v < 0 else "") + (it.get("prefix") or "") + fmt_num(abs(v), dec) + (it.get("suffix") or "")


def check_actions(items):
    """Melding zodra een planregel afgaat (bijv. 'SMH onder $500: verklein met een derde').
    Een regel meldt zich één keer; pas als de koers duidelijk terug is, mag hij opnieuw melden."""
    from . import planstatus
    plan = db.get_doc("plan/current") or {}
    state = db.get_doc("system/actions") or {}
    by_id = planstatus.checks_by_id(plan)
    alerted = []
    for cid in state.get("alerted", state.get("hit", [])):
        pc = by_id.get(cid)
        if pc and not planstatus.recovered(pc[1], planstatus._val(items, pc[1].get("key"))):
            alerted.append(cid)
    now_hit = []
    for st in planstatus.evaluate(plan, items):
        n = st.get("next")
        if not n or not n["hit"]:
            continue
        now_hit.append(n["id"])
        if n["id"] in alerted:
            continue
        alerted.append(n["id"])
        c = n["check"]
        notify(f"Handelsplan: {st['name']}: {c.get('action', '')}",
               f"{c.get('label', '')} (nu {fmt_value(items.get(c.get('key')))}).\n\n{c.get('then', '')}\n\n"
               "Markeer het op de site als gedaan zodra je het hebt uitgevoerd.", site_url())
        db.event("let op", "planregel", f"{st['name']}: {c.get('action', '')} ({c.get('label', '')})")
    fresh = db.get_doc("plan/current") or {}
    if planstatus.reset_done(fresh, items):
        db.set_doc("plan/current", fresh)
        db.event("info", "planregel", "Een als gedaan gemarkeerde regel staat weer scherp (koers is duidelijk terug).")
    db.set_doc("system/actions", {"hit": now_hit, "alerted": alerted, "checkedAt": now_iso()})


# ---------------------------------------------------------------- elk kwartier
def _save_sources(part, status):
    try:
        st = db.get_doc("system/sources") or {}
        st[part] = status
        db.set_doc("system/sources", st)
    except db.DBError:
        pass


def markt():
    """Koersen van indexen, metalen, olie, valuta en rente; daarna signalen en planregels controleren."""
    from . import quotes
    doc = db.get_doc("market/latest") or {"items": []}
    items = {i["key"]: i for i in doc.get("items", [])}
    series = (db.get_doc("market/series") or {}).get("series", {})
    status = {"at": now_iso(), "ok": [], "errors": [], "via": {}}

    syms = dict(YAHOO_LIVE)
    if not quotes.finnhub_key():
        syms.update(YAHOO_IF_NO_FINNHUB)

    # 1. Twelve Data (alleen met sleutel) voor de symbolen die het kent
    if TD_KEY:
        try:
            tds = list(PRICE_TD.values())
            r = httpx.get("https://api.twelvedata.com/price", params={"symbol": ",".join(tds), "apikey": TD_KEY}, timeout=30).json()
            if len(tds) == 1:
                r = {tds[0]: r}
            for key, sym in PRICE_TD.items():
                v = r.get(sym, {})
                if isinstance(v, dict) and "price" in v:
                    put(items, key, float(v["price"]), "Twelve Data", stamp(), obs=now_nl().date().isoformat())
                    status["ok"].append(key)
                    status["via"][key] = "Twelve Data"
                    syms.pop(key, None)
        except Exception as e:
            status["errors"].append(f"Twelve Data: {e.__class__.__name__}")

    # 2. Yahoo Finance (zonder sleutel); bij een blokkade de rest overslaan en op de reserves leunen
    skipped = []
    with sources.client() as h:
        for key, sym in syms.items():
            if sources.yahoo_status()["pausedFor"]:
                skipped.append(key)
                continue
            try:
                y = sources.yahoo_chart(sym, "5d", "1d", http=h)
            except sources.SourceError as e:
                status["errors"].append(str(e))
                continue
            v, prev = y["price"], y["prev"]
            if key == "us10y":  # ^TNX staat soms als rente x 10 genoteerd
                v = v / 10 if v > 20 else v
                prev = (prev / 10 if prev and prev > 20 else prev)
                chg = f"dag: {signed((v - prev) * 100, 0, ' bp')}" if prev else ""
            else:
                chg = f"dag: {signed(y['changePct'], 1, '%')}" if y["changePct"] is not None else ""
            if put(items, key, round(v, 6), "Yahoo Finance", stamp_iso(y["time"]) if y["time"] else stamp(), obs=y["date"], change=chg):
                put_series(series, key, y["date"], round(v, 4))
            status["ok"].append(key)
            status["via"][key] = "Yahoo"
            if key == "kospi" and y["changePct"] is not None:
                put(items, "kospiDay", round(y["changePct"], 2), "Yahoo Finance (berekend)",
                    stamp_iso(y["time"]) if y["time"] else stamp(), obs=y["date"], change="dagbeweging van de Kospi")

        # 3. CoinGecko: bitcoin, en als reserve goud (PAXG), zilver (KAG) en de euro (USDC)
        try:
            cg = sources.coingecko(["bitcoin", "pax-gold", "kinesis-silver", "usd-coin"], ("usd", "eur"), http=h)
            b = cg.get("bitcoin") or {}
            if b.get("usd"):
                ch = b.get("usd_24h_change")
                put(items, "btc", float(b["usd"]), "CoinGecko", stamp(), obs=now_nl().date().isoformat(),
                    change=f"24u: {signed(ch, 1, '%')}" if ch is not None else "")
                put_series(series, "btc", now_nl().date().isoformat(), round(float(b["usd"])))
                status["ok"].append("btc")
                status["via"]["btc"] = "CoinGecko"
            for key, cid, label in (("gold", "pax-gold", "PAXG"), ("silver", "kinesis-silver", "KAG")):
                d = cg.get(cid) or {}
                if key not in status["ok"] and d.get("usd"):
                    ch = d.get("usd_24h_change")
                    put(items, key, float(d["usd"]), f"CoinGecko ({label}, ≈ spotprijs)", stamp(), obs=now_nl().date().isoformat(),
                        change=f"24u: {signed(ch, 1, '%')}" if ch is not None else "")
                    status["ok"].append(key)
                    status["via"][key] = "CoinGecko"
            u = (cg.get("usd-coin") or {}).get("eur")
            if "eurusd" not in status["ok"] and u:
                put(items, "eurusd", round(1 / float(u), 4), "CoinGecko (via USDC)", stamp(), obs=now_nl().date().isoformat())
                status["ok"].append("eurusd")
                status["via"]["eurusd"] = "CoinGecko"
        except sources.SourceError as e:
            status["errors"].append(str(e))

    if skipped:
        status["errors"].append(f"Yahoo blokkeert even (429): {len(skipped)} koersen overgeslagen; "
                                "reserves via CoinGecko, Finnhub en FRED")
    update_drawdown(items)
    doc["items"] = list(items.values())
    doc["updatedAt"] = now_iso()
    doc["updatedBy"] = "Server (automatisch)"
    db.set_doc("market/latest", doc)
    db.set_doc("market/series", {"updatedAt": doc["updatedAt"], "series": series})
    _save_sources("markt", status)
    check_triggers(items)
    check_actions(items)
    print(f"Koersen bijgewerkt {stamp()}: {len(status['ok'])} gelukt, {len(status['errors'])} fouten", flush=True)
    for e in status["errors"][:8]:
        print("  let op:", e, flush=True)
    if not status["ok"]:
        raise RuntimeError("geen enkele koers opgehaald: " + "; ".join(status["errors"][:3]))


# ---------------------------------------------------------------- dagelijks
def dagelijks():
    doc = db.get_doc("market/latest") or {"items": []}
    items = {i["key"]: i for i in doc.get("items", [])}
    series = (db.get_doc("market/series") or {}).get("series", {})
    bars_by_key = {}
    errors = []

    def fred_down():  # FRED is even niet bereikbaar: de rest van de reeksen meteen overslaan
        return bool(sources.paused("fred"))

    # 1. FRED dagreeksen (een nieuwere koers van Yahoo of Twelve Data blijft staan)
    ok = []
    for key, sid in FRED_DAILY.items():
        if fred_down():
            errors.append("FRED niet bereikbaar: overige reeksen overgeslagen (nieuwe poging bij de volgende ronde)")
            break
        try:
            obs = fred_obs(sid, LONG_HISTORY.get(key, 260), "d")
        except Exception as e:
            errors.append(f"{sid}: {e}")
            continue
        if not obs:
            continue
        ok.append(key)
        d, v = obs[-1]
        chg = ""
        if len(obs) > 1:
            pv = obs[-2][1]
            chg = f"dag: {signed((v - pv) * 100, 0, ' bp')}" if key in RATE_LIKE else f"dag: {signed((v / pv - 1) * 100, 1, '%')}"
        put(items, key, v, "FRED", nl_date(d), obs=d, change=chg, weak=True)
        if key == "fedFunds":
            items[key]["label"] = "Fed-rente (effectief)"
        if key == "spx":
            ath_d, ath_v = max(obs, key=lambda o: o[1])
            dd = ensure_item(items, "spxDD")
            if ath_v > float(dd.get("ath") or 0):
                dd["ath"], dd["athDate"] = ath_v, ath_d[:10]
        old = {p_[0]: p_[1] for p_ in series.get(key, [])}
        old.update({a: b for a, b in obs[-130:]})
        series[key] = [[a, old[a]] for a in sorted(old)][-130:]
        if key in ("us10y", "wti"):
            bars_by_key[key] = ([(a, b, b, b, b) for a, b in obs], "FRED")
    update_drawdown(items)
    # Wisselkoers EUR/USD (dollars per euro) als reserve voor Yahoo
    try:
        if fred_down():
            raise sources.SourceError("overgeslagen")
        eu = fred_obs("DEXUSEU", 30, "d")
        if eu:
            chg = f"dag: {signed((eu[-1][1] / eu[-2][1] - 1) * 100, 1, '%')}" if len(eu) > 1 and eu[-2][1] else ""
            put(items, "eurusd", eu[-1][1], "FRED (Fed H.10)", nl_date(eu[-1][0]), obs=eu[-1][0], change=chg, weak=True)
    except Exception as e:
        if not fred_down():
            errors.append(f"DEXUSEU: {e}")
    try:
        if fred_down():
            raise sources.SourceError("overgeslagen")
        jp = fred_obs("DEXJPUS", 30, "d")
        if jp:
            chg = f"dag: {signed((jp[-1][1] / jp[-2][1] - 1) * 100, 1, '%')}" if len(jp) > 1 and jp[-2][1] else ""
            put(items, "usdjpy", jp[-1][1], "FRED (Fed H.10)", nl_date(jp[-1][0]), obs=jp[-1][0], change=chg, weak=True)
    except Exception as e:
        if not fred_down():
            errors.append(f"DEXJPUS: {e}")

    # 2. Maandcijfers en weekcijfers
    try:
        if fred_down():
            raise sources.SourceError("overgeslagen")
        sa = fred_obs("SAHMREALTIME", 13, "m")
        if sa:
            it = ensure_item(items, "sahm")
            it.update(value=round(sa[-1][1], 2), asOf=nl_month(sa[-1][0]), src="FRED",
                      change=f"vorige mnd {fmt_num(sa[-2][1], 2)} · alarm vanaf 0,50" if len(sa) > 1 else "alarm vanaf 0,50")
            series["sahm"] = [[a, b] for a, b in sa]
    except Exception as e:
        if not fred_down():
            errors.append(f"Sahm-regel: {e}")
    try:
        if fred_down():
            raise sources.SourceError("overgeslagen")
        un = fred_obs("UNRATE", 24, "m")
        if un:
            it = ensure_item(items, "unrate")
            it.update(value=un[-1][1], asOf=nl_month(un[-1][0]), src="FRED (BLS)",
                      change=f"vorige mnd {fmt_num(un[-2][1], 1)}%" if len(un) > 1 else "")
            series["unrate"] = [[a, b] for a, b in un]
        cl = fred_obs("ICSA", 60, "w")
        if cl:
            ks = [(a, b / 1000) for a, b in cl]
            avg4 = sum(b for _, b in ks[-4:]) / min(4, len(ks))
            it = ensure_item(items, "claims")
            it.update(value=round(ks[-1][1]), asOf="week " + nl_date(ks[-1][0]), src="FRED (DoL)",
                      change=f"4-wk gem. {fmt_num(avg4, 1)}k")
            series["claims"] = [[a, round(b, 1)] for a, b in ks]
        for key, sid in (("cpiYoY", "CPIAUCSL"), ("coreCpi", "CPILFESL")):
            cp = fred_obs(sid, 40, "m")
            if len(cp) > 13:
                yoy = [(cp[i][0], (cp[i][1] / cp[i - 12][1] - 1) * 100) for i in range(12, len(cp))]
                it = ensure_item(items, key)
                it.update(value=round(yoy[-1][1], 1), asOf=nl_month(yoy[-1][0]), src="FRED (BLS)",
                          change=f"vorige mnd {fmt_num(yoy[-2][1], 1)}%")
                series[key] = [[a, round(b, 2)] for a, b in yoy]
        pay = fred_obs("PAYEMS", 18, "m")
        if len(pay) > 4:
            diffs = [(pay[i][0], pay[i][1] - pay[i - 1][1]) for i in range(1, len(pay))]
            last3 = diffs[-3:]
            it = ensure_item(items, "nfp3m")
            it.update(value=round(sum(b for _, b in last3) / 3), asOf=nl_month(last3[-1][0]), src="FRED (BLS)",
                      change=" · ".join(f"{nl_month(a)} {signed(b, 0, 'k')}" for a, b in last3))
            series["nfp3m"] = [[a, b] for a, b in diffs]
    except Exception as e:
        if not fred_down():
            errors.append(f"maandcijfers: {e}")

    # 3. Netto liquiditeit = Fed-balans (WALCL, mln) − TGA (WTREGEN, mln) − reverse repo (RRPONTSYD, mld)
    try:
        if fred_down():
            raise sources.SourceError("overgeslagen")
        walcl, tga, rrp = fred_obs("WALCL", 60, "w"), fred_obs("WTREGEN", 60, "w"), fred_obs("RRPONTSYD", 400, "d")
        if walcl:
            wk = walcl[-1][1] - walcl[-2][1] if len(walcl) > 1 else None
            put(items, "fedAssets", round(walcl[-1][1] / 1e6, 3), "FRED (Fed H.4.1)", nl_date(walcl[-1][0]), obs=walcl[-1][0],
                change=(f"week: {signed(wk / 1000, 0, ' mld')}" if wk is not None else ""))

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
        if not fred_down():
            errors.append(f"liquiditeit: {e}")

    # 4. Daggrafieken: Twelve Data met sleutel, anders Yahoo Finance (met hoog/laag)
    if not TD_KEY:
        with sources.client() as h:
            for key, sym in LEVEL_YAHOO.items():
                if sources.yahoo_status()["pausedFor"]:
                    errors.append("Yahoo blokkeert even (429): daggrafieken overgeslagen")
                    break
                try:
                    y = sources.yahoo_chart(sym, "1y", "1d", http=h)
                except sources.SourceError as e:
                    errors.append(str(e))
                    continue
                bars = y["bars"]
                if key == "usdjpy":
                    bars = [b for b in bars if b[4] > 50]
                if len(bars) >= 20:
                    bars_by_key[key] = (bars, "Yahoo Finance")
                    series[key] = [[b[0], round(b[4], 4)] for b in bars[-130:]]
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

    # 5. Bitcoin daggrafiek: Yahoo (met hoog/laag), anders CoinGecko
    try:
        if sources.yahoo_status()["pausedFor"]:
            raise sources.SourceError("Yahoo BTC-USD: even gepauzeerd")
        y = sources.yahoo_chart("BTC-USD", "1y", "1d")
        if len(y["bars"]) >= 20:
            bars_by_key["btc"] = (y["bars"], "Yahoo Finance")
            series["btc"] = [[b[0], round(b[4])] for b in y["bars"][-130:]]
    except sources.SourceError as e:
        errors.append(str(e))
    if "btc" not in bars_by_key:
        try:
            pts = sources.coingecko_chart("bitcoin", 260)
            if pts:
                bars_by_key["btc"] = ([(d, p, p, p, p) for d, p in pts], "CoinGecko")
                series["btc"] = [[d, round(p)] for d, p in pts[-130:]]
        except sources.SourceError as e:
            errors.append(str(e))

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
    _save_sources("dagelijks", {"at": doc["updatedAt"], "ok": ok, "errors": errors[:20], "levels": len(rows),
                                "charts": sorted(bars_by_key)})
    check_triggers(items)
    check_actions(items)
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
            db.event("info" if a["stopped"].startswith("tijdslimiet") else "let op", "grok", a["stopped"])
    db.set_json("post:last", {"at": now_nl().isoformat(timespec="seconds"), "error": mail_error})
    if mail_error:
        raise RuntimeError(mail_error)


def koersen():
    from . import quotes
    r = quotes.refresh()
    if r["errors"]:  # alleen problemen in het logboek, niet elk kwartier een regel
        db.event("let op", "koersen", f"{r['updated']} koersen bijgewerkt: " + "; ".join(r["errors"][:3]))


def briefing():
    from . import briefing as b
    out = b.make()
    print("Briefing:", out.get("kop", ""), flush=True)


JOBS = {"post": post, "koersen": koersen, "markt": markt, "dagelijks": dagelijks, "briefing": briefing, "melding": melding}

if __name__ == "__main__":
    JOBS[sys.argv[1] if len(sys.argv) > 1 else "markt"]()
