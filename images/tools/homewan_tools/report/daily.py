"""The daily check: emails as soon as something needs attention, once per event.

Events (SPEC 8.5):
  drives (DISK_WARNINGS=yes): an expected drive goes missing or is replaced,
      and when it comes back; a drive's health turns failing, or its
      reallocated or pending sector count rises.
  data cap (CAP_WARNINGS=yes): usage passes 80% or 100% of an allowance, or
      the 7-day projection passes it before the reset. Once per period.

State lives in /state/daily.json so a warning is never sent twice.
"""
import json
import os
from datetime import datetime, timedelta, timezone

from . import drives, mail
from .settings import Settings

STATE_DIR = os.environ.get("HOMEWAN_STATE", "/state")


def load_state():
    try:
        with open(os.path.join(STATE_DIR, "daily.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    path = os.path.join(STATE_DIR, "daily.json")
    with open(path + ".tmp", "w") as f:
        json.dump(state, f, indent=1)
    os.replace(path + ".tmp", path)


def drive_events(host, state):
    events = []
    seen = state.setdefault("drives", {})
    for d in host.get("drives", []):
        m, status = d["mount"], d.get("status", "ok")
        before = seen.get(m, "ok")
        if status != "ok" and before == "ok":
            what = "is missing: nothing is mounted there" if status == "missing" else "has a different drive mounted"
            events.append(f"Drive {m} {what}. Programs that store files there may be failing.")
        elif status == "ok" and before != "ok":
            events.append(f"Drive {m} is back.")
        seen[m] = status
    return events


def smart_events(rows, state):
    events = []
    seen = state.setdefault("smart", {})
    for d in rows:
        key = d["drive"]
        prev = seen.get(key, {})
        name = d.get("model") or key
        failing = d.get("passed") in (False, "false", 0)
        if failing and not prev.get("failing"):
            events.append(f"Drive {name} reports that it is FAILING. Copy its data somewhere safe now.")
        for k, label in (("reallocated", "reallocated"), ("pending", "pending")):
            now_v, before = int(d.get(k) or 0), prev.get(k)
            if before is not None and now_v > before:
                events.append(f"Drive {name}: {label} sectors rose from {before} to {now_v}. That is an early sign of failure.")
        seen[key] = {"failing": failing, "reallocated": int(d.get("reallocated") or 0), "pending": int(d.get("pending") or 0)}
    return events


def cap_events(status, state, s):
    events = []
    c = state.setdefault("cap", {})
    period = status["start"].isoformat()
    if c.get("period") != period:
        c.clear()
        c["period"] = period
    sent = set(c.get("sent", []))
    from .weekly import OVER
    for r in status["rows"]:
        tag = r.name.lower()
        if r.percent >= 100 and f"{tag}100" not in sent:
            events.append(f"Data cap: {r.name} usage has reached {r.percent:.0f}% ({r.used_gb:.0f} of {r.allowance_gb:.0f} GB). "
                          f"From now on {OVER.get(s.get('CAP_OVER_ACTION'), 'your plan limits apply')}.")
            sent.update({f"{tag}100", f"{tag}80", f"{tag}proj"})
        elif r.percent >= 80 and f"{tag}80" not in sent:
            events.append(f"Data cap: {r.name} usage has passed 80% ({r.used_gb:.0f} of {r.allowance_gb:.0f} GB), "
                          f"with {status['days_left']:.0f} days to the reset.")
            sent.add(f"{tag}80")
        if r.projected_gb > r.allowance_gb and f"{tag}proj" not in sent and r.percent < 100:
            events.append(f"Data cap: at the last 7 days' rate, {r.name.lower()} usage will reach {r.projected_gb:.0f} GB "
                          f"({r.projected_percent:.0f}%) before the reset in {status['days_left']:.0f} days.")
            sent.add(f"{tag}proj")
    c["sent"] = sorted(sent)
    return events


def main(args):
    s = Settings()
    dry = "--dry-run" in args
    state = load_state()
    events = []
    now = datetime.now(timezone.utc)
    source = None
    try:
        if s.get("DISK_WARNINGS") == "yes":
            events += drive_events(drives.host_state(), state)
            if s.smart_devices:
                from .queries import Source
                source = source or Source(s)
                events += smart_events(drives.smart_table(*source.smart_latest(now - timedelta(days=2), now)), state)
        if s.get("CAP_WARNINGS") == "yes" and s.cap_enabled and s.has("capture"):
            from .queries import Source
            from .weekly import cap_status
            source = source or Source(s)
            events += cap_events(cap_status(source, s, now), state, s)
    finally:
        if source:
            source.close()
    if not events:
        if not dry:
            save_state(state)
        print("OK: nothing needs attention")
        return 0
    subject = "homewan: " + (events[0] if len(events) == 1 else f"{len(events)} things need attention")
    subject = subject if len(subject) < 120 else subject[:117] + "..."
    text = "\n\n".join(events) + "\n\nThis warning is sent once. Check details with: sudo homewan doctor\n"
    body = "<html><body style='font-family:sans-serif'>" + "".join(f"<p>{e}</p>" for e in events) + \
           "<p style='color:#666;font-size:12px'>This warning is sent once. Check details with: sudo homewan doctor</p></body></html>"
    msg = mail.build(s, subject, text, body)
    if dry:
        print(f"Would send: {subject}\n\n{text}")
        return 0
    mail.send(s, msg)
    save_state(state)
    print(f"OK: sent warning: {subject}")
    return 0
