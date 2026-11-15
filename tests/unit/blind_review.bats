#!/usr/bin/env bats
# blind-review skill: blind.sh snapshots a repo with no history and audits a subagent transcript.
# The audit is the only proof the blind agent stayed blind, so every evasion form it must catch is a
# case here, and a transcript it cannot read must fail, never pass as clean.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  B="$ROOT/.claude/skills/research/blind-review/blind.sh"
  export HOME="$BATS_TEST_TMPDIR/home" CLAUDE_CODE_SESSION_ID=test-session
  T="$HOME/.claude-x/projects/p/s/subagents"
  mkdir -p "$T"
}

# transcript ID CALL... -> one assistant tool_use line per Bash command
transcript() {
  local id=$1 c; shift
  for c in "$@"; do
    jq -nc --arg c "$c" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}'
  done > "$T/agent-$id.jsonl"
}

@test "snapshot: the tree at the commit, no .git, neutral name" {
  r="$BATS_TEST_TMPDIR/plan-x-repo"; git init -q "$r"; echo a > "$r/f"
  git -C "$r" add f; git -C "$r" -c user.email=t@t -c user.name=t commit -qm one
  run "$B" snapshot "$r" HEAD
  assert_success
  [[ $output == "$HOME/.cache/blind-review/test-session/src-"* ]]
  [ -f "$output/f" ] && [ ! -e "$output/.git" ]
  [[ $output != *plan-x* ]]
}

@test "snapshot: a bad rev exits 2 and leaves nothing behind" {
  r="$BATS_TEST_TMPDIR/r"; git init -q "$r"
  run "$B" snapshot "$r" nope
  assert_failure 2
  [ -z "$(ls -A "$HOME/.cache/blind-review/test-session" 2>/dev/null)" ]
}

@test "audit: clean calls pass" {
  transcript ok "ls /snap/src" "rg -n foo /snap/src" "git -C /snap archive HEAD" "cat ~/.agentrc-not"
  run "$B" audit ok "$HOME/.dotfiles"
  assert_success
  assert_output --partial clean
}

@test "audit: each forbidden form is a leak" {
  local c
  for c in "cat ~/.claude-max4/plans/x.md" "ls ~/.agent" "ls \$HOME/.agent/queue" "cd $HOME/.notes && cat a" \
           "git log --oneline" "git -C /r log" "git --no-pager show HEAD" "git -c a=b blame f" \
           "cat ~/.dotfiles/CLAUDE.md" "ls $HOME/.dotfiles"; do
    transcript leak "ls /snap" "$c"
    run "$B" audit leak "~/.dotfiles"
    assert_failure 1
    assert_output --partial LEAK
  done
}

@test "audit: a live path does not match its prefix sibling" {
  transcript sib "cat ~/.dotfiles-private/x"
  run "$B" audit sib "$HOME/.dotfiles"
  assert_success
}

@test "audit: a live path with regex characters is escaped, not an error" {
  transcript re "ls /snap"
  run "$B" audit re "$HOME/a+b(c)[d]"
  assert_success
}

@test "audit: an unreadable transcript fails with 2, never clean" {
  printf '{"type":"assistant","message":{"content":[\n' > "$T/agent-bad.jsonl"
  run "$B" audit bad
  assert_failure 2
  refute_output --partial clean
}

@test "audit: an unknown agent id fails with 2" {
  run "$B" audit missing
  assert_failure 2
}
