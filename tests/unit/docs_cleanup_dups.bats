#!/usr/bin/env bats
# agentctl-docs-cleanup counts restated instructions (skill-drift --dups --check) beside the skill and
# doc drift: a count over dup_pairs_max is drift and queues the pass, a count at or under it is not,
# knowledge lint drift (the vault, with the knowledge-retired list) queues the same one pass,
# an open correction chain is drift too, and a lost baseline reads FAILED instead of "no drift". skill-drift is a stub that serves canned JSON.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  export HOME="$BATS_TEST_TMPDIR/home"
  BIN="$HOME/.local/bin"
  export PATH="$BIN:$PATH" # the runner unit declares ~/.local/bin on PATH; the script no longer does
  mkdir -p "$BIN" "$HOME/.local/lib" "$HOME/.agent/lessons"
  cp "$BATS_TEST_DIRNAME/../../.local/bin/agentctl-docs-cleanup" "$BATS_TEST_DIRNAME/../../.local/bin/lessons" "$BATS_TEST_DIRNAME/../../.local/bin/docs-renamed-paths" "$BIN/"
  # shape-grow --stock is a stub: STOCK_OUT is its answer, STOCK_RC its exit; it records its arguments.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$HOME/stock.args"\n[ -z "${STOCK_OUT-}" ] || printf "%%s\\n" "$STOCK_OUT"\nexit "${STOCK_RC:-0}"\n' > "$BIN/shape-grow"
  printf 'proof_outcome() { :; }\n' > "$HOME/.local/lib/agent-proof.sh"
  printf '#!/usr/bin/env bash\necho docs-cleanup\n' > "$BIN/agentctl"
  printf '#!/usr/bin/env bash\necho "{}"\n' > "$BIN/agent-queue"
  # knowledge lint and the retired list are stubs: KNOWLEDGE_JSON is the lint answer, RETIRED_RC the list's exit.
  cat > "$BIN/notes" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "knowledge lint" ] || exit 2
printf '%s\n' "$*" > "$LINT_ARGS"
printf '%s\n' "${KNOWLEDGE_JSON-{\"total\":0\}}"
STUB
  cat > "$BIN/knowledge-retired" <<'STUB'
#!/usr/bin/env bash
printf 'host\tmac-studio\tleft the inventory\n'
exit "${RETIRED_RC:-0}"
STUB
  cat > "$BIN/skill-drift" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --json) echo '{"findings":[]}' ;;
  --docs) echo '{"drift":0}' ;;
  --dups) [ -n "$DUPS_JSON" ] || exit 2; echo "$DUPS_JSON"; [ "$(jq .over <<<"$DUPS_JSON")" = 0 ] || exit 1 ;;
esac
STUB
  chmod +x "$BIN"/*
  export AGENTCTL_INBOX="$BATS_TEST_TMPDIR/inbox" DOCS_CLEANUP_LESSONS="$HOME/.agent/lessons" LINT_ARGS="$BATS_TEST_TMPDIR/lint.args"
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

@test "an open correction chain is drift, in the baseline and its summary; one that only reads like a correction is not" {
  printf -- '- **2026-08-18** The backup mirror is alive at zero commits ahead.\n- **2026-08-20** Correction to the 08-18 bullet: zero commits ahead says the backup mirror is reachable.\n' > "$HOME/.agent/lessons/p.md"
  DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_success
  assert_output --partial 'no drift ('
  assert_output --partial 'correction chains 0,'
  k=$("$BIN/lessons" key "$HOME/.agent/lessons/p.md" 1)
  sed -i "2s/\$/ <!-- supersedes:$k -->/" "$HOME/.agent/lessons/p.md"
  DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_success
  assert_output --partial 'would queue'
  assert_output --partial 'correction chains 1,'
  run cut -f1,2 "$AGENTCTL_INBOX"/*/chains.tsv
  assert_output $'p.md:2\t1'
  # A marker whose target was reworded away is drift too, listed with target -.
  sed -i "1s/alive/up/" "$HOME/.agent/lessons/p.md"
  rm -rf "${AGENTCTL_INBOX:?}"/*
  DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_output --partial 'correction chains 1,'
  run cut -f1,2 "$AGENTCTL_INBOX"/*/chains.tsv
  assert_output $'p.md:2\t-'
}

@test "a real run archives a live chain's target by script, so the night counts no chain; a dry run moves nothing" {
  printf -- '- **2026-08-18** The backup mirror is alive at zero commits ahead.\n- **2026-08-20** Correction to the 08-18 bullet: zero commits ahead says the backup mirror is reachable.\n' > "$HOME/.agent/lessons/p.md"
  k=$("$BIN/lessons" key "$HOME/.agent/lessons/p.md" 1)
  sed -i "2s/\$/ <!-- supersedes:$k -->/" "$HOME/.agent/lessons/p.md"
  DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_output --partial 'correction chains 1,'
  [ ! -e "$HOME/.agent/lessons/_archive/p-superseded.md" ]
  DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'no drift ('
  assert_output --partial 'correction chains 0,'
  grep -q 'alive at zero commits ahead' "$HOME/.agent/lessons/_archive/p-superseded.md"
  ! grep -q 'alive at zero commits ahead' "$HOME/.agent/lessons/p.md"
}

@test "a lost baseline row is a failure, not a quiet night" {
  DUPS_JSON= run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_failure 1
  assert_output --partial 'skill-drift --dups --check --json gave no JSON'
}

@test "knowledge drift queues the one pass, and the lint reads the retired list the runner wrote" {
  KNOWLEDGE_JSON='{"total":2,"classes":{"dated_slug":{"count":1},"retired_command":{"count":1}}}' \
    DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_success
  assert_output --partial 'would queue'
  assert_output --partial 'correction chains 0, knowledge 2.'
  run cat "$LINT_ARGS"
  assert_output --partial "--retired $AGENTCTL_INBOX/"
  run cat "$AGENTCTL_INBOX"/*/retired.tsv
  assert_output "$(printf 'host\tmac-studio\tleft the inventory')"
}

@test "negative control: zero knowledge drift is no drift" {
  DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_success
  assert_output --partial 'no drift ('
  assert_output --partial 'knowledge 0)'
}

@test "a lint with no JSON or a retired list that fails is a failure, not a quiet night" {
  KNOWLEDGE_JSON='' DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_failure 1
  assert_output --partial 'notes knowledge lint gave no JSON'
  RETIRED_RC=1 DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_failure 1
  assert_output --partial 'knowledge-retired failed'
}

@test "the copy stock is scanned over the default repos and written to stock.txt; an over line is no drift" {
  STOCK_OUT=$'dotfiles_sites=345\nover dotfiles_sites 345 (baseline 300)' STOCK_RC=1 DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_success
  assert_output --partial 'no drift ('
  run grep -c '^over ' "$AGENTCTL_INBOX"/*/stock.txt
  assert_output 1
  assert_equal "$(cat "$HOME/stock.args")" "--stock --check $HOME/.dotfiles $HOME/.dotfiles-private"
}

@test "copy-stock-repos names the repos to scan; a scan that cannot run reads FAILED" {
  mkdir -p "$HOME/.config/agentctl"
  printf '# the repos\n~/dev/platform  # api\n/srv/other\n' > "$HOME/.config/agentctl/copy-stock-repos"
  DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_success
  assert_equal "$(cat "$HOME/stock.args")" "--stock --check $HOME/dev/platform /srv/other"
  STOCK_RC=2 DUPS_JSON='{"pairs":60,"max":60,"over":0}' run "$BIN/agentctl-docs-cleanup" --dry-run
  assert_failure
  assert_output --partial 'shape-grow --stock could not run'
}
