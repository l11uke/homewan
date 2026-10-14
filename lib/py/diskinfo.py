"""Block devices the installer cares about, from `lsblk -J -b`.

diskinfo.py unmounted [FIXTURES]
    Filesystems on attached drives that are not mounted.
    Columns: device, fstype, size GB, UUID, label, model, transport.
diskinfo.py disks [FIXTURES]
    Whole drives that could report SMART health (SD cards and eMMC cannot).
    Columns: device, stable name from /dev/disk/by-id (or -), model, transport, size GB.

FIXTURES is a directory holding lsblk.json and byid.txt ("name target" lines).
"""
import json
import os
import subprocess
import sys

SKIP_FS = {"swap", "LVM2_member", "crypto_LUKS", "linux_raid_member", "zfs_member", "squashfs", ""}


def load(fixtures):
    if fixtures:
        with open(os.path.join(fixtures, "lsblk.json")) as f:
            data = json.load(f)
        byid = {}
        path = os.path.join(fixtures, "byid.txt")
        if os.path.exists(path):
            with open(path) as f:
                for line in f:
                    parts = line.split()
                    if len(parts) == 2:
                        byid.setdefault(parts[1], parts[0])
        return data, byid
    out = subprocess.run(["lsblk", "-J", "-b", "-o",
                          "NAME,PATH,TYPE,FSTYPE,SIZE,MOUNTPOINTS,UUID,LABEL,TRAN,MODEL"],
                         capture_output=True, text=True).stdout
    data = json.loads(out or '{"blockdevices": []}')
    byid = {}
    d = "/dev/disk/by-id"
    if os.path.isdir(d):
        for name in sorted(os.listdir(d)):
            if "-part" in name or name.startswith(("wwn-", "nvme-eui.", "nvme-nvme.")):
                continue
            target = os.path.basename(os.path.realpath(os.path.join(d, name)))
            byid.setdefault(target, name)
    return data, byid


def walk(nodes, parent=None):
    for n in nodes:
        yield n, parent
        yield from walk(n.get("children", []) or [], n)


def mounted(n):
    return any(m for m in (n.get("mountpoints") or []) if m)


def main():
    mode = sys.argv[1]
    fixtures = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
    data, byid = load(fixtures)
    for n, parent in walk(data.get("blockdevices", [])):
        name = n.get("name", "")
        if name.startswith(("loop", "zram", "ram", "mtdblock")):
            continue
        disk = parent if n.get("type") == "part" and parent else n
        tran = disk.get("tran") or "-"
        model = (disk.get("model") or "-").strip()
        size = int(n.get("size") or 0) / 1e9
        if mode == "unmounted":
            fstype = n.get("fstype") or ""
            if n.get("type") not in ("part", "disk") or fstype in SKIP_FS or mounted(n):
                continue
            print("\t".join([n.get("path", "/dev/" + name), fstype, f"{size:.0f}",
                             n.get("uuid") or "-", n.get("label") or "-", model, tran]))
        elif mode == "disks":
            if n.get("type") != "disk" or name.startswith("mmcblk"):
                continue
            print("\t".join([n.get("path", "/dev/" + name), byid.get(name, "-"), model, tran, f"{size:.0f}"]))


if __name__ == "__main__":
    main()
