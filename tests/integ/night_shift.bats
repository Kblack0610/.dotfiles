#!/usr/bin/env bats
# night-shift - the overnight queue's verb contract, driven with a stub runner in place of
# agentctl-run, so no model is called. The stub emits the same stream-json a real run does.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  NS="$REPO_ROOT/.local/bin/night-shift"
  PANEL="$REPO_ROOT/.local/src/tmux/night-shift.sh"
  export NIGHT_SHIFT_DIR="$HOME/.agent/night" NIGHT_SHIFT_LOGS="$HOME/logs"
  export NIGHT_SHIFT_RUNNER="$SANDBOX/bin/stub-run" AGENTCTL_NAME=ns-test
  export AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  REPO="$SANDBOX/repo"
  git init -q "$REPO"
  cat > "$NIGHT_SHIFT_RUNNER" <<'EOF'
#!/usr/bin/env bash
p=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && p="$2"; shift; done
printf '%s' "$p" > "$HOME/last-prompt"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"sess-1","model":"m"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}'
if [ "${STUB_STATUS:-ok}" = noblock ]; then r="forgot the block"
else r="$(printf 'done\nNIGHT-SHIFT-RESULT\nstatus: %s\npr: https://example/pr/7\nasks: none\nsummary: did it\nEND' "${STUB_STATUS:-ok}")"; fi
jq -cn --arg r "$r" '{type:"result",subtype:"success",num_turns:3,total_cost_usd:0.1,result:$r}'
exit "${STUB_RC:-0}"
EOF
  chmod +x "$NIGHT_SHIFT_RUNNER"
}

# Header only: the body is the run's final text, which repeats the result block.
result_of() { awk -v k="$2: " '$0 == "---" { exit } index($0, k) == 1 { print substr($0, length(k) + 1) }' "$NIGHT_SHIFT_DIR"/done/*/"$1".result.md; }

@test "an empty queue is a NOOP and calls no runner" {
  run "$NS" run
  assert_success
  assert_output --partial 'queue empty'
  [ ! -e "$HOME/last-prompt" ]
  run cat "$AGENTCTL_STATE_DIR/ns-test/last-outcome"
  assert_output NOOP
}

@test "queue refuses a duplicate slug and an unknown --after" {
  run "$NS" queue "$REPO" "first task" --slug first
  assert_success
  run "$NS" queue "$REPO" "again" --slug first
  assert_failure
  assert_output --partial 'already queued'
  run "$NS" queue "$REPO" "x" --after nope
  assert_failure
  assert_output --partial 'no queued or finished task'
}

@test "a task runs as /one-shot --pr-only and its result block is parsed" {
  "$NS" queue "$REPO" "Bump the editor" --slug bump --project agent-runtime
  run "$NS" run
  assert_success
  run head -1 "$HOME/last-prompt"
  assert_output '/one-shot --pr-only Bump the editor'
  run grep -c 'agent-ask post --project agent-runtime' "$HOME/last-prompt"
  assert_output 1
  [ "$(result_of bump status)" = ok ]
  [ "$(result_of bump pr)" = https://example/pr/7 ]
  [ "$(result_of bump session)" = sess-1 ]
  run cat "$NIGHT_SHIFT_LOGS/bump.log"
  assert_output --partial '> Bash git status'
}

@test "a run with no result block is failed, never ok" {
  "$NS" queue "$REPO" "t" --slug t
  STUB_STATUS=noblock STUB_RC=3 run "$NS" run
  [ "$(result_of t status)" = failed ]
  run result_of t summary
  assert_output --partial 'no NIGHT-SHIFT-RESULT block (exit 3)'
}

@test "--after runs only when the predecessor ended ok" {
  "$NS" queue "$REPO" "a" --slug a
  "$NS" queue "$REPO" "b" --slug b --after a
  STUB_STATUS=blocked run "$NS" run
  [ "$(result_of a status)" = blocked ]
  [ "$(result_of b status)" = skipped ]
}

@test "the night's verdict: needs the human is BLOCKED, all erroring is FAILED, all ok WORKED" {
  "$NS" queue "$REPO" "a" --slug a
  STUB_STATUS=blocked run "$NS" run
  run cat "$AGENTCTL_STATE_DIR/ns-test/last-outcome"
  assert_output BLOCKED
  "$NS" queue "$REPO" "b" --slug b
  STUB_STATUS=noblock STUB_RC=3 run "$NS" run
  run cat "$AGENTCTL_STATE_DIR/ns-test/last-outcome"
  assert_output FAILED
  "$NS" queue "$REPO" "c" --slug c
  run "$NS" run
  run cat "$AGENTCTL_STATE_DIR/ns-test/last-outcome"
  assert_output WORKED
}

@test "a task orphaned in running/ is reported failed on the next run" {
  "$NS" queue "$REPO" "o" --slug o
  mkdir -p "$NIGHT_SHIFT_DIR/running"
  mv "$NIGHT_SHIFT_DIR"/queue/*-o.md "$NIGHT_SHIFT_DIR/running/"
  run "$NS" run
  [ "$(result_of o status)" = failed ]
  run cat "$AGENTCTL_STATE_DIR/ns-test/last-outcome"
  refute_output NOOP
}

@test "list keeps its columns when a field is empty" {
  "$NS" queue "$REPO" "a" --slug a
  STUB_STATUS=blocked "$NS" run
  "$NS" queue "$REPO" "c" --slug c
  run "$NS" list
  assert_line --index 0 --regexp $'^queued\tc\trepo\t[0-9T:-]+\t-\t-$'
  run "$NS" report
  assert_output --partial '- **blocked** a (repo): did it - https://example/pr/7'
}

@test "the panel board renders the CLI rows and rejects an unknown verb" {
  "$NS" queue "$REPO" "a" --slug a
  NIGHT_SHIFT_CLI="$NS" PANEL_NO_COLOR=1 run bash "$PANEL" board
  assert_success
  assert_output --partial 'queued   a'
  run bash "$PANEL" nope
  assert_failure
}

