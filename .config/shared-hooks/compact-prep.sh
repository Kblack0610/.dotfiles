#!/bin/bash
# compact-prep.sh — compaction safety net + path resolver.
#
# Single source of truth for WHERE compaction artifacts live, so the three
# actors agree on {project} and the archive/marker paths:
#   - the PreCompact hook (writer)         -> `precompact`  (settings.json)
#   - the compact-prep skill (reader)      -> `paths` / `marker`
#   - the SessionStart preflight (re-inject)-> reads MARKER directly
#
# Verbs:
#   compact-prep.sh precompact     # PreCompact hook: archive transcript + drop marker (reads stdin JSON)
#   compact-prep.sh paths          # print resolved project + durable-layer paths as KEY=VALUE
#   compact-prep.sh marker         # print the pending-marker path + contents if it exists
#   compact-prep.sh marker --clear # remove the pending marker (after a post-compact reconcile)
#
# Never blocks compaction (always exits 0 in `precompact`) — a blocked compaction
# can trap a full context window.

set -uo pipefail

PN="$HOME/.config/shared-hooks/project-name.sh"
resolve_project() {
  if [ -f "$PN" ]; then
    # shellcheck source=/dev/null
    . "$PN"
    resolve_project_name "${CLAUDE_PROJECT_DIR:-$PWD}"
  else
    local b="${CLAUDE_PROJECT_DIR:-$PWD}"; b="${b##*/}"; echo "${b#.}"
  fi
}

PROJECT="$(resolve_project)"
AGENT="$HOME/.agent"
ARCHIVE_DIR="$AGENT/archives/$PROJECT"
MARKER="$AGENT/compact/$PROJECT.pending"

cmd_paths() {
  cat <<EOF
PROJECT=$PROJECT
ANCHOR=$AGENT/anchors/$PROJECT.md
PLAN_DIR=$AGENT/plans/$PROJECT
CLAUDE_PLAN_DIR=$HOME/.claude/plans
LESSONS=$AGENT/lessons/$PROJECT.md
ARCHIVE_DIR=$ARCHIVE_DIR
MARKER=$MARKER
EOF
}

cmd_marker() {
  if [ "${1:-}" = "--clear" ]; then
    rm -f "$MARKER" 2>/dev/null && echo "cleared: $MARKER" || echo "no marker to clear: $MARKER"
    return 0
  fi
  echo "$MARKER"
  [ -f "$MARKER" ] && { echo "--- marker contents ---"; cat "$MARKER"; }
}

cmd_precompact() {
  # Read the hook payload from stdin. Fields (verified vs code.claude.com/docs/en/hooks):
  #   .transcript_path     — path to the full uncompacted session transcript (JSONL)
  #   .reason              — "manual" | "auto"
  #   .custom_instructions — user-supplied /compact focus string (may be empty)
  local payload transcript reason ts archived
  payload="$(cat 2>/dev/null || true)"

  if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
    transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
    reason="$(printf '%s' "$payload" | jq -r '.reason // "unknown"' 2>/dev/null)"
  fi
  reason="${reason:-unknown}"
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"

  # 1. Archive the full uncompacted transcript (the recoverable ground truth).
  archived=""
  if [ -n "${transcript:-}" ] && [ -f "$transcript" ]; then
    mkdir -p "$ARCHIVE_DIR" 2>/dev/null || true
    archived="$ARCHIVE_DIR/${ts}-${reason}.jsonl"
    cp "$transcript" "$archived" 2>/dev/null || archived=""
  fi

  # 2. Drop the capture-check marker so the next SessionStart (source=compact) can
  #    surface "an auto-compact just happened; run /compact-prep check to reconcile".
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
  {
    echo "reason=$reason"
    echo "ts=$ts"
    echo "transcript=${transcript:-}"
    echo "archived=${archived:-}"
  } > "$MARKER" 2>/dev/null || true

  # Never block. No stdout needed — the marker + SessionStart re-inject carry the signal.
  exit 0
}

case "${1:-paths}" in
  precompact) shift; cmd_precompact "$@" ;;
  paths)      shift; cmd_paths "$@" ;;
  marker)     shift; cmd_marker "$@" ;;
  *)
    echo "usage: compact-prep.sh {precompact | paths | marker [--clear]}" >&2
    exit 2
    ;;
esac
