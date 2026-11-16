"""Bouwt app/pages/index.html (servervariant) uit page/handelsplan.html (zelfde bron als de Claude-voorbeeldversie)."""
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parent.parent
src = (root / "page" / "handelsplan.html").read_text(encoding="utf-8")
head, body = src.split("<!--BODY-->", 1)
# Versie in de scriptlink: na een update haalt de browser shim.js zeker opnieuw op (anders kan hij een oude kopie blijven gebruiken).
ver = hashlib.sha1((root / "app" / "static" / "shim.js").read_bytes()).hexdigest()[:10]
html = ('<!doctype html>\n<html lang="nl"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
        f'<script src="/static/shim.js?v={ver}"></script>\n' + head + '</head><body>\n' + body + '\n</body></html>\n')
(root / "app" / "pages").mkdir(exist_ok=True)
(root / "app" / "pages" / "index.html").write_text(html, encoding="utf-8")
print("index.html:", len(html), "bytes, shim.js versie", ver)
