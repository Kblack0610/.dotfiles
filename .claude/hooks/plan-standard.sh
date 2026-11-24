#!/usr/bin/env bash
# plan-standard.sh - holds plans to three rules of ~/.local/src/docs/planning.md (Epic, Phases,
# Chain), read at the two moments a plan forms:
#   UserPromptSubmit in plan mode: inject those three rules.
#   PreToolUse on ExitPlanMode: deny, naming each gap, before the human sees the plan.
# The doc's Sections table is the written standard and is not checked here (the human released
# that gate, 2026-11-22). A rule that must be recalled at a trigger does not hold, which is why
# these three are a check. Fails open: a missing doc or an empty plan passes. "plan-standard:"
# opens every deny; session outcomes count on it.

DOC="$HOME/.local/src/docs/planning.md"

INPUT=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$INPUT" 2>/dev/null)
case "$event" in
  UserPromptSubmit) [ "$(jq -r '.permission_mode // empty' <<<"$INPUT")" = plan ] || exit 0 ;;
  PreToolUse) ;;
  *) exit 0 ;;
esac
[ -r "$DOC" ] || exit 0
# shellcheck source=/dev/null
. "$HOME/.config/shared-hooks/project-name.sh" 2>/dev/null || exit 0

cwd=$(jq -r '.cwd // empty' <<<"$INPUT")
[ -n "$cwd" ] || cwd=$PWD
project=$(resolve_project_name "$cwd")
label=$project

# epic_checked: the Epic: rule applies only to a project with a board (client work is tracked
# elsewhere) on a machine with lab sheets to check the id against (not a fleet worker).
epic_checked() { [ -n "$(project_board "$project")" ] && [ -d "$HOME/.notes/lab" ]; }

if [ "$event" = UserPromptSubmit ]; then
  # Once per session: every later plan-mode prompt would re-send the same text, and the
  # ExitPlanMode check below names any gap anyway.
  tp=$(jq -r '.transcript_path // empty' <<<"$INPUT")
  [ -n "$tp" ] && [ -r "$tp" ] && grep -qF "Plan standard for $label." "$tp" && exit 0
  # A rule's "Why:" history is for editing the doc; the deny below names any gap.
  rules=$(grep -E '^(Chain|Phases): ' "$DOC")
  ! epic_checked || rules+=$'\n'$(grep -E '^Epic: ' "$DOC")
  rules=$(sed -E 's/ Why: .*//' <<<"$rules")
  jq -nc --arg c "Plan standard for $label. ExitPlanMode is denied unless the plan meets these rules:
$rules
Full text and where to look: $DOC" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
  exit 0
fi

plan=$(jq -r '.tool_input.plan // empty' <<<"$INPUT")
[ -n "$plan" ] || exit 0

# phased: a `## Phases` heading outside code fences, so a heading in an example is no section.
phased=$(awk '/^```/ {f = !f} !f && /^## Phases[ \t]*$/' <<<"$plan" | head -n1)
# multi: a plan with more than one phase is a feature (planning.md, Phases). The one-phase checklist
# one-shot writes on every plan is not, so it may name a standing epic.
# shellcheck source=/dev/null
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../.local/lib/plan-phases.sh" 2>/dev/null
multi=''
if [ -n "${_PLAN_PHASES_AWK:-}" ]; then
  # Outside code fences, so an example checklist in a fence is no phase.
  [ "$(awk '/^```/ {f = !f; next} !f' <<<"$plan" | awk -v mode=count "$_PLAN_PHASES_AWK" | cut -f2)" -gt 1 ] 2>/dev/null && multi=1
else
  multi=$phased   # no parser: the stricter old rule, never a silent pass
fi
gaps=()

# The doc's Chain: rule. Only a sentence that runs, does or takes the work in one session
# counts, read outside code, quotes and backticks and never a negated one, so "answers given in
# this session", "never run them in one session" or a quoted old rule passes, and so does a
# plan with one open phase. Open phases are counted by the queue's own parser.
open=0
[ -n "${_PLAN_PHASES_AWK:-}" ] && open=$(awk -v mode=list "$_PLAN_PHASES_AWK" <<<"$plan" | grep -c '^open')
if [ "$open" -gt 1 ]; then
  re='(^|[^[:alpha:]])(run|runs|running|do|does|doing|take|takes|taking)[^[:alpha:]][^.]*[^[:alpha:]](in|within) (this|one|a single|the same) session([^[:alpha:]]|$)'
  one=$(awk '/^```/ {f = !f; next} !f' <<<"$plan" | sed -E 's/"[^"]*"//g; s/`[^`]*`//g' \
    | grep -oiE "[^.]*$re" | grep -viE "(^|[^[:alpha:]])(never|not|no|don't|nothing)[^[:alpha:]]" \
    | grep -m1 -oiE "$re" | sed -nE '1{s/^[^[:alpha:]]//; s/[^[:alpha:]]$//; p;}')
  [ -n "$one" ] && gaps+=("$open open phases run as a chain, a fresh session per phase: file them with agent-queue add --plan and stop, never \"${one:0:200}\"")
fi

# The phase markers: `agent-queue add --plan --check` is the one parser that files phases, so a marker it
# would refuse (an `(after N)` with no `needs`, a shared-file reason, one that does not parse) is denied here
# too. Only its Phases-checklist error counts (a marker, or two phases with one number): any other failure of
# the tool leaves the plan to pass.
aq="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../.local/bin/agent-queue"
if [ -n "$phased" ] && [ -x "$aq" ] && tmpd=$(mktemp -d); then
  trap 'rm -rf "$tmpd"' EXIT
  printf '%s\n' "$plan" > "$tmpd/plan.md"
  aq_err=$("$aq" add --plan "$tmpd/plan.md" --check 2>&1 >/dev/null) || {
    marker=$(grep -m1 -oE 'could not read its Phases checklist: .*' <<<"$aq_err" | sed 's/^could not read its Phases checklist: //')
    [ -z "$marker" ] || gaps+=("Phases checklist: $marker")
  }
fi

# The doc's Epic: rule (epic_checked, above). The id must be an epic( row on some lab sheet, open
# or closed; a plan with more than one phase is a feature, so its epic is not a standing
# "epic(<system>): <system> to standard" one.
# epic_new_gaps <proposal> -> one gap a line for an `epic: new` (plan_epic_new): the read-only part of
# the self-check `notes ptask add` runs on it at approval (plan-approved.sh). The shortlist is the CLI's:
# `similar` on both lanes, merged best first, its SHORTLIST_TOP (project_tasks.rs) rows, every id of
# which the plan names on Overlap:, its review of them.
epic_new_gaps() {
  local t="$1" board sys ids lane short missing
  board=$(project_board "$project")
  if ! [[ "$t" =~ ^epic\(([a-z0-9-]+)\):[[:space:]]*[^[:space:]] ]]; then
    echo "epic: new $t is no epic(<system>): <outcome>"; return
  fi
  sys=${BASH_REMATCH[1]}
  grep -qiE '^epic\([^)]*\):.* to standard([[:space:]]+#[^[:space:]]+)*$' <<<"$t" &&
    echo "epic: new $t is a standing \"to standard\" title, which notes and project-stage-check file, never a plan"
  grep -qE '(^|[[:space:]])#(urgent|high|normal|low)([[:space:]]|$)' <<<"$t" ||
    echo "epic: new $t carries no priority: end it with #urgent, #high, #normal or #low (the rubric in ~/.config/inbox-triage/rules/priority.md)"
  if ! ids=$(project-stage-check "$board" --list --json 2>/dev/null | jq -er '.[].id' 2>/dev/null); then
    echo "epic: new: project-stage-check $board --list --json printed no system list, so epic($sys) cannot be checked"
  elif ! grep -qxF -- "$sys" <<<"$ids"; then
    echo "epic: new names epic($sys), no system of $board: one of $(paste -sd, <<<"$ids")"
  fi
  short=$(for lane in '' --agent; do
      notes ptask "$board" $lane similar --top 5 --json -- "$t" 2>/dev/null | jq -r '.[] | "\(.percent)\t\(.id)"' 2>/dev/null
    done | sort -s -t$'\t' -k1,1nr | awk 'NR <= 5' | cut -f2)
  missing=$(comm -23 <(sort -u <<<"$short" | awk 'NF') <(plan_overlap_ids <<<"$plan"))
  [ -z "$missing" ] ||
    echo "epic: new: the open rows most like it on $board are $(paste -sd' ' <<<"$short"), and Overlap: does not name $(paste -sd' ' <<<"$missing"): read each (notes ptask $board similar -- \"$t\", and --agent), then put its id on Overlap: with why it is other work, or name the one that is this work on the epic: line instead"
}

if epic_checked; then
  epic=$(awk '/^```/ {f = !f; next} !f' <<<"$plan" | grep -m1 -oE '^epic:[[:space:]]*[a-z]+-[0-9]+' | sed -E 's/^epic:[[:space:]]*//')
  row='' proposal=''
  [ -z "$epic" ] || row=$(lab_row "$epic" | grep -m1 'epic(')
  [ -n "$epic" ] || proposal=$(plan_epic_new <<<"$plan")
  if [ -n "$proposal" ]; then
    mapfile -t -O "${#gaps[@]}" gaps < <(epic_new_gaps "$proposal")
  elif [ -z "$epic" ]; then
    gaps+=("No epic: <id> line: name the epic this plan serves, or its system's standing \"epic(<system>): <system> to standard\" row, or propose a new one as epic: new epic(<system>): <outcome> #<priority>")
  elif [ -z "$row" ]; then
    gaps+=("epic: $epic is not an epic( row on any sheet under ~/.notes/lab")
  elif [ -n "$multi" ] && grep -qE 'epic\([^)]*\):[[:space:]]*[^[:space:]]+ to standard([[:space:]]|$)' <<<"$row"; then
    gaps+=("epic: $epic is a standing \"to standard\" epic, and a plan with more than one phase is a feature: propose its own as epic: new epic(<system>): <outcome> #<priority>")
  fi
fi

[ "${#gaps[@]}" -gt 0 ] || exit 0
reason="plan-standard: ${#gaps[@]} gap(s) for $label. Fix the plan file and call ExitPlanMode again."
for g in "${gaps[@]}"; do reason+=$'\n'"- $g"; done
reason+=$'\n'"Standard: $DOC"
# gate: hook-plan-standard
jq -nc --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
