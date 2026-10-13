# Changelog

## Unreleased

### Installer interview (homewan-002)

- `install.sh` runs the read-only checks and the full interview (goals, network layout, mirror test, plan, data cap, report, email, outdoor temperature, Grafana, shared database, storage), shows a summary, and writes `/etc/homewan/site.conf` and `/etc/homewan/secrets.env`. It sets up no services yet.
- Every run asks every question, prefilled with the last answers. Esc saves a draft and quits; the next run offers to resume it.
- The mirror test listens on the capture port while pinging 9.9.9.9 from the management port, and reports which layout the wiring matches, plus PPPoE.
- `tests/run.sh` covers 11 installer scenarios and the mirror classifier.

Initial repository: specification, README and licence.
