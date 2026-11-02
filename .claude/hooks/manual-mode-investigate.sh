#!/usr/bin/env bash
# Manual ("default") permission mode means investigate-only: answer the question, change nothing.
#
# The human uses manual mode for nothing else, so the mode itself is the switch: plan, acceptEdits
# and bypass stay untouched. Shift+Tab changes the mode mid-session, so this reads the live
# `permission_mode` from each hook payload instead of deciding once at SessionStart.
#
# UserPromptSubmit: inject the investigate posture, which outranks the global plan-first and
# land-changes rules for that turn.
# PreToolUse (Edit|Write|MultiEdit|NotebookEdit|EnterPlanMode): deny. The settings allowlist has
# Edit(**), so manual mode would otherwise edit without a prompt.
set -uo pipefail

INPUT=$(cat)
[ "$(jq -r '.permission_mode // empty' <<<"$INPUT" 2>/dev/null)" = default ] || exit 0

case "$(jq -r '.hook_event_name // empty' <<<"$INPUT")" in
  UserPromptSubmit)
    jq -nc --arg c "Manual mode is investigate-only. Investigate the question and answer it with evidence (file:line, command output, docs). Read, search and run read-only commands freely; use Explore agents for broad sweeps. Do not edit or write files, commit, push, open PRs, enter plan mode, write a plan, or add board rows. This overrides the global CLAUDE.md plan-mode-default and land-changes rules while the session is in manual mode. If a fix is warranted, name it in one line, then end on the answer rather than an offer; the human switches mode (Shift+Tab) when they want changes." \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
    ;;
  PreToolUse)
    jq -nc '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "Manual mode is investigate-only: answer without changing anything. The human switches mode (Shift+Tab) to allow edits or a plan."}}'
    ;;
esac
exit 0
