#!/usr/bin/env bats
# checkout-guard.py: a checkout stow deploys stays on its default branch. The repos are fixtures
# built here; the hook only reads git state. .githooks/post-checkout is the record of a move that
# got past it, run by a real checkout in the fixture.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$BATS_TEST_DIRNAME/../.."
  GUARD="$ROOT/.claude/hooks/checkout-guard.py"
  T="$BATS_TEST_TMPDIR"
  g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
  g init -b main "$T/dots"
  g -C "$T/dots" commit --allow-empty -m init
  g -C "$T/dots" branch fix/x
  g -C "$T/dots" update-ref refs/remotes/origin/fix/x HEAD
  g -C "$T/dots" update-ref refs/remotes/origin/main HEAD
  g -C "$T/dots" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  touch "$T/dots/f"
  g -C "$T/dots" worktree add "$T/wt" -b feat/w
  g init -b main "$T/other"
  g -C "$T/other" commit --allow-empty -m init
  g -C "$T/other" branch fix/x
  export DOTFILES="$T/dots" DOTFILES_PRIVATE="$T/absent"
}

at() { jq -nc --arg c "$2" --arg d "$1" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | python3 "$GUARD"; }

denied() { assert_success; assert_output --partial '"deny"'; assert_output --partial 'checkout-guard:'; }
allowed() { assert_success; assert_output ''; }

@test "the 2026-11-06 command is denied, from any cwd" {
  run at /tmp "cd $T/dots; git fetch -q origin 2>&1|tail -1; git checkout -q --detach origin/fix/x 2>&1|tail -2; git log --oneline -1"
  denied
  assert_output --partial 'git show'
}

@test "every way off the default branch is denied" {
  local c
  for c in 'git checkout fix/x' 'git checkout origin/main' 'git checkout -b new' 'git checkout -' 'git checkout --detach' \
           'git switch fix/x' 'git switch -c new' 'git switch --detach main' 'git switch -' 'gh pr checkout 1240' \
           "git -C $T/dots switch fix/x" 'bash -c "git switch fix/x"'; do
    run at "$T/dots" "$c"
    denied
  done
}

@test "going to the default branch and restoring files are allowed" {
  local c
  for c in 'git checkout main' 'git switch main' 'git checkout -- f' 'git checkout fix/x -- f' 'git checkout HEAD f' 'git checkout f' 'git checkout .'; do
    run at "$T/dots" "$c"
    allowed
  done
}

@test "a linked worktree and any other repo are left alone" {
  run at "$T/wt" 'git switch -c next'
  allowed
  run at "$T/other" 'git checkout fix/x'
  allowed
  run at "$T/wt" 'gh pr checkout 1240'
  allowed
}

@test "settings.json runs the guard on every Bash call, fail-open" {
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("checkout-guard"))' "$ROOT/.claude/settings.json"
  assert_output 'python3 ~/.claude/hooks/checkout-guard.py || true'
}

@test "post-checkout records who moved the deployed checkout, and nothing else" {
  export FLEET_SHEPHERD_DIR="$T/ledger" CLAUDE_CODE_SESSION_ID=abcdef0123 AGENT_QUEUE_ITEM=some-item
  g -C "$T/dots" config core.hooksPath "$ROOT/.githooks"
  # negative controls: a worktree's move, and a return to the default branch, leave no record
  g -C "$T/wt" switch -c elsewhere
  g -C "$T/dots" switch main
  [ ! -e "$T/ledger/checkout-moves.tsv" ]
  run git -C "$T/dots" checkout -q --detach origin/fix/x
  assert_success
  assert_output --partial "is off main"
  [ "$(wc -l < "$T/ledger/checkout-moves.tsv")" = 1 ]
  [ "$(cut -f2 "$T/ledger/checkout-moves.tsv")" = "$(git -C "$T/dots" rev-parse --show-toplevel)" ]
  [ "$(cut -f3 "$T/ledger/checkout-moves.tsv")" = "$(git -C "$T/dots" rev-parse HEAD)" ]
  run cut -f4 "$T/ledger/checkout-moves.tsv"
  assert_output --partial 'session abcdef01 item some-item'
  assert_output --partial 'git'
}
