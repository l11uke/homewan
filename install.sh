#!/usr/bin/env bash
# homewan installer. Run as: sudo /opt/homewan/install.sh
#
# Options:
#   --text            plain text prompts instead of whiptail screens
#   --preview         try the questions: settings go to /tmp/homewan-preview,
#                     and containers from an older stack only raise a warning
#   --alongside       install next to an older monitoring stack that is still
#                     running (it keeps its ports; homewan takes free ones)
#   --answers FILE    test suite only (needs HOMEWAN_TEST=1)
set -uo pipefail

HOMEWAN_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOMEWAN_PREVIEW=0
HOMEWAN_ALONGSIDE=0
for arg in "$@"; do
    [[ "$arg" == --alongside ]] && HOMEWAN_ALONGSIDE=1
    if [[ "$arg" == --preview ]]; then HOMEWAN_PREVIEW=1; HOMEWAN_ETC="${HOMEWAN_PREVIEW_DIR:-/tmp/homewan-preview}"; fi
done
# shellcheck source=lib/common.sh
source "$HOMEWAN_ROOT/lib/common.sh"
# shellcheck source=lib/ui.sh
source "$HOMEWAN_ROOT/lib/ui.sh"
# shellcheck source=lib/config.sh
source "$HOMEWAN_ROOT/lib/config.sh"
# shellcheck source=lib/packages.sh
source "$HOMEWAN_ROOT/lib/packages.sh"
# shellcheck source=lib/checks.sh
source "$HOMEWAN_ROOT/lib/checks.sh"
# shellcheck source=lib/mirror_test.sh
source "$HOMEWAN_ROOT/lib/mirror_test.sh"
# shellcheck source=lib/interview.sh
source "$HOMEWAN_ROOT/lib/interview.sh"
# shellcheck source=lib/deploy.sh
source "$HOMEWAN_ROOT/lib/deploy.sh"
# shellcheck source=lib/verify.sh
source "$HOMEWAN_ROOT/lib/verify.sh"

while (($#)); do
    case "$1" in
        --text) UI_MODE=text ;;
        --preview|--alongside) ;;
        --answers)
            [[ "${HOMEWAN_TEST:-0}" == 1 ]] || die "--answers is for the test suite only. Run the installer without it."
            HOMEWAN_ANSWERS="${2:?--answers needs a file}"; shift ;;
        -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

main() {
    ui_init
    checks_run
    checks_verdict
    if [[ -n "$CHECK_STOP" ]]; then
        ui_msg - "Cannot continue" "$CHECK_STOP"
        log "$CHECK_STOP"
        exit 1
    fi

    local mode="install"; [[ -f "$SITE_CONF" ]] && mode="reconfigure"
    ui_msg - "Welcome to homewan" "homewan watches your internet connection and emails you a weekly report.

This installer:
  1. Asks what you want to track, and checks you have the hardware for it.
  2. Works out your network layout and tests the wiring.
  3. Asks about your internet plan, data cap, email and schedule.
  4. Shows a summary. Nothing on this Pi changes before you confirm it.
  5. Sets everything up and checks that it works.
$( [[ $mode == reconfigure ]] && printf '\nhomewan is already set up here. Every question starts with your current answer: press Enter to keep it.\n')
Press Esc on any screen to save your answers and quit."
    ui_msg - "This Pi" "$CHECK_TEXT"

    cfg_load_prefill

    while true; do
        phase_goals;    save_draft
        phase_network;  save_draft
        phase_features; save_draft
        phase_storage;  save_draft
        if phase_summary; then break; fi
        local k; for k in "${!ANS[@]}"; do PREV[$k]="${ANS[$k]}"; done
    done

    write_site_conf
    write_secrets
    rm -f "$ANSWERS_DRAFT"

    if ((HOMEWAN_PREVIEW)); then
        ui_msg - "Preview finished" "Your answers are in $SITE_CONF. Nothing else changed.

Delete the preview with: sudo rm -rf $HOMEWAN_ETC"
        log "Preview settings written to $SITE_CONF"
        return
    fi

    is_test && { log "Settings saved to $SITE_CONF (test mode: nothing set up)"; return; }

    deploy --build
    phase_verify
}

phase_verify() {
    ui_info "Checking that everything works. This takes up to 2 minutes..."
    verify_all 120
    if feature speedtest && ui_yesno FIRST_SPEEDTEST "First speedtest" "Run a first speedtest now? It takes about 30 seconds and uses about $(( (${CONF[PLAN_DOWN_MBPS]} + ${CONF[PLAN_UP_MBPS]}) * 10 / 8 )) MB." yes; then
        ui_info "Running a speedtest..."
        local out
        if out="$(run_first_speedtest 2>&1)"; then vpass "first speedtest: ${out#OK: }"; else vfail "first speedtest failed: $(tail -1 <<<"$out")"; fi
    fi
    local head="homewan is running."
    ((VERIFY_FAILED)) && head="homewan is set up, but $VERIFY_FAILED check(s) failed. Fix them, then run: sudo homewan doctor"
    ui_msg - "Done" "$head

$(verify_text)

Web logins: sudo homewan secrets
Health check: sudo homewan doctor
All commands: homewan help"
    log "$head"
    verify_text >&2
}

run_first_speedtest() {
    docker run --rm --network homewan_default \
        -e "INFLUX_ORG=${CONF[INFLUX_ORG]}" -e INFLUX_URL=http://influxdb:8086 \
        -e "INFLUX_TOKEN_SPEEDTEST=${SECRETS[INFLUX_TOKEN_SPEEDTEST]}" \
        homewan/tools:local speedtest
}

main
