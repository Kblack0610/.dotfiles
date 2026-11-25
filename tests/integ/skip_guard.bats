#!/usr/bin/env bats
# skip-guard.py: a session cannot skip a gate on its own (plan everything-should-wondrous-snail P2,
# ar-5448): --no-verify, a moved core.hooksPath, a push straight to the default branch. Each deny
# has its allowed twin, the normal command. The repos are fixtures built here, with a bare origin
# whose HEAD is main; the hook only reads git state.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$BATS_TEST_DIRNAME/../.."
  GUARD="$ROOT/.claude/hooks/skip-guard.py"
  T="$BATS_TEST_TMPDIR"
  g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
  g init --bare -b main "$T/origin.git"
  g init -b main "$T/repo"
  g -C "$T/repo" commit --allow-empty -m init
  g -C "$T/repo" remote add origin "$T/origin.git"
  g -C "$T/repo" push -q origin main
  g -C "$T/repo" fetch -q origin
  g -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  # A worktree cut off origin/main tracks it, as `git worktree add -b x <wt> origin/main` leaves one.
  g -C "$T/repo" worktree add --track -b feat/x "$T/wt" origin/main
  g init -b main "$T/plain"
  g -C "$T/plain" commit --allow-empty -m init
  g -C "$T/plain" remote add backup "$T/origin.git"
}

at() { jq -nc --arg c "$2" --arg d "$1" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | python3 "$GUARD"; }

denied() { assert_success; assert_output --partial '"deny"'; assert_output --partial 'skip-guard:'; }
allowed() { assert_success; assert_output ''; }

each() {
  local verdict=$1 dir=$2 c
  shift 2
  for c in "$@"; do
    run at "$dir" "$c"
    "$verdict" || { echo "for: $c" >&2; return 1; }
  done
}

@test "--no-verify on a hooked git command and git commit -n are denied, through cd, -C and bash -c" {
  each denied "$T/wt" 'git commit --no-verify -m x' 'git commit -n -m x' 'git commit -anm x' 'git commit -qn -m x' \
    'git commit -m x --no-veri' 'git push --no-verify origin feat/x' 'git merge --no-verify main' 'git pull --no-verify' \
    'git rebase --no-verify main' "cd '$T/wt' && git commit --no-verify -m x" "git -C '$T/wt' commit -n -m x" \
    'bash -c "git commit --no-verify -m x"'
  run at "$T/wt" 'git commit --no-verify -m x'
  assert_output --partial 'Only the human bypasses a hook'
}

@test "a commit message, a path after --, -u, and -n on another verb are not --no-verify" {
  each allowed "$T/wt" 'git commit -m -n' 'git commit -m "--no-verify is denied"' 'git commit -uno -m x' 'git commit -am fix' \
    'git commit -- --no-verify' 'git merge -n main' 'git commit -m x --no-ver' 'git log --grep=no-verify' \
    'echo git commit --no-verify' "rg -- '--no-verify' ."
}

@test "core.hooksPath moved for one command or written by git config is denied" {
  each denied "$T/wt" 'git -c core.hooksPath=/dev/null commit -m x' 'git -c Core.HooksPath=/dev/null push origin feat/x' \
    'git --config-env core.hooksPath=X commit -m x' 'git --config-env=core.hooksPath=X commit -m x' \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x' \
    "GIT_CONFIG_PARAMETERS=\"'core.hooksPath'='/dev/null'\" git commit -m x" 'env GIT_CONFIG_KEY_0=core.hooksPath git commit -m x' \
    'git config core.hooksPath /dev/null' 'git config --local core.hooksPath x' 'git config --unset core.hooksPath' \
    'git config set core.hooksPath x' 'git config unset core.hooksPath'
}

@test "reading core.hooksPath and other -c and config writes are allowed" {
  each allowed "$T/wt" 'git config core.hooksPath' 'git config --get core.hooksPath' 'git config get core.hooksPath' \
    'git config --show-origin --get core.hooksPath' 'git config user.name x' 'git -c user.name=x commit -m y' \
    'GIT_CONFIG_KEY_0=user.name git commit -m y'
}

@test "a push whose destination is the default branch is denied, by refspec or from that branch" {
  each denied "$T/wt" 'git push origin HEAD:main' 'git push origin feat/x:main' 'git push origin +HEAD:refs/heads/main' \
    'git push origin main' 'git push origin :main' 'git push --all origin' 'git push origin :' 'git push --repo=origin main' \
    "git -C '$T/wt' push -q origin HEAD:main"
  each denied "$T/repo" 'git push' 'git push origin' 'git push origin HEAD' 'git push -u origin HEAD'
  run at "$T/wt" 'git push origin HEAD:main'
  assert_output --partial 'main, the default branch'
  assert_output --partial 'agent-land <N>'
}

@test "a branch push, a tag, a dry run and a repo with no default branch on origin are allowed" {
  each allowed "$T/wt" 'git push -u origin HEAD' 'git push origin feat/x' 'git push' 'git push origin HEAD:feat/x' \
    'git push origin v1.0' 'git push origin refs/tags/v1' 'git push -n origin HEAD:main' 'git push --dry-run origin main' \
    'git push origin feat/x:refs/heads/feat/y'
  each allowed "$T/plain" 'git push backup main' 'git push'
}

@test "under push.default=upstream a bare push from a branch tracking the default branch is denied" {
  git -C "$T/wt" config push.default upstream
  run at "$T/wt" 'git push'
  denied
  git -C "$T/wt" config push.default simple
  run at "$T/wt" 'git push'
  allowed
}

@test "fail-open: a broken payload or another tool allows" {
  run python3 "$GUARD" <<<'not json'
  allowed
  run bash -c "jq -nc '{tool_name:\"Read\", tool_input:{command:\"git commit -n\"}}' | python3 '$GUARD'"
  allowed
}
