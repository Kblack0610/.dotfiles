#!/usr/bin/env bats
# coord-watch: the event stream a /coordinate session follows. Its contract is which chain events
# reach the coordinator: every event on a tracked row, item or PR, and triage acting on the
# session's own outbox lines; never its own writes or bookkeeping.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CW="$REPO_ROOT/.local/bin/coord-watch"
  PLAN="$SANDBOX/plan.md"
  cat > "$PLAN" <<'EOF'
# a plan
## Phases
- [ ] ar-1 phases are not the ledger
## Follow-through
- [ ] ar-10 fix the governor
- [x] ar-11 already live
- [ ] fix-gov-p1 its queue item
- [ ] o/r#7 a PR
## Results
- [ ] ar-12 not the ledger either
EOF
  export AGENT_QUEUE_ITEM= CLAUDE_CODE_SESSION_ID=abcdef12-0000-0000-0000-000000000000
}

ev() { printf '%s\n' "$@" | "$CW" filter "$PLAN"; }

@test "ids reads only the open lines under Follow-through" {
  run "$CW" ids "$PLAN"
  assert_success
  assert_output $'ar-10\nfix-gov-p1\no/r#7'
}

@test "an event on a tracked row, item or PR word prints one line, failures included" {
  run ev '{"action":"merged","id":"ar-10","item":"x","pr":"o/r#1 o/r#2","by":"x"}' \
         '{"action":"land-failed","item":"fix-gov-p1","pr":"o/r#3","why":"checks: Checks","by":"x"}' \
         '{"action":"item-cancelled","item":"y","pr":"o/q#1 o/r#7","by":"z"}'
  assert_success
  assert_line --index 0 'merged ar-10 item=x pr=o/r#1 o/r#2 | '
  assert_line --index 1 'land-failed fix-gov-p1 pr=o/r#3 why=checks: Checks | '
  assert_line --index 2 --partial 'item-cancelled y '
  assert_equal "${#lines[@]}" 3
}

@test "triage acting on the session's outbox line matches on #from/<writer>, --from adds a writer" {
  run ev '{"action":"filed","id":"ar-50","text":"#agent #from/abcdef12 fix(ci): x","by":"inbox-triage"}'
  assert_output --partial 'filed ar-50 | #agent #from/abcdef12 fix(ci): x'
  run bash -c 'printf "%s\n" "{\"action\":\"dropped\",\"text\":\"#from/coord-1 y\",\"by\":\"inbox-triage\"}" | "$1" filter "$2" --from coord-1' _ "$CW" "$PLAN"
  assert_output --partial 'dropped -'
}

@test "negative control: untracked ids, a ticked line, a longer writer, bookkeeping and own writes print nothing" {
  run ev '{"action":"merged","id":"ar-99","item":"other","pr":"o/r#70"}' \
         '{"action":"merged","id":"ar-11"}' \
         '{"action":"merged","id":"ar-1"}' \
         '{"action":"filed","id":"ar-51","text":"#from/abcdef123 z","by":"inbox-triage"}' \
         '{"action":"item-set","id":"ar-10","by":"x"}' \
         '{"action":"added","id":"ar-10","text":"#from/abcdef12 mine","by":"abcdef12"}' \
         'not json'
  assert_success
  assert_output ''
}

@test "a plan that does not exist is an error, not a silent empty watch" {
  run "$CW" filter "$SANDBOX/nope.md" </dev/null
  assert_failure 2
  assert_output --partial 'no plan at'
}
