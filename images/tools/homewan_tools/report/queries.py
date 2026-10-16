"""Flux queries. Each returns a pandas DataFrame, empty when there is no data.

Rules learned on the previous project (see SPEC 8.4):
- Counter totals: difference(nonNegative: true) |> sum(), with no daily
  aggregateWindow, which splits at UTC midnight and loses data.
- A bare group() goes directly before ranking.
- The client timeout is 60 seconds; the protocol queries scan many tags.
"""
import os

import pandas as pd

NETWORK, SYSTEM = "network", "system"


def _rfc(ts):
    return pd.Timestamp(ts).tz_convert("UTC").strftime("%Y-%m-%dT%H:%M:%SZ")


class Source:
    """Runs Flux against InfluxDB. Tests replace it with a fake that has the
    same methods."""

    def __init__(self, settings):
        from influxdb_client import InfluxDBClient
        self.org = settings.get("INFLUX_ORG")
        self.client = InfluxDBClient(url=settings.get("INFLUX_URL", "http://influxdb:8086"),
                                     token=os.environ.get("INFLUX_TOKEN_REPORT", ""),
                                     org=self.org, timeout=60_000)

    def close(self):
        self.client.close()

    def frame(self, flux, columns):
        df = self.client.query_api().query_data_frame(flux, org=self.org)
        if isinstance(df, list):
            df = pd.concat(df) if df else pd.DataFrame()
        if df.empty:
            return pd.DataFrame(columns=columns)
        for c in columns:
            if c not in df.columns:
                df[c] = None
        return df[columns]

    # ---- network ----

    def speedtest(self, start, stop):
        return self.frame(f'''
from(bucket: "{NETWORK}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "speedtest")
  |> filter(fn: (r) => r._field == "download" or r._field == "upload" or r._field == "ping" or r._field == "bytes_used")
''', ["_time", "_field", "_value"])

    def wan_counters(self, start, stop):
        """Cumulative byte counters per layer-4 protocol, as ntopng writes them."""
        return self.frame(f'''
from(bucket: "{NETWORK}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "iface:l4protos" and r._field == "bytes")
''', ["_time", "l4proto", "_value"])

    def wan_hourly(self, start, stop):
        """Bytes per hour, summed across protocols, for data cap accounting."""
        return self.frame(f'''
from(bucket: "{NETWORK}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "iface:l4protos" and r._field == "bytes")
  |> difference(nonNegative: true)
  |> aggregateWindow(every: 1h, fn: sum, createEmpty: false)
  |> group(columns: ["_time"]) |> sum() |> group()
''', ["_time", "_value"])

    def top_protocols(self, start, stop, n=10):
        return self.frame(f'''
from(bucket: "{NETWORK}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "iface:ndpi" and r._field == "bytes")
  |> group(columns: ["protocol"])
  |> difference(nonNegative: true)
  |> sum()
  |> group()
  |> sort(columns: ["_value"], desc: true)
  |> limit(n: {n})
''', ["protocol", "_value"])

    def protocol_windows(self, start, stop, protocols):
        if not protocols:
            return pd.DataFrame(columns=["_time", "protocol", "_value"])
        match = " or ".join(f'r.protocol == "{p}"' for p in protocols)
        return self.frame(f'''
from(bucket: "{NETWORK}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "iface:ndpi" and r._field == "bytes")
  |> filter(fn: (r) => {match})
  |> group(columns: ["protocol"])
  |> sort(columns: ["_time"])
  |> difference(nonNegative: true)
  |> aggregateWindow(every: 6h, fn: sum, createEmpty: false)
''', ["_time", "protocol", "_value"])

    def speedtest_bytes(self, start, stop):
        df = self.frame(f'''
from(bucket: "{NETWORK}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "speedtest" and r._field == "bytes_used")
  |> group() |> sum()
''', ["_value"])
        return float(df["_value"].sum()) if not df.empty else 0.0

    def top_hosts(self, start, stop, n=10):
        """Layout B: bytes per local host (ntopng host timeseries)."""
        return self.frame(f'''
from(bucket: "{NETWORK}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "host:traffic" and (r._field == "bytes_sent" or r._field == "bytes_rcvd"))
  |> group(columns: ["host", "_field"])
  |> difference(nonNegative: true)
  |> sum()
  |> group(columns: ["host"]) |> sum() |> group()
  |> sort(columns: ["_value"], desc: true)
  |> limit(n: {n})
''', ["host", "_value"])

    # ---- system ----

    def system_usage(self, start, stop):
        df = self.frame(f'''
from(bucket: "{SYSTEM}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) =>
      (r._measurement == "cpu" and r._field == "usage_idle") or
      (r._measurement == "mem" and r._field == "used_percent") or
      (r._measurement == "disk" and r._field == "used_percent"))
  |> aggregateWindow(every: 10m, fn: mean, createEmpty: false)
''', ["_time", "_measurement", "_value", "path"])
        return df

    def storage(self):
        return self.frame(f'''
from(bucket: "{SYSTEM}") |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "disk" and (r._field == "used" or r._field == "total"))
  |> last()
''', ["path", "device", "fstype", "_field", "_value"])

    def temperature(self, start, stop):
        return self.frame(f'''
from(bucket: "{SYSTEM}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "temp" and r._field == "temp")
  |> group(columns: ["_measurement"])
  |> aggregateWindow(every: 10m, fn: max, createEmpty: false)
''', ["_time", "_value"])

    def smart_latest(self, start, stop):
        """Last value of each SMART field per drive, and the first value in
        the window, to show what changed during the week."""
        last = self.frame(f'''
from(bucket: "{SYSTEM}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "smart")
  |> last()
''', ["drive", "model", "_field", "_value"])
        first = self.frame(f'''
from(bucket: "{SYSTEM}") |> range(start: {_rfc(start)}, stop: {_rfc(stop)})
  |> filter(fn: (r) => r._measurement == "smart")
  |> first()
''', ["drive", "_field", "_value"])
        return last, first
