#!/usr/bin/env bats
# sync-codex-home.sh: Codex reads the Claude skill corpus through one link per skill, and its
# hooks.json is rendered from .config/codex/hooks.json, refused when a hook names a missing script,
# and Claude's Bash denies become Codex execpolicy `forbidden` rules.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUBJECT="$PUB/.config/codex/sync-codex-home.sh"
  export HOME="$BATS_TEST_TMPDIR/home" CODEX_HOME="$BATS_TEST_TMPDIR/home/.codex" CLAUDE_HOME="$BATS_TEST_TMPDIR/home/.claude"
  mkdir -p "$CLAUDE_HOME/skills" "$CODEX_HOME/skills/.system" "$HOME/hooks"
  for s in alpha beta; do mkdir -p "$CLAUDE_HOME/skills/$s"; printf -- '---\nname: %s\n---\n' "$s" > "$CLAUDE_HOME/skills/$s/SKILL.md"; done
  mkdir -p "$CLAUDE_HOME/skills/notaskill"
  touch "$HOME/hooks/pre.sh" "$HOME/hooks/guard.py"
  export CODEX_HOOKS_SRC="$BATS_TEST_TMPDIR/hooks.json"
  cat > "$CODEX_HOOKS_SRC" <<'J'
{"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "bash $HOME/hooks/pre.sh", "timeout": 30}]}],
           "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 $HOME/hooks/guard.py || true", "timeout": 10}]}]}}
J
}

@test "skills: one link per Claude skill; stale links this sync made are pruned, Codex's own and foreign ones stay" {
  ln -s "$PUB/.config/codex/skills/old-copy" "$CODEX_HOME/skills/old-copy"
  ln -s "$CLAUDE_HOME/skills/gone" "$CODEX_HOME/skills/gone"
  ln -s /elsewhere/theirs "$CODEX_HOME/skills/theirs"
  mkdir -p "$CODEX_HOME/skills/beta"   # a real dir is the human's: never linked over
  run "$SUBJECT"
  assert_success
  assert_line '  Codex skills: 1 linked from '"$CLAUDE_HOME"'/skills, 2 pruned'
  assert_equal "$(readlink "$CODEX_HOME/skills/alpha")" "$CLAUDE_HOME/skills/alpha"
  [ ! -L "$CODEX_HOME/skills/beta" ] && [ -d "$CODEX_HOME/skills/beta" ]
  [ ! -e "$CODEX_HOME/skills/notaskill" ]
  [ ! -L "$CODEX_HOME/skills/old-copy" ] && [ ! -L "$CODEX_HOME/skills/gone" ]
  [ -L "$CODEX_HOME/skills/theirs" ] && [ -d "$CODEX_HOME/skills/.system" ]
  run "$SUBJECT"
  assert_line '  Codex skills: 1 linked from '"$CLAUDE_HOME"'/skills, 0 pruned'
}

@test "hooks: rendered with HOME filled in, and every command's script exists" {
  run "$SUBJECT"
  assert_success
  run jq -r '.hooks[][].hooks[].command' "$CODEX_HOME/hooks.json"
  assert_output "$(printf 'bash %s/hooks/pre.sh\npython3 %s/hooks/guard.py || true' "$HOME" "$HOME")"
}

@test "hooks: a command naming a missing script fails and leaves the old hooks.json alone" {
  echo '{"old": true}' > "$CODEX_HOME/hooks.json"
  rm "$HOME/hooks/guard.py"
  run "$SUBJECT"
  assert_failure
  assert_output --partial "$HOME/hooks/guard.py"
  assert_equal "$(cat "$CODEX_HOME/hooks.json")" '{"old": true}'
}

@test "hooks: the real hooks.json names only scripts the repos ship, and no event Codex lacks" {
  run jq -r '.hooks | keys[]' "$PUB/.config/codex/hooks.json"
  assert_success
  for e in $output; do
    case "$e" in SessionStart|PreToolUse|PostToolUse|UserPromptSubmit|Stop|PreCompact|PostCompact|SessionEnd|PermissionRequest|SubagentStart|SubagentStop) ;; *) fail "unknown Codex hook event $e" ;; esac
  done
  run bash -c "jq -r '.hooks[][].hooks[].command' '$PUB/.config/codex/hooks.json' | grep -oE '\\\$HOME/[^ ]+\\.(sh|py)'"
  assert_success
  for p in $output; do
    rel=${p#\$HOME/}
    case "$rel" in
      .config/shared-hooks/*) [ -f "$PUB/$rel" ] || fail "missing $PUB/$rel" ;;
      .claude/hooks/*) [ -f "$PUB/$rel" ] || fail "missing $PUB/$rel" ;;
      *) fail "a hook outside the repo: $p" ;;
    esac
  done
}

@test "hooks: a Codex run gets the Claude shell guards and the Stop check that it closed its queue item" {
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$PUB/.config/codex/hooks.json"
  for g in block-pkill-f.sh forge-guard.py checkout-guard.py deny-list-guard.py block-pip.sh block-root-search.sh block-poll.py; do
    assert_output --partial "/.claude/hooks/$g"
  done
  run jq -r '.hooks.Stop[].hooks[].command' "$PUB/.config/codex/hooks.json"
  assert_output "$(printf '%s\n' 'bash $HOME/.claude/hooks/pre-stop-checks.sh --checks-only' 'bash $HOME/.claude/hooks/codex-item-stop.sh')"
}

# deny <entry>... -- a Claude settings.json whose permissions.deny holds these entries.
deny() {
  jq -n '{permissions: {deny: $ARGS.positional}}' --args "$@" > "$CLAUDE_HOME/settings.json"
}

# stub_codex <exit> -- a codex whose execpolicy check exits as told.
stub_codex() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit %s\n' "$1" > "$BATS_TEST_TMPDIR/bin/codex"; chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  export CODEX_BIN="$BATS_TEST_TMPDIR/bin/codex"
}

@test "rules: each whole-word Bash deny is one forbidden rule; a glued glob is narrowed, a pipe or an expansion skipped" {
  stub_codex 0
  deny 'Bash(git push --force*)' 'Bash(git push --force-with-lease*)' 'Bash(sudo *)' 'Bash(git push -f*)' \
       'Bash(curl * | sh)' 'Bash(rm -rf ~)' 'Bash(rm -rf /*)' 'Bash(mkfs.* *)' 'Read(./.env)' 'Bash(sudo:*)'
  run "$SUBJECT"
  assert_success
  assert_line --partial "  Codex rules: $CODEX_HOME/rules/claude-deny.rules (4 forbidden, 3 narrowed, 5 skipped;"
  f="$CODEX_HOME/rules/claude-deny.rules"
  [ -f "$f" ] && [ ! -L "$f" ]
  run grep '^prefix_rule' "$f"
  assert_line --partial 'pattern=["git","push","--force"], decision="forbidden"'
  assert_line --partial 'pattern=["git","push","--force-with-lease"]'
  assert_line --partial 'pattern=["git","push","-f"]'
  assert_line --partial 'pattern=["sudo"]'
  refute_output --partial 'Read('
  refute_output --partial '"/"'   # rm -rf /* is not rm -rf / exactly
  run grep '^# ' "$f"
  assert_line '# narrowed: Bash(git push --force*) is forbidden only as git push --force; a longer word passes'
  assert_line '# skipped: Bash(curl * | sh) is not a whole-word prefix'
  assert_line '# skipped: Bash(rm -rf ~) is not a whole-word prefix'
  assert_line '# skipped: Bash(rm -rf /*) is not a whole-word prefix'
  assert_line '# skipped: Bash(mkfs.* *) is not a whole-word prefix'
  refute_line --partial 'Bash(sudo *)'
}

@test "rules: with no codex to check them, no rules file is written" {
  export CODEX_BIN=/nonexistent/codex
  deny 'Bash(sudo *)'
  run "$SUBJECT"
  assert_success
  assert_output --partial 'no /nonexistent/codex to check them with, not written'
  [ ! -e "$CODEX_HOME/rules/claude-deny.rules" ]
}

@test "rules: a rendering codex execpolicy rejects leaves the old rules file in place" {
  mkdir -p "$CODEX_HOME/rules"
  echo '# old' > "$CODEX_HOME/rules/claude-deny.rules"
  stub_codex 1
  deny 'Bash(sudo *)'
  run "$SUBJECT"
  assert_failure
  assert_output --partial 'execpolicy rejects the rendered rules'
  assert_equal "$(cat "$CODEX_HOME/rules/claude-deny.rules")" '# old'
  [ ! -e "$CODEX_HOME/rules/claude-deny.rules.tmp" ]
  # a codex that accepts it puts the new file in place (negative control)
  stub_codex 0
  run "$SUBJECT"
  assert_success
  run grep -c '^prefix_rule' "$CODEX_HOME/rules/claude-deny.rules"
  assert_output 1
}

@test "rules: the real codex forbids the force push and lets a plain push through" {
  command -v codex >/dev/null || skip "no codex on PATH"
  deny 'Bash(git push --force*)' 'Bash(git push --force-with-lease*)' 'Bash(git reset --hard*)' 'Bash(sudo *)' 'Bash(mkfs*)'
  CODEX_BIN=codex run "$SUBJECT"
  assert_success
  f="$CODEX_HOME/rules/claude-deny.rules"
  run codex execpolicy check --rules "$f" git push --force-with-lease origin x
  assert_output --partial '"decision":"forbidden"'
  run codex execpolicy check --rules "$f" sudo ls
  assert_output --partial '"decision":"forbidden"'
  run codex execpolicy check --rules "$f" mkfs /dev/sda
  assert_output --partial '"decision":"forbidden"'
  run codex execpolicy check --rules "$f" git push origin x
  refute_output --partial 'forbidden'
}
