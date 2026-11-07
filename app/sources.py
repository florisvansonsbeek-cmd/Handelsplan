"""Gratis databronnen die zonder sleutel werken.

- FRED (St. Louis Fed): de CSV-download van elke reeks. Met FRED_API_KEY gebruikt jobs.py de officiële API.
- Yahoo Finance: de grafiek-API (koersen ±15 min vertraagd, plus daggrafieken met hoog/laag).
- CoinGecko: bitcoin, en als reserve goud (PAXG) en zilver (KAG), plus de euro via USDC.

Elke functie geeft gewone Python-waarden terug of gooit SourceError; de taken vangen dat per
cijfer af, zodat één haperende bron nooit de rest tegenhoudt.
"""
import csv
import io
import json
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

import httpx

try:  # Yahoo weigert verzoeken die niet als een gewone browser binnenkomen (429); curl_cffi doet zich voor als Chrome
    from curl_cffi import requests as cffi_requests
except ImportError:  # zonder curl_cffi werkt alles behalve (waarschijnlijk) Yahoo
    cffi_requests = None

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36",
      "Accept": "application/json,text/csv,*/*"}
FRED_CSV = os.environ.get("FRED_CSV_URL", "https://fred.stlouisfed.org/graph/fredgraph.csv")
YAHOO_HOSTS = [h.strip().rstrip("/") for h in os.environ.get(
    "YAHOO_HOSTS", "https://query1.finance.yahoo.com,https://query2.finance.yahoo.com").split(",") if h.strip()]
COINGECKO = os.environ.get("COINGECKO_URL", "https://api.coingecko.com/api/v3").rstrip("/")


YAHOO_WARMUP = os.environ.get("YAHOO_WARMUP", "https://fc.yahoo.com")  # haalt het cookie op dat Yahoo verwacht
# Na een blokkade of time-outs een bron zo lang overslaan, zodat de planner nooit vastloopt op één bron.
PAUSE = {"yahoo": int(os.environ.get("YAHOO_PAUSE_SEC", "900")), "fred": int(os.environ.get("FRED_PAUSE_SEC", "1800"))}
FAILS_BEFORE_PAUSE = {"yahoo": 1, "fred": 2}


class SourceError(Exception):
    """Een bron gaf geen bruikbaar antwoord."""


def client(timeout=25):
    return httpx.Client(timeout=timeout, headers=UA, follow_redirects=True)


# ---------------------------------------------------------------- browserverbinding en pauzes
_state = {"session": None, "warm": False, "paused": {"yahoo": 0.0, "fred": 0.0}, "fails": {"yahoo": 0, "fred": 0}}
_lock = threading.Lock()


def paused(src):
    """Seconden dat bron `src` nog wordt overgeslagen (0 = gewoon proberen)."""
    left = _state["paused"].get(src, 0.0) - time.time()
    return int(left) if left > 0 else 0


def _ok(src):
    _state["fails"][src] = 0
    _state["paused"][src] = 0.0


def _fail(src):
    _state["fails"][src] += 1
    if _state["fails"][src] >= FAILS_BEFORE_PAUSE[src]:
        _state["paused"][src] = time.time() + PAUSE[src]
        _state["fails"][src] = 0


def browser_get(url, params=None, timeout=20, warmup=None):
    """GET met de verbindingsvingerafdruk van Chrome (curl_cffi, zoals yfinance), anders gewoon httpx.
    Yahoo en de FRED-site weigeren of laten scripts hangen; als Chrome komen ze wel binnen. Geeft (status, tekst)."""
    if cffi_requests is None:
        r = httpx.get(url, params=params, headers=UA, timeout=timeout, follow_redirects=True)
        return r.status_code, r.text
    with _lock:
        if _state["session"] is None:
            _state["session"] = cffi_requests.Session(impersonate="chrome")
        sess = _state["session"]
        if warmup and not _state["warm"]:
            _state["warm"] = True
            try:
                sess.get(warmup, timeout=8, allow_redirects=True)
            except Exception:  # het cookie is mooi meegenomen, maar niet nodig
                pass
        r = sess.get(url, params=params, timeout=timeout, allow_redirects=True)
        return r.status_code, r.text


def status():
    return {"browser": cffi_requests is not None, "pausedFor": {k: paused(k) for k in ("yahoo", "fred")}}


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
    """Een FRED-reeks via de CSV-download. Na twee mislukte pogingen (time-out, blokkade) een half uur pauze."""
    left = paused("fred")
    if left:
        raise SourceError(f"FRED {series}: niet bereikbaar, nieuwe poging over {max(1, left // 60)} min")
    params = {"id": series}
    if start:
        params["cosd"] = start
    try:
        code, text = browser_get(FRED_CSV, params, timeout=20)
    except Exception as e:  # time-out of netwerkfout
        _fail("fred")
        raise SourceError(f"FRED {series}: {e.__class__.__name__}") from e
    if code >= 400:
        if code in (403, 429) or code >= 500:
            _fail("fred")
        raise SourceError(f"FRED {series}: HTTP {code}")
    try:
        out = parse_fred_csv(text)
    except SourceError:
        _fail("fred")
        raise
    _ok("fred")
    return out


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


def yahoo_status():
    """Voor de taken en de verbindingstest: is Yahoo even gepauzeerd?"""
    return {"browser": cffi_requests is not None, "pausedFor": paused("yahoo")}


def yahoo_chart(symbol, rng="5d", interval="1d", http=None):
    """Koers en daggrafiek van één symbool. `http` wordt alleen gebruikt als curl_cffi ontbreekt."""
    if paused("yahoo"):
        raise SourceError(f"Yahoo {symbol}: even gepauzeerd na een blokkade (429)")
    last, n429 = "geen antwoord", 0
    params = {"range": rng, "interval": interval, "includePrePost": "false"}
    for host in YAHOO_HOSTS:
        url = f"{host}/v8/finance/chart/{quote(symbol, safe='')}"
        try:
            if cffi_requests is None and http is not None:
                r = http.get(url, params=params, headers=UA, timeout=20, follow_redirects=True)
                code, text = r.status_code, r.text
            else:
                code, text = browser_get(url, params, timeout=20, warmup=YAHOO_WARMUP)
        except Exception as e:  # netwerkfout, time-out, TLS: probeer de volgende host
            last = e.__class__.__name__
            continue
        if code == 429:
            n429 += 1
            last = "limiet bereikt (429)"
            continue
        if code >= 400 and code != 404:
            last = f"HTTP {code}"
            continue
        try:
            res = ((json.loads(text) or {}).get("chart") or {}).get("result") or []
        except ValueError:
            last = "geen JSON"
            continue
        if not res:
            last = "onbekend symbool"
            continue
        _ok("yahoo")
        return parse_yahoo(res[0])
    if n429 == len(YAHOO_HOSTS):  # alle hosts weigeren: even pauzeren in plaats van door te hameren
        _fail("yahoo")
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
