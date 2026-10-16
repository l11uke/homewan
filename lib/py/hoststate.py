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


def link_speed(iface, fixtures):
    if not iface:
        return None
    if fixtures:
        path = os.path.join(fixtures, "speed.txt")
        if os.path.exists(path):
            for line in open(path):
                p = line.split()
                if len(p) == 2 and p[0] == iface and p[1].isdigit():
                    return int(p[1])
        return None
    try:
        v = open(f"/sys/class/net/{iface}/speed").read().strip()
        return int(v) if v.isdigit() and int(v) > 0 else None
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
    state = {"written": datetime.now(timezone.utc).isoformat(), "drives": drives, "new_drives": new,
             "mgmt_iface": mgmt, "mgmt_link_mbps": link_speed(mgmt, fixtures),
             "capture_iface": capture, "capture_link_mbps": link_speed(capture, fixtures)}
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out + ".tmp", "w") as f:
        json.dump(state, f, indent=1)
    os.replace(out + ".tmp", out)


if __name__ == "__main__":
    main()
