#!/bin/bash
# Codex's half of the shared sync, run by sync-ai-global-config.sh (the one writer of CODEX_HOME):
# - skills: one link in CODEX_HOME/skills per Claude skill, so both read one corpus. A link this
#   sync made whose skill is gone is pruned; Codex's own .system dir and any real dir are left alone.
# - hooks: CODEX_HOME/hooks.json rendered from hooks.json here ($HOME filled in), and refused when
#   a command names a script that is not there, so a hook can never point at nothing.
# - rules: CODEX_HOME/rules/claude-deny.rules, a `forbidden` execpolicy rule for each Bash(...) entry
#   of Claude's permissions.deny, so a Codex run is refused what a Claude session is (fleet runs pass
#   --dangerously-bypass-approvals-and-sandbox, and forbidden rules still bind there). A regular file:
#   Codex skips a symlinked .rules file. Prefix rules match whole words, so `Bash(git push --force*)`
#   becomes `git push --force` exactly; an entry with a wildcard elsewhere, a pipe, a redirect or an
#   expansion (`curl * | sh`, `rm -rf ~`) cannot be a prefix rule and is named, not written; the
#   PreToolUse hook deny-list-guard.py applies those with Claude's glob meaning.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CODEX_HOOKS_SRC="${CODEX_HOOKS_SRC:-$SCRIPT_DIR/hooks.json}"
CODEX_BIN="${CODEX_BIN:-codex}"

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

# deny_rules <settings.json>: the execpolicy text for its Bash(...) denies. A glob glued to a word
# (`mkfs*`, `--force*`) can only be the exact word, so that rule is written plus a `# narrowed:` line;
# an entry that cannot be a prefix at all gets a `# skipped:` line and no rule.
deny_rules() {
    jq -r '
      def words: split(" ") | map(select(. != ""));
      [.permissions.deny[]? | select(startswith("Bash(") and endswith(")")) | .[5:-1] as $e
        | ($e | sub(" \\*$"; "")) as $t
        | ($t | test("[A-Za-z0-9_-]\\*$")) as $glued
        | (if $glued then $t | sub("\\*$"; "") else $t end) as $p
        | if ($p | test("[*|<>$~;&`\"\u0027()]")) or ($p | words | length) == 0 then {skip: $e}
          else {entry: $e, pattern: ($p | words), glued: $glued} end]
      | (map(select(.skip)) | .[] | "# skipped: Bash(\(.skip)) is not a whole-word prefix"),
        (map(select(.glued)) | .[] | "# narrowed: Bash(\(.entry)) is forbidden only as \(.pattern | join(" ")); a longer word passes"),
        (map(select(.pattern)) | unique_by(.pattern) | .[]
          | "prefix_rule(pattern=\(.pattern | tojson), decision=\"forbidden\", justification=\("Claude denies Bash(\(.entry)) in ~/.claude/settings.json" | tojson))")
    ' "$1"
}

render_rules() {
    local settings="$CLAUDE_HOME/settings.json" dst="$CODEX_HOME/rules/claude-deny.rules" body
    [ -f "$settings" ] || { echo "  Codex rules: no $settings, left as they are" >&2; return 0; }
    # One rules file that does not parse drops every rule Codex has, so none is written unchecked.
    command -v "$CODEX_BIN" >/dev/null 2>&1 || { echo "  Codex rules: no $CODEX_BIN to check them with, not written" >&2; return 0; }
    body=$(deny_rules "$settings") || { echo "Codex rules: $settings is not JSON; rules left as they are" >&2; return 1; }
    mkdir -p "$CODEX_HOME/rules"
    { echo "# Written by sync-codex-home.sh from $settings permissions.deny; edit that list, not this file."
      printf '%s\n' "$body"; } >"$dst.tmp"
    if ! "$CODEX_BIN" execpolicy check --rules "$dst.tmp" true >/dev/null 2>&1; then
        rm -f "$dst.tmp"; echo "Codex rules: $CODEX_BIN execpolicy rejects the rendered rules; $dst left as it is" >&2; return 1
    fi
    if cmp -s "$dst.tmp" "$dst"; then rm -f "$dst.tmp"; else mv "$dst.tmp" "$dst"; fi
    echo "  Codex rules: $dst ($(grep -c '^prefix_rule' "$dst" || true) forbidden, $(grep -c '^# narrowed' "$dst" || true) narrowed, $(grep -c '^# skipped' "$dst" || true) skipped; the # lines name the Claude denies Codex holds in part or not at all)"
}

link_skills
render_hooks
render_rules
