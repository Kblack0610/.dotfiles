#!/usr/bin/env bats
# .local/lib/test-pick.sh: which fast-tier test files a change can affect. tests/pick.sh (the PR
# gate) and fleet-bench's hold check both read it, so a miss here is a test that skips and a red
# that reaches main.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "picker: a script change picks the tests that name it, and only those" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  run test_picked .local/bin/fleet-bench tests/unit/fleet_bench.bats <"$REPO_ROOT/tests/unit/fleet_bench.bats"
  assert_success
  run test_picked .local/bin/fleet-bench tests/unit/theme_generated.bats <"$REPO_ROOT/tests/unit/theme_generated.bats"
  assert_failure
}

# A test that globs a directory names no file in it: stop_hook_quiet.bats greps
# .claude/hooks/stop-post.d/*.sh and never names 80-session-register.sh. test-pick.sh reads
# `<dir>/` and `<dir>/*` as a reference to every file under <dir>.
@test "picker: a change under a directory picks the test that globs that directory" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  run test_picked .claude/hooks/stop-post.d/80-session-register.sh tests/integ/stop_hook_quiet.bats <"$REPO_ROOT/tests/integ/stop_hook_quiet.bats"
  assert_success
}

@test "picker: a path through a directory is not a reference to the whole directory" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  run test_picked .claude/hooks/stop-post.d/other.sh tests/x.bats <<<'cp "$R/.claude/hooks/stop-post.d/95-wind-down.sh" .'
  assert_failure
  run test_picked .claude/hooks/stop-post.d/other.sh tests/x.bats <<<'cp "$R/.claude/hooks/stop-post.d/" .'
  assert_success
  run test_picked docs/x.md tests/x.bats <<<'globs: ["*/.local/src/docs/*"]'
  assert_failure
  run test_picked .claude/hooks/stop-post.d/other.sh tests/x.bats <<<'ls .claude/hooks/stop-postXd/*'
  assert_failure
  local root
  for root in '${R}/' '~/' '$BATS_TEST_DIRNAME/../../' '$(git rev-parse --show-toplevel)/' './'; do
    run test_picked .claude/hooks/stop-post.d/other.sh tests/x.bats <<<"for f in $root.claude/hooks/stop-post.d/*; do"
    assert_success
  done
  run test_picked README.md tests/x.bats <<<'ls "$R"/ ./'
  assert_failure
}

@test "picker: a name a test only stubs, mentions in prose, or uses as a directory does not pick it" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  local t
  for t in '  stub agentctl "exit 0"' '# the agentctl conf' '@test "agentctl says no" {' \
    'mkdir -p "$HOME/.config/agentctl/"' 'systemctl --user start agentctl@inbox.service'; do
    run test_picked .local/bin/agentctl tests/x.bats <<<"$t"
    assert_failure
  done
  # A trailing comment and a path in another directory (ar-3036): fleet_dispatch/common.bash had
  # both for fleet-bench, which picked all ten fleet_dispatch*.bats files for a fleet-bench change.
  for t in '  export X=0   # so no pass asks agentctl' 'mkdir -p "$HOME/.config/agentctl"' \
    'cat "$SANDBOX/state/agentctl" "x/agentctl"' 'run /opt/tool/agentctl'; do
    run test_picked .local/bin/agentctl tests/x.bats <<<"$t"
    assert_failure
  done
  # The same name run for real still picks it (negative controls): after a code `#` that starts
  # no word, by a path in its own directory or through a variable, before a trailing comment, and
  # after a ` #` inside quotes.
  for t in '  stub fleet-bench "exit 0"; run agentctl list' '  [ $# -gt 0 ] && agentctl list' \
    'run "$REPO_ROOT/.local/bin/agentctl" list' 'run "$BIN/agentctl"' 'run ${BIN}/agentctl' \
    'run ./agentctl' '  agentctl list   # the real one' \
    '  printf "%s\n" "issue #12" | agentctl add' "  echo 'a #1'; agentctl list"; do
    run test_picked .local/bin/agentctl tests/x.bats <<<"$t"
    assert_success
  done
  # A file changed at the repo root sits in no directory, so `<dir>/<name>` is another file.
  run test_picked rootcmd tests/x.bats <<<'bash scripts/rootcmd'
  assert_failure
  run test_picked rootcmd tests/x.bats <<<'bash "$REPO_ROOT/rootcmd"'
  assert_success
  # The real file: a fleet-bench change leaves fleet_dispatch_reap.bats out, which only loads
  # common.bash and so names fleet-bench in a stub, a comment and a config directory.
  run test_picked .local/bin/fleet-bench tests/unit/fleet_dispatch_reap.bats <"$REPO_ROOT/tests/unit/fleet_dispatch_reap.bats"
  assert_failure
  # The real files: an agentctl change leaves the fleet_dispatch*.bats files out; a fleet-dispatch
  # change, sourced only in the fleet_dispatch/common.bash they load, picks every one.
  local f n=0
  for f in "$REPO_ROOT"/tests/unit/fleet_dispatch*.bats; do
    n=$((n + 1))
    run test_picked .local/bin/agentctl "tests/unit/${f##*/}" <"$f"
    assert_failure
    run test_picked .local/bin/fleet-dispatch "tests/unit/${f##*/}" <"$f"
    assert_success
    run test_picked tests/unit/fleet_dispatch/common.bash "tests/unit/${f##*/}" <"$f"
    assert_success
    run test_picked tests/helpers/sandbox.bash "tests/unit/${f##*/}" <"$f"
    assert_success
  done
  [ "$n" -gt 1 ]
}

@test "picker: a stub's body naming its own fake does not pick the test; another name in it does (ar-3036)" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  run test_picked .local/bin/store-sync tests/x.bats <<<"  stub store-sync 'echo \"store-sync \$*\" >> \"\$NOTES_FIXTURE/calls.log\"'"
  assert_failure
  # Negative controls: the fake runs the real command, a longer name only contains it, and a
  # later line runs it.
  run test_picked .local/bin/store-sync tests/x.bats <<<"  stub fleet-bench 'exec store-sync \"\$@\"'"
  assert_success
  run test_picked .local/bin/store-sync tests/x.bats <<<"  stub store-sync-age 'echo store-sync'"
  assert_success
  run test_picked .local/bin/store-sync tests/x.bats <<<$'  stub store-sync \'exit 0\'\n  run store-sync join'
  assert_success
  run test_picked .local/bin/store-sync tests/x.bats <<<"  stub store-sync 'exit 0'; run store-sync join"
  assert_success
  # A passthrough fake runs the real script by path, so it is a use.
  run test_picked .local/bin/agent-hold tests/x.bats <<<'  stub agent-hold "exec \"$REPO_ROOT/.local/bin/agent-hold\" \"\$@\""'
  assert_success
  # The real file: fleet_dispatch.bats only fakes store-sync (fleet_dispatch/common.bash).
  run test_picked .local/bin/store-sync tests/unit/fleet_dispatch.bats <"$REPO_ROOT/tests/unit/fleet_dispatch.bats"
  assert_failure
}

@test "picker: a fixture change picks the tests that name its entry, not the whole tier; basic is the harness (ar-3036)" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  local ch=tests/fixtures/comms/lab-status/fail/new.txt t
  for t in 'for f in "$REPO_ROOT"/tests/fixtures/comms/*/*/*; do' 'ls "$REPO_ROOT/tests/fixtures/comms"' \
    'cp "$BATS_TEST_DIRNAME/../fixtures/comms/x" .' '  sandbox_init comms'; do
    run test_picked "$ch" tests/x.bats <<<"$t"
    assert_success
  done
  # Negative controls: a longer entry name and a test that names no fixture.
  for t in 'ls "$REPO_ROOT/tests/fixtures/comms-old"' '  sandbox_init basic; run comms-lint'; do
    run test_picked "$ch" tests/x.bats <<<"$t"
    assert_failure
  done
  # sandbox_init seeds every sandbox from basic by default, so it still picks every file.
  run test_picked tests/fixtures/basic/notes.md tests/x.bats <<<'run true'
  assert_success
  # The real files, through tests/pick.sh: comms_lint.bats in, fleet_dispatch.bats out, and no full run.
  run env PICK_CHANGED="$ch" "$REPO_ROOT/tests/pick.sh" unit HEAD
  assert_success
  assert_line unit/comms_lint.bats
  refute_line unit/fleet_dispatch.bats
  refute_output --partial 'full:'
}

@test "picker: a shared basename named as the tail of another tracked file's path does not pick it (ar-3036)" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  local ch=.local/src/hub-core/src/projects.rs t
  [ -f "$REPO_ROOT/.local/src/notes-cli/src/projects.rs" ]
  [ -f "$REPO_ROOT/$ch" ]
  run test_picked "$ch" tests/x.bats <<<'sed -n p "$REPO_ROOT/.local/src/notes-cli/src/projects.rs"'
  assert_failure
  # Negative controls: the changed file's own path, a path the picker cannot place, and a bare
  # parent/name all still pick it.
  for t in 'cat "$REPO_ROOT/.local/src/hub-core/src/projects.rs"' 'cat "$CRATE/src/projects.rs"' 'cat src/projects.rs'; do
    run test_picked "$ch" tests/x.bats <<<"$t"
    assert_success
  done
  run test_picked "$ch" tests/unit/fleet_dispatch.bats <"$REPO_ROOT/tests/unit/fleet_dispatch.bats"
  assert_failure
  run test_picked .local/src/notes-cli/src/projects.rs tests/unit/fleet_dispatch.bats <"$REPO_ROOT/tests/unit/fleet_dispatch.bats"
  assert_success
}

@test "picker: a file a test loads picks it, with or without .bash, and so does a file that one loads" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  _TEST_PICK_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$_TEST_PICK_REPO/tests/unit/lib"
  printf "load 'lib/inner'\n" > "$_TEST_PICK_REPO/tests/unit/lib/outer.bash"
  printf "load 'lib/outer'\n" > "$_TEST_PICK_REPO/tests/unit/lib/inner.bash"   # a cycle ends
  printf 'run fleet-dispatch\n' > "$_TEST_PICK_REPO/tests/unit/lib/plain"
  local t
  for t in "load 'lib/outer'" "load 'lib/outer.bash'" 'load lib/outer'; do
    run test_picked tests/unit/lib/inner.bash tests/unit/x.bats <<<"$t"
    assert_success
  done
  run test_picked tests/unit/lib/plain tests/unit/x.bats <<<"load 'lib/plain'"
  assert_success
  run test_picked .local/bin/fleet-dispatch tests/unit/x.bats <<<"load 'lib/plain'"
  assert_success
  # Negative controls: a file the test does not load, and a load of another directory's file.
  run test_picked tests/unit/lib/inner.bash tests/unit/x.bats <<<"load 'lib/plain'"
  assert_failure
  run test_picked tests/unit/lib/inner.bash tests/integ/x.bats <<<"load 'lib/outer'"
  assert_failure
}

@test "picker: a basename many files share counts only with its parent directory" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  run test_picked .claude/skills/sentinel/SKILL.md tests/x.bats <<<'grep -c x "$R/.claude/skills/ci-cost/SKILL.md"'
  assert_failure
  run test_picked .claude/skills/sentinel/SKILL.md tests/x.bats <<<'grep -c x "$R/.claude/skills/sentinel/SKILL.md"'
  assert_success
}

# Two misses main paid for (ar-4309): questions_panel.bats runs agent-ask only as "$AGENT_ASK",
# which sandbox.bash defines, and worktree_create_hook.bats runs worktree-remove.sh, which runs
# worktree.sh by path. #2385 and #2127 changed those scripts, were not picked, and went red on main.
@test "picker: a script a shared helper names is named where the test uses its variable" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  run test_picked .local/bin/agent-ask tests/x.bats <<<'run "$AGENT_ASK" list'
  assert_success
  run test_picked .local/bin/agent-ask tests/x.bats <<<'run "${AGENT_ASK}" list'
  assert_success
  # Negative controls: the variable in a comment, and a longer name it only starts.
  run test_picked .local/bin/agent-ask tests/x.bats <<<'# "$AGENT_ASK" is the real one'
  assert_failure
  run test_picked .local/bin/agent-ask tests/x.bats <<<'run "$AGENT_ASK_ROOT" list'
  assert_failure
  run test_picked .local/bin/agent-ask tests/integ/questions_panel.bats <"$REPO_ROOT/tests/integ/questions_panel.bats"
  assert_success
}

@test "picker: a script the test runs by path is read one level down for the repo paths it names" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  # A fixture repo, so the controls do not ride on what a live hook happens to say.
  local repo="$BATS_TEST_TMPDIR/repo" hook='bash "$REPO_ROOT/hooks/remove.sh"'
  mkdir -p "$repo/hooks"
  cat >"$repo/hooks/remove.sh" <<'EOF'
# .local/src/tmux/fleet.sh is only named in a comment
jq -r . "$1"
wt list
"$(dirname "$0")/../.local/src/tmux/worktree.sh" remove "$1"
EOF
  _TEST_PICK_REPO=$repo run test_picked .local/src/tmux/worktree.sh tests/x.bats <<<"$hook"
  assert_success
  # Negative controls: a path only its comments name, and commands it runs by bare name.
  _TEST_PICK_REPO=$repo run test_picked .local/src/tmux/fleet.sh tests/x.bats <<<"$hook"
  assert_failure
  _TEST_PICK_REPO=$repo run test_picked .local/bin/jq tests/x.bats <<<"$hook"
  assert_failure
  _TEST_PICK_REPO=$repo run test_picked .local/bin/wt tests/x.bats <<<"$hook"
  assert_failure
  # The real chain #2127 broke: worktree_create_hook.bats -> worktree-remove.sh -> worktree.sh.
  run test_picked .local/src/tmux/worktree.sh tests/integ/worktree_create_hook.bats <"$REPO_ROOT/tests/integ/worktree_create_hook.bats"
  assert_success
}

@test "picker: a changed test file picks itself" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  run test_picked tests/unit/test_pick.bats tests/unit/test_pick.bats <"$BATS_TEST_FILENAME"
  assert_success
}

@test "picker: a change no test names picks nothing" {
  . "$REPO_ROOT/.local/lib/test-pick.sh"
  # Built at runtime: written out literally, this file would name it and pick itself.
  run test_picked "docs/$(printf 'unnamed%s' -doc).md" tests/unit/test_pick.bats <"$BATS_TEST_FILENAME"
  assert_failure
}
