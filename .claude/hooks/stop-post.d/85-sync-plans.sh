#!/bin/bash
# Stop-post: sync the plans THIS session wrote from ~/.claude/plans/ into
# ~/.agent/plans/{project}/ so the next session's preflight injects them.
#
# ~/.claude/plans/ is FLAT, GLOBAL and PROJECT-LESS -- a plan's filename encodes
# nothing about which project it belongs to. The previous implementation selected
# on mtime alone (`find -mtime -1`) and copied every recently-touched plan into
# whatever project the current session happened to be in, so working in three
# projects in one day broadcast each plan into all three.
#
# Measured 2026-08-09, before this change: 456 of 514 distinct plan names existed
# in 2+ project dirs and one sat in 7 unrelated ones -- 2,272 redundant copies.
# The blast radius was not disk: session-preflight.sh lists plans at turn 1,
# regen-anchor.sh lists them again in the anchor, and regen-lab-feed.sh links the
# directory into the human-facing lab feed, so every session opened by advertising
# other projects' plans as its own.
#
# Attribution now needs THREE signals to agree, because no single one is sound:
#   1. mtime      -- the plan was touched recently (the old, insufficient, test)
#   2. transcript -- THIS session's transcript names it, so this session saw it
#   3. ownership  -- no other project dir already holds that basename
# (2) alone over-attributes: a transcript also names plans the session merely READ,
# and reading another project's plan is common. (3) is first-writer-wins, and is
# what actually bounds the fan-out to one copy.
#
# Idempotent. Never blocks; always exits 0.

set -uo pipefail

SRC_DIR="$HOME/.claude/plans"
PLANS_ROOT="$HOME/.agent/plans"
[ -d "$SRC_DIR" ] || exit 0

# --- stdin payload: the transcript is the attribution key ---
STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
[ -n "$STDIN_JSON" ] || exit 0
[ "$(echo "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0

TRANSCRIPT=$(echo "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)
# No transcript means no attribution, so copy NOTHING. A broadcast is precisely the
# failure being removed here, and a missed sync self-heals on the next Stop.
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# --- project ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
# Guarded source: under stow --no-folding this hook can run from a commit that
# lands before the symlink does, and an unguarded source would leave
# resolve_project_name undefined rather than fall back.
if [ -r "$HOME/.config/shared-hooks/project-name.sh" ]; then
  . "$HOME/.config/shared-hooks/project-name.sh"
fi
if declare -F resolve_project_name >/dev/null 2>&1; then
  PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")
else
  PROJECT_NAME=$(basename "$PROJECT_DIR")
  PROJECT_NAME=${PROJECT_NAME#.}
fi
[ -n "$PROJECT_NAME" ] || exit 0

DEST_DIR="$PLANS_ROOT/$PROJECT_NAME"
mkdir -p "$DEST_DIR" 2>/dev/null || exit 0

while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue

  # (2) this session actually touched it. Fixed-string match on the absolute
  # path, so a $HOME containing regex metacharacters cannot change the meaning.
  grep -qF -- "$f" "$TRANSCRIPT" 2>/dev/null || continue

  # (3) first writer wins. A basename already held by ANOTHER project stays
  # there; copying it here is exactly the cross-project fan-out being removed.
  # -print -quit stops at the first hit, so this stays cheap over a large tree.
  base=${f##*/}
  owned_elsewhere=$(find "$PLANS_ROOT" -mindepth 2 -type f -name "$base" \
    -not -path "$DEST_DIR/*" -print -quit 2>/dev/null)
  [ -n "$owned_elsewhere" ] && continue

  cp -p "$f" "$DEST_DIR/" 2>/dev/null || true
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.md' -mtime -1 2>/dev/null)

exit 0
