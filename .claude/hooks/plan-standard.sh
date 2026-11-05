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
type=$(project_type "$project")
client=$(project_field "$project" client)
label="$project${type:+ ($type)}"

# rows -> "<section><TAB><must answer>" for each row of the tables that applies here.
rows() {
  cat "$DOC" "$CLIENT_DOC" 2>/dev/null | awk -F' *[|] *' -v want=" base $type ${client:+client} " '
    /^[|] `## / {
      n = split($3, applies, /, */)
      for (i = 1; i <= n; i++) if (index(want, " " applies[i] " ")) {
        name = $2; gsub(/`|## /, "", name); print name "\t" $4; break
      }
    }'
}

if [ "$event" = UserPromptSubmit ]; then
  sections=$(rows | awk -F'\t' '{print "- ## " $1 ": " $2}')
  rules=$(grep -E '^(Scaling|Depth): ' "$DOC")
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

[ "${#gaps[@]}" -gt 0 ] || exit 0
reason="plan-standard: ${#gaps[@]} gap(s) for $label. Fix the plan file and call ExitPlanMode again."
for g in "${gaps[@]}"; do reason+=$'\n'"- $g"; done
reason+=$'\n'"Standard: $DOC"
jq -nc --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
