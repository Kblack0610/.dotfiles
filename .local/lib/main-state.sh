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
