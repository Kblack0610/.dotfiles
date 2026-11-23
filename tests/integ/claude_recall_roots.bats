#!/usr/bin/env bats
# claude-recall reads the transcripts of every Claude account in claude-acct's accounts file:
# an account linked to main's projects/ once, an unlinked account's own dir, and the
# .pre-share-<date>/projects copy `claude-acct link` parks. The sandbox HOME holds all three.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  RECALL="$REPO_ROOT/.local/bin/claude-recall"
  unset CLAUDE_TRANSCRIPTS CLAUDE_ACCT_CONFIG
  mkdir -p "$XDG_CONFIG_HOME/claude-acct"
  printf '# name dir\nmain -\nlinked ~/.claude-linked\nsolo ~/.claude-solo\n' > "$XDG_CONFIG_HOME/claude-acct/accounts"

  ts='"timestamp":"2026-11-17T10:00:00Z"'
  session() {   # session <projects dir> <id> <words>
    mkdir -p "$1/-home-u-proj"
    printf '{"type":"user","cwd":"/home/u/proj",%s,"message":{"role":"user","content":"%s"}}\n' "$ts" "$3" > "$1/-home-u-proj/$2.jsonl"
  }
  H=$(cd "$HOME" && pwd -P)   # roots are real paths
  session "$HOME/.claude/projects" main1 "mainword here"
  mkdir -p "$HOME/.claude-linked"
  ln -s "$HOME/.claude/projects" "$HOME/.claude-linked/projects"
  session "$HOME/.claude-linked/.pre-share-2026-11-15/projects" parked1 "parkedword here"
  session "$HOME/.claude-solo/projects" solo1 "soloword here"
  # a config dir no accounts line names (a hand-set CLAUDE_CONFIG_DIR)
  session "$HOME/.claude-work/projects" work1 "workword here"
}

@test "roots: main, an unlinked account and a parked copy, a linked account read once" {
  run "$RECALL" roots
  assert_success
  assert_line "$H/.claude/projects	1 sessions"
  assert_line "$H/.claude-solo/projects	1 sessions"
  assert_line "$H/.claude-linked/.pre-share-2026-11-15/projects	1 sessions"
  assert_line "$H/.claude-work/projects	1 sessions"
  assert_equal "${#lines[@]}" 4
}

@test "search finds a session in every account's dir" {
  for w in mainword soloword parkedword workword; do
    run "$RECALL" search "$w" --context 0
    assert_success
    assert_output --partial "1 match(es)"
  done
}

@test "with no accounts file, main and the other ~/.claude* dirs are still read" {
  rm "$XDG_CONFIG_HOME/claude-acct/accounts"
  run "$RECALL" roots
  assert_success
  assert_line "$H/.claude/projects	1 sessions"
  assert_line "$H/.claude-solo/projects	1 sessions"
  assert_line "$H/.claude-linked/.pre-share-2026-11-15/projects	1 sessions"
  assert_equal "${#lines[@]}" 4
}

@test "a session in both main and a parked copy is read once, from main" {
  session "$HOME/.claude-linked/.pre-share-2026-11-15/projects" main1 "mainword here"
  run "$RECALL" search mainword --context 0
  assert_success
  assert_output --partial "1 match(es)"
}

@test "sessions resolves a session that is only in an unlinked account's dir" {
  run "$REPO_ROOT/.local/bin/sessions" prompts solo1
  assert_success
  assert_output --partial "soloword here"
}
