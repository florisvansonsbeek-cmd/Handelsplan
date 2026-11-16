"""Tekst uit een document halen voor de inbox (transcripten en notities).

De pagina stuurt een bestand naar POST /api/extract; dit module haalt de tekst eruit:
- pdf (tot 200 pagina's), Word (.docx), OpenDocument (.odt), Excel (.xlsx), PowerPoint (.pptx), rtf, html,
  tekst, markdown, csv, json en e-mail (.eml);
- ondertitels (.srt, .vtt): tijden, nummers en herhaalde regels eruit, zodat er een leesbaar transcript overblijft;
- afbeeldingen (jpg, png): Grok leest de tekst en cijfers uit de afbeelding (screenshot, grafiek, tweet, melding).
Het bestand zelf wordt niet bewaard: de tekst gaat terug naar de pagina en komt pas in de inbox als jij op
'Analyseer' of 'Alleen bewaren' klikt.
"""
import email
import email.policy
import io
import re
import zipfile

from . import ai, mail

MAX_BYTES = 20 * 1024 * 1024       # per bestand
MAX_PAGES = 200                    # pdf
MAX_CHARS = 400_000                # wat er maximaal terug naar de pagina gaat
MAX_UNZIPPED = 60 * 1024 * 1024    # beveiliging tegen 'zipbommen' in docx/xlsx/pptx/odt

IMAGE_PROMPT = """Floris zet deze afbeelding in de inbox van zijn beleggingsplan (bijvoorbeeld een screenshot van een grafiek,
een tweet, een nieuwsbericht, een melding of een tabel). Schrijf ALLE leesbare tekst en cijfers letterlijk over, in de
volgorde waarin ze op de afbeelding staan. Staat er (ook) een grafiek op, beschrijf daarna in hooguit 5 regels wat je
ziet: instrument, periode, belangrijke niveaus en de richting. Verzin niets wat niet op de afbeelding staat.
Antwoord in platte tekst, zonder inleiding of slotzin."""


class ExtractError(Exception):
    """Een nette foutmelding voor de pagina."""


def _zip_member(z, name):
    try:
        info = z.getinfo(name)
    except KeyError:
        return ""
    if info.file_size > MAX_UNZIPPED:
        raise ExtractError("Dit document is uitgepakt te groot om te lezen.")
    return mail._strip_html(z.read(name).decode("utf-8", "replace")
                            .replace("</w:p>", "\n").replace("</a:p>", "\n").replace("</text:p>", "\n").replace("</text:h>", "\n"))


def _office(data, members):
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            names = z.namelist()
            if sum(z.getinfo(n).file_size for n in names) > MAX_UNZIPPED * 2:
                raise ExtractError("Dit document is uitgepakt te groot om te lezen.")
            return "\n".join(t for t in (_zip_member(z, n) for n in members(names)) if t).strip()
    except zipfile.BadZipFile:
        raise ExtractError("Dit bestand is beschadigd of geen echt Office-document.")


def _pdf(data):
    from pypdf import PdfReader
    try:
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted:
            try:
                reader.decrypt("")
            except Exception:
                raise ExtractError("Deze pdf is beveiligd met een wachtwoord.")
        pages = len(reader.pages)
    except ExtractError:
        raise
    except Exception:
        raise ExtractError("Deze pdf kon niet worden geopend; misschien is hij beschadigd.")
    parts = []
    for page in reader.pages[:MAX_PAGES]:
        try:
            parts.append(page.extract_text() or "")
        except Exception:  # één kapotte pagina mag de rest niet tegenhouden
            continue
    text = re.sub(r"[ \t]+\n", "\n", "\n\n".join(p.strip() for p in parts if p.strip())).strip()
    if not text:
        raise ExtractError("Deze pdf bevat geen leesbare tekst; waarschijnlijk is hij gescand. Maak er een screenshot "
                           "van (JPG of PNG), dan leest Grok de tekst.")
    note = f"alleen de eerste {MAX_PAGES} van {pages} pagina's" if pages > MAX_PAGES else ""
    return text, pages, note


TIME_RE = re.compile(r"^\s*(\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}\s*-->\s*(\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}.*$")


def subtitles(raw):
    """Ondertitels (.srt/.vtt) naar lopende tekst: zonder nummers, tijden, opmaak en herhaalde regels."""
    out = []
    for line in raw.replace("\r", "").split("\n"):
        s = line.strip()
        if not s or s.isdigit() or TIME_RE.match(s) or s.upper().startswith(("WEBVTT", "NOTE", "STYLE", "REGION", "KIND:", "LANGUAGE:")):
            continue
        s = re.sub(r"<\d{1,2}:\d{2}[:.\d]*>", "", s)          # tijdcodes per woord (YouTube)
        s = re.sub(r"</?[a-zA-Z][^>]*>|\{\\[^}]*\}", "", s)    # <c>, <i>, <v Spreker>, {\an8}
        s = re.sub(r"\s+", " ", s).strip()
        if s and s not in out[-3:]:                              # automatische ondertitels herhalen regels
            out.append(s)
    return re.sub(r"\s+([,.!?])", r"\1", " ".join(out)).strip()


def _rtf(raw):
    s = re.sub(r"\{\\(fonttbl|colortbl|stylesheet|info|listtable|listoverridetable|rsidtbl|generator)[^{}]*(\{[^{}]*\}[^{}]*)*\}", "", raw)
    s = re.sub(r"\{\\\*[^{}]*\}", "", s)                       # verborgen groepen
    s = re.sub(r"\\'([0-9a-fA-F]{2})", lambda m: bytes.fromhex(m.group(1)).decode("cp1252", "replace"), s)
    s = re.sub(r"\\(par|line)\b ?", "\n", s)
    s = re.sub(r"\\[a-zA-Z]+-?\d* ?", "", s)
    s = s.replace("{", "").replace("}", "").replace("\\\\", "\\")
    return re.sub(r"\n\s*\n+", "\n\n", s).strip()


def _eml(data):
    msg = email.message_from_bytes(data, policy=email.policy.default)
    head = "\n".join(f"{k}: {msg.get(k)}" for k in ("From", "To", "Date", "Subject") if msg.get(k))
    body = mail._body_text(msg)
    files = [f for f, _, _ in mail._attachments(msg)]
    return (head + "\n\n" + body + (f"\n\nBijlagen: {', '.join(files)}" if files else "")).strip()


def _image(data, mime):
    if not ai.provider():
        raise ExtractError("Een afbeelding lezen kan alleen met een AI-sleutel (XAI_API_KEY in Railway).")
    try:
        raw, _ = ai.complete(IMAGE_PROMPT, images=[(mime, data)], tier="default", max_tokens=3000, timeout=150)
    except ai.AIError as e:
        raise ExtractError(f"Grok kon de afbeelding niet lezen: {e}") from e
    text = (raw or "").strip()
    if not text:
        raise ExtractError("Grok vond geen tekst of grafiek in deze afbeelding.")
    return text


def _kind(name, ctype):
    n, c = (name or "").lower(), (ctype or "").lower()
    if n.endswith(".pdf") or c == "application/pdf":
        return "pdf"
    for ext, kind in ((".docx", "word"), (".odt", "odt"), (".xlsx", "excel"), (".pptx", "powerpoint"), (".rtf", "rtf"),
                      (".srt", "ondertitels"), (".vtt", "ondertitels"), (".eml", "e-mail"), (".html", "html"), (".htm", "html")):
        if n.endswith(ext):
            return kind
    if n.endswith((".jpg", ".jpeg", ".png")) or c in ("image/jpeg", "image/jpg", "image/png"):
        return "afbeelding"
    if n.endswith((".txt", ".md", ".csv", ".tsv", ".json", ".xml", ".log")) or c.startswith("text/"):
        return "tekst"
    if n.endswith(".doc"):
        raise ExtractError("Oud Word-formaat (.doc): sla het op als .docx of pdf en probeer het opnieuw.")
    if n.endswith((".pages", ".numbers", ".key")):
        raise ExtractError("Apple-documenten kan de site niet lezen: exporteer naar pdf of Word.")
    if n.endswith((".heic", ".heif", ".webp", ".gif", ".tif", ".tiff", ".bmp")) or c.startswith("image/"):
        raise ExtractError("Dit soort afbeelding wordt niet ondersteund: gebruik JPG of PNG (een screenshot werkt altijd).")
    raise ExtractError("Dit bestandstype wordt niet ondersteund. Gebruik pdf, Word, Excel, PowerPoint, tekst, "
                       "ondertitels (.srt/.vtt) of een afbeelding (JPG/PNG).")


LABELS = {"pdf": "pdf", "word": "Word", "odt": "OpenDocument", "excel": "Excel", "powerpoint": "PowerPoint", "rtf": "rtf",
          "ondertitels": "ondertitels", "e-mail": "e-mail", "html": "webpagina", "tekst": "tekst", "afbeelding": "afbeelding"}


def extract(name, ctype, data):
    """Geeft {name, kind, label, text, chars, words, pages?, truncated, note} of gooit ExtractError."""
    if not data:
        raise ExtractError("Het bestand is leeg.")
    if len(data) > MAX_BYTES:
        raise ExtractError("Dit bestand is groter dan 20 MB.")
    kind = _kind(name, ctype)
    pages, note = None, ""
    if kind == "pdf":
        text, pages, note = _pdf(data)
    elif kind == "word":
        text = _office(data, lambda ns: [n for n in ("word/document.xml", "word/footnotes.xml") if n in ns])
    elif kind == "odt":
        text = _office(data, lambda ns: ["content.xml"] if "content.xml" in ns else [])
    elif kind == "excel":
        text = _office(data, lambda ns: ["xl/sharedStrings.xml"] + sorted(n for n in ns if n.startswith("xl/worksheets/sheet"))[:10])
    elif kind == "powerpoint":
        def slides(ns):
            sl = [n for n in ns if re.match(r"ppt/slides/slide\d+\.xml$", n)]
            return sorted(sl, key=lambda n: int(re.search(r"(\d+)\.xml$", n).group(1)))[:80]
        text = _office(data, slides)
    elif kind == "rtf":
        text = _rtf(mail._decode(data))
    elif kind == "ondertitels":
        text = subtitles(mail._decode(data))
    elif kind == "e-mail":
        text = _eml(data)
    elif kind == "html":
        text = mail._strip_html(mail._decode(data))
    elif kind == "afbeelding":
        mime = "image/png" if (name or "").lower().endswith(".png") or (ctype or "").lower() == "image/png" else "image/jpeg"
        text = _image(data, mime)
        note = "tekst gelezen door Grok"
    else:
        text = mail._decode(data).strip()
    text = (text or "").replace("\x00", "").strip()
    if not text:
        raise ExtractError("Er stond geen leesbare tekst in dit bestand.")
    truncated = len(text) > MAX_CHARS
    text = text[:MAX_CHARS]
    out = {"name": (name or "bestand")[:160], "kind": kind, "label": LABELS.get(kind, kind), "text": text,
           "chars": len(text), "words": len(text.split()), "truncated": truncated, "note": note}
    if pages:
        out["pages"] = pages
    return out
