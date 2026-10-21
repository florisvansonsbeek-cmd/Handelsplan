"""Werkt een bestaande database bij met nieuwe onderdelen: python -m scripts.migrate
Je eigen wijzigingen blijven staan; alleen ontbrekende onderdelen worden toegevoegd."""
from app import db, patch

plan = db.get_doc("plan/current")
market = db.get_doc("market/latest")
plan, market, notes = patch.apply(plan, market)
if plan is not None:
    db.set_doc("plan/current", plan)
if market is not None:
    db.set_doc("market/latest", market)
print("Bijgewerkt:" if notes else "Niets bij te werken.", "; ".join(notes))
