#!/usr/bin/env bash
# plan-approved.sh - PostToolUse on ExitPlanMode: one line in the approved-plan ledger, so a plan's
# open phases can reach the queue after its session is gone (fleet-dispatch reap, reconcile_plans).
# The event fires only on an approved plan: a rejected one is a failed tool call. filePath is the
# plan's real path, which differs per account (~/.claude-bnb/plans, ~/.claude/plans).
# Fails open: nothing here may get in the way of the session that just got its plan approved.

INPUT=$(cat)
plan=$(jq -r 'if .tool_response.isAgent == true then empty else .tool_response.filePath // empty end' <<<"$INPUT" 2>/dev/null)
[ -f "$plan" ] || exit 0
# shellcheck source=/dev/null
. "$HOME/.config/shared-hooks/project-name.sh" 2>/dev/null || exit 0

ledger="${PLAN_LEDGER:-$HOME/.agent/plans/approved.jsonl}"
cwd=$(jq -r '.cwd // empty' <<<"$INPUT")
mkdir -p "$(dirname "$ledger")"
jq -nc --arg plan "$plan" --arg project "$(resolve_project_name "${cwd:-$PWD}")" --arg cwd "$cwd" \
  --arg session "$(jq -r '.session_id // empty' <<<"$INPUT")" --argjson epoch "$(date +%s)" \
  '{epoch: $epoch, plan: $plan, project: $project, session: $session, cwd: $cwd}' >> "$ledger"
exit 0
