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

: "${WAKE_BATCH:=3}"   # wakes per settle window: fleet-pace's GO batch ("at most 3 sessions per pass"); 7 at once took load 28.8 to 69 on 24 cores (2026-10-26)
: "${WAKE_SETTLE_MIN:=5}"   # minutes a wake counts against the batch: its load is not in the 1-minute average yet (DISPATCH_START_LOAD_MIN, measured 2026-11-07)
WAKE_LEDGER="${WAKE_PACE_LEDGER:-${XDG_STATE_HOME:-$HOME/.local/state}/wake-pace/wakes}"

# wake_recent -> the wakes in the ledger inside the settle window
wake_recent() {
  local since=$(( $(date +%s) - WAKE_SETTLE_MIN * 60 ))
  awk -F'\t' -v s="$since" '$1 >= s { n++ } END { print n + 0 }' "$WAKE_LEDGER" 2>/dev/null || echo 0
}

# wake_room -> how many sessions may wake now: none while the machine reads HOLD (over the high mark,
# or not yet back under the low one while a load hold is set, the CLEAR fleet-pace's go waits for),
# else what the batch has left in the settle window. No fleet-assess (a Mac runner) leaves the batch.
wake_room() {
  local n
  if command -v fleet-assess >/dev/null 2>&1 && ! fleet-assess --watch-probe >/dev/null 2>&1; then
    echo 0; return 0
  fi
  n=$(wake_recent)
  echo $(( n >= WAKE_BATCH ? 0 : WAKE_BATCH - n ))
}

# wake_take <who> <what> -- take one wake from the budget, rc 1 when it has none. The ledger keeps
# only the settle window, so it never grows.
wake_take() {
  local since rc=1 _wake_fd
  mkdir -p "${WAKE_LEDGER%/*}" || return 1
  exec {_wake_fd}>"$WAKE_LEDGER.lock"
  flock "$_wake_fd" || { exec {_wake_fd}>&-; return 1; }
  if [ "$(wake_room)" -gt 0 ]; then
    since=$(( $(date +%s) - WAKE_SETTLE_MIN * 60 ))
    { awk -F'\t' -v s="$since" '$1 >= s' "$WAKE_LEDGER" 2>/dev/null
      printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2"; } > "$WAKE_LEDGER.tmp" && mv -f "$WAKE_LEDGER.tmp" "$WAKE_LEDGER" && rc=0
  fi
  exec {_wake_fd}>&-
  return "$rc"
}
