"""Unit tests for the Python parts. Run: python3 -m unittest tests/test_python.py"""
import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "images", "tools"))
sys.path.insert(0, os.path.join(ROOT, "lib", "py"))
FIX = os.path.join(ROOT, "tests", "fixtures", "tools")

from homewan_tools import influx, smart, speedtest  # noqa: E402
import render  # noqa: E402


class TestInfluxLine(unittest.TestCase):
    def test_escaping_and_types(self):
        ln = influx.line("speedtest", {"server": "Example Net, Brisbane", "isp": None},
                         {"download": 740.5, "bytes_used": 12, "ok": True, "note": 'a "b"', "skip": None}, ts=1700000000.9)
        self.assertEqual(ln, 'speedtest,server=Example\\ Net\\,\\ Brisbane download=740.5,bytes_used=12i,ok=true,note="a \\"b\\"" 1700000000')

    def test_no_fields(self):
        with self.assertRaises(ValueError):
            influx.line("x", {}, {"a": None})


class TestSpeedtest(unittest.TestCase):
    def test_parse(self):
        with open(os.path.join(FIX, "speedtest.json")) as f:
            tags, fields = speedtest.parse(json.load(f))
        self.assertEqual(tags, {"server": "Example Net Brisbane", "isp": "Example ISP"})
        self.assertEqual(fields["download"], 740.0)
        self.assertEqual(fields["upload"], 42.0)
        self.assertEqual(fields["ping"], 9.42)
        self.assertEqual(fields["bytes_used"], 1163000000)
        self.assertEqual(fields["packet_loss"], 0.0)

    def test_no_external_ip_stored(self):
        with open(os.path.join(FIX, "speedtest.json")) as f:
            tags, fields = speedtest.parse(json.load(f))
        self.assertNotIn("203.0.113.7", json.dumps([tags, fields]))


class TestSmart(unittest.TestCase):
    def test_parse_ata(self):
        with open(os.path.join(FIX, "smartctl-ata.json")) as f:
            fields = smart.parse(json.load(f))
        self.assertEqual(fields, {"passed": True, "temperature": 38.0, "power_on_hours": 51234,
                                  "reallocated": 2, "pending": 0, "uncorrectable": 0, "crc_errors": 14})

    def test_device_path_map(self):
        os.environ["SMART_DEVICE_PATHS"] = "ata-X:Y=/dev/sdz,usb-Q=/dev/sdq"
        try:
            self.assertEqual(smart.device_path("usb-Q"), "/dev/sdq")
        finally:
            del os.environ["SMART_DEVICE_PATHS"]


class TestRender(unittest.TestCase):
    def test_conditionals_and_values(self):
        tpl = "a={{A}}\n#%if B\nb on ${KEEP}\n#%if !C\nnot c\n#%endif\n#%endif\n#%if !B\nb off\n#%endif\n"
        self.assertEqual(render.render(tpl, {"A": "1", "B": "yes", "C": "no"}, "t"), "a=1\nb on ${KEEP}\nnot c\n")
        self.assertEqual(render.render(tpl, {"A": "1", "B": "no"}, "t"), "a=1\nb off\n")

    def test_missing_value_fails(self):
        with self.assertRaises(SystemExit):
            render.render("{{NOPE}}", {}, "t")

    def test_load_quotes(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("# c\nA='x y'\nB=z\nC=''\n")
        try:
            self.assertEqual(render.load([f.name]), {"A": "x y", "B": "z", "C": ""})
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
