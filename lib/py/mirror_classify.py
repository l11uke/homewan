"""Classify a mirror-port capture.

Usage: mirror_classify.py TARGET_IP LAN_SUBNET < `tcpdump -nn -e -r file` output

Prints one line: VERDICT<TAB>SOURCE<TAB>PACKETS<TAB>PPPOE
VERDICT is one of:
  NO_PACKETS  nothing arrived on the capture interface
  NO_ECHO     traffic arrived, but none of the test pings
  LAN         test pings seen with a source address inside the LAN subnet (layout B)
  WAN         test pings seen with a source address outside private ranges (layout A)
  OTHER       test pings seen with a private source address outside the LAN subnet
"""
import ipaddress
import re
import sys

RFC1918 = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]


def main():
    target, lan = sys.argv[1], ipaddress.ip_network(sys.argv[2], strict=False)
    echo = re.compile(r"(\d+\.\d+\.\d+\.\d+) > " + re.escape(target) + r": ICMP echo request")
    packets, pppoe, sources = 0, False, []
    for line in sys.stdin:
        if not line.strip():
            continue
        packets += 1
        if "PPPoE" in line:
            pppoe = True
        m = echo.search(line)
        if m:
            sources.append(m.group(1))
    if packets == 0:
        verdict, src = "NO_PACKETS", "-"
    elif not sources:
        verdict, src = "NO_ECHO", "-"
    else:
        src = max(set(sources), key=sources.count)
        ip = ipaddress.ip_address(src)
        if ip in lan:
            verdict = "LAN"
        elif any(ip in n for n in RFC1918) or ip.is_loopback or ip.is_link_local:
            verdict = "OTHER"
        else:
            # Public, carrier-grade NAT (100.64.0.0/10) or documentation ranges:
            # the router's WAN side.
            verdict = "WAN"
    print(f"{verdict}\t{src}\t{packets}\t{'yes' if pppoe else 'no'}")


if __name__ == "__main__":
    main()
