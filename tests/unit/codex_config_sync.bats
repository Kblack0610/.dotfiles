#!/usr/bin/env bats
# sync-ai-global-config.sh writes ~/.codex/config.toml: the keys in config.owned.toml at the head,
# the human's part as it was minus any copy of an owned key, then the rulesync MCP block without
# the keys Codex does not know. rulesync and the opencode mirror are stubs.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUBJECT="$PUB/.config/codex/sync-ai-global-config.sh"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" CODEX_HOME="$T/home/.codex" CLAUDE_HOME="$T/home/.claude"
  export GEMINI_HOME="$T/home/.gemini" OPENCODE_HOME="$T/home/.opencode"
  export RULESYNC_ROOT="$T/rulesync" DOTFILES_ROOT="$T/dotfiles" RULESYNC_BIN="$T/bin/rulesync"
  export CODEX_HOOKS_SRC="$T/hooks.json" RULES_CLAUDE_MD="$T/CLAUDE.md"
  mkdir -p "$CODEX_HOME" "$CLAUDE_HOME/skills" "$RULESYNC_ROOT/.rulesync/rules" "$DOTFILES_ROOT/.config/codex" "$T/bin"
  echo '# rules' > "$RULESYNC_ROOT/.rulesync/rules/overview.md"
  touch "$T/pre.sh"
  echo '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "bash '"$T"'/pre.sh"}]}]}}' > "$CODEX_HOOKS_SRC"
  printf '#!/bin/sh\nexit 0\n' > "$DOTFILES_ROOT/.config/codex/sync-opencode-claude-assets.sh"
  cat > "$RULESYNC_BIN" <<'SH'
#!/bin/sh
mkdir -p .codex
echo rules > AGENTS.md
echo '{}' > opencode.jsonc
cat > .codex/config.toml <<'T'
[mcp_servers.ctx]
description = "Docs"
type = "stdio"
command = "npx"

[mcp_servers.ctx.env]
type = "kept: inside env it is the server's own variable"
T
SH
  chmod +x "$RULESYNC_BIN" "$DOTFILES_ROOT/.config/codex/sync-opencode-claude-assets.sh"
}

@test "config: owned keys at the head replace the human's copies; their other keys and tables stay" {
  cat > "$CODEX_HOME/config.toml" <<'T'
personality = "pragmatic"
model = "gpt-5.6-sol"

[projects."/x"]
trust_level = "trusted"
model = "a table's own key, not the top-level one"
T
  run "$SUBJECT"
  assert_success
  run sed -n 1,4p "$CODEX_HOME/config.toml"
  assert_output "$(printf '%s\n' '# >>> dotfiles codex owned keys start >>>' 'model = "gpt-6.1-sol"' 'project_doc_fallback_filenames = ["CLAUDE.md"]' '# <<< dotfiles codex owned keys end <<<')"
  run grep -c '^model = "gpt-' "$CODEX_HOME/config.toml"
  assert_output 1
  run grep -n -e '^personality = "pragmatic"' -e "^model = \"a table's own key" "$CODEX_HOME/config.toml"
  assert_equal "${#lines[@]}" 2
}

@test "config: MCP servers lose type and description, a server's env keeps them; a second run changes nothing" {
  run "$SUBJECT"
  assert_success
  run grep -c -E '^(type|description) = ' "$CODEX_HOME/config.toml"
  assert_output 1
  assert grep -q '^type = "kept' "$CODEX_HOME/config.toml"
  cp "$CODEX_HOME/config.toml" "$T/first.toml"
  run "$SUBJECT"
  assert_success
  run diff "$T/first.toml" "$CODEX_HOME/config.toml"
  assert_success
}

@test "config: a human copy of an owned key spread over lines goes whole; an owned file with no keys keeps the human's" {
  cat > "$CODEX_HOME/config.toml" <<'T'
project_doc_fallback_filenames = [
  "NOTES.md",
]
personality = "pragmatic"
T
  run "$SUBJECT"
  assert_success
  run grep -c -e 'NOTES.md' -e '^]' "$CODEX_HOME/config.toml"
  assert_output 0
  run grep -c '^personality = "pragmatic"' "$CODEX_HOME/config.toml"
  assert_output 1
  # no owned keys: the sync still runs, and no key of the human's is taken for one
  printf '# nothing owned\n' > "$T/empty.toml"
  CODEX_OWNED_TOML="$T/empty.toml" run "$SUBJECT"
  assert_success
  run grep -c '^personality = "pragmatic"' "$CODEX_HOME/config.toml"
  assert_output 1
}
