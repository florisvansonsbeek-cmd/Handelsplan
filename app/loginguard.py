"""Bescherming van het inloggen, vooral met een korte pincode.

Een pincode van 4 cijfers is snel geraden als iemand onbeperkt mag proberen. Tegelijk mag een bot die steeds een
verkeerde pincode probeert jou niet buitensluiten. Daarom twee soorten apparaten:

- Bekende apparaten: browsers en losse html's waarop al eens met de juiste pincode is ingelogd. Ze krijgen een
  ondertekend apparaatbewijs (cookie 'hp_dev' op de site, of een waarde die de losse html bewaart). Een bekend
  apparaat heeft alleen zijn eigen grens: 5 foute pogingen per 15 minuten en 10 per 24 uur.
- Onbekende apparaten: 5 foute pogingen per 15 minuten per adres, 4 per 24 uur per netwerk (IPv4 /24, IPv6 /48)
  en 10 per 24 uur voor alle onbekende apparaten samen. Raden kost dan gemiddeld jaren.

De tellers staan in de database (kv 'login:fails'), zodat een herstart ze niet wist, en horen bij het huidige
wachtwoord: wijzig je APP_PASSWORD, dan beginnen ze opnieuw.
"""
import ipaddress
import secrets
import threading
import time
from datetime import datetime

from itsdangerous import BadSignature, URLSafeTimedSerializer

from . import db

WINDOW = 86400                 # 24 uur
SHORT_WINDOW = 900             # 15 minuten
SHORT_LIMIT = 5                # foute pogingen per 15 minuten per apparaat of adres
NET_LIMIT = 4                  # foute pogingen per 24 uur per netwerk (onbekende apparaten)
DEVICE_LIMIT = 10              # foute pogingen per 24 uur per bekend apparaat
DEVICE_DAYS = 400              # zo lang blijft een apparaat bekend zonder opnieuw in te loggen
COOKIE = "hp_dev"

_lock = threading.Lock()
_short: dict[str, list[float]] = {}   # in het geheugen: 15-minutengrens
_mem: dict = {}                       # reserve als de database even weg is
GUARD = None                          # gezet door configure() bij het starten van de server


def configure(secret, tag, daily_limit=10, tz=None):
    global GUARD
    GUARD = Guard(secret, tag, daily_limit, tz)
    return GUARD


class Guard:
    """Alle tellers voor één wachtwoord. secret ondertekent apparaatbewijzen, tag hoort bij APP_PASSWORD."""

    def __init__(self, secret, tag, daily_limit=10, tz=None):
        self.signer = URLSafeTimedSerializer(secret, salt="handelsplan-device")
        self.tag = tag
        self.daily_limit = daily_limit
        self.tz = tz

    # ---------- apparaatbewijs ----------
    def new_device(self, dev_id=None):
        return self.signer.dumps({"d": dev_id or secrets.token_hex(8), "v": 1})

    def device_id(self, token):
        """De id van een geldig apparaatbewijs, of None."""
        if not token or not isinstance(token, str) or len(token) > 400:
            return None
        try:
            data = self.signer.loads(token, max_age=DEVICE_DAYS * 86400)
        except BadSignature:
            return None
        d = data.get("d") if isinstance(data, dict) else None
        return d if isinstance(d, str) and 4 <= len(d) <= 40 else None

    # ---------- opslag ----------
    def _load(self):
        try:
            st = db.get_json("login:fails") or {}
        except db.DBError:
            st = dict(_mem)
        if st.get("tag") != self.tag:
            st = {"tag": self.tag}
        now = time.time()
        fresh = lambda xs: [t for t in (xs or []) if isinstance(t, (int, float)) and now - t < WINDOW]
        st["fails"] = fresh(st.get("fails"))
        st["nets"] = {k: v for k, v in ((k, fresh(v)) for k, v in (st.get("nets") or {}).items()) if v}
        st["devs"] = {k: v for k, v in ((k, fresh(v)) for k, v in (st.get("devs") or {}).items()) if v}
        if st.get("last") and now - float(st["last"].get("at") or 0) > WINDOW:
            st.pop("last", None)
        return st

    def _save(self, st):
        _mem.clear()
        _mem.update(st)
        try:
            db.set_json("login:fails", st)
        except db.DBError:
            pass

    def _until(self, times):
        t = min(times) + WINDOW
        return datetime.fromtimestamp(t, self.tz).strftime("%d-%m %H:%M") if self.tz else ""

    # ---------- de grenzen ----------
    def blocked(self, ip, dev):
        """Een foutmelding (status, tekst) als dit apparaat nu niet mag proberen, anders None."""
        now = time.time()
        key = ("dev:" + dev) if dev else ("ip:" + ip)
        with _lock:
            _short[key] = [t for t in _short.get(key, []) if now - t < SHORT_WINDOW]
            if len(_short[key]) >= SHORT_LIMIT:
                return 429, "Te veel pogingen achter elkaar. Probeer het over 15 minuten opnieuw."
            st = self._load()
        if dev:
            mine = st["devs"].get(dev, [])
            if len(mine) >= DEVICE_LIMIT:
                return 429, (f"Te veel foute pogingen op dit apparaat, tot {self._until(mine)}. "
                             "Wil je meteen weer in? Wijzig APP_PASSWORD in Railway.")
            return None
        net = net_of(ip)
        mine = st["nets"].get(net, [])
        if len(mine) >= NET_LIMIT:
            return 429, (f"Te veel foute pogingen vanaf dit netwerk, tot {self._until(mine)}. Apparaten waarop je al "
                         "eerder bent ingelogd kunnen gewoon in.")
        if len(st["fails"]) >= self.daily_limit:
            return 429, (f"Inloggen is dicht voor nieuwe apparaten na {self.daily_limit} foute pogingen, tot "
                         f"{self._until(st['fails'])}. Apparaten waarop je al eerder bent ingelogd kunnen gewoon in. "
                         "Wil je meteen op dit apparaat? Wijzig APP_PASSWORD in Railway.")
        return None

    def failed(self, ip, dev):
        """Telt een foute poging.

        Geeft terug: left (pogingen over voor dit apparaat of netwerk vandaag), closed ('apparaat', 'netwerk',
        'nieuw' of None: wat er met deze poging dichtging) en unknown24h (foute pogingen van onbekende apparaten)."""
        now = time.time()
        key = ("dev:" + dev) if dev else ("ip:" + ip)
        with _lock:
            _short.setdefault(key, []).append(now)
            st = self._load()
            if dev:
                st["devs"].setdefault(dev, []).append(now)
                n = len(st["devs"][dev])
                left, closed = DEVICE_LIMIT - n, "apparaat" if n == DEVICE_LIMIT else None
            else:
                net = net_of(ip)
                st["nets"].setdefault(net, []).append(now)
                st["fails"].append(now)
                n_net, n_all = len(st["nets"][net]), len(st["fails"])
                left = min(NET_LIMIT - n_net, self.daily_limit - n_all)
                closed = "nieuw" if n_all == self.daily_limit else "netwerk" if n_net == NET_LIMIT else None
            st["last"] = {"at": now, "net": mask(ip), "known": bool(dev)}
            self._save(st)
        return {"left": left, "closed": closed, "unknown24h": len(st["fails"])}

    def succeeded(self, ip, dev):
        with _lock:
            _short.pop(("dev:" + dev) if dev else ("ip:" + ip), None)
            st = self._load()
            changed = False
            if dev and st["devs"].pop(dev, None):
                changed = True
            net = net_of(ip)
            if not dev and st["nets"].pop(net, None):
                changed = True
            if changed:
                self._save(st)

    def summary(self):
        """Voor Uitleg en de verbindingstest: hoe staat het inloggen ervoor?"""
        with _lock:
            st = self._load()
        n = len(st["fails"])
        nets = sorted(st["nets"].items(), key=lambda kv: -len(kv[1]))
        last = st.get("last") or {}
        out = {"fails24h": n, "limit": self.daily_limit, "networks": len(nets),
               "closed": n >= self.daily_limit, "deviceFails": sum(len(v) for v in st["devs"].values()),
               "lastAt": datetime.fromtimestamp(last["at"], self.tz).isoformat(timespec="seconds") if last.get("at") and self.tz else None,
               "lastFrom": last.get("net"), "lastKnown": last.get("known")}
        if nets:
            out["topNet"] = mask_net(nets[0][0])
            out["topNetFails"] = len(nets[0][1])
        return out


def client_ip(request):
    """Het adres van de bezoeker. Railway zet X-Real-IP zelf; daarna wat uvicorn uit de proxykoppen haalde."""
    ip = (request.headers.get("x-real-ip") or "").strip()
    if not ip:
        ip = request.client.host if request.client else ""
    try:
        return str(ipaddress.ip_address(ip))
    except ValueError:
        return ip[:64] or "?"


def net_of(ip):
    """Het netwerk van een adres: IPv4 /24, IPv6 /48. Zo telt een bot die van adres wisselt binnen één netwerk als één."""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    return str(ipaddress.ip_network(f"{a}/{24 if a.version == 4 else 48}", strict=False))


def mask(ip):
    """Adres zonder laatste deel, voor op de site: 152.55.182.x."""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return "onbekend"
    if a.version == 4:
        return ".".join(str(a).split(".")[:3]) + ".x"
    return str(ipaddress.ip_network(f"{a}/48", strict=False)).replace("::/48", ":…")


def mask_net(net):
    return net.replace(".0/24", ".x").replace("::/48", ":…")
