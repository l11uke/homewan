"""Entry point: python -m homewan_tools JOB [--dry-run]"""
import sys

from . import smart, speedtest

JOBS = {"speedtest": speedtest.main, "smart": smart.main}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in JOBS:
        print(f"usage: homewan_tools {{{'|'.join(JOBS)}}} [--dry-run]", file=sys.stderr)
        return 2
    return JOBS[sys.argv[1]](sys.argv[2:]) or 0


if __name__ == "__main__":
    sys.exit(main())
