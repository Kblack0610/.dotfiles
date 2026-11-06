#!/usr/bin/env bats
# plan-approved.sh: an approved plan gets one ledger line; anything else writes none.

load '../vendor/bats-support/load'
load '../vendor/bats-assert/load'

ROOT="$BATS_TEST_DIRNAME/../.."
HOOK="$ROOT/.claude/hooks/plan-approved.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/shared-hooks" "$HOME/work/agame" "$HOME/plans"
  ln -s "$(cd "$ROOT" && pwd)/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/project-name.sh"
  echo '{"paths": {}, "aliases": {}, "trackers": {"agame": {"type": "game"}}}' > "$HOME/.config/shared-hooks/project-map.json"
  unset PROJECT_MAP_FILE PLAN_LEDGER
  LEDGER="$HOME/.agent/plans/approved.jsonl"
  : > "$HOME/plans/p.md"
}

payload() {
  jq -nc --arg f "$1" --argjson a "${2:-false}" --arg c "$HOME/work/agame" \
    '{hook_event_name: "PostToolUse", session_id: "s-1", cwd: $c, tool_name: "ExitPlanMode", tool_response: {plan: "x", isAgent: $a, filePath: $f}}'
}

@test "an approved plan writes its real path, project and session" {
  run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_success
  run jq -c --arg h "$HOME" '[.plan == $h + "/plans/p.md", .project, .session, (.epoch > 0)]' "$LEDGER"
  assert_output '[true,"agame","s-1",true]'
}

@test "no file path, a subagent's plan or a missing file writes no line" {
  run bash "$HOOK" <<<'{"session_id": "s-1", "tool_response": "rejected"}'
  assert_success
  run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md" true)"
  assert_success
  run bash "$HOOK" <<<"$(payload "$HOME/plans/none.md")"
  assert_success
  [ ! -e "$LEDGER" ] || fail "ledger written: $(cat "$LEDGER")"
}
