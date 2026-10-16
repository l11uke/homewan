"""Data cap arithmetic: period boundaries, peak/off-peak split, projection.

Pure functions on plain values, so they can be tested without a database.
"""
import calendar
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta


def _clamped(year, month, day):
    return date(year, month, min(day, calendar.monthrange(year, month)[1]))


def period_bounds(now, period, reset_day=1, start_date=None):
    """Start and end (exclusive) of the allowance period containing `now`,
    as timezone-aware datetimes in now's time zone."""
    tz = now.tzinfo
    today = now.date()
    if period == "daily":
        start = today
        end = today + timedelta(days=1)
    elif period == "rolling_30":
        anchor = date.fromisoformat(start_date)
        n = (today - anchor).days // 30
        start = anchor + timedelta(days=30 * n)
        end = start + timedelta(days=30)
    else:  # monthly
        this = _clamped(today.year, today.month, reset_day)
        if today >= this:
            start = this
            y, m = (today.year + (today.month == 12), today.month % 12 + 1)
            end = _clamped(y, m, reset_day)
        else:
            y, m = (today.year - (today.month == 1), (today.month - 2) % 12 + 1)
            start = _clamped(y, m, reset_day)
            end = this
    return (datetime.combine(start, time(), tz), datetime.combine(end, time(), tz))


def in_peak(local_dt, peak_hours):
    """peak_hours like "07:00-01:00"; ranges may cross midnight."""
    a, b = peak_hours.split("-")
    start = time.fromisoformat(a)
    end = time.fromisoformat(b)
    t = local_dt.time()
    if start <= end:
        return start <= t < end
    return t >= start or t < end


@dataclass
class CapStatus:
    name: str          # "Total", "Peak" or "Off-peak"
    used_gb: float
    allowance_gb: float
    projected_gb: float

    @property
    def percent(self):
        return 100 * self.used_gb / self.allowance_gb if self.allowance_gb else 0.0

    @property
    def projected_percent(self):
        return 100 * self.projected_gb / self.allowance_gb if self.allowance_gb else 0.0


def project(used_gb, last7_gb, now, end):
    """Used so far plus the last 7 days' daily average for the time left."""
    days_left = max((end - now).total_seconds() / 86400, 0)
    return used_gb + (last7_gb / 7) * days_left


def adjusted(gb, adjust_percent):
    return gb * (1 + adjust_percent / 100)
