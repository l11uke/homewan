"""Read drive health with smartctl and store it in the "system" bucket.

SMART_DEVICES (from site.conf) lists NAME:TYPE pairs, where NAME is a
/dev/disk/by-id entry (or a /dev name) and TYPE a smartctl device type.
Measurement "smart", tag "drive" = NAME. Fields: passed (true/false),
temperature (C), power_on_hours, reallocated, pending, uncorrectable,
crc_errors (raw counts from the matching ATA attributes, when present).
"""
import json
import os
import subprocess
import sys
import time

from . import influx

ATTRS = {5: "reallocated", 197: "pending", 198: "uncorrectable", 199: "crc_errors"}


def device_path(name):
    """The homewan command passes the drives into the container and maps
    each name to its device node in SMART_DEVICE_PATHS (name=/dev/sdX,...)."""
    for pair in os.environ.get("SMART_DEVICE_PATHS", "").split(","):
        n, _, path = pair.partition("=")
        if n == name and path:
            return path
    by_id = f"/dev/disk/by-id/{name}"
    return by_id if os.path.exists(by_id) else f"/dev/{name}"


def parse(data):
    fields = {}
    status = data.get("smart_status")
    if status is not None:
        fields["passed"] = bool(status.get("passed"))
    temp = data.get("temperature", {}).get("current")
    if temp is not None:
        fields["temperature"] = float(temp)
    hours = data.get("power_on_time", {}).get("hours")
    if hours is not None:
        fields["power_on_hours"] = int(hours)
    for a in data.get("ata_smart_attributes", {}).get("table", []):
        name = ATTRS.get(a.get("id"))
        if name:
            fields[name] = int(a.get("raw", {}).get("value", 0))
    nvme = data.get("nvme_smart_health_information_log")
    if nvme:
        fields["uncorrectable"] = int(nvme.get("media_errors", 0))
    return fields


def main(args):
    dry = "--dry-run" in args
    devices = [d for d in os.environ.get("SMART_DEVICES", "").split(",") if d]
    if not devices:
        print("No drives selected for health checks (SMART_DEVICES is empty).")
        return 0
    lines, problems = [], []
    now = time.time()
    for dev in devices:
        name, _, dtype = dev.rpartition(":")
        if not name:
            name, dtype = dtype, "auto"
        r = subprocess.run(["smartctl", "-j", "-a", "-d", dtype, device_path(name)],
                           capture_output=True, text=True, timeout=120)
        try:
            data = json.loads(r.stdout or "{}")
        except ValueError:
            data = {}
        fields = parse(data)
        if not fields:
            problems.append(f"{name}: no SMART data (smartctl exit {r.returncode})")
            continue
        model = data.get("model_name") or data.get("model_family")
        lines.append(influx.line("smart", {"drive": name, "model": model}, fields, ts=now))
    if dry:
        print("\n".join(lines))
    elif lines:
        influx.write("system", lines, "INFLUX_TOKEN_SYSTEM")
    for p in problems:
        print(f"WARNING: {p}", file=sys.stderr)
    print(f"OK: {len(lines)} drive(s) read" + (f", {len(problems)} without data" if problems else ""))
    return 1 if problems and not lines else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
