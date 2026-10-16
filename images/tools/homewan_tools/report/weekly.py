"""The weekly report: charts as PNG attachments, summary tables in the body.

homewan run report            build and send
homewan run report --dry-run  build only; saves the email and charts to
                              /state/report-preview/ instead of sending
"""
import html
import json
import os
import sys
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import pandas as pd

from . import cap, charts, drives, mail
from .settings import Settings

GB = 1e9  # decimal gigabytes, as internet providers count them
STATE_DIR = os.environ.get("HOMEWAN_STATE", "/state")


# ---------------- data shaping ----------------

def speedtest_frame(df, tz):
    if df is None or df.empty:
        return None
    p = df.pivot_table(index="_time", columns="_field", values="_value", aggfunc="mean").sort_index()
    p.index = pd.to_datetime(p.index, utc=True)
    return p


def cumulative_gb(df):
    """Cumulative GB from ntopng's per-protocol byte counters."""
    if df is None or df.empty:
        return None
    total = df.groupby("_time")["_value"].sum().sort_index()
    deltas = total.diff().clip(lower=0).fillna(0)
    s = deltas.cumsum() / GB
    s.index = pd.to_datetime(s.index, utc=True)
    return s


def system_frame(df):
    if df is None or df.empty:
        return None
    df = df.copy()
    df["path"] = df["path"].fillna("")
    df["series"] = df["_measurement"]
    disk = df["_measurement"] == "disk"
    df.loc[disk, "series"] = "disk:" + df.loc[disk, "path"].astype(str)
    df = df[~df["series"].str.startswith("disk:/boot")]
    p = df.pivot_table(index="_time", columns="series", values="_value", aggfunc="mean").sort_index()
    p.index = pd.to_datetime(p.index, utc=True)
    if "cpu" in p:
        p["cpu"] = 100 - p["cpu"]
    return p


def storage_frame(df):
    if df is None or df.empty:
        return None
    df = df[~df["path"].astype(str).str.startswith("/boot")]
    p = df.pivot_table(index=["path", "device"], columns="_field", values="_value", aggfunc="max")
    if "used" not in p or "total" not in p:
        return None
    p = p.reset_index()
    p = p[p["total"] > 0]
    p["used_gb"] = p["used"] / GB
    p["total_gb"] = p["total"] / GB
    p["pct"] = p["used"] / p["total"] * 100
    p["is_sd"] = p["device"].astype(str).str.startswith("mmcblk")
    p["label"] = [("SD card (/)" if str(d).startswith("mmcblk") else f"{os.path.basename(str(m).rstrip('/')) or m} ({d})")
                  for m, d in zip(p["path"], p["device"])]
    return p.sort_values(["is_sd", "path"], ascending=[False, True]).reset_index(drop=True)


def protocol_frame(df, protocols):
    if df is None or df.empty or not protocols:
        return None
    p = df.pivot_table(index="_time", columns="protocol", values="_value", aggfunc="sum", fill_value=0)
    p = p.reindex(columns=protocols, fill_value=0) / GB
    p.index = pd.to_datetime(p.index, utc=True) - pd.Timedelta(hours=6)  # bars start at window start
    return p.sort_index()


def ambient(settings, start, end):
    lat, lon = settings.get("LOCATION_LAT"), settings.get("LOCATION_LON")
    if not lat or not lon:
        return None
    q = urllib.parse.urlencode({"latitude": lat, "longitude": lon, "hourly": "temperature_2m",
                                "past_days": 8, "forecast_days": 1, "timezone": "UTC"})
    try:
        with urllib.request.urlopen(f"https://api.open-meteo.com/v1/forecast?{q}", timeout=20) as r:
            data = json.load(r)
        s = pd.Series(data["hourly"]["temperature_2m"],
                      index=pd.to_datetime(data["hourly"]["time"]).tz_localize("UTC"), dtype="float")
        return s[(s.index >= start) & (s.index <= end)].dropna()
    except (OSError, ValueError, KeyError) as e:
        print(f"WARNING: outdoor temperature lookup failed, the chart leaves it out: {e}", file=sys.stderr)
        return None


def hourly_split(df, tz, peak_hours=None):
    """Hourly byte totals -> (total GB, peak GB, off-peak GB)."""
    if df is None or df.empty:
        return 0.0, 0.0, 0.0
    t = pd.to_datetime(df["_time"], utc=True)
    v = df["_value"].astype(float)
    total = v.sum() / GB
    if not peak_hours:
        return total, 0.0, 0.0
    peak = sum(b for ts, b in zip(t, v) if cap.in_peak((ts - pd.Timedelta(hours=1)).tz_convert(tz).to_pydatetime(), peak_hours))
    return total, peak / GB, (v.sum() - peak) / GB


def cap_status(source, s, now):
    """CapStatus rows for the current period, plus period info."""
    tz = s.tz
    local_now = now.astimezone(tz)
    start, end = cap.period_bounds(local_now, s.get("CAP_PERIOD", "monthly"),
                                   int(s.get("CAP_RESET_DAY") or 1), s.get("CAP_START_DATE") or None)
    split = s.get("CAP_SPLIT") == "yes"
    hours = s.get("CAP_PEAK_HOURS") if split else None
    adj = float(s.get("CAP_ADJUST_PERCENT") or 0)
    used = hourly_split(source.wan_hourly(start, now), tz, hours)
    last7 = hourly_split(source.wan_hourly(now - timedelta(days=7), now), tz, hours)
    rows = []
    if split:
        for i, name, key in ((1, "Peak", "CAP_PEAK_GB"), (2, "Off-peak", "CAP_OFFPEAK_GB")):
            u = cap.adjusted(used[i], adj)
            rows.append(cap.CapStatus(name, u, float(s.get(key) or 0), cap.project(u, cap.adjusted(last7[i], adj), local_now, end)))
    else:
        u = cap.adjusted(used[0], adj)
        rows.append(cap.CapStatus("Total", u, float(s.get("CAP_GB") or 0), cap.project(u, cap.adjusted(last7[0], adj), local_now, end)))
    speed_gb = source.speedtest_bytes(start, now) / GB
    return {"rows": rows, "start": start, "end": end, "speedtest_gb": speed_gb,
            "days_left": max((end - local_now).total_seconds() / 86400, 0)}


# ---------------- report ----------------

def esc(x):
    return html.escape(str(x))


def table(headers, rows, align=None):
    align = align or ["left"] * len(headers)
    th = "".join(f'<th style="padding:4px 10px;text-align:{a};border-bottom:2px solid #333">{esc(h)}</th>' for h, a in zip(headers, align))
    trs = "".join("<tr>" + "".join(f'<td style="padding:4px 10px;text-align:{a};border-bottom:1px solid #ddd">{c}</td>'
                                    for c, a in zip(r, align)) + "</tr>" for r in rows)
    return f'<table style="border-collapse:collapse;font-size:14px">{th and "<tr>" + th + "</tr>"}{trs}</table>'


OVER = {"slowed": "your speed is slowed", "charged": "extra data is charged", "cut_off": "your internet stops until the reset"}


def build_report(source, s, now, outdir):
    tz = s.tz
    end = now
    start = end - timedelta(days=7)
    host = drives.host_state()
    attachments, notes, sections, text = [], [], [], []

    # Notes that change how to read the rest
    ml = host.get("mgmt_link_mbps")
    if ml and s.has("speedtest") and ml < s.plan_down:
        notes.append(f"The Pi's own connection ({esc(host.get('mgmt_iface'))}) runs at {ml} Mbps, so speedtests "
                     f"cannot show more than about {ml * 94 // 100} Mbps of your {s.plan_down} Mbps plan.")
    for d in host.get("drives", []):
        if d.get("status") == "missing":
            notes.append(f"<b>Drive missing:</b> nothing is mounted at {esc(d['mount'])}.")
        elif d.get("status") == "different":
            notes.append(f"<b>Different drive:</b> the drive at {esc(d['mount'])} is not the one homewan expects.")

    # Speed
    if s.has("speedtest"):
        st = speedtest_frame(source.speedtest(start, end), tz)
        attachments.append(charts.speedtest(st, s.plan_down, s.plan_up, start, end, tz, os.path.join(outdir, "1-speedtest.png")))
        if st is not None and "download" in st:
            dl, ul = st["download"], st.get("upload", pd.Series(dtype=float))
            used = st["bytes_used"].sum() / GB if "bytes_used" in st else 0
            rows = [["Download", f"{dl.mean():.0f}", f"{dl.min():.0f}", f"{dl.max():.0f}", f"{s.plan_down}", f"{100 * dl.mean() / s.plan_down:.0f}%" if s.plan_down else "-"],
                    ["Upload", f"{ul.mean():.0f}", f"{ul.min():.0f}", f"{ul.max():.0f}", f"{s.plan_up}", f"{100 * ul.mean() / s.plan_up:.0f}%" if s.plan_up and not ul.empty else "-"]]
            sections.append(f"<h3>Speed</h3>{table(['', 'Average', 'Lowest', 'Highest', 'Plan', 'Average vs plan'], rows, ['left'] + ['right'] * 5)}"
                            f"<p>{len(dl)} tests, using {used:.1f} GB.</p>")
            text.append(f"Speed: average {dl.mean():.0f}/{ul.mean():.0f} Mbps from {len(dl)} tests (plan {s.plan_down}/{s.plan_up}).")
        else:
            sections.append("<h3>Speed</h3><p>No speedtest results this week.</p>")

    # Internet use and apps
    if s.has("capture"):
        cum = cumulative_gb(source.wan_counters(start, end))
        sp_gb = source.speedtest_bytes(start, end) / GB if s.has("speedtest") else 0
        attachments.append(charts.consumption(cum, sp_gb, start, end, tz, os.path.join(outdir, "2-internet-use.png")))
        total = float(cum.iloc[-1]) if cum is not None and not cum.empty else 0.0
        sections.append(f"<h3>Internet use</h3><p>{total:.1f} GB this week, {total / 7:.1f} GB a day on average"
                        + (f", of which {sp_gb:.1f} GB by homewan's speedtests" if sp_gb else "") + ".</p>")
        text.append(f"Internet use: {total:.1f} GB this week.")

        top = source.top_protocols(start, end, 10)
        protocols = top["protocol"].tolist() if not top.empty else []
        if protocols:
            rows = [[f"{i + 1}", esc(r["protocol"]), f"{r['_value'] / GB:.2f} GB"] for i, r in enumerate(top.to_dict("records"))]
            sections.append(f"<h3>Top 10 apps and services</h3>{table(['#', 'App or service', 'Data'], rows, ['right', 'left', 'right'])}")
        attachments.append(charts.protocol_windows(protocol_frame(source.protocol_windows(start, end, protocols), protocols),
                                                   start, end, tz, os.path.join(outdir, "6-apps-by-6-hours.png")))
        if s.get("LAYOUT") == "lan_mirror":
            hosts = source.top_hosts(start, end, 10)
            if not hosts.empty:
                rows = [[f"{i + 1}", esc(r["host"]), f"{r['_value'] / GB:.2f} GB"] for i, r in enumerate(hosts.to_dict("records"))]
                sections.append(f"<h3>Top 10 devices</h3>{table(['#', 'Device', 'Data'], rows, ['right', 'left', 'right'])}")

    # Data cap
    if s.cap_enabled and s.has("capture"):
        c = cap_status(source, s, now)
        rows = [[r.name, f"{r.used_gb:.1f} GB", f"{r.allowance_gb:.0f} GB", f"{r.percent:.0f}%",
                 f"{r.projected_gb:.0f} GB ({r.projected_percent:.0f}%)"] for r in c["rows"]]
        warn = [r for r in c["rows"] if r.projected_gb > r.allowance_gb]
        body = table(["", "Used", "Allowance", "Used %", "Projected at reset"], rows, ["left"] + ["right"] * 4)
        body += (f"<p>Period {c['start']:%d %b} to {c['end'] - timedelta(days=1):%d %b}, {c['days_left']:.0f} days left. "
                 f"Speedtests used {c['speedtest_gb']:.1f} GB of it. Measured by homewan"
                 + (f", adjusted by {s.get('CAP_ADJUST_PERCENT')}%" if float(s.get('CAP_ADJUST_PERCENT') or 0) else "")
                 + "; your provider's meter can differ by a few percent.</p>")
        if s.get("CAP_COUNTS") == "down":
            body += "<p>Your plan counts downloads only. homewan counts both directions here, so these figures run a little high.</p>"
        if warn:
            notes.append(f"<b>Data cap:</b> at this week's rate you will use {warn[0].projected_percent:.0f}% of the "
                         f"{warn[0].name.lower()} allowance before the reset, after which {OVER.get(s.get('CAP_OVER_ACTION'), 'your plan limits apply')}.")
        sections.append(f"<h3>Data cap</h3>{body}")
        text.append("Data cap: " + "; ".join(f"{r.name} {r.used_gb:.0f} of {r.allowance_gb:.0f} GB" for r in c["rows"]) + ".")

    # Pi health and drives
    if s.has("health"):
        attachments.append(charts.system_usage(system_frame(source.system_usage(start, end)), start, end, tz, os.path.join(outdir, "3-pi-usage.png")))
        stor = storage_frame(source.storage())
        attachments.append(charts.storage(stor, tz, os.path.join(outdir, "4-drive-space.png"), now))
        temp = source.temperature(start, end)
        cpu = None
        if not temp.empty:
            cpu = pd.Series(temp["_value"].astype(float).values, index=pd.to_datetime(temp["_time"], utc=True)).sort_index()
        amb = ambient(s, start, end) if s.has("ambient") else None
        attachments.append(charts.temperature(cpu, amb, s.get("LOCATION_NAME"), start, end, tz, os.path.join(outdir, "5-temperature.png")))
        if cpu is not None and not cpu.empty:
            sections.append(f"<h3>The Pi</h3><p>CPU temperature peaked at {cpu.max():.0f} °C"
                            + (f"; outdoors peaked at {amb.max():.0f} °C" if amb is not None and not amb.empty else "") + ".</p>")

        drive_rows = []
        for d in host.get("drives", []):
            st = {"ok": "connected", "missing": "<b>missing</b>", "different": "<b>different drive</b>"}.get(d.get("status"), "unknown")
            drive_rows.append([esc(d["mount"]), st])
        for d in host.get("new_drives", []):
            drive_rows.append([esc(d["mount"]), f"new: not on the always-connected list ({esc(d.get('fstype'))}, {d.get('size_gb')} GB). "
                               "Add it with: sudo homewan reconfigure"])
        if drive_rows:
            sections.append(f"<h3>Drives</h3>{table(['Drive', 'Status'], drive_rows)}")

        smart = drives.smart_table(*source.smart_latest(start, end)) if s.smart_devices else []
        if smart:
            rows = []
            for d in smart:
                status = "<b>needs attention</b>" if d["problem"] else "OK"
                if d.get("passed") in (False, "false", 0):
                    status = "<b>FAILING</b>"
                rows.append([esc(d.get("model") or d["drive"]), status,
                             f"{d.get('temperature', '-'):.0f} °C" if isinstance(d.get("temperature"), (int, float)) else "-",
                             f"{int(d['power_on_hours']) // 24:,} days" if d.get("power_on_hours") is not None else "-",
                             f"{int(d.get('reallocated', 0))} (+{d.get('reallocated_rise', 0)})",
                             f"{int(d.get('pending', 0))}"])
                if d["problem"]:
                    notes.append(f"<b>Drive health:</b> {esc(d.get('model') or d['drive'])} shows signs of failing. Back up its data.")
            sections.append(f"<h3>Drive health</h3>{table(['Drive', 'Health', 'Temp', 'Powered on', 'Reallocated sectors (this week)', 'Pending sectors'], rows, ['left', 'left', 'right', 'right', 'right', 'right'])}")

    week = f"{start.astimezone(tz):%d %b} to {end.astimezone(tz):%d %b %Y}"
    subject = f"homewan weekly report, {week}" + (" (needs attention)" if notes else "")
    note_html = "".join(f'<p style="background:#fff4e5;border-left:4px solid #f59e0b;padding:6px 10px">{n}</p>' for n in notes)
    html_body = (f'<html><body style="font-family:sans-serif;max-width:720px">'
                 f"<h2>homewan weekly report</h2><p>{esc(week)}</p>{note_html}{''.join(sections)}"
                 f'<p style="color:#666;font-size:12px">{len(attachments)} charts attached. Sent by homewan on {esc(s.get("MGMT_IFACE"))}.</p>'
                 "</body></html>")
    plain = "\n".join([f"homewan weekly report, {week}", ""] + [html.unescape(n.replace("<b>", "").replace("</b>", "")) for n in notes] + text
                      + ["", "The charts are attached. View this email in an HTML-capable client for the tables."])
    return subject, plain, html_body, sorted(a for a in attachments if a)


def main(args):
    s = Settings()
    dry = "--dry-run" in args
    from .queries import Source
    source = Source(s)
    try:
        outdir = os.path.join(STATE_DIR, "report-preview") if dry else tempfile.mkdtemp(prefix="homewan-report-")
        os.makedirs(outdir, exist_ok=True)
        subject, plain, html_body, attachments = build_report(source, s, datetime.now(timezone.utc), outdir)
    finally:
        source.close()
    msg = mail.build(s, subject, plain, html_body, attachments)
    if dry:
        mail.save(msg, os.path.join(outdir, "report.eml"))
        print(f"OK: report saved to {outdir} (not sent): {subject}")
        return 0
    mail.send(s, msg)
    print(f"OK: report sent to {', '.join(s.report_to)}: {subject}")
    return 0
