#!/bin/bash
# Codex's half of the shared sync, run by sync-ai-global-config.sh (the one writer of CODEX_HOME):
# - skills: one link in CODEX_HOME/skills per Claude skill, so both read one corpus. A link this
#   sync made whose skill is gone is pruned; Codex's own .system dir and any real dir are left alone.
# - hooks: CODEX_HOME/hooks.json rendered from hooks.json here ($HOME filled in), and refused when
#   a command names a script that is not there, so a hook can never point at nothing.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CODEX_HOOKS_SRC="${CODEX_HOOKS_SRC:-$SCRIPT_DIR/hooks.json}"

link_skills() {
    local src="$CLAUDE_HOME/skills" dst="$CODEX_HOME/skills" s t target name linked=0 pruned=0
    [ -d "$src" ] || { echo "  Codex skills: no $src, left as they are" >&2; return 0; }
    mkdir -p "$dst"
    for t in "$dst"/*; do
        [ -L "$t" ] || continue
        target=$(readlink "$t"); name=$(basename "$t")
        case "$target" in
            "$src/$name") [ -e "$target" ] && continue ;;
            "$src"/* | */.config/codex/skills/*) ;;   # ours: a renamed skill, or the retired Codex copies
            *) continue ;;
        esac
        rm "$t"; pruned=$((pruned + 1))
    done
    for s in "$src"/*; do
        [ -f "$s/SKILL.md" ] || continue
        name=$(basename "$s"); t="$dst/$name"
        if [ -e "$t" ] && [ ! -L "$t" ]; then echo "  Codex skills: $t is a real directory, not linked over" >&2; continue; fi
        ln -sfn "$s" "$t"; linked=$((linked + 1))
    done
    echo "  Codex skills: $linked linked from $src, $pruned pruned"
}

render_hooks() {
    local out missing
    out=$(jq --arg h "$HOME" 'walk(if type == "string" then gsub("\\$HOME"; $h) else . end)' "$CODEX_HOOKS_SRC") ||
        { echo "Codex hooks: $CODEX_HOOKS_SRC is not JSON; hooks.json left as it is" >&2; return 1; }
    missing=$(jq -r '.hooks[][].hooks[].command' <<<"$out" | grep -oE '/[^ ]+\.(sh|py)' | while read -r p; do [ -f "$p" ] || echo "$p"; done)
    if [ -n "$missing" ]; then
        echo "Codex hooks: not written, these scripts are not there:" >&2
        printf '  %s\n' $missing >&2
        return 1
    fi
    mkdir -p "$CODEX_HOME"
    printf '%s\n' "$out" >"$CODEX_HOME/hooks.json.tmp" && mv "$CODEX_HOME/hooks.json.tmp" "$CODEX_HOME/hooks.json"
    echo "  Codex hooks: $CODEX_HOME/hooks.json ($(jq -r '.hooks | keys | join(", ")' <<<"$out"))"
}

link_skills
render_hooks
