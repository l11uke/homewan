"""Entry point: python -m homewan_tools JOB [--dry-run]"""
import sys

from . import smart, speedtest


def _report(args):
    from .report import weekly
    return weekly.main(args)


def _daily(args):
    from .report import daily
    return daily.main(args)


JOBS = {"speedtest": speedtest.main, "smart": smart.main, "report": _report, "daily": _daily}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in JOBS:
        print(f"usage: homewan_tools {{{'|'.join(JOBS)}}} [--dry-run]", file=sys.stderr)
        return 2
    return JOBS[sys.argv[1]](sys.argv[2:]) or 0


if __name__ == "__main__":
    sys.exit(main())
