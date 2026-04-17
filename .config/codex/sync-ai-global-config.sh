#!/bin/bash
set -euo pipefail

DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"
RULESYNC_ROOT="$DOTFILES_ROOT/.config/rulesync-global"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
GEMINI_HOME="${GEMINI_HOME:-$HOME/.gemini}"
OPENCODE_HOME="${OPENCODE_HOME:-$HOME/.config/opencode}"
RULESYNC_BIN="${RULESYNC_BIN:-}"

START_MARKER="# >>> dotfiles codex managed start >>>"
END_MARKER="# <<< dotfiles codex managed end <<<"

find_rulesync() {
    if [ -n "$RULESYNC_BIN" ] && [ -x "$RULESYNC_BIN" ]; then
        printf '%s\n' "$RULESYNC_BIN"
        return 0
    fi

    if command -v rulesync >/dev/null 2>&1; then
        command -v rulesync
        return 0
    fi

    if [ -x "$HOME/.rulesync/bin/rulesync" ]; then
        printf '%s\n' "$HOME/.rulesync/bin/rulesync"
        return 0
    fi

    return 1
}

RULESYNC="$(find_rulesync || true)"
if [ -z "$RULESYNC" ]; then
    echo "rulesync is required. Install it first:" >&2
    echo "  curl -fsSL https://github.com/dyoshikawa/rulesync/releases/latest/download/install.sh | bash" >&2
    exit 1
fi

if [ ! -d "$RULESYNC_ROOT" ]; then
    echo "Missing Rulesync source directory: $RULESYNC_ROOT" >&2
    exit 1
fi

stage_dir="$(mktemp -d)"
codex_tmp="$(mktemp)"
managed_tmp="$(mktemp)"
features_tmp="$(mktemp)"
trap 'rm -rf "$stage_dir"; rm -f "$codex_tmp" "$managed_tmp" "$features_tmp"' EXIT

cp -R "$RULESYNC_ROOT"/. "$stage_dir"/

(
    cd "$stage_dir"
    "$RULESYNC" generate --targets codexcli,geminicli,opencode --features rules,mcp >/dev/null
)

for required_file in \
    "$stage_dir/AGENTS.md" \
    "$stage_dir/GEMINI.md" \
    "$stage_dir/.codex/config.toml" \
    "$stage_dir/.gemini/settings.json" \
    "$stage_dir/opencode.jsonc"; do
    if [ ! -f "$required_file" ]; then
        echo "Missing expected Rulesync output: $required_file" >&2
        exit 1
    fi
done

mkdir -p "$CODEX_HOME" "$GEMINI_HOME" "$OPENCODE_HOME"

# Claude Code's CLAUDE.md and .mcp.json are stow-managed from ~/.dotfiles/.claude/
# — do NOT write them here; it would clobber the stow symlinks.
cp "$stage_dir/AGENTS.md" "$CODEX_HOME/AGENTS.md"
cp "$stage_dir/GEMINI.md" "$GEMINI_HOME/GEMINI.md"
cp "$stage_dir/AGENTS.md" "$OPENCODE_HOME/AGENTS.md"

{
    echo "$START_MARKER"
    cat "$stage_dir/.codex/config.toml"
    echo "$END_MARKER"
} > "$managed_tmp"

if [ -f "$CODEX_HOME/config.toml" ]; then
    awk -v start="$START_MARKER" -v end="$END_MARKER" '
        $0 == start {skip_managed=1; next}
        $0 == end {skip_managed=0; next}
        /^\[/ {skip_mcp=($0 ~ /^\[mcp_servers(\.|])/) ? 1 : 0}
        skip_managed != 1 && skip_mcp != 1 {print}
    ' "$CODEX_HOME/config.toml" > "$codex_tmp"
else
    : > "$codex_tmp"
fi

awk '
    BEGIN { in_features=0; saw_features=0; saw_rmcp=0 }
    /^\[/ {
        if (in_features && !saw_rmcp) {
            print "rmcp_client = true"
            saw_rmcp = 1
        }
        in_features = ($0 == "[features]")
        if (in_features) {
            saw_features = 1
        }
        print
        next
    }
    {
        if (in_features && $0 ~ /^rmcp_client[[:space:]]*=/) {
            saw_rmcp = 1
        }
        print
    }
    END {
        if (in_features && !saw_rmcp) {
            print "rmcp_client = true"
        }
        if (!saw_features) {
            print ""
            print "[features]"
            print "rmcp_client = true"
        }
    }
' "$codex_tmp" > "$features_tmp"
mv "$features_tmp" "$codex_tmp"

awk '
    BEGIN { last_nonblank = 0 }
    {
        lines[NR] = $0
        if ($0 !~ /^[[:space:]]*$/) {
            last_nonblank = NR
        }
    }
    END {
        for (i = 1; i <= last_nonblank; i++) {
            print lines[i]
        }
    }
' "$codex_tmp" > "$features_tmp"
mv "$features_tmp" "$codex_tmp"

if [ -s "$codex_tmp" ]; then
    printf "\n" >> "$codex_tmp"
fi
cat "$managed_tmp" >> "$codex_tmp"
mv "$codex_tmp" "$CODEX_HOME/config.toml"

export GEMINI_SETTINGS_PATH="$GEMINI_HOME/settings.json"
export GEMINI_STAGE_PATH="$stage_dir/.gemini/settings.json"
export OPENCODE_CONFIG_PATH="$OPENCODE_HOME/opencode.json"
export OPENCODE_STAGE_PATH="$stage_dir/opencode.jsonc"

python3 <<'PY'
import json
import os
from pathlib import Path


def read_json(path_str: str) -> dict:
    path = Path(path_str)
    if not path.exists():
        return {}
    text = path.read_text().strip()
    if not text:
        return {}
    return json.loads(text)


def write_json(path_str: str, data: dict) -> None:
    path = Path(path_str)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


gemini_path = os.environ["GEMINI_SETTINGS_PATH"]
gemini_stage_path = os.environ["GEMINI_STAGE_PATH"]
gemini_current = read_json(gemini_path)
gemini_stage = read_json(gemini_stage_path)
gemini_current["mcpServers"] = gemini_stage.get("mcpServers", {})
write_json(gemini_path, gemini_current)

opencode_path = os.environ["OPENCODE_CONFIG_PATH"]
opencode_stage_path = os.environ["OPENCODE_STAGE_PATH"]
opencode_current = read_json(opencode_path)
opencode_stage = read_json(opencode_stage_path)
current_mcp = opencode_current.get("mcp", {})
shared_mcp = opencode_stage.get("mcp", {})

for key, value in shared_mcp.items():
    current_mcp[key] = value

opencode_current["mcp"] = current_mcp
write_json(opencode_path, opencode_current)
PY

echo "Synced shared AI rules and MCP config (Claude owned by stow, not this script)"
echo "  Codex:  $CODEX_HOME/AGENTS.md and $CODEX_HOME/config.toml"
echo "  Gemini: $GEMINI_HOME/GEMINI.md and $GEMINI_HOME/settings.json"
echo "  OpenCode: $OPENCODE_HOME/AGENTS.md and $OPENCODE_HOME/opencode.json"
