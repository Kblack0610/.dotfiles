#!/usr/bin/env bats
# codex-item-stop.sh, the Codex Stop hook: a fleet Codex run whose item is still running with no PR
# gets one block naming how to close it; every other Stop goes through. agent-queue is a stub.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUBJECT="$PUB/.claude/hooks/codex-item-stop.sh"
  export AGENT_QUEUE_BIN="$BATS_TEST_TMPDIR/agent-queue" AGENT_QUEUE_ITEM=cx
  item '{"slug": "cx", "state": "running", "sessions": "th-0 th-1"}'
}

# item <json> -- what `agent-queue show cx --json` prints.
item() {
  printf '#!/bin/sh\n[ "$1 $2 $3" = "show cx --json" ] || exit 1\ncat <<'"'"'J'"'"'\n%s\nJ\n' "$1" > "$AGENT_QUEUE_BIN"
  chmod +x "$AGENT_QUEUE_BIN"
}

stop() { run bash "$SUBJECT" <<<"{\"hook_event_name\": \"Stop\", \"session_id\": \"${1:-th-1}\", \"stop_hook_active\": ${2:-false}}"; }

@test "the item's own thread stopping with the item running and no PR is blocked once, with each way to close it" {
  stop
  assert_success
  assert_equal "$(jq -r .decision <<<"$output")" block
  run jq -r .reason <<<"$output"
  assert_output --partial 'agent-land <N> --item cx'
  assert_output --partial 'agent-queue requeue cx --ask <id>'
  assert_output --partial 'agent-queue move cx done --status failed'
  stop th-1 true
  assert_success; assert_output ''
}

@test "every other Stop goes through: a closed, parked or PR'd item, another thread, no item, an unreadable queue" {
  for j in '{"state": "done", "sessions": "th-1"}' '{"state": "waiting", "sessions": "th-1"}' \
           '{"state": "running", "pr": "o/r#4", "sessions": "th-1"}'; do
    item "$j"; stop; assert_success; assert_output ''
  done
  # a Claude session's item reaches any codex it runs, through the env: not this thread's to close
  item '{"state": "running", "sessions": "claude-sid"}'; stop; assert_output ''
  printf '#!/bin/sh\nexit 1\n' > "$AGENT_QUEUE_BIN"; stop; assert_success; assert_output ''
  item '{"state": "running", "sessions": "th-1"}'
  AGENT_QUEUE_ITEM= run bash "$SUBJECT" <<<"{\"session_id\": \"th-1\", \"stop_hook_active\": false}"; assert_output ''
}
