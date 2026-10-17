"""Tests for the weekly report and the daily check, against a fake database.
Run from the repo root: python3 -m unittest tests.test_report"""
import email
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "images", "tools"))

from homewan_tools.report import cap, daily, drives, mail, weekly  # noqa: E402
from homewan_tools.report.settings import Settings  # noqa: E402

NOW = datetime(2026, 10, 18, 8, 0, tzinfo=timezone.utc)
TZ = ZoneInfo("Australia/Brisbane")


def times(start, end, step):
    return pd.date_range(pd.Timestamp(start).tz_convert("UTC"), pd.Timestamp(end).tz_convert("UTC"), freq=step)


class FakeSource:
    """Same methods as queries.Source, returning made-up but realistic data."""

    def __init__(self, hourly_gb=1.0, smart_passed=True, reallocated=(2, 2)):
        self.hourly_gb, self.smart_passed, self.reallocated = hourly_gb, smart_passed, reallocated

    def close(self):
        pass

    def speedtest(self, start, stop):
        rows = []
        for t in times(start, stop, "6h"):
            rows += [(t, "download", 690.0), (t, "upload", 40.0), (t, "ping", 9.0), (t, "bytes_used", 1.1e9)]
        return pd.DataFrame(rows, columns=["_time", "_field", "_value"])

    def wan_counters(self, start, stop):
        rows, tcp, udp = [], 0.0, 0.0
        for i, t in enumerate(times(start, stop, "5min")):
            tcp, udp = tcp + 60e6, udp + 20e6
            if i == 500:  # ntopng restart: counters reset
                tcp, udp = 1e6, 1e6
            rows += [(t, "tcp", tcp), (t, "udp", udp)]
        return pd.DataFrame(rows, columns=["_time", "l4proto", "_value"])

    def wan_hourly(self, start, stop):
        return pd.DataFrame([(t, self.hourly_gb * 1e9) for t in times(start, stop, "1h")], columns=["_time", "_value"])

    def top_protocols(self, start, stop, n=10):
        names = ["YouTube", "Netflix", "Steam", "TeamsCall", "Spotify", "iCloudPrivateRelay", "HTTP", "TLS", "DNS", "QUIC"]
        return pd.DataFrame([(p, (10 - i) * 5e9) for i, p in enumerate(names[:n])], columns=["protocol", "_value"])

    def protocol_windows(self, start, stop, protocols):
        rows = [(t, p, 2e8) for t in times(start, stop, "6h") for p in protocols]
        return pd.DataFrame(rows, columns=["_time", "protocol", "_value"])

    def speedtest_bytes(self, start, stop):
        return 1.1e9 * len(times(start, stop, "6h"))

    def top_hosts(self, start, stop, n=10):
        return pd.DataFrame([("192.168.1.20", 9e9), ("192.168.1.21", 4e9)], columns=["host", "_value"])

    def system_usage(self, start, stop):
        rows = []
        for t in times(start, stop, "10min"):
            rows += [(t, "cpu", 80.0, None), (t, "mem", 35.0, None), (t, "disk", 58.0, "/"),
                     (t, "disk", 10.0, "/media/usb"), (t, "disk", 16.0, "/boot/firmware")]
        return pd.DataFrame(rows, columns=["_time", "_measurement", "_value", "path"])

    def storage(self):
        return pd.DataFrame([("/", "mmcblk0p2", "ext4", "used", 16e9), ("/", "mmcblk0p2", "ext4", "total", 29e9),
                             ("/media/usb", "sda1", "ntfs3", "used", 180e9), ("/media/usb", "sda1", "ntfs3", "total", 2000e9)],
                            columns=["path", "device", "fstype", "_field", "_value"])

    def temperature(self, start, stop):
        return pd.DataFrame([(t, 52.0) for t in times(start, stop, "10min")], columns=["_time", "_value"])

    def smart_latest(self, start, stop):
        last = pd.DataFrame([("ata-X", "Example 2TB", "passed", self.smart_passed), ("ata-X", "Example 2TB", "temperature", 38.0),
                             ("ata-X", "Example 2TB", "power_on_hours", 51234), ("ata-X", "Example 2TB", "reallocated", self.reallocated[1]),
                             ("ata-X", "Example 2TB", "pending", 0)], columns=["drive", "model", "_field", "_value"])
        first = pd.DataFrame([("ata-X", "reallocated", self.reallocated[0]), ("ata-X", "pending", 0)], columns=["drive", "_field", "_value"])
        return last, first


BASE_ENV = {
    "TZ": "Australia/Brisbane", "FEATURES": "report,health,speedtest,capture", "GOALS": "speed,usage,apps,health",
    "PLAN_DOWN_MBPS": "740", "PLAN_UP_MBPS": "42", "REPORT_TO": "someone@example.com", "SMTP_FROM": "sender@example.com",
    "LAYOUT": "wan_mirror", "MGMT_IFACE": "eth1", "CAP_ENABLED": "no", "SMART_DEVICES": "ata-X:auto",
    "DISK_WARNINGS": "yes", "CAP_WARNINGS": "no",
}


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        drives.STATE_DIR = daily.STATE_DIR = weekly.STATE_DIR = self.dir
        self.host({"drives": [{"mount": "/media/usb", "expected_uuid": "AB", "actual_uuid": "AB", "status": "ok"}],
                   "new_drives": [], "mgmt_iface": "eth1", "mgmt_link_mbps": 1000})

    def host(self, data):
        with open(os.path.join(self.dir, "host.json"), "w") as f:
            json.dump(data, f)

    def settings(self, **extra):
        return Settings(env={**BASE_ENV, **extra})


class TestWeekly(Base):
    def build(self, source=None, **extra):
        return weekly.build_report(source or FakeSource(), self.settings(**extra), NOW, self.dir)

    def test_all_old_charts_present(self):
        subject, plain, body, att = self.build()
        names = sorted(os.path.basename(a) for a in att)
        self.assertEqual(names, ["1-speedtest.png", "2-internet-use.png", "3-pi-usage.png", "4-drive-space.png",
                                 "5-temperature.png", "6-apps-by-6-hours.png"])
        for a in att:
            self.assertGreater(os.path.getsize(a), 10_000, a)
        self.assertIn("Top 10 apps and services", body)
        self.assertIn("YouTube", body)
        self.assertEqual(subject, "homewan weekly report, 11 Oct to 18 Oct 2026")

    def test_speed_table_against_plan(self):
        _, _, body, _ = self.build()
        self.assertIn("<td style=\"padding:4px 10px;text-align:right;border-bottom:1px solid #ddd\">93%</td>", body)
        self.assertIn("29 tests, using 31.9 GB", body)

    def test_counter_reset_does_not_go_negative(self):
        s = weekly.cumulative_gb(FakeSource().wan_counters(NOW - timedelta(days=7), NOW))
        self.assertTrue((s.diff().dropna() >= 0).all())

    def test_slow_link_note(self):
        self.host({"drives": [], "mgmt_iface": "eth1", "mgmt_link_mbps": 100})
        subject, plain, body, _ = self.build()
        self.assertIn("runs at 100 Mbps", body)
        self.assertIn("needs attention", subject)

    def test_usb2_note(self):
        self.host({"drives": [], "mgmt_iface": "eth1", "mgmt_link_mbps": 1000, "mgmt_usb_mbps": 480})
        _, _, body, _ = self.build()
        self.assertIn("USB 2 connection", body)

    def test_no_usb_note_on_usb3(self):
        self.host({"drives": [], "mgmt_iface": "eth1", "mgmt_link_mbps": 1000, "mgmt_usb_mbps": 5000})
        _, _, body, _ = self.build()
        self.assertNotIn("USB 2", body)

    def test_missing_drive_and_new_drive(self):
        self.host({"drives": [{"mount": "/media/usb", "status": "missing"}],
                   "new_drives": [{"mount": "/media/stick", "fstype": "ext4", "size_gb": 64}], "mgmt_link_mbps": 1000})
        subject, plain, body, _ = self.build()
        self.assertIn("Drive missing", body)
        self.assertIn("/media/stick", body)
        self.assertIn("Drive missing", plain)

    def test_smart_rise_flags_drive(self):
        _, _, body, _ = self.build(FakeSource(reallocated=(2, 9)))
        self.assertIn("9 (+7)", body)
        self.assertIn("shows signs of failing", body)

    def test_cap_section_and_projection_warning(self):
        _, _, body, _ = self.build(FakeSource(hourly_gb=1.0), CAP_ENABLED="yes", CAP_PERIOD="monthly",
                                   CAP_RESET_DAY="1", CAP_SPLIT="no", CAP_GB="500", CAP_OVER_ACTION="slowed")
        self.assertIn("<h3>Data cap</h3>", body)
        self.assertIn("Projected at reset", body)
        self.assertIn("your speed is slowed", body)  # 24 GB a day blows a 500 GB cap

    def test_cap_split_peak(self):
        s = self.settings(CAP_ENABLED="yes", CAP_PERIOD="monthly", CAP_RESET_DAY="1", CAP_SPLIT="yes",
                          CAP_PEAK_GB="100", CAP_OFFPEAK_GB="200", CAP_PEAK_HOURS="07:00-01:00")
        c = weekly.cap_status(FakeSource(hourly_gb=1.0), s, NOW)
        peak, off = c["rows"]
        self.assertEqual((peak.name, off.name), ("Peak", "Off-peak"))
        self.assertAlmostEqual(peak.used_gb / (peak.used_gb + off.used_gb), 18 / 24, places=1)

    def test_layout_c_has_no_traffic_charts(self):
        _, _, body, att = self.build(FEATURES="report,health,speedtest")
        names = [os.path.basename(a) for a in att]
        self.assertNotIn("2-internet-use.png", names)
        self.assertNotIn("Top 10 apps", body)

    def test_email_has_attachments(self):
        s = self.settings()
        subject, plain, body, att = weekly.build_report(FakeSource(), s, NOW, self.dir)
        msg = email.message_from_bytes(bytes(mail.build(s, subject, plain, body, att)))
        files = [p.get_filename() for p in msg.walk() if p.get_filename()]
        self.assertEqual(len(files), 6)
        self.assertEqual(msg["To"], "someone@example.com")


class TestCapMath(unittest.TestCase):
    def test_monthly_short_month(self):
        s, e = cap.period_bounds(datetime(2026, 2, 28, 9, tzinfo=TZ), "monthly", 31)
        self.assertEqual((s.date().isoformat(), e.date().isoformat()), ("2026-02-28", "2026-03-31"))

    def test_rolling(self):
        s, e = cap.period_bounds(datetime(2026, 10, 15, 9, tzinfo=TZ), "rolling_30", start_date="2026-09-01")
        self.assertEqual((s.date().isoformat(), e.date().isoformat()), ("2026-10-01", "2026-10-31"))

    def test_peak_across_midnight(self):
        self.assertTrue(cap.in_peak(datetime(2026, 1, 1, 0, 30), "07:00-01:00"))
        self.assertFalse(cap.in_peak(datetime(2026, 1, 1, 3, 0), "07:00-01:00"))
        self.assertTrue(cap.in_peak(datetime(2026, 1, 1, 7, 0), "07:00-01:00"))

    def test_projection(self):
        now = datetime(2026, 10, 15, tzinfo=TZ)
        self.assertAlmostEqual(cap.project(100, 70, now, now + timedelta(days=10)), 200)


class TestDaily(Base):
    def run_daily(self, source=None, **extra):
        state = daily.load_state()
        s = self.settings(**extra)
        events = daily.drive_events(drives.host_state(), state)
        events += daily.smart_events(drives.smart_table(*(source or FakeSource()).smart_latest(NOW, NOW)), state)
        if s.cap_enabled:
            events += daily.cap_events(weekly.cap_status(source or FakeSource(), s, NOW), state, s)
        daily.save_state(state)
        return events

    def test_drive_missing_once_then_back(self):
        self.assertEqual(self.run_daily(), [])
        self.host({"drives": [{"mount": "/media/usb", "status": "missing"}]})
        ev = self.run_daily()
        self.assertEqual(len(ev), 1)
        self.assertIn("is missing", ev[0])
        self.assertEqual(self.run_daily(), [])
        self.host({"drives": [{"mount": "/media/usb", "status": "ok"}]})
        self.assertEqual(self.run_daily(), ["Drive /media/usb is back."])

    def test_smart_rise_once(self):
        self.run_daily(FakeSource(reallocated=(2, 2)))
        ev = self.run_daily(FakeSource(reallocated=(2, 5)))
        self.assertTrue(any("rose from 2 to 5" in e for e in ev))
        self.assertEqual(self.run_daily(FakeSource(reallocated=(2, 5))), [])

    def test_smart_failing(self):
        ev = self.run_daily(FakeSource(smart_passed=False))
        self.assertTrue(any("FAILING" in e for e in ev))
        self.assertEqual(self.run_daily(FakeSource(smart_passed=False)), [])

    def test_cap_warnings_once_per_period(self):
        kw = dict(CAP_ENABLED="yes", CAP_PERIOD="monthly", CAP_RESET_DAY="1", CAP_SPLIT="no", CAP_GB="500", CAP_OVER_ACTION="charged")
        ev = self.run_daily(FakeSource(hourly_gb=1.0), **kw)  # 17.3 days x 24 GB = 416 GB: past 80%, projected over
        self.assertEqual(len([e for e in ev if e.startswith("Data cap")]), 2)
        self.assertEqual(self.run_daily(FakeSource(hourly_gb=1.0), **kw), [])


if __name__ == "__main__":
    unittest.main()
