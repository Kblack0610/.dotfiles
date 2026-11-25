#!/bin/bash
# Stop-post: link the plans THIS session wrote into ~/.agent/plans/{project}/, so the
# next session's preflight injects them. The plan itself lives once, in
# ~/.agent/plans/_live/ (store-sync versions it and carries it to peers); ~/.claude/plans
# is a link to that dir (claude-acct plans_store), and each project entry is a relative
# link ../_live/<name>, which resolves on every peer. settings.json also runs it as
# PostToolUse(Write|Edit|MultiEdit), so a plan is linked when it is written, Stop or not.
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

# As PostToolUse(Write|Edit|MultiEdit) the payload names the one file just written, which is the
# whole attribution: a plan whose turn ends on an interrupt (a rejected ExitPlanMode, Esc) gets no
# Stop, and 28 of 80 unlinked plans in the week to 2026-11-25 ended that way (ar-3571).
WROTE=$(echo "$STDIN_JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
PLAN_PATH_RE='(\.claude(-[A-Za-z0-9_]+)?/plans|\.agent/plans/_live)/[^/[:space:]"\\]+\.md'
if [ -n "$WROTE" ]; then
  [[ "$WROTE" =~ $PLAN_PATH_RE$ ]] || exit 0
else
  TRANSCRIPT=$(echo "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)
  # No transcript means no attribution, so copy NOTHING. A broadcast is precisely the
  # failure being removed here, and a missed sync self-heals on the next Stop.
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
fi

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
  local proj
  declare -F plan_epic_project >/dev/null 2>&1 || return 0   # the resolver source above was skipped
  proj=$(plan_epic_project "$1")
  [ -n "$proj" ] && printf '%s\n' "$PLANS_ROOT/$proj"
  return 0
}

# Created only when a plan is linked: a session that wrote no plan (a headless run in a
# mktemp dir, a reaped worktree's husk) must not leave an empty project dir behind.
DEST_DIR="$PLANS_ROOT/$PROJECT_NAME"

# (2) this session actually touched it. A transcript names a plan by its absolute path or as
# `~/.claude/plans/<name>`, through any account's link (`.claude-bnb/plans`, claude-acct), or by
# its store path `~/.agent/plans/_live/<name>` (7 of the 80 above were written there), so the match
# is on those, which another dir named plans does not carry. One scan per Stop lists every name it
# carries; each plan is then an exact name match.
if [ -n "$WROTE" ]; then
  NAMED=${WROTE##*/}
else
  NAMED=$(grep -oE "$PLAN_PATH_RE" "$TRANSCRIPT" 2>/dev/null | sed 's#.*/##' | sort -u)
fi
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
  epic=$(plan_epic_dir "$f")
  dest=${epic:-$DEST_DIR}
  [ "$(readlink "$dest/$base" 2>/dev/null)" = "../_live/$base" ] && continue   # already linked
  # An epic: line written after the plan's first write (PostToolUse links at that write): the link
  # this session made under its own project moves to the epic's, or first writer wins would keep it.
  if [ -n "$epic" ] && [ "$(readlink "$DEST_DIR/$base" 2>/dev/null)" = "../_live/$base" ]; then
    rm -f "$DEST_DIR/$base"
    rmdir "$DEST_DIR" 2>/dev/null || true
  fi
  owned_elsewhere=$(find "$PLANS_ROOT" -path "$SRC_DIR" -prune -o -path "$PLANS_ROOT/*/*" \
    \( -type f -o -type l \) -name "$base" -not -path "$dest/*" -print -quit 2>/dev/null)
  [ -n "$owned_elsewhere" ] && continue

  # Relative, so the link resolves in every clone store-sync carries it to.
  mkdir -p "$dest" 2>/dev/null && ln -sfn "../_live/$base" "$dest/$base" 2>/dev/null || true
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.md' -mtime -1 2>/dev/null)

exit 0
