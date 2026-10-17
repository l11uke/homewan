"""Write the host facts the report and daily check need (they run in a
container that cannot see the Pi's drives by filesystem ID).

hoststate.py OUT_JSON DISK_EXPECTED MGMT_IFACE CAPTURE_IFACE [FIXTURES]
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))


def links(fixtures):
    """Link speed and USB bus speed per interface, from netinfo.py."""
    out = subprocess.run([sys.executable, "-I", os.path.join(HERE, "netinfo.py")] + ([fixtures] if fixtures else []),
                         capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) >= 9:
            num = lambda v: int(v) if v.isdigit() else None
            found[p[0]] = (num(p[7]), num(p[8]))
    return found


def pi_model(fixtures):
    path = os.path.join(fixtures, "model") if fixtures else "/proc/device-tree/model"
    try:
        with open(path, "rb") as f:
            return f.read().replace(b"\0", b"").decode(errors="replace").strip() or None
    except OSError:
        return None


def main():
    out, expected, mgmt, capture = sys.argv[1:5]
    fixtures = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
    fs = subprocess.run([sys.executable, "-I", os.path.join(HERE, "fsinfo.py")] + ([fixtures] if fixtures else []),
                        capture_output=True, text=True).stdout
    mounted = {}
    for line in fs.splitlines():
        p = line.split("\t")
        if len(p) >= 8:
            mounted[p[0]] = {"fstype": p[1], "size_gb": int(float(p[3])), "uuid": p[7]}
    drives, wanted = [], set()
    for e in [x for x in expected.split(",") if x]:
        m, _, u = e.partition("=")
        wanted.add(m)
        actual = mounted.get(m, {}).get("uuid")
        status = "missing" if not actual else ("ok" if actual.upper() == u.upper() else "different")
        drives.append({"mount": m, "expected_uuid": u, "actual_uuid": actual, "status": status})
    new = []
    if wanted:
        new = [{"mount": m, "fstype": v["fstype"], "size_gb": v["size_gb"]}
               for m, v in sorted(mounted.items()) if m != "/" and m not in wanted]
    ln = links(fixtures)
    m_link, m_usb = ln.get(mgmt, (None, None))
    c_link, c_usb = ln.get(capture, (None, None)) if capture else (None, None)
    state = {"written": datetime.now(timezone.utc).isoformat(), "drives": drives, "new_drives": new,
             "mgmt_iface": mgmt, "mgmt_link_mbps": m_link, "mgmt_usb_mbps": m_usb,
             "capture_iface": capture, "capture_link_mbps": c_link, "capture_usb_mbps": c_usb,
             "pi_model": pi_model(fixtures)}
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out + ".tmp", "w") as f:
        json.dump(state, f, indent=1)
    os.replace(out + ".tmp", out)


if __name__ == "__main__":
    main()
