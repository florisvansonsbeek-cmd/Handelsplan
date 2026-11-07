"""Live koersen van wat je volgt: Finnhub (FINNHUB_API_KEY) voor aandelen en ETF's, CoinGecko voor crypto.

Zonder Finnhub-sleutel (of als Finnhub een symbool niet kent of zijn limiet bereikt) komen de koersen
van Yahoo Finance, zonder sleutel. Een storing wordt per symbool vastgelegd; de rest gaat gewoon door.
"""
import os
from datetime import datetime, timezone

import httpx

from . import db

DEFAULT_WATCHLIST = [
    ("SMH", "Chips-ETF (VanEck)", "etf"), ("CRCL", "Circle", "aandeel"), ("GLD", "Goud (ETF, als graadmeter)", "etf"),
    ("BTC", "Bitcoin", "crypto"), ("VT", "Wereldaandelen (VT, graadmeter voor VWCE)", "etf"),
    ("NVDA", "Nvidia", "aandeel"), ("MSFT", "Microsoft", "aandeel"),
]
COINGECKO_IDS = {"BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana", "XRP": "ripple", "USDC": "usd-coin",
                 "ADA": "cardano", "DOGE": "dogecoin", "LINK": "chainlink", "AVAX": "avalanche-2", "DOT": "polkadot"}
# koppeling met de cijfers op de Markt-pagina
MARKET_KEYS = {"CRCL": "crcl", "MAGS": "mags", "BTC": "btc", "SMH": "smh"}


def finnhub_key():
    return os.environ.get("FINNHUB_API_KEY", "")


def ensure_watchlist():
    with db.conn() as c:
        if c.execute("SELECT COUNT(*) AS n FROM watchlist").fetchone()["n"] == 0:
            for i, (s, n, k) in enumerate(DEFAULT_WATCHLIST):
                c.execute("INSERT INTO watchlist(symbol,name,kind,position) VALUES(%s,%s,%s,%s) ON CONFLICT DO NOTHING", (s, n, k, i))


def watchlist():
    with db.conn() as c:
        return c.execute("SELECT w.symbol, w.name, w.kind, q.price, q.change_pct, q.prev_close, q.source, q.fetched_at, q.error "
                         "FROM watchlist w LEFT JOIN quotes q ON q.symbol=w.symbol ORDER BY w.position, w.symbol").fetchall()


def _save(symbol, price=None, change=None, prev=None, source=None, error=None):
    with db.conn() as c:
        if error:
            c.execute("INSERT INTO quotes(symbol,error,fetched_at) VALUES(%s,%s,now()) "
                      "ON CONFLICT(symbol) DO UPDATE SET error=excluded.error", (symbol, error[:200]))
        else:
            c.execute("INSERT INTO quotes(symbol,price,change_pct,prev_close,source,fetched_at,error) VALUES(%s,%s,%s,%s,%s,now(),NULL) "
                      "ON CONFLICT(symbol) DO UPDATE SET price=excluded.price, change_pct=excluded.change_pct, "
                      "prev_close=excluded.prev_close, source=excluded.source, fetched_at=now(), error=NULL",
                      (symbol, price, change, prev, source))


def refresh():
    from . import sources
    ensure_watchlist()
    rows = watchlist()
    out = {"updated": 0, "errors": []}
    key = finnhub_key()
    got = {}
    via_yahoo = []
    with httpx.Client(timeout=20) as h:
        finnhub_ok = bool(key)
        for r in rows:
            sym, kind = r["symbol"], r["kind"]
            if kind == "crypto":
                continue
            if not finnhub_ok:
                via_yahoo.append(sym)
                continue
            try:
                resp = h.get("https://finnhub.io/api/v1/quote", params={"symbol": sym}, headers={"X-Finnhub-Token": key})
                if resp.status_code == 429:
                    out["errors"].append("Finnhub: limiet bereikt (60 per minuut); de rest via Yahoo")
                    finnhub_ok = False
                    via_yahoo.append(sym)
                    continue
                if resp.status_code in (401, 403):
                    via_yahoo.append(sym)
                    continue
                resp.raise_for_status()
                q = resp.json()
                if not q or not q.get("c"):
                    via_yahoo.append(sym)
                    continue
                _save(sym, q["c"], q.get("dp"), q.get("pc"), "Finnhub")
                got[sym] = (q["c"], q.get("dp"), "Finnhub")
                out["updated"] += 1
            except (httpx.HTTPError, ValueError):
                via_yahoo.append(sym)
        for sym in via_yahoo:
            if sources.yahoo_status()["pausedFor"]:
                out["errors"].append("Yahoo blokkeert even (429); volgende poging over een kwartier")
                break
            try:
                y = sources.yahoo_chart(sym, "5d", "1d", http=h)
            except sources.SourceError as e:
                _save(sym, error=str(e))
                out["errors"].append(str(e))
                continue
            _save(sym, y["price"], y["changePct"], y["prev"], "Yahoo")
            got[sym] = (y["price"], y["changePct"], "Yahoo Finance")
            out["updated"] += 1
        crypto = [r["symbol"] for r in rows if r["kind"] == "crypto"]
        ids = {s: COINGECKO_IDS.get(s.upper(), s.lower()) for s in crypto}
        if ids:
            try:
                data = sources.coingecko(list(ids.values()), ("usd",), http=h)
                for s, cid in ids.items():
                    d = data.get(cid)
                    if d and d.get("usd"):
                        _save(s, d["usd"], d.get("usd_24h_change"), None, "CoinGecko")
                        got[s] = (d["usd"], d.get("usd_24h_change"), "CoinGecko")
                        out["updated"] += 1
                    else:
                        _save(s, error="onbekende munt bij CoinGecko")
            except sources.SourceError as e:
                out["errors"].append(str(e))
    _update_market(got)
    db.set_json("quotes:last", {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"), **out})
    return out


def _update_market(got):
    """Zet de live koersen (Finnhub, CoinGecko) van CRCL, SMH en bitcoin ook in de cijfers van de Markt-pagina.
    Yahoo-koersen staan daar al via de markttaak."""
    keys = {MARKET_KEYS[s]: v for s, v in got.items() if s in MARKET_KEYS and v[2] != "Yahoo Finance"}
    if not keys:
        return
    from .jobs import ensure_item, now_iso, signed, stamp
    doc = db.get_doc("market/latest") or {"items": []}
    items = {i["key"]: i for i in doc.get("items", [])}
    for k, (price, chg, src) in keys.items():
        it = ensure_item(items, k)
        it.update(value=float(price), asOf=stamp(), display=None, src=src, at=now_iso(),
                  change=(("24u: " if k == "btc" else "dag: ") + signed(float(chg), 1, "%")) if chg is not None else "")
    doc["items"] = list(items.values())
    doc["updatedAt"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    doc["updatedBy"] = "Server (automatisch)"
    db.set_doc("market/latest", doc)
