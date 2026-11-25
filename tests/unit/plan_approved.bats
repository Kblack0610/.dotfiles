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
  echo '{"paths": {}, "trackers": {"agame": {"type": "game"}}}' > "$HOME/.config/shared-hooks/project-map.json"
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

@test "an attended approval grants its plan on the human's holds, never on an agent's or from a dispatched session" {
  export AGENT_HOLD_DIR="$HOME/.agent/holds"
  mkdir -p "$AGENT_HOLD_DIR"
  printf 'since: 2026-11-20T10:00:00-0800\nby: human\nkind: resource\nreason: r\ngranted: hc-1\n' > "$AGENT_HOLD_DIR/critical"
  printf 'since: 2026-11-20T10:00:00-0800\nby: agent\nkind: resource\nreason: r\ngranted: \n' > "$AGENT_HOLD_DIR/chores"
  CLAUDE_CODE_SESSION_ATTENDED=1 AGENT_QUEUE_ITEM= run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_success
  assert_output --partial 'granted p on the human'
  run grep '^granted:' "$AGENT_HOLD_DIR/critical"
  assert_output 'granted: hc-1,p'
  run grep '^granted:' "$AGENT_HOLD_DIR/chores"
  assert_output 'granted: '
  printf 'since: 2026-11-20T10:00:00-0800\nby: human\nkind: resource\nreason: r\ngranted: \n' > "$AGENT_HOLD_DIR/critical"
  CLAUDE_CODE_SESSION_ATTENDED=1 AGENT_QUEUE_ITEM=ar-1 run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_success
  run grep '^granted:' "$AGENT_HOLD_DIR/critical"
  assert_output 'granted: '
}

# proposing <add rc> <add output>: agame gets a board, and a stub notes records each call (with the
# session id it ran under) and answers `log --trace` from $TRACE and `ptask add` with <rc> and <output>.
proposing() {
  jq '.trackers.agame.lab = "personal"' "$HOME/.config/shared-hooks/project-map.json" > "$BATS_TEST_TMPDIR/m.json"
  mv "$BATS_TEST_TMPDIR/m.json" "$HOME/.config/shared-hooks/project-map.json"
  export CALLS="$BATS_TEST_TMPDIR/calls" TRACE="$BATS_TEST_TMPDIR/trace" ADD_RC="$1" ADD_OUT="$2"
  : > "$CALLS"; : > "$TRACE"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/notes" <<'SH'
#!/usr/bin/env bash
echo "$* [${CLAUDE_CODE_SESSION_ID:-}]" >> "$CALLS"
case "$1" in
  log) [ -z "${LOG_FAIL:-}" ] || { echo "$LOG_FAIL" >&2; exit 2; }
       [ -s "$TRACE" ] || { echo "no event in the record matches '$3' (it keeps 30 days)" >&2; exit 1; }
       cat "$TRACE" ;;
  ptask) printf '%s\n' "$ADD_OUT"; exit "$ADD_RC" ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/notes"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset CLAUDE_CODE_SESSION_ID
  printf '# P\n\nepic: new epic(ui): a lobby\n\n## Reviewed\n\n- Overlap: ag-1 and ag-2 are other work.\n- Standards: none\n' > "$HOME/plans/p.md"
}

@test "an approved epic: new is filed with its Overlap ids, and the plan line takes the id" {
  proposing 0 '- [ ] epic(ui): a lobby #plan/p <!-- id:ag-9 -->'
  run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_success
  assert_output --partial 'filed as ag-9'
  run grep -F 'ptask agame add' "$CALLS"
  assert_output 'ptask agame add --checked ag-1,ag-2 -- epic(ui): a lobby #plan/p [s-1]'
  run grep '^epic:' "$HOME/plans/p.md"
  assert_output 'epic: ag-9'
  [ -s "$LEDGER" ] || fail "no ledger line"
}

@test "an epic: new whose Overlap rows are another project's is filed on that board and ledgered there (ar-5288)" {
  proposing 0 '- [ ] epic(ui): a lobby #plan/p <!-- id:ot-9 -->'
  jq '.trackers.other = {"lab": "personal", "code": "ot"}' "$HOME/.config/shared-hooks/project-map.json" > "$BATS_TEST_TMPDIR/m.json"
  mv "$BATS_TEST_TMPDIR/m.json" "$HOME/.config/shared-hooks/project-map.json"
  sed -i 's/ag-1 and ag-2/ot-1 and ot-2/' "$HOME/plans/p.md"
  run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_success
  run grep -F ' add ' "$CALLS"
  assert_output 'ptask other add --checked ot-1,ot-2 -- epic(ui): a lobby #plan/p [s-1]'
  run jq -r .project "$LEDGER"
  assert_output 'other'
}

@test "an epic: new sent to the outbox stays in the plan, pending" {
  proposing 4 'inboxed: - [ ] #p:agame #from/x epic(ui): a lobby #plan/p'
  run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_output --partial 'went to the outbox'
  run grep '^epic:' "$HOME/plans/p.md"
  assert_output 'epic: new epic(ui): a lobby'
}

@test "a refused epic: new is reported back with what notes said" {
  proposing 5 $'ag-3\t40\thuman\tepic(ui): the lobby'
  run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_output --partial 'notes exit 5'
  assert_output --partial 'ag-3'
  run grep "^epic:" "$HOME/plans/p.md"
  assert_output --partial 'epic: new epic(ui)'
}

@test "an epic: new already proposed, or a plan with none, calls no add" {
  proposing 0 'unused'
  echo '{"action":"added","text":"epic(ui): a lobby #plan/p"}' > "$TRACE"
  run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_output ''
  printf '# P\n\nepic: ag-1\n' > "$HOME/plans/p.md"
  run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_output ''
  run grep -c 'ptask' "$CALLS"
  assert_output 0
}

@test "an epic: new whose verdict cannot be read is not proposed, and the session is told" {
  proposing 0 'unused'
  LOG_FAIL='notes: index locked' run bash "$HOOK" <<<"$(payload "$HOME/plans/p.md")"
  assert_success
  assert_output --partial 'could not read whether it already was'
  run grep -c 'ptask' "$CALLS"
  assert_output 0
}
