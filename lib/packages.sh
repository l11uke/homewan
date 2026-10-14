# shellcheck shell=bash
# Installing small helper packages the interview needs. These are the only
# changes the installer makes before the summary, and only after asking.

# ensure_pkg COMMAND PACKAGE KEY REASON
ensure_pkg() {
    local cmd="$1" pkg="$2" key="$3" reason="$4"
    is_test && return 0
    command -v "$cmd" >/dev/null && return 0
    if ui_yesno "$key" "Install $pkg" "$reason

Install $pkg now? Apart from these small tools, nothing changes on this Pi before you confirm the summary." yes; then
        ui_info "Installing $pkg..."
        if apt-get install -y -q "$pkg" >/dev/null 2>&1; then return 0; fi
        ui_msg - "Install failed" "apt-get could not install $pkg. Check the Pi's internet connection, or run: sudo apt-get update"
    fi
    return 1
}
