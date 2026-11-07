"""Planregels per positie toetsen aan de cijfers (dezelfde logica als 'Wat moet ik doen?' op de site).

Een positie heeft `checks`: [{id, key, op: 'lt'|'gt', level, near, action, tone, label, then}].
Een check die je op de site als 'gedaan' hebt gemarkeerd (positie.done[check-id]) telt niet meer mee,
totdat de koers duidelijk terug is (voorbij de 'near'-grens, of 3% terug als die er niet is). Dan staat
de regel weer scherp. Zo krijg je geen tweede melding als een koers rond het niveau heen en weer gaat.
"""
RANK = {"bad": 3, "warn": 2, "good": 1}


def check_id(pos, i, c):
    return c.get("id") or f"{pos.get('id')}-{i}"


def evaluate(plan, items):
    """Geeft per positie: label, toon, uitleg en de check die het dichtst bij is of geraakt is."""
    vals = {k: (v.get("value") if isinstance(v, dict) else v) for k, v in (items or {}).items()}
    out = []
    for pos in plan.get("positions", []) or []:
        done = pos.get("done") or {}
        best = None
        for i, c in enumerate(pos.get("checks") or []):
            cid = check_id(pos, i, c)
            v = vals.get(c.get("key"))
            if not isinstance(v, (int, float)) or not isinstance(c.get("level"), (int, float)):
                continue
            if cid in done:  # gedaan/gezien: telt pas weer mee als reset_done hem weer scherp zet
                continue
            hit = v < c["level"] if c.get("op") == "lt" else v > c["level"]
            near = (c.get("near") is not None and not hit and (v < c["near"] if c.get("op") == "lt" else v > c["near"]))
            dist = abs((v - c["level"]) / c["level"]) * 100 if c["level"] else None
            cand = {"id": cid, "check": c, "value": v, "hit": hit, "near": near, "dist": dist}
            if hit:
                if not best or not best["hit"] or RANK.get(c.get("tone"), 0) > RANK.get(best["check"].get("tone"), 0):
                    best = cand
            elif not best or not best["hit"]:
                if near and (not best or not best["near"]):
                    best = cand
                elif not best or (not best["near"] and dist is not None and best["dist"] is not None and dist < best["dist"]):
                    best = cand
        st = {"id": pos.get("id"), "name": pos.get("short") or pos.get("name"), "label": pos.get("doLabel") or "Houden",
              "tone": "base", "why": pos.get("doNow") or pos.get("stanceNote") or "", "next": best}
        if best and best["hit"]:
            st.update(label=best["check"].get("action", ""), tone=best["check"].get("tone", "warn"),
                      why=best["check"].get("then") or st["why"])
        elif best and best["near"]:
            st.update(label="Let op", tone="warn")
        out.append(st)
    return out


def _val(items, key):
    v = (items or {}).get(key)
    v = v.get("value") if isinstance(v, dict) else v
    return v if isinstance(v, (int, float)) else None


def recovered(c, v):
    """Is de koers zo ver terug dat een eerder geraakte regel weer scherp mag staan?"""
    lvl = c.get("level")
    if not isinstance(v, (int, float)) or not isinstance(lvl, (int, float)):
        return False
    lt = c.get("op") == "lt"
    reset = c.get("near") if isinstance(c.get("near"), (int, float)) else lvl * (1.03 if lt else 0.97)
    return v > reset if lt else v < reset


def checks_by_id(plan):
    out = {}
    for pos in plan.get("positions", []) or []:
        for i, c in enumerate(pos.get("checks") or []):
            out[check_id(pos, i, c)] = (pos, c)
    return out


def reset_done(plan, items):
    """Haalt 'gedaan' weg bij regels waarvan de koers duidelijk terug is. Geeft True als er iets veranderde."""
    changed = False
    by_id = checks_by_id(plan)
    for pos in plan.get("positions", []) or []:
        done = pos.get("done")
        if not isinstance(done, dict):
            continue
        for cid in list(done):
            pc = by_id.get(cid)
            if pc is None:  # regel bestaat niet meer
                del done[cid]
                changed = True
                continue
            if recovered(pc[1], _val(items, pc[1].get("key"))):
                del done[cid]
                changed = True
    return changed
