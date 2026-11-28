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
    'echo git commit --no-verify' "rg -- '--no-verify' ." "git rebase -x 'git commit --no-verify' main" \
    'git merge -m --no-verify main' 'git push -o --no-verify origin feat/x' 'git cherry-pick -X --no-verify HEAD'
}

@test "core.hooksPath moved for one command or written by git config is denied" {
  each denied "$T/wt" 'git -c core.hooksPath=/dev/null commit -m x' 'git -c Core.HooksPath=/dev/null push origin feat/x' \
    'git --config-env core.hooksPath=X commit -m x' 'git --config-env=core.hooksPath=X commit -m x' \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x' \
    "GIT_CONFIG_PARAMETERS=\"'core.hooksPath'='/dev/null'\" git commit -m x" 'env GIT_CONFIG_KEY_0=core.hooksPath git commit -m x' \
    'git config core.hooksPath /dev/null' 'git config --local core.hooksPath x' 'git config --unset core.hooksPath' \
    'git config set core.hooksPath x' 'git config unset core.hooksPath' 'git config -e' 'git config --global --edit' \
    'GIT_CONFIG_GLOBAL=/dev/null git commit -m x' 'GIT_CONFIG_NOSYSTEM=1 git push origin feat/x' 'HOME=/tmp git commit -m x' \
    'XDG_CONFIG_HOME=/tmp git merge main'
}

@test "reading core.hooksPath and other -c and config writes are allowed" {
  each allowed "$T/wt" 'git config core.hooksPath' 'git config --get core.hooksPath' 'git config get core.hooksPath' \
    'git config --show-origin --get core.hooksPath' 'git config user.name x' 'git -c user.name=x commit -m y' \
    'GIT_CONFIG_KEY_0=user.name git commit -m y' 'HOME=/tmp git log' 'GIT_CONFIG_GLOBAL=/dev/null git status'
}

@test "a push whose destination is the default branch is denied, by refspec or from that branch" {
  each denied "$T/wt" 'git push origin HEAD:main' 'git push origin feat/x:main' 'git push origin +HEAD:refs/heads/main' \
    'git push origin main' 'git push origin :main' 'git push --all origin' 'git push origin :' 'git push --repo=origin main' \
    "git -C '$T/wt' push -q origin HEAD:main" "git push '$T/origin.git' HEAD:main"
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
  # Another remote than origin is not the default branch's forge: a backup push passes.
  git -C "$T/wt" remote add backup "$T/origin.git"
  each allowed "$T/wt" 'git push backup main' 'git push backup HEAD:main'
}

@test "under push.default=upstream a bare push from a branch tracking the default branch is denied" {
  git -C "$T/wt" config push.default upstream
  run at "$T/wt" 'git push'
  denied
  git -C "$T/wt" config push.default simple
  run at "$T/wt" 'git push'
  allowed
}

@test "a bare push under push.default=matching or a remote.origin.push refspec to main is denied" {
  git -C "$T/wt" config push.default matching
  run at "$T/wt" 'git push origin'
  denied
  git -C "$T/wt" config push.default simple
  git -C "$T/wt" config remote.origin.push HEAD:refs/heads/main
  run at "$T/wt" 'git push'
  denied
  git -C "$T/wt" config remote.origin.push 'refs/heads/feat/x:refs/heads/feat/x'
  run at "$T/wt" 'git push'
  allowed
}

@test "fail-open: a broken payload or another tool allows" {
  run python3 "$GUARD" <<<'not json'
  allowed
  run bash -c "jq -nc '{tool_name:\"Read\", tool_input:{command:\"git commit -n\"}}' | python3 '$GUARD'"
  allowed
}

@test "posting agent-land's review status by hand is denied; a read, another context and agent-land --verdict are allowed" {
  local c
  c=$(sed -n 's/^export REVIEW_CONTEXT=//p' "$ROOT/.local/lib/pr-ci.sh")
  [ -n "$c" ]
  each denied "$T/wt" "gh api repos/o/r/statuses/abc -f state=success -f context=$c -f description=x" \
    "gh api -X POST repos/o/r/statuses/abc -f context=$c -f state=success" "gh api --method POST repos/o/r/statuses/abc -F context=$c" \
    "gh api repos/o/r/statuses/abc --raw-field=context=$c -f state=success" "gh api repos/o/r/statuses/abc -Fcontext=$c" \
    "gh api -X POST repos/o/r/statuses/abc --input /tmp/s.json" "cd '$T/wt' && gh api repos/o/r/statuses/abc -f context=$c"
  run at "$T/wt" "gh api repos/o/r/statuses/abc -f state=success -f context=$c"
  assert_output --partial 'agent-land'
  each allowed "$T/wt" "gh api repos/o/r/commits/abc/statuses" "gh api repos/o/r/commits/abc/statuses --jq '.[].context'" \
    "gh api repos/o/r/statuses/abc -f state=success -f context=ci" "gh api repos/o/r/statuses/abc -f context=${c}er" \
    "agent-land 42 --item x --verdict pass --note ok" "echo gh api repos/o/r/statuses/abc -f context=$c"
}

@test "applying gate-guard's human-only label, in any case or from a file, is denied; another label, a read and creating the label are allowed" {
  local label
  label=$(python3 "$ROOT/.local/bin/gate-guard" label)
  each denied "$T/wt" "gh pr edit 5 --add-label $label" "gh pr edit 5 --add-label bug,$label" "gh -R o/r pr edit 5 --add-label=$label" \
    "gh issue edit 5 --add-label $label" "gh pr create --title t --body b --label $label" "gh pr create -l $label -t t -b b" \
    "gh api repos/o/r/issues/5/labels -f labels[]=$label" "gh api --method POST repos/o/r/issues/5/labels -f \"labels[]=$label\"" \
    "cd '$T/wt' && gh pr edit 5 --add-label $label" "gh pr edit 5 --add-label ${label^^}" "gh pr create -t t -b b -l$label" \
    "gh api repos/o/r/issues/5/labels --input /tmp/l.json" "gh api -X POST repos/o/r/issues/5/labels -F labels[]=@f"
  run at "$T/wt" "gh pr edit 5 --add-label $label"
  assert_output --partial 'the label only the human applies'
  each allowed "$T/wt" 'gh pr edit 5 --add-label bug' "gh pr edit 5 --remove-label $label" "gh label create $label --color B60205" \
    "gh api repos/o/r/issues/5/labels --jq '.[].name'" "gh pr view 5 --json labels" "echo gh pr edit 5 --add-label $label" \
    'gh pr create -t t -b b -lbug' "gh pr list --label $label"
}
