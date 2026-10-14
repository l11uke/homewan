"""List the Pi's physical network interfaces as tab-separated lines.

Columns: name, state, mac, ipv4 addresses (comma-separated CIDR or -),
default route metric (or -), kind (wired|wireless), lan subnet (or -),
link speed in Mbps (or - when unknown, as for Wi-Fi).

Reads `ip -j addr` and `ip -j route` and /sys/class/net, or the files
addr.json, route.json, sysnet.txt and speed.txt ("name mbps" lines) from a
fixture directory.
"""
import ipaddress
import json
import os
import subprocess
import sys


def load(fixtures):
    if fixtures:
        with open(os.path.join(fixtures, "addr.json")) as f:
            addrs = json.load(f)
        with open(os.path.join(fixtures, "route.json")) as f:
            routes = json.load(f)
        sysnet = {}
        with open(os.path.join(fixtures, "sysnet.txt")) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3:
                    sysnet[parts[0]] = (parts[1] == "physical", parts[2] == "wireless")
        speeds = {}
        path = os.path.join(fixtures, "speed.txt")
        if os.path.exists(path):
            with open(path) as f:
                for line in f:
                    parts = line.split()
                    if len(parts) == 2:
                        speeds[parts[0]] = parts[1]
        return addrs, routes, sysnet, speeds
    addrs = json.loads(subprocess.run(["ip", "-j", "addr"], capture_output=True, text=True).stdout or "[]")
    routes = json.loads(subprocess.run(["ip", "-j", "route"], capture_output=True, text=True).stdout or "[]")
    sysnet = {}
    for a in addrs:
        name = a.get("ifname", "")
        base = os.path.join("/sys/class/net", name)
        sysnet[name] = (os.path.exists(os.path.join(base, "device")),
                        os.path.exists(os.path.join(base, "wireless")))
    speeds = {}
    for name in sysnet:
        try:
            with open(os.path.join("/sys/class/net", name, "speed")) as f:
                v = f.read().strip()
            if v.isdigit() and int(v) > 0:
                speeds[name] = v
        except OSError:
            pass
    return addrs, routes, sysnet, speeds


def main():
    fixtures = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
    addrs, routes, sysnet, speeds = load(fixtures)
    metrics = {}
    for r in routes:
        if r.get("dst") == "default" and r.get("dev"):
            m = r.get("metric", 0)
            metrics[r["dev"]] = min(m, metrics.get(r["dev"], m))
    for a in addrs:
        name = a.get("ifname", "")
        physical, wireless = sysnet.get(name, (False, False))
        if not physical:
            continue
        v4 = [f'{i["local"]}/{i["prefixlen"]}' for i in a.get("addr_info", []) if i.get("family") == "inet"]
        subnet = str(ipaddress.ip_interface(v4[0]).network) if v4 else "-"
        state = a.get("operstate", "UNKNOWN")
        # USB adapters often report UNKNOWN while carrying traffic; trust the LOWER_UP flag.
        if "LOWER_UP" in a.get("flags", []) and state == "UNKNOWN":
            state = "UP"
        print("\t".join([
            name, state, a.get("address", "-"),
            ",".join(v4) or "-",
            str(metrics[name]) if name in metrics else "-",
            "wireless" if wireless else "wired",
            subnet,
            speeds.get(name, "-"),
        ]))


if __name__ == "__main__":
    main()
