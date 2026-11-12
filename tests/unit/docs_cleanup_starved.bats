#!/usr/bin/env bats
# agentctl-docs-cleanup queues its pass where the queue lets it start (high, tagged cleanup), and a
# pass that sat queued past DOCS_CLEANUP_STARVED_DAYS is a failure, not another quiet NOOP night.
# agent-queue and skill-drift are stubs; the stub queue records what it was asked to add.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  export HOME="$BATS_TEST_TMPDIR/home"
  BIN="$HOME/.local/bin"
  mkdir -p "$BIN" "$HOME/.local/lib" "$HOME/.agent/lessons"
  cp "$BATS_TEST_DIRNAME/../../.local/bin/agentctl-docs-cleanup" "$BIN/"
  printf 'proof_outcome() { :; }\n' > "$HOME/.local/lib/agent-proof.sh"
  printf '#!/usr/bin/env bash\necho docs-cleanup\n' > "$BIN/agentctl"
  cat > "$BIN/agent-queue" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  show) echo "${ITEM_JSON:-{\}}" ;;
  add) printf '%s\n' "$@" > "$ADD_LOG" ;;
esac
STUB
  cat > "$BIN/skill-drift" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --json) echo '{"findings":[]}' ;;
  --docs) echo '{"drift":3}' ;;
  --dups) echo '{"pairs":60,"max":60,"over":0}' ;;
esac
STUB
  chmod +x "$BIN"/*
  export AGENTCTL_INBOX="$BATS_TEST_TMPDIR/inbox" DOCS_CLEANUP_LESSONS="$HOME/.agent/lessons" ADD_LOG="$BATS_TEST_TMPDIR/add.log"
}

@test "a pass queued 3 days ago and never started is a failure" {
  ITEM_JSON="{\"state\":\"queued\",\"queued\":\"$(date -u -d '3 days ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'starved: queued since'
}

@test "negative control: a pass queued an hour ago is still open, not starved" {
  ITEM_JSON="{\"state\":\"queued\",\"queued\":\"$(date -u -d '1 hour ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'still queued, not queuing another'
}

@test "a running pass is never starved, however old its queued time" {
  ITEM_JSON="{\"state\":\"running\",\"queued\":\"$(date -u -d '9 days ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'still running'
}

@test "the pass is queued at high, tagged night and cleanup" {
  run "$BIN/agentctl-docs-cleanup"
  assert_success
  run cat "$ADD_LOG"
  assert_line --index 0 add
  assert_output --partial $'--priority\nhigh'
  assert_output --partial $'--tags\nnight cleanup'
}
