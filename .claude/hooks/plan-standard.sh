#!/usr/bin/env bash
# plan-standard.sh - holds plans to ~/.local/src/docs/planning.md, read at the two moments a
# plan forms:
#   UserPromptSubmit in plan mode: inject the sections this project's type requires.
#   PreToolUse on ExitPlanMode: deny, naming each gap, before the human sees the plan.
# The doc's tables are the standard, so nothing here restates a section or a label. A rule
# that must be recalled at a trigger does not hold, which is why this is a check.
# Fails open: a missing doc or an empty plan passes. The gate proves a section is present
# and answered, never that it is true. "plan-standard:" opens every deny; session outcomes
# count on it.

DOC="$HOME/.local/src/docs/planning.md"
CLIENT_DOC="$HOME/.config/agentctl/PLANNING-CLIENT.md"

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
type=$(project_inherited "$project" type)
client=$(project_inherited "$project" client)
label="$project${type:+ ($type)}"

# rows -> "<section><TAB><must answer>" for each row of the tables that applies here.
rows() {
  cat "$DOC" "$CLIENT_DOC" 2>/dev/null | awk -F' *[|] *' -v want=" base $type $client " '
    /^[|] `## / {
      n = split($3, applies, /, */)
      for (i = 1; i <= n; i++) if (index(want, " " applies[i] " ")) {
        name = $2; gsub(/`|## /, "", name); print name "\t" $4; break
      }
    }'
}

# epic_checked: the Epic: rule applies only to a project with a board (client work is tracked
# elsewhere) on a machine with lab sheets to check the id against (not a fleet worker).
epic_checked() { [ -n "$(project_board "$project")" ] && [ -d "$HOME/.notes/lab" ]; }

if [ "$event" = UserPromptSubmit ]; then
  # Once per session: every later plan-mode prompt would re-send the same text, and the
  # ExitPlanMode check below names any gap anyway.
  tp=$(jq -r '.transcript_path // empty' <<<"$INPUT")
  [ -n "$tp" ] && [ -r "$tp" ] && grep -qF "Plan standard for $label." "$tp" && exit 0
  sections=$(rows | awk -F'\t' '{print "- ## " $1 ": " $2}')
  rules=$(grep -E '^(Scaling|Depth|Chain): ' "$DOC")
  ! epic_checked || rules+=$'\n'$(grep -E '^Epic: ' "$DOC")
  jq -nc --arg c "Plan standard for $label. The plan must carry these sections, and ExitPlanMode is denied without them:
$sections
$rules
Full text and where to look: $DOC" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
  exit 0
fi

plan=$(jq -r '.tool_input.plan // empty' <<<"$INPUT")
[ -n "$plan" ] || exit 0

# Both skip fenced code, so a heading in an example is not a section.
headings() { awk '/^```/ {f = !f} !f && /^## / {sub(/[ \t]+$/, ""); print}' <<<"$plan"; }
body() {
  awk -v h="## $1" '/^```/ {f = !f}
    !f && /^## / {if (on) exit; sub(/[ \t]+$/, ""); on = ($0 == h); next}
    on && NF' <<<"$plan"
}
label_line() { grep -E "^[[:space:]]*([-*][[:space:]]+)?(\*\*)?$1" <<<"$2"; }

# path_exists <text> -> does any path-shaped token in it exist, from $HOME or the cwd?
path_exists() {
  local tok
  while IFS= read -r tok; do
    case "$tok" in
      "~/"*) tok="$HOME/${tok#\~/}" ;;
      /*) ;;
      *) tok="$cwd/$tok" ;;
    esac
    [ -e "$tok" ] && return 0
  done < <(grep -oE '[~./A-Za-z0-9_-]*/[./A-Za-z0-9_-]+' <<<"$1")
  return 1
}

all_headings=$(headings)
phased=$(grep -m1 '^## Phases' <<<"$all_headings")
gaps=()
while IFS=$'\t' read -r name must; do
  [ -n "$name" ] || continue
  if ! grep -qxF "## $name" <<<"$all_headings"; then
    gaps+=("Missing ## $name: $must"); continue
  fi
  text=$(body "$name")
  if [ -z "$text" ]; then
    gaps+=("## $name is empty: $must"); continue
  fi
  if grep -qiE '^[[:space:]]*n/a' <<<"${text%%$'\n'*}"; then
    if [ "$name" = Context ] || [ "$name" = Verification ]; then
      gaps+=("## $name cannot be n/a: $must")
    elif [ -n "$phased" ]; then
      gaps+=("## $name cannot be n/a in a plan with ## Phases: $must")
    elif ! grep -qiE '^[[:space:]]*n/a:[[:space:]]*[^[:space:]]' <<<"${text%%$'\n'*}"; then
      gaps+=("## $name needs a reason: write n/a: <reason>")
    fi
    continue
  fi
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    line=$(label_line "$want" "$text")
    if [ -z "$line" ]; then
      gaps+=("## $name has no $want line: $must")
    elif [ "$want" = Standards: ] && ! path_exists "$line"; then
      gaps+=("## $name: no path on the Standards: line exists. List the docs read as paths, on that line")
    fi
  done < <(grep -oE '`[A-Z][a-z]+:`' <<<"$must" | tr -d '`')
done < <(rows)

# The doc's Chain: rule. Only a sentence that runs, does or takes the work in one session
# counts, read outside code, quotes and backticks and never a negated one, so "answers given in
# this session", "never run them in one session" or a quoted old rule passes, and so does a
# plan with one open phase. Open phases are counted by the queue's own parser.
# shellcheck source=/dev/null
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../.local/lib/plan-phases.sh" 2>/dev/null
open=0
[ -n "${_PLAN_PHASES_AWK:-}" ] && open=$(awk -v mode=list "$_PLAN_PHASES_AWK" <<<"$plan" | grep -c '^open')
if [ "$open" -gt 1 ]; then
  re='(^|[^[:alpha:]])(run|runs|running|do|does|doing|take|takes|taking)[^[:alpha:]][^.]*[^[:alpha:]](in|within) (this|one|a single|the same) session([^[:alpha:]]|$)'
  one=$(awk '/^```/ {f = !f; next} !f' <<<"$plan" | sed -E 's/"[^"]*"//g; s/`[^`]*`//g' \
    | grep -oiE "[^.]*$re" | grep -viE "(^|[^[:alpha:]])(never|not|no|don't|nothing)[^[:alpha:]]" \
    | grep -m1 -oiE "$re" | sed -nE '1{s/^[^[:alpha:]]//; s/[^[:alpha:]]$//; p;}')
  [ -n "$one" ] && gaps+=("$open open phases run as a chain, a fresh session per phase: file them with agent-queue add --plan and stop, never \"${one:0:200}\"")
fi

# The doc's Epic: rule (epic_checked, above). The id must be an epic( row on some lab sheet, open
# or closed; a plan with ## Phases is a feature, so its epic is not a standing
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
  grep -qE '(^|[[:space:]])#(urgent|high|low)([[:space:]]|$)' <<<"$t" ||
    echo "epic: new $t carries no priority: end it with #urgent, #high or #low (priority_rule in agentctl-inbox-triage)"
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
  elif [ -n "$phased" ] && grep -qE 'epic\([^)]*\):[[:space:]]*[^[:space:]]+ to standard([[:space:]]|$)' <<<"$row"; then
    gaps+=("epic: $epic is a standing \"to standard\" epic, and a plan with ## Phases is a feature: propose its own as epic: new epic(<system>): <outcome> #<priority>")
  fi
fi

[ "${#gaps[@]}" -gt 0 ] || exit 0
reason="plan-standard: ${#gaps[@]} gap(s) for $label. Fix the plan file and call ExitPlanMode again."
for g in "${gaps[@]}"; do reason+=$'\n'"- $g"; done
reason+=$'\n'"Standard: $DOC"
jq -nc --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
