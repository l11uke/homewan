#!/usr/bin/env bash
# shellcheck disable=SC2015  # "check && ok || fail" is deliberate in tests
# Installer tests. Runs install.sh in answers mode against fixture data and
# checks the files it writes. Needs bash, python3 and openssl; changes nothing
# outside a temporary folder.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
WORK="$(mktemp -d)"
trap '[[ -n "${HOMEWAN_TEST_KEEP:-}" ]] && printf "Test files kept in %s\n" "$WORK" || rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; CASE=""
# --quiet: one line per test group, failure details, and the summary.
# Exit status is non-zero on any failure.
GROUP=""; GROUP_FAIL=0
group_end() {
    [[ -n "$GROUP" ]] || return 0
    local r="ok"; ((FAIL > GROUP_FAIL)) && r="$((FAIL - GROUP_FAIL)) FAILED"
    printf '  %-74s %s\n' "${GROUP:0:74}" "$r"
}
if [[ "${1:-}" == --quiet ]]; then echo() { group_end; GROUP="$*"; GROUP_FAIL=$FAIL; }; fi

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

echo "Ports in use: every service still gets its own port"
run_case ports default "${BASE[@]}" GOALS=speed,health
printf 'LISTEN 0 1 0.0.0.0:%s 0.0.0.0:*\n' 3000 3001 8086 6380 >> "$FX/ss"
rm -rf "$ETC"; mkdir -p "$ETC"
rerun_case "${BASE[@]}" GOALS=speed,health
expect INFLUX_PORT 8087; expect NTOPNG_PORT 3002; expect GRAFANA_PORT 3003; expect REDIS_PORT 6381

echo "Cap goal ticked but no data limit: the goal is dropped"
run_case cap_no default "${BASE[@]}" GOALS=speed,usage,cap,health HAS_MIRROR=yes LAYOUT=wan_mirror CAP_ENABLED=no
expect GOALS speed,usage,health; expect CAP_ENABLED no

echo "Slow USB adapter: warn about the speedtest ceiling and the capture port"
run_case slow_link default "${BASE[@]}" GOALS=speed,usage,health HAS_MIRROR=yes LAYOUT=wan_mirror CAP_ENABLED=no PLAN_DOWN_MBPS=740 PLAN_UP_MBPS=42
printf 'eth0 100\neth1 100\n' > "$FX/speed.txt"; rm -rf "$ETC"; mkdir -p "$ETC"
rerun_case "${BASE[@]}" GOALS=speed,usage,health HAS_MIRROR=yes LAYOUT=wan_mirror CAP_ENABLED=no PLAN_DOWN_MBPS=740 PLAN_UP_MBPS=42 LINK_SLOW_ACTION=quit
expect_rc 10
grep -q "after changing the adapter" "$WORK/$CASE/out2" && ok || fail "slow link not reported"
rerun_case "${BASE[@]}" RESUME_DRAFT=yes LINK_SLOW_ACTION=continue
expect_rc 0

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
HOMEWAN_TEST=1 HOMEWAN_FIXTURES="$FX" HOMEWAN_PREVIEW_DIR="$WORK/preview" bash "$ROOT/install.sh" --preview --answers "$WORK/$CASE/answers" > "$WORK/$CASE/out3" 2>&1
[[ $? == 0 && -f "$WORK/preview/site.conf" ]] && ok || fail "preview did not finish: $(tail -2 "$WORK/$CASE/out3")"

echo "--answers is refused outside the test suite"
HOMEWAN_TEST=0 bash "$ROOT/install.sh" --answers /dev/null >/dev/null 2>&1 && fail "accepted" || ok

# render_check NAME: render every file from a case's settings and validate them
render_check() {
    local etc="$WORK/$1/etc"
    HOMEWAN_TEST=1 HOMEWAN_ETC="$etc" HOMEWAN_ROOT="$ROOT" bash -c '
        source "$HOMEWAN_ROOT/lib/common.sh"; source "$HOMEWAN_ROOT/lib/ui.sh"; source "$HOMEWAN_ROOT/lib/config.sh"
        source "$HOMEWAN_ROOT/lib/deploy.sh"; conf_load && render_all' > "$WORK/$1/render.out" 2>&1
}
compose_ok() {
    if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then ok; return; fi
    if docker compose -f "$WORK/$1/etc/rendered/compose.yml" --env-file "$WORK/$1/etc/secrets.env" config -q > "$WORK/$1/compose.out" 2>&1; then ok
    else fail "compose.yml invalid: $(head -3 "$WORK/$1/compose.out")"; fi
}
in_file() { grep -q -- "$2" "$1" && ok || fail "$(basename "$1") lacks: $2"; }
not_in_file() { grep -q -- "$2" "$1" && fail "$(basename "$1") should not contain: $2" || ok; }

echo "Rendering: layout A with Grafana, all drives, drive health"
CASE=render_a
render_check layout_a && ok || fail "render failed: $(tail -3 "$WORK/layout_a/render.out")"
R="$WORK/layout_a/etc/rendered"
compose_ok layout_a
in_file "$R/compose.yml" "homewan/ntopng:local"; in_file "$R/compose.yml" "--interface=eth0"
in_file "$R/compose.yml" "127.0.0.1:8086:8086"; in_file "$R/compose.yml" "DOCKER_INFLUXDB_INIT_ORG: homelab"
in_file "$R/compose.yml" "DOCKER_INFLUXDB_INIT_RETENTION: 90d"; in_file "$R/compose.yml" "grafana/grafana:12.4.12"
in_file "$R/compose.yml" 'restart: "unless-stopped"'
not_in_file "$R/compose.yml" "apppassword"; not_in_file "$R/telegraf.conf" "apppassword"
in_file "$R/telegraf.conf" "ignore_fs"; not_in_file "$R/telegraf.conf" "mount_points"
in_file "$R/telegraf.conf" 'organization = "homelab"'
in_file "$R/grafana/datasources/homewan.yaml" "organization: homelab"
in_file "$R/systemd/homewan.service" "RequiresMountsFor=/var/lib/homewan"
in_file "$R/systemd/homewan-capture.service" "ip link set eth0 up"
in_file "$R/systemd/homewan-speedtest.timer" "OnCalendar=\*-\*-\* 00/4:07:00"
in_file "$R/systemd/homewan-smart.timer" "homewan-run@smart.service"
in_file "$R/systemd/homewan-report.timer" "OnCalendar=Mon \*-\*-\* 08:00:00 Australia/Brisbane"
in_file "$R/systemd/homewan-daily.timer" "homewan-run@daily.service"

echo "Rendering: no capture, selected drives, no Grafana, keep data forever"
CASE=render_c
sed -i "s/^RETENTION_DAYS=.*/RETENTION_DAYS='0'/" "$WORK/drives_selected/etc/site.conf"
render_check drives_selected && ok || fail "render failed: $(tail -3 "$WORK/drives_selected/render.out")"
R="$WORK/drives_selected/etc/rendered"
compose_ok drives_selected
not_in_file "$R/compose.yml" "ntopng"; not_in_file "$R/compose.yml" "grafana"; not_in_file "$R/compose.yml" "INIT_RETENTION"
in_file "$R/telegraf.conf" 'mount_points = \["/"\]'
[[ ! -e "$R/systemd/homewan-capture.service" && ! -e "$R/systemd/homewan-smart.timer" && ! -e "$R/systemd/homewan-daily.timer" ]] && ok || fail "unneeded units rendered"
[[ -e "$R/systemd/homewan-report.timer" ]] && ok || fail "report timer missing"

echo "Deploy against stand-ins for Docker and InfluxDB, twice"
CASE=deploy
D="$WORK/deploy"; mkdir -p "$D/systemd" "$D/bin"
cp -r "$WORK/layout_a/etc" "$D/etc"
sed -i "s#^DATA_DIR=.*#DATA_DIR='$D/data'#" "$D/etc/site.conf"
deploy_run() {
    PATH="$ROOT/tests/stubs:$PATH" STUB_STATE="$D/state.json" STUB_LOG="$D/calls.log" \
    HOMEWAN_ETC="$D/etc" HOMEWAN_ROOT="$ROOT" SYSTEMD_DIR="$D/systemd" NM_CONF="$D/nm.conf" \
    HOMEWAN_LOG_DIR="$D/log" HOMEWAN_BIN_LINK="$D/bin/homewan" bash -c '
        source "$HOMEWAN_ROOT/lib/common.sh"; source "$HOMEWAN_ROOT/lib/ui.sh"; UI_MODE=text
        source "$HOMEWAN_ROOT/lib/config.sh"; source "$HOMEWAN_ROOT/lib/deploy.sh"; source "$HOMEWAN_ROOT/lib/verify.sh"
        deploy --build && verify_all 0 && verify_text' > "$D/out$1" 2>&1
}
deploy_run 1 && ok || fail "first deploy failed: $(tail -3 "$D/out1")"
sec() { sed -n "s/^$1='\(.*\)'\$/\1/p" "$D/etc/secrets.env"; }
[[ -n "$(sec INFLUX_TOKEN_TELEGRAF)" && -n "$(sec INFLUX_TOKEN_SPEEDTEST)" && -n "$(sec INFLUX_TOKEN_REPORT)" && -n "$(sec INFLUX_TOKEN_GRAFANA)" ]] && ok || fail "tokens missing from secrets.env"
[[ "$(sec SMTP_PASSWORD)" == apppassword ]] && ok || fail "SMTP password lost during deploy"
T1="$(sec INFLUX_TOKEN_TELEGRAF)"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if set(s["buckets"])=={"network","system"} and len(s["auths"])==4 and [v["token"] for v in s["v1"]]==["ntopng"] else 1)' "$D/state.json" && ok || fail "buckets/tokens wrong: $(cat "$D/state.json")"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["redis"]; sys.exit(0 if r.get("ntopng.prefs.timeseries_driver")=="influxdb" and r.get("ntopng.prefs.ts_post_data_url")=="http://127.0.0.1:8086" and r.get("ntopng.prefs.admin_password_changed")=="1" and len(r.get("ntopng.user.admin.password",""))==32 else 1)' "$D/state.json" && ok || fail "ntopng settings wrong"
in_file "$D/nm.conf" "unmanaged-devices=interface-name:eth0"
[[ -f "$D/systemd/homewan.service" && -f "$D/systemd/homewan-speedtest.timer" && -f "$D/systemd/homewan-smart.timer" ]] && ok || fail "units not installed"
[[ -d "$D/data/influxdb/data" && -d "$D/data/ntopng" && -L "$D/bin/homewan" ]] && ok || fail "folders or command link missing"
grep -q "pull --ignore-buildable" "$D/calls.log" && grep -q "profile tools build" "$D/calls.log" && ok || fail "images not pulled and built"
grep -q "OK    Pi health data is arriving" "$D/out1" && ok || fail "verify output: $(tail -5 "$D/out1")"
deploy_run 2 && ok || fail "second deploy failed: $(tail -3 "$D/out2")"
[[ "$(sec INFLUX_TOKEN_TELEGRAF)" == "$T1" ]] && ok || fail "second deploy replaced a valid token"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if len(s["auths"])==4 and len(s["v1"])==1 else 1)' "$D/state.json" && ok || fail "second deploy added tokens or logins"
grep -q "v1 auth set-password --username ntopng" "$D/calls.log" && ok || fail "ntopng password not refreshed on second run"

echo "homewan bucket add, against the stand-ins"
CASE=bucket
if [[ $EUID -eq 0 ]]; then
    PATH="$ROOT/tests/stubs:$PATH" STUB_STATE="$D/state.json" STUB_LOG="$D/calls.log" HOMEWAN_ETC="$D/etc" \
        bash "$ROOT/bin/homewan" bucket add media > "$D/bucket.out" 2>&1 && ok || fail "bucket add failed: $(tail -2 "$D/bucket.out")"
    grep -q "^  tok[0-9]" "$D/bucket.out" && ok || fail "no token printed"
    grep -q "^SHARED_BUCKETS='media'$" "$D/etc/site.conf" && ok || fail "SHARED_BUCKETS not updated"
    MID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["buckets"]["media"])' "$D/state.json")"
    grep -q "bucket-media-writer --write-bucket $MID " "$D/calls.log" && ok || fail "token not scoped to the new bucket"
else
    ok; ok; ok; ok  # needs root; covered when the suite runs as root
fi
bash "$ROOT/bin/homewan" help | grep -q "bucket add NAME" && ok || fail "help text"

echo "Host state for the report: expected, missing and new drives, link speeds"
CASE=hoststate
python3 -I "$ROOT/lib/py/hoststate.py" "$WORK/host.json" "/media/usb=1a2b3c4d5e6f7a8b,/media/gone=XYZ" eth1 eth0 "$FIX/pi4" \
    && python3 -c 'import json,sys; h=json.load(open(sys.argv[1])); st={d["mount"]: d["status"] for d in h["drives"]}; sys.exit(0 if st=={"/media/usb":"ok","/media/gone":"missing"} and h["mgmt_link_mbps"]==1000 and h["new_drives"]==[] else 1)' "$WORK/host.json" \
    && ok || fail "host state wrong: $(cat "$WORK/host.json" 2>/dev/null)"

echo "homewan report --dry-run runs the report job with the report token, mail password and state folder"
CASE=report_cmd
if [[ $EUID -eq 0 ]]; then
    PATH="$ROOT/tests/stubs:$PATH" STUB_STATE="$D/state.json" STUB_LOG="$D/calls.log" HOMEWAN_ETC="$D/etc" HOST_STATE_FIXTURES="$FIX/pi4" \
        bash "$ROOT/bin/homewan" report --dry-run > "$D/report.out" 2>&1 && ok || fail "report command failed: $(tail -2 "$D/report.out")"
    grep -E "^run .*-v $D/data/state:/state .*INFLUX_TOKEN_REPORT=tok.* .*SMTP_PASSWORD=apppassword .*homewan/tools:local report --dry-run" "$D/calls.log" >/dev/null && ok || fail "docker run arguments wrong: $(grep '^run' "$D/calls.log" | tail -1 | cut -c1-200)"
    [[ -f "$D/data/state/host.json" ]] && ok || fail "host.json not written"
else
    ok; ok; ok
fi

echo "Progress filter: one line per download and build step, with durations"
CASE=progress
P="$(python3 -I "$ROOT/lib/py/progress.py" < "$FIX/progress/build.txt")"
grep -q "influxdb: downloaded" <<<"$P" && grep -q "ntopng: step 2 of 3: RUN apt-get update" <<<"$P" \
    && grep -q "done in 2m31s" <<<"$P" && grep -q "homewan/tools:local: built" <<<"$P" \
    && ! grep -q "Setting up ntopng" <<<"$P" && ok || fail "progress output: $P"
[[ "$(python3 -I "$ROOT/lib/py/progress.py" --verbose < "$FIX/progress/build.txt" | wc -l)" == "$(wc -l < "$FIX/progress/build.txt")" ]] && ok || fail "--verbose drops lines"

echo "Python unit tests"
CASE=python
if (cd "$ROOT" && python3 -m unittest -q tests.test_python > "$WORK/python.out" 2>&1); then ok; else fail "$(tail -5 "$WORK/python.out")"; fi

echo "Report and daily check tests"
CASE=report
if python3 -c "import pandas, matplotlib" 2>/dev/null; then
    (cd "$ROOT" && python3 -m unittest -q tests.test_report > "$WORK/report.out" 2>&1) && ok || fail "$(tail -8 "$WORK/report.out")"
elif command -v docker >/dev/null && docker image inspect homewan/tools:local >/dev/null 2>&1 \
        && docker run --rm --entrypoint python homewan/tools:local -c "import pandas" >/dev/null 2>&1; then
    # On a Pi without pandas, run them inside homewan's tools image.
    docker run --rm --entrypoint python -v "$ROOT:/src:ro" -w /src -e PYTHONDONTWRITEBYTECODE=1 homewan/tools:local \
        -m unittest -q tests.test_report > "$WORK/report.out" 2>&1 && ok || fail "$(tail -8 "$WORK/report.out")"
else
    printf '  note: report tests skipped (needs pandas and matplotlib, or the homewan/tools image)\n'
    ok
fi

echo "Mirror classifier"
CASE=classifier
c() { python3 -I "$ROOT/lib/py/mirror_classify.py" 9.9.9.9 192.168.1.0/24 < "$FIX/captures/$1" | cut -f1,4; }
[[ "$(c lan)" == $'LAN\tno' ]] && ok || fail "lan: $(c lan)"
[[ "$(c noecho)" == $'NO_ECHO\tno' ]] && ok || fail "noecho: $(c noecho)"
[[ "$(c empty)" == $'NO_PACKETS\tno' ]] && ok || fail "empty: $(c empty)"
[[ "$(c pppoe)" == $'WAN\tyes' ]] && ok || fail "pppoe: $(c pppoe)"

group_end
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
