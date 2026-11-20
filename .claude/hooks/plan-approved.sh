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
project=$(resolve_project_name "${cwd:-$PWD}")
session=$(jq -r '.session_id // empty' <<<"$INPUT")
mkdir -p "$(dirname "$ledger")"
jq -nc --arg plan "$plan" --arg project "$project" --arg cwd "$cwd" \
  --arg session "$session" --argjson epoch "$(date +%s)" \
  '{epoch: $epoch, plan: $plan, project: $project, session: $session, cwd: $cwd}' >> "$ledger"

# An `epic: new` line (plan_epic_new) is proposed once: `notes ptask add` files it in a hand session,
# after its self-check, with the ids the plan reviewed on Overlap: as --checked, and sends it to the
# outbox for inbox-triage otherwise. Its tag (plan_epic_tag) is how plan_epic_verdict finds the verdict
# later. A filed epic's id replaces the line, so every reader sees an ordinary `epic: <id>`.
# shellcheck source=/dev/null
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../.local/lib/plan-phases.sh" 2>/dev/null || exit 0
title=$(plan_epic_new "$plan")
[ -n "$title" ] && [ "$(plan_epic_verdict "$plan")" = none ] || exit 0
say() { jq -nc --arg c "plan-approved: $1" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'; }
board=$(project_board "$project")
[ -n "$board" ] || { say "epic: new $title was not proposed: this project has no board. Name an epic by id on the epic: line."; exit 0; }
export CLAUDE_CODE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-$session}"
tag=$(plan_epic_tag "$plan")
text="$title $tag"
checked=$(plan_overlap_ids "$plan" | paste -sd,)
out=$(notes ptask "$board" add ${checked:+--checked "$checked"} -- "$text" 2>&1)
rc=$?
id=''
[[ "$out" =~ '<!-- id:'([a-z][a-z0-9]*-[0-9]+)' -->' ]] && id=${BASH_REMATCH[1]}
case "$rc" in
  0) if [ -z "$id" ]; then msg="epic: new was filed on $board but its id was not in the output, so the plan still says epic: new. Find it with notes log --trace '$tag' and write epic: <id>. Output: $out"
     elif plan_epic_settle "$plan" "$id"; then msg="epic: new filed as $id on $board, and the plan's line now reads epic: $id."
     else msg="epic: new filed as $id on $board, but the plan could not be rewritten: write epic: $id on its epic: line."
     fi ;;
  4) msg="epic: new went to the outbox for inbox-triage: agent-queue add --plan holds its phases until the verdict, which notes log --trace '$tag' shows." ;;
  *) msg="epic: new was not filed (notes exit $rc). Fix the plan (name the twin on the epic: line, or the shortlist ids on Overlap:), then run: notes ptask $board add --checked <ids> -- \"$text\", and write its id on the epic: line. Output: $out" ;;
esac
say "$msg"
exit 0
