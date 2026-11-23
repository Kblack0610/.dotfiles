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
- [ ] `ar-13`: decorated
## Results
- [ ] ar-12 not the ledger either
EOF
  export AGENT_QUEUE_ITEM= CLAUDE_CODE_SESSION_ID=abcdef12-0000-0000-0000-000000000000
  # The record has carried every id-shaped ledger word once, so the arm check knows them.
  export COORD_WATCH_LOG="$SANDBOX/ingest.jsonl"
  printf '%s\n' '{"action":"added","id":"ar-10"}' '{"action":"item-added","id":"ar-13","item":"fix-gov-p1"}' > "$COORD_WATCH_LOG"
}

ev() { printf '%s\n' "$@" | "$CW" filter "$PLAN"; }

@test "ids reads only the open lines under Follow-through" {
  run "$CW" ids "$PLAN"
  assert_success
  assert_output $'ar-10\nfix-gov-p1\no/r#7\nar-13'
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
         '{"action":"item-claimed","id":"ar-10","by":"x"}' \
         '{"action":"added","id":"ar-10","text":"#from/abcdef12 mine","by":"abcdef12"}' \
         'not json'
  assert_success
  assert_output ''
}

@test "a plan that does not exist, or has no Follow-through section, is an error, not a silent empty watch" {
  run "$CW" filter "$SANDBOX/nope.md" </dev/null
  assert_failure 2
  assert_output --partial 'no plan at'
  printf '# p\n## Follow-through (live)\n- [ ] ar-10 x\n' > "$SANDBOX/bad.md"
  run "$CW" ids "$SANDBOX/bad.md"
  assert_failure 2
  assert_output --partial "no '## Follow-through' section"
}

@test "follow mode on a ledger with every line ticked exits 3 and writes no mark: a watch on nothing is a timer" {
  export COORD_WATCH_STATE="$SANDBOX/cw" COORD_WATCH_LOG="$SANDBOX/ingest.jsonl"
  : > "$COORD_WATCH_LOG"
  sed -i 's/^- \[ \] /- [x] /' "$PLAN"
  sed -i 's/^- \[x\] ar-1 /- [ ] ar-1 /; s/^- \[x\] ar-12 /- [ ] ar-12 /' "$PLAN"
  run "$CW" "$PLAN"
  assert_failure 3
  assert_output --partial "nothing to watch"
  assert_output --partial "coordinate step 6"
  [ ! -e "$COORD_WATCH_STATE/session-$CLAUDE_CODE_SESSION_ID.pid" ]
  [ "$(cat "$COORD_WATCH_STATE/session-$CLAUDE_CODE_SESSION_ID.plan")" = "$PLAN" ]
}

@test "follow mode on a missing plan or one with no ledger keeps its error and exit 2, not the empty-ledger exit 3" {
  export COORD_WATCH_STATE="$SANDBOX/cw"
  run "$CW" "$SANDBOX/nope.md"
  assert_failure 2
  refute_output --partial "nothing to watch"
}

# A Monitor re-arm leaves a gap; a land-failed in it was lost before the cursor (code review, #2675).
@test "--since drops what was already read and --cursor records the last event read, matched or not" {
  run bash -c 'printf "%s\n" "$3" "$4" "$5" | "$1" filter "$2" --since 2026-11-19T10:00:00.0-08:00 --cursor "$6"' _ "$CW" "$PLAN" \
    '{"ts":"2026-11-19T09:59:00.0-08:00","action":"merged","id":"ar-10"}' \
    '{"ts":"2026-11-19T10:01:00.0-08:00","action":"land-failed","id":"ar-10"}' \
    '{"ts":"2026-11-19T10:02:00.0-08:00","action":"merged","id":"ar-99"}' "$SANDBOX/cur.ts"
  assert_success
  assert_output 'land-failed ar-10 | '
  assert_equal "$(cat "$SANDBOX/cur.ts")" '2026-11-19T10:02:00.0-08:00'
}

# A prune replaces the record and tail -F re-reads it whole: one land-failed printed 32 times (2026-11-19).
@test "a record re-read after a prune prints each event once; a new or out-of-order event still prints" {
  local a='{"ts":"2026-11-19T10:00:00.0-08:00","action":"merged","id":"ar-10"}'
  local b='{"ts":"2026-11-19T10:02:00.0-08:00","action":"land-failed","id":"ar-10"}'
  local late='{"ts":"2026-11-19T10:01:00.0-08:00","action":"reopened","id":"ar-10"}'
  local c='{"ts":"2026-11-19T10:03:00.0-08:00","action":"done","id":"ar-10"}'
  run ev "$a" "$b" "$late" "$a" "$b" "$late" "$c"
  assert_success
  assert_output $'merged ar-10 | \nland-failed ar-10 | \nreopened ar-10 | \ndone ar-10 | '
}

@test "a non-object or odd-typed line does not end the stream, and a decorated ledger id still matches" {
  run ev '123' '"str"' '{"action":"merged","pr":42,"text":7}' '{"action":"merged","id":"ar-13"}'
  assert_success
  assert_output 'merged ar-13 | '
}

# The armed mark is what stop-post.d/89-coord-watch.sh reads (2026-11-19: a coordinator ran ten hours unwatched).
@test "follow mode records its pid and the plan under the session's mark while it runs, and removes it on exit" {
  local stubs="$SANDBOX/cw-stubs"; mkdir -p "$stubs"
  # The stub tail stands in for the record and ends the stream at once, after copying the live mark.
  printf '#!/bin/bash\ncat "$COORD_WATCH_STATE"/session-*.pid > "$SEEN"\n' > "$stubs/tail"; chmod +x "$stubs/tail"
  run env PATH="$stubs:$PATH" COORD_WATCH_STATE="$SANDBOX/cw" SEEN="$SANDBOX/seen" "$CW" "$PLAN"
  assert_success
  read -r pid plan < "$SANDBOX/seen"
  [[ "$pid" =~ ^[0-9]+$ ]]
  assert_equal "$plan" "$PLAN"
  [ ! -e "$SANDBOX/cw/session-abcdef12-0000-0000-0000-000000000000.pid" ]
}

@test "negative control: with no session id there is no mark to write" {
  local stubs="$SANDBOX/cw-stubs"; mkdir -p "$stubs"
  printf '#!/bin/bash\nls "$COORD_WATCH_STATE" > "$SEEN"\n' > "$stubs/tail"; chmod +x "$stubs/tail"
  run env PATH="$stubs:$PATH" CLAUDE_CODE_SESSION_ID= COORD_WATCH_STATE="$SANDBOX/cw" SEEN="$SANDBOX/seen" "$CW" "$PLAN"
  assert_success
  refute grep -q 'session-' "$SANDBOX/seen"
}

# Code review, #2791: a re-arm overlaps the old watch, whose exit removed the new watch's mark.
@test "an exit leaves the mark alone once a newer watch of the session has rewritten it" {
  local stubs="$SANDBOX/cw-stubs"; mkdir -p "$stubs"
  printf '#!/bin/bash\nprintf "1 /newer.md\\n" > "$COORD_WATCH_STATE"/session-*.pid\n' > "$stubs/tail"; chmod +x "$stubs/tail"
  run env PATH="$stubs:$PATH" COORD_WATCH_STATE="$SANDBOX/cw" "$CW" "$PLAN"
  assert_success
  assert_equal "$(cat "$SANDBOX/cw/session-abcdef12-0000-0000-0000-000000000000.pid")" '1 /newer.md'
}

# Code review, #2791: bash defers a trapped TERM while a foreground pipeline runs, so a killed watch
# lived on with its mark and the Stop check passed with no Monitor attached.
@test "a TERM while the record is being followed ends the watch at once and removes its mark" {
  local stubs="$SANDBOX/cw-stubs"; mkdir -p "$stubs"
  mkfifo "$SANDBOX/ready" "$SANDBOX/hold"
  # The stub tail says it is running, then blocks like tail -F on a quiet record.
  printf '#!/bin/bash\necho up > "$READY"\nexec 3<>"$HOLD"; read -r -u 3\n' > "$stubs/tail"; chmod +x "$stubs/tail"
  PATH="$stubs:$PATH" COORD_WATCH_STATE="$SANDBOX/cw" READY="$SANDBOX/ready" HOLD="$SANDBOX/hold" "$CW" "$PLAN" 3>&- &
  local pid=$!
  read -r _ < "$SANDBOX/ready"
  [ -f "$SANDBOX/cw/session-abcdef12-0000-0000-0000-000000000000.pid" ]
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  assert_equal "$rc" 143
  [ ! -e "$SANDBOX/cw/session-abcdef12-0000-0000-0000-000000000000.pid" ]
}

# 2026-11-23: a Monitor expires every 30 minutes, so coordinators waiting on asks woke 4 to 221 times
# each. --until runs under Bash run_in_background: no expiry, one wake per event batch.
@test "--until waits through untracked events, prints the first batch, exits 0 and leaves no tail or mark" {
  local stubs="$SANDBOX/cw-stubs"; mkdir -p "$stubs"; mkfifo "$SANDBOX/hold"
  # The stub tail replays one untracked event, then relays what the test writes, like tail -F.
  cat > "$stubs/tail" <<'STUB'
#!/bin/bash
echo $$ > "$TAILPID"
echo '{"ts":"2026-11-23T10:00:00.0-08:00","action":"merged","id":"ar-99"}'
exec 3<>"$HOLD"
while read -r -u 3 l; do printf '%s\n' "$l"; done
STUB
  chmod +x "$stubs/tail"
  # A cursor before the events: with none, the watch starts at now and drops these fixed-ts events
  # as already read once the clock passes them (it hung CI on 2026-11-23).
  mkdir -p "$SANDBOX/cw"; echo '2026-11-23T09:00:00.0-08:00' > "$SANDBOX/cw/plan.ts"
  # timeout: a regression fails this test, not the whole shard at the job limit.
  PATH="$stubs:$PATH" COORD_WATCH_STATE="$SANDBOX/cw" COORD_WATCH_BATCH_S=1 TAILPID="$SANDBOX/tailpid" HOLD="$SANDBOX/hold" \
    timeout 20 "$CW" --until "$PLAN" > "$SANDBOX/out" 2>&1 &
  local pid=$!
  exec 4<>"$SANDBOX/hold"
  printf '%s\n' '{"ts":"2026-11-23T10:01:00.0-08:00","action":"land-failed","id":"ar-10"}' \
    '{"ts":"2026-11-23T10:01:01.0-08:00","action":"done","item":"fix-gov-p1"}' >&4
  local rc=0; wait "$pid" || rc=$?
  exec 4>&-
  assert_equal "$rc" 0
  assert_equal "$(cat "$SANDBOX/out")" $'land-failed ar-10 | \ndone fix-gov-p1 | '
  run kill -0 "$(cat "$SANDBOX/tailpid")"
  assert_failure
  [ ! -e "$SANDBOX/cw/session-abcdef12-0000-0000-0000-000000000000.pid" ]
  assert_equal "$(cat "$SANDBOX/cw/plan.ts")" '2026-11-23T10:01:01.0-08:00'
}

# 2026-11-23: a ledger named a phase by a slug its item never had; the events carried ar-4707.
@test "an id-shaped ledger word no event or board row carries is an error at arm, naming it" {
  local stubs="$SANDBOX/cw-stubs"; mkdir -p "$stubs"
  printf '#!/bin/sh\necho "{\\"rows\\":[{\\"id\\":\\"ar-77\\",\\"text\\":\\"x\\"}]}"\n' > "$stubs/notes"; chmod +x "$stubs/notes"
  sed -i '/^## Results/i - [ ] plan-slug-p2 a slug nothing carries\n- [ ] ar-77 a board row with no event yet' "$PLAN"
  run env PATH="$stubs:$PATH" COORD_WATCH_STATE="$SANDBOX/cw" "$CW" --until "$PLAN"
  assert_failure 2
  assert_output --partial 'no event or board row carries plan-slug-p2 in'
  refute_output --partial 'ar-77'
  [ ! -e "$SANDBOX/cw/session-abcdef12-0000-0000-0000-000000000000.pid" ]
}

@test "negative control: a PR, a digitless outbox text line and ids the record carries pass the arm check" {
  local stubs="$SANDBOX/cw-stubs"; mkdir -p "$stubs"
  printf '#!/bin/bash\necho armed > "$SEEN"\n' > "$stubs/tail"; chmod +x "$stubs/tail"
  sed -i '/^## Results/i - [ ] fix(ci): an outbox line triage has not filed' "$PLAN"
  run env PATH="$stubs:$PATH" COORD_WATCH_STATE="$SANDBOX/cw" SEEN="$SANDBOX/seen" "$CW" --until "$PLAN"
  assert_success
  assert_equal "$(cat "$SANDBOX/seen")" armed
}
