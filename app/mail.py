"""E-mail ophalen via IMAP (iCloud) en bijlagen omzetten naar tekst.

- Alleen lezen: berichten blijven ongelezen en worden niet verplaatst (BODY.PEEK, readonly).
- Bij de eerste keer de laatste EMAIL_SINCE_DAYS dagen (standaard 14), daarna alleen nieuwe berichten.
- Per ronde maximaal EMAIL_MAX_PER_RUN berichten (standaard 40).
- Map instelbaar met EMAIL_FOLDER (standaard INBOX). Tip: maak in iCloud Mail een map "Handelsplan"
  met een regel, dan analyseert Grok alleen wat daarin komt.
"""
import email
import email.policy
import hashlib
import html
import imaplib
import io
import os
import re
import socket
import zipfile
from datetime import datetime, timedelta, timezone
from email.utils import parseaddr, parsedate_to_datetime

from . import db

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
MAX_ATTACHMENT = 15 * 1024 * 1024
MAX_IMAGE_BLOB = 5 * 1024 * 1024
MAX_TEXT = 200_000


def settings():
    env = os.environ.get
    return {"host": env("EMAIL_HOST", ""), "port": int(env("EMAIL_PORT", "993") or 993), "user": env("EMAIL_USER", ""),
            "password": env("EMAIL_PASS", ""), "folder": env("EMAIL_FOLDER", "INBOX") or "INBOX",
            "since_days": int(env("EMAIL_SINCE_DAYS", "14") or 14), "max": int(env("EMAIL_MAX_PER_RUN", "40") or 40)}


def configured():
    s = settings()
    return bool(s["host"] and s["user"] and s["password"])


# ---------------- tekst uit bijlagen ----------------
def _strip_html(s):
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s)
    s = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>|</h\d>|</li>", "\n", s)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    s = re.sub(r"[ \t\r\f\v]+", " ", s)
    return re.sub(r"\n\s*\n+", "\n\n", s).strip()


def _decode(b: bytes):
    for enc in ("utf-8", "cp1252", "latin-1"):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            continue
    return b.decode("utf-8", "replace")


def _xml_text(z, name):
    try:
        return _strip_html(z.read(name).decode("utf-8", "replace").replace("</w:p>", "\n").replace("</a:p>", "\n"))
    except KeyError:
        return ""


def extract_text(filename: str, ctype: str, data: bytes):
    """Geeft (tekst, soort) terug. soort: 'tekst', 'afbeelding' of 'overgeslagen'."""
    name = (filename or "").lower()
    ctype = (ctype or "").lower()
    if ctype == "application/pdf" or name.endswith(".pdf"):
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(data))
        parts = []
        for page in reader.pages[:60]:
            try:
                parts.append(page.extract_text() or "")
            except Exception:  # één kapotte pagina mag de rest niet tegenhouden
                continue
        return "\n".join(parts).strip(), "tekst"
    if name.endswith(".docx") or "wordprocessingml" in ctype:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            return _xml_text(z, "word/document.xml"), "tekst"
    if name.endswith(".xlsx") or "spreadsheetml" in ctype:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            sheets = sorted(n for n in z.namelist() if n.startswith("xl/worksheets/sheet"))
            return (_xml_text(z, "xl/sharedStrings.xml") + "\n" + "\n".join(_xml_text(z, s) for s in sheets[:5])).strip(), "tekst"
    if name.endswith(".pptx") or "presentationml" in ctype:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            slides = sorted(n for n in z.namelist() if re.match(r"ppt/slides/slide\d+\.xml$", n))
            return "\n".join(_xml_text(z, s) for s in slides[:40]).strip(), "tekst"
    if ctype in ("text/html", "application/xhtml+xml") or name.endswith((".html", ".htm")):
        return _strip_html(_decode(data)), "tekst"
    if ctype.startswith("text/") or name.endswith((".txt", ".csv", ".md", ".json", ".xml", ".tsv", ".eml")):
        return _decode(data), "tekst"
    if ctype in ("image/jpeg", "image/png", "image/jpg") or name.endswith((".jpg", ".jpeg", ".png")):
        return "", "afbeelding"
    return "", "overgeslagen"


def _body_text(msg):
    plain = msg.get_body(preferencelist=("plain",))
    if plain is not None:
        try:
            return plain.get_content().strip()
        except (LookupError, UnicodeDecodeError):
            return _decode(plain.get_payload(decode=True) or b"").strip()
    htmlpart = msg.get_body(preferencelist=("html",))
    if htmlpart is not None:
        try:
            return _strip_html(htmlpart.get_content())
        except (LookupError, UnicodeDecodeError):
            return _strip_html(_decode(htmlpart.get_payload(decode=True) or b""))
    return ""


def _attachments(msg):
    """Echte bijlagen; kleine inline-afbeeldingen (logo's, handtekeningen) slaan we over."""
    for part in msg.walk():
        if part.is_multipart():
            continue
        disp = (part.get_content_disposition() or "").lower()
        fname = part.get_filename() or ""
        ctype = part.get_content_type()
        if disp != "attachment" and not fname:
            continue
        data = part.get_payload(decode=True) or b""
        if disp == "inline" and ctype.startswith("image/") and len(data) < 40_000:
            continue
        yield fname or f"bijlage.{ctype.split('/')[-1]}", ctype, data


# ---------------- opslaan ----------------
def store_message(folder, uid, raw: bytes):
    """Slaat één bericht op met zijn bijlagen als documenten. Geeft het aantal nieuwe documenten terug."""
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    try:
        received = parsedate_to_datetime(msg["Date"]) if msg["Date"] else None
        if received and received.tzinfo is None:
            received = received.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        received = None
    subject = str(msg["Subject"] or "")[:500]
    sender = parseaddr(str(msg["From"] or ""))
    from_addr = (f"{sender[0]} <{sender[1]}>" if sender[0] else sender[1])[:300]
    body = _body_text(msg)[:MAX_TEXT]
    atts = list(_attachments(msg))
    with db.conn() as c:
        row = c.execute(
            "INSERT INTO mails(folder,uid,message_id,from_addr,subject,received_at,body_text,attachments) "
            "VALUES(%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(folder,uid) DO NOTHING RETURNING id",
            (folder, uid, str(msg["Message-ID"] or "")[:300], from_addr, subject, received, body, len(atts))).fetchone()
        if not row:
            return 0
        mail_id, n = row["id"], 0
        if len(body) > 40 or not atts:
            c.execute("INSERT INTO documents(mail_id,kind,filename,content_type,size,text_content,status) "
                      "VALUES(%s,'email','',%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                      (mail_id, "text/plain", len(body), body, "nieuw" if body else "overgeslagen"))
            n += 1
        seen = set()
        for fname, ctype, data in atts:
            base, k = fname, 2
            while fname in seen:  # twee bijlagen met dezelfde naam
                fname = f"{base} ({k})"
                k += 1
            seen.add(fname)
            sha = hashlib.sha256(data).hexdigest()
            text, kind, err, blob, status = "", "overgeslagen", None, None, "nieuw"
            if len(data) > MAX_ATTACHMENT:
                status, err = "overgeslagen", "bijlage groter dan 15 MB"
            else:
                try:
                    text, kind = extract_text(fname, ctype, data)
                except Exception as e:  # kapotte of beveiligde bijlage: vastleggen en doorgaan
                    status, err = "fout", f"kon de bijlage niet lezen: {e.__class__.__name__}"
                if status == "nieuw":
                    if kind == "afbeelding":
                        if len(data) <= MAX_IMAGE_BLOB:
                            blob = data
                        else:
                            status, err = "overgeslagen", "afbeelding groter dan 5 MB"
                    elif kind == "overgeslagen":
                        status, err = "overgeslagen", f"bestandstype {ctype} wordt niet gelezen"
                    elif not text.strip():
                        status, err = "overgeslagen", "geen leesbare tekst (bijv. een gescande PDF)"
            c.execute("INSERT INTO documents(mail_id,kind,filename,content_type,size,sha256,text_content,blob,status,error) "
                      "VALUES(%s,'bijlage',%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                      (mail_id, fname[:300], ctype, len(data), sha, text[:MAX_TEXT], blob, status, err))
            n += 1
    return n


def _since(days):
    d = datetime.now(timezone.utc) - timedelta(days=days)
    return f"{d.day:02d}-{MONTHS[d.month - 1]}-{d.year}"


def _quote(folder):
    return '"' + folder.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fetch_new(client_factory=None):
    """Haalt nieuwe berichten op. client_factory is er alleen voor tests."""
    s = settings()
    if not configured():
        return {"skipped": "EMAIL_HOST, EMAIL_USER of EMAIL_PASS ontbreekt"}
    folder = s["folder"]
    out = {"messages": 0, "documents": 0, "errors": []}
    try:
        M = (client_factory or (lambda: imaplib.IMAP4_SSL(s["host"], s["port"], timeout=30)))()
    except (OSError, socket.timeout, imaplib.IMAP4.error) as e:
        raise RuntimeError(f"mailserver {s['host']}:{s['port']} niet bereikbaar ({e.__class__.__name__})") from e
    try:
        try:
            M.login(s["user"], s["password"])
        except imaplib.IMAP4.error as e:
            raise RuntimeError("inloggen bij de mailserver mislukt: controleer EMAIL_USER en EMAIL_PASS "
                               "(bij iCloud een app-specifiek wachtwoord)") from e
        typ, data = M.select(_quote(folder), readonly=True)
        if typ != "OK":
            raise RuntimeError(f"map '{folder}' bestaat niet op de mailserver")
        typ, resp = M.response("UIDVALIDITY")
        validity = (resp[0].decode() if resp and resp[0] else "")
        state = db.get_json(f"mail:{folder}", {}) or {}
        if state.get("validity") and validity and state["validity"] != validity:
            state = {}  # map is opnieuw opgebouwd: opnieuw beginnen
        last = int(state.get("last_uid", 0))
        if last:
            typ, data = M.uid("SEARCH", None, f"UID {last + 1}:*")
        else:
            typ, data = M.uid("SEARCH", None, "SINCE", _since(s["since_days"]))
        uids = sorted(int(x) for x in (data[0].split() if data and data[0] else []) if int(x) > last)
        for uid in uids[: s["max"]]:
            try:
                typ, parts = M.uid("FETCH", str(uid), "(BODY.PEEK[])")
                raw = next((p[1] for p in parts if isinstance(p, tuple) and len(p) > 1), None)
                if raw:
                    out["documents"] += store_message(folder, uid, raw)
                    out["messages"] += 1
            except db.DBError:
                raise
            except Exception as e:  # één vreemd bericht mag de rest niet blokkeren
                out["errors"].append(f"bericht {uid}: {e.__class__.__name__}: {str(e)[:120]}")
            last = max(last, uid)
            db.set_json(f"mail:{folder}", {"validity": validity, "last_uid": last})
        out["remaining"] = max(0, len(uids) - s["max"])
    finally:
        try:
            M.logout()
        except Exception:
            pass
    return out
