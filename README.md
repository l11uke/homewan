# homewan

Monitor your home internet connection from a Raspberry Pi and get a weekly email report: speed over time, how much data your household uses and on what, usage against your plan's data cap, and the health of the Pi itself.

An installer asks about your hardware, your network and your internet plan, tests your wiring, and builds a setup that fits your home. You answer questions; you edit no files.

> [!WARNING]
> homewan is under construction. The installer sets up traffic capture, the speedtest and Pi health monitoring. The weekly email report is not built yet. [SPEC.md](SPEC.md) describes what is being built.

## What you need

| For | You need |
|---|---|
| Everything | A Raspberry Pi 4 or 5 running Raspberry Pi OS 64-bit, and an email account that can send through SMTP |
| Usage totals and usage by app | A managed switch or router with port mirroring, and a second network connection on the Pi (a USB Ethernet adapter, or Wi-Fi) |
| Usage by device | The above, wired so the mirror sees your devices. The installer explains the options. |

Without port mirroring, homewan still tracks your speed and the Pi's health.

## Development

The installer runs end to end against fixture data, without touching the system:

```
bash tests/run.sh --quiet
```

The suite also runs `install.sh --answers`, an option that only works with `HOMEWAN_TEST=1` set, so a real install always asks every question.

## Licence

MIT. See [LICENSE](LICENSE).
