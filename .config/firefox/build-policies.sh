#!/bin/bash
# Build the Firefox enterprise policy: the public policies.json deep-merged with the private
# policies.local.json, @HOME@ filled in, and @KARAKEEP_KEY@ (Tab Keeper's Karakeep key) read
# from rbw so no repo holds it. Writes OUT atomically, mode 0600, since it holds the key.
# Run by install.sh and by firefox-policies.service when either source changes.
# Usage: build-policies.sh OUT

set -euo pipefail

out="${1:?usage: build-policies.sh OUT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base="$SCRIPT_DIR/policies.json"
overlay="${DOTFILES_PRIVATE:-$HOME/.dotfiles-private}/.config/firefox/policies.local.json"
[[ -f "$overlay" ]] || overlay=""

key=""
if [[ -n "$overlay" ]] && grep -q '@KARAKEEP_KEY@' "$overlay"; then
    # Ask rbw only when it is unlocked: a locked rbw would raise pinentry from a background unit.
    if rbw unlocked >/dev/null 2>&1; then
        key=$(rbw get karakeep_api_key 2>/dev/null) || key=""
    fi
    # A locked rbw keeps the key the last build wrote, so a pull never drops it.
    if [[ -z "$key" && -f "$out" ]]; then
        key=$(jq -r --argjson ps "$(jq -c '[paths(. == "@KARAKEEP_KEY@")]' "$overlay")" \
            'first($ps[] as $p | getpath($p) // empty | select(type == "string" and . != "")) // ""' "$out")
    fi
    [[ -n "$key" ]] || echo "Warning: Tab Keeper gets no Karakeep key: rbw unlock, then rerun $0" >&2
fi

mkdir -p "$(dirname "$out")"
tmp=$(mktemp "$out.XXXXXX")
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
jq -s --arg home "$HOME" --arg key "$key" \
    '(if length > 1 then .[0] * (.[1] | del(._comment)) else .[0] end)
     | walk(if type == "string" then (if . == "@KARAKEEP_KEY@" then $key else gsub("@HOME@"; $home) end) else . end)' \
    "$base" ${overlay:+"$overlay"} >"$tmp"
mv "$tmp" "$out"
trap - EXIT
