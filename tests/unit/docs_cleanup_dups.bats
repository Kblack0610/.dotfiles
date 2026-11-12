#!/usr/bin/env bats
# agentctl-docs-cleanup counts restated instructions (skill-drift --dups --check) beside the skill and
# doc drift: a count over dup_pairs_max is drift and queues the pass, a count at or under it is not,
# and a lost baseline reads FAILED instead of "no drift". skill-drift is a stub that serves canned JSON.

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
  printf '#!/usr/bin/env bash\necho "{}"\n' > "$BIN/agent-queue"
  cat > "$BIN/skill-drift" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --json) echo '{"findings":[]}' ;;
  --docs) echo '{"drift":0}' ;;
  --dups) [ -n "$DUPS_JSON" ] || exit 2; echo "$DUPS_JSON"; [ "$(jq .over <<<"$DUPS_JSON")" = 0 ] || exit 1 ;;
esac
STUB
  chmod +x "$BIN"/*
  export AGENTCTL_INBOX="$BATS_TEST_TMPDIR/inbox" DOCS_CLEANUP_LESSONS="$HOME/.agent/lessons"
}

@test "a pair count over the baseline is drift: the pass would be queued with the count in its task" {
  DUPS_JSON='{"pairs":63,"max":60,"over":3}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_success
  assert_output --partial 'would queue'
  assert_output --partial 'restated pairs 63 (baseline 60)'
}

@test "negative control: a count at the baseline is no drift" {
  DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_success
  assert_output --partial 'no drift (skills 0, global docs 0, restated pairs 60 (baseline 60)'
  run jq .pairs "$AGENTCTL_INBOX"/*/dups.json
  assert_output 60
}

@test "a lost baseline row is a failure, not a quiet night" {
  DUPS_JSON= run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_failure 1
  assert_output --partial 'skill-drift --dups --check --json gave no JSON'
}
