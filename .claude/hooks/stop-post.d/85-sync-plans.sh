#!/bin/bash
# Sync plans written this session from ~/.claude/plans/ into
# ~/.agent/plans/{project}/ so the next session's preflight injects them.
#
# Idempotent: copies any *.md touched in the last 24h. Overwrites are fine —
# the source-of-truth file is in ~/.claude/plans/; the agent-plans copy is
# a cache that the SessionStart hook reads.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
. "$HOME/.config/shared-hooks/project-name.sh"
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")

SRC_DIR="$HOME/.claude/plans"
DEST_DIR="$HOME/.agent/plans/$PROJECT_NAME"

[ -d "$SRC_DIR" ] || exit 0
mkdir -p "$DEST_DIR" 2>/dev/null || exit 0

find "$SRC_DIR" -maxdepth 1 -type f -name '*.md' -mtime -1 -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do
      cp -p "$f" "$DEST_DIR/" 2>/dev/null || true
    done

exit 0
