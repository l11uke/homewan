"""Run Ookla's speedtest CLI and store the result in the "network" bucket.

Fields: download and upload in Mbps, ping and jitter in ms, packet_loss in %,
bytes_used (download plus upload bytes, for data cap accounting).
Tags: server (name and location), isp.
"""
import json
import subprocess
import sys
import time

from . import influx


def parse(result):
    """Turn speedtest JSON into (tags, fields)."""
    dl, ul, ping = result.get("download", {}), result.get("upload", {}), result.get("ping", {})
    server = result.get("server", {})
    tags = {
        "server": " ".join(x for x in (server.get("name"), server.get("location")) if x),
        "isp": result.get("isp"),
    }
    fields = {
        "download": round(dl.get("bandwidth", 0) * 8 / 1e6, 2),
        "upload": round(ul.get("bandwidth", 0) * 8 / 1e6, 2),
        "ping": float(ping.get("latency")) if ping.get("latency") is not None else None,
        "jitter": float(ping.get("jitter")) if ping.get("jitter") is not None else None,
        "packet_loss": float(result["packetLoss"]) if isinstance(result.get("packetLoss"), (int, float)) else None,
        "bytes_used": int(dl.get("bytes", 0)) + int(ul.get("bytes", 0)),
    }
    return tags, fields


def run_cli():
    r = subprocess.run(["speedtest", "--accept-license", "--accept-gdpr", "--format=json", "--progress=no"],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError(f"speedtest failed (exit {r.returncode}): {r.stderr.strip()[:300]}")
    # The CLI can print log lines before the JSON result.
    last = [ln for ln in r.stdout.splitlines() if ln.startswith("{")][-1]
    return json.loads(last)


def main(args):
    dry = "--dry-run" in args
    result = run_cli()
    tags, fields = parse(result)
    ln = influx.line("speedtest", tags, fields, ts=time.time())
    if dry:
        print(ln)
        return 0
    influx.write("network", [ln], "INFLUX_TOKEN_SPEEDTEST")
    print(f"OK: download {fields['download']} Mbps, upload {fields['upload']} Mbps, "
          f"ping {fields['ping']} ms, {fields['bytes_used'] / 1e6:.0f} MB used, server {tags['server']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
