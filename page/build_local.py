"""Bouwt één los HTML-bestand dat je in Chrome opent: python page/build_local.py [uitvoer.html]

Erin zitten: de pagina, de lokale opslag en koppelingen (page/local.js), je startplan met de
cyclus-analyse (seed/) en de lettertypen. Het bestand laadt niets van andere sites, behalve
Claude, Twelve Data en CoinGecko als je daar zelf sleutels voor invult.
"""
import base64
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root))
from app import patch as patchmod  # noqa: E402

out = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "dist" / "handelsplan.html"
src = (root / "page" / "handelsplan.html").read_text(encoding="utf-8")
head, body = src.split("<!--BODY-->", 1)
head = re.sub(r'<link rel="preconnect"[^>]*>\s*', "", head)
head = re.sub(r'<link rel="stylesheet" href="https://fonts\.googleapis\.com[^>]*>\s*', "", head)
assert "fonts.googleapis" not in head

FONTS = [("Bricolage Grotesque", 500, "bricolage-grotesque-latin-500-normal.woff2"),
         ("Bricolage Grotesque", 700, "bricolage-grotesque-latin-700-normal.woff2"),
         ("IBM Plex Sans", 400, "ibm-plex-sans-latin-400-normal.woff2"),
         ("IBM Plex Sans", 500, "ibm-plex-sans-latin-500-normal.woff2"),
         ("IBM Plex Sans", 600, "ibm-plex-sans-latin-600-normal.woff2"),
         ("IBM Plex Mono", 400, "ibm-plex-mono-latin-400-normal.woff2"),
         ("IBM Plex Mono", 500, "ibm-plex-mono-latin-500-normal.woff2")]
faces = "\n".join(
    f'@font-face{{font-family:"{fam}";font-style:normal;font-weight:{w};font-display:swap;'
    f'src:url(data:font/woff2;base64,{base64.b64encode((root / "page" / "fonts" / fn).read_bytes()).decode()}) format("woff2")}}'
    for fam, w, fn in FONTS)

S = root / "seed"
load = lambda fn: json.loads((S / fn).read_text(encoding="utf-8"))
plan, market = load("plan.json"), load("market.json")
patch = load("macro_patch.json")
patchmod.apply(plan, market, patch)
seed = {"docs": {"plan/current": plan, "market/latest": market,
                 "inbox/juli-plan": load("inbox_juli.json"), "history/v1-start": load("history_v1.json")},
        "patch": patch}
seed_json = json.dumps(seed, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
local_js = (root / "page" / "local.js").read_text(encoding="utf-8")
assert "</script" not in local_js

html = ('<!doctype html>\n<html lang="nl"><head><meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
        '<meta name="robots" content="noindex, nofollow">\n'
        '<style>\n/* Lettertypen zitten in dit bestand, dus de pagina laadt niets van Google.\n'
        '   Bricolage Grotesque (c) The Bricolage Grotesque Project Authors; IBM Plex (c) IBM Corp.\n'
        '   Beide onder de SIL Open Font License 1.1. */\n' + faces + '\n</style>\n'
        '<script type="application/json" id="hp-seed">' + seed_json + '</script>\n'
        '<script>\n' + local_js + '</script>\n' + head + '</head><body>\n' + body + '\n</body></html>\n')
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(html, encoding="utf-8")
print(f"{out}: {len(html.encode('utf-8')):,} bytes")
