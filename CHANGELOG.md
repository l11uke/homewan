# Changelog

## Unreleased

### Drives (homewan-003)

- The installer lists drives that are plugged in but not mounted, with the exact `/etc/fstab` line and commands to mount each one at boot (`nofail`, 10-second timeout, `ntfs3` for NTFS). It never edits `/etc/fstab` itself.
- The report covers every mounted drive by default, so drives mounted later appear without a reconfigure. Picking specific drives is still possible.
- Drives that should always be connected are recorded by mount point and filesystem UUID, with an option to email the day one goes missing.
- Drive health: the installer tests each drive with smartctl (installing smartmontools after asking) and offers the drives that respond.

### Installer interview (homewan-002)

- `install.sh` runs the read-only checks and the full interview (goals, network layout, mirror test, plan, data cap, report, email, outdoor temperature, Grafana, shared database, storage), shows a summary, and writes `/etc/homewan/site.conf` and `/etc/homewan/secrets.env`. It sets up no services yet.
- Every run asks every question, prefilled with the last answers. Esc saves a draft and quits; the next run offers to resume it.
- The mirror test listens on the capture port while pinging 9.9.9.9 from the management port, and reports which layout the wiring matches, plus PPPoE.
- `tests/run.sh` covers 11 installer scenarios and the mirror classifier.

Initial repository: specification, README and licence.
