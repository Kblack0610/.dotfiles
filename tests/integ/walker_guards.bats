#!/usr/bin/env bats
# walker-guards.py: the Bash guards (forge, checkout, release, scratch-rm, gh-login, shared-state,
# block-pip, block-poll, python-write-guard, skip) run in one process, each still refusing what it refused as its own hook. Each guard's
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

@test "Claude's settings.json and Codex's hooks.json run the one process on every Bash call, fail-open, and none of the nine" {
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("walker-guards|(forge|checkout|release|scratch-rm|gh-login|shared-state|python-write|skip)-guard|block-p(ip|oll)"))' "$ROOT/.claude/settings.json"
  assert_output 'python3 ~/.claude/hooks/walker-guards.py || true'
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("walker-guards|(forge|checkout|release|scratch-rm|gh-login|shared-state|python-write|skip)-guard|block-p(ip|oll)"))' "$ROOT/.config/codex/hooks.json"
  assert_output 'python3 $HOME/.claude/hooks/walker-guards.py || true'
}

@test "each of the nine guards still denies through the one process" {
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
  run at "$T/game" 'git stash pop'
  denied_by shared-state-guard
  run at /tmp 'pip install x'
  denied_by block-pip
  run at /tmp 'until false; do sleep 5; done'
  denied_by block-poll
  run at /tmp "python3 -c 'open(\"/w/CLAUDE.md\", \"w\").write(\"x\")'"
  denied_by python-write-guard
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
  # The copy keeps a checkout's layout: skip-guard reads its label from .local/bin/gate-guard beside the hooks.
  mkdir -p "$T/co/.claude/hooks" "$T/co/.local/bin"
  cp "$HOOKS"/*.py "$T/co/.claude/hooks/"
  cp "$ROOT/.local/bin/gate-guard" "$T/co/.local/bin/"
  printf 'def decide(data):\n    raise RuntimeError("broken")\n' > "$T/co/.claude/hooks/checkout-guard.py"
  WALKER="$T/co/.claude/hooks/walker-guards.py" run at "$T/dots" 'git checkout -b feat/x && gh auth logout'
  denied_by gh-login-guard
  refute_output --partial 'checkout-guard:'
  assert_output --partial 'walker-guards: checkout-guard skipped'
  [ "$(grep -c ' skipped, it raised' <<<"$output")" -eq 1 ]
}

@test "run through a stow link with no hooklib.py beside it, the guards import hooklib from the checkout" {
  # ~/.claude/hooks holds one link per file, so a new hooklib.py is not linked there until stow runs
  # again; Python puts the link's target dir on sys.path, which is where the import finds it.
  mkdir "$T/linked"
  ln -s "$(realpath "$HOOKS/walker-guards.py")" "$T/linked/walker-guards.py"
  WALKER="$T/linked/walker-guards.py" run at "$T/dots" 'gh auth logout'
  denied_by gh-login-guard
}

@test "with hooklib.py missing altogether the guards fail open: no deny, a non-blocking exit (negative control)" {
  mkdir "$T/nolib"
  cp "$HOOKS"/*.py "$T/nolib/"
  rm "$T/nolib/hooklib.py"
  WALKER="$T/nolib/walker-guards.py" run at "$T/dots" 'gh auth logout'
  assert_failure 1
  refute_output --partial '"deny"'
}
