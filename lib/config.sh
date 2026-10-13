# shellcheck shell=bash
# Reading and writing site.conf, secrets.env and the answers draft.
#
# File format: one KEY='value' per line. Values never contain a single quote
# or a newline (inputs are validated), so bash, systemd EnvironmentFile and
# Docker Compose env files all read them the same way. The files are parsed
# line by line here and never sourced, so a hand-edited file cannot run code.

declare -gA ANS=()      # answers from this run
declare -gA PREV=()     # prefill: draft, else site.conf
declare -gA SECRETS=()  # secrets.env contents
NEW_SMTP_PASSWORD=""    # typed this run; never written to the draft

# site.conf keys in file order, with a section heading before each group.
SITE_LAYOUT=(
    "#Installer" HOMEWAN_CONFIG_VERSION GOALS
    "#Network" LAYOUT CAPTURE_IFACE MGMT_IFACE LAN_SUBNET WAN_ENCAP MIRROR_TEST
    "#Internet plan" PLAN_DOWN_MBPS PLAN_UP_MBPS
    "#Data cap" CAP_ENABLED CAP_COUNTS CAP_PERIOD CAP_RESET_DAY CAP_START_DATE CAP_SPLIT
        CAP_GB CAP_PEAK_GB CAP_OFFPEAK_GB CAP_PEAK_HOURS CAP_OVER_ACTION CAP_ADJUST_PERCENT CAP_WARNINGS
    "#Features" FEATURES SPEEDTEST_INTERVAL_HOURS
    "#Weekly report" REPORT_TO REPORT_DAY REPORT_TIME
    "#Email" SMTP_PRESET SMTP_HOST SMTP_PORT SMTP_SECURITY SMTP_USER SMTP_FROM
    "#Outdoor temperature" LOCATION_NAME LOCATION_LAT LOCATION_LON
    "#Storage and time" TZ DATA_DIR RETENTION_DAYS DISK_MOUNTS
    "#Metrics store" INFLUX_ORG INFLUX_BIND INFLUX_PORT SHARED_BUCKETS
    "#Ports" NTOPNG_PORT GRAFANA_PORT REDIS_PORT
)

SECRET_KEYS=(
    INFLUX_ADMIN_PASSWORD INFLUX_OPERATOR_TOKEN
    INFLUX_TOKEN_TELEGRAF INFLUX_TOKEN_SPEEDTEST INFLUX_TOKEN_REPORT INFLUX_TOKEN_GRAFANA
    NTOPNG_INFLUX_PASSWORD NTOPNG_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD SMTP_PASSWORD
)
# Generated at write time when missing. Scoped InfluxDB tokens are created by
# InfluxDB itself during deployment.
GENERATED_SECRETS=(INFLUX_ADMIN_PASSWORD INFLUX_OPERATOR_TOKEN NTOPNG_INFLUX_PASSWORD NTOPNG_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD)

# cfg_read FILE ARRAY_NAME
cfg_read() {
    local file="$1" line key val
    local -n _into="$2"
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
        _into["$key"]="$val"
    done < "$file"
}

# Load prefill values. A draft newer than site.conf wins, after asking.
cfg_load_prefill() {
    cfg_read "$SITE_CONF" PREV
    cfg_read "$SECRETS_ENV" SECRETS
    if [[ -f "$ANSWERS_DRAFT" && ( ! -f "$SITE_CONF" || "$ANSWERS_DRAFT" -nt "$SITE_CONF" ) ]]; then
        if ui_yesno RESUME_DRAFT "Resume" "You started the installer before and saved your answers.

Use those answers as the starting values?" yes; then
            cfg_read "$ANSWERS_DRAFT" PREV
        fi
    fi
}

# prev KEY FALLBACK -> the prefill value, else FALLBACK
prev() {
    local key="$1" fallback="${2:-}"
    if [[ -v "PREV[$key]" && -n "${PREV[$key]}" ]]; then
        printf '%s' "${PREV[$key]}"
    else
        printf '%s' "$fallback"
    fi
}

valid_value() {
    [[ "$1" != *"'"* && "$1" != *$'\n'* ]]
}

_write_kv_file() {
    local file="$1" mode="$2" tmp
    tmp="$(mktemp "$file.XXXXXX")" || die "cannot write $file"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$file"
}

save_draft() {
    mkdir -p "$HOMEWAN_ETC"
    local k
    {
        printf '# homewan installer answers in progress. Safe to delete.\n'
        for k in "${!ANS[@]}"; do printf "%s='%s'\n" "$k" "${ANS[$k]}"; done | sort
    } | _write_kv_file "$ANSWERS_DRAFT" 600
}

write_site_conf() {
    mkdir -p "$HOMEWAN_ETC"
    chmod 755 "$HOMEWAN_ETC"
    ANS[HOMEWAN_CONFIG_VERSION]="$HOMEWAN_CONFIG_VERSION"
    # Values the installer does not ask about survive a reconfigure.
    local k
    [[ -v "ANS[SHARED_BUCKETS]" ]] || ANS[SHARED_BUCKETS]="$(prev SHARED_BUCKETS)"
    for k in "${!ANS[@]}"; do
        valid_value "${ANS[$k]}" || die "value for $k contains a quote or a line break"
    done
    {
        printf '# homewan site configuration, written by the installer on %s.\n' "$(date '+%Y-%m-%d %H:%M')"
        printf '# Change settings with: sudo homewan reconfigure\n'
        printf '# Hand edits are kept: the next reconfigure starts from these values.\n'
        local item
        for item in "${SITE_LAYOUT[@]}"; do
            if [[ "$item" == "#"* ]]; then
                printf '\n# %s\n' "${item#\#}"
            else
                printf "%s='%s'\n" "$item" "${ANS[$item]:-}"
            fi
        done
    } | _write_kv_file "$SITE_CONF" 644
}

gen_secret() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

write_secrets() {
    mkdir -p "$HOMEWAN_ETC"
    local k
    for k in "${GENERATED_SECRETS[@]}"; do
        if [[ -z "${SECRETS[$k]:-}" || "${ROTATE_SECRETS:-no}" == yes ]]; then
            SECRETS[$k]="$(gen_secret 32)"
        fi
    done
    if [[ -n "$NEW_SMTP_PASSWORD" ]]; then SECRETS[SMTP_PASSWORD]="$NEW_SMTP_PASSWORD"; fi
    {
        printf '# homewan secrets. Root only. Show web logins with: sudo homewan secrets\n'
        for k in "${SECRET_KEYS[@]}"; do printf "%s='%s'\n" "$k" "${SECRETS[$k]:-}"; done
    } | _write_kv_file "$SECRETS_ENV" 600
}
