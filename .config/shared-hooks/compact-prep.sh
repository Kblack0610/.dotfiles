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

# Resolve project-name.sh next to this script first (robust regardless of how the
# script is invoked — repo path or the ~/.config stow symlink), then fall back to
# the stowed home path.
PN="$(dirname "$0")/project-name.sh"
[ -f "$PN" ] || PN="$HOME/.config/shared-hooks/project-name.sh"
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
MARKER="$AGENT/compact/$PROJECT.pending"

cmd_paths() {
  cat <<EOF
PROJECT=$PROJECT
ANCHOR=$AGENT/anchors/$PROJECT.md
PLAN_DIR=$AGENT/plans/$PROJECT
CLAUDE_PLAN_DIR=$HOME/.claude/plans
LESSONS=$AGENT/lessons/$PROJECT.md
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
  local payload transcript reason ts
  payload="$(cat 2>/dev/null || true)"

  if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
    transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
    reason="$(printf '%s' "$payload" | jq -r '.reason // "unknown"' 2>/dev/null)"
  fi
  reason="${reason:-unknown}"
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"

  # NOTE: this used to `cp` the transcript into ~/.agent/archives/{project}/ and record
  # the copy as `archived=`. It never preserved anything the live transcript did not.
  # Compaction does not truncate or rotate the session JSONL -- it keeps growing in
  # place -- so every archive was a byte-exact PREFIX of a file still sitting in
  # ~/.claude/projects/, and always a shorter one. Measured 2026-08-09: all 14 archives
  # matched a live transcript by md5 over their own length, 11/11 sessions still present,
  # every live copy larger; several sessions had been archived two or three times, each
  # copy a prefix of the next. 58 MB, zero unique bytes.
  #
  # The marker now points at the transcript itself. That is the same file the reconcile
  # actually wants, and `claude-recall`, 80-session-register.sh and 90-eval-gate.sh all
  # already depend on ~/.claude/projects/ being there, so this adds no new dependency.

  # Drop the capture-check marker so the next SessionStart (source=compact) can
  # surface "an auto-compact just happened; run /compact-prep check to reconcile".
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
  {
    echo "reason=$reason"
    echo "ts=$ts"
    echo "transcript=${transcript:-}"
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
