# shellcheck shell=bash
# Phase 6 (deploy) and the "apply" command: render files from site.conf,
# set up InfluxDB, ntopng and the capture port, start the containers and
# install the timers. Every step is safe to repeat.

RENDERED="$HOMEWAN_ETC/rendered"
DERIVED_ENV="$RENDERED/derived.env"
HOMEWAN_LOG_DIR="${HOMEWAN_LOG_DIR:-/var/log/homewan}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
NM_CONF="${NM_CONF:-/etc/NetworkManager/conf.d/90-homewan-capture.conf}"
RPS_RULE="${RPS_RULE:-/etc/udev/rules.d/90-homewan-rps.rules}"
SYSFS_NET="${SYSFS_NET:-/sys/class/net}"

declare -gA CONF=()   # site.conf as loaded by deploy and the homewan command

conf_load() {
    CONF=(); SECRETS=()
    [[ -r "$SITE_CONF" ]] || die "no settings yet: run sudo $HOMEWAN_ROOT/install.sh"
    cfg_read "$SITE_CONF" CONF
    cfg_read "$SECRETS_ENV" SECRETS
}
feature() { list_has "${CONF[FEATURES]:-}" "$1"; }

hw_compose() {
    docker compose -p homewan -f "$RENDERED/compose.yml" --env-file "$SECRETS_ENV" "$@"
}

# ---------- rendering ----------

# Mount point holding PATH (or its nearest existing parent).
mount_of() {
    local p="$1"
    while [[ ! -e "$p" && "$p" != / ]]; do p="$(dirname "$p")"; done
    findmnt -n -o TARGET -T "$p" 2>/dev/null || printf '/'
}

derive_values() {
    local restart=unless-stopped mounts=() m
    # Containers on a removable drive must not start before the drive is
    # mounted, so homewan.service (RequiresMountsFor) starts them instead.
    [[ "$(mount_of "${CONF[DATA_DIR]}")" != / ]] && restart=no
    local retention=""; [[ "${CONF[RETENTION_DAYS]:-0}" != 0 ]] && retention="${CONF[RETENTION_DAYS]}d"
    IFS=',' read -ra _m <<<"${CONF[DISK_MOUNTS]:-/}"
    for m in "${_m[@]}"; do [[ -n "$m" ]] && mounts+=("\"$m\""); done
    local h="${CONF[SPEEDTEST_INTERVAL_HOURS]:-4}" cal
    if [[ "$h" == 24 ]]; then cal="*-*-* 03:07:00"; else cal="*-*-* 00/$h:07:00"; fi
    mkdir -p "$RENDERED"
    {
        printf "HOMEWAN_ROOT='%s'\nHOMEWAN_ETC='%s'\nRENDERED='%s'\n" "$HOMEWAN_ROOT" "$HOMEWAN_ETC" "$RENDERED"
        printf "RESTART='%s'\nRETENTION_DURATION='%s'\n" "$restart" "$retention"
        printf "FEAT_CAPTURE='%s'\n" "$(feature capture && echo yes || echo no)"
        printf "FEAT_GRAFANA='%s'\n" "$(feature grafana && echo yes || echo no)"
        printf "FEAT_SPEEDTEST='%s'\n" "$(feature speedtest && echo yes || echo no)"
        printf "FEAT_SMART='%s'\n" "$([[ -n "${CONF[SMART_DEVICES]:-}" ]] && echo yes || echo no)"
        printf "DISK_ALL='%s'\n" "$([[ "${CONF[DISK_MODE]:-all}" == all ]] && echo yes || echo no)"
        printf "TELEGRAF_MOUNTS='%s'\n" "$(join , "${mounts[@]}" | sed 's/,/, /g')"
        printf "SPEEDTEST_CALENDAR='%s'\n" "$cal"
        printf "FEAT_DAILY='%s'\n" "$([[ "${CONF[CAP_WARNINGS]:-}" == yes || "${CONF[DISK_WARNINGS]:-}" == yes ]] && echo yes || echo no)"
    } > "$DERIVED_ENV"
}

render() { py render.py "$HOMEWAN_ROOT/templates/$1" "$RENDERED/$2" "$SITE_CONF" "$DERIVED_ENV"; }

render_all() {
    derive_values
    rm -rf "$RENDERED/grafana" "$RENDERED/systemd"
    render compose.yml.tmpl compose.yml || return 1
    render telegraf.conf.tmpl telegraf.conf || return 1
    if feature grafana; then
        render grafana/datasources.yaml.tmpl grafana/datasources/homewan.yaml || return 1
    fi
    render systemd/homewan.service.tmpl systemd/homewan.service || return 1
    render systemd/homewan-run@.service.tmpl systemd/homewan-run@.service || return 1
    if feature capture; then render systemd/homewan-capture.service.tmpl systemd/homewan-capture.service || return 1; fi
    if feature speedtest; then render systemd/homewan-speedtest.timer.tmpl systemd/homewan-speedtest.timer || return 1; fi
    if [[ -n "${CONF[SMART_DEVICES]:-}" ]]; then render systemd/homewan-smart.timer.tmpl systemd/homewan-smart.timer || return 1; fi
    render systemd/homewan-report.timer.tmpl systemd/homewan-report.timer || return 1
    if grep -q "^FEAT_DAILY='yes'" "$DERIVED_ENV"; then render systemd/homewan-daily.timer.tmpl systemd/homewan-daily.timer || return 1; fi
    chmod -R go-w "$RENDERED"
}

# ---------- host setup ----------

ensure_docker() {
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then return 0; fi
    log "Installing Docker from Docker's package repository..."
    curl -fsSL https://get.docker.com | sh || die "Docker installation failed. See https://docs.docker.com/engine/install/debian/"
    systemctl enable --now docker
}

make_dirs() {
    local d="${CONF[DATA_DIR]}"
    mkdir -p "$d"/influxdb/data "$d"/influxdb/config "$d"/state "$HOMEWAN_LOG_DIR"
    if feature capture; then mkdir -p "$d"/ntopng "$d"/redis; fi
    if feature grafana; then mkdir -p "$d"/grafana; chown 472:0 "$d"/grafana 2>/dev/null || log "could not hand $d/grafana to the Grafana user (uid 472)"; fi
    ln -sfn "$HOMEWAN_ROOT/bin/homewan" "${HOMEWAN_BIN_LINK:-/usr/local/bin/homewan}"
}

# The capture port carries no addresses and is left alone by NetworkManager.
configure_capture_port() {
    local ifc="${CONF[CAPTURE_IFACE]:-}"
    if ! feature capture || [[ -z "$ifc" ]]; then
        rm -f "$NM_CONF"
        return 0
    fi
    [[ "$ifc" != "${CONF[MGMT_IFACE]}" ]] || die "capture port and the Pi's own connection are both $ifc"
    if systemctl is-active --quiet NetworkManager; then
        printf '# Written by homewan: %s receives the mirror and must carry no addresses.\n[keyfile]\nunmanaged-devices=interface-name:%s\n' "$ifc" "$ifc" > "$NM_CONF"
        systemctl reload NetworkManager 2>/dev/null || true
        nmcli device set "$ifc" managed no 2>/dev/null || true
    else
        log "NetworkManager is not running. Make sure nothing else gives $ifc an address."
    fi
}

# ---------- packet processing across cores (RPS) ----------
# Linux handles each network port's incoming packets on one core by default.
# With capture on, a speedtest's traffic arrives twice (on the Pi's own port
# and as the mirrored copy), and that one core saturates long before the
# connection does. Receive packet steering spreads the work over every core.

rps_mask() {
    local n="${HOMEWAN_NPROC:-$(nproc 2>/dev/null || echo 1)}"
    printf '%x' $(( (1 << n) - 1 ))
}

rps_ifaces() {
    printf '%s\n' "${CONF[MGMT_IFACE]:-}"
    if feature capture; then printf '%s\n' "${CONF[CAPTURE_IFACE]:-}"; fi
}

# rps_state IFACE: "ok", "off" (some queue not spread), or "-" (no queues).
rps_state() {
    local want=$(( 16#$(rps_mask) )) q v found=0
    for q in "$SYSFS_NET/$1"/queues/rx-*/rps_cpus; do
        [[ -r "$q" ]] || continue
        found=1
        v="$(tr -d ',\n' < "$q")"; [[ "$v" =~ ^[0-9a-fA-F]+$ ]] || v=0
        (( (16#${v:-0} & want) == want )) || { printf off; return; }
    done
    ((found)) && printf ok || printf -- -
}

configure_rps() {
    local mask; mask="$(rps_mask)"
    local ifaces=() i q
    mapfile -t ifaces < <(rps_ifaces | grep .)
    if [[ "$mask" == 1 || ${#ifaces[@]} -eq 0 ]]; then rm -f "$RPS_RULE"; return 0; fi
    mkdir -p "$(dirname "$RPS_RULE")"
    {
        printf '# Written by homewan: spread incoming packet work over all cores (RPS).\n'
        printf '# Reapplied whenever the port appears, for example after a USB adapter reconnects.\n'
        for i in "${ifaces[@]}"; do
            printf 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="%s", RUN+="/bin/sh -c '"'"'for q in /sys/class/net/%%k/queues/rx-*/rps_cpus; do echo %s > $$q; done'"'"'"\n' "$i" "$mask"
        done
    } > "$RPS_RULE"
    udevadm control --reload 2>/dev/null || true
    # Apply now as well; the rule covers the next boot or reconnect.
    for i in "${ifaces[@]}"; do
        for q in "$SYSFS_NET/$i"/queues/rx-*/rps_cpus; do
            [[ -w "$q" ]] && printf '%s\n' "$mask" > "$q"
        done
    done
    return 0
}

install_units() {
    local f name
    # Remove units homewan no longer needs, then install the current set.
    for f in "$SYSTEMD_DIR"/homewan*; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f")"
        if [[ ! -e "$RENDERED/systemd/$name" ]]; then
            systemctl disable --now "$name" >/dev/null 2>&1 || true
            rm -f "$f"
        fi
    done
    cp "$RENDERED"/systemd/* "$SYSTEMD_DIR"/
    systemctl daemon-reload
    systemctl enable homewan.service >/dev/null 2>&1
    if feature capture; then systemctl enable --now homewan-capture.service >/dev/null 2>&1; fi
    for f in "$RENDERED"/systemd/*.timer; do
        [[ -e "$f" ]] && systemctl enable --now "$(basename "$f")" >/dev/null 2>&1
    done
    return 0
}

# ---------- InfluxDB ----------

# The influx CLI stops reading options at the first plain argument (a query
# or a folder), so the token goes in the environment instead of a trailing --token.
hw_influx() { hw_compose exec -T -e "INFLUX_TOKEN=${SECRETS[INFLUX_OPERATOR_TOKEN]}" influxdb influx "$@"; }

influx_wait() {
    local i
    for ((i = 0; i < 60; i++)); do
        hw_compose exec -T influxdb influx ping >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

bucket_id() {
    hw_influx bucket list --org "${CONF[INFLUX_ORG]}" --name "$1" --json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null
}

# ensure_bucket NAME RETENTION_DAYS (0 = keep forever)
ensure_bucket() {
    local name="$1" r="${2:-0}" id
    [[ "$r" == 0 ]] && r=0 || r="${r}d"
    id="$(bucket_id "$name")"
    if [[ -z "$id" ]]; then
        hw_influx bucket create --org "${CONF[INFLUX_ORG]}" --name "$name" --retention "$r" >/dev/null || return 1
    else
        hw_influx bucket update --id "$id" --retention "$r" >/dev/null || return 1
    fi
}

# token_valid TOKEN: true when InfluxDB knows the token and it is active.
token_valid() {
    [[ -n "$1" ]] || return 1
    hw_influx auth list --org "${CONF[INFLUX_ORG]}" --json 2>/dev/null \
        | TOKEN="$1" python3 -c 'import json,os,sys; t=os.environ["TOKEN"]; sys.exit(0 if any(a.get("token")==t and a.get("status")=="active" for a in json.load(sys.stdin)) else 1)'
}

# ensure_token SECRET_KEY DESCRIPTION PERMISSION_FLAGS...
ensure_token() {
    local key="$1" desc="$2"; shift 2
    token_valid "${SECRETS[$key]:-}" && return 0
    # Replace, so repeated runs never pile up unused tokens.
    local t old
    for old in $(hw_influx auth list --org "${CONF[INFLUX_ORG]}" --json 2>/dev/null \
            | DESC="$desc" python3 -c 'import json,os,sys; [print(a["id"]) for a in json.load(sys.stdin) if a.get("description")==os.environ["DESC"]]' 2>/dev/null); do
        hw_influx auth delete --id "$old" >/dev/null 2>&1
    done
    t="$(hw_influx auth create --org "${CONF[INFLUX_ORG]}" --description "$desc" "$@" --json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')" || return 1
    [[ -n "$t" ]] || return 1
    SECRETS[$key]="$t"
}

# InfluxDB lists a 1.x login with its user name in the "token" field
# ("userName" is the InfluxDB user who owns it, usually admin).
ensure_ntopng_login() {
    local nid="$1" exists
    exists="$(hw_influx v1 auth list --org "${CONF[INFLUX_ORG]}" --json 2>/dev/null \
        | python3 -c 'import json,sys; print("yes" if any(a.get("token")=="ntopng" for a in json.load(sys.stdin)) else "no")' 2>/dev/null)"
    if [[ "$exists" == yes ]]; then
        hw_influx v1 auth set-password --username ntopng --password "${SECRETS[NTOPNG_INFLUX_PASSWORD]}" >/dev/null
    else
        hw_influx v1 auth create --org "${CONF[INFLUX_ORG]}" --username ntopng \
            --password "${SECRETS[NTOPNG_INFLUX_PASSWORD]}" --read-bucket "$nid" --write-bucket "$nid" >/dev/null
    fi
}

setup_influx() {
    hw_compose up -d influxdb >/dev/null 2>&1 || return 1
    influx_wait || { log "InfluxDB did not start. See: homewan logs influxdb"; return 1; }
    local days="${CONF[RETENTION_DAYS]:-0}" nid sid
    ensure_bucket network "$days" && ensure_bucket system "$days" || return 1
    nid="$(bucket_id network)"; sid="$(bucket_id system)"
    ensure_token INFLUX_TOKEN_TELEGRAF homewan-telegraf --write-bucket "$sid" || return 1
    ensure_token INFLUX_TOKEN_SPEEDTEST homewan-speedtest --write-bucket "$nid" || return 1
    ensure_token INFLUX_TOKEN_REPORT homewan-report --read-bucket "$nid" --read-bucket "$sid" || return 1
    if feature grafana; then ensure_token INFLUX_TOKEN_GRAFANA homewan-grafana --read-buckets || return 1; fi
    if feature capture; then ensure_ntopng_login "$nid" || return 1; fi
    NEW_SMTP_PASSWORD="" write_secrets
}

# ---------- ntopng ----------

setup_ntopng() {
    feature capture || return 0
    local port="${CONF[REDIS_PORT]}" i md5
    hw_compose up -d redis >/dev/null 2>&1 || return 1
    for ((i = 0; i < 30; i++)); do
        hw_compose exec -T redis redis-cli -p "$port" ping 2>/dev/null | grep -q PONG && break
        sleep 1
    done
    md5="$(printf '%s' "${SECRETS[NTOPNG_ADMIN_PASSWORD]}" | md5sum | cut -d' ' -f1)"
    local kv=(
        ntopng.prefs.timeseries_driver influxdb
        ntopng.prefs.ts_post_data_url "http://127.0.0.1:${CONF[INFLUX_PORT]}"
        ntopng.prefs.influx_dbname network
        ntopng.prefs.influx_auth_enabled 1
        ntopng.prefs.influx_username ntopng
        ntopng.prefs.influx_password "${SECRETS[NTOPNG_INFLUX_PASSWORD]}"
        ntopng.user.admin.password "$md5"
        ntopng.prefs.admin_password_changed 1
    )
    for ((i = 0; i < ${#kv[@]}; i += 2)); do
        hw_compose exec -T redis redis-cli -p "$port" SET "${kv[i]}" "${kv[i+1]}" >/dev/null || return 1
    done
    # ntopng restores its settings from this file at start-up, which would
    # undo the values above after a password change.
    rm -f "${CONF[DATA_DIR]}/ntopng/runtimeprefs.json"
}

# ---------- the whole sequence ----------

# Progress: deploy prints numbered steps with timings to the terminal, and
# condensed download and build progress. HOMEWAN_VERBOSE=1 (or --verbose)
# streams every line. Everything also goes to deploy.log.
HOMEWAN_VERBOSE="${HOMEWAN_VERBOSE:-0}"
STEP_N=0
STEP_TOTAL=8
STEP_START=0

step() {
    local now; now=$(date +%s)
    if ((STEP_N > 0)); then printf '        finished in %ss\n' $(( now - STEP_START )) >&2; fi
    STEP_N=$((STEP_N + 1)); STEP_START=$now
    printf '\n[%d/%d] %s\n' "$STEP_N" "$STEP_TOTAL" "$1" >&2
    printf '\n== %s %s\n' "$(date '+%F %T')" "$1" >&3
}

# run_logged CMD...: output to deploy.log; on the terminal, condensed progress
# (or everything with HOMEWAN_VERBOSE=1). Returns the command's exit status.
run_logged() {
    local v=""; ((HOMEWAN_VERBOSE)) && v=--verbose
    "$@" 2>&1 | tee -a /dev/fd/3 | py progress.py $v >&2
    return "${PIPESTATUS[0]}"
}

# run_quiet CMD...: output to deploy.log only; on failure, its last lines on the terminal.
run_quiet() {
    # Functions run in this shell (no pipe), so the values they set survive.
    if ((HOMEWAN_VERBOSE)); then "$@" > >(tee -a /dev/fd/3 >&2) 2>&1; return; fi
    local tmp rc; tmp="$(mktemp)"
    "$@" > "$tmp" 2>&1; rc=$?
    cat "$tmp" >&3
    ((rc == 0)) || { printf '    last output:\n' >&2; tail -15 "$tmp" | sed 's/^/      /' >&2; }
    rm -f "$tmp"
    return $rc
}

fail() { die "$1. Full detail: $HOMEWAN_LOG_DIR/deploy.log"; }

# deploy [--build]: everything apply does; --build rebuilds homewan's images.
deploy() {
    local build="${1:-}" t0; t0=$(date +%s)
    mkdir -p "$HOMEWAN_LOG_DIR"
    # Only file descriptor 3 goes to the log. (exec applies every redirection
    # on its line to the whole script, so nothing else may be redirected here.)
    if [[ -w "$HOMEWAN_LOG_DIR" ]]; then exec 3>>"$HOMEWAN_LOG_DIR/deploy.log"; else exec 3>/dev/null; fi
    STEP_N=0
    printf '\nSetting up homewan. Full detail goes to %s/deploy.log\n' "$HOMEWAN_LOG_DIR" >&2

    step "Checking Docker"; ensure_docker
    conf_load
    step "Preparing folders and settings files"; make_dirs
    render_all || fail "could not render configuration files"
    step "Configuring the network ports"; configure_capture_port; configure_rps

    if [[ "$build" == --build ]] || ! docker image inspect homewan/tools:local >/dev/null 2>&1 \
        || { feature capture && ! docker image inspect homewan/ntopng:local >/dev/null 2>&1; }; then
        step "Downloading images (InfluxDB, Telegraf$(feature capture && printf ', Redis')$(feature grafana && printf ', Grafana'))"
        run_logged hw_compose --progress plain pull --ignore-buildable || fail "could not download images"
        step "Building homewan's own images$(feature capture && printf ' (ntopng takes longest on a Pi)')"
        run_logged hw_compose --progress plain --profile tools build || fail "could not build images"
    else
        step "Images are up to date"
        step "No build needed"
    fi

    step "Setting up the database"; run_quiet setup_influx || fail "database setup failed"
    if feature capture; then
        printf '        buckets, tokens and ntopng'"'"'s login are ready\n' >&2
        run_quiet setup_ntopng || fail "ntopng setup failed"
    fi
    step "Starting homewan"
    run_quiet hw_compose up -d --remove-orphans || fail "containers did not start"
    # Containers that read settings at start-up pick up changes.
    if feature capture; then run_quiet hw_compose restart ntopng; fi
    run_quiet hw_compose restart telegraf
    step "Installing timers"; install_units
    printf '        finished in %ss\n\nSet-up took %s.\n' $(( $(date +%s) - STEP_START )) \
        "$(( ($(date +%s) - t0) / 60 ))m$(( ($(date +%s) - t0) % 60 ))s" >&2
}
