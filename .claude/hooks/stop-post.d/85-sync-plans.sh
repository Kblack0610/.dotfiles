#!/bin/bash
# Stop-post: link the plans THIS session wrote into ~/.agent/plans/{project}/, so the
# next session's preflight injects them. The plan itself lives once, in
# ~/.agent/plans/_live/ (store-sync versions it and carries it to peers); ~/.claude/plans
# is a link to that dir (claude-acct plans_store), and each project entry is a relative
# link ../_live/<name>, which resolves on every peer.
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
#   2. transcript -- THIS session's transcript names it (absolute or `~/` path), so it saw it
#   3. ownership  -- no other project dir already holds that basename
# (2) alone over-attributes: a transcript also names plans the session merely READ,
# and reading another project's plan is common. (3) is first-writer-wins, and is
# what actually bounds the fan-out to one link.
#
# Idempotent. Never blocks; always exits 0. A machine whose ~/.claude/plans is not linked to
# _live yet (store-sync has not brought it) links nothing until claude-acct links it.

set -uo pipefail

PLANS_ROOT="$HOME/.agent/plans"
SRC_DIR="$PLANS_ROOT/_live"
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

# plan_epic_dir <plan> -> $PLANS_ROOT/<project> for the project whose registry `code` the plan's
# `epic: <code>-<N>` line carries, or nothing (no line, no map, an unknown code).
plan_epic_dir() {
  local code proj
  code=$(sed -nE '/^epic: *([a-z0-9]+)-[0-9]+([^0-9].*)?$/{s//\1/p;q;}' "$1" 2>/dev/null)
  [ -n "$code" ] || return 0
  declare -F project_of_code >/dev/null 2>&1 || return 0   # the resolver source above was skipped
  proj=$(project_of_code "$code")
  [ -n "$proj" ] && printf '%s\n' "$PLANS_ROOT/$proj"
}

# Created only when a plan is linked: a session that wrote no plan (a headless run in a
# mktemp dir, a reaped worktree's husk) must not leave an empty project dir behind.
DEST_DIR="$PLANS_ROOT/$PROJECT_NAME"

# (2) this session actually touched it. A transcript names a plan by its absolute path or as
# `~/.claude/plans/<name>`, through any account's link (`.claude-bnb/plans`, claude-acct), so
# the match is on `.claude<account>/plans/<name>`, which another dir named plans does not carry.
# One scan per Stop lists every name it carries; each plan is then an exact name match.
NAMED=$(grep -oE '\.claude(-[A-Za-z0-9_]+)?/plans/[^/[:space:]"\\]+\.md' "$TRANSCRIPT" 2>/dev/null |
  sed 's#.*/##' | sort -u)
[ -n "$NAMED" ] || exit 0

while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  base=${f##*/}
  grep -qxF -- "$base" <<<"$NAMED" || continue

  # (3) first writer wins. A basename already held by ANOTHER project (a link, or a plan a
  # skill wrote there) stays there; linking it here is exactly the cross-project fan-out being
  # removed. -print -quit stops at the first hit, so this stays cheap over a large tree.
  # A plan with an `epic: <code>-<N>` line is filed under the project that epic's row code names,
  # not the session's: a game's plan written from the playground checkout counts on the game.
  dest=$(plan_epic_dir "$f")
  dest=${dest:-$DEST_DIR}
  [ "$(readlink "$dest/$base" 2>/dev/null)" = "../_live/$base" ] && continue   # already linked
  owned_elsewhere=$(find "$PLANS_ROOT" -path "$SRC_DIR" -prune -o -path "$PLANS_ROOT/*/*" \
    \( -type f -o -type l \) -name "$base" -not -path "$dest/*" -print -quit 2>/dev/null)
  [ -n "$owned_elsewhere" ] && continue

  # Relative, so the link resolves in every clone store-sync carries it to.
  mkdir -p "$dest" 2>/dev/null && ln -sfn "../_live/$base" "$dest/$base" 2>/dev/null || true
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.md' -mtime -1 2>/dev/null)

exit 0
