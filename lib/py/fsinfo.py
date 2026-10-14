"""List real filesystems as tab-separated lines.

Columns: mount point, filesystem type, device, size GB, free GB,
data_ok (yes|no), reason, filesystem UUID (or -).

Reads `findmnt -J -b`, or findmnt.json from a fixture directory.
"""
import json
import os
import subprocess
import sys

REAL = {"ext2", "ext3", "ext4", "xfs", "btrfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk"}
DATA_OK = {"ext4", "xfs", "btrfs", "f2fs"}


def walk(nodes):
    for n in nodes:
        yield n
        yield from walk(n.get("children", []))


def main():
    fixtures = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
    if fixtures:
        with open(os.path.join(fixtures, "findmnt.json")) as f:
            data = json.load(f)
    else:
        out = subprocess.run(["findmnt", "-J", "-b", "-o", "TARGET,SOURCE,FSTYPE,SIZE,AVAIL,UUID"],
                             capture_output=True, text=True).stdout
        data = json.loads(out or '{"filesystems": []}')
    for n in walk(data.get("filesystems", [])):
        fstype = n.get("fstype", "")
        source = n.get("source", "") or ""
        target = n.get("target", "")
        if fstype not in REAL or not source.startswith("/dev/"):
            continue
        if target.startswith("/boot"):
            continue
        size = int(n.get("size") or 0) / 1e9
        avail = int(n.get("avail") or 0) / 1e9
        if fstype in DATA_OK:
            ok, why = "yes", "-"
        elif fstype in ("ntfs", "ntfs3", "fuseblk"):
            ok, why = "no", "NTFS can corrupt a database after a power cut and handles Linux permissions poorly"
        else:
            ok, why = "no", f"{fstype} has no Linux permissions and corrupts easily"
        uuid = n.get("uuid") or "-"
        print(f"{target}\t{fstype}\t{source}\t{size:.0f}\t{avail:.1f}\t{ok}\t{why}\t{uuid}")


if __name__ == "__main__":
    main()
