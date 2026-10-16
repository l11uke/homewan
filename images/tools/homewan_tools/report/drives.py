"""Drive status from the host, and drive health (SMART) from the database.

The homewan command writes /state/host.json on the Pi before each report or
daily check, because the container cannot see the Pi's mounts by filesystem ID:
{"drives": [{"mount", "expected_uuid", "actual_uuid", "status": ok|missing|different}],
 "new_drives": [{"mount", "fstype", "size_gb"}],
 "mgmt_iface", "mgmt_link_mbps", "capture_iface", "capture_link_mbps"}
"""
import json
import os

STATE_DIR = os.environ.get("HOMEWAN_STATE", "/state")


def host_state():
    try:
        with open(os.path.join(STATE_DIR, "host.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def smart_table(last, first):
    """One dict per drive: model, passed, temperature, hours and the counts
    that matter, with how much each count rose during the window."""
    rows = {}
    if last is None or last.empty:
        return []
    for r in last.to_dict("records"):
        d = rows.setdefault(r["drive"], {"drive": r["drive"], "model": r.get("model")})
        d[r["_field"]] = r["_value"]
    if first is not None and not first.empty:
        for r in first.to_dict("records"):
            if r["drive"] in rows:
                rows[r["drive"]]["first_" + r["_field"]] = r["_value"]
    out = []
    for d in rows.values():
        for k in ("reallocated", "pending", "uncorrectable", "crc_errors"):
            if k in d and ("first_" + k) in d:
                d[k + "_rise"] = max(0, int(d[k]) - int(d["first_" + k]))
        d["problem"] = (d.get("passed") in (False, "false", 0)
                        or (d.get("pending") or 0) > 0 or d.get("reallocated_rise", 0) > 0
                        or d.get("uncorrectable_rise", 0) > 0)
        out.append(d)
    return sorted(out, key=lambda d: d["drive"])
