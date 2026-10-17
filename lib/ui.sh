# shellcheck shell=bash
# Question screens. Three back ends:
#   whiptail  the default on a terminal
#   text      plain prompts (HOMEWAN_UI=text), for terminals where whiptail misbehaves
#   answers   test mode only: values come from an answers file
#
# Every function takes a KEY first. Answers mode looks the KEY up; the other
# modes ignore it. Results go into the global UI_REPLY, so that cancelling
# can exit the installer from inside the function.

UI_REPLY=""
UI_MODE="${HOMEWAN_UI:-whiptail}"
UI_TITLE="homewan installer"
UI_H=22
UI_W=76
declare -gA UI_ANSWERS=()

ui_init() {
    if is_test; then
        UI_MODE=answers
        [[ -n "${HOMEWAN_ANSWERS:-}" && -f "$HOMEWAN_ANSWERS" ]] || die "test mode needs HOMEWAN_ANSWERS"
        local line key val
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            key="${line%%=*}"; val="${line#*=}"
            UI_ANSWERS["$key"]="$val"
        done < "$HOMEWAN_ANSWERS"
        return
    fi
    if [[ "$UI_MODE" == whiptail ]] && ! command -v whiptail >/dev/null; then
        UI_MODE=text
    fi
}

# Answers mode: the answers file value, else the default, else fail the test.
_ui_answer() {
    local key="$1" default="$2"
    if [[ -v "UI_ANSWERS[$key]" ]]; then
        UI_REPLY="${UI_ANSWERS[$key]}"
    elif [[ -n "$default" ]]; then
        UI_REPLY="$default"
    else
        die "answers file has no value for $key and the question has no default"
    fi
}

# Called when the user cancels a screen.
_ui_cancelled() {
    if [[ "$UI_MODE" == answers ]]; then die "cancel in answers mode"; fi
    if _ui_raw_yesno "Quit the installer?" "Save your answers so far and quit?

Nothing on this Pi has changed yet. Run the installer again to pick up where you left off." yes; then
        declare -F save_draft >/dev/null && save_draft
        log "Answers saved to $ANSWERS_DRAFT. Run the installer again to resume."
        exit 10
    fi
    return 1
}

_ui_raw_yesno() {
    local title="$1" text="$2" default="$3"
    if [[ "$UI_MODE" == text ]]; then
        local hint="[Y/n]"; [[ "$default" == no ]] && hint="[y/N]"
        printf '\n== %s ==\n%s\n%s ' "$title" "$text" "$hint" >&2
        local r; read -r r
        r="${r:-$default}"
        [[ "${r,,}" == y* ]]
        return
    fi
    local extra=(); [[ "$default" == no ]] && extra=(--defaultno)
    whiptail --title "$title" --backtitle "$UI_TITLE" "${extra[@]}" --yesno "$text" "$UI_H" "$UI_W"
}

# ui_msg KEY TITLE TEXT
ui_msg() {
    local key="$1" title="$2" text="$3"
    case "$UI_MODE" in
        answers) return 0 ;;
        text) printf '\n== %s ==\n%s\n\nPress Enter to continue. ' "$title" "$text" >&2; read -r _ ;;
        *) whiptail --title "$title" --backtitle "$UI_TITLE" --scrolltext --msgbox "$text" "$UI_H" "$UI_W" ;;
    esac
}

# ui_yesno KEY TITLE TEXT DEFAULT(yes|no) -> UI_REPLY yes|no, status 0 for yes
ui_yesno() {
    local key="$1" title="$2" text="$3" default="${4:-yes}"
    if [[ "$UI_MODE" == answers ]]; then
        _ui_answer "$key" "$default"
    elif _ui_raw_yesno "$title" "$text" "$default"; then
        UI_REPLY=yes
    else
        local rc=$?
        # whiptail returns 255 for Esc
        if [[ "$UI_MODE" == whiptail && $rc -eq 255 ]]; then
            _ui_cancelled
            ui_yesno "$@"
            return
        fi
        UI_REPLY=no
    fi
    [[ "$UI_REPLY" == yes ]]
}

# ui_input KEY TITLE TEXT DEFAULT [VALIDATOR]
# VALIDATOR is a function name; it prints an error and returns 1 for bad input.
ui_input() {
    local key="$1" title="$2" text="$3" default="$4" validator="${5:-}" err=""
    while true; do
        case "$UI_MODE" in
            answers) _ui_answer "$key" "$default" ;;
            text)
                printf '\n== %s ==\n%s%s\n[%s] ' "$title" "${err:+$err$'\n\n'}" "$text" "$default" >&2
                read -r UI_REPLY; UI_REPLY="${UI_REPLY:-$default}" ;;
            *)
                if ! UI_REPLY=$(whiptail --title "$title" --backtitle "$UI_TITLE" \
                        --inputbox "${err:+$err$'\n\n'}$text" "$UI_H" "$UI_W" "$default" 3>&1 1>&2 2>&3); then
                    _ui_cancelled; continue
                fi ;;
        esac
        if [[ -z "$validator" ]] || err=$("$validator" "$UI_REPLY"); then
            return 0
        fi
        [[ "$UI_MODE" == answers ]] && die "answer for $key rejected: $err"
    done
}

# ui_password KEY TITLE TEXT -> UI_REPLY; empty means keep the current value
ui_password() {
    local key="$1" title="$2" text="$3"
    case "$UI_MODE" in
        answers) _ui_answer "$key" "-" ; [[ "$UI_REPLY" == "-" ]] && UI_REPLY="" ;;
        text) printf '\n== %s ==\n%s\n> ' "$title" "$text" >&2; read -rs UI_REPLY; printf '\n' >&2 ;;
        *)
            if ! UI_REPLY=$(whiptail --title "$title" --backtitle "$UI_TITLE" \
                    --passwordbox "$text" "$UI_H" "$UI_W" 3>&1 1>&2 2>&3); then
                _ui_cancelled; ui_password "$@"
            fi ;;
    esac
}

# ui_menu KEY TITLE TEXT DEFAULT TAG ITEM [TAG ITEM...] -> UI_REPLY TAG
ui_menu() {
    local key="$1" title="$2" text="$3" default="$4"; shift 4
    local tags=() i
    for ((i = 1; i <= $#; i += 2)); do tags+=("${!i}"); done
    case "$UI_MODE" in
        answers)
            # Tests read the screens shown from this transcript.
            [[ -n "${HOMEWAN_UI_TRANSCRIPT:-}" ]] && printf '== %s ==\n%s\n' "$title" "$text" >> "$HOMEWAN_UI_TRANSCRIPT"
            _ui_answer "$key" "$default"
            [[ " ${tags[*]} " == *" $UI_REPLY "* ]] || die "answer for $key is '$UI_REPLY', expected one of: ${tags[*]}"
            ;;
        text)
            local n=0 r
            printf '\n== %s ==\n%s\n' "$title" "$text" >&2
            for ((i = 1; i <= $#; i += 2)); do
                local j=$((i + 1)); n=$((n + 1))
                printf '  %d) %s  %s%s\n' "$n" "${!i}" "${!j}" "$([[ "${!i}" == "$default" ]] && printf ' (default)')" >&2
            done
            while true; do
                printf 'Choose 1-%d: ' "$n" >&2; read -r r
                if [[ -z "$r" && -n "$default" ]]; then UI_REPLY="$default"; break; fi
                if [[ "$r" =~ ^[0-9]+$ ]] && ((r >= 1 && r <= n)); then UI_REPLY="${tags[r-1]}"; break; fi
            done ;;
        *)
            local rows=$(( $# / 2 )); ((rows > 10)) && rows=10
            if ! UI_REPLY=$(whiptail --title "$title" --backtitle "$UI_TITLE" --notags \
                    --default-item "$default" --menu "$text" "$UI_H" "$UI_W" "$rows" "$@" 3>&1 1>&2 2>&3); then
                _ui_cancelled; ui_menu "$key" "$title" "$text" "$default" "$@"
            fi ;;
    esac
}

# ui_checklist KEY TITLE TEXT TAG ITEM on|off [...] -> UI_REPLY comma-separated tags
ui_checklist() {
    local key="$1" title="$2" text="$3"; shift 3
    local defaults=() i
    for ((i = 1; i <= $#; i += 3)); do
        local s=$((i + 2)); [[ "${!s}" == on ]] && defaults+=("${!i}")
    done
    case "$UI_MODE" in
        answers) _ui_answer "$key" "$(join , "${defaults[@]}")" ;;
        text)
            local n=0 r picked=()
            printf '\n== %s ==\n%s\n' "$title" "$text" >&2
            for ((i = 1; i <= $#; i += 3)); do
                local j=$((i + 1)) s=$((i + 2)); n=$((n + 1))
                printf '  %d) [%s] %s\n' "$n" "$([[ "${!s}" == on ]] && printf x || printf ' ')" "${!j}" >&2
            done
            printf 'Numbers separated by spaces, or Enter for the ticked ones: ' >&2; read -r r
            if [[ -z "$r" ]]; then UI_REPLY="$(join , "${defaults[@]}")"; return; fi
            local tags=(); for ((i = 1; i <= $#; i += 3)); do tags+=("${!i}"); done
            for i in $r; do [[ "$i" =~ ^[0-9]+$ ]] && ((i >= 1 && i <= n)) && picked+=("${tags[i-1]}"); done
            UI_REPLY="$(join , "${picked[@]}")" ;;
        *)
            local rows=$(( $# / 3 )) out
            ((rows > 10)) && rows=10
            if ! out=$(whiptail --title "$title" --backtitle "$UI_TITLE" --notags --separate-output \
                    --checklist "$text" "$UI_H" "$UI_W" "$rows" "$@" 3>&1 1>&2 2>&3); then
                _ui_cancelled; ui_checklist "$key" "$title" "$text" "$@"; return
            fi
            UI_REPLY="$(printf '%s' "$out" | paste -sd, -)" ;;
    esac
}

# Show progress text for a step that takes a while.
ui_info() {
    case "$UI_MODE" in
        answers) ;;
        text) printf '\n%s\n' "$1" >&2 ;;
        *) TERM=${TERM:-xterm} whiptail --title "Working" --backtitle "$UI_TITLE" --infobox "$1" 8 "$UI_W" ;;
    esac
}
