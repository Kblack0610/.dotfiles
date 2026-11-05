#!/usr/bin/env bats
# fleet-stages (`fleet-sessions stages`): time per delivery stage, replayed from a canned
# shepherd watch.log. Three sessions on 2026-10-28 (local): an agent session that goes
# red, reruns, waits on an ask, unticks a phase, merges and lands, flickers out and back
# for one tick, then winds down; a hand session waiting at the prompt that is still open
# at the window's end; an agent session that hits a conflict and ends with no PR.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export TZ=America/Los_Angeles
  SUBJECT="$REPO_ROOT/.local/lib/fleet-stages.py"
  LOG="$SANDBOX/watch.log"
  FROM=$(date -d 2026-10-28 +%s) TO=$(date -d 2026-10-29 +%s)
  cat > "$LOG" <<'EOF'
2026-10-27 23:00  game-agent-1:1  new: WORKING (busy)
2026-10-28 00:30  game-agent-1:1  plan - -> 0/2, pr - -> #5 open, ci - -> pending
2026-10-28 00:32  game-agent-1:1  ci pending -> fail, stage WORKING -> STALLED (CI red on #5, 2 failing)
2026-10-28 00:40  game-agent-1:1  ci fail -> pending, stage STALLED -> WORKING, labels - -> manual (busy)
2026-10-28 00:45  game-agent-1:1  ci pending -> pass, plan 0/2 -> 1/2
2026-10-28 01:00  game-agent-1:1  stage WORKING -> NEEDS (1 pending ask)
2026-10-28 02:00  game-agent-1:1  stage NEEDS -> WORKING (busy)
2026-10-28 02:10  game-agent-1:1  plan 1/2 -> 0/2
2026-10-28 02:20  game-agent-1:1  plan 0/2 -> 2/2, pr #5 open -> #5 merged, stage WORKING -> LANDED (merged)
2026-10-28 02:30  game-agent-1:1  gone
2026-10-28 02:31  game-agent-1:1  new: LANDED (merged)
2026-10-28 02:40  game-agent-1:1  gone
2026-10-28 03:00  game-agent-2:1  new: WORKING (busy)
2026-10-28 03:10  game-agent-2:1  conflicts no -> CONFLICT, stage WORKING -> STALLED (conflicts with origin/main)
2026-10-28 03:25  game-agent-2:1  conflicts CONFLICT -> no, stage STALLED -> WORKING (busy)
2026-10-28 04:00  game-agent-2:1  gone
2026-10-28 10:00  dotfiles:2  new: NEEDS (waiting on a prompt or permission)
2026-10-28 10:30  dotfiles:2  stage NEEDS -> WORKING (busy)
2026-10-29 01:00  dotfiles:2  gone
EOF
}

stages() { run python3 "$SUBJECT" --log "$LOG" --from "$FROM" --to "$TO" --json; assert_success; }
v() { jq -c "$1" <<<"$output"; }

@test "sessions: a gone and a new one tick apart are one session; ended, no PR and the stage it ended from" {
  stages
  assert_equal "$(v '[.sessions, .started, .ended, .ended_no_pr, .ended_from]')" '[3,2,2,1,{"landed":1,"working":1}]'
}

@test "negative control: a gap longer than a tick is two sessions" {
  sed -i 's/^2026-10-28 02:31 /2026-10-28 02:35 /' "$LOG"
  stages
  assert_equal "$(v '[.started, .ended, .ended_from]')" '[3,3,{"landed":2,"working":1}]'
}

@test "stages: minutes are clipped to the window, waits split by reason, and a stage still open at the end is open" {
  stages
  # WORKING: game-agent-1 72 (its hour before midnight is outside), game-agent-2 45, dotfiles:2 810 (10:30..24:00)
  assert_equal "$(v '.stages.WORKING | [.minutes, .open]')" '[927,1]'
  assert_equal "$(v '[.stages.NEEDS.minutes, .stages["NEEDS:ask"].minutes, .stages["NEEDS:prompt"].minutes]')" '[90,60,30]'
  assert_equal "$(v '[.stages["STALLED:ci_red"].minutes, .stages["STALLED:conflict"].minutes, .stages.STALLED.n]')" '[8,15,2]'
}

@test "ci, prs, conflicts and plans: a rerun after red, open to merged, a resolved conflict, an untick" {
  stages
  assert_equal "$(v '[.ci.started, .ci.rerun_after_red, .ci.fail.n, .ci.pass.n]')" '[1,1,1,1]'
  assert_equal "$(v '[.prs.opened, .prs.merged, .prs.open_to_merged.p50]')" '[1,1,110.0]'
  assert_equal "$(v '[.conflicts.entered, .conflicts.resolved.p50]')" '[1,15.0]'
  assert_equal "$(v '[.plans.plans_started, .plans.phases_ticked, .plans.phases_unticked]')" '[1,3,1]'
}

@test "wind-down is finished to gone across a flicker, and projects split agent worktrees from the main session" {
  stages
  assert_equal "$(v '[.wind_down.n, .wind_down.p50]')" '[1,20.0]'
  assert_equal "$(v '.by_project.game | [.ended, .ended_no_pr, .prs_merged, .ci_fail, .ci_pass]')" '[2,1,1,1,1]'
  assert_equal "$(v '.by_project["dotfiles (main)"] | [.needs_min, .working_min]')" '[30,810]'
}

@test "a window before anything happened is empty, not an error" {
  run python3 "$SUBJECT" --log "$LOG" --from "$((FROM - 86400))" --to "$((FROM - 7200))" --json
  assert_success
  assert_equal "$(v '[.sessions, .ended, .stages]')" '[0,0,{}]'
}

@test "the text table and the fleet-sessions verb read the same log" {
  run python3 "$SUBJECT" --log "$LOG" --from "$FROM" --to "$TO"
  assert_success
  assert_output --partial 'NEEDS:ask'
  assert_output --partial '3 sessions, 2 started, 2 ended (1 with no PR seen)'
  mkdir -p "$HOME/.agent/shepherd" && cp "$LOG" "$HOME/.agent/shepherd/watch.log"
  run "$REPO_ROOT/.local/bin/fleet-sessions" stages --from "$FROM" --to "$TO" --json
  assert_success
  assert_equal "$(v '.ended')" '2'
}

@test "every NEEDS and STALLED reason fleet-sessions writes falls in a named class, never other" {
  grep -oP 'echo "\K(NEEDS|STALLED) [^"]*' "$REPO_ROOT/.local/bin/fleet-sessions" | sort -u > "$SANDBOX/reasons"
  [ "$(wc -l < "$SANDBOX/reasons")" -ge 10 ]
  run python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fs", sys.argv[1]); fs = importlib.util.module_from_spec(spec); spec.loader.exec_module(fs)
for line in open(sys.argv[2]):
    stage, reason = line.rstrip("\n").split(" ", 1)
    print(fs.stage_key(stage, reason), "|", reason)' "$SUBJECT" "$SANDBOX/reasons"
  assert_success
  refute_output --partial ':other'
  # negative control: a reason nobody writes is other
  run python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fs", sys.argv[1]); fs = importlib.util.module_from_spec(spec); spec.loader.exec_module(fs)
print(fs.stage_key("STALLED", "something new"))' "$SUBJECT"
  assert_output 'STALLED:other'
}
