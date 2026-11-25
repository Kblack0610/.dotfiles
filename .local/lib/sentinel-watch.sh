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

# watch_is_stale <manifest> <lastrun-epoch> [now] -> exit 0 when stale. A missing or
# non-numeric lastrun is NOT stale: the watch was never polled, and its state says so.
watch_is_stale() {
  local lastrun="${2:-}" now="${3:-$(date +%s)}"
  [[ "$lastrun" =~ ^[0-9]+$ ]] || return 1
  (( now - lastrun > WATCH_STALE_FACTOR * $(watch_interval_secs "$1") ))
}

# log_norm: a line with what varies between runs taken out, so one error is one signature: a leading
# timestamp, quoted strings, paths, hex ids and numbers become placeholders. fleet-bench signs stderr
# lines with it, and watch_red_lines a watch's red lines.
log_norm() {
  sed -E 's/^\[[^]]*\][[:space:]]*//; s/"[^"]*"/"Q"/g; s/'"'"'[^'"'"']*'"'"'/'"'"'Q'"'"'/g
          s#(~|\.)?(/[^[:space:]/:"'"'"']+)+/?#P#g; s/\b[0-9a-f]{7,}\b/H/g; s/[0-9]+/N/g; s/[[:space:]]+/ /g; s/ $//'
}

# watch_red_lines <evidence file> -> the red lines a watch's redacted evidence (<name>.out) names,
# normalized (log_norm), in order: each `reason:` line (Sentinel's convention: vendor-check names its
# worst rows), else each `RED` line of a probe that prints one OK or RED line a stage
# (unity-core-playground's release-ready.py), else its last line, usually the error. The first is
# fleet-bench triage's why; the set is what a quarantine covers. Nothing when the file is missing.
watch_red_lines() {
  { sed -n 's/^reason: \(.\)/\1/p' "$1" | grep . || grep -E '^RED[[:space:]]' "$1" \
      || grep -v '^[[:space:]]*$' "$1" | tail -n 1; } 2>/dev/null | log_norm
}

# watch_uncovered <state dir> <name> -> each red line of <name>.out that <name>.quarantine.covers (the
# evidence `watch-companion-loop quarantine` was taken on) does not name, so a reordered line or a new
# timestamp is still covered. Nothing for a quarantine with no covers file (one taken before them):
# it covers whatever is red, as it always did.
watch_uncovered() {
  [ -e "$1/$2.quarantine.covers" ] || return 0
  grep -vxF -f <(watch_red_lines "$1/$2.quarantine.covers") <(watch_red_lines "$1/$2.out") || true
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
