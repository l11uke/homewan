# shellcheck shell=bash
# shellcheck disable=SC2034  # globals here are read by the other installer files
# Shared paths, logging and helpers. Sourced by install.sh and bin/homewan.

HOMEWAN_ROOT="${HOMEWAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOMEWAN_ETC="${HOMEWAN_ETC:-/etc/homewan}"
HOMEWAN_PY="$HOMEWAN_ROOT/lib/py"
SITE_CONF="$HOMEWAN_ETC/site.conf"
SECRETS_ENV="$HOMEWAN_ETC/secrets.env"
ANSWERS_DRAFT="$HOMEWAN_ETC/answers.draft"
HOMEWAN_CONFIG_VERSION=1

# Test mode: answers come from a file and system probes read fixtures.
# Only the test suite sets HOMEWAN_TEST=1.
HOMEWAN_TEST="${HOMEWAN_TEST:-0}"
HOMEWAN_FIXTURES="${HOMEWAN_FIXTURES:-}"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'homewan: %s\n' "$*" >&2; exit 1; }

is_test() { [[ "$HOMEWAN_TEST" == "1" ]]; }

# Run a system probe, or read its fixture file in test mode.
# Usage: probe NAME command [args...]
probe() {
    local name="$1"; shift
    if is_test && [[ -n "$HOMEWAN_FIXTURES" ]]; then
        if [[ -f "$HOMEWAN_FIXTURES/$name" ]]; then
            cat "$HOMEWAN_FIXTURES/$name"
        fi
        return 0
    fi
    "$@" 2>/dev/null || true
}

py() { python3 -I "$HOMEWAN_PY/$1" "${@:2}"; }

# Join arguments with a separator: join , a b c -> a,b,c
join() { local IFS="$1"; shift; printf '%s' "$*"; }

# True when a comma-separated list contains an item.
list_has() { [[ ",$1," == *",$2,"* ]]; }
