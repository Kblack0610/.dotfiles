# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# sentinel-watch.sh -- how a READER judges a sentinel watch's freshness.
#
# The writer is watch-companion-loop (private overlay): it stores the verdict in
# ~/.local/state/watch-companion/<name>.state and the poll time in <name>.lastrun.
# A dead sentinel leaves every .state frozen at its last value, so a reader that
# trusts .state alone shows an unpolled OK as green. Every reader that shows a
# watch (fleet.sh, agent-mqtt-publish -> Prometheus) asks this file instead of
# keeping its own copy of the rule.

# A watch whose last poll is older than this many intervals is stale.
WATCH_STALE_FACTOR=3

# watch_interval_secs <manifest> -> the poll interval in seconds. Same grammar and
# 300s default as watch-companion-loop's to_secs.
watch_interval_secs() {
  local d n
  d="$(awk '/^interval:/ { sub(/^interval:[[:space:]]*/, ""); gsub(/["'\'' ]/, ""); print; exit }' "$1" 2>/dev/null)"
  [[ "$d" =~ ^([0-9]+)([smhd]?)$ ]] && (( BASH_REMATCH[1] > 0 )) || { printf 300; return; }
  n="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]:-s}" in
    s) printf '%s' "$n" ;; m) printf '%s' $(( n * 60 )) ;;
    h) printf '%s' $(( n * 3600 )) ;; d) printf '%s' $(( n * 86400 )) ;;
  esac
}

# watch_is_stale <manifest> <lastrun-epoch> [now] -> exit 0 when stale. A missing or
# non-numeric lastrun is NOT stale: the watch was never polled, and its state says so.
watch_is_stale() {
  local lastrun="${2:-}" now="${3:-$(date +%s)}"
  [[ "$lastrun" =~ ^[0-9]+$ ]] || return 1
  (( now - lastrun > WATCH_STALE_FACTOR * $(watch_interval_secs "$1") ))
}
