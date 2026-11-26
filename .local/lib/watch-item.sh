# shellcheck shell=bash
# watch-item.sh - the one check that a red item for a Sentinel watch may close ok: agent-land's
# watch_gate and agent-queue's move to done --status ok both read it (ar-5414), so a close by hand
# cannot claim a red is gone while its watch still trips.

# item_watch <tags> <title> -> the watch name when the item is a `red` item for a Sentinel watch
# (title `check(watch): <name> ...`), empty otherwise.
item_watch() {
  [[ " $1 " == *" red "* ]] || return 0
  [[ "$2" =~ ^check\(watch\):\ ([A-Za-z0-9._-]+) ]] || return 0
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# watch_probe <verb> <watch> [args...]: runs `watch-companion-loop <verb> <watch> [args...]` and prints
# one line. Returns 0 when the watch reads OK, is not known here (exit 2 with "no watch named"), or no
# loop is on PATH, the line saying which; 75 when the loop could not take its lock (a caller retries);
# 1 when it still trips or the call failed, the line saying why. Exit 2 is also a usage error (a loop
# with no resolve), so only "no watch named" skips the check.
watch_probe() {
  local verb=$1 w=$2 out rc=0
  command -v watch-companion-loop >/dev/null 2>&1 || { echo "watch: $w not checked (no watch-companion-loop on PATH)"; return 0; }
  out=$(watch-companion-loop "$@" 2>&1) || rc=$?
  case "$rc" in
    0) echo "watch: $w OK" ;;
    2) [[ "$out" == *"no watch named $w"* ]] || { echo "watch-companion-loop $verb $w: $(printf '%s' "$out" | tail -n 1)"; return 1; }
       echo "watch: $w not known here (exit 2), skipping probe check" ;;
    75) echo "watch-companion-loop $verb $w could not take the lock (exit 75); re-run"; return 75 ;;
    *) echo "watch $w did not read OK on $verb (exit $rc)${out:+: $(printf '%s' "$out" | tail -n 1)}"; return 1 ;;
  esac
}

# watch_route_owned <watch>: 0 and the route when triage-routes sends the watch's red to `alert` or
# `owned:<row>`. Such an item's job is the ask or the owner, not the red (no merge clears an alert
# route's KPI), so it closes ok while the watch still trips, and cause_tries reads that close as the
# cause's owner. 1 for any other route, and when fleet-bench cannot say, so the probe decides.
watch_route_owned() {
  local r
  r=$(fleet-bench triage --route "watch $1" 2>/dev/null | cut -f2) || return 1
  case "$r" in alert | owned:?*) printf '%s\n' "$r"; return 0 ;; esac
  return 1
}
