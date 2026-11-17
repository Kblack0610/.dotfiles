#!/usr/bin/env bats
# playtest-feedback: open playtester feedback per game playtest sheet. notes is the shared stub
# (helpers/stubs/notes): stats.json lists the projects, playtest.personal.<p> each sheet's open
# rows the way `notes ptask <p> --playtest list` prints them, and a sheet with no fixture fails.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PF="$REPO_ROOT/.local/bin/playtest-feedback"
  export PROM_TEXTFILE_DIR="$SANDBOX/textfile"
  mkdir -p "$PROM_TEXTFILE_DIR" "$SANDBOX/lab/dodge" "$SANDBOX/lab/pmp" "$SANDBOX/lab/broken"
  : > "$SANDBOX/lab/dodge/playtest.md"
  : > "$SANDBOX/lab/broken/playtest.md"
  jq -nc --arg l "$SANDBOX/lab" '[{name: "dodge", dir: "\($l)/dodge"}, {name: "pmp", dir: "\($l)/pmp"},
    {name: "broken", dir: "\($l)/broken"}, {name: "nodir", dir: null}]' > "$NOTES_FIXTURE/stats.json"
  DODGE="$NOTES_FIXTURE/playtest.personal.dodge"
  {
    printf '%s\t7\tGeneral\t%s\n' "$SANDBOX/lab/dodge/playtest.md" 'Street: ride the scooter (scooter, unity-core#1003)'
    printf '%s\t9\tGeneral\t%s\n' "$SANDBOX/lab/dodge/playtest.md" 'the ball clips through the gym wall (playtest Nov 21 playtest, sam)'
    printf '%s\t9\tGeneral\t%s\n' "$SANDBOX/lab/dodge/playtest.md" 'menus are slow, and the music, too loud (playtest Nov 21, jo)'
    printf '%s\t11\tGeneral\t%s\n' "$SANDBOX/lab/dodge/playtest.md" 'sound cuts out (playtest Nov 21, Sam (he/him))'
  } > "$DODGE"
}

@test "open feedback is the rows feedback-to-ptask filed, never the checks to play" {
  rm "$SANDBOX/lab/broken/playtest.md"
  run "$PF"
  assert_success
  assert_equal "$(jq -c '.projects' <<<"$output")" '[{"project":"dodge","feedback_open":3}]'
}

@test "publish: a project without a sheet writes nothing; an unreadable sheet holds the source down" {
  run "$PF" publish
  assert_success
  assert_equal "$(jq -c '.projects[] | select(.project == "broken")' <<<"$output")" \
    '{"project":"broken","error":"notes ptask --playtest list failed"}'
  p="$PROM_TEXTFILE_DIR/playtest_feedback.prom"
  run grep -F 'playtest_feedback_open{project="dodge"} 3' "$p"
  assert_success
  run grep -Fx 'playtest_feedback_up 0' "$p"
  assert_success
  # negative control: neither the sheetless project nor the unreadable one reads as zero
  run grep -E 'project="(pmp|broken)"' "$p"
  assert_failure
}

@test "an empty sheet is a read zero" {
  : > "$DODGE"
  rm "$SANDBOX/lab/broken/playtest.md"
  run "$PF" publish
  assert_success
  run grep -F 'playtest_feedback_open{project="dodge"} 0' "$PROM_TEXTFILE_DIR/playtest_feedback.prom"
  assert_success
  run grep -Fx 'playtest_feedback_up 1' "$PROM_TEXTFILE_DIR/playtest_feedback.prom"
  assert_success
}

@test "a failed project list publishes the source down, never a stale file" {
  : > "$NOTES_FIXTURE/stats.fail"
  run "$PF" publish
  assert_success
  assert_equal "$(jq -c '{projects, error}' <<<"$output")" '{"projects":[],"error":"notes projects --stats --json failed"}'
  run grep -Fx 'playtest_feedback_up 0' "$PROM_TEXTFILE_DIR/playtest_feedback.prom"
  assert_success
}

# Under agentctl a pass that declares no outcome is promoted to STALLED and trips fleet-liveness.
@test "under agentctl a published pass is WORKED, an unread sheet counted; a failed project list is FAILED" {
  AGENTCTL_NAME=playtest-feedback AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$PF" publish
  assert_success
  assert_equal "$(cat "$SANDBOX/astate/playtest-feedback/last-outcome")" WORKED
  run grep -F 'outcome=WORKED 2 projects, 1 unread' "$SANDBOX/astate/playtest-feedback/activity.log"
  assert_success
  : > "$NOTES_FIXTURE/stats.fail"
  AGENTCTL_NAME=playtest-feedback AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$PF" publish
  assert_equal "$(cat "$SANDBOX/astate/playtest-feedback/last-outcome")" FAILED
  run grep -F 'notes projects --stats --json failed' "$SANDBOX/astate/playtest-feedback/activity.log"
  assert_success
}

@test "no sheet read, or no textfile directory, is a FAILED pass; outside agentctl no outcome is written" {
  rm "$DODGE"
  AGENTCTL_NAME=playtest-feedback AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$PF" publish
  assert_equal "$(cat "$SANDBOX/astate/playtest-feedback/last-outcome")" FAILED
  run grep -F 'none of 2 playtest sheets could be read' "$SANDBOX/astate/playtest-feedback/activity.log"
  assert_success
  PROM_TEXTFILE_DIR="$SANDBOX/none" AGENTCTL_NAME=playtest-feedback AGENTCTL_STATE_DIR="$SANDBOX/cstate" run "$PF" publish
  assert_equal "$(cat "$SANDBOX/cstate/playtest-feedback/last-outcome")" FAILED
  AGENTCTL_STATE_DIR="$SANDBOX/bstate" run env -u AGENTCTL_NAME "$PF" publish
  assert_success
  [ ! -e "$SANDBOX/bstate" ]
}
