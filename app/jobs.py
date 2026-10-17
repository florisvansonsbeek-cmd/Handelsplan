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
