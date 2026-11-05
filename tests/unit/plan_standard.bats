#!/usr/bin/env bats
# plan-standard.sh: the gate reads planning.md, so these run against the real doc. A row
# edit that drops a section or label from a type goes red here.

load '../vendor/bats-support/load'
load '../vendor/bats-assert/load'

ROOT="$BATS_TEST_DIRNAME/../.."
HOOK="$ROOT/.claude/hooks/plan-standard.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/src/docs" "$HOME/.config/shared-hooks" "$HOME/.config/agentctl" "$HOME/docs"
  ln -s "$(cd "$ROOT" && pwd)/.local/src/docs/planning.md" "$HOME/.local/src/docs/planning.md"
  ln -s "$(cd "$ROOT" && pwd)/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/project-name.sh"
  : > "$HOME/docs/standards.md"
  cat > "$HOME/.config/shared-hooks/project-map.json" <<'JSON'
{"paths": {}, "aliases": {}, "trackers": {
  "agame": {"type": "game"}, "anapp": {"type": "app"}, "aninfra": {"type": "infra"},
  "untyped": {}, "gig": {"client": "acme"}}}
JSON
  for p in agame anapp aninfra untyped gig; do mkdir -p "$HOME/work/$p"; done
  unset PROJECT_MAP_FILE
}

# base -> a plan that passes the base standard.
base() {
  cat <<EOF
# A plan

## Context

The ask, and what done looks like.

## Approach

What we will do.

Rejected: the other way.

## Reviewed

- Existing: the readers.
- Overlap: no open rows.
- Standards: \`~/docs/standards.md\`

## Risks

Small, and reversible.

## Verification

Real surface, negative control, live when deployed.
EOF
}

# without <section> reads a plan on stdin and drops that section.
without() { awk -v h="## $1" '/^## /{skip = ($0 == h)} !skip'; }

gate() { # gate <project> <plan>
  jq -nc --arg c "$HOME/work/$1" --arg p "$2" \
    '{hook_event_name: "PreToolUse", tool_name: "ExitPlanMode", cwd: $c, tool_input: {plan: $p}}' \
    | bash "$HOOK"
}

prompt() { # prompt <project> <mode>
  jq -nc --arg c "$HOME/work/$1" --arg m "$2" \
    '{hook_event_name: "UserPromptSubmit", permission_mode: $m, cwd: $c}' | bash "$HOOK"
}

@test "a complete base plan passes for an untyped project" {
  run gate untyped "$(base)"
  assert_success
  assert_output ''
}

@test "each base section is required" {
  for s in Context Approach Reviewed Risks Verification; do
    run gate untyped "$(base | without "$s")"
    assert_output --partial 'plan-standard:'
    assert_output --partial "Missing ## $s"
  done
}

@test "an empty section is denied" {
  run gate untyped "$(base | sed 's/^Small, and reversible\.$//')"
  assert_output --partial '## Risks is empty'
}

@test "infra adds Source of truth, Telemetry and Target, and not Playtest" {
  run gate aninfra "$(base)"
  assert_output --partial 'Missing ## Source of truth'
  assert_output --partial 'Missing ## Telemetry'
  assert_output --partial 'Missing ## Target'
  refute_output --partial 'Playtest'
  refute_output --partial 'Release'
}

@test "app adds Source of truth, Telemetry and Release" {
  run gate anapp "$(base)"
  assert_output --partial 'Missing ## Source of truth'
  assert_output --partial 'Missing ## Telemetry'
  assert_output --partial 'Missing ## Release'
  refute_output --partial 'Target'
}

@test "game adds Playtest only" {
  run gate agame "$(base)"
  assert_output --partial 'Missing ## Playtest'
  refute_output --partial 'Source of truth'
  refute_output --partial 'Telemetry'
  run gate agame "$(base; printf '\n## Playtest\n\nWhich game, and how.\n')"
  assert_output ''
}

@test "n/a with a reason passes" {
  run gate untyped "$(base | sed 's/^Small, and reversible\.$/n\/a: a one-line typo fix/')"
  assert_output ''
}

@test "n/a without a reason is denied" {
  run gate untyped "$(base | sed 's/^Small, and reversible\.$/n\/a/')"
  assert_output --partial '## Risks needs a reason'
}

@test "Context and Verification cannot be n/a" {
  run gate untyped "$(base | sed 's/^The ask, and what done looks like\.$/n\/a: obvious/')"
  assert_output --partial '## Context cannot be n/a'
  run gate untyped "$(base | sed 's/^Real surface.*$/n\/a: obvious/')"
  assert_output --partial '## Verification cannot be n/a'
}

@test "a plan with Phases cannot use n/a" {
  run gate untyped "$(base | sed 's/^Small, and reversible\.$/n\/a: small/'; printf '\n## Phases\n\n- [ ] one\n')"
  assert_output --partial 'cannot be n/a in a plan with ## Phases'
}

@test "each label is required" {
  run gate untyped "$(base | sed '/^Rejected:/d')"
  assert_output --partial '## Approach has no Rejected: line'
  run gate untyped "$(base | sed '/Overlap:/d')"
  assert_output --partial '## Reviewed has no Overlap: line'
  run gate untyped "$(base | sed '/Existing:/d')"
  assert_output --partial '## Reviewed has no Existing: line'
  run gate untyped "$(base | sed '/Standards:/d')"
  assert_output --partial '## Reviewed has no Standards: line'
}

@test "a Standards path that does not exist is denied" {
  run gate untyped "$(base | sed 's/docs\/standards\.md/docs\/gone.md/')"
  assert_output --partial 'no path on the Standards: line exists'
}

@test "a heading inside a code fence is not a section" {
  plan="$(base | without Risks; printf '\n```\n## Risks\n\nexample\n```\n')"
  run gate untyped "$plan"
  assert_output --partial 'Missing ## Risks'
}

@test "client rows apply only to a project with a client field" {
  printf '| `## Ticket` | client | The ticket | Existing rule |\n' > "$HOME/.config/agentctl/PLANNING-CLIENT.md"
  run gate gig "$(base)"
  assert_output --partial 'Missing ## Ticket'
  run gate untyped "$(base)"
  assert_output ''
}

@test "plan mode gets the sections for its type" {
  run prompt aninfra plan
  assert_success
  assert_output --partial 'additionalContext'
  assert_output --partial '## Target'
  assert_output --partial 'Depth:'
  refute_output --partial '## Playtest'
}

@test "other modes get nothing" {
  run prompt aninfra default
  assert_output ''
}

@test "a missing doc fails open" {
  rm "$HOME/.local/src/docs/planning.md"
  run gate aninfra "$(base)"
  assert_success
  assert_output ''
}

@test "an empty plan fails open" {
  run gate aninfra ''
  assert_success
  assert_output ''
}
