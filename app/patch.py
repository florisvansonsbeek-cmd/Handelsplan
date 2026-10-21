"""Voegt nieuwe onderdelen (macro-overzicht, extra triggers en cijfers) toe aan een bestaand plan,
zonder iets te overschrijven wat je zelf al hebt aangepast."""
import copy
import json
from pathlib import Path

PATCH_FILE = Path(__file__).resolve().parent.parent / "seed" / "macro_patch.json"


def load_patch():
    return json.loads(PATCH_FILE.read_text(encoding="utf-8"))


def apply(plan: dict | None, market: dict | None, patch: dict | None = None):
    patch = patch or load_patch()
    notes = []
    if plan is not None:
        if "macro" not in plan:
            plan["macro"] = copy.deepcopy(patch["macro"])
            notes.append("macro-overzicht toegevoegd")
        elif "cycle" not in plan["macro"] and "cycle" in patch["macro"]:
            plan["macro"]["cycle"] = copy.deepcopy(patch["macro"]["cycle"])
            notes.append("cyclus-analyse toegevoegd")
        trig = plan.setdefault("triggers", [])
        have = {t.get("id") for t in trig}
        for t in patch.get("triggersAdd", []):
            if t["id"] not in have:
                trig.append(copy.deepcopy(t))
                notes.append(f"trigger {t['id']} toegevoegd")
        for t in trig:
            p = patch.get("triggerPatch", {}).get(t.get("id"))
            if not p:
                continue
            for k, v in p.items():
                if k == "unit":
                    if t.get("unit") == "k" and v == "Δk":
                        t["unit"] = v
                elif not t.get(k):
                    t[k] = v
        srcs = plan.setdefault("sources", [])
        urls = {s.get("url") for s in srcs}
        for s in patch.get("sourcesAdd", []):
            if s["url"] not in urls:
                srcs.append(s)
    if market is not None:
        items = market.setdefault("items", [])
        keys = {i.get("key") for i in items}
        for it in patch.get("itemsAdd", []):
            if it["key"] not in keys:
                items.append(copy.deepcopy(it))
                notes.append(f"cijfer {it['key']} toegevoegd")
        for it in items:
            pil = patch.get("itemPillars", {}).get(it.get("key"))
            if pil and not it.get("pillar"):
                it["pillar"] = pil
    return plan, market, notes
