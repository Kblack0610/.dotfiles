# shellcheck shell=bash
# This file is SOURCED, never executed. The one reader of .config/claude-acct/pace.conf, the home of
# the pace numbers: claude-acct's verdict and auth wake, and the wake budget (wake-pace.sh) that
# fleet-dispatch shares. No env override and no default in any script, so every reader sees the same
# line; CLAUDE_ACCT_PACE_CONF names another file (a test's copy).
#
# It is also the one reader and writer of the overrides file, PACE_OVERRIDES (a test's scratch copy;
# ~/.agent/pace-overrides on the machine), which `pace-conf` sets and ends. One row per override,
# key|value|from|until|by, times in epoch seconds: an empty until is the key's standing override,
# a set one a window. pace_get takes a window in force now, else the standing override, else the
# pace.conf line, so a window that ends falls back by itself with no timer (a read-time expiry).
# Usage and troubleshooting: .local/src/docs/pace-conf.md.
PACE_CONF="${CLAUDE_ACCT_PACE_CONF:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.config/claude-acct/pace.conf}"
PACE_OVERRIDES="${PACE_OVERRIDES:-$HOME/.agent/pace-overrides}"

# pace_now -> epoch seconds; PACE_NOW is a test's clock
pace_now() { printf '%s' "${PACE_NOW:-${EPOCHSECONDS:-$(date +%s)}}"; }

# pace_row_ok KEY VALUE FROM UNTIL -> exit 0 when a row is well formed: a numeric value, an epoch
# from, and an until that is empty or an epoch
pace_row_ok() {
    [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ && "$2" =~ ^[0-9]+(\.[0-9]+)?$ && "$3" =~ ^[0-9]+$ && "$4" =~ ^([0-9]+)?$ ]]
}

# pace_default KEY -> the pace.conf line's value as written, unchecked; empty when there is none
pace_default() { sed -n "/^$1=/{s///p;q;}" "$PACE_CONF" 2>/dev/null; }

# pace_keys -> every key pace.conf sets, in its order
pace_keys() { sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$PACE_CONF" 2>/dev/null; }

# _pace_in_force KEY -> "<value>\t<source>" from the overrides file: source is `window <until>` for a
# window in force now, else `override` for the standing one; nothing when neither. Exit 1 on a
# malformed row of KEY, which pace_get turns into the stop a bad pace.conf line is.
_pace_in_force() {
    local now k v f u by win="" std=""
    [[ -r "$PACE_OVERRIDES" ]] || return 0
    now=$(pace_now)
    while IFS='|' read -r k v f u by || [[ -n "$k" ]]; do
        [[ "$k" == "$1" ]] || continue
        pace_row_ok "$k" "$v" "$f" "$u" || return 1
        if [[ -z "$u" ]]; then std="$v"$'\toverride'
        elif ((f <= now && now < u)); then win="$v"$'\twindow '"$u"
        fi
    done < "$PACE_OVERRIDES"
    printf '%s' "${win:-$std}"
}

# pace_get KEY -> the value in force; empty and a line naming the file when it is not set or not a
# plain number, which stops the caller: a missing number must not quietly become a default. The
# check is the same whichever source the value came from.
pace_get() {
    local v row src="$PACE_CONF"
    if ! row=$(_pace_in_force "$1"); then
        echo "${0##*/}: a $1 row in $PACE_OVERRIDES is not key|value|from|until|by (pace-conf end $1 drops it, or delete the line)" >&2
        return 0
    fi
    if [[ -n "$row" ]]; then v=${row%%$'\t'*}; src=$PACE_OVERRIDES
    else v=$(pace_default "$1"); fi
    if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "${0##*/}: $1 is not set to a number in $src" >&2
        return 0
    fi
    printf '%s' "$v"
}

# pace_source KEY -> where pace_get's value comes from: `default` (pace.conf), `override` (a
# standing override) or `window <until epoch>`; empty when a row of KEY is malformed
pace_source() {
    local row
    row=$(_pace_in_force "$1") || return 0
    if [[ -z "$row" ]]; then echo default; else echo "${row#*$'\t'}"; fi
}

# pace_write FILTER [ARG...] -> under the lock, FILTER reads the overrides file's rows on stdin and
# prints the new ones. Ended windows are dropped (a malformed row is kept, so it still stops its
# readers until `pace-conf end` drops it), and the file is replaced whole (tmp + mv, as
# machine-mode's write_state does), so a reader never sees half a write. A FILTER that fails
# leaves the file as it was, and pace_write returns its failure.
pace_write() {
    mkdir -p "$(dirname "$PACE_OVERRIDES")" || return 1
    (
        set -o pipefail
        flock -w 10 9 || { echo "${0##*/}: $PACE_OVERRIDES.lock is held by another write" >&2; exit 1; }
        tmp=$(mktemp "$PACE_OVERRIDES.XXXXXX") || exit 1
        trap 'rm -f "$tmp"' EXIT
        { [[ ! -r "$PACE_OVERRIDES" ]] || cat "$PACE_OVERRIDES"; } | "$@" \
            | awk -F'|' -v now="$(pace_now)" '!($4 ~ /^[0-9]+$/ && $4 + 0 <= now)' > "$tmp" || exit 1
        mv -f "$tmp" "$PACE_OVERRIDES"
    ) 9>>"$PACE_OVERRIDES.lock"
}
