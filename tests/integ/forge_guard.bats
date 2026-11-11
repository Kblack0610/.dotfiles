#!/usr/bin/env bats
# forge-guard.py: in a checkout that commits .forgejo/workflows/mirror-to-github.yaml, gh pr
# create/merge and a push to a github.com remote are denied; anywhere else gh pr merge, and on any
# forge a merge through the PR API, are denied naming agent-land. The repos are fixtures built here; the hook only reads git state,
# so nothing outside BATS_TEST_TMPDIR is touched.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  GUARD="$BATS_TEST_DIRNAME/../../.claude/hooks/forge-guard.py"
  T="$BATS_TEST_TMPDIR"
  g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
  # hc: Forgejo-canonical like home-config. ps: a Forgejo remote but GitHub CI, like personal-sites.
  for r in hc ps; do
    g init "$T/$r"
    g -C "$T/$r" remote add origin "git@github.com:Kblack0610/$r.git"
    g -C "$T/$r" remote add forgejo "https://forgejo.example/kblack0610/$r.git"
  done
  mkdir -p "$T/hc/.forgejo/workflows"
  touch "$T/hc/.forgejo/workflows/mirror-to-github.yaml"
  g -C "$T/hc" add -A
  g -C "$T/hc" commit -m init
  g -C "$T/hc" config branch.master.remote origin
  g -C "$T/ps" commit --allow-empty -m init
  g -C "$T/hc" worktree add "$T/wt" -b feat/x
  export PROJECT_MAP_FILE="$T/map.json"
  jq -nc --arg hc "$T/hc" --arg ps "$T/ps" '{paths: {($hc): "home-config", ($ps): "personal-sites"}}' > "$PROJECT_MAP_FILE"
}

at() { jq -nc --arg c "$2" --arg d "$1" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | python3 "$GUARD"; }

denied() { assert_success; assert_output --partial '"deny"'; assert_output --partial 'forge-guard:'; }
allowed() { assert_success; assert_output ''; }

@test "the 2026-11-06 PR 62 commands are denied, from a dotfiles cwd" {
  run at /tmp "cd $T/wt
git add f
git push -q -u origin feat/x 2>&1 | tail -1"
  denied
  assert_output --partial 'git push origin'
  assert_output --partial 'git push forgejo <branch>'
  run at /tmp "cd $T/wt && gh pr create --head feat/x --base master --title t --body-file b.md"
  denied
  run at /tmp "cd $T/hc
gh pr merge 62 --squash --delete-branch 2>&1 | tail -1"
  denied
}

@test "the payload cwd, git -C, a bare push, -R and GH_REPO each find the checkout" {
  run at "$T/hc" 'gh pr create --fill'
  denied
  run at /tmp "git -C $T/wt push origin HEAD"
  denied
  run at "$T/hc" 'git push'
  denied
  run at /tmp 'gh pr merge 62 -R Kblack0610/home-config --squash'
  denied
  run at /tmp 'GH_REPO=Kblack0610/home-config gh pr create --fill'
  denied
  run at "$T/hc" 'git push git@github.com:Kblack0610/home-config.git HEAD'
  denied
}

@test "Forgejo pushes, reads, and repos that are not Forgejo-canonical pass" {
  run at "$T/wt" 'git push -u forgejo feat/x'
  allowed
  run at "$T/hc" 'gh pr view 62; gh pr list; git fetch origin'
  allowed
  run at "$T/ps" 'git push origin HEAD && gh pr create --fill && agent-land 1'
  allowed
  # agent-land lands a Forgejo PR through that forge's API, so it runs in a Forgejo checkout too.
  run at /tmp "pushd $T/hc >/dev/null; agent-land 62 --item x"
  allowed
  run at /tmp 'gh pr create -R Kblack0610/personal-sites; gh pr create -R Kblack0610/unknown'
  allowed
  run at /tmp "cd $T/hc && cd $T/ps && gh pr create --fill"
  allowed
}

@test "text that only mentions the commands passes" {
  run at "$T/hc" 'echo "gh pr merge 62"; git commit -m "git push origin was the bug"'
  allowed
  run at "$T/hc" "cat > b.md <<'EOF'
gh pr create
git push origin x
EOF"
  allowed
  run at "$T/hc" '# not gh pr create
git log -1'
  allowed
}

@test "fail-open: unparseable input and other tools are allowed" {
  run at "$T/hc" "gh pr create 'unbalanced"
  allowed
  run bash -c "echo 'not json' | python3 '$GUARD'"
  allowed
  run bash -c "jq -nc '{tool_name:\"Read\", tool_input:{file_path:\"x\"}}' | python3 '$GUARD'"
  allowed
}

@test "review forms: redirects, keywords, nested shells, mid-word #, cd flags, \$HOME, PR URLs" {
  run at "$T/hc" 'git push 2>&1 | tail -1'
  denied
  run at "$T/hc" 'git push >/dev/null'
  denied
  run at /tmp "if true; then cd $T/hc && gh pr merge 62; fi"
  denied
  run at /tmp "bash -lc 'cd $T/hc && gh pr merge 62'"
  denied
  run at "$T/hc" 'eval gh pr merge 62'
  denied
  run at "$T/hc" 'n=`gh pr create --fill`'
  denied
  run at "$T/ps" "git push origin fix#3; cd $T/hc; gh pr merge 1"
  denied
  run at /tmp "cd -P $T/hc && env -i gh pr merge 62"
  denied
  run env HOME="$T" bash -c "jq -nc '{tool_name:\"Bash\", cwd:\"/tmp\", tool_input:{command:\"cd \$HOME/hc && gh pr merge 1\"}}' | python3 '$GUARD'"
  denied
  run at /tmp 'gh pr merge https://github.com/Kblack0610/home-config/pull/62 --squash'
  denied
}

@test "review forms: a subshell's cd stays inside it, a missing map and a lookalike host allow" {
  run at "$T/ps" "(cd $T/hc && git log -1); gh pr create --fill"
  allowed
  run env PROJECT_MAP_FILE="$T/none.json" bash -c "jq -nc '{tool_name:\"Bash\", cwd:\"$T/hc\", tool_input:{command:\"gh pr create -R o/home-config; git push origin HEAD\"}}' | python3 '$GUARD'"
  denied
  assert_output --partial 'git push origin'
  git -C "$T/hc" remote add look "https://forgejo.example/x/github.com-mirror.git"
  run at "$T/hc" 'git push look HEAD'
  allowed
}

@test "gh pr merge outside a Forgejo checkout is denied, naming agent-land with the PR and repo" {
  run at "$T/ps" 'gh pr merge 1 --squash --delete-branch'
  denied
  assert_output --partial 'agent-land 1'
  assert_output --partial 'ledger_coverage'
  run at /tmp 'gh pr merge 563 --squash -R Kblack0610/.dotfiles-private'
  denied
  assert_output --partial 'agent-land 563 --repo Kblack0610/.dotfiles-private'
  run at /tmp 'gh -R o/engine pr merge 915 --squash'
  denied
  assert_output --partial 'agent-land 915 --repo o/engine'
  run at /tmp 'gh pr merge https://github.com/Kblack0610/personal-sites/pull/7 --squash'
  denied
  assert_output --partial 'agent-land 7 --repo Kblack0610/personal-sites'
  run at "$T/ps" "bash -lc 'gh pr merge --auto'"
  denied
  assert_output --partial 'agent-land <N> --item <slug>'
  # A flag's value is not the PR number.
  run at "$T/ps" 'gh pr merge --match-head-commit 1234567 --squash'
  denied
  assert_output --partial 'agent-land <N>'
  run at "$T/ps" 'gh pr merge --subject 5 12 --squash'
  denied
  assert_output --partial 'agent-land 12 --item'
  # A Forgejo checkout keeps its own message: open through forgejo-ops, land with agent-land.
  run at "$T/hc" 'gh pr merge 62'
  denied
  assert_output --partial 'forgejo-ops'
  assert_output --partial 'agent-land <N>'
  refute_output --partial 'ledger_coverage'
}

@test "a merge through a forge's PR API is denied naming agent-land, anywhere (ar-1213)" {
  # The forgejo-ops snippet sessions ran in home-config and bnb-game-servers, API set in an earlier call.
  run at /tmp 'curl -s -X POST -H "Authorization: token $TOKEN" -H "Content-Type: application/json" -d '"'"'{"Do":"squash"}'"'"' "$API/pulls/12/merge"'
  denied
  assert_output --partial 'agent-land 12 --item <slug>'
  assert_output --partial 'records the PR on no queue item'
  run at /tmp 'curl -sf -XPOST https://forge.example/api/v1/repos/o/r/pulls/7/merge --data-binary @m.json'
  denied
  assert_output --partial 'agent-land 7'
  run at /tmp 'curl -s -d @m.json "$API/pulls/<n>/merge"'
  denied
  assert_output --partial 'agent-land <N>'
  run at /tmp 'gh api -X PUT repos/o/r/pulls/3/merge -f merge_method=squash'
  denied
  assert_output --partial 'agent-land 3'
}

@test "reads of the merge endpoint and other PR API writes pass" {
  # A GET there asks whether the PR merged; opening a PR or commenting is not a merge.
  run at /tmp 'curl -s -H "Authorization: token $TOKEN" "$API/pulls/12/merge"; gh api repos/o/r/pulls/3/merge'
  allowed
  run at /tmp 'curl -s -X POST -d @pr.json "$API/pulls"; curl -s -X POST -d @c.json "$API/issues/12/comments"'
  allowed
  run at /tmp 'echo "curl -X POST \$API/pulls/12/merge"'
  allowed
}

@test "the rest of gh pr and text naming a merge pass" {
  run at "$T/ps" 'gh pr view 1; gh pr checks 1; gh pr list --state merged; gh pr edit 1 --body-file b.md'
  allowed
  run at "$T/ps" 'echo "gh pr merge 1"; rg -n "gh pr merge" .; git commit -m "gh pr merge was the bug"'
  allowed
}
