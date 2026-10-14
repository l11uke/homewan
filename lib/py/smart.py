"""Check whether a drive reports SMART health through smartctl.

smart.py DEVICE -> one line: ok<TAB>type<TAB>health<TAB>temperature C (or -)
                   or: none<TAB>reason
Tries smartctl's automatic device type first, then SAT, which most USB
hard drive adapters need. In test mode, reads smartctl-NAME.json fixtures.
"""
import json
import os
import subprocess
import sys


def query(dev, dtype):
    fx = os.environ.get("HOMEWAN_FIXTURES")
    if os.environ.get("HOMEWAN_TEST") == "1" and fx:
        path = os.path.join(fx, f"smartctl-{os.path.basename(dev)}-{dtype}.json")
        if not os.path.exists(path):
            return {}
        with open(path) as f:
            return json.load(f)
    r = subprocess.run(["smartctl", "-j", "-i", "-H", "-A", "-d", dtype, dev],
                       capture_output=True, text=True, timeout=60)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {}


def main():
    dev = sys.argv[1]
    reason = "the drive or its USB adapter does not pass SMART through"
    for dtype in ("auto", "sat"):
        d = query(dev, dtype)
        if not d:
            continue
        status = d.get("smart_status")
        if d.get("smart_support", {}).get("available") is False:
            reason = "the drive has no SMART support"
            continue
        if status is None:
            continue
        health = "passed" if status.get("passed") else "FAILING"
        temp = d.get("temperature", {}).get("current")
        print(f"ok\t{dtype}\t{health}\t{temp if temp is not None else '-'}")
        return
    print(f"none\t{reason}")


if __name__ == "__main__":
    main()
