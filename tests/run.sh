#!/usr/bin/env bash
# shellcheck disable=SC2015  # "check && ok || fail" is deliberate in tests
# Installer tests. Runs install.sh in answers mode against fixture data and
# checks the files it writes. Needs bash, python3 and openssl; changes nothing
# outside a temporary folder.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; CASE=""

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL [%s] %s\n' "$CASE" "$*"; }

# run_case NAME CAPTURE ANSWERS... : runs the installer, leaves output in $ETC
run_case() {
    CASE="$1"; local capture="$2"; shift 2
    ETC="$WORK/$CASE/etc"; FX="$WORK/$CASE/fixtures"
    mkdir -p "$ETC" "$FX"
    cp "$FIX"/pi4/* "$FX"/
    [[ "$capture" != default ]] && cp "$FIX/captures/$capture" "$FX/mirror-capture"
    printf '%s\n' "$@" > "$WORK/$CASE/answers"
    HOMEWAN_TEST=1 HOMEWAN_ETC="$ETC" HOMEWAN_FIXTURES="$FX" \
        bash "$ROOT/install.sh" --answers "$WORK/$CASE/answers" > "$WORK/$CASE/out" 2>&1
    RC=$?
}

# rerun_case: run the installer again on the same ETC with new answers
rerun_case() {
    printf '%s\n' "$@" > "$WORK/$CASE/answers2"
    HOMEWAN_TEST=1 HOMEWAN_ETC="$ETC" HOMEWAN_FIXTURES="$FX" \
        bash "$ROOT/install.sh" --answers "$WORK/$CASE/answers2" > "$WORK/$CASE/out2" 2>&1
    RC=$?
}

expect_rc() { if [[ "$RC" == "$1" ]]; then ok; else fail "exit $RC, expected $1: $(tail -3 "$WORK/$CASE/out")"; fi; }
expect() {   # expect KEY VALUE
    local got; got="$(sed -n "s/^$1='\(.*\)'\$/\1/p" "$ETC/site.conf" 2>/dev/null)"
    if [[ "$got" == "$2" ]]; then ok; else fail "$1='$got', expected '$2'"; fi
}
expect_secret_set() {
    local got; got="$(sed -n "s/^$1='\(.*\)'\$/\1/p" "$ETC/secrets.env" 2>/dev/null)"
    if [[ ${#got} -ge "${2:-1}" ]]; then ok; else fail "secret $1 is '${got}'"; fi
}
expect_mode() { local m; m="$(stat -c %a "$1")"; if [[ "$m" == "$2" ]]; then ok; else fail "$1 mode $m, expected $2"; fi; }

# Answers shared by most cases
BASE=(
    PLAN_DOWN_MBPS=100 PLAN_UP_MBPS=20
    REPORT_TO=someone@example.com REPORT_DAY=Mon REPORT_TIME=08:00
    SMTP_PRESET=gmail SMTP_USER=sender@example.com SMTP_PASSWORD=apppassword SMTP_TEST=yes
    GRAFANA=no SHARED_STORE=no AMBIENT=no
)

echo "Layout A, monthly cap, outdoor temperature, shared store"
run_case layout_a default "${BASE[@]}" \
    GOALS=speed,usage,apps,health,cap HAS_MIRROR=yes LAYOUT=wan_mirror \
    CAP_ENABLED=yes CAP_PERIOD=monthly CAP_RESET_DAY=15 CAP_SPLIT=no CAP_GB=500 \
    AMBIENT=yes LOCATION_SEARCH=Brisbane LOCATION_PICK=1 \
    GRAFANA=yes SHARED_STORE=yes INFLUX_ORG=homelab
expect_rc 0
expect LAYOUT wan_mirror; expect CAPTURE_IFACE eth0; expect MGMT_IFACE eth1; expect LAN_SUBNET 192.168.1.0/24
expect MIRROR_TEST WAN; expect WAN_ENCAP none
expect CAP_ENABLED yes; expect CAP_COUNTS down_up; expect CAP_RESET_DAY 15; expect CAP_GB 500; expect CAP_WARNINGS yes
expect FEATURES report,health,speedtest,capture,ambient,grafana,shared
expect SPEEDTEST_INTERVAL_HOURS 4
expect LOCATION_NAME "Brisbane, Queensland, AU"; expect LOCATION_LAT -27.4679
expect SMTP_HOST smtp.gmail.com; expect SMTP_FROM sender@example.com
expect INFLUX_ORG homelab; expect INFLUX_BIND 127.0.0.1; expect TZ Australia/Brisbane
expect DATA_DIR /var/lib/homewan; expect RETENTION_DAYS 90
expect DISK_MODE all; expect DISK_MOUNTS ""
expect DISK_EXPECTED "/media/usb=1A2B3C4D5E6F7A8B"; expect DISK_WARNINGS yes
expect SMART_DEVICES "usb-Example_External_HDD_0000000001-0:0:sat"
expect INFLUX_PORT 8086; expect NTOPNG_PORT 3001; expect GRAFANA_PORT 3000
expect_secret_set INFLUX_OPERATOR_TOKEN 32; expect_secret_set SMTP_PASSWORD; expect_secret_set GRAFANA_ADMIN_PASSWORD 32
expect_mode "$ETC/secrets.env" 600; expect_mode "$ETC/site.conf" 644
[[ ! -e "$ETC/answers.draft" ]] && ok || fail "draft left behind"
grep -q "apppassword" "$ETC/site.conf" && fail "SMTP password leaked into site.conf" || ok

echo "Reconfigure keeps every answer and every secret when nothing is typed"
cp "$ETC/site.conf" "$WORK/site.before"; cp "$ETC/secrets.env" "$WORK/secrets.before"
rerun_case LOCATION_SEARCH=Brisbane LOCATION_PICK=1
expect_rc 0
diff <(grep -v '^#' "$WORK/site.before") <(grep -v '^#' "$ETC/site.conf") >/dev/null && ok || fail "site.conf changed: $(diff <(grep -v '^#' "$WORK/site.before") <(grep -v '^#' "$ETC/site.conf") | head -5)"
diff "$WORK/secrets.before" "$ETC/secrets.env" >/dev/null && ok || fail "secrets changed on reconfigure"

echo "Layout B with devices, split peak/off-peak cap over rolling 30 days"
run_case layout_b lan "${BASE[@]}" \
    GOALS=speed,usage,apps,devices,health HAS_MIRROR=yes MOST_ON_ROUTER_WIFI=no LAYOUT=lan_mirror \
    CAP_ENABLED=yes CAP_COUNTS=down CAP_PERIOD=rolling_30 CAP_START_DATE=2026-10-01 \
    CAP_SPLIT=yes CAP_PEAK_GB=100 CAP_OFFPEAK_GB=200 CAP_PEAK_HOURS=07:00-01:00 CAP_OVER_ACTION=charged \
    CAP_ADJUST_PERCENT=3 CAP_WARNINGS=no SPEEDTEST_INTERVAL_HOURS=6
expect_rc 0
expect LAYOUT lan_mirror; expect MIRROR_TEST LAN; expect GOALS speed,usage,apps,devices,cap,health
expect CAP_PERIOD rolling_30; expect CAP_START_DATE 2026-10-01; expect CAP_RESET_DAY ""
expect CAP_SPLIT yes; expect CAP_PEAK_GB 100; expect CAP_GB ""; expect CAP_ADJUST_PERCENT 3; expect CAP_WARNINGS no
expect SPEEDTEST_INTERVAL_HOURS 6; expect FEATURES report,health,speedtest,capture

echo "Devices wanted, but most use the router's Wi-Fi: layout A, devices dropped"
run_case wifi_devices default "${BASE[@]}" \
    GOALS=usage,devices,health HAS_MIRROR=yes MOST_ON_ROUTER_WIFI=yes CAP_ENABLED=no
expect_rc 0
expect LAYOUT wan_mirror; expect GOALS usage,health; expect FEATURES report,health,capture

echo "No mirror hardware: continue without capture"
run_case no_mirror default "${BASE[@]}" \
    GOALS=speed,usage,health,cap HAS_MIRROR=no MISSING_PREREQ=continue
expect_rc 0
expect LAYOUT none; expect GOALS speed,health; expect CAP_ENABLED no; expect CAPTURE_IFACE ""
expect FEATURES report,health,speedtest; expect MIRROR_TEST skipped

echo "Mirror sees LAN traffic but layout A was chosen: switch to B"
run_case mismatch lan "${BASE[@]}" \
    GOALS=usage,health HAS_MIRROR=yes LAYOUT=wan_mirror MIRROR_FAIL_ACTION=switch CAP_ENABLED=no
expect_rc 0
expect LAYOUT lan_mirror; expect MIRROR_TEST LAN

echo "Mirror sends nothing: continue without capture"
run_case dead_mirror empty "${BASE[@]}" \
    GOALS=usage,health HAS_MIRROR=yes LAYOUT=wan_mirror MIRROR_FAIL_ACTION=none
expect_rc 0
expect LAYOUT none; expect MIRROR_TEST NO_PACKETS; expect FEATURES report,health

echo "PPPoE connection is detected"
run_case pppoe pppoe "${BASE[@]}" GOALS=usage,health HAS_MIRROR=yes LAYOUT=wan_mirror CAP_ENABLED=no
expect_rc 0
expect WAN_ENCAP pppoe; expect MIRROR_TEST WAN

echo "Custom SMTP server and manual coordinates"
run_case custom_smtp default "${BASE[@]}" \
    GOALS=speed,health SMTP_PRESET=custom SMTP_HOST=mail.example.net SMTP_SECURITY=starttls \
    AMBIENT=yes LOCATION_SEARCH=Nowhere LOCATION_PICK=manual LOCATION_LAT=51.5 LOCATION_LON=-0.12
expect_rc 0
expect SMTP_HOST mail.example.net; expect SMTP_PORT 587; expect SMTP_SECURITY starttls
expect LOCATION_LAT 51.5; expect LOCATION_LON -0.12; expect LAYOUT none

echo "Drives: pick specific drives, no missing-drive warnings, no health checks"
run_case drives_selected default "${BASE[@]}" GOALS=speed,health \
    DISK_MODE=selected DISK_MOUNTS=/ DISK_EXPECTED= SMART_CHECK=no
expect_rc 0
expect DISK_MODE selected; expect DISK_MOUNTS /; expect DISK_EXPECTED ""; expect DISK_WARNINGS no; expect SMART_DEVICES ""

echo "Drives: unmounted drive found, quit to mount it, resume later"
run_case drives_quit default "${BASE[@]}" GOALS=speed,health UNMOUNTED_ACTION=quit
expect_rc 10
[[ -f "$ETC/answers.draft" && ! -f "$ETC/site.conf" ]] && ok || fail "draft not saved on quit"
HOMEWAN_TEST=1 bash -c "source '$ROOT/lib/common.sh'; source '$ROOT/lib/interview.sh'; fstab_hint /dev/sdb1 ext4 5e6f7a8b-0000-4000-8000-00000000000b backup" \
    | grep -q "UUID=5e6f7a8b-0000-4000-8000-00000000000b /media/backup ext4 defaults,nofail,noatime,x-systemd.device-timeout=10s 0 2" && ok || fail "ext4 fstab hint wrong"
rerun_case RESUME_DRAFT=yes UNMOUNTED_ACTION=continue
expect_rc 0
expect REPORT_TO someone@example.com; expect GOALS speed,health
[[ ! -f "$ETC/answers.draft" ]] && ok || fail "draft left after resume"

echo "Drives: NTFS fstab hint uses the ntfs3 driver"
HOMEWAN_TEST=1 bash -c "source '$ROOT/lib/common.sh'; source '$ROOT/lib/interview.sh'; SUDO_UID=1000 SUDO_GID=1000 fstab_hint /dev/sdc1 ntfs ABCD 'My Drive'" > "$WORK/hint"
grep -q "UUID=ABCD /media/My_Drive ntfs3 defaults,nofail,noatime,uid=1000,gid=1000,x-systemd.device-timeout=10s 0 0" "$WORK/hint" && ok || fail "ntfs hint: $(cat "$WORK/hint")"

echo "Bad answers are rejected"
run_case bad_email default "${BASE[@]}" GOALS=speed,health REPORT_TO=not-an-address
[[ "$RC" != 0 ]] && grep -q "REPORT_TO rejected" "$WORK/$CASE/out" && ok || fail "bad email accepted"
run_case bad_quote default "${BASE[@]}" GOALS=speed,health SMTP_USER="it's"
[[ "$RC" != 0 ]] && ok || fail "single quote accepted"

echo "Old monitoring containers stop the installer"
run_case old_stack default "${BASE[@]}" GOALS=speed,health
printf 'influxdb pi-monitor\ngrafana pi-monitor\nplex \n' > "$FX/docker-ps"
rm -rf "$ETC"; mkdir -p "$ETC"
rerun_case GOALS=speed,health
[[ "$RC" == 1 ]] && grep -q "influxdb grafana" "$WORK/$CASE/out2" && ok || fail "old stack not detected (rc $RC)"

echo "Preview mode only warns about old containers"
HOMEWAN_TEST=1 HOMEWAN_FIXTURES="$FX" bash "$ROOT/install.sh" --preview --answers "$WORK/$CASE/answers" > "$WORK/$CASE/out3" 2>&1
[[ $? == 0 && -f /tmp/homewan-preview/site.conf ]] && ok || fail "preview did not finish: $(tail -2 "$WORK/$CASE/out3")"
rm -rf /tmp/homewan-preview

echo "--answers is refused outside the test suite"
HOMEWAN_TEST=0 bash "$ROOT/install.sh" --answers /dev/null >/dev/null 2>&1 && fail "accepted" || ok

echo "Mirror classifier"
CASE=classifier
c() { python3 -I "$ROOT/lib/py/mirror_classify.py" 9.9.9.9 192.168.1.0/24 < "$FIX/captures/$1" | cut -f1,4; }
[[ "$(c lan)" == $'LAN\tno' ]] && ok || fail "lan: $(c lan)"
[[ "$(c noecho)" == $'NO_ECHO\tno' ]] && ok || fail "noecho: $(c noecho)"
[[ "$(c empty)" == $'NO_PACKETS\tno' ]] && ok || fail "empty: $(c empty)"
[[ "$(c pppoe)" == $'WAN\tyes' ]] && ok || fail "pppoe: $(c pppoe)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
