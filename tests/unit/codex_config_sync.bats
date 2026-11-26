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

@test "opencode: the rulesync V1 mcp map lands as V2 mcp.servers, other keys stay; a 2.x stage passes through" {
  cat > "$RULESYNC_BIN" <<'SH'
#!/bin/sh
mkdir -p .codex
echo rules > AGENTS.md
echo '{"mcp": {"ctx": {"type": "local", "command": ["npx"], "enabled": true, "timeout": 9000}, "off": {"type": "remote", "url": "https://x", "enabled": false}}}' > opencode.jsonc
: > .codex/config.toml
SH
  mkdir -p "$OPENCODE_HOME"
  echo '{"model": "litellm/m", "mcp": {"servers": {"gone": {"type": "local", "command": ["x"]}}}}' > "$OPENCODE_HOME/opencode.json"
  run "$SUBJECT"
  assert_success
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["model"], json.dumps(d["mcp"], sort_keys=True))' "$OPENCODE_HOME/opencode.json"
  assert_output 'litellm/m {"servers": {"ctx": {"command": ["npx"], "disabled": false, "timeout": {"execution": 9000}, "type": "local"}, "off": {"disabled": true, "type": "remote", "url": "https://x"}}}'
  cat > "$RULESYNC_BIN" <<'SH'
#!/bin/sh
mkdir -p .codex
echo rules > AGENTS.md
echo '{"mcp": {"servers": {"ctx": {"type": "local", "command": ["npx"], "disabled": false}, "off": {"type": "remote", "url": "https://x"}}}}' > opencode.jsonc
: > .codex/config.toml
SH
  run "$SUBJECT"
  assert_success
  run python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["mcp"], sort_keys=True))' "$OPENCODE_HOME/opencode.json"
  assert_output '{"servers": {"ctx": {"command": ["npx"], "disabled": false, "type": "local"}, "off": {"type": "remote", "url": "https://x"}}}'
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

# OPENCODE_HOME itself is a stow symlink in the real deployment: it names a subdirectory
# of the private overlay's repo root, not the root itself. A check that mixes the resolved
# root with the unresolved symlink path (the bug this pins) only breaks on that mismatch,
# so the repo root here is deliberately a different, separately-named directory.
init_opencode_repo() {
  repo="$T/private-overlay"
  mkdir -p "$repo/.config/opencode" "$(dirname "$OPENCODE_HOME")"
  git -C "$repo" init -q
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
  printf '%s\n' "$1" > "$repo/.config/opencode/AGENTS.md"
  git -C "$repo" add .config/opencode/AGENTS.md
  git -C "$repo" commit -q -m base
  ln -s "$repo/.config/opencode" "$OPENCODE_HOME"
}

@test "opencode: a regenerated AGENTS.md that differs from the tracked copy warns and names the repo, but still syncs" {
  init_opencode_repo "old tracked rules"
  run "$SUBJECT"
  assert_success
  assert_output --partial "note: $OPENCODE_HOME/AGENTS.md changed and left $T/private-overlay dirty"
  assert_output --partial 'agent-land cannot otherwise'
  assert_equal "$(cat "$OPENCODE_HOME/AGENTS.md")" rules
  run git -C "$OPENCODE_HOME" status --porcelain -- AGENTS.md
  assert_output --partial 'M .config/opencode/AGENTS.md'
}

@test "opencode: a regenerated AGENTS.md that matches the tracked copy stays quiet" {
  init_opencode_repo "rules"
  run "$SUBJECT"
  assert_success
  refute_output --partial 'AGENTS.md changed'
  run git -C "$OPENCODE_HOME" status --porcelain -- AGENTS.md
  assert_output ""
}

@test "opencode: AGENTS.md outside any git repo (the common case) is never checked" {
  run "$SUBJECT"
  assert_success
  refute_output --partial 'AGENTS.md changed'
}

@test "agy: the rulesync source set lands in agy's own shape beside the human's servers; a dropped shared one goes" {
  cat > "$RULESYNC_ROOT/.rulesync/mcp.json" <<'J'
{"mcpServers": {
  "ctx": {"description": "Docs", "type": "stdio", "command": "npx", "args": ["-y", "c7"], "env": {}},
  "web": {"type": "http", "url": "https://x/mcp", "headers": {"A": "b"}},
  "old": {"type": "stdio", "command": "old-mcp"}}}
J
  mkdir -p "$GEMINI_HOME/config"
  echo '{"mcpServers": {"unityMCP": {"serverUrl": "http://localhost:8080/mcp", "disabled": false}}}' > "$GEMINI_HOME/config/mcp_config.json"
  run "$SUBJECT"
  assert_success
  run python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$GEMINI_HOME/config/mcp_config.json"
  assert_output '{"mcpServers": {"ctx": {"args": ["-y", "c7"], "command": "npx", "disabled": false}, "old": {"command": "old-mcp", "disabled": false}, "unityMCP": {"disabled": false, "serverUrl": "http://localhost:8080/mcp"}, "web": {"disabled": false, "headers": {"A": "b"}, "serverUrl": "https://x/mcp"}}}'
  python3 - "$RULESYNC_ROOT/.rulesync/mcp.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); del d["mcpServers"]["old"]; json.dump(d, open(sys.argv[1], "w"))
PY
  run "$SUBJECT"
  assert_success
  run python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["mcpServers"]))' "$GEMINI_HOME/config/mcp_config.json"
  assert_output "['ctx', 'unityMCP', 'web']"
}

@test "agy: with no rulesync mcp.json the live agy file is left as it was" {
  mkdir -p "$GEMINI_HOME/config"
  echo '{"mcpServers": {"mine": {"command": "x", "disabled": false}}}' > "$GEMINI_HOME/config/mcp_config.json"
  cp "$GEMINI_HOME/config/mcp_config.json" "$T/before.json"
  run "$SUBJECT"
  assert_success
  run diff "$T/before.json" "$GEMINI_HOME/config/mcp_config.json"
  assert_success
}

@test "agy: a shared server with no url or command is left out with a note; the rest of the sync still runs" {
  echo '{"mcpServers": {"odd": {"type": "sse"}, "ctx": {"command": "npx"}}}' > "$RULESYNC_ROOT/.rulesync/mcp.json"
  run "$SUBJECT"
  assert_success
  assert_output --partial "MCP server odd has no url or command"
  run python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["mcpServers"]))' "$GEMINI_HOME/config/mcp_config.json"
  assert_output "['ctx']"
  [ -f "$OPENCODE_HOME/opencode.json" ]
}

@test "agy: the shared rules land in its global rules dir as an always-on rule" {
  run "$SUBJECT"
  assert_success
  run cat "$GEMINI_HOME/config/rules/fleet.md"
  assert_output "$(printf -- '---\ntrigger: always_on\n---\n\nrules')"
}

@test "agy: skills.json declares the Claude skill corpus once and keeps the human's own entries" {
  mkdir -p "$GEMINI_HOME/config"
  echo '{"entries": [{"path": "~/mine"}], "inherits": [{"path": "/x.json"}]}' > "$GEMINI_HOME/config/skills.json"
  run "$SUBJECT"
  assert_success
  run "$SUBJECT"
  assert_success
  run jq -c . "$GEMINI_HOME/config/skills.json"
  assert_output '{"entries":[{"path":"~/mine"},{"path":"'"$CLAUDE_HOME"'/skills"}],"inherits":[{"path":"/x.json"}]}'
}

@test "agy: Claude's Bash denies land in its settings.json as command rules, with the credential files, and the human's keys and deny rules stay" {
  mkdir -p "$GEMINI_HOME/antigravity-cli"
  echo '{"trustedWorkspaces": ["/w"], "permissions": {"ask": ["command(x)"], "deny": ["command(mine)"]}}' > "$GEMINI_HOME/antigravity-cli/settings.json"
  echo '{"permissions": {"deny": ["Bash(sudo *)", "Bash(git push --force*)", "Bash(curl * | sh)", "Read(**/.env)"]}}' > "$CLAUDE_HOME/settings.json"
  run "$SUBJECT"
  assert_success
  run "$SUBJECT"
  assert_success
  run jq -c '[.trustedWorkspaces, .permissions.ask, (.permissions.deny | map(select(startswith("command("))))]' "$GEMINI_HOME/antigravity-cli/settings.json"
  assert_output '[["/w"],["command(x)"],["command(git push --force)","command(mine)","command(sudo)"]]'
  run jq -r '.permissions.deny[]' "$GEMINI_HOME/antigravity-cli/settings.json"
  assert_output --partial "write_file($HOME/.ssh)"
  refute_output --partial ".env"
}

@test "agy: a settings.json that is not JSON stays as it is and the sync still finishes" {
  mkdir -p "$GEMINI_HOME/antigravity-cli"
  echo 'not json' > "$GEMINI_HOME/antigravity-cli/settings.json"
  run "$SUBJECT"
  assert_success
  run cat "$GEMINI_HOME/antigravity-cli/settings.json"
  assert_output 'not json'
}
