#!/usr/bin/env bats
# timebox-panel maps each panel key to one `timebox` command and holds no queue of its own. A stub
# timebox records its argv, so these pin the key -> command contract without a real state dir.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PANEL="$BATS_TEST_DIRNAME/../../.local/bin/timebox-panel"
  export FX="$BATS_TEST_TMPDIR"
  export TIMEBOX="$FX/timebox"
  cat > "$TIMEBOX" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/calls"
case "$*" in
  queue) cat "$FX/queue" 2>/dev/null || echo "queue empty" ;;
  pause) exit "${PAUSE_RC:-0}" ;;
esac
exit 0
STUB
  chmod +x "$TIMEBOX"
}

calls() { cat "$FX/calls" 2>/dev/null; }

@test "each key runs its timebox command with the row's position" {
  for a in "done" "rm 2" "down 2" "up 2" "go" "clear"; do
    # shellcheck disable=SC2086
    run "$PANEL" act $a
    assert_success
  done
  assert_equal "$(calls)" "done
queue rm 2
queue mv 2 3
queue mv 2 1
queue go
queue clear"
}

@test "the placeholder row and the top row never move or remove anything" {
  run "$PANEL" act rm -
  assert_success
  run "$PANEL" act up 1
  assert_success
  run "$PANEL" act down
  assert_success
  assert_equal "$(calls)" ""
}

@test "pause resumes a head that is already paused" {
  PAUSE_RC=1 run "$PANEL" act pause
  assert_success
  assert_equal "$(calls)" "pause
resume"
}

@test "add appends the typed task as one argument; an empty line adds nothing" {
  run "$PANEL" act add <<< "work at desk 10m"
  assert_success
  assert_equal "$(calls)" "queue add work at desk 10m"
  rm "$FX/calls"
  run "$PANEL" act add <<< ""
  assert_equal "$(calls)" ""
}

@test "rows is the queue with its header line, or a hint when empty" {
  run "$PANEL" rows
  assert_line --index 0 "queue empty"
  assert_line --index 1 --partial "a adds a task"
  printf 'queue on\n1  guitar  5m\n' > "$FX/queue"
  run "$PANEL" rows
  assert_output "queue on
1  guitar  5m"
}

@test "an unknown verb fails" {
  run "$PANEL" act teleport
  assert_failure 2
}
