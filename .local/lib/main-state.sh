# shellcheck shell=bash disable=SC2034  # MAIN_STREAKS is for the scripts that source this
# main-state.sh - how a branch's CI runs read as red or green, for fleet-sessions (main_health)
# and fleet-bench (the cleanup hold check), so the two cannot disagree about when a red started.

# MAIN_STREAKS: a jq program, gh run fields (any order) in, one object out per workflow whose latest
# decided run is red: {workflow, red, green}. red is the first run of the red streak, green the
# last green before it, null when none is in view; then red is the oldest red in view, which
# slides as runs age out. A cancelled or skipped run decides nothing, so it neither hides a red
# nor reads as green.
MAIN_STREAKS='map(select(.status == "completed"
                    and (.conclusion | test("^(success|failure|timed_out|startup_failure)$"))))
    | group_by(.workflowName)[] | sort_by(.createdAt) | reverse
    | select(.[0].conclusion != "success")
    | (map(.conclusion == "success") | index(true)) as $g
    | {workflow: .[0].workflowName, red: (if $g == null then .[-1] else .[$g - 1] end),
       green: (if $g == null then null else .[$g] end)}'

: "${FLEET_MAIN_TTL:=300}" # seconds a repo's main run list is reused across passes: every caller (the
                           # ask watcher, fleet-bench, the shepherd, the board) runs a pass, and on
                           # 2026-10-29 the fleet spent GitHub's 5,000/hr REST limit; a nightly's red
                           # is no less true five minutes later
: "${MAIN_CACHE:=${XDG_CACHE_HOME:-$HOME/.cache}/fleet}"

# main_runs <cache key> <owner/repo> <branch> -> the branch's runs in gh run list field names, reused
# for FLEET_MAIN_TTL seconds across passes. A failed call is not cached, so the next pass asks again.
# actions/runs, not `gh run list`: that looks workflows up under actions/workflows, a separate
# bucket that `gh api rate_limit` does not show, and on 2026-10-29 it was the one used up.
main_runs() {
  local b="$3" file runs
  file="$MAIN_CACHE/runs_$1_${b//\//%2F}.json" # %2F: feat/x and feat_x are two branches
  if [ -s "$file" ] && [ $(( $(date +%s) - $(date -r "$file" +%s) )) -lt "$FLEET_MAIN_TTL" ]; then
    cat "$file"; return
  fi
  runs="$(gh api -X GET "repos/$2/actions/runs" -f branch="$b" -f per_page=100 \
            --jq '[.workflow_runs[] | {id, event, workflowName: .name, status, conclusion, headSha: .head_sha, createdAt: .created_at}]' \
            2>/dev/null)" || return 1
  mkdir -p "$MAIN_CACHE"
  printf '%s\n' "$runs" > "$file.$$" && mv "$file.$$" "$file"
  printf '%s\n' "$runs"
}
