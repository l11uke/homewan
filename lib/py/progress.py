"""Turn docker compose pull/build output into short progress lines.

progress.py [--verbose] < output

Prints one line per image download and per build step (with its duration
when it took 5 seconds or more). On a terminal, the latest raw line shows
on a single self-overwriting status line, so it is visible that work is
happening. --verbose prints every line unchanged.
"""
import os
import re
import shutil
import sys
import time

STEP = re.compile(r"^#(\d+) \[([\w.-]+) +(\d+)/(\d+)\] (.*)$")
DONE = re.compile(r"^#(\d+) DONE (\d+(?:\.\d+)?)s")
CACHED = re.compile(r"^#(\d+) CACHED")
PULLED = re.compile(r"^\s*(?:Image )?(\S+) +(Pulled|Built)\s*$")
ERROR = re.compile(r"(^#\d+ ERROR|^ERROR|failed to solve|error:)", re.I)


def fmt(seconds):
    s = int(round(seconds))
    return f"{s // 60}m{s % 60:02d}s" if s >= 60 else f"{s}s"


def main():
    verbose = "--verbose" in sys.argv
    tty = sys.stdout.isatty() and not verbose
    width = shutil.get_terminal_size((100, 20)).columns - 4
    steps, status_shown, start = {}, False, time.time()

    def out(text):
        nonlocal status_shown
        if status_shown:
            sys.stdout.write("\r\033[K")
            status_shown = False
        print(text, flush=True)

    def status(text):
        nonlocal status_shown
        if tty:
            sys.stdout.write("\r\033[K    " + text[:width - 4])
            sys.stdout.flush()
            status_shown = True

    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if verbose:
            print(line, flush=True)
            continue
        m = STEP.match(line)
        if m and not m.group(5).startswith(("internal]", "load ")):
            sid, svc, i, n, what = m.groups()
            if sid not in steps:
                steps[sid] = svc
                what = re.sub(r"\s+", " ", what).replace("RUN set -eux; ", "RUN ")
                out(f"  [{fmt(time.time() - start):>6}] {svc}: step {i} of {n}: {what[:width - 30]}")
            continue
        m = DONE.match(line)
        if m and m.group(1) in steps:
            if float(m.group(2)) >= 5:
                out(f"           done in {fmt(float(m.group(2)))}")
            continue
        m = PULLED.match(line)
        if m:
            out(f"  [{fmt(time.time() - start):>6}] {m.group(1)}: {'downloaded' if m.group(2) == 'Pulled' else 'built'}")
            continue
        if ERROR.search(line):
            out("  " + line)
            continue
        text = re.sub(r"^#\d+ [\d.]+ ", "", line).strip()
        if text:
            status(text)
    if status_shown:
        sys.stdout.write("\r\033[K")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
