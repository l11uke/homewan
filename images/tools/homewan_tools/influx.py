"""Minimal InfluxDB 2 line-protocol writer (standard library only)."""
import os
import urllib.parse
import urllib.request


def escape_tag(value):
    return str(value).replace("\\", "\\\\").replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")


def field(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return f"{value}i"
    if isinstance(value, float):
        return repr(value)
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def line(measurement, tags, fields, ts=None):
    """One line-protocol line. Fields with value None are left out."""
    t = "".join(f",{escape_tag(k)}={escape_tag(v)}" for k, v in sorted(tags.items()) if v not in (None, ""))
    f = ",".join(f"{escape_tag(k)}={field(v)}" for k, v in fields.items() if v is not None)
    if not f:
        raise ValueError(f"{measurement}: no fields to write")
    return f"{escape_tag(measurement)}{t} {f}" + (f" {int(ts)}" if ts is not None else "")


def write(bucket, lines, token_env):
    url = os.environ.get("INFLUX_URL", "http://influxdb:8086")
    org = os.environ["INFLUX_ORG"]
    token = os.environ.get(token_env, "")
    if not token:
        raise RuntimeError(f"{token_env} is empty: run 'sudo homewan apply' to create InfluxDB tokens")
    q = urllib.parse.urlencode({"org": org, "bucket": bucket, "precision": "s"})
    req = urllib.request.Request(f"{url}/api/v2/write?{q}", data="\n".join(lines).encode(),
                                 headers={"Authorization": f"Token {token}",
                                          "Content-Type": "text/plain; charset=utf-8"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status != 204:
            raise RuntimeError(f"InfluxDB write returned HTTP {r.status}")
