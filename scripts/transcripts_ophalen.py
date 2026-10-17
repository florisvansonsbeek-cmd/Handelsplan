#!/usr/bin/env python3
"""
transcripts_ophalen.py

Haalt de ondertitels (transcripts) van de nieuwste video's van je YouTube-kanalen op
en zet ze als .txt-bestand in een map. Die bestanden plak je in de Inbox van je
Handelsplan, of je laat een geplande Claude-taak de map uitlezen en verwerken.

Eenmalig installeren:   pip install -U yt-dlp
Draaien:                python transcripts_ophalen.py

Tip: laat dit dagelijks draaien met Taakplanner (Windows) of cron/launchd (Mac).
Werk yt-dlp af en toe bij (pip install -U yt-dlp): YouTube verandert regelmatig.
"""
import html
import json
import re
import urllib.request
import sys
from datetime import datetime
from pathlib import Path

try:
    import yt_dlp
except ImportError:
    sys.exit("yt-dlp ontbreekt. Installeer het met:  pip install -U yt-dlp")

# ------------------------------------------------------------------
# INSTELLINGEN: vul hier de kanaallinks in (tabblad 'Video's' van het kanaal)
# ------------------------------------------------------------------
KANALEN = {
    # "Naam zoals in je inbox": "https://www.youtube.com/@kanaalnaam/videos",
    "Rebel Capitalist": "https://www.youtube.com/@VUL-IN/videos",
    "TradersReality": "https://www.youtube.com/@VUL-IN/videos",
    "Eigen video": "https://www.youtube.com/@VUL-IN/videos",
}
AANTAL_NIEUWSTE = 3            # hoeveel recente video's per kanaal controleren
TALEN = ["en", "nl"]           # voorkeursvolgorde van ondertiteltalen
MAP = Path.home() / "Handelsplan" / "transcripts"
# Automatisch doorsturen naar je site (laat leeg om alleen bestanden te maken)
SERVER_URL = "https://plan.vsonsbeek.nl/api/inbox"
INBOX_TOKEN = ""  # dezelfde waarde als de variabele INBOX_TOKEN in Railway
# ------------------------------------------------------------------

STATUSBESTAND = MAP / ".al_opgehaald.json"


def schone_naam(s: str) -> str:
    return re.sub(r'[\\/:*?"<>|\n\r\t]+', "", s).strip()[:80] or "video"


def vtt_naar_tekst(vtt: str) -> str:
    """Zet WebVTT-ondertitels om naar lopende tekst zonder tijdcodes en dubbele regels."""
    regels, vorige = [], ""
    for r in vtt.splitlines():
        r = r.strip()
        if (not r or r == "WEBVTT" or "-->" in r or r.isdigit()
                or r.startswith(("Kind:", "Language:", "NOTE", "STYLE"))):
            continue
        r = html.unescape(re.sub(r"<[^>]+>", "", r)).strip()
        if r and r != vorige:          # automatische ondertitels herhalen regels
            regels.append(r)
            vorige = r
    return re.sub(r"\s+", " ", " ".join(regels)).strip()


def nieuwste_videos(kanaal_url: str, n: int):
    opties = {"quiet": True, "no_warnings": True, "extract_flat": True, "playlistend": n}
    with yt_dlp.YoutubeDL(opties) as ydl:
        info = ydl.extract_info(kanaal_url, download=False)
    return [(e["id"], e.get("title") or e["id"]) for e in (info.get("entries") or []) if e.get("id")]


def kies_ondertitel(info: dict):
    """Eerst handgemaakte ondertitels, dan automatische; in de volgorde van TALEN."""
    for soort in ("subtitles", "automatic_captions"):
        subs = info.get(soort) or {}
        for taal in TALEN:
            for sleutel, formaten in subs.items():
                if sleutel == taal or sleutel.startswith(taal + "-"):
                    for f in formaten:
                        if f.get("ext") == "vtt" and f.get("url"):
                            return f["url"], sleutel
    return None, None


def haal_transcript(video_id: str):
    url = f"https://www.youtube.com/watch?v={video_id}"
    with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True}) as ydl:
        info = ydl.extract_info(url, download=False)
        sub_url, taal = kies_ondertitel(info)
        if not sub_url:
            return info, None, None
        vtt = ydl.urlopen(sub_url).read().decode("utf-8", "replace")
    return info, vtt_naar_tekst(vtt), taal


def main():
    MAP.mkdir(parents=True, exist_ok=True)
    try:
        gezien = json.loads(STATUSBESTAND.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        gezien = {}

    nieuw = 0
    for bron, kanaal_url in KANALEN.items():
        if "VUL-IN" in kanaal_url:
            print(f"- {bron}: nog geen kanaallink ingevuld, overgeslagen.")
            continue
        try:
            videos = nieuwste_videos(kanaal_url, AANTAL_NIEUWSTE)
        except Exception as e:  # netwerk, verkeerde link, YouTube-wijziging
            print(f"- {bron}: kanaal niet op te halen ({e}).")
            continue

        for video_id, titel in videos:
            if video_id in gezien:
                continue
            try:
                info, tekst, taal = haal_transcript(video_id)
            except Exception as e:
                print(f"- {bron}: '{titel}' overgeslagen ({e}).")
                continue
            if not tekst:
                print(f"- {bron}: '{titel}' heeft nog geen ondertitels; volgende keer opnieuw.")
                continue

            ud = info.get("upload_date") or datetime.now().strftime("%Y%m%d")
            datum = f"{ud[:4]}-{ud[4:6]}-{ud[6:]}"
            bestand = MAP / f"{datum}_{schone_naam(bron)}_{schone_naam(titel)}.txt"
            kop = (f"Bron: {bron}\nTitel: {titel}\nLink: https://www.youtube.com/watch?v={video_id}\n"
                   f"Datum: {datum}\nOndertiteltaal: {taal}\n---\n")
            bestand.write_text(kop + tekst + "\n", encoding="utf-8")
            gezien[video_id] = {"bron": bron, "titel": titel, "datum": datum, "bestand": bestand.name,
                                "opgehaald": datetime.now().isoformat(timespec="seconds")}
            if SERVER_URL and INBOX_TOKEN:
                try:
                    req = urllib.request.Request(SERVER_URL, method="POST", data=json.dumps(
                        {"source": bron, "title": titel, "url": f"https://www.youtube.com/watch?v={video_id}",
                         "date": datum, "text": tekst}).encode(), headers={
                        "Content-Type": "application/json", "Authorization": f"Bearer {INBOX_TOKEN}"})
                    urllib.request.urlopen(req, timeout=30)
                    print("  -> naar je inbox gestuurd")
                except Exception as e:
                    print(f"  -> doorsturen mislukt ({e}); bestand staat wel in de map")
            nieuw += 1
            print(f"+ {bron}: {titel}  ({len(tekst.split())} woorden)")

    STATUSBESTAND.write_text(json.dumps(gezien, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nKlaar: {nieuw} nieuw transcript(s) in {MAP}")


if __name__ == "__main__":
    main()
