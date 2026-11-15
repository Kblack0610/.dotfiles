#!/usr/bin/env bats
# playtest-feedback: open playtester feedback per game playtest sheet. notes is a stub that lists
# the projects and each sheet's open rows the way `notes ptask <p> --playtest list` does.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PF="$REPO_ROOT/.local/bin/playtest-feedback"
  export SANDBOX PROM_TEXTFILE_DIR="$SANDBOX/textfile" NOTES_BIN="$SANDBOX/bin/notes-stub"
  mkdir -p "$PROM_TEXTFILE_DIR" "$SANDBOX/lab/dodge" "$SANDBOX/lab/pmp" "$SANDBOX/lab/broken"
  : > "$SANDBOX/lab/dodge/playtest.md"
  : > "$SANDBOX/lab/broken/playtest.md"
  jq -nc --arg l "$SANDBOX/lab" '[{name: "dodge", dir: "\($l)/dodge"}, {name: "pmp", dir: "\($l)/pmp"},
    {name: "broken", dir: "\($l)/broken"}, {name: "nodir", dir: null}]' > "$SANDBOX/projects.json"
  {
    printf '%s\t7\tGeneral\t%s\n' "$SANDBOX/lab/dodge/playtest.md" 'Street: ride the scooter (scooter, unity-core#1003)'
    printf '%s\t9\tGeneral\t%s\n' "$SANDBOX/lab/dodge/playtest.md" 'the ball clips through the gym wall (playtest Nov 21 playtest, sam)'
    printf '%s\t9\tGeneral\t%s\n' "$SANDBOX/lab/dodge/playtest.md" 'menus are slow, and the music, too loud (playtest Nov 21, jo)'
    printf '%s\t11\tGeneral\t%s\n' "$SANDBOX/lab/dodge/playtest.md" 'sound cuts out (playtest Nov 21, Sam (he/him))'
  } > "$SANDBOX/dodge.tsv"
  cat > "$NOTES_BIN" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "projects --stats") [ "${PROJECTS_FAIL:-0}" = 0 ] || exit 1; cat "$SANDBOX/projects.json" ;;
  "ptask dodge") cat "$SANDBOX/dodge.tsv" ;;
  "ptask broken") exit 1 ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$NOTES_BIN"
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
  : > "$SANDBOX/dodge.tsv"
  rm "$SANDBOX/lab/broken/playtest.md"
  run "$PF" publish
  assert_success
  run grep -F 'playtest_feedback_open{project="dodge"} 0' "$PROM_TEXTFILE_DIR/playtest_feedback.prom"
  assert_success
  run grep -Fx 'playtest_feedback_up 1' "$PROM_TEXTFILE_DIR/playtest_feedback.prom"
  assert_success
}

@test "a failed project list publishes the source down, never a stale file" {
  PROJECTS_FAIL=1 run "$PF" publish
  assert_success
  assert_equal "$(jq -c '{projects, error}' <<<"$output")" '{"projects":[],"error":"notes projects --stats --json failed"}'
  run grep -Fx 'playtest_feedback_up 0' "$PROM_TEXTFILE_DIR/playtest_feedback.prom"
  assert_success
}
