#!/bin/bash
set -euo pipefail

DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SOURCE_CONFIG="$DOTFILES_ROOT/codex/config.managed.toml"
TARGET_CONFIG="$CODEX_HOME/config.toml"
SKILLS_SOURCE_DIR="$DOTFILES_ROOT/codex/skills"
SKILLS_TARGET_DIR="$CODEX_HOME/skills"
START_MARKER="# >>> dotfiles codex managed start >>>"
END_MARKER="# <<< dotfiles codex managed end <<<"

if [ ! -f "$SOURCE_CONFIG" ]; then
    echo "Missing managed Codex config: $SOURCE_CONFIG" >&2
    exit 1
fi

mkdir -p "$CODEX_HOME" "$SKILLS_TARGET_DIR"

tmp_config="$(mktemp)"
managed_tmp="$(mktemp)"
trap 'rm -f "$tmp_config" "$managed_tmp"' EXIT

{
    echo "$START_MARKER"
    cat "$SOURCE_CONFIG"
    echo "$END_MARKER"
} > "$managed_tmp"

if [ -f "$TARGET_CONFIG" ]; then
    awk -v start="$START_MARKER" -v end="$END_MARKER" '
        $0 == start {skip_managed=1; next}
        $0 == end {skip_managed=0; next}
        /^\[/ {skip_mcp=($0 ~ /^\[mcp_servers(\.|])/) ? 1 : 0}
        skip_managed != 1 && skip_mcp != 1 {print}
    ' "$TARGET_CONFIG" > "$tmp_config"
else
    : > "$tmp_config"
fi

features_tmp="$(mktemp)"
trap 'rm -f "$tmp_config" "$managed_tmp" "$features_tmp"' EXIT

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
' "$tmp_config" > "$features_tmp"
mv "$features_tmp" "$tmp_config"

if [ -s "$tmp_config" ]; then
    printf "\n" >> "$tmp_config"
fi
cat "$managed_tmp" >> "$tmp_config"
mv "$tmp_config" "$TARGET_CONFIG"

for skill_dir in "$SKILLS_SOURCE_DIR"/*; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    target_path="$SKILLS_TARGET_DIR/$skill_name"
    rm -rf "$target_path"
    ln -s "$skill_dir" "$target_path"
done

echo "Synced Codex config to $TARGET_CONFIG"
echo "Synced skills into $SKILLS_TARGET_DIR"
