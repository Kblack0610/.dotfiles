#!/usr/bin/env bash
# shellcheck shell=bash
# claude-acct's sign-in state: the auth and wake verbs and check auth/expiry. Sourced by claude-acct,
# which owns CONF, CACHE, MAIN_DIR, pace_get and accounts(); it runs nowhere else.
#
# A signed-out account looks like nothing from outside: no usage call fails loudly, the sessions on
# it just sit on "Not logged in". On 2026-11-17 15:49 a test wrote {} over every account's
# .credentials.json and 19 sessions stopped with nothing paged. So the sign-in state is read from
# the files and the panes themselves, never from a usage answer:
#   logged_in   the file holds a refresh token (an access token alone ends in hours)
#   written     the file's mtime: Claude rewrites it on a login and on every refresh, so it is the
#               last successful refresh (or login); a logout writes it too, and logged_in says which
#   stuck       an idle session (agent-panel list) whose pane shows "Not logged in" in its last lines
# The numbers (grace, warning, wake batch) are in pace.conf.

AUTH_PANE_RE='Not logged in.*Please run /login'
AUTH_PANE_LINES=8
WAKE_TEXT="${CLAUDE_ACCT_WAKE_TEXT:-You were signed out and are signed in again. Carry on with what you were doing.}"
WAKE_STATE="$CACHE/wake"
# seconds -> "2d 3h", "5h 10m" or "12m"
AUTH_JQ='def span: (if . < 0 then -. else . end) as $s
    | if $s >= 86400 then "\($s / 86400 | floor)d \($s % 86400 / 3600 | floor)h"
      elif $s >= 3600 then "\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m"
      else "\($s / 60 | floor)m" end;'

# auth_conf -> sets AUTH_GRACE_S (an expired access token this old, with sessions working, is a
# refresh that failed), AUTH_WARN_S (a refresh token this near its end is warned) and WAKE_*;
# fails when pace.conf lacks one, so a typo is never a silent default.
auth_conf() {
    local g w gap
    g=$(pace_get AUTH_REFRESH_GRACE_MIN); w=$(pace_get AUTH_WARN_DAYS); gap=$(pace_get WAKE_GAP_MIN)
    WAKE_BATCH=$(pace_get WAKE_BATCH); WAKE_LOAD_PCT=$(pace_get WAKE_LOAD_PCT); WAKE_TRIES=$(pace_get WAKE_TRIES)
    [[ -n "$g" && -n "$w" && -n "$gap" && -n "$WAKE_BATCH" && -n "$WAKE_LOAD_PCT" && -n "$WAKE_TRIES" ]] || return 2
    AUTH_GRACE_S=$((g * 60)); AUTH_WARN_S=$((w * 86400)); WAKE_GAP_S=$((gap * 60))
}

# stuck_panes <agent-panel rows> -> "pane US target US account" for each idle Claude session whose
# pane's last AUTH_PANE_LINES lines say Not logged in. Only the tail counts: a session that quotes
# the words higher up, or went on after a login, is not stuck. A busy one is working, so not stuck.
stuck_panes() {
    local pane target acct
    while IFS=$'\t' read -r pane target acct; do
        timeout 10 tmux -L "${pane%%/*}" capture-pane -p -t "${pane#*/}" 2>/dev/null |
            awk -v re="$AUTH_PANE_RE" -v n="$AUTH_PANE_LINES" 'NF { a[c++] = $0 } END { for (i = c - n; i < c; i++) if (i >= 0 && a[i] ~ re) f = 1; exit !f }' || continue
        printf '%s\037%s\037%s\n' "$pane" "$target" "$acct"
    done < <(jq -r 'select(.harness == "claude" and .status == "idle" and (.parked | not)) | [.pane, .target, .account] | @tsv' <<< "$1")
}

# auth_state -> sets PANEL (agent-panel's rows), STUCK (stuck_panes) and ROWS (auth_rows)
auth_state() {
    local rc=0
    PANEL=$(timeout 20 agent-panel list --json 2>/dev/null) || rc=$?
    # 3 is a read with a gap: the rows it printed still count
    PANEL_OK=1
    (( rc == 0 || rc == 3 )) || { PANEL_OK=0; echo "claude-acct: agent-panel list failed ($rc), so no sessions are counted" >&2; }
    STUCK=$(stuck_panes "$PANEL")
    ROWS=$(auth_rows)
}

# login_tsv <creds> -> "a_ok TAB r_ok TAB a_exp TAB r_exp" of a credentials file (epochs, 0 when
# unset); exit 1 when it cannot be read. The one reader of a login: auth_rows and fetch's rank.
login_tsv() {
    jq -r '(.claudeAiOauth // {}) | [((.accessToken // "") != ""), ((.refreshToken // "") != ""),
        ((.expiresAt // 0) / 1000 | floor), ((.refreshTokenExpiresAt // 0) / 1000 | floor)] | @tsv' "$1" 2>/dev/null
}

# refresh_live <r_ok> <r_exp> <now>: the refresh token is there and not past its end (0: no end
# recorded). Without it a launch cannot refresh, so the account is signed out.
refresh_live() { [[ "$1" == true ]] && (( $2 == 0 || $2 > $3 )); }

# auth_rows -> one JSON object a line per Claude account: name, relogin (the command), logged_in,
# why (empty when logged in), access_expires, refresh_expires, written (epochs, 0 when unknown),
# working (busy sessions) and stuck (panes on Not logged in). Reads PANEL and STUCK.
auth_rows() {
    local name dir creds tsv a_ok r_ok a_exp r_exp written why working n now="${CLAUDE_ACCT_NOW:-$(date +%s)}"
    while IFS=$'\037' read -r name dir; do
        creds="${dir:-$MAIN_DIR}/.credentials.json"
        a_ok=false r_ok=false a_exp=0 r_exp=0 written=0 why=""
        if [[ ! -e "$creds" ]]; then
            why="no credentials file"
        elif tsv=$(login_tsv "$creds"); then
            read -r a_ok r_ok a_exp r_exp <<< "$tsv"
            written=$(stat -c %Y "$creds" 2>/dev/null || echo 0)
            if [[ "$r_ok" == true ]] && ! refresh_live "$r_ok" "$r_exp" "$now"; then r_ok=false; why="its login ended $(( (now - r_exp) / 3600 ))h ago"
            elif [[ "$r_ok" != true && "$a_ok" != true ]]; then why="the credentials file holds no login"
            elif [[ "$r_ok" != true ]]; then why="no refresh token"; fi
        else
            why="credentials file unreadable"
        fi
        working=$(jq -s --arg n "$name" '[.[] | select(.account == $n and .status == "busy")] | length' <<< "$PANEL")
        n=$(awk -F'\037' -v a="$name" 'NF && $3 == a { c++ } END { print c + 0 }' <<< "$STUCK")
        jq -nc --arg name "$name" --arg why "$why" --argjson ok "$r_ok" --argjson ae "$a_exp" --argjson re "$r_exp" \
            --argjson w "$written" --argjson working "$working" --argjson stuck "$n" \
            '{name: $name, relogin: "cl --acct \($name), then /login", logged_in: $ok, why: $why, access_expires: $ae,
              refresh_expires: $re, written: $w, working: $working, stuck: $stuck}'
    done < <(accounts)
}

# auth_prom -> the textfile lines for the sign-in state
auth_prom() {
    auth_state
    jq -rs '
        def rows($metric; f): .[] | f as $v | select($v != null) | "\($metric){account=\"\(.name)\",kind=\"claude\"} \($v)";
        (rows("claude_account_logged_in"; if .logged_in then 1 else 0 end)),
        (rows("claude_account_access_expires_timestamp_seconds"; if .access_expires > 0 then .access_expires else null end)),
        (rows("claude_account_refresh_expires_timestamp_seconds"; if .refresh_expires > 0 then .refresh_expires else null end)),
        (rows("claude_account_credentials_written_timestamp_seconds"; if .written > 0 then .written else null end)),
        (rows("claude_account_not_logged_in_sessions"; .stuck)),
        "claude_fleet_signed_out_accounts \(map(select(.logged_in | not)) | length)",
        "claude_fleet_not_logged_in_sessions \(map(.stuck) | add // 0)"' <<< "$ROWS"
}

# auth [--json] -> every account's sign-in state
cmd_auth() {
    local now="${CLAUDE_ACCT_NOW:-$(date +%s)}"
    auth_state
    [[ -n "$ROWS" ]] || { echo "claude-acct: no accounts in $CONF" >&2; return 2; }
    if [[ "${1:-}" == --json ]]; then jq -s . <<< "$ROWS"; return 0; fi
    { printf 'ACCOUNT\tLOGGED-IN\tACCESS-TOKEN\tLOGIN-ENDS\tWRITTEN\tWORKING\tNOT-LOGGED-IN\n'
      jq -r --argjson now "$now" "$AUTH_JQ"'
          def at($t): if $t == 0 then "-" elif $t > $now then "in \(($t - $now) | span)" else "\(($now - $t) | span) ago" end;
          [.name, (if .logged_in then "yes" else "NO:\(.why | gsub(" "; "_"))" end), at(.access_expires), at(.refresh_expires),
           at(.written), .working, .stuck] | @tsv' <<< "$ROWS"; } | column -t -s $'\t'
}

# check auth: an account signed out, a refresh that failed, or a pane wake could not move. One line
# naming each account and the command that signs it in again; exit 1 when tripped. A pane stuck on a
# signed-in account is wake's to move first, so it trips only once wake gave up on it. A session on a
# setup token (CLAUDE_CODE_OAUTH_TOKEN) never reads or refreshes the file, so for an account that has
# one the file's access token ending says nothing about its sessions: only the login ending does.
auth_check() {
    local now="${CLAUDE_ACCT_NOW:-$(date +%s)}" bad n tok
    auth_conf || return 2
    auth_state
    [[ -n "$ROWS" ]] || { echo "no accounts in $CONF"; return 2; }
    # asked only for an account the refresh rule would name, so a quiet check never reads rbw
    tok=$(while read -r n; do acct_token "$n" </dev/null >/dev/null 2>&1 && echo "$n"; done < <(jq -rs --argjson now "$now" --argjson grace "$AUTH_GRACE_S" \
        '.[] | select(.logged_in and .working > 0 and .access_expires > 0 and (.access_expires + $grace) < $now) | .name' <<< "$ROWS") |
        jq -Rsc 'split("\n") | map(select(. != ""))')
    tok=${tok:-[]}
    bad=$(jq -rs --argjson now "$now" --argjson grace "$AUTH_GRACE_S" --argjson gave "$(wake_gave_up)" --argjson tok "$tok" '
        .[] | . as $a
        | (if (.logged_in | not) then "signed out (\(.why))\(if .stuck > 0 then ", \(.stuck) sessions on Not logged in" else "" end)"
           elif .working > 0 and .access_expires > 0 and (.access_expires + $grace) < $now and (($tok | index($a.name)) | not)
             then "not refreshing: its access token ended \((($now - .access_expires) / 60) | floor)m ago with \(.working) sessions working"
           elif ($gave[$a.name] // 0) > 0 then "\($gave[$a.name]) sessions stay on Not logged in after the wakes"
           else empty end) as $why
        | "\(.name) \($why): \(.relogin)"' <<< "$ROWS")
    if [[ -z "$bad" ]]; then echo "$(grep -c . <<< "$ROWS") accounts signed in"; return 0; fi
    paste -sd';' <<< "$bad" | sed 's/;/; /g'
    return 1
}

# check expiry: a refresh token that ends within AUTH_WARN_DAYS. Claude rewrites it on every refresh,
# so an account in use does not get here; one left idle does, and its next session would start
# signed out.
expiry_check() {
    local now="${CLAUDE_ACCT_NOW:-$(date +%s)}" soon
    auth_conf || return 2
    ROWS=$(PANEL='' STUCK='' auth_rows)
    [[ -n "$ROWS" ]] || { echo "no accounts in $CONF"; return 2; }
    soon=$(jq -rs --argjson now "$now" --argjson warn "$AUTH_WARN_S" "$AUTH_JQ"'
        .[] | select(.logged_in and .refresh_expires > 0 and (.refresh_expires - $now) < $warn)
        | "\(.name) login ends in \((.refresh_expires - $now) | span): \(.relogin)"' <<< "$ROWS")
    if [[ -z "$soon" ]]; then echo "no login ends within $((AUTH_WARN_S / 86400)) days"; return 0; fi
    paste -sd';' <<< "$soon" | sed 's/;/; /g'
    return 1
}

# wake_gave_up -> {"<account>": panes} for the panes wake tried WAKE_TRIES times (its ledger: one file
# a pane, "tries epoch account") that still show Not logged in
wake_gave_up() {
    local f t acct
    [[ -d "$WAKE_STATE" ]] || { echo '{}'; return 0; }
    for f in "$WAKE_STATE"/*; do
        [[ -f "$f" ]] || continue
        read -r t _ acct < "$f" || continue
        (( t >= WAKE_TRIES )) && printf '%s\n' "$acct"
    done | jq -Rsc 'split("\n") | map(select(. != "")) | group_by(.) | map({key: .[0], value: length}) | from_entries'
}

# wake [--dry-run]: a session stopped on Not logged in, on an account that is signed in again, gets
# WAKE_TEXT typed in through `agent-panel send`. At most WAKE_BATCH a run, one when the machine is
# past WAKE_LOAD_PCT of its cores (a wake starts a model turn each), a pane no sooner than
# WAKE_GAP_MIN after its last wake and never more than WAKE_TRIES times: a pane that stays stuck is
# check auth's to page.
cmd_wake() {
    local dry=0 now="${CLAUDE_ACCT_NOW:-$(date +%s)}" batch f keep pane target acct ok human t at n=0
    [[ "${1:-}" == --dry-run ]] && dry=1
    auth_conf || return 2
    auth_state
    # with no panel read nothing is known about any pane: no wake, and the ledger stays as it is
    (( PANEL_OK )) || return 1
    mkdir -p "$WAKE_STATE"
    # a pane that is idle and shows no Not logged in, or is gone, is forgotten, so a later sign-out
    # starts its tries again; a pane at work or parked keeps its tries
    keep=$({ cut -d$'\037' -f1 <<< "$STUCK"
             jq -r 'select(.harness == "claude" and (.status != "idle" or .parked)) | .pane' <<< "$PANEL"; } | tr / _)
    for f in "$WAKE_STATE"/*; do
        [[ -f "$f" ]] || continue
        grep -qxF "${f##*/}" <<< "$keep" || rm -f "$f"
    done
    [[ -n "$STUCK" ]] || return 0
    batch=$WAKE_BATCH
    awk -v l="$(cut -d' ' -f1 "${CLAUDE_ACCT_LOADAVG:-/proc/loadavg}" 2>/dev/null || echo 0)" -v c="$(nproc 2>/dev/null || echo 1)" \
        -v p="$WAKE_LOAD_PCT" 'BEGIN { exit !(l * 100 >= c * p) }' && batch=1
    while IFS=$'\037' read -r pane target acct; do
        [[ -n "$pane" ]] || continue
        ok=$(jq -rs --arg n "$acct" '[.[] | select(.name == $n and .logged_in)] | length' <<< "$ROWS")
        [[ "$ok" == 1 ]] || continue
        # a human who touched the pane lately may have a draft in its input box
        human=$(jq -rs --arg p "$pane" '[.[] | select(.pane == $p) | .human_at // 0] | first // 0' <<< "$PANEL")
        (( now - human < WAKE_GAP_S )) && continue
        f="$WAKE_STATE/${pane//\//_}"
        t=0 at=0
        [[ -f "$f" ]] && read -r t at _ < "$f"
        (( t >= WAKE_TRIES || now - at < WAKE_GAP_S )) && continue
        (( n >= batch )) && break
        if (( dry )); then
            echo "would wake $target ($pane, account $acct)"
        else
            # a try counts whether or not the pane took it, so a pane that never does reaches check auth
            printf '%s %s %s\n' $((t + 1)) "$now" "$acct" > "$f"
            if timeout 30 agent-panel send --pane "$pane" "$WAKE_TEXT"; then
                echo "woke $target ($pane, account $acct), try $((t + 1)) of $WAKE_TRIES"
            else
                echo "could not wake $target ($pane, account $acct), try $((t + 1)) of $WAKE_TRIES" >&2
            fi
        fi
        n=$((n + 1))
    done <<< "$STUCK"
    return 0
}
