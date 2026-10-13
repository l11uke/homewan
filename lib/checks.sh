# shellcheck shell=bash
# shellcheck disable=SC2034  # globals here are read by the other installer files
# Phase 0: read-only checks of the Pi. Nothing here changes the system.

NET_LINES=()       # netinfo.py output, one interface per line
FS_LINES=()        # fsinfo.py output, one filesystem per line
PORTS_IN_USE=" "   # space-padded list of listening TCP ports
OS_PRETTY=""; OS_ID=""; OS_VERSION=""; ARCH=""; RAM_MB=0
DOCKER_VER=""; NTP_SYNC=""; TZ_DETECTED=""; OLD_STACK=""
CHECK_WARNINGS=()

_fixture_dir() { if is_test; then printf '%s' "$HOMEWAN_FIXTURES"; fi; }

checks_run() {
    local line

    # OS and hardware
    local osr; osr="$(probe os-release cat /etc/os-release)"
    OS_PRETTY="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' <<<"$osr")"
    OS_ID="$(sed -n 's/^ID=//p' <<<"$osr" | tr -d '"')"
    OS_VERSION="$(sed -n 's/^VERSION_ID=//p' <<<"$osr" | tr -d '"')"
    ARCH="$(probe uname-m uname -m)"
    RAM_MB=$(( $(probe meminfo cat /proc/meminfo | awk '/^MemTotal:/ {print $2}') / 1024 ))

    # Network and storage
    mapfile -t NET_LINES < <(py netinfo.py "$(_fixture_dir)")
    mapfile -t FS_LINES < <(py fsinfo.py "$(_fixture_dir)")

    # Ports
    while read -r line; do
        [[ -n "$line" ]] && PORTS_IN_USE+="$line "
    done < <(probe ss ss -Htln | awk '{print $4}' | sed 's/.*://' | sort -un)

    # Docker
    DOCKER_VER="$(probe docker-version docker version --format '{{.Server.Version}}')"
    OLD_STACK="$(probe docker-ps docker ps -a --format '{{.Names}} {{.Label "com.docker.compose.project"}}' \
        | awk '$1 ~ /^(influxdb|grafana|ntopng|telegraf)$/ && $2 != "homewan" {print $1}' | paste -sd' ' -)"

    # Time
    local td; td="$(probe timedatectl timedatectl show -p NTPSynchronized -p Timezone)"
    NTP_SYNC="$(sed -n 's/^NTPSynchronized=//p' <<<"$td")"
    TZ_DETECTED="$(sed -n 's/^Timezone=//p' <<<"$td")"
}

port_free() { [[ "$PORTS_IN_USE" != *" $1 "* ]]; }

# next_free_port START -> first free port at or above START
next_free_port() {
    local p="$1"
    while ! port_free "$p"; do p=$((p + 1)); done
    printf '%s' "$p"
}

# Field accessors for NET_LINES: net_field IFACE COLUMN(1-7)
net_field() {
    local line
    for line in "${NET_LINES[@]}"; do
        if [[ "${line%%$'\t'*}" == "$1" ]]; then
            cut -f"$2" <<<"$line"; return 0
        fi
    done
    return 1
}
net_names() { local l; for l in "${NET_LINES[@]}"; do printf '%s\n' "${l%%$'\t'*}"; done; }

# Hard stops and warnings. Prints the summary screen text.
checks_verdict() {
    local stop="" text=""
    if ! is_test && [[ $EUID -ne 0 ]]; then stop+="Run the installer with sudo."$'\n'; fi
    case "$ARCH" in
        aarch64|x86_64) ;;
        *) stop+="This Pi runs a 32-bit OS ($ARCH). homewan needs 64-bit Raspberry Pi OS."$'\n' ;;
    esac
    if [[ -n "$OLD_STACK" ]] && ((${HOMEWAN_PREVIEW:-0})); then
        CHECK_WARNINGS+=("Containers from an earlier monitoring stack are running: $OLD_STACK. A real install stops here until they are removed.")
    elif [[ -n "$OLD_STACK" ]]; then
        stop+="Containers from an earlier monitoring stack are still here: $OLD_STACK. Remove them first, so homewan can use their ports and network interface."$'\n'
    fi
    if [[ "$OS_ID" != debian && "$OS_ID" != raspbian ]] || [[ "$OS_VERSION" != 12 && "$OS_VERSION" != 13 ]]; then
        CHECK_WARNINGS+=("$OS_PRETTY is untested. homewan is built for Raspberry Pi OS based on Debian 12 or 13.")
    fi
    if (( RAM_MB < 1800 )); then
        CHECK_WARNINGS+=("This Pi has ${RAM_MB} MB of memory. Traffic capture needs 2 GB or more, so the installer will suggest the layout without capture.")
    fi
    if [[ "$NTP_SYNC" != yes ]]; then
        CHECK_WARNINGS+=("The clock is not synchronised with a time server. Charts and schedules depend on it. Check: timedatectl")
    fi
    if [[ -z "$DOCKER_VER" ]]; then
        CHECK_WARNINGS+=("Docker is not installed. The installer will install it from Docker's own package source after you confirm the summary.")
    fi

    text+="System:    $OS_PRETTY, $ARCH, ${RAM_MB} MB memory"$'\n'
    text+="Docker:    ${DOCKER_VER:-not installed}"$'\n'
    text+="Time zone: ${TZ_DETECTED:-unknown}, clock synchronised: ${NTP_SYNC:-unknown}"$'\n\n'
    text+="Network interfaces:"$'\n'
    local l name state v4 metric kind
    for l in "${NET_LINES[@]}"; do
        IFS=$'\t' read -r name state _ v4 metric kind _ <<<"$l"
        text+="  $name ($kind) $state, address ${v4/-/none}"
        [[ "$metric" != "-" ]] && text+=", default route metric $metric"
        text+=$'\n'
    done
    text+=$'\n'"Storage:"$'\n'
    local target fstype src size avail
    for l in "${FS_LINES[@]}"; do
        IFS=$'\t' read -r target fstype src size avail _ <<<"$l"
        text+="  $target  $fstype  ${avail} GB free of ${size} GB"$'\n'
    done
    if ((${#CHECK_WARNINGS[@]})); then
        text+=$'\n'"Warnings:"$'\n'
        local w; for w in "${CHECK_WARNINGS[@]}"; do text+="  - $w"$'\n'; done
    fi
    CHECK_TEXT="$text"
    CHECK_STOP="$stop"
}
