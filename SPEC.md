# homewan specification

Version 0.4 (draft for review), 2026-10-14

## 1. Purpose

homewan monitors a home internet connection from a Raspberry Pi and emails a weekly report. It measures speed over time, how much data the household uses and on what, and the health of the Pi itself.

An installer interviews the user, checks their hardware and network, and produces a deployment that fits their home. A person with a Pi, basic SSH skills and an email account can install it without editing files.

## 2. Scope

### 2.1 Features

| Feature | Default | Needs |
|---|---|---|
| Weekly email report | On | An SMTP account (Gmail, Fastmail, iCloud Mail or any SMTP server) |
| Pi health: CPU, memory, disks, temperature | On | Nothing |
| Speedtest | On, every 4 hours | Plan speed, to estimate the data each test uses |
| Traffic capture and protocol breakdown (ntopng) | On when a working mirror is detected | A switch or router with port mirroring, and a second network interface on the Pi |
| Per-device usage | On with layout B only | Layout B wiring |
| Usage against a data cap, with warning emails between reports | On when the plan has a cap | Traffic capture (layout A or B) and the plan's cap rules (section 7.4.1) |
| Outdoor temperature on the report | Off | A town name or coordinates |
| Grafana dashboards | Off | Nothing |
| Shared metrics store for other apps on the Pi | Off | Nothing |

### 2.2 Out of scope for version 1

1. Running the Pi inline between modem and router. A Pi fault would take the household offline.
2. Per-device usage for devices on the router's own Wi-Fi. That traffic never crosses a switch port, so it needs flow export from the router, which few home routers offer.
3. Alerts between reports other than data cap warnings, such as a speed drop. The report and `homewan doctor` cover version 1.
4. Hardware other than a Raspberry Pi 4 or 5. Other arm64 or amd64 Debian machines may work but are untested.

## 3. Supported platform

| Item | Requirement |
|---|---|
| Board | Raspberry Pi 4B or 5. 2 GB RAM minimum, 4 GB recommended with traffic capture. |
| OS | Raspberry Pi OS 64-bit, Debian 13 (trixie). Debian 12 (bookworm) supported on a best-effort basis. |
| Storage | 4 GB free for the data folder. The installer refuses NTFS and exFAT for the data folder, and warns when the data folder is on the SD card that it shortens card life. |
| Network interfaces | Layouts A and B: two. The built-in Ethernet port captures; the second interface (USB Ethernet adapter or Wi-Fi) carries the Pi's own traffic. Layout C: one. |
| Time | NTP synchronised. The installer checks `timedatectl`. |

## 4. Network layouts

The installer explains all three layouts, recommends one from the user's answers, and then tests the wiring.

### 4.1 Layout A: mirror between modem and router

```
modem ── [switch port 1, mirrored] ── [switch port 2] ── router ── home network
                    │
             [switch port 3] ── Pi capture interface (no IP address)
```

Sees every byte between the home and the internet. Reports total usage, protocol breakdown and speedtest traffic. Cannot attribute traffic to devices, because the router hides every device behind its public address.

Needs a managed switch with port mirroring between the modem and the router.

### 4.2 Layout B: mirror on the router's LAN side

```
modem ── router ── [switch port 1, mirrored] ── [switch ports 4-8] ── wired devices, access points
                                │
                         [switch port 3] ── Pi capture interface (no IP address)
```

Sees traffic between the router and everything plugged into the switch, with each device's address. Reports usage per device in addition to everything in layout A.

Misses all traffic from devices on the router's own Wi-Fi. Fits homes where the router's Wi-Fi is off and access points connect through the switch, or where most heavy users are wired. The installer states this limit in plain words before the user picks B.

### 4.3 Layout C: no capture

The Pi connects to the network normally. Reports speedtest results and Pi health. Needs no extra hardware.

### 4.4 Choosing a layout

The installer asks:

1. Do you have a managed switch, or a router, that supports port mirroring? No: layout C.
2. Do you want usage per device? No: layout A.
3. Do most devices use the router's own Wi-Fi? Yes: layout A, with the per-device limit explained. No: layout B.

The user can override the recommendation.

### 4.5 Mirror test

After wiring, the installer confirms that the mirror works and identifies which layout it matches:

1. Start `tcpdump` on the capture interface for 15 seconds.
2. Send 5 ICMP echo requests from the management interface to a fixed public address.
3. Read the capture:
   1. No packets at all: the interface has no link or the mirror is off.
   2. Packets, but none of the test echoes: the mirror is on the wrong port.
   3. Test echoes with a private source address in the LAN subnet: layout B.
   4. Test echoes with a public or carrier-grade NAT (100.64.0.0/10) source address: layout A.
   5. PPPoE frames present: record it in `site.conf` and confirm ntopng decodes them.
4. Report the result in plain words. On a mismatch with the chosen layout, offer to switch layouts, retry, or continue as layout C.

## 5. Architecture

### 5.1 Components

Everything runs in one Docker Compose project named `homewan`. The host runs Docker and two systemd timers that start one-off containers. No Python packages or other software are installed on the host, apart from Docker, `tcpdump` and `whiptail`.

| Service | Image | Profile | Network | Role |
|---|---|---|---|---|
| influxdb | `influxdb:2.7.x`, pinned | always | bridge, port 8086 published on `INFLUX_BIND` | Stores all metrics |
| telegraf | `telegraf:1.x`, pinned | always | bridge | Pi health metrics to the `system` bucket |
| redis | `redis:7.x-alpine`, pinned | capture | host, 127.0.0.1:`REDIS_PORT` | ntopng's settings and cache |
| ntopng | `homewan/ntopng`, built locally from ntop's official arm64 packages, pinned version | capture | host | Captures traffic, writes to the `network` bucket |
| grafana | `grafana/grafana:12.x`, pinned | grafana | bridge, port `GRAFANA_PORT` | Optional dashboards |
| tools | `homewan/tools`, built locally: Python 3.13 slim, Ookla CLI, report package | run on demand | bridge | `speedtest` and `report` commands |

### 5.2 Data flow

```
mirror ──► ntopng ───────────────────────► influxdb: network
homewan-speedtest.timer ──► tools speedtest ──► influxdb: network
telegraf ────────────────────────────────► influxdb: system
homewan-report.timer ──► tools report ──reads network, system──► SMTP ──► recipient
other apps (optional) ───────────────────► influxdb: their own bucket
```

### 5.3 Files on the Pi

| Path | Contents | Owner and mode |
|---|---|---|
| `/opt/homewan` | Git checkout of a tagged release | root, 755 |
| `/etc/homewan/site.conf` | Every setting from the interview | root, 644 |
| `/etc/homewan/secrets.env` | Generated passwords and tokens, SMTP password | root, 600 |
| `/etc/homewan/devices.csv` | Optional MAC address to device name map, layout B | root, 644 |
| `/etc/homewan/rendered/` | Files generated from templates: telegraf.conf, Grafana provisioning | root, 755 |
| `DATA_DIR` (default `/var/lib/homewan`) | influxdb, redis, ntopng and grafana data, as bind mounts | root, 755 |
| `/etc/systemd/system/homewan-*.{service,timer}` | Rendered timer units | root, 644 |
| `/usr/local/bin/homewan` | Symlink to `/opt/homewan/bin/homewan` | root |

The repo holds code and templates only. No file in the repo holds a value specific to one home.

## 6. Configuration model

### 6.1 Rules

1. Every value specific to a home comes from an answer in the interview. The installer asks every question on every run of `install.sh` and `homewan reconfigure`, including on a reinstall over an existing configuration. On those runs, current values prefill each answer, so pressing Enter keeps them. Only commands that change no settings (`apply`, `update`, `status`, `doctor`) skip the interview.
2. The installer writes `site.conf` and `secrets.env` from the answers. Hand edits survive, because `homewan apply` re-renders everything from these two files, and the next interview prefills from them.
3. Both files use `KEY=value` lines, so bash, systemd `EnvironmentFile` and Compose `--env-file` read them without a parser.
4. Every other configuration file is rendered from a template in `/opt/homewan/templates` into `/etc/homewan/rendered`.
5. Fixed names (bucket names, measurement names) live in code.
6. `site.conf` starts with `HOMEWAN_CONFIG_VERSION`. A newer release migrates older files on `homewan update`.
7. The installer generates every password and token with `openssl rand`. The user types only their SMTP password. A reinstall keeps existing generated secrets unless the user asks to rotate them.

### 6.2 site.conf keys

| Key | Example | Set by |
|---|---|---|
| `HOMEWAN_CONFIG_VERSION` | `1` | Installer |
| `GOALS` | `speed,usage,apps,cap,health` | Interview, phase 1 |
| `LAYOUT` | `wan_mirror`, `lan_mirror` or `none` | Interview |
| `CAPTURE_IFACE` | `eth0` | Interview, from detected interfaces |
| `MGMT_IFACE` | `eth1` | Interview, defaults to the interface with the lowest-metric default route |
| `LAN_SUBNET` | `192.168.1.0/24` | Detected from `MGMT_IFACE` |
| `WAN_ENCAP` | `none` or `pppoe` | Mirror test |
| `MIRROR_TEST` | `WAN`, `LAN`, `NO_PACKETS`, `NO_ECHO`, `OTHER` or `skipped` | Mirror test result |
| `TZ` | `Australia/Brisbane` | Detected, confirmed |
| `DATA_DIR` | `/var/lib/homewan` | Interview |
| `INFLUX_ORG` | `homewan` | Default, editable |
| `INFLUX_BIND` | `127.0.0.1` | Default. `0.0.0.0` when the user opts to reach InfluxDB from other machines. |
| `INFLUX_PORT` | `8086` | Default, moved when in use |
| `RETENTION_DAYS` | `90` | Interview |
| `FEATURES` | `report,health,speedtest,capture` | Interview |
| `SPEEDTEST_INTERVAL_HOURS` | `4` | Interview, with estimated monthly data use shown |
| `PLAN_DOWN_MBPS`, `PLAN_UP_MBPS` | `100`, `20` | Interview |
| `CAP_ENABLED` | `yes` or `no` | Interview |
| `CAP_COUNTS` | `down` or `down_up` | Interview |
| `CAP_PERIOD` | `monthly`, `rolling_30` or `daily` | Interview |
| `CAP_RESET_DAY` | `1`, monthly periods only | Interview |
| `CAP_START_DATE` | `2026-10-01`, `rolling_30` periods only | Interview |
| `CAP_SPLIT` | `yes` or `no` | Interview |
| `CAP_GB` | `500`. The total allowance when the plan has no peak and off-peak split. | Interview |
| `CAP_PEAK_GB`, `CAP_OFFPEAK_GB` | `100`, `200` | Interview, split plans only |
| `CAP_PEAK_HOURS` | `07:00-01:00` | Interview, split plans only |
| `CAP_OVER_ACTION` | `slowed`, `charged` or `cut_off` | Interview |
| `CAP_ADJUST_PERCENT` | `0` | Interview, optional |
| `CAP_WARNINGS` | `yes` or `no` | Interview |
| `REPORT_DAY`, `REPORT_TIME` | `Mon`, `08:00`, in `TZ` | Interview |
| `REPORT_TO` | `someone@example.com` | Interview, comma-separated list allowed |
| `SMTP_PRESET` | `gmail`, `fastmail`, `icloud` or `custom` | Interview |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURITY`, `SMTP_USER`, `SMTP_FROM` | `smtp.gmail.com`, `465`, `ssl` | Interview, from the preset or typed for custom |
| `LOCATION_NAME`, `LOCATION_LAT`, `LOCATION_LON` | `Brisbane`, `-27.47`, `153.03` | Interview, looked up from a town name through the Open-Meteo geocoding API |
| `DISK_MOUNTS` | `/,/media/usb` | Interview, from detected real filesystems |
| `NTOPNG_PORT` | `3001` | Default, moved when in use |
| `GRAFANA_PORT` | `3000` | Default, moved when in use |
| `REDIS_PORT` | `6380` | Default, moved when in use |
| `SHARED_BUCKETS` | `media` | `homewan bucket add` |

### 6.3 secrets.env keys

| Key | Purpose |
|---|---|
| `INFLUX_ADMIN_PASSWORD` | InfluxDB web login for the `admin` user |
| `INFLUX_OPERATOR_TOKEN` | Full control. Used only by the `homewan` command. |
| `INFLUX_TOKEN_TELEGRAF` | Write `system` |
| `INFLUX_TOKEN_SPEEDTEST` | Write `network` |
| `INFLUX_TOKEN_REPORT` | Read `network` and `system` |
| `INFLUX_TOKEN_GRAFANA` | Read all buckets |
| `NTOPNG_INFLUX_PASSWORD` | ntopng's InfluxDB 1.x login, write `network` |
| `NTOPNG_ADMIN_PASSWORD` | ntopng web login |
| `GRAFANA_ADMIN_PASSWORD` | Grafana web login |
| `SMTP_PASSWORD` | Typed by the user |

`homewan secrets` prints the web logins after asking for sudo. Tokens for shared buckets print once, when created.

## 7. Installer

### 7.1 Entry point

```
sudo git clone https://github.com/l11uke/homewan /opt/homewan
sudo /opt/homewan/install.sh
```

The installer is bash with whiptail screens. whiptail ships with Raspberry Pi OS. `install.sh --answers FILE` exists for the automated test suite only: it refuses to run unless `HOMEWAN_TEST=1` is set, so no real install skips the interview.

Each phase saves answers to `/etc/homewan/answers.draft`. Quitting and rerunning resumes where the user stopped. The installer changes nothing on the system before the user confirms the summary in phase 5, apart from installing `tcpdump` for the mirror test after asking.

### 7.2 Phase 0: checks (read-only, no questions)

| Check | Fails when | Result |
|---|---|---|
| Running as root | Not root | Stop |
| Architecture | Not aarch64 or x86_64 | Stop |
| OS | Not Debian 12 or 13 based | Warn |
| RAM | Under 2 GB | Warn, and recommend layout C |
| Interfaces | Lists each with link state, addresses, default route | Shown in phase 2 |
| Docker | Absent or older than 24 | Offer install in phase 6 |
| Ports in use | Any homewan default port taken | Pick the next free port |
| Existing install | `/etc/homewan/site.conf` present | Switch to reconfigure mode |
| Old stacks | Containers named influxdb, grafana, ntopng or telegraf outside homewan | Stop and name them. The user removes them first. |
| Time sync | NTP off | Warn |
| Filesystems | Lists real mounts with type and free space | Shown in phase 4 |

### 7.3 Phase 1: goals and prerequisites

1. Ask what the user wants: speed history, usage totals, usage by app, usage by device, Pi health, a monthly cap check.
2. Map the goals to a feature set and show a checklist of what each one needs (section 2.1), with the hardware it needs and roughly what it costs.
3. The user ticks what they have. Goals whose prerequisites are missing get removed or flagged "set up later". The user can save and quit to buy hardware.

### 7.4 Phase 2: network design

1. Explain the three layouts with the diagrams in section 4 and recommend one (section 4.4).
2. Pick the capture interface. Candidates are interfaces with link and no address. Explain that the capture interface carries no IP address.
3. Pick the management interface. Default: the interface with the lowest-metric default route. Warn when two default routes exist and show which one the speedtest will measure.
4. Show wiring steps for the chosen layout, including the mirror settings for common switches (TP-Link Easy Smart, Netgear Plus) and a generic description for others.
5. Run the mirror test (section 4.5).
6. Ask the plan speeds.
7. Ask about the data cap (section 7.4.1). With layout C, the installer explains that it can't track a cap without traffic capture and skips these questions.

#### 7.4.1 Data cap questions

| # | Question | Answers |
|---|---|---|
| 1 | Does your plan have a data limit? | Yes or no. No skips the rest. |
| 2 | How is it counted? | Downloads only, or downloads plus uploads |
| 3 | What period does it reset on? | Monthly on a set day, every 30 days from a start date, or daily |
| 4 | Is the allowance split into peak and off-peak hours? | No: one total in GB. Yes: the peak allowance, the off-peak allowance and the peak hours. |
| 5 | What happens at the limit? | Slowed down, charged per extra GB, or cut off. Changes only the warning wording. |
| 6 | Optional: adjust homewan's count by a percentage? | Default 0. For users who compare with their ISP's meter and see a steady gap. |
| 7 | Send warning emails between reports? | Default yes (section 8.5) |

The installer explains that homewan's count can differ from the ISP's meter by a few percent, because the two count network overhead differently.

### 7.5 Phase 3: features and schedule

1. Speedtest interval, with the estimated monthly data use for the plan speed. Example: a 100/20 Mbps plan uses about 150 MB a test, so every 4 hours costs about 27 GB a month.
2. Report recipient, day and time.
3. Email provider: Gmail, Fastmail, iCloud Mail or custom. Outlook.com is left out: since September 2024 it requires OAuth sign-in for SMTP, which homewan does not support. Each preset fills host, port and security, and shows how to create an app password. The installer sends a test email from the host before continuing.
4. Outdoor temperature: optional, by town name.
5. Grafana: optional.
6. Shared metrics store: optional, with the InfluxDB org name and bind address.

### 7.6 Phase 4: storage

1. Show real filesystems with type and free space.
2. Recommend a USB SSD on ext4 when present, otherwise the SD card.
3. Refuse NTFS and exFAT for the data folder. For any folder under a removable mount, add a systemd mount dependency, so the stack waits for the drive and never writes into an empty mount-point folder.
4. Ask the retention period, with an estimated size.

### 7.7 Phase 5: summary

One screen lists every choice, the ports, the data folder and the expected data use. Confirming writes `site.conf` and `secrets.env`. Nothing else has changed up to this point.

### 7.8 Phase 6: deploy

1. Install Docker from Docker's apt repository when absent.
2. Configure the capture interface: no IP address, NetworkManager unmanaged, up at boot.
3. Render templates.
4. Build `homewan/ntopng` and `homewan/tools`. This takes several minutes on a Pi 4. The installer shows progress.
5. Start InfluxDB. Its first-start setup creates the org, the admin user and the operator token from `secrets.env`. An init script creates the `network` and `system` buckets with the chosen retention.
6. Create the scoped tokens and ntopng's 1.x login, and write the token values into `secrets.env`.
7. With capture on: start Redis, write ntopng's settings (section 8.1), then start ntopng.
8. Start Telegraf, and Grafana when enabled.
9. Install and enable the timers.

### 7.9 Phase 7: verify

| Check | Pass |
|---|---|
| Containers | Every enabled service running and healthy |
| Telegraf | A point in `system` within 60 seconds |
| ntopng | A point in `network` within 5 minutes |
| Speedtest | One run now, and its point in `network` |
| Report | `homewan report --now` sends, marked as a partial first report |
| Timers | Next run times shown |

The final screen shows the web addresses, where the passwords are, and `homewan doctor` for later checks.

## 8. Implementation notes

### 8.1 ntopng settings without the web interface

ntopng reads its InfluxDB settings from Redis (ntopng source, `scripts/lua/modules/timeseries/ts_utils_core.lua`). The installer sets these before ntopng's first start:

| Redis key | Value |
|---|---|
| `ntopng.prefs.timeseries_driver` | `influxdb` |
| `ntopng.prefs.ts_post_data_url` | `http://127.0.0.1:INFLUX_PORT` |
| `ntopng.prefs.influx_dbname` | `network` |
| `ntopng.prefs.influx_auth_enabled` | `1` |
| `ntopng.prefs.influx_username` | `ntopng` |
| `ntopng.prefs.influx_password` | `NTOPNG_INFLUX_PASSWORD` |
| `ntopng.user.admin.password` | MD5 of `NTOPNG_ADMIN_PASSWORD` |

ntopng supports InfluxDB 2 only through the 1.x compatibility interface. InfluxDB 2.7 maps each bucket to a 1.x database of the same name automatically.

ntopng options: `--interface=CAPTURE_IFACE`, `--http-port=NTOPNG_PORT`, `--local-networks=LAN_SUBNET`, `--redis=127.0.0.1:REDIS_PORT`, `--community`.

### 8.2 Speedtest

The `tools` image downloads the Ookla CLI tarball for the platform at build time, with its checksum pinned. Each run writes `download`, `upload`, `ping`, `jitter`, `packet_loss` and `bytes_used` to the `speedtest` measurement. The report shows speedtest traffic on its own line. nDPI labels it `Ookla`.

### 8.3 Telegraf

`hostname = "homewan"` in the agent section, so every point carries the same host tag across container rebuilds. Disks come from `DISK_MOUNTS` through a read-only `/hostfs` mount with `rslave` propagation. Telegraf runs as root so it can read mounts under `/media`.

### 8.4 Report

The report is a Python package in the `tools` image. Each section is a module that runs only when its feature is on:

| Section | Feature |
|---|---|
| Speed trend against plan speed | speedtest |
| WAN usage, cumulative, with the speedtest share shown separately | capture |
| Data cap: usage this period, allowance left, days left, projected usage at reset from the last 7 days, and speedtest data this period. Peak and off-peak on separate lines for split plans. Labelled "measured by homewan". | capture, cap set |
| Protocol breakdown by 6-hour window, and the top-10 table | capture |
| Top 10 devices by usage | capture, layout B |
| CPU, memory and disk use | health |
| Storage per disk | health |
| CPU temperature, with outdoor temperature when enabled | health |

SMTP settings come from `site.conf`. Charts carry the local time zone from `TZ`.

Flux rules carried over from the previous project:

1. Counter totals use `difference(nonNegative: true) |> sum()` with no daily `aggregateWindow`, which splits at UTC midnight and drops data.
2. A bare `group()` goes directly before `top()`.
3. The InfluxDB client timeout is 60 seconds.

### 8.5 Data cap check

A daily timer, `homewan-capcheck.timer`, runs at 07:00 when `CAP_WARNINGS=yes`. It computes usage for the current period with the same query as the report, applies `CAP_ADJUST_PERCENT`, and emails once per period for each of these events:

1. Usage crosses 80% of an allowance.
2. Usage crosses 100% of an allowance.
3. The 7-day projection exceeds an allowance before the reset date, sent at most once per period.

Each event is recorded in a small state file in `DATA_DIR`, so a warning never repeats within a period. Split plans track peak and off-peak separately.

### 8.6 Shared metrics store

`homewan bucket add NAME [--retention DAYS]` creates a bucket and a write-only token, prints the token once, and adds `NAME` to `SHARED_BUCKETS`. Grafana's data source reads all buckets. `homewan bucket list` shows each bucket, who writes to it and its size.

## 9. The homewan command

| Command | Action |
|---|---|
| `homewan status` | Services, last data point per source, next timer runs |
| `homewan doctor` | Every check from phase 7, plus disk space, mount checks and mirror traffic in the last 5 minutes |
| `homewan reconfigure` | Rerun the full interview with current values prefilled, then apply |
| `homewan apply` | Re-render templates and restart what changed |
| `homewan report --now` | Send the report now |
| `homewan speedtest --now` | Run one speedtest |
| `homewan cap` | Show usage against the cap for the current period |
| `homewan bucket add/list/remove` | Shared buckets |
| `homewan secrets` | Show web logins |
| `homewan backup [PATH]` | Archive `/etc/homewan` and an InfluxDB backup |
| `homewan restore PATH` | Rebuild from a backup on a fresh install. Runs the full interview with the backup's values prefilled, then loads the InfluxDB backup. |
| `homewan update` | Fetch the latest tagged release, migrate config, rebuild, restart |
| `homewan uninstall [--purge]` | Remove containers, images, timers and `/opt/homewan`. Keeps `/etc/homewan` and `DATA_DIR` unless `--purge`. Lists shared buckets and asks before deleting data. |

## 10. Security

1. InfluxDB listens on 127.0.0.1 unless the user opts in to remote access.
2. ntopng and Grafana start with generated passwords and never with admin/admin.
3. Each writer has a token scoped to its bucket. Only the `homewan` command holds the operator token.
4. `secrets.env` is root-only. No command prints a secret unless asked through `homewan secrets`.
5. The repo holds no addresses, MAC addresses or names from any real home. Examples use documentation addresses.

## 11. Repository layout

```
homewan/
├── install.sh                 Entry point
├── bin/homewan                Command-line tool
├── lib/                       Installer and command modules (bash)
│   ├── checks.sh  interview.sh  network.sh  mirror_test.sh
│   ├── render.sh  influx.sh  ntopng.sh  timers.sh  ui.sh
├── compose/compose.yml
├── images/
│   ├── ntopng/Dockerfile
│   └── tools/Dockerfile
├── report/                    Python package: report sections, charts, email
├── templates/                 telegraf.conf, Grafana provisioning, systemd units
├── dashboards/                Grafana dashboards (JSON)
├── docs/                      layouts.md, switches.md, troubleshooting.md, sharing.md
├── tests/                     bats for bash, pytest for the report with fixture data
├── .github/workflows/ci.yml   shellcheck, bats, pytest, arm64 image builds
├── SPEC.md  README.md  CHANGELOG.md  LICENSE (MIT)
```

## 12. To verify during build

1. ntop's arm64 trixie packages install in a `debian:trixie-slim` image.
2. ntopng accepts the MD5 admin password set through Redis, and whether a second key suppresses the forced password change at first login.
3. ntopng decodes PPPoE on a layout A capture.
4. `influx restore --bucket` loads a bucket backup from another instance into a new instance with the same org name.
5. Compose reads `COMPOSE_PROFILES` from `--env-file`, or the `homewan` command passes `--profile` flags itself.
6. NetworkManager on Raspberry Pi OS 13 keeps an unmanaged capture interface up after reboot.
