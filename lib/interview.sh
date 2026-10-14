# shellcheck shell=bash
# shellcheck disable=SC2153  # ANS[KEY] subscripts look like variables to shellcheck
# Phases 1 to 5 of the installer: the interview. Answers go into ANS.
# Each question prefills from PREV (the last run) where one exists.

# ---------- validators: print an error and return 1 for bad input ----------

v_int_range() { # v_int_range MIN MAX VALUE
    if [[ "$3" =~ ^-?[0-9]+$ ]] && (( $3 >= $1 && $3 <= $2 )); then return 0; fi
    printf 'Enter a whole number from %s to %s.' "$1" "$2"; return 1
}
v_speed()    { v_int_range 1 100000 "$1"; }
v_gb()       { v_int_range 1 1000000 "$1"; }
v_day()      { v_int_range 1 31 "$1"; }
v_adjust()   { v_int_range -20 20 "$1"; }
v_time() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && return 0
    printf 'Enter a 24-hour time such as 08:00.'; return 1
}
v_hours() {
    local a="${1%%-*}" b="${1#*-}"
    if [[ "$1" == *-* ]] && v_time "$a" >/dev/null && v_time "$b" >/dev/null; then
        return 0
    fi
    printf 'Enter a range such as 07:00-01:00 (start-end, 24-hour).'; return 1
}
v_date() {
    if [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" >/dev/null 2>&1; then return 0; fi
    printf 'Enter a date as YYYY-MM-DD.'; return 1
}
v_email() {
    [[ "$1" =~ ^[^@[:space:],\']+@[^@[:space:],\']+\.[^@[:space:],\']+$ ]] && return 0
    printf 'Enter one email address.'; return 1
}
v_emails() {
    local e ok=0
    IFS=',' read -ra _list <<<"${1// /}"
    ((${#_list[@]})) || ok=1
    for e in "${_list[@]}"; do v_email "$e" >/dev/null || ok=1; done
    ((ok == 0)) && return 0
    printf 'Enter one or more email addresses, separated by commas.'; return 1
}
v_nonempty() { [[ -n "$1" ]] && valid_value "$1" && return 0; printf 'This cannot be empty or contain a single quote.'; return 1; }
v_host()     { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] && return 0; printf 'Enter a host name such as smtp.example.com.'; return 1; }
v_port()     { v_int_range 1 65535 "$1"; }
v_lat()      { [[ "$1" =~ ^-?[0-9]{1,2}(\.[0-9]+)?$ ]] && awk -v x="$1" 'BEGIN{exit !(x>=-90 && x<=90)}' && return 0; printf 'Enter a latitude from -90 to 90, such as -27.47.'; return 1; }
v_lon()      { [[ "$1" =~ ^-?[0-9]{1,3}(\.[0-9]+)?$ ]] && awk -v x="$1" 'BEGIN{exit !(x>=-180 && x<=180)}' && return 0; printf 'Enter a longitude from -180 to 180, such as 153.03.'; return 1; }
v_tz() {
    if [[ "$1" == UTC || "$1" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$ ]]; then
        if is_test || [[ -f "/usr/share/zoneinfo/$1" ]]; then return 0; fi
    fi
    printf 'Enter a time zone name such as Australia/Brisbane or Europe/London.'; return 1
}
v_org() { [[ "$1" =~ ^[A-Za-z0-9_-]{2,40}$ ]] && return 0; printf 'Use 2 to 40 letters, digits, - or _.'; return 1; }
v_abspath() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* ]] && return 0; printf 'Enter an absolute path such as /mnt/ssd/homewan.'; return 1; }

# ---------- helpers ----------

goal() { list_has "${ANS[GOALS]:-}" "$1"; }
needs_capture() { goal usage || goal apps || goal devices || goal cap; }
drop_capture_goals() {
    local g out=()
    IFS=',' read -ra _g <<<"${ANS[GOALS]}"
    for g in "${_g[@]}"; do [[ "$g" =~ ^(usage|apps|devices|cap)$ ]] || out+=("$g"); done
    ANS[GOALS]="$(join , "${out[@]}")"
}
gb1() { awk -v mb="$1" 'BEGIN { printf "%.1f", mb / 1000 }'; } # MB -> GB, one decimal
GOAL_ORDER=(speed usage apps devices cap health)
# Keep GOALS in one fixed order, so a reconfigure that changes nothing writes the same file.
normalize_goals() {
    local g out=()
    for g in "${GOAL_ORDER[@]}"; do list_has "${ANS[GOALS]}" "$g" && out+=("$g"); done
    ANS[GOALS]="$(join , "${out[@]}")"
}
add_goal() { ANS[GOALS]+=",$1"; normalize_goals; }
remove_goal() {
    local g out=()
    IFS=',' read -ra _g <<<"${ANS[GOALS]}"
    for g in "${_g[@]}"; do [[ "$g" == "$1" ]] || out+=("$g"); done
    ANS[GOALS]="$(join , "${out[@]}")"
}
onoff() { if list_has "$1" "$2"; then printf on; else printf off; fi; }

# Estimated MB per speedtest: about 10 seconds at full rate in each direction.
speedtest_mb() { echo $(( (ANS[PLAN_DOWN_MBPS] + ANS[PLAN_UP_MBPS]) * 10 / 8 )); }
speedtest_gb_month() { echo $(( $(speedtest_mb) * (24 / $1) * 30 / 1000 )); }

# ---------- phase 1: goals and prerequisites ----------

phase_goals() {
    local pg; pg="$(prev GOALS "speed,usage,apps,health")"
    ui_checklist GOALS "What do you want to know?" \
"Tick what you want homewan to track. The next screens show what each one needs." \
        speed   "Internet speed over time"                 "$(onoff "$pg" speed)" \
        usage   "How much data the household uses"         "$(onoff "$pg" usage)" \
        apps    "Which apps and services use it"            "$(onoff "$pg" apps)" \
        devices "Which devices use it"                      "$(onoff "$pg" devices)" \
        cap     "Usage against my plan's data cap"          "$(onoff "$pg" cap)" \
        health  "The Pi's own health"                       "$(onoff "$pg" health)"
    ANS[GOALS]="$UI_REPLY"
    [[ -n "${ANS[GOALS]}" ]] || ANS[GOALS]="health"
    normalize_goals

    local wired=0 total=${#NET_LINES[@]} l
    for l in "${NET_LINES[@]}"; do [[ "$(cut -f6 <<<"$l")" == wired ]] && wired=$((wired + 1)); done

    local need="Everything:
  - This Pi, and an email account that can send mail (SMTP)."
    if goal speed; then need+="
Internet speed:
  - Nothing extra. Each test uses some of your data allowance; a later screen shows how much."
    fi
    if needs_capture; then need+="
Data usage, apps, devices or data cap:
  - A managed switch or router that supports port mirroring.
  - Two network connections on the Pi: the built-in Ethernet port to receive
    the mirror, and a USB Ethernet adapter or Wi-Fi for the Pi's own traffic.
    This Pi has $total ($wired wired)."
    fi
    if goal devices; then need+="
Devices:
  - The mirror must see your devices' traffic. Devices on the router's own
    Wi-Fi never pass through the switch, so homewan cannot see them by device."
    fi
    ui_msg - "What you will need" "$need"

    if needs_capture; then
        local missing=""
        if ! ui_yesno HAS_MIRROR "Port mirroring" "Do you have a managed switch, or a router, that supports port mirroring (also called SPAN or monitor port)?

Examples: TP-Link Easy Smart (TL-SG105E, TL-SG108E), Netgear Plus (GS105E, GS108E), most business switches. Unmanaged switches cannot mirror." "$(prev HAS_MIRROR yes)"; then
            missing="a switch or router with port mirroring"
        fi
        ANS[HAS_MIRROR]="$UI_REPLY"
        if (( total < 2 || wired < 1 )); then
            missing+="${missing:+ and }a second network connection on the Pi"
        fi
        if [[ -n "$missing" ]]; then
            ui_menu MISSING_PREREQ "Missing hardware" \
"Tracking data usage needs $missing.

You can continue now with speed and Pi health only, and add usage tracking later with: sudo homewan reconfigure" continue \
                continue "Continue with speed and Pi health" \
                quit     "Save my answers and quit, to get the hardware first"
            if [[ "$UI_REPLY" == quit ]]; then save_draft; log "Answers saved. Run the installer again when the hardware is ready."; exit 10; fi
            drop_capture_goals
        fi
    fi
}

# ---------- phase 2: network design ----------

_iface_menu_items() { # _iface_menu_items FILTER(any|wired|ipv4) EXCLUDE
    local l name state v4 metric kind
    for l in "${NET_LINES[@]}"; do
        IFS=$'\t' read -r name state _ v4 metric kind _ <<<"$l"
        [[ "$name" == "$2" ]] && continue
        [[ "$1" == wired && "$kind" != wired ]] && continue
        [[ "$1" == ipv4 && "$v4" == "-" ]] && continue
        local desc="$name: $kind, $state, address ${v4/-/none}"
        [[ "$metric" != "-" ]] && desc+=", default route metric $metric"
        printf '%s\n%s\n' "$name" "$desc"
    done
}

_default_mgmt() {
    local l name metric best="" bestm=999999
    for l in "${NET_LINES[@]}"; do
        name="$(cut -f1 <<<"$l")"; metric="$(cut -f5 <<<"$l")"
        [[ "$metric" == "-" ]] && continue
        (( metric < bestm )) && { best="$name"; bestm="$metric"; }
    done
    printf '%s' "$best"
}

_wiring_text() {
    local cap="${ANS[CAPTURE_IFACE]}"
    case "${ANS[LAYOUT]}" in
        wan_mirror) cat <<EOF
Wire it like this:

  modem ---- switch port 1 (mirrored)
             switch port 2 ---- router WAN port
             switch port 3 ---- Pi $cap (mirror destination)
  the Pi's other connection ---- your home network as normal

In the switch's web page, set up port mirroring:
  Mirrored (source) port: 1      Mirroring (destination) port: 3
  Direction: ingress and egress (both)

TP-Link Easy Smart: Monitoring > Port Mirror.
Netgear Plus: System > Monitoring > Mirroring.
Other switches: look for Port Mirroring, SPAN or Monitor Port.

The switch carries all your internet traffic, so connect it to power the
router can share, and keep the cabling short.
EOF
        ;;
        lan_mirror) cat <<EOF
Wire it like this:

  modem ---- router
  router LAN port ---- switch port 1 (mirrored)
  switch ports 4 and up ---- wired devices and Wi-Fi access points
  switch port 3 ---- Pi $cap (mirror destination)
  the Pi's other connection ---- your home network as normal

In the switch's web page, set up port mirroring:
  Mirrored (source) port: 1      Mirroring (destination) port: 3
  Direction: ingress and egress (both)

TP-Link Easy Smart: Monitoring > Port Mirror.
Netgear Plus: System > Monitoring > Mirroring.
EOF
        ;;
    esac
}

phase_network() {
    # Management interface: the one the Pi uses for its own traffic.
    local dm items=()
    dm="$(_default_mgmt)"
    mapfile -t items < <(_iface_menu_items ipv4 "")
    ((${#items[@]})) || die "no network interface has an IPv4 address. Connect the Pi to your network first."

    if needs_capture; then
        local rec=wan_mirror
        if goal devices; then
            if ui_yesno MOST_ON_ROUTER_WIFI "Where are your devices?" "Do most of your devices connect to the router's own Wi-Fi?

Answer No if the router's Wi-Fi is off and Wi-Fi comes from access points plugged into the switch, or if most heavy users are wired." "$(prev MOST_ON_ROUTER_WIFI yes)"; then
                rec=wan_mirror
                ui_msg - "Per-device usage" "Traffic between the router's Wi-Fi and the internet never crosses a switch port, so no mirror can see it by device.

The recommended layout below shows total usage and usage by app. Per-device usage needs the router's Wi-Fi off and access points on the switch."
            else
                rec=lan_mirror
            fi
            ANS[MOST_ON_ROUTER_WIFI]="$UI_REPLY"
        fi
        ui_menu LAYOUT "Network layout" \
"Where should the Pi watch traffic?

A: between modem and router. Sees all internet traffic: totals, apps, data cap. Cannot tell devices apart.
B: on the router's LAN side. Adds usage per device, but misses everything on the router's own Wi-Fi.
C: no capture. Speed and Pi health only." "$(prev LAYOUT "$rec")" \
            wan_mirror "A: mirror between modem and router$([[ $rec == wan_mirror ]] && printf ' (recommended)')" \
            lan_mirror "B: mirror on the router's LAN side$([[ $rec == lan_mirror ]] && printf ' (recommended)')" \
            none       "C: no capture"
        ANS[LAYOUT]="$UI_REPLY"
    else
        ANS[LAYOUT]=none
    fi
    [[ "${ANS[LAYOUT]}" == none ]] && drop_capture_goals
    if [[ "${ANS[LAYOUT]}" != lan_mirror ]] && goal devices; then
        remove_goal devices
    fi

    local mtext="Which connection should the Pi use for its own traffic: updates, email, and the speedtest?"
    local dcount; dcount="$(printf '%s\n' "${NET_LINES[@]}" | awk -F'\t' '$5 != "-"' | wc -l)"
    (( dcount > 1 )) && mtext+="

The Pi has $dcount default routes. Linux sends traffic through the one with the lowest metric ($dm), so the speedtest measures that path."
    ui_menu MGMT_IFACE "The Pi's own connection" "$mtext" "$(prev MGMT_IFACE "$dm")" "${items[@]}"
    ANS[MGMT_IFACE]="$UI_REPLY"
    ANS[LAN_SUBNET]="$(net_field "${ANS[MGMT_IFACE]}" 7)"

    ANS[CAPTURE_IFACE]=""; ANS[WAN_ENCAP]=none; ANS[MIRROR_TEST]=skipped
    if [[ "${ANS[LAYOUT]}" != none ]]; then
        local citems=()
        mapfile -t citems < <(_iface_menu_items wired "${ANS[MGMT_IFACE]}")
        if ((${#citems[@]} == 0)); then
            ui_msg - "No capture port" "Every wired port is in use as the Pi's own connection, so nothing is free to receive the mirror. Continuing with layout C (no capture)."
            ANS[LAYOUT]=none; drop_capture_goals
        else
            local dc="" l
            for l in "${NET_LINES[@]}"; do
                [[ "$(cut -f1 <<<"$l")" == "${ANS[MGMT_IFACE]}" ]] && continue
                [[ "$(cut -f6 <<<"$l")" == wired && "$(cut -f4 <<<"$l")" == "-" ]] && { dc="$(cut -f1 <<<"$l")"; break; }
            done
            ui_menu CAPTURE_IFACE "Capture port" "Which wired port receives the mirror?

It must carry no IP address. The built-in port (usually eth0) is the best choice: USB adapters can drop packets at high speed." "$(prev CAPTURE_IFACE "${dc:-${citems[0]}}")" "${citems[@]}"
            ANS[CAPTURE_IFACE]="$UI_REPLY"
            if [[ "$(net_field "${ANS[CAPTURE_IFACE]}" 4)" != "-" ]]; then
                ui_yesno CAPTURE_HAS_IP "Capture port has an address" "${ANS[CAPTURE_IFACE]} has an IP address now. During setup homewan removes it, and anything connected through ${ANS[CAPTURE_IFACE]} loses its connection to the Pi.

Continue with ${ANS[CAPTURE_IFACE]}?" no || { phase_network; return; }
            fi
            ui_msg - "Wiring" "$(_wiring_text)"
            phase_mirror_test
        fi
    fi

    ui_input PLAN_DOWN_MBPS "Your internet plan" "Download speed of your plan, in Mbps (for example 100):" "$(prev PLAN_DOWN_MBPS 100)" v_speed
    ANS[PLAN_DOWN_MBPS]="$UI_REPLY"
    ui_input PLAN_UP_MBPS "Your internet plan" "Upload speed of your plan, in Mbps (for example 20):" "$(prev PLAN_UP_MBPS 20)" v_speed
    ANS[PLAN_UP_MBPS]="$UI_REPLY"

    phase_cap
}

phase_mirror_test() {
    while true; do
        if ! ui_yesno RUN_MIRROR_TEST "Mirror test" "Once the wiring and the switch settings are done, homewan checks the mirror: it listens on ${ANS[CAPTURE_IFACE]} for 25 seconds while pinging $MIRROR_TARGET from ${ANS[MGMT_IFACE]}.

Run the test now?" yes; then
            ANS[MIRROR_TEST]=skipped
            ui_msg - "Mirror test skipped" "The test runs again when homewan starts, and with: sudo homewan doctor"
            return
        fi
        ensure_tcpdump || { ANS[MIRROR_TEST]=skipped; return; }
        ui_info "Listening on ${ANS[CAPTURE_IFACE]} for 25 seconds..."
        mirror_test "${ANS[CAPTURE_IFACE]}" "${ANS[MGMT_IFACE]}" "${ANS[LAN_SUBNET]}"
        ANS[MIRROR_TEST]="$MIRROR_VERDICT"
        [[ "$MIRROR_PPPOE" == yes ]] && ANS[WAN_ENCAP]=pppoe || ANS[WAN_ENCAP]=none

        local expect=WAN; [[ "${ANS[LAYOUT]}" == lan_mirror ]] && expect=LAN
        local msg
        case "$MIRROR_VERDICT" in
            "$expect")
                msg="The mirror works. $MIRROR_PACKETS packets arrived, including the test pings from $MIRROR_SRC."
                [[ "$MIRROR_PPPOE" == yes ]] && msg+=" Your connection uses PPPoE; homewan handles that."
                ui_msg - "Mirror test passed" "$msg"; return ;;
            NO_PACKETS) msg="Nothing arrived on ${ANS[CAPTURE_IFACE]}. Check the cable to the mirror port, and that mirroring is switched on and saved in the switch." ;;
            NO_ECHO)    msg="$MIRROR_PACKETS packets arrived, but none of the test pings. The mirror is probably on the wrong source port."
                        [[ "${ANS[LAYOUT]}" == lan_mirror && "$(net_field "${ANS[MGMT_IFACE]}" 6)" == wireless ]] && \
                            msg+=" Also: the Pi's own connection is Wi-Fi. If that is the router's Wi-Fi, its pings never cross the switch." ;;
            WAN)        msg="The mirror works, but it sees traffic between modem and router (source $MIRROR_SRC is a public address). That is layout A, and you chose B." ;;
            LAN)        msg="The mirror works, but it sees traffic inside your network (source $MIRROR_SRC). That is layout B, and you chose A." ;;
            *)          msg="Test pings arrived from $MIRROR_SRC, which is neither your network (${ANS[LAN_SUBNET]}) nor a public address. Check the wiring against the diagram." ;;
        esac
        local options=(retry "Fix the wiring or settings, then test again")
        [[ "$MIRROR_VERDICT" == WAN ]] && options+=(switch "Switch to layout A, which matches the wiring")
        [[ "$MIRROR_VERDICT" == LAN ]] && options+=(switch "Switch to layout B, which matches the wiring")
        options+=(skip "Continue anyway; check later with homewan doctor" none "Continue without capture (layout C)")
        ui_menu MIRROR_FAIL_ACTION "Mirror test" "$msg" retry "${options[@]}"
        if is_test && [[ "$UI_REPLY" == retry ]]; then die "mirror test retry in answers mode: verdict $MIRROR_VERDICT"; fi
        case "$UI_REPLY" in
            retry) continue ;;
            switch) [[ "$MIRROR_VERDICT" == WAN ]] && ANS[LAYOUT]=wan_mirror || ANS[LAYOUT]=lan_mirror; return ;;
            skip) return ;;
            none) ANS[LAYOUT]=none; ANS[CAPTURE_IFACE]=""; drop_capture_goals; return ;;
        esac
    done
}

# ---------- data cap (SPEC 7.4.1) ----------

phase_cap() {
    local keys=(CAP_COUNTS CAP_PERIOD CAP_RESET_DAY CAP_START_DATE CAP_SPLIT CAP_GB CAP_PEAK_GB CAP_OFFPEAK_GB CAP_PEAK_HOURS CAP_OVER_ACTION CAP_ADJUST_PERCENT CAP_WARNINGS)
    local k; for k in "${keys[@]}"; do ANS[$k]=""; done
    ANS[CAP_ENABLED]=no
    if [[ "${ANS[LAYOUT]}" == none ]]; then
        goal cap && ui_msg - "Data cap" "Tracking a data cap needs traffic capture (layout A or B), so homewan skips the data cap questions. Add capture later with: sudo homewan reconfigure"
        return
    fi
    local dflt=no; goal cap && dflt=yes
    ui_yesno CAP_ENABLED "Data cap" "Does your internet plan have a data limit?" "$(prev CAP_ENABLED "$dflt")" || return
    ANS[CAP_ENABLED]=yes
    goal cap || add_goal cap

    ui_menu CAP_COUNTS "Data cap" "How does your provider count usage?" "$(prev CAP_COUNTS down_up)" \
        down_up "Downloads and uploads" \
        down    "Downloads only"
    ANS[CAP_COUNTS]="$UI_REPLY"

    ui_menu CAP_PERIOD "Data cap" "When does the allowance reset?" "$(prev CAP_PERIOD monthly)" \
        monthly    "Monthly, on a set day of the month" \
        rolling_30 "Every 30 days from a start date" \
        daily      "Every day"
    ANS[CAP_PERIOD]="$UI_REPLY"
    case "$UI_REPLY" in
        monthly)
            ui_input CAP_RESET_DAY "Data cap" "Day of the month the allowance resets (1 to 31). In short months, a day past the end means the last day of the month." "$(prev CAP_RESET_DAY 1)" v_day
            ANS[CAP_RESET_DAY]="$UI_REPLY" ;;
        rolling_30)
            ui_input CAP_START_DATE "Data cap" "Date of any recent reset, as YYYY-MM-DD. homewan counts 30-day periods from it." "$(prev CAP_START_DATE "$(date +%F)")" v_date
            ANS[CAP_START_DATE]="$UI_REPLY" ;;
    esac

    if ui_yesno CAP_SPLIT "Data cap" "Is the allowance split into peak and off-peak hours?" "$(prev CAP_SPLIT no)"; then
        ANS[CAP_SPLIT]=yes
        ui_input CAP_PEAK_GB "Data cap" "Peak allowance per period, in GB:" "$(prev CAP_PEAK_GB)" v_gb;       ANS[CAP_PEAK_GB]="$UI_REPLY"
        ui_input CAP_OFFPEAK_GB "Data cap" "Off-peak allowance per period, in GB:" "$(prev CAP_OFFPEAK_GB)" v_gb; ANS[CAP_OFFPEAK_GB]="$UI_REPLY"
        ui_input CAP_PEAK_HOURS "Data cap" "Peak hours, as start-end in 24-hour time (for example 07:00-01:00):" "$(prev CAP_PEAK_HOURS 07:00-01:00)" v_hours
        ANS[CAP_PEAK_HOURS]="$UI_REPLY"
    else
        ANS[CAP_SPLIT]=no
        ui_input CAP_GB "Data cap" "Allowance per period, in GB:" "$(prev CAP_GB)" v_gb; ANS[CAP_GB]="$UI_REPLY"
    fi

    ui_menu CAP_OVER_ACTION "Data cap" "What happens when you reach the limit?" "$(prev CAP_OVER_ACTION slowed)" \
        slowed  "Speed is slowed down" \
        charged "Extra data is charged" \
        cut_off "Internet stops until the reset"
    ANS[CAP_OVER_ACTION]="$UI_REPLY"

    ui_input CAP_ADJUST_PERCENT "Data cap" "homewan's count can differ from your provider's meter by a few percent, because the two count network overhead differently.

If you have compared them and see a steady gap, enter it as a percentage to add (for example 3) or subtract (-3). Otherwise leave 0." "$(prev CAP_ADJUST_PERCENT 0)" v_adjust
    ANS[CAP_ADJUST_PERCENT]="$UI_REPLY"

    ui_yesno CAP_WARNINGS "Data cap" "Email a warning between weekly reports when usage passes 80% or 100% of the allowance, or is on track to run out before the reset?

Each warning is sent once per period." "$(prev CAP_WARNINGS yes)"
    ANS[CAP_WARNINGS]="$UI_REPLY"
}

# ---------- phase 3: features and schedule ----------

SMTP_PRESETS=(
    "gmail|smtp.gmail.com|465|ssl|Gmail needs an app password: Google Account > Security > 2-Step Verification (must be on) > App passwords. Use the 16 letters without spaces."
    "fastmail|smtp.fastmail.com|465|ssl|Fastmail needs an app password: Settings > Privacy & Security > App passwords, with SMTP access."
    "icloud|smtp.mail.me.com|587|starttls|iCloud Mail needs an app-specific password: account.apple.com > Sign-In and Security > App-Specific Passwords. The user name is your full iCloud address."
)

phase_features() {
    local features="report"
    goal health && features+=",health"
    goal speed && features+=",speedtest"
    [[ "${ANS[LAYOUT]}" != none ]] && features+=",capture"
    ANS[SPEEDTEST_INTERVAL_HOURS]=""

    if goal speed; then
        local h items=()
        for h in 1 2 3 4 6 8 12 24; do
            items+=("$h" "Every $h hour$([[ $h != 1 ]] && printf s): about $(speedtest_gb_month "$h") GB a month")
        done
        ui_menu SPEEDTEST_INTERVAL_HOURS "Speedtest" "How often should homewan test your speed?

Each test downloads and uploads at full speed for about 10 seconds each way: about $(speedtest_mb) MB on your ${ANS[PLAN_DOWN_MBPS]}/${ANS[PLAN_UP_MBPS]} Mbps plan. That counts towards any data cap.$([[ ${ANS[CAP_ENABLED]} == yes ]] && printf ' The data cap section of the report shows it separately.')" \
            "$(prev SPEEDTEST_INTERVAL_HOURS 4)" "${items[@]}"
        ANS[SPEEDTEST_INTERVAL_HOURS]="$UI_REPLY"
    fi

    # Weekly report
    ui_input TZ "Time zone" "Your time zone, for the report schedule and the charts:" "$(prev TZ "${TZ_DETECTED:-UTC}")" v_tz
    ANS[TZ]="$UI_REPLY"
    ui_input REPORT_TO "Weekly report" "Who should receive the weekly report? One or more email addresses, separated by commas." "$(prev REPORT_TO)" v_emails
    ANS[REPORT_TO]="${UI_REPLY// /}"
    ui_menu REPORT_DAY "Weekly report" "Which day should the report arrive?" "$(prev REPORT_DAY Mon)" \
        Mon Monday Tue Tuesday Wed Wednesday Thu Thursday Fri Friday Sat Saturday Sun Sunday
    ANS[REPORT_DAY]="$UI_REPLY"
    ui_input REPORT_TIME "Weekly report" "What time? 24-hour, in ${ANS[TZ]} time:" "$(prev REPORT_TIME 08:00)" v_time
    ANS[REPORT_TIME]="$UI_REPLY"

    phase_email

    # Outdoor temperature
    ANS[LOCATION_NAME]=""; ANS[LOCATION_LAT]=""; ANS[LOCATION_LON]=""
    if goal health; then
        if ui_yesno AMBIENT "Outdoor temperature" "Add your outdoor temperature to the report's CPU temperature chart?

It helps tell a hot day from a cooling problem. homewan looks up the weather for your town through Open-Meteo, a free service with no account." "$( [[ -n "$(prev LOCATION_LAT)" ]] && printf yes || printf no)"; then
            phase_location
            features+=",ambient"
        fi
    fi

    # Grafana and sharing
    if ui_yesno GRAFANA "Grafana dashboards" "Install Grafana for live dashboards in a web browser?

The weekly email works without it. Grafana uses about 150 MB of memory." "$(list_has "$(prev FEATURES)" grafana && printf yes || printf no)"; then
        features+=",grafana"
    fi
    if ui_yesno SHARED_STORE "Share the metrics store" "Let other programs on this Pi store their own metrics in homewan's database?

Each program gets its own bucket and a write-only key, created with: sudo homewan bucket add NAME" "$(list_has "$(prev FEATURES)" shared && printf yes || printf no)"; then
        features+=",shared"
        ui_input INFLUX_ORG "Share the metrics store" "Organisation name inside the database. Keep the default unless another program on this Pi already expects a particular name." "$(prev INFLUX_ORG homewan)" v_org
        ANS[INFLUX_ORG]="$UI_REPLY"
        ui_menu INFLUX_BIND "Share the metrics store" "Which programs can reach the database?" "$(prev INFLUX_BIND 127.0.0.1)" \
            127.0.0.1 "Programs on this Pi only (recommended)" \
            0.0.0.0   "Any computer on your network"
        ANS[INFLUX_BIND]="$UI_REPLY"
    else
        ANS[INFLUX_ORG]="$(prev INFLUX_ORG homewan)"
        ANS[INFLUX_BIND]=127.0.0.1
    fi
    ANS[FEATURES]="$features"

}

phase_email() {
    local p name host port sec pnote note
    ui_menu SMTP_PRESET "Sending email" "Which email service should send the report?

Use an account you are happy to store an app password for. A separate account just for notifications is a good idea." "$(prev SMTP_PRESET gmail)" \
        gmail "Gmail" fastmail "Fastmail" icloud "iCloud Mail" custom "Another provider (enter the server details)"
    ANS[SMTP_PRESET]="$UI_REPLY"
    note=""
    for p in "${SMTP_PRESETS[@]}"; do
        IFS='|' read -r name host port sec pnote <<<"$p"
        if [[ "$name" == "${ANS[SMTP_PRESET]}" ]]; then
            ANS[SMTP_HOST]="$host"; ANS[SMTP_PORT]="$port"; ANS[SMTP_SECURITY]="$sec"; note="$pnote"
        fi
    done
    if [[ "${ANS[SMTP_PRESET]}" == custom ]]; then
        ui_input SMTP_HOST "Sending email" "SMTP server name:" "$(prev SMTP_HOST)" v_host;  ANS[SMTP_HOST]="$UI_REPLY"
        ui_menu SMTP_SECURITY "Sending email" "Connection security:" "$(prev SMTP_SECURITY ssl)" \
            ssl "SSL/TLS (usually port 465)" starttls "STARTTLS (usually port 587)"
        ANS[SMTP_SECURITY]="$UI_REPLY"
        local dport=465; [[ "$UI_REPLY" == starttls ]] && dport=587
        ui_input SMTP_PORT "Sending email" "Port:" "$(prev SMTP_PORT "$dport")" v_port; ANS[SMTP_PORT]="$UI_REPLY"
    fi
    ui_input SMTP_USER "Sending email" "Sign-in name for ${ANS[SMTP_HOST]} (usually the full email address):" "$(prev SMTP_USER)" v_nonempty
    ANS[SMTP_USER]="$UI_REPLY"
    local dfrom="${ANS[SMTP_USER]}"; v_email "$dfrom" >/dev/null || dfrom=""
    ui_input SMTP_FROM "Sending email" "Send from this address:" "$(prev SMTP_FROM "$dfrom")" v_email
    ANS[SMTP_FROM]="$UI_REPLY"

    while true; do
        local have=""; [[ -n "${SECRETS[SMTP_PASSWORD]:-}" ]] && have="

Leave it empty to keep the password saved last time."
        ui_password SMTP_PASSWORD "Sending email" "Password for ${ANS[SMTP_USER]}.${note:+ $note}$have"
        if [[ -n "$UI_REPLY" ]]; then
            valid_value "$UI_REPLY" || { ui_msg - "Password" "homewan cannot store a password containing a single quote. Create an app password without one."; continue; }
            NEW_SMTP_PASSWORD="$UI_REPLY"
        elif [[ -z "${SECRETS[SMTP_PASSWORD]:-}" ]] && ! is_test; then
            continue
        fi
        if ! ui_yesno SMTP_TEST "Test email" "Send a test email to ${ANS[REPORT_TO]} now?" yes; then return; fi
        ui_info "Sending a test email..."
        local out
        out="$(SMTP_HOST="${ANS[SMTP_HOST]}" SMTP_PORT="${ANS[SMTP_PORT]}" SMTP_SECURITY="${ANS[SMTP_SECURITY]}" \
               SMTP_USER="${ANS[SMTP_USER]}" SMTP_FROM="${ANS[SMTP_FROM]}" REPORT_TO="${ANS[REPORT_TO]}" \
               SMTP_PASSWORD="${NEW_SMTP_PASSWORD:-${SECRETS[SMTP_PASSWORD]:-}}" HOMEWAN_TEST="$HOMEWAN_TEST" \
               py smtp_test.py)"
        if [[ "$out" == OK* ]]; then
            ui_msg - "Test email" "Sent. Check the inbox of ${ANS[REPORT_TO]}, and the spam folder."
            return
        fi
        ui_menu SMTP_FAIL_ACTION "Test email failed" "$out

A 535 error means the sign-in name or app password is wrong." again \
            again "Enter the password again" \
            back  "Change the email settings" \
            skip  "Continue anyway"
        case "$UI_REPLY" in
            again) continue ;;
            back) phase_email; return ;;
            skip) return ;;
        esac
    done
}

phase_location() {
    while true; do
        ui_input LOCATION_SEARCH "Outdoor temperature" "Type your town or suburb:" "$(prev LOCATION_NAME)" v_nonempty
        local q="${UI_REPLY%%,*}" lines=() l items=() n=0
        ui_info "Looking up $q..."
        mapfile -t lines < <(py geocode.py search "$q")
        for l in "${lines[@]}"; do n=$((n + 1)); items+=("$n" "$(cut -f1 <<<"$l")"); done
        items+=(again "Search again" manual "Enter latitude and longitude myself")
        ui_menu LOCATION_PICK "Outdoor temperature" "$( ((n)) && printf 'Pick your place:' || printf 'No places found for "%s", or the lookup service could not be reached.' "$q")" \
            "$( ((n)) && printf 1 || printf manual)" "${items[@]}"
        case "$UI_REPLY" in
            again) continue ;;
            manual)
                ui_input LOCATION_LAT "Outdoor temperature" "Latitude (south is negative), for example -27.47:" "$(prev LOCATION_LAT)" v_lat; ANS[LOCATION_LAT]="$UI_REPLY"
                ui_input LOCATION_LON "Outdoor temperature" "Longitude (west is negative), for example 153.03:" "$(prev LOCATION_LON)" v_lon; ANS[LOCATION_LON]="$UI_REPLY"
                ANS[LOCATION_NAME]="${ANS[LOCATION_LAT]}, ${ANS[LOCATION_LON]}" ;;
            *)
                l="${lines[UI_REPLY-1]}"
                ANS[LOCATION_NAME]="$(cut -f1 <<<"$l")"; ANS[LOCATION_LAT]="$(cut -f2 <<<"$l")"; ANS[LOCATION_LON]="$(cut -f3 <<<"$l")" ;;
        esac
        local t
        if t="$(py geocode.py current "${ANS[LOCATION_LAT]}" "${ANS[LOCATION_LON]}")"; then
            ui_msg - "Outdoor temperature" "${ANS[LOCATION_NAME]}: $t °C now. The report will use this place."
        else
            ui_msg - "Outdoor temperature" "The weather service could not be reached just now. homewan keeps ${ANS[LOCATION_NAME]}; if a lookup fails on report day, the chart leaves the outdoor line out."
        fi
        return
    done
}

# ---------- phase 4: storage ----------

phase_storage() {
    local l target fstype src size avail ok why items=() bad="" root_dir=""
    for l in "${FS_LINES[@]}"; do
        IFS=$'\t' read -r target fstype src size avail ok why <<<"$l"
        if [[ "$ok" == yes ]]; then
            local dir="$target/homewan" label
            [[ "$target" == / ]] && dir=/var/lib/homewan
            label="$dir  ($fstype, $avail GB free"
            if [[ "$src" == /dev/mmcblk* ]]; then label+=", SD card"; fi
            label+=")"
            items+=("$dir" "$label")
            [[ "$target" == / ]] && root_dir="$dir"
        else
            bad+="  $target ($fstype): $why"$'\n'
        fi
    done
    items+=(custom "Another folder")
    local rec="${root_dir:-/var/lib/homewan}" text
    text="Where should homewan keep its database?

An SSD or hard drive formatted ext4 lasts longest. The SD card works; constant small writes shorten its life, so keep the retention period modest."
    [[ -n "$bad" ]] && text+=$'\n\n'"Not offered:"$'\n'"$bad"
    ui_menu DATA_DIR_PICK "Storage" "$text" "$(prev DATA_DIR "$rec")" "${items[@]}"
    if [[ "$UI_REPLY" == custom ]]; then
        ui_input DATA_DIR "Storage" "Folder for homewan's data (homewan creates it):" "$(prev DATA_DIR /var/lib/homewan)" v_abspath
    fi
    ANS[DATA_DIR]="$UI_REPLY"

    local perday=3
    [[ "${ANS[LAYOUT]}" == wan_mirror ]] && perday=15
    [[ "${ANS[LAYOUT]}" == lan_mirror ]] && perday=40
    local d ritems=()
    for d in 30 90 180 365; do ritems+=("$d" "$d days: about $(gb1 $((d * perday))) GB"); done
    ritems+=(0 "Keep everything: grows about $(gb1 $((365 * perday))) GB a year")
    ui_menu RETENTION_DAYS "Storage" "How long should homewan keep data?

The weekly report needs 7 days; data cap tracking needs one full period (up to 31 days)." "$(prev RETENTION_DAYS 90)" "${ritems[@]}"
    ANS[RETENTION_DAYS]="$UI_REPLY"

    phase_drives

    # Ports: keep last run's choice, else the first free one.
    ANS[INFLUX_PORT]="$(prev INFLUX_PORT "$(next_free_port 8086)")"
    ANS[NTOPNG_PORT]="$(prev NTOPNG_PORT "$(next_free_port 3001)")"
    ANS[GRAFANA_PORT]="$(prev GRAFANA_PORT "$(next_free_port 3000)")"
    ANS[REDIS_PORT]="$(prev REDIS_PORT "$(next_free_port 6380)")"
}

# ---------- drives: discovery, monitoring, missing-drive warnings, SMART ----------

# fstab_hint DEVICE FSTYPE UUID LABEL -> commands to mount a drive at boot
fstab_hint() {
    local dev="$1" fstype="$2" uuid="$3" label="$4" name opts type pass=0
    name="$(orelse "$label" "" | tr -c 'A-Za-z0-9_-' '_' | sed 's/_*$//')"
    [[ -n "$name" ]] || name="disk-${uuid:0:8}"
    local uid="${SUDO_UID:-1000}" gid="${SUDO_GID:-1000}"
    case "$fstype" in
        ext2|ext3|ext4|xfs|btrfs|f2fs) type="$fstype"; opts="defaults,nofail,noatime"; pass=2 ;;
        ntfs) type=ntfs3; opts="defaults,nofail,noatime,uid=$uid,gid=$gid" ;;
        exfat|vfat) type="$fstype"; opts="defaults,nofail,uid=$uid,gid=$gid,umask=022" ;;
        *) type="$fstype"; opts="defaults,nofail" ;;
    esac
    opts+=",x-systemd.device-timeout=10s"
    cat <<EOF
$dev ($fstype, label $(orelse "$label" none)):
  sudo mkdir -p /media/$name
  echo 'UUID=$uuid /media/$name $type $opts 0 $pass' | sudo tee -a /etc/fstab
  sudo systemctl daemon-reload && sudo mount -a && df -h /media/$name
EOF
}

phase_drives() {
    local l target fstype src size avail ok why uuid

    # 1. Drives that are plugged in but not mounted.
    if ((${#UNMOUNTED_LINES[@]})); then
        local hints="" dev label
        for l in "${UNMOUNTED_LINES[@]}"; do
            IFS=$'\t' read -r dev fstype size uuid label _ <<<"$l"
            hints+="$(fstab_hint "$dev" "$fstype" "$uuid" "$label")"$'\n\n'
        done
        ui_msg - "Drives not mounted" "These drives are plugged in but not mounted, so homewan cannot see their free space:

${hints}Each block mounts one drive now and at every boot. 'nofail' and the 10-second timeout let the Pi boot normally when the drive is unplugged. Check the folder name under /media before you run them.

homewan never edits /etc/fstab itself."
        ui_menu UNMOUNTED_ACTION "Drives not mounted" "What next?" continue \
            continue "Continue; I'll mount them later (they appear in the report once mounted)" \
            quit     "Save my answers and quit, to mount them first"
        if [[ "$UI_REPLY" == quit ]]; then save_draft; log "Answers saved. Mount the drives, then run the installer again."; exit 10; fi
    fi

    # 2. Which drives the report covers.
    ui_menu DISK_MODE "Drives in the report" "Which drives should the report show space for?" "$(prev DISK_MODE all)" \
        all      "Every mounted drive, including ones added later (recommended)" \
        selected "Only the drives I pick now"
    ANS[DISK_MODE]="$UI_REPLY"
    ANS[DISK_MOUNTS]=""
    if [[ "${ANS[DISK_MODE]}" == selected ]]; then
        local citems=() pm; pm="$(prev DISK_MOUNTS)"
        for l in "${FS_LINES[@]}"; do
            IFS=$'\t' read -r target fstype src size avail ok why uuid <<<"$l"
            citems+=("$target" "$target ($fstype, $size GB)" "$( [[ -z "$pm" ]] || list_has "$pm" "$target" && printf on || printf off)")
        done
        ui_checklist DISK_MOUNTS "Drives in the report" "Tick the drives the report should show:" "${citems[@]}"
        ANS[DISK_MOUNTS]="${UI_REPLY:-/}"
    fi

    # 3. Drives that should always be connected.
    ANS[DISK_EXPECTED]=""; ANS[DISK_WARNINGS]=no
    local eitems=() pe; pe="$(prev DISK_EXPECTED)"
    for l in "${FS_LINES[@]}"; do
        IFS=$'\t' read -r target fstype src size avail ok why uuid <<<"$l"
        [[ "$target" == / ]] && continue
        local on=on; [[ -n "$pe" && ",$pe," != *",$target="* ]] && on=off
        eitems+=("$target=$uuid" "$target ($fstype, $size GB)" "$on")
    done
    if ((${#eitems[@]})); then
        ui_checklist DISK_EXPECTED "Missing drive warnings" "Which drives should always be connected?

The report warns when one of them is missing or a different drive is mounted in its place. homewan recognises each drive by its filesystem ID." "${eitems[@]}"
        ANS[DISK_EXPECTED]="$UI_REPLY"
        if [[ -n "${ANS[DISK_EXPECTED]}" ]]; then
            ui_yesno DISK_WARNINGS "Missing drive warnings" "Also email a warning the day one of these drives goes missing, without waiting for the weekly report?

homewan checks once a day and emails once per missing drive, plus once when it comes back." "$(prev DISK_WARNINGS yes)"
            ANS[DISK_WARNINGS]="$UI_REPLY"
        fi
    fi

    # 4. Drive health (SMART).
    ANS[SMART_DEVICES]=""
    if ((${#DISK_LINES[@]} == 0)); then return; fi
    local list="" dl dev byid model dsize
    for dl in "${DISK_LINES[@]}"; do
        IFS=$'\t' read -r dev byid model _ dsize <<<"$dl"
        list+="  $dev  $(orelse "$model" "unknown model"), $dsize GB"$'\n'
    done
    local dflt=yes; [[ -n "$(prev SMART_CHECK)" ]] && dflt="$(prev SMART_CHECK)"
    if ! ui_yesno SMART_CHECK "Drive health" "Many hard drives and SSDs report their own health and temperature (SMART). The report can show it, and warn when a drive starts failing.

Drives found:
$list
SD cards cannot report health. Test which of these drives respond?" "$dflt"; then
        ANS[SMART_CHECK]=no; return
    fi
    ANS[SMART_CHECK]=yes
    ensure_pkg smartctl smartmontools INSTALL_SMARTMONTOOLS "Testing drive health needs smartmontools." || return
    ui_info "Asking each drive for its health..."
    local sitems=() silent="" r rtype health temp ps; ps="$(prev SMART_DEVICES)"
    for dl in "${DISK_LINES[@]}"; do
        IFS=$'\t' read -r dev byid model _ dsize <<<"$dl"
        r="$(py smart.py "$dev")"
        if [[ "$r" == ok* ]]; then
            IFS=$'\t' read -r _ rtype health temp <<<"$r"
            local id; id="$(orelse "$byid" "${dev#/dev/}"):$rtype"
            local on=on
            [[ -n "$ps" && ",$ps," != *",$id,"* ]] && on=off
            sitems+=("$id" "$(orelse "$model" "$dev") ($dev): $health$( [[ $temp != - ]] && printf ', %s °C' "$temp")" "$on")
        else
            silent+="  $(orelse "$model" "$dev") ($dev): ${r#none$'\t'}"$'\n'
        fi
    done
    if ((${#sitems[@]} == 0)); then
        ui_msg - "Drive health" "None of the drives responded:
$silent
The report leaves drive health out. Free space and missing-drive warnings still work."
        return
    fi
    ui_checklist SMART_DEVICES "Drive health" "These drives report their health. Tick the ones the report should include.${silent:+

No response from:
$silent}" "${sitems[@]}"
    ANS[SMART_DEVICES]="$UI_REPLY"
}

# ---------- phase 5: summary ----------

_label() { # _label VALUE TAG LABEL [TAG LABEL...]
    local v="$1"; shift
    while (($#)); do [[ "$1" == "$v" ]] && { printf '%s' "$2"; return; }; shift 2; done
    printf '%s' "$v"
}

expected_summary() {
    if [[ -z "${ANS[DISK_EXPECTED]}" ]]; then printf 'none'; return; fi
    local e out=()
    IFS=',' read -ra _e <<<"${ANS[DISK_EXPECTED]}"
    for e in "${_e[@]}"; do out+=("${e%%=*}"); done
    printf '%s, warning email %s' "$(join , "${out[@]}" | sed 's/,/, /g')" "${ANS[DISK_WARNINGS]}"
}

summary_text() {
    local s
    s="Network
  Layout:            $(_label "${ANS[LAYOUT]}" wan_mirror "A, mirror between modem and router" lan_mirror "B, mirror on the router's LAN side" none "C, no capture")"
    if [[ "${ANS[LAYOUT]}" != none ]]; then s+="
  Capture port:      ${ANS[CAPTURE_IFACE]} (mirror test: ${ANS[MIRROR_TEST]})"; fi
    s+="
  Pi's connection:   ${ANS[MGMT_IFACE]}, network ${ANS[LAN_SUBNET]}
  Plan:              ${ANS[PLAN_DOWN_MBPS]}/${ANS[PLAN_UP_MBPS]} Mbps"
    if [[ "${ANS[CAP_ENABLED]}" == yes ]]; then
        local amount="${ANS[CAP_GB]} GB"
        [[ "${ANS[CAP_SPLIT]}" == yes ]] && amount="${ANS[CAP_PEAK_GB]} GB peak (${ANS[CAP_PEAK_HOURS]}) + ${ANS[CAP_OFFPEAK_GB]} GB off-peak"
        local period; period="$(_label "${ANS[CAP_PERIOD]}" monthly "monthly, resets on day ${ANS[CAP_RESET_DAY]}" rolling_30 "every 30 days from ${ANS[CAP_START_DATE]}" daily daily)"
        s+="
  Data cap:          $amount, $period
                     counts $(_label "${ANS[CAP_COUNTS]}" down_up "downloads and uploads" down "downloads only"), adjust ${ANS[CAP_ADJUST_PERCENT]}%, warnings ${ANS[CAP_WARNINGS]}"
    else
        s+="
  Data cap:          none"
    fi
    s+="

Features
  Tracking:          ${ANS[GOALS]//,/, }"
    [[ -n "${ANS[SPEEDTEST_INTERVAL_HOURS]}" ]] && s+="
  Speedtest:         every ${ANS[SPEEDTEST_INTERVAL_HOURS]} h, about $(speedtest_gb_month "${ANS[SPEEDTEST_INTERVAL_HOURS]}") GB a month"
    s+="
  Report:            ${ANS[REPORT_DAY]} ${ANS[REPORT_TIME]} ${ANS[TZ]}, to ${ANS[REPORT_TO]}
  Email via:         ${ANS[SMTP_HOST]}:${ANS[SMTP_PORT]} as ${ANS[SMTP_USER]}
  Outdoor temp:      ${ANS[LOCATION_NAME]:-off}
  Grafana:           $(list_has "${ANS[FEATURES]}" grafana && printf 'on, port %s' "${ANS[GRAFANA_PORT]}" || printf off)
  Shared database:   $(list_has "${ANS[FEATURES]}" shared && printf 'on, organisation %s, reachable from %s' "${ANS[INFLUX_ORG]}" "$( [[ ${ANS[INFLUX_BIND]} == 127.0.0.1 ]] && printf 'this Pi only' || printf 'your network')" || printf off)

Storage
  Data folder:       ${ANS[DATA_DIR]}
  Keep data for:     $( [[ ${ANS[RETENTION_DAYS]} == 0 ]] && printf 'ever' || printf '%s days' "${ANS[RETENTION_DAYS]}")
  Drives in report:  $( [[ ${ANS[DISK_MODE]} == all ]] && printf 'every mounted drive' || printf '%s' "${ANS[DISK_MOUNTS]//,/, }")
  Must be connected: $(expected_summary)
  Drive health:      $( [[ -n ${ANS[SMART_DEVICES]} ]] && printf '%s' "${ANS[SMART_DEVICES]//,/, }" || printf off)
  Ports:             database ${ANS[INFLUX_PORT]}$( [[ ${ANS[LAYOUT]} != none ]] && printf ', ntopng %s' "${ANS[NTOPNG_PORT]}")"
    printf '%s' "$s"
}

phase_summary() {
    ui_msg - "Summary" "$(summary_text)"
    ui_menu CONFIRM "Confirm" "Nothing on this Pi has changed yet.

Save these settings and set up homewan?" save \
        save   "Save and continue" \
        change "Go through the questions again, starting from these answers" \
        quit   "Save my answers and quit"
    case "$UI_REPLY" in
        save) return 0 ;;
        change) return 1 ;;
        quit) save_draft; log "Answers saved to $ANSWERS_DRAFT."; exit 10 ;;
    esac
}
