# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# wake-pace.sh - the one budget every bulk wake draws from: fleet-dispatch restore, its unpark of
# preempted sessions, `claude-acct unpark --all`. A wake is a session told to carry on, which reruns
# its gate, suite or Unity run, so it costs load the 1-minute average does not show for minutes.
#
#   wake_take <who> <what>   rc 0 and one wake recorded when the budget has room, rc 1 when not
#   wake_room                how many may wake now (0 while fleet-assess reads HOLD)
#
# 2026-11-17 10:29: a restore woke 22 sessions at once after a reboot, load 127 on 32 cores and Tctl
# 96 C. One ledger for every caller, taken under one lock, so no caller, and no two callers together,
# wake more than a fleet-pace GO batch inside the settle window. A hand unpark or start of one session
# is the human's and never draws on it (the repo CLAUDE.md "Hard limits on budgets").

# shellcheck source=pace-conf.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/pace-conf.sh"
# WAKE_BUDGET: wakes per settle window, fleet-pace's GO batch. WAKE_SETTLE_MIN: minutes a wake counts
# against it, its load not in the 1-minute average yet. Both are in pace.conf, with their why.
WAKE_BUDGET=$(pace_get WAKE_BUDGET); WAKE_SETTLE_MIN=$(pace_get WAKE_SETTLE_MIN)
WAKE_LEDGER="${WAKE_PACE_LEDGER:-${XDG_STATE_HOME:-$HOME/.local/state}/wake-pace/wakes}"

# wake_window -> the ledger's lines inside the settle window
wake_window() {
  awk -F'\t' -v s="$(( EPOCHSECONDS - WAKE_SETTLE_MIN * 60 ))" '$1 >= s' "$WAKE_LEDGER" 2>/dev/null
}

# wake_recent -> the wakes in the ledger inside the settle window
wake_recent() { wake_window | wc -l; }

# wake_room -> how many sessions may wake now: none while the machine reads HOLD (over the high mark,
# or not yet back under the low one while a load hold is set, the CLEAR fleet-pace's go waits for),
# else what the batch has left in the settle window. No fleet-assess (a Mac runner) leaves the batch.
wake_room() {
  local n
  # A number missing from pace.conf, or not whole, wakes nobody, never a default batch, and says so at each refusal.
  [[ "$WAKE_BUDGET" =~ ^[0-9]+$ && "$WAKE_SETTLE_MIN" =~ ^[0-9]+$ ]] || { echo "wake-pace: no wake: WAKE_BUDGET or WAKE_SETTLE_MIN is not a whole number in $PACE_CONF" >&2; echo 0; return 0; }
  if command -v fleet-assess >/dev/null 2>&1 && ! fleet-assess --watch-probe >/dev/null 2>&1; then
    echo 0; return 0
  fi
  n=$(wake_recent)
  echo $(( n >= WAKE_BUDGET ? 0 : WAKE_BUDGET - n ))
}

# wake_take <who> <what> -- take one wake from the budget, rc 1 when it has none. The ledger keeps
# only the settle window, so it never grows. Once refused, the rest of this process's wakes are
# refused without asking again: a bulk walk's later items would read the same HOLD or spent batch.
WAKE_REFUSED=0
wake_take() {
  local rc=1 _wake_fd
  [ "$WAKE_REFUSED" = 0 ] || return 1
  mkdir -p "${WAKE_LEDGER%/*}" || return 1
  exec {_wake_fd}>"$WAKE_LEDGER.lock"
  flock "$_wake_fd" || { exec {_wake_fd}>&-; return 1; }
  if [ "$(wake_room)" -gt 0 ]; then
    { wake_window; printf '%s\t%s\t%s\n' "$EPOCHSECONDS" "$1" "$2"; } > "$WAKE_LEDGER.tmp" &&
      mv -f "$WAKE_LEDGER.tmp" "$WAKE_LEDGER" && rc=0
  fi
  exec {_wake_fd}>&-
  [ "$rc" = 0 ] || WAKE_REFUSED=1
  return "$rc"
}
