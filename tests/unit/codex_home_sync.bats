#!/usr/bin/env bats
# sync-codex-home.sh: Codex reads the Claude skill corpus through one link per skill, and its
# hooks.json is rendered from .config/codex/hooks.json, refused when a hook names a missing script.

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
