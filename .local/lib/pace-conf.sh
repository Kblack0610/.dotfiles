# shellcheck shell=bash
# This file is SOURCED, never executed. The one reader of .config/claude-acct/pace.conf, the home of
# the pace numbers: claude-acct's verdict and auth wake, and the wake budget (wake-pace.sh) that
# fleet-dispatch shares. No env override and no default in any script, so every reader sees the same
# line; CLAUDE_ACCT_PACE_CONF names another file (a test's copy).
PACE_CONF="${CLAUDE_ACCT_PACE_CONF:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.config/claude-acct/pace.conf}"

# pace_get KEY -> the value; empty and a line naming the file when it is not set or not a plain
# number, which stops the caller: a missing number must not quietly become a default
pace_get() {
    local v
    v=$(sed -n "/^$1=/{s///p;q;}" "$PACE_CONF" 2>/dev/null)
    if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "${0##*/}: $1 is not set to a number in $PACE_CONF" >&2
        return 0
    fi
    printf '%s' "$v"
}
