"""Bouwt de losse html die met je Railway-site verbindt: python page/build_remote.py [uitvoer.html]

Erin zitten alleen de pagina, de lettertypen en de koppeling (page/remote.js + app/static/shim.js).
Geen plan, geen gegevens en geen sleutels: die staan op de server. Bij openen log je in met het
adres van je Railway-site en APP_PASSWORD.
"""
import base64
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "dist" / "handelsplan-2027.html"
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
js = (root / "page" / "remote.js").read_text(encoding="utf-8") + "\n" + (root / "app" / "static" / "shim.js").read_text(encoding="utf-8")
assert "</script" not in js

html = ('<!doctype html>\n<html lang="nl"><head><meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
        '<meta name="robots" content="noindex, nofollow">\n'
        '<!-- Handelsplan 2027: losse html die alles via je Railway-site laat lopen (database, mail, Grok, koersen). -->\n'
        '<style>\n/* Bricolage Grotesque (c) The Bricolage Grotesque Project Authors; IBM Plex (c) IBM Corp. SIL OFL 1.1. */\n'
        + faces + '\n</style>\n<script>\n' + js + '</script>\n' + head + '</head><body>\n' + body + '\n</body></html>\n')
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(html, encoding="utf-8")
print(f"{out}: {len(html.encode('utf-8')):,} bytes")
