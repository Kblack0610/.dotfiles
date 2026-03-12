#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILLS_SOURCE_DIR="$DOTFILES_ROOT/.config/codex/skills"
SKILLS_TARGET_DIR="$CODEX_HOME/skills"

"$SCRIPT_DIR/sync-ai-global-config.sh"

mkdir -p "$SKILLS_TARGET_DIR"

for skill_dir in "$SKILLS_SOURCE_DIR"/*; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    target_path="$SKILLS_TARGET_DIR/$skill_name"
    rm -rf "$target_path"
    ln -s "$skill_dir" "$target_path"
done

echo "Synced Codex skills into $SKILLS_TARGET_DIR"
