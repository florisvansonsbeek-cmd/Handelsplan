"""Zet je startplan, koersen, inbox en historie in de database: python -m scripts.seed
Bestaande documenten worden NIET overschreven (gebruik scripts.migrate om bij te werken)."""
import json
from pathlib import Path

from app import db, patch

S = Path(__file__).resolve().parent.parent / "seed"
items = {"plan/current": "plan.json", "market/latest": "market.json",
         "inbox/juli-plan": "inbox_juli.json", "history/v1-start": "history_v1.json"}
for path, fn in items.items():
    if db.get_doc(path) is None:
        data = json.loads((S / fn).read_text(encoding="utf-8"))
        if path == "plan/current":
            patch.apply(data, None)
        if path == "market/latest":
            patch.apply(None, data)
        db.set_doc(path, data)
        print("Geplaatst:", path)
    else:
        print("Bestaat al, overgeslagen:", path)
