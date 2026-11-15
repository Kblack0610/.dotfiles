#!/usr/bin/env bats
# agentctl-docs-cleanup queues its pass where the queue lets it start (high, tagged cleanup), and a
# pass that sat queued past DOCS_CLEANUP_STARVED_DAYS is a failure, not another quiet NOOP night.
# A pass held by admission past that long is starved the same way. agent-queue and skill-drift are stubs; the stub queue records what it was asked to add.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  export HOME="$BATS_TEST_TMPDIR/home"
  BIN="$HOME/.local/bin"
  export PATH="$BIN:$PATH" # the runner unit declares ~/.local/bin on PATH; the script no longer does
  mkdir -p "$BIN" "$HOME/.local/lib" "$HOME/.agent/lessons"
  cp "$BATS_TEST_DIRNAME/../../.local/bin/agentctl-docs-cleanup" "$BIN/"
  printf 'proof_outcome() { :; }\n' > "$HOME/.local/lib/agent-proof.sh"
  printf '#!/usr/bin/env bash\necho docs-cleanup\n' > "$BIN/agentctl"
  cat > "$BIN/agent-queue" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  show) echo "${ITEM_JSON:-{\}}" ;;
  add) printf '%s\n' "$@" > "$ADD_LOG"; exit "${ADD_RC:-0}" ;;
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
  assert_line --index 8 --  '--priority'
  assert_line --index 9 high
  assert_line --index 10 -- '--tags'
  assert_line --index 11 'night cleanup'
}

@test "a queued pass with no readable queued time is a failure, not a fresh pass" {
  ITEM_JSON='{"state":"queued","queued":""}' run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'no readable queued time'
}

@test "a pass held by another hold (after, focus) is the queue's choice, not starved" {
  ITEM_JSON="{\"state\":\"queued\",\"hold\":\"after other-slug\",\"queued\":\"$(date -u -d '5 days ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'still queued'
}

@test "a pass held only by the night window still starves" {
  ITEM_JSON="{\"state\":\"queued\",\"hold\":\"night (01:00-06:00)\",\"queued\":\"$(date -u -d '3 days ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'starved: queued since'
}

@test "admission holding the add: the first night is a NOOP, past the limit a failure, a queued pass clears it" {
  ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'held the pass (admission)'
  date -d '3 days ago' +%s > "$AGENTCTL_INBOX/held-since"
  ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'held by queue admission since'
  run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert [ ! -e "$AGENTCTL_INBOX/held-since" ]
}
