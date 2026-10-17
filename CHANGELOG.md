# Changelog

## Unreleased

### README, logins and USB 2 detection (homewan-011)

- README rewritten: what homewan needs, the three layouts, install, commands, file locations and a FAQ.
- `homewan secrets` shows each login as address, user and password on separate lines.
- The installer, `homewan doctor` and the weekly report detect a USB Ethernet adapter on a USB 2 connection. Such an adapter reports a gigabit link but carries roughly 200 to 300 Mbps, so the link-speed check alone missed it. The fix text covers USB 2 converters.
- The installer's slow-link advice no longer says every USB 2 adapter tops out at 100 Mbps.
- Test runs can record the installer's menu screens (`HOMEWAN_UI_TRANSCRIPT`), so tests check the text shown.

### Report polish (homewan-010)

- No more `MissingPivotFunction` warnings in the report's output and the system log.
- Dates read "9 Oct", not "09 Oct".

### Fix for re-running set-up (homewan-009)

- `homewan apply` failed at "Setting up the database" on any re-run with "token already exists": the check for ntopng's existing 1.x login read the wrong field. InfluxDB lists a 1.x login's user name under `token`; `userName` is its owner. The test stand-in now behaves like the real server, rejecting a duplicate login.
- `tests/run.sh --quiet` prints one line per test group as it goes.
- Telegraf: `skip_processors_after_aggregators` set explicitly, silencing a start-up warning.

### Set-up progress (homewan-008)

- Set-up now prints numbered steps with the time each took, one line per image downloaded and per build step (with its duration), and a live status line showing the latest output, so long builds visibly progress. `--verbose` on `install.sh` or `homewan apply` prints every line. Everything still goes to `/var/log/homewan/deploy.log`.
- On failure, the last lines of the failing step's output appear on screen.

### Weekly report and daily check (homewan-007)

- Weekly report with the previous project's six charts as attachments (speedtest, internet use, Pi usage, drive space, CPU and outdoor temperature, apps per 6 hours) and the top-10 apps table, plus: plan speed lines and an average-vs-plan table, speedtest data use, data cap status with projection, top devices (layout B), drive status, new drives, and drive health. Warnings appear at the top of the email and in the subject.
- Daily check emails once per event: a drive missing, replaced or back; drive health failing or sector counts rising; data cap at 80%, 100% or projected over.
- `homewan report [--dry-run]`; timers `homewan-report.timer` and `homewan-daily.timer`.
- Charts: day ticks now sit at local midnight, and legends sit beside the plot.

### Fixes from the first real install (homewan-006)

- The installer showed no final screen and no error messages after the setup step started: the deploy log line redirected the whole script's error output to /dev/null.
- `homewan doctor` reported missing data that was arriving: the InfluxDB CLI ignores options after the first plain argument, so a trailing `--token` was never read. The token now goes in the environment. `homewan bucket import` had the same fault.
- The installer and `homewan doctor` now warn when the Pi's own connection is slower than the plan (the speedtest cannot measure past it) or the capture port is slower than both directions of the plan together (traffic gets dropped).
- The test stand-in for InfluxDB now rejects a token passed the wrong way, as the real CLI does.

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
