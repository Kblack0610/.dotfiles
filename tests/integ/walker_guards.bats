#!/usr/bin/env bats
# walker-guards.py: the Bash guards (forge, checkout, release, scratch-rm, gh-login, block-pip,
# block-poll) run in one process, each still refusing what it refused as its own hook. Each guard's
# own cases are in its <name>_guard.bats; this checks the dispatch. The repos, the gh dir and the
# cache are fixtures under the test dir; the other session is a real process holding a fixture id,
# killed in teardown.

ME=0b7e5a00-0000-4000-8000-00000000aaaa

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$BATS_TEST_DIRNAME/../.."
  HOOKS="$ROOT/.claude/hooks"
  T="$BATS_TEST_TMPDIR"
  g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
  g init -b main "$T/dots"
  g -C "$T/dots" commit --allow-empty -m init
  g init -b main "$T/game"
  g -C "$T/game" commit --allow-empty -m init
  export DOTFILES="$T/dots" DOTFILES_PRIVATE="$T/absent"
  export PROJECT_MAP_FILE="$T/map.json"
  printf '{"paths": {"%s": "game"}}' "$T/game" >"$PROJECT_MAP_FILE"
  export HOME="$T/home" XDG_CACHE_HOME="$T/cache"
  unset XDG_CONFIG_HOME GH_CONFIG_DIR
  mkdir -p "$HOME/.config/gh"
  echo 'github.com:' > "$HOME/.config/gh/hosts.yml"
  OTHER=0b7e5a00-0000-4000-8000-$(printf '%012x' "$BASHPID")
  mkdir -p "$XDG_CACHE_HOME/tool/$OTHER"
  # bash starts with the id in its environ, so the fifo read returning means the guard can see it.
  mkfifo "$T/ready"
  CLAUDE_CODE_SESSION_ID=$OTHER bash -c 'echo up > "$1"; exec sleep 100000' _ "$T/ready" 3>&- &
  LIVE=$!
  read -r _ < "$T/ready"
}

# KILL: a job of the parallel runner can inherit TERM as ignored.
teardown() { { kill -KILL "$LIVE"; wait "$LIVE"; } 2>/dev/null || true; }

at() { jq -nc --arg c "$2" --arg d "$1" --arg s "$ME" '{tool_name:"Bash", session_id:$s, cwd:$d, tool_input:{command:$c}}' | python3 "${WALKER:-$HOOKS/walker-guards.py}"; }

denied_by() { assert_success; assert_output --partial '"deny"'; assert_output --partial "$1:"; }

@test "Claude's settings.json and Codex's hooks.json run the one process on every Bash call, fail-open, and none of the seven" {
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("walker-guards|(forge|checkout|release|scratch-rm|gh-login|python-write)-guard|block-p(ip|oll)"))' "$ROOT/.claude/settings.json"
  assert_output 'python3 ~/.claude/hooks/walker-guards.py || true'
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("walker-guards|(forge|checkout|release|scratch-rm|gh-login|python-write)-guard|block-p(ip|oll)"))' "$ROOT/.config/codex/hooks.json"
  assert_output 'python3 $HOME/.claude/hooks/walker-guards.py || true'
}

@test "each of the seven guards still denies through the one process" {
  run at "$T/game" 'gh pr merge 12 --squash'
  denied_by forge-guard
  run at "$T/dots" 'git checkout -b feat/x'
  denied_by checkout-guard
  run at "$T/game" 'git tag v0.5.5'
  denied_by release-guard
  run at /tmp "rm -rf $XDG_CACHE_HOME/tool"
  denied_by scratch-rm-guard
  assert_output --partial "$OTHER"
  run at /tmp 'gh auth logout'
  denied_by gh-login-guard
  run at /tmp 'pip install x'
  denied_by block-pip
  run at /tmp 'until false; do sleep 5; done'
  denied_by block-poll
}

@test "a command two guards refuse names both in the one deny; a plain command passes with no output" {
  run at "$T/game" 'git tag v0.5.5 && gh auth logout'
  denied_by release-guard
  assert_output --partial 'gh-login-guard:'
  run at "$T/game" 'git status && ls'
  assert_success
  assert_output ''
}

@test "a guard that raises is skipped and the others still run (each fails open on its own)" {
  mkdir "$T/hooks"
  cp "$HOOKS"/*.py "$T/hooks/"
  printf 'def decide(data):\n    raise RuntimeError("broken")\n' > "$T/hooks/checkout-guard.py"
  WALKER="$T/hooks/walker-guards.py" run at "$T/dots" 'git checkout -b feat/x && gh auth logout'
  denied_by gh-login-guard
  refute_output --partial 'checkout-guard:'
  assert_output --partial 'walker-guards: checkout-guard skipped'
  [ "$(grep -c ' skipped, it raised' <<<"$output")" -eq 1 ]
}
