#!/usr/bin/env bash
# Manual ("default") permission mode means investigate-only: answer the question, change nothing.
#
# The human uses manual mode for nothing else, so the mode itself is the switch: plan, acceptEdits
# and bypass stay untouched. Shift+Tab changes the mode mid-session, so this reads the live
# `permission_mode` from each hook payload instead of deciding once at SessionStart.
#
# PreToolUse (Edit|Write|MultiEdit|NotebookEdit|EnterPlanMode): deny, on every call, with the
# posture in the reason. The settings allowlist has Edit(**), so manual mode would otherwise edit
# without a prompt. No prompt-time inject: it went into 420 prompts for 5 denies (2026-11-21), and
# the deny reason reaches the session at the one moment the posture matters.
set -uo pipefail

INPUT=$(cat)
[ "$(jq -r '.permission_mode // empty' <<<"$INPUT" 2>/dev/null)" = default ] || exit 0
[ "$(jq -r '.hook_event_name // empty' <<<"$INPUT")" = PreToolUse ] || exit 0
jq -nc '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "manual-mode-investigate: Manual mode is investigate-only: answer the question with evidence (file:line, command output) and change nothing: no edits, plan, commit, PR or board row. The human switches mode (Shift+Tab) to allow edits or a plan."}}'
exit 0
