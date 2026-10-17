# homewan

homewan monitors your home internet connection from a Raspberry Pi and emails you a weekly report. The report covers speed over time, how much data your household uses and on what, usage against your plan's data cap, and the health of the Pi and its drives.

An installer asks about your hardware, network and internet plan, tests your wiring, and sets up homewan to fit. You answer questions; you edit no files.

## What you need

| For | You need |
|---|---|
| Speed history, Pi health, the weekly report | A Raspberry Pi 4 or 5 with Raspberry Pi OS 64-bit, and an email account that sends through SMTP (Gmail, Fastmail, iCloud Mail or any SMTP server) |
| Usage totals, usage by app, data cap tracking | A managed switch or router with port mirroring, and a second network connection on the Pi: a USB 3 gigabit Ethernet adapter, or Wi-Fi |
| Usage by device | The above, wired so the mirror sees your devices (layout B below) |

## Network layouts

The installer explains each layout, recommends one, and tests the wiring before it changes anything.

| Layout | Wiring | Reports |
|---|---|---|
| A | A mirrored switch port between the modem and the router; the Pi's built-in Ethernet port listens to a copy | Every byte to and from the internet: totals, apps, data cap |
| B | A mirrored switch port between the router and your wired devices and access points | Layout A's reports, plus usage per device. Devices on the router's own Wi-Fi stay invisible. |
| C | The Pi on your network as normal | Speed and Pi health |

## Install

```
sudo apt install -y git
sudo git clone https://github.com/l11uke/homewan /opt/homewan
sudo /opt/homewan/install.sh
```

The installer saves your answers as you go. Press Esc on any screen to quit, and run it again to resume. Nothing on the Pi changes until you confirm the summary screen. Set-up then takes 5 to 15 minutes, and ends with a list of checks and an optional first speedtest.

## Commands

Run each command with `sudo`.

| Command | What it does |
|---|---|
| `homewan doctor` | Checks that every service runs, data arrives, timers are set and drives are present |
| `homewan status` | Shows containers, timers and versions |
| `homewan reconfigure` | Asks the installer's questions again, with your current answers filled in, then applies them |
| `homewan apply [--build]` | Rebuilds every file from your settings and restarts what changed; `--build` also rebuilds the images |
| `homewan speedtest` | Runs a speedtest now |
| `homewan report [--dry-run]` | Sends the weekly report now; `--dry-run` saves it to `/var/lib/homewan/state/report-preview/` instead |
| `homewan secrets` | Shows the web logins for ntopng, Grafana and InfluxDB |
| `homewan logs SERVICE` | Shows the last 100 log lines of `influxdb`, `telegraf`, `ntopng`, `redis` or `grafana` |
| `homewan bucket add NAME` | Creates a database bucket for another program on the Pi, with a write-only token |
| `homewan bucket import NAME DIR` | Loads a bucket from an `influx backup` folder |
| `homewan uninstall [--purge]` | Removes homewan; `--purge` also deletes its settings and data |

## Where things live

| Path | Contents |
|---|---|
| `/opt/homewan` | The code |
| `/etc/homewan/site.conf` | Your answers from the installer |
| `/etc/homewan/secrets.env` | Passwords and tokens, readable by root only |
| `/var/lib/homewan` | The database and service data (the installer lets you pick another drive) |
| `/var/log/homewan/deploy.log` | Full output of the last set-up |

## FAQ

**My speedtests come out well below my plan. Why?**
Every speedtest runs through the Pi's own network connection, so they can only measure as fast as that connection. Common limits are a 100 Mbps USB adapter, and a gigabit adapter plugged into a USB 2 port or through a USB 2 converter, which caps it at roughly 200 to 300 Mbps. `homewan doctor` and the weekly report both name the cause when they detect it. Use a gigabit adapter in a blue USB 3 port; `lsusb -t` then shows `5000M` next to it.

**The mirror test sees no packets.**
Check the switch's mirror settings: the source is the port the modem (layout A) or router (layout B) plugs into, the destination is the port the Pi's built-in Ethernet plugs into, and mirroring covers both directions. Then run the installer again.

**Which switches work?**
Any managed switch with port mirroring. Low-cost options include the TP-Link Easy Smart range (for example the TL-SG105E and TL-SG108E) and the Netgear Plus range (for example the GS305E and GS308E). Unmanaged switches have no mirroring.

**Why can't I see usage per device on layout A?**
Your router shares one public address across every device, so the traffic between the modem and the router carries no device identity. Layout B places the mirror on the router's local side, where each device has its own address.

**How much data does homewan use?**
Speedtests use the most: each test uses roughly 10 seconds of traffic at your plan's speed in each direction. The installer shows an estimate before you pick how often to test, and the report shows the measured total each week. Everything else homewan does uses almost nothing.

**Why won't the installer put the database on my NTFS, exFAT or FAT drive?**
The database needs Linux file permissions and a filesystem that survives a power cut, and those filesystems provide neither reliably on Linux. Pick a drive formatted ext4, or keep the default on the SD card. homewan still reports free space on those drives.

**How do I change a setting?**
Run `sudo homewan reconfigure`. Press Enter to keep each answer you want to keep.

**How do I let another program on the Pi store data in homewan's database?**
Turn on the shared store during the installer, then run `sudo homewan bucket add NAME`. It prints the address, organisation and a write-only token for that program to use.

**How do I update homewan?**
```
sudo git -C /opt/homewan pull
sudo homewan apply --build
```

**How do I remove homewan?**
Run `sudo homewan uninstall`. It keeps your settings and data, so a later install can reuse them. `sudo homewan uninstall --purge` deletes both.

## Licence

MIT. See [LICENSE](LICENSE).
