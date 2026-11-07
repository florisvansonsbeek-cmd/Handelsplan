"""Gratis databronnen die zonder sleutel werken.

- FRED (St. Louis Fed): de CSV-download van elke reeks. Met FRED_API_KEY gebruikt jobs.py de API.
- Yahoo Finance: de grafiek-API (koersen ±15 min vertraagd, plus daggrafieken met hoog/laag).
- CoinGecko: bitcoin, en als reserve goud (PAXG) en zilver (KAG), plus de euro via USDC.

Elke functie geeft gewone Python-waarden terug of gooit SourceError; de taken vangen dat per
cijfer af, zodat één haperende bron nooit de rest tegenhoudt.
"""
import csv
import io
import os
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

import httpx

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36",
      "Accept": "application/json,text/csv,*/*"}
FRED_CSV = os.environ.get("FRED_CSV_URL", "https://fred.stlouisfed.org/graph/fredgraph.csv")
YAHOO_HOSTS = [h.strip().rstrip("/") for h in os.environ.get(
    "YAHOO_HOSTS", "https://query1.finance.yahoo.com,https://query2.finance.yahoo.com").split(",") if h.strip()]
COINGECKO = os.environ.get("COINGECKO_URL", "https://api.coingecko.com/api/v3").rstrip("/")


class SourceError(Exception):
    """Een bron gaf geen bruikbaar antwoord."""


def client(timeout=25):
    return httpx.Client(timeout=timeout, headers=UA, follow_redirects=True)


# ---------------------------------------------------------------- FRED (CSV)
def parse_fred_csv(text):
    """'observation_date,DGS10\\n2026-11-05,4.84\\n2026-11-06,.' -> [('2026-11-05', 4.84)]"""
    t = (text or "").lstrip("﻿")
    if not t.strip() or t.lstrip().startswith("<"):
        raise SourceError("FRED gaf geen CSV")
    out = []
    for row in list(csv.reader(io.StringIO(t)))[1:]:
        if len(row) < 2:
            continue
        d, v = row[0].strip(), row[1].strip()
        if not d or v in ("", ".", "NaN", "nan"):
            continue
        try:
            out.append((d[:10], float(v)))
        except ValueError:
            continue
    return out


def fred_csv(series, start=None, http=None):
    params = {"id": series}
    if start:
        params["cosd"] = start
    try:
        r = (http or httpx).get(FRED_CSV, params=params, headers=UA, timeout=40, follow_redirects=True)
    except httpx.HTTPError as e:
        raise SourceError(f"FRED {series}: {e.__class__.__name__}") from e
    if r.status_code >= 400:
        raise SourceError(f"FRED {series}: HTTP {r.status_code}")
    return parse_fred_csv(r.text)


def fred_start(limit, freq="d"):
    """Startdatum zodat er ruim `limit` waarnemingen in zitten."""
    days = {"d": limit * 1.6 + 10, "w": limit * 7 + 21, "m": limit * 31 + 62, "q": limit * 92 + 120}.get(freq, limit * 1.6 + 10)
    return (datetime.now(timezone.utc).date() - timedelta(days=int(days))).isoformat()


# ---------------------------------------------------------------- Yahoo Finance
def parse_yahoo(res):
    """Eén 'result' uit de chart-API -> dict met prijs, vorige slot, dagbalken en tijd."""
    meta = res.get("meta") or {}
    off = int(meta.get("gmtoffset") or 0)
    ts = res.get("timestamp") or []
    q = ((res.get("indicators") or {}).get("quote") or [{}])[0]
    opens, highs, lows, closes = (q.get(k) or [] for k in ("open", "high", "low", "close"))
    bars = []
    for i, t in enumerate(ts):
        c = closes[i] if i < len(closes) else None
        if c is None:
            continue
        d = datetime.fromtimestamp(int(t) + off, timezone.utc).date().isoformat()
        o = opens[i] if i < len(opens) and opens[i] is not None else c
        h = highs[i] if i < len(highs) and highs[i] is not None else max(o, c)
        lo = lows[i] if i < len(lows) and lows[i] is not None else min(o, c)
        if bars and bars[-1][0] == d:
            bars[-1] = (d, bars[-1][1], max(bars[-1][2], h), min(bars[-1][3], lo), c)
        else:
            bars.append((d, float(o), float(h), float(lo), float(c)))
    price = meta.get("regularMarketPrice")
    mtime = meta.get("regularMarketTime")
    if price is None and bars:
        price = bars[-1][4]
    if price is None:
        raise SourceError("Yahoo gaf geen koers")
    mdate = datetime.fromtimestamp(int(mtime) + off, timezone.utc).date().isoformat() if mtime else (bars[-1][0] if bars else None)
    prev = None
    for b in reversed(bars):
        if mdate and b[0] < mdate:
            prev = b[4]
            break
    if prev is None:
        prev = meta.get("previousClose") or meta.get("chartPreviousClose")
    return {
        "price": float(price), "prev": float(prev) if prev else None,
        "changePct": (float(price) / float(prev) - 1) * 100 if prev else None,
        "date": mdate, "time": datetime.fromtimestamp(int(mtime), timezone.utc).isoformat(timespec="seconds") if mtime else None,
        "currency": meta.get("currency") or "", "bars": bars, "symbol": meta.get("symbol") or "",
    }


def yahoo_chart(symbol, rng="5d", interval="1d", http=None):
    last = "geen antwoord"
    for host in YAHOO_HOSTS:
        try:
            r = (http or httpx).get(f"{host}/v8/finance/chart/{quote(symbol, safe='')}", headers=UA, timeout=20, follow_redirects=True,
                                    params={"range": rng, "interval": interval, "includePrePost": "false"})
        except httpx.HTTPError as e:
            last = e.__class__.__name__
            continue
        if r.status_code == 429:
            last = "limiet bereikt (429)"
            continue
        if r.status_code >= 400:
            last = f"HTTP {r.status_code}"
            continue
        try:
            res = ((r.json() or {}).get("chart") or {}).get("result") or []
        except ValueError:
            last = "geen JSON"
            continue
        if not res:
            last = "onbekend symbool"
            continue
        return parse_yahoo(res[0])
    raise SourceError(f"Yahoo {symbol}: {last}")


# ---------------------------------------------------------------- CoinGecko
def coingecko(ids, vs=("usd",), http=None):
    try:
        r = (http or httpx).get(f"{COINGECKO}/simple/price", headers=UA, timeout=20, follow_redirects=True,
                                params={"ids": ",".join(ids), "vs_currencies": ",".join(vs), "include_24hr_change": "true"})
    except httpx.HTTPError as e:
        raise SourceError(f"CoinGecko: {e.__class__.__name__}") from e
    if r.status_code >= 400:
        raise SourceError(f"CoinGecko: HTTP {r.status_code}")
    try:
        return r.json() or {}
    except ValueError as e:
        raise SourceError("CoinGecko: geen JSON") from e


def coingecko_chart(coin="bitcoin", days=260, http=None):
    """Dagkoersen [(datum, prijs)] van CoinGecko (reserve voor de bitcoingrafiek)."""
    try:
        r = (http or httpx).get(f"{COINGECKO}/coins/{coin}/market_chart", headers=UA, timeout=30, follow_redirects=True,
                                params={"vs_currency": "usd", "days": days, "interval": "daily"})
    except httpx.HTTPError as e:
        raise SourceError(f"CoinGecko-grafiek: {e.__class__.__name__}") from e
    if r.status_code >= 400:
        raise SourceError(f"CoinGecko-grafiek: HTTP {r.status_code}")
    try:
        prices = (r.json() or {}).get("prices") or []
    except ValueError as e:
        raise SourceError("CoinGecko-grafiek: geen JSON") from e
    pts = []
    for ms, price in prices:
        d = datetime.fromtimestamp(ms / 1000, timezone.utc).date().isoformat()
        if pts and pts[-1][0] == d:
            pts[-1] = (d, price)
        else:
            pts.append((d, price))
    return pts
