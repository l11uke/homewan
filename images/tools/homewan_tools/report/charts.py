"""Report charts, one PNG each. Ported from the previous project's weekly
report; every chart covers the report window and marks local midnight
(solid) and midday (dashed)."""
import os
from datetime import timedelta

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

GB = 1024 ** 3


def _day_markers(ax, start, end, tz):
    cursor = start.astimezone(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    while cursor <= end:
        for when, style, width, alpha in ((cursor, "-", 0.8, 0.5), (cursor.replace(hour=12), "--", 0.6, 0.35)):
            if start <= when <= end:
                ax.axvline(when, color="#999999", linestyle=style, linewidth=width, alpha=alpha, zorder=0)
        cursor += timedelta(days=1)


def _finish(fig, ax, start, end, tz, path, dates=True):
    if dates:
        # Ticks at local midnight, so labels line up with the solid day lines.
        ax.xaxis.set_major_locator(mdates.DayLocator(tz=tz))
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%a %d", tz=tz))
        _day_markers(ax, start, end, tz)
        ax.set_xlim(start, end)
        fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
    return path


def _empty(ax, text):
    ax.text(0.5, 0.5, text, ha="center", va="center", transform=ax.transAxes)


def speedtest(df, plan_down, plan_up, start, end, tz, path):
    fig, ax = plt.subplots(figsize=(11, 4.5))
    ax.set_title(f"Speedtest, {start.astimezone(tz):%d %b} to {end.astimezone(tz):%d %b}")
    if df is not None and not df.empty:
        if "download" in df:
            ax.plot(df.index, df["download"], marker="o", markersize=3, label="Download (Mbps)", color="#2563eb")
        if "upload" in df:
            ax.plot(df.index, df["upload"], marker="o", markersize=3, label="Upload (Mbps)", color="#16a34a")
        if plan_down:
            ax.axhline(plan_down, color="#2563eb", linestyle=":", linewidth=1, label=f"Plan download ({plan_down})")
        if plan_up:
            ax.axhline(plan_up, color="#16a34a", linestyle=":", linewidth=1, label=f"Plan upload ({plan_up})")
        ax.set_ylabel("Mbps")
        ax.set_ylim(bottom=0)
        ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=8, frameon=False)
    else:
        _empty(ax, "No speedtest results in this period")
    return _finish(fig, ax, start, end, tz, path)


def consumption(series, speedtest_gb, start, end, tz, path):
    fig, ax = plt.subplots(figsize=(11, 4.5))
    total = float(series.iloc[-1]) if series is not None and not series.empty else 0.0
    ax.set_title(f"Internet use, cumulative: {total:.1f} GB this week"
                 + (f" ({speedtest_gb:.1f} GB by speedtests)" if speedtest_gb else ""))
    if series is not None and not series.empty:
        ax.plot(series.index, series.values, color="#dc2626")
        ax.fill_between(series.index, series.values, color="#dc2626", alpha=0.15)
        ax.set_ylabel("GB")
        ax.set_ylim(bottom=0)
    else:
        _empty(ax, "No traffic data in this period")
    return _finish(fig, ax, start, end, tz, path)


def system_usage(df, start, end, tz, path):
    fig, ax = plt.subplots(figsize=(11, 4.5))
    ax.set_title("Pi usage: CPU, memory and drives (% used)")
    if df is not None and not df.empty:
        colors = {"cpu": "#2563eb", "mem": "#16a34a"}
        labels = {"cpu": "CPU", "mem": "Memory"}
        extra = ["#f59e0b", "#7c3aed", "#e11d48", "#0891b2", "#65a30d"]
        disks = sorted(c for c in df.columns if str(c).startswith("disk:"))
        for i, c in enumerate(disks):
            colors[c] = extra[i % len(extra)]
            labels[c] = "SD card (/)" if c == "disk:/" else os.path.basename(c[5:].rstrip("/")) or c[5:]
        for c in ("cpu", "mem", *disks):
            if c in df:
                ax.plot(df.index, df[c], label=labels[c], color=colors[c])
        ax.set_ylabel("% used")
        ax.set_ylim(0, 100)
        ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=8, frameon=False)
    else:
        _empty(ax, "No Pi health data in this period")
    return _finish(fig, ax, start, end, tz, path)


def storage(df, tz, path, now):
    """Horizontal bars, one per drive, each scaled to its own capacity."""
    surface, used_c, free_c, ink, ink2 = "#fcfcfb", "#2a78d6", "#e1e0d9", "#0b0b0b", "#52514e"
    has = df is not None and not df.empty
    n = len(df) if has else 1
    fig, ax = plt.subplots(figsize=(10, 1.0 * n + 1.6))
    fig.patch.set_facecolor(surface)
    ax.set_facecolor(surface)
    ax.set_title(f"Drive space ({now.astimezone(tz):%d %b %Y})", color=ink)
    if has:
        y = list(range(n))
        used = df["pct"].tolist()
        ax.barh(y, used, height=0.32, color=used_c, edgecolor=surface, linewidth=1.5)
        ax.barh(y, [100 - p for p in used], height=0.32, left=used, color=free_c, edgecolor=surface, linewidth=1.5)
        for i, row in df.reset_index(drop=True).iterrows():
            ax.text(0, i - 0.30, f"{row['used_gb']:.1f} GB used of {row['total_gb']:.1f} GB ({row['pct']:.0f}%)",
                    ha="left", va="bottom", fontsize=9, color=ink2)
        ax.set_yticks(y)
        ax.set_yticklabels(df["label"].tolist(), color=ink)
        ax.set_xlim(0, 100)
        ax.set_ylim(n - 0.5, -0.7)
        ax.set_xlabel("% of capacity used", color=ink2)
        for side in ("top", "right", "left"):
            ax.spines[side].set_visible(False)
        ax.tick_params(axis="y", length=0)
    else:
        _empty(ax, "No drive data in the last hour")
        ax.set_xticks([]); ax.set_yticks([])
    fig.tight_layout()
    fig.savefig(path, dpi=150, facecolor=surface)
    plt.close(fig)
    return path


def temperature(cpu, ambient, location, start, end, tz, path):
    fig, ax = plt.subplots(figsize=(11, 4.5))
    ax.set_title("CPU temperature" + (f" and outdoor temperature ({location})" if ambient is not None else ""))
    if cpu is not None and not cpu.empty:
        ax.plot(cpu.index, cpu.values, color="#dc2626", label="CPU")
    if ambient is not None and not ambient.empty:
        ax.plot(ambient.index, ambient.values, color="#2563eb", label="Outdoor")
    if (cpu is not None and not cpu.empty) or (ambient is not None and not ambient.empty):
        ax.set_ylabel("°C")
        ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=8, frameon=False)
    else:
        _empty(ax, "No temperature data in this period")
    return _finish(fig, ax, start, end, tz, path)


def protocol_windows(df, start, end, tz, path):
    fig, ax = plt.subplots(figsize=(11, 4.5))
    ax.set_title("Top 10 apps and services, per 6-hour window")
    if df is not None and not df.empty:
        x = mdates.date2num(df.index.to_pydatetime())
        bottom = pd.Series(0.0, index=df.index)
        cmap = plt.get_cmap("tab10")
        for i, p in enumerate(df.columns):
            ax.bar(x, df[p].values, width=(6 / 24) * 0.85, bottom=bottom.values, label=p, color=cmap(i % 10), align="edge")
            bottom = bottom + df[p]
        ax.xaxis_date()
        ax.set_ylabel("GB per 6 hours")
        ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=8, frameon=False)
    else:
        _empty(ax, "No app data in this period")
    return _finish(fig, ax, start, end, tz, path)
