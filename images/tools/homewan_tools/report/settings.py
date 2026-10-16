"""Settings from the environment (site.conf values plus the job's secrets)."""
import os
from dataclasses import dataclass, field
from zoneinfo import ZoneInfo


def _list(v):
    return [x for x in (v or "").split(",") if x]


def _int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


@dataclass
class Settings:
    env: dict = field(default_factory=lambda: dict(os.environ))

    def get(self, key, default=""):
        return self.env.get(key, default) or default

    @property
    def tz(self):
        return ZoneInfo(self.get("TZ", "UTC"))

    @property
    def features(self):
        return _list(self.get("FEATURES"))

    def has(self, feature):
        return feature in self.features

    @property
    def goals(self):
        return _list(self.get("GOALS"))

    @property
    def plan_down(self):
        return _int(self.get("PLAN_DOWN_MBPS"))

    @property
    def plan_up(self):
        return _int(self.get("PLAN_UP_MBPS"))

    @property
    def report_to(self):
        return _list(self.get("REPORT_TO"))

    @property
    def cap_enabled(self):
        return self.get("CAP_ENABLED") == "yes"

    @property
    def smart_devices(self):
        return [d.rpartition(":")[0] or d for d in _list(self.get("SMART_DEVICES"))]
