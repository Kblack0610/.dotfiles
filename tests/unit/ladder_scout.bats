#!/usr/bin/env bats
# ladder-scout: a model a source key may call that the ladder does not carry becomes one board row.
# claude-acct, model-lane and notes are stubs; the sources, harnesses.json and canary-lanes are fixtures.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SCOUT="$REPO_ROOT/.local/bin/ladder-scout"
  export LADDER_SCOUT_SOURCES="$BATS_TEST_TMPDIR/sources"
  export LADDER_SCOUT_HARNESSES="$BATS_TEST_TMPDIR/harnesses.json"
  export LADDER_SCOUT_CANARY_LANES="$BATS_TEST_TMPDIR/canary-lanes"
  export LADDER_SCOUT_STATE="$BATS_TEST_TMPDIR/state"
  export LADDER_SCOUT_NOW=2000000000
  export LADDER_SCOUT_ACCT="$SANDBOX/bin/fake-acct" LADDER_SCOUT_MODEL_LANE="$SANDBOX/bin/fake-ml" LADDER_SCOUT_NOTES="$SANDBOX/bin/fake-notes"
  cat > "$LADDER_SCOUT_SOURCES" <<'E'
# name kind ref
nim   litellm-key  /x/nim.key  rpm=40 priority=low
reserve litellm-key /x/reserve.key max_live=2 alert=off
agy   agy          gemini
codex codex        /x/codex
E
  cat > "$LADDER_SCOUT_HARNESSES" <<'E'
{"harnesses": {"nim": {"source": "nim", "models": {"minimax": "litellm/free-minimax (minimax-m3.1-flash)", "qwen": "litellm/free-qwen (qwen3.8-27b)"}}}}
E
  printf '# lanes\nnim minimax\nnim qwen\n' > "$LADDER_SCOUT_CANARY_LANES"
  printf '%s\n' '{"pair":"nim:minimax","retired":false,"admitted":true,"why":"x"}' '{"pair":"nim:qwen","retired":false,"admitted":false,"why":"0 of 1 canary passes"}' > "$BATS_TEST_TMPDIR/listed"
  printf '%s\n' 'free-minimax (minimax-m3.1-flash)' 'free-qwen (qwen3.8-27b)' > "$BATS_TEST_TMPDIR/catalog.nim"
  cat > "$LADDER_SCOUT_ACCT" <<'E'
#!/usr/bin/env bash
[[ "$1" == models ]] && cat "$BATS_TEST_TMPDIR/catalog.$2" 2>/dev/null || { echo "no catalog" >&2; exit 1; }
E
  printf '#!/usr/bin/env bash\ncat "$BATS_TEST_TMPDIR/listed"\n' > "$LADDER_SCOUT_MODEL_LANE"
  cat > "$LADDER_SCOUT_NOTES" <<'E'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/notes.log"
exit "${FAKE_NOTES_RC:-4}"
E
  chmod +x "$LADDER_SCOUT_ACCT" "$LADDER_SCOUT_MODEL_LANE" "$LADDER_SCOUT_NOTES"
  : > "$BATS_TEST_TMPDIR/notes.log"
}

@test "a model the gateway lists and the ladder carries changes nothing" {
  run "$SCOUT"
  assert_success
  assert_output --partial "nim (nim): 2 models"
  refute_output --partial "missing"
  [ ! -s "$BATS_TEST_TMPDIR/notes.log" ]
}

@test "a listed pair still waiting on its canary is reported and files no row" {
  run "$SCOUT"
  assert_success
  assert_output --partial "waits on its canary (0 of 1 canary passes)"
  [ ! -s "$BATS_TEST_TMPDIR/notes.log" ]
}

@test "an unknown model id files one row naming all three places, keyed by its gateway id" {
  echo 'free-gpt-oss (gpt-oss-120b)' >> "$BATS_TEST_TMPDIR/catalog.nim"
  run "$SCOUT"
  assert_success
  assert_output --partial "free-gpt-oss (gpt-oss-120b): missing a models entry in harnesses.json, a line in canary-lanes, a lanes.yaml trainee candidate"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/notes.log")" = 1 ]
  run cat "$BATS_TEST_TMPDIR/notes.log"
  assert_output --partial "ptask agent-runtime --agent add"
  assert_output --partial "onboard nim gpt-oss-120b as a trainee candidate"
  assert_output --partial "Key: ladder-scout:nim:free-gpt-oss (gpt-oss-120b)"
}

@test "a known model with no canary line is a row naming only the canary line and the candidate" {
  printf '# lanes\nnim minimax\n' > "$LADDER_SCOUT_CANARY_LANES"
  run "$SCOUT"
  assert_success
  assert_output --partial "free-qwen (qwen3.8-27b): missing a line in canary-lanes"
}

@test "a second run inside the refile window files nothing, and one after it asks again" {
  echo 'free-gpt-oss (gpt-oss-120b)' >> "$BATS_TEST_TMPDIR/catalog.nim"
  "$SCOUT" > /dev/null
  run "$SCOUT"
  assert_success
  assert_output --partial "kept"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/notes.log")" = 1 ]
  LADDER_SCOUT_NOW=$((2000000000 + 8 * 86400)) run "$SCOUT"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/notes.log")" = 2 ]
}

@test "-n reports the row and files nothing" {
  echo 'free-gpt-oss (gpt-oss-120b)' >> "$BATS_TEST_TMPDIR/catalog.nim"
  run "$SCOUT" -n
  assert_success
  assert_output --partial "would file: feat(model-lane): onboard nim gpt-oss-120b"
  [ ! -s "$BATS_TEST_TMPDIR/notes.log" ]
}

@test "a canary line for a model the gateway stopped listing is reported as gone" {
  printf 'free-minimax (minimax-m3.1-flash)\n' > "$BATS_TEST_TMPDIR/catalog.nim"
  run "$SCOUT"
  assert_success
  assert_output --partial "gone: canary-lanes names nim qwen"
}

@test "agy is said to be hand-added, and an unreadable catalog exits 1 without a row" {
  rm "$BATS_TEST_TMPDIR/catalog.nim"
  run --separate-stderr "$SCOUT"
  assert_failure 1
  [[ "$output" == *"agy: no gateway catalog, its models are hand-added"* ]] || fail "$output"
  [[ "$stderr" == *"nim: catalog unread"* ]] || fail "$stderr"
  [ ! -s "$BATS_TEST_TMPDIR/notes.log" ]
}

@test "a notes add that fails for a reason other than a twin or the outbox exits 1" {
  echo 'free-gpt-oss (gpt-oss-120b)' >> "$BATS_TEST_TMPDIR/catalog.nim"
  FAKE_NOTES_RC=2 run "$SCOUT"
  assert_failure 1
  [ ! -s "$LADDER_SCOUT_STATE/filed.tsv" ]
}

@test "a litellm-key source that is not priority=low is not scouted" {
  echo 'free-gpt-oss (gpt-oss-120b)' > "$BATS_TEST_TMPDIR/catalog.reserve"
  jq '.harnesses.lazer = {source: "reserve", models: {}}' "$LADDER_SCOUT_HARNESSES" > "$BATS_TEST_TMPDIR/h2" && mv "$BATS_TEST_TMPDIR/h2" "$LADDER_SCOUT_HARNESSES"
  run "$SCOUT"
  assert_success
  refute_output --partial "reserve"
  [ ! -s "$BATS_TEST_TMPDIR/notes.log" ]
}

@test "a source claude-acct does not carry on this host (exit 3) is skipped, not unread" {
  printf '#!/usr/bin/env bash\necho "not here" >&2; exit 3\n' > "$LADDER_SCOUT_ACCT"
  run --separate-stderr "$SCOUT"
  assert_success
  [[ "$output" == *"nim: not a litellm-key source on this host, skipped"* ]] || fail "$output"
}

@test "a warning claude-acct prints on stderr is not read as a model id" {
  printf '#!/usr/bin/env bash\ncat "$BATS_TEST_TMPDIR/catalog.$2"; echo "claude-acct: warning" >&2\n' > "$LADDER_SCOUT_ACCT"
  run --separate-stderr "$SCOUT"
  assert_success
  refute_output --partial "warning"
  [ ! -s "$BATS_TEST_TMPDIR/notes.log" ]
}

@test "a short name with regex characters matches its canary line literally, never as a pattern" {
  echo 'free-x (foo.bar+1)' >> "$BATS_TEST_TMPDIR/catalog.nim"
  printf 'nim fooXbar1\n' >> "$LADDER_SCOUT_CANARY_LANES"
  run "$SCOUT"
  assert_output --partial "free-x (foo.bar+1): missing a models entry in harnesses.json, a line in canary-lanes"
  printf 'nim foo.bar+1\n' >> "$LADDER_SCOUT_CANARY_LANES"
  run "$SCOUT"
  refute_output --partial "free-x (foo.bar+1): missing a models entry in harnesses.json, a line in canary-lanes"
}

@test "a long catalog files at most MAX_ROWS rows a run and leaves the rest for the next" {
  for i in 1 2 3; do echo "free-m$i (m$i)" >> "$BATS_TEST_TMPDIR/catalog.nim"; done
  LADDER_SCOUT_MAX_ROWS=2 run "$SCOUT"
  assert_success
  [ "$(wc -l < "$BATS_TEST_TMPDIR/notes.log")" = 2 ]
  assert_output --partial "held to the next run"
}

@test "notes exit 5 (a hand run's shortlist) files nothing and does not fail the run" {
  echo 'free-gpt-oss (gpt-oss-120b)' >> "$BATS_TEST_TMPDIR/catalog.nim"
  FAKE_NOTES_RC=5 run --separate-stderr "$SCOUT"
  assert_success
  [[ "$stderr" == *"shortlist"* ]] || fail "$stderr"
  [ ! -s "$LADDER_SCOUT_STATE/filed.tsv" ]
}

@test "under agentctl each pass declares its outcome: NOOP when quiet, WORKED when it files, FAILED when a source is unread; -n declares none" {
  export AGENTCTL_NAME=ladder-scout
  out="$AGENTCTL_STATE_DIR/ladder-scout/last-outcome"
  run "$SCOUT"
  assert_success
  [ "$(cat "$out")" = NOOP ] || fail "quiet pass: $(cat "$out")"
  echo 'free-glm (glm-5)' >> "$BATS_TEST_TMPDIR/catalog.nim"
  rm -f "$out"
  run "$SCOUT" -n
  [ ! -e "$out" ] || fail "-n declared $(cat "$out")"
  run "$SCOUT"
  assert_success
  [ "$(cat "$out")" = WORKED ] || fail "filing pass: $(cat "$out")"
  rm "$BATS_TEST_TMPDIR/catalog.nim"
  run "$SCOUT"
  assert_failure
  [ "$(cat "$out")" = FAILED ] || fail "unread pass: $(cat "$out")"
  run tail -n 1 "$AGENTCTL_STATE_DIR/ladder-scout/activity.log"
  assert_output --partial 'why: nim catalog unread'
}
