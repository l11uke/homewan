# shellcheck shell=bash
# Phase 7: check that what was set up works. Also used by "homewan doctor".

VERIFY_LINES=()
VERIFY_FAILED=0
vpass() { VERIFY_LINES+=("  OK    $1"); }
vfail() { VERIFY_LINES+=("  FAIL  $1"); VERIFY_FAILED=$((VERIFY_FAILED + 1)); }
vnote() { VERIFY_LINES+=("  --    $1"); }

# recent_points BUCKET MEASUREMENT_FILTER MINUTES -> number of points
recent_points() {
    hw_influx query --org "${CONF[INFLUX_ORG]}" --raw \
        "from(bucket: \"$1\") |> range(start: -$3m) |> filter(fn: (r) => $2) |> group() |> count()" 2>/dev/null \
        | awk -F, '$0 !~ /^#/ && NF > 1 && $NF ~ /^[0-9]+\r?$/ {sub(/\r/, "", $NF); n += $NF} END {print n + 0}'
}

wait_points() { # wait_points BUCKET FILTER MINUTES SECONDS: check now, then every 10 s
    local waited=0
    while true; do
        (( $(recent_points "$1" "$2" "$3") > 0 )) && return 0
        (( waited >= $4 )) && return 1
        sleep 10; waited=$((waited + 10))
    done
}

verify_all() {
    local wait_secs="${1:-120}" svc state
    VERIFY_LINES=(); VERIFY_FAILED=0
    local services=(influxdb telegraf)
    feature capture && services+=(redis ntopng)
    feature grafana && services+=(grafana)
    for svc in "${services[@]}"; do
        state="$(hw_compose ps --format '{{.State}}' "$svc" 2>/dev/null | head -1)"
        if [[ "$state" == running ]]; then vpass "$svc is running"; else vfail "$svc is ${state:-not running} (homewan logs $svc)"; fi
    done

    if wait_points system 'r._measurement == "cpu"' 5 "$wait_secs"; then
        vpass "Pi health data is arriving"
    else
        vfail "no Pi health data in the last 5 minutes (homewan logs telegraf)"
    fi

    if feature capture; then
        if curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${CONF[NTOPNG_PORT]}/lua/login.lua"; then
            vpass "ntopng answers on port ${CONF[NTOPNG_PORT]}"
        else
            vfail "ntopng does not answer on port ${CONF[NTOPNG_PORT]} (homewan logs ntopng)"
        fi
        if (( $(recent_points network 'r._measurement =~ /^iface:/' 15) > 0 )); then
            vpass "traffic data from ntopng is arriving"
        else
            vnote "no traffic data from ntopng yet; it writes every few minutes. Check later with: sudo homewan doctor"
        fi
    fi

    if feature speedtest; then
        if (( $(recent_points network 'r._measurement == "speedtest"' $(( ${CONF[SPEEDTEST_INTERVAL_HOURS]:-4} * 60 + 30 ))) > 0 )); then
            vpass "speedtest results are arriving"
        else
            vnote "no speedtest result yet. Run one now with: sudo homewan speedtest"
        fi
    fi

    local t
    for t in "$SYSTEMD_DIR"/homewan-*.timer; do
        [[ -e "$t" ]] || continue
        t="$(basename "$t")"
        if systemctl is-active --quiet "$t"; then
            vpass "$t, next run $(systemctl show -p NextElapseUSecRealtime --value "$t" 2>/dev/null)"
        else
            vfail "$t is not active"
        fi
    done
}

verify_text() { printf '%s\n' "${VERIFY_LINES[@]}"; }
