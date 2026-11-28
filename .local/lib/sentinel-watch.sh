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
# watch (fleet.sh, fleet-bench triage and health, agent-mqtt-publish ->
# Prometheus) asks this file instead of keeping its own copy of the rule.

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

# watch_severity <manifest> -> low|normal|high|urgent. Same default as watch-companion-loop:
# missing, or a word `sentinel-manifest validate` refuses, reads as normal. A trailing
# `# comment` is dropped, as the YAML parser watch-companion-loop loads manifests with drops it.
watch_severity() {
  local s
  s="$(awk '/^severity:/ { sub(/^severity:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/["'\'' ]/, ""); print; exit }' "$1" 2>/dev/null)"
  case "$s" in low|normal|high|urgent) printf '%s' "$s" ;; *) printf normal ;; esac
}

# watch_trip_level <manifest> <state dir> -> low|normal|high|urgent: the level of the trip now on, from
# the `<name>.level` file watch-companion-loop writes off a probe's `page:` line (alertmanager-fleet:
# the highest level its firing alerts map to), else watch_severity. Read only while the state is TRIP
# (the loop drops the file at any other state), so a reader's priority for a warning-only trip is not
# the manifest's fixed fallback.
watch_trip_level() {
  local n l
  n="$(basename "$1" .paused)"; n="${n%.yaml}"
  l="$(cat "$2/$n.level" 2>/dev/null)"
  [ "$(cat "$2/$n.state" 2>/dev/null)" = TRIP ] || l=
  case "$l" in low|normal|high|urgent) printf '%s' "$l" ;; *) watch_severity "$1" ;; esac
}

# watch_is_stale <manifest> <lastrun-epoch> [now] -> exit 0 when stale. A missing or
# non-numeric lastrun is NOT stale: the watch was never polled, and its state says so.
watch_is_stale() {
  local lastrun="${2:-}" now="${3:-$(date +%s)}"
  [[ "$lastrun" =~ ^[0-9]+$ ]] || return 1
  (( now - lastrun > WATCH_STALE_FACTOR * $(watch_interval_secs "$1") ))
}

# log_norm: a line with what varies between runs taken out, so one error is one signature: a leading
# timestamp, quoted strings, paths, hex ids and numbers become placeholders. fleet-bench signs stderr
# lines and a watch row's why with it.
log_norm() {
  sed -E 's/^\[[^]]*\][[:space:]]*//; s/"[^"]*"/"Q"/g; s/'"'"'[^'"'"']*'"'"'/'"'"'Q'"'"'/g
          s#(~|\.)?(/[^[:space:]/:"'"'"']+)+/?#P#g; s/\b[0-9a-f]{7,}\b/H/g; s/[0-9]+/N/g; s/[[:space:]]+/ /g; s/ $//'
}

# watch_red_lines <evidence file> -> the red lines a watch's redacted evidence (<name>.out) names, as
# written, in order: each `RED` line of a probe that prints one OK or RED line a stage
# (unity-core-playground's release-ready.py); else, for a probe that prints a status row a vendor
# (vendor-check: `<name> OK|LOW|EXPIRED|NO_CREDS probe=<p> [detail=...]`), its worst rows without a
# `gap:` owner, detail left off (log_norm turns it into 'Q'): each EXPIRED or NO_CREDS, else each LOW,
# so an OK row or a LOW one after the culprit is not blamed; else its last non-blank line, usually the
# error. The first, through log_norm, is fleet-bench triage's why; the set is what a quarantine
# covers. Nothing when the file is missing.
watch_red_lines() {
  { grep -E '^RED[[:space:]]' "$1" \
      || awk '/^[^[:space:]]+ (EXPIRED|NO_CREDS|LOW) probe=/ && !/ gap: / {
                sub(/ detail=.*/, ""); r = ($2 == "LOW") ? 1 : 0; row[++n] = $0; rk[n] = r; if (!seen || r < best) { best = r; seen = 1 } }
              END { if (!seen) exit 1; for (i = 1; i <= n; i++) if (rk[i] == best) print row[i] }' "$1" \
      || grep -v '^[[:space:]]*$' "$1" | tail -n 1; } 2>/dev/null
}

# watch_red_key: a red line as a quarantine compares it, a leading timestamp dropped and each number
# N, so a new reading or time is the same red. Lighter than log_norm on purpose: a unit, path or quoted
# name stays, so `b.service failed` is not covered by a quarantine taken on `a.service failed`.
watch_red_key() {
  sed -E 's/^\[[^]]*\][[:space:]]*//; s/[0-9]+/N/g; s/[[:space:]]+/ /g; s/ $//'
}

# watch_uncovered <state dir> <name> -> each red line of <name>.out whose key (watch_red_key) no red
# line of <name>.quarantine.covers (the evidence `watch-companion-loop quarantine` was taken on) has,
# so a reordered line or a new timestamp is still covered. Nothing for a quarantine with no covers, or
# covers that name no red (one taken before them, or on no evidence): it covers whatever is red.
watch_uncovered() {
  local keys l
  keys=$(watch_red_lines "$1/$2.quarantine.covers" | watch_red_key)
  [ -n "$keys" ] || return 0
  watch_red_lines "$1/$2.out" | while IFS= read -r l; do
    grep -qxF -- "$(watch_red_key <<<"$l")" <<<"$keys" || printf '%s\n' "$l"
  done
  return 0
}

# watch_quarantine_open <state dir> <name> [now] -> exit 0 while <name>.quarantine's first field
# (UNTIL, epoch, written by `watch-companion-loop quarantine`) is ahead of now, whatever it covers.
watch_quarantine_open() {
  local until="" now="${3:-$(date +%s)}"
  [ -r "$1/$2.quarantine" ] && read -r until _ < "$1/$2.quarantine"
  [[ "$until" =~ ^[0-9]+$ ]] && (( 10#$until > 10#$now ))
}

# watch_quarantined <state dir> <name> [now] -> exit 0 while a quarantine holds: it is open and every
# red line the watch names now is one it covers (ar-3916). A quarantined red counts as a warning, not
# red; past UNTIL, or once it names a red the quarantine was not taken on, it reads red again.
watch_quarantined() {
  watch_quarantine_open "$@" && [ -z "$(watch_uncovered "$1" "$2")" ]
}
