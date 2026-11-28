#!/usr/bin/env bats
# forge-failover: the drill for home-config docs/gitops.md "Failover", on throwaway repos. "GitHub" and
# "Forgejo" are local bare repos that git's url.insteadOf maps the remotes' real-looking URLs to, so the
# checkout keeps github.com and a Forgejo host in its config (what forge-guard reads) while no network is
# touched. gh is a stub that logs its arguments. The live forge-drill (a scratch repo on both forges) is
# the same cycle by hand.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  FF="$REPO_ROOT/.local/bin/forge-failover"
  GUARD="$REPO_ROOT/.claude/hooks/forge-guard.py"
  T="$SANDBOX/drill"
  mkdir -p "$T/bin"
  export FORGE_STATE_DIR="$SANDBOX/state/forge"
  export FORGE_GH="$T/bin/gh" GH_LOG="$T/gh.log"
  printf '#!/bin/sh\necho "$*" >> "$GH_LOG"\n[ -z "$GH_FAIL" ] || exit 1\n' > "$T/bin/gh"
  chmod +x "$T/bin/gh"
  g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
  GH_URL=git@github.com:Kblack0610/hc.git
  FJ_URL=https://forgejo.example/kblack0610/hc.git
  g init --bare "$T/gh.git"; g init --bare "$T/fj.git"
  g init "$T/hc"
  mkdir -p "$T/hc/.forgejo/workflows"
  : > "$T/hc/.forgejo/workflows/mirror-to-github.yaml"
  g -C "$T/hc" add -A; g -C "$T/hc" commit -m init
  g -C "$T/hc" remote add origin "$GH_URL"
  g -C "$T/hc" remote add forgejo "$FJ_URL"
  net git -C "$T/hc" push -q origin master 2>/dev/null
  net git -C "$T/hc" push -q forgejo master 2>/dev/null
  git -C "$T/gh.git" symbolic-ref HEAD refs/heads/master
  export PROJECT_MAP_FILE="$T/map.json"
  jq -nc --arg d "$T/hc" '{paths: {($d): "hc"}}' > "$PROJECT_MAP_FILE"
}

# net CMD...: run with the two remote URLs mapped to the local bare repos, for the git calls that
# would reach a forge. Everything else (the guard, forge_canonical) sees the real-looking URLs.
net() {
  GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0="url.$T/gh.git.insteadOf" GIT_CONFIG_VALUE_0="$GH_URL" \
  GIT_CONFIG_KEY_1="url.$T/fj.git.insteadOf" GIT_CONFIG_VALUE_1="$FJ_URL" \
  "$@"
}

guard() { jq -nc --arg c "$1" --arg d "$T/hc" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | python3 "$GUARD"; }
tip() { git -C "$T/$1.git" rev-parse master; }
commit() { g -C "$T/hc" commit --allow-empty -m "$1"; }

@test "off: status says so, and forge-guard denies a GitHub push" {
  run net "$FF" status hc
  assert_success
  assert_output --partial 'off:'
  run guard 'git push origin master'
  assert_output --partial '"deny"'
}

@test "the whole cycle: on, land on GitHub, off, Forgejo has the merge" {
  run net "$FF" on hc
  assert_success
  [ -f "$FORGE_STATE_DIR/hc" ]
  grep -q 'variable set FORGE_FAILOVER --body 1 --repo Kblack0610/hc' "$GH_LOG"

  # While on: GitHub is where it lands. The guard allows the push, and agent-land's forge pick is GitHub.
  run guard 'git push origin master'
  assert_output ''
  run bash -c ". '$REPO_ROOT/.local/lib/origin-repo.sh'; forge_canonical '$T/hc'"
  assert_failure
  run bash -c ". '$REPO_ROOT/.local/lib/session-outcomes.sh'; so_forge_remote '$T/hc'"
  assert_failure 1
  run net "$FF" status hc
  assert_output --partial 'on since'

  # The merge lands on GitHub only.
  commit 'merged on github'
  net git -C "$T/hc" push -q origin master
  [ "$(tip gh)" != "$(tip fj)" ]

  run net "$FF" off hc
  assert_success
  [ "$(tip fj)" = "$(tip gh)" ]
  [ ! -e "$FORGE_STATE_DIR/hc" ]
  grep -q 'variable delete FORGE_FAILOVER --repo Kblack0610/hc' "$GH_LOG"

  # Negative control: off again, the guard denies GitHub and the repo is Forgejo-canonical.
  run guard 'git push origin master'
  assert_output --partial '"deny"'
  run bash -c ". '$REPO_ROOT/.local/lib/origin-repo.sh'; forge_canonical '$T/hc'"
  assert_success
}

@test "a worktree of the repo reads the same state" {
  g -C "$T/hc" worktree add "$T/wt" -b feat
  run net "$FF" on "$T/wt"
  assert_success
  [ -f "$FORGE_STATE_DIR/hc" ]
  run bash -c ". '$REPO_ROOT/.local/lib/origin-repo.sh'; forge_canonical '$T/hc'"
  assert_failure
}

@test "off refuses, state kept, when Forgejo holds a commit GitHub lacks" {
  net "$FF" on hc
  commit 'only on forgejo'
  net git -C "$T/hc" push -q forgejo master
  g -C "$T/hc" reset --hard HEAD~1
  commit 'only on github'
  net git -C "$T/hc" push -q origin master
  fj=$(tip fj)
  : > "$GH_LOG"
  run net "$FF" off hc
  assert_failure
  assert_output --partial 'diverged'
  [ "$(tip fj)" = "$fj" ]
  [ -e "$FORGE_STATE_DIR/hc" ]
  ! grep -q 'variable delete' "$GH_LOG"
}

@test "on fails with no state when GitHub refuses the variable" {
  GH_FAIL=1 run net "$FF" on hc
  assert_failure
  assert_output --partial 'GitHub is not usable'
  [ ! -e "$FORGE_STATE_DIR/hc" ]
}

@test "a repo without the marker is refused" {
  g init "$T/plain"
  run "$FF" on "$T/plain"
  assert_failure
  assert_output --partial 'not Forgejo-canonical'
}

@test "the mirror's push (no --force) fails on a diverged GitHub branch instead of erasing it" {
  # the push command of home-config .forgejo/workflows/mirror-to-github.yaml, against the drill's remotes
  commit 'only on github'
  net git -C "$T/hc" push -q origin master
  g -C "$T/hc" reset --hard HEAD~1
  commit 'only on forgejo'
  net git -C "$T/hc" push -q forgejo master
  before=$(tip gh)
  run net git -C "$T/fj.git" push --prune "$GH_URL" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
  assert_failure
  [ "$(tip gh)" = "$before" ]
}

@test "project-map forges shows the failover while it is on" {
  export SO_FORGEJO_HOSTS=forgejo.example
  run "$REPO_ROOT/.local/bin/project-map" forges
  [ "$(grep -E '^hc ' <<<"$output" | tr -s ' ' | cut -d' ' -f2,4)" = "forgejo github" ]
  net "$FF" on hc
  run "$REPO_ROOT/.local/bin/project-map" forges
  [ "$(grep -E '^hc ' <<<"$output" | tr -s ' ' | cut -d' ' -f2,4)" = "github failover" ]
}
