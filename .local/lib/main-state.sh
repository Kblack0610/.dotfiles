# shellcheck shell=bash disable=SC2034  # MAIN_STREAKS is for the scripts that source this
# main-state.sh - how a branch's CI runs read as red or green, for fleet-sessions (main_health)
# and fleet-bench (the cleanup hold check), so the two cannot disagree about when a red started.

# MAIN_STREAKS: a jq program, gh run fields (any order) in, one object out per workflow whose latest
# decided run is red: {workflow, red, green}. red is the first run of the red streak, green the
# last green before it, null when none is in view; then red is the oldest red in view, which
# slides as runs age out. A cancelled or skipped run decides nothing, so it neither hides a red
# nor reads as green. A workflow is its file (workflowPath): workflowName follows the file's
# run-name, so a retitled workflow would leave its old title red for as long as that run is in
# view. workflow is the title of the first red, so the fact holds still while the streak runs on.
MAIN_STREAKS='map(select(.status == "completed"
                    and (.conclusion | test("^(success|failure|timed_out|startup_failure)$"))))
    | group_by(.workflowPath)[] | sort_by(.createdAt) | reverse
    | select(.[0].conclusion != "success")
    | (map(.conclusion == "success") | index(true)) as $g
    | (if $g == null then .[-1] else .[$g - 1] end) as $red
    | {workflow: $red.workflowName, red: $red, green: (if $g == null then null else .[$g] end)}'

: "${MAIN_CACHE:=${XDG_CACHE_HOME:-$HOME/.cache}/fleet}"
# The run ledger's one reader (schedules-sync runs); the sibling in this tree, so a worktree's
# scripts read through its own copy.
: "${SCHEDULES_SYNC:=$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../bin/schedules-sync}"

# main_runs <owner/repo> [branch] -> the branch's runs (every branch's without one) in gh run list field names, from the run
# ledger (~/.local/state/ci/runs.jsonl), never actions/runs: schedules-sync is its one writer and
# keeps it within 10 minutes. rc 1 when the ledger cannot answer for the repo (not synced in 30
# minutes, or unreadable), so the caller reads unknown, never green; rc 3, and nothing, for a repo
# the ledger does not sync (day-log-ci is the one list of watched repos), which the caller decides.
main_runs() {
  local runs rc=0
  runs="$("$SCHEDULES_SYNC" runs "$1" ${2:+--branch "$2"} 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 3 ] && return 3; return 1; }
  jq -ce 'map({id, event, workflowName: .workflow, workflowPath: .path, headBranch: .branch, status, conclusion, headSha: .sha, createdAt: .created_at})' <<<"$runs"
}
