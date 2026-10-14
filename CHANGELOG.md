# Changelog

## Unreleased

### Deployment (homewan-005)

- After the summary, the installer installs Docker if needed, prepares folders, configures the capture port (left unmanaged by NetworkManager, no addresses), renders all files from `site.conf`, builds the ntopng and tools images, sets up InfluxDB (buckets, retention, one scoped token per writer and reader, ntopng's 1.x login), writes ntopng's settings, starts the containers and installs the timers. It then checks that data arrives and offers a first speedtest.
- New `homewan` command: status, doctor, reconfigure, apply, speedtest, run, secrets, logs, bucket list/add/import, up, down, uninstall.
- Jobs: speedtest (Ookla CLI, including data used per test) and drive health (smartctl), run by systemd timers.
- `install.sh --alongside` installs next to an older stack that is still running; a later reconfigure moves homewan to its usual ports.
- Tests: rendering and Compose validation, a full deploy against stand-ins for Docker and InfluxDB (run twice, to prove repeat runs change nothing), Python unit tests. `tests/run.sh --quiet` prints only failures and exits non-zero on any.
- Not yet: the weekly report and the daily check.

### Fixes from the first preview on a Pi (homewan-004)

- Ports: when the usual ports are taken, each service now gets its own free port. Before, ntopng and Grafana could both be given the same one.
- Ticking "data cap" and then answering that the plan has no limit now drops the goal, so the report has no empty cap section.
- The shared database screen shows the port other programs must use, and warns when it is not 8086.
- In preview mode, the final screen says that saving writes settings only.

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
