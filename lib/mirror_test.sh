# shellcheck shell=bash
# shellcheck disable=SC2034  # globals here are read by the other installer files
# Mirror test (SPEC 4.5): capture on the capture interface while pinging a
# public address from the management interface, then classify what arrived.

MIRROR_TARGET="9.9.9.9"

# mirror_test CAPTURE_IFACE MGMT_IFACE LAN_SUBNET -> MIRROR_VERDICT, MIRROR_SRC, MIRROR_PACKETS, MIRROR_PPPOE
mirror_test() {
    local cap="$1" mgmt="$2" subnet="$3" result
    if is_test; then
        result="$(probe mirror-capture true | py mirror_classify.py "$MIRROR_TARGET" "$subnet")"
    else
        local pcap; pcap="$(mktemp --suffix=.pcap)"
        timeout 25 tcpdump -nn -e -i "$cap" -c 20000 -w "$pcap" >/dev/null 2>&1 &
        local tpid=$!
        sleep 3
        ping -I "$mgmt" -c 5 -i 0.5 -W 2 "$MIRROR_TARGET" >/dev/null 2>&1
        sleep 4
        kill "$tpid" 2>/dev/null; wait "$tpid" 2>/dev/null
        result="$(tcpdump -nn -e -r "$pcap" 2>/dev/null | py mirror_classify.py "$MIRROR_TARGET" "$subnet")"
        rm -f "$pcap"
    fi
    IFS=$'\t' read -r MIRROR_VERDICT MIRROR_SRC MIRROR_PACKETS MIRROR_PPPOE <<<"$result"
}

ensure_tcpdump() {
    ensure_pkg tcpdump tcpdump INSTALL_TCPDUMP "The mirror test needs tcpdump, a small packet capture tool."
}
