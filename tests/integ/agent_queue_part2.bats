#!/usr/bin/env bats
# The second half of agent_queue.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in agent_queue/common.bash.
# shard-seconds: 133 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'agent_queue/common'

@test "add --plan refuses a plan another active item names; the calling session's own item does not count" {
  plan_fixture
  "$AQ" add --project game --slug mine --running "phase 1 of $SANDBOX/my-plan.md" >/dev/null
  AGENT_QUEUE_ITEM=mine run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --dry-run
  assert_success
  # queued by hand from the plan's copy in another directory: the file name matches
  "$AQ" add --project game --slug by-hand "Phase 2 of /home/x/.agent/plans/game/my-plan.md" >/dev/null
  AGENT_QUEUE_ITEM=mine run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --priority high
  assert_failure
  assert_output --partial "already queued or filed: by-hand (nothing was added)"
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --dry-run
  assert_failure
  assert_output --regexp "already queued or filed: (mine by-hand|by-hand mine) "
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" | grep my-plan)" ]
}

@test "cancel moves a queued item to done, and kills the session dispatch made for a running item" {
  "$AQ" add --project game --slug q "q"
  run "$AQ" cancel q
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-q.md)" status)" = cancelled ]
  run grep -c kill-session "$NOTES_FIXTURE/calls.log"
  assert_output 0
  "$AQ" add --project game --running --session game-agent-2 --slug r "r"
  "$AQ" set r origin=run
  run "$AQ" cancel r
  assert_success
  run grep -- "-L lab kill-session -t =game-agent-2" "$NOTES_FIXTURE/calls.log"
  assert_success
  run "$AQ" cancel r
  assert_failure; assert_output --partial "nothing active"
  # fleet-dispatch writes <server>:<tmux session>: the kill goes to that server.
  "$AQ" add --project game --running --session default:game-agent-3 --slug s "s"
  "$AQ" set s origin=hand
  run "$AQ" cancel s
  assert_success
  run grep -- "-L default kill-session -t =game-agent-3" "$NOTES_FIXTURE/calls.log"
  assert_success
}

# 2026-11-12: two cleanup sessions cancelled 425 items and the items said only "cancelled".
@test "cancel from a session needs --why, and records who and why on the item and in the event" {
  "$AQ" add --project game --from shepherd --slug w1 "w1"
  "$AQ" add --project game --from shepherd --slug w2 "w2"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel w1
  assert_failure; assert_output --partial "needs --why"
  [ -n "$(item queued w1)" ]
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=sess-9 AGENT_QUEUE_ITEM=other run "$AQ" cancel w1 --why "superseded by w2"
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-w1.md)"
  [ "$(field "$f" status)" = cancelled ]
  [ "$(field "$f" cancelled_by)" = sess-9 ]
  [ "$(field "$f" cancel_why)" = "superseded by w2" ]
  assert_called "--action item-cancelled"
  assert_called "--by sess-9 --why superseded by w2"
  # a script with only the item slug is named by it
  AGENT_QUEUE_ITEM=sweeper run "$AQ" cancel w2
  assert_failure; assert_output --partial "needs --why"
  AGENT_QUEUE_ITEM=sweeper run "$AQ" cancel w2 --why "dup"
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-w2.md)" cancelled_by)" = sweeper ]
}

@test "cancel at a terminal with no session needs no --why and writes no canceller" {
  "$AQ" add --project game --slug h1 "h1"
  run "$AQ" cancel h1
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-h1.md)"
  [ "$(field "$f" status)" = cancelled ]
  [ -z "$(field "$f" cancelled_by)" ]
  [ -z "$(field "$f" cancel_why)" ]
  "$AQ" add --project game --slug h2 "h2"
  run "$AQ" cancel h2 --why "not needed"
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-h2.md)" cancel_why)" = "not needed" ]
}

@test "move --status cancelled takes the same --why, and --why on any other close is refused" {
  "$AQ" add --project game --from shepherd --slug m1 "m1"
  "$AQ" add --project game --from shepherd --slug m2 "m2"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m1 done --status cancelled
  assert_failure; assert_output --partial "needs --why"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m1 done --status cancelled --why "gone"
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-m1.md)"
  [ "$(field "$f" cancelled_by)" = sess-9 ]
  [ "$(field "$f" cancel_why)" = gone ]
  run "$AQ" move m2 done --status failed --why "x"
  assert_failure; assert_output --partial "--why and --ask record a cancel"
  # a failed close from a session still needs no reason
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m2 done --status failed
  assert_success
}

# 2026-11-12 (ar-2299): a bulk return by `cancel` left every item after: it dead, and a cleanup then
# cancelled those one by one, 40 chains lost.
@test "return sends A back with B after: A: B is returned, not left dead, and both rows are un-started" {
  "$AQ" add --project game --from shepherd --slug ra "a"
  legacy rb "after: ra" --project game --from shepherd "b"
  legacy rc "after: rb" --project game --from shepherd "c"
  "$AQ" add --project game --from shepherd --slug rz "unrelated"
  "$AQ" set ra row=game:gm-1
  "$AQ" set rb row=game:gm-2
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ra
  assert_failure; assert_output --partial "says why"
  [ -n "$(item queued ra)" ]
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ra --why "out of focus"
  assert_success
  for s in ra rb rc; do
    f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-$s.md)"
    [ "$(field "$f" status)" = cancelled ]
    [ "$(field "$f" end_reason)" = returned ]
    [ "$(field "$f" cancel_why)" = "out of focus" ]
  done
  [ -z "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-ra.md)" cancel_cause)" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-rb.md)" cancel_cause)" = "returned with ra" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-rc.md)" cancel_cause)" = "returned with ra" ]
  # nothing is left queued behind a closed item, and the unrelated item is untouched
  run bash -c "'$AQ' list --json | jq -r '.slug + \" \" + (.hold // \"\")'"
  assert_output "rz "
  assert_called "ptask game --agent unstart gm-1"
  assert_called "ptask game --agent unstart gm-2"
  assert_called "--action item-cancelled"
  assert_called "--by sess-9 --why returned: out of focus"
}

@test "return exits 1 and names the row command when a board row could not be un-started, the return stands" {
  "$AQ" add --project game --slug ua "a"
  "$AQ" set ua row=game:gm-5
  printf '#!/usr/bin/env bash\necho "notes $*" >> "$NOTES_FIXTURE/calls.log"\ncase "$*" in *unstart*) exit 1 ;; esac\n' > "$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$AQ" return ua --why "back"
  assert_failure
  assert_output --partial "ua is returned, but its board row gm-5 on game was not un-started: notes ptask game --agent unstart gm-5"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-ua.md)" end_reason)" = returned ]
}

@test "return of an item already behind a dead after: keeps that root cause" {
  "$AQ" add --project game --from shepherd --slug va "a"
  legacy vb "after: va" --project game --from shepherd "b"
  CLAUDE_CODE_SESSION_ID=sess-1 "$AQ" cancel va --why "set aside"
  "$AQ" return vb --why "back"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-vb.md)" cancel_cause)" = "after va closed cancelled by sess-1: set aside" ]
}

@test "negative control: a plain cancel of A still leaves B dead, and cancelling B records A as the cause" {
  "$AQ" add --project game --from shepherd --slug na "a"
  legacy nb "after: na" --project game --from shepherd "b"
  legacy nc "after: nb" --project game --from shepherd "c"
  CLAUDE_CODE_SESSION_ID=sess-1 "$AQ" cancel na --why "set aside"
  run bash -c "'$AQ' show nb --json | jq -r .hold"
  assert_output --partial "after na closed cancelled, dead"
  [ -n "$(item queued nb)" ]
  # the cleanup loop that cancels the dead ones leaves the root cause on each, down the chain
  CLAUDE_CODE_SESSION_ID=sess-2 "$AQ" cancel nb --why "dead chain"
  CLAUDE_CODE_SESSION_ID=sess-2 "$AQ" cancel nc --why "dead chain"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-nb.md)" cancel_cause)" = "after na closed cancelled by sess-1: set aside" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-nc.md)" cancel_cause)" = "after na closed cancelled by sess-1: set aside" ]
  # a cancel with nothing dead before it records no cause
  "$AQ" add --project game --slug nd "d"
  "$AQ" cancel nd
  [ -z "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-nd.md)" cancel_cause)" ]
}

@test "a session returns the human's work to its board row with no ask, but not an item with no row" {
  "$AQ" add --project game --from shepherd --slug ga "a"
  legacy gb "after: ga" --project game "b"
  # gb has no board row: returning it would leave the human's work nowhere, so the guard holds the chain
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "drain the queue under its cap"
  assert_failure; assert_output --partial "gb is work the human asked for"
  [ -n "$(item queued ga)" ] && [ -n "$(item queued gb)" ]
  "$AQ" set gb row=game:gm-7
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "drain the queue under its cap"
  assert_success
  [ -z "$(item queued ga)" ] && [ -z "$(item queued gb)" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-gb.md)" end_reason)" = returned ]
  assert_called "ptask game --agent unstart gm-7"
}

@test "a session drops the human's work only on an answered ask that names the whole chain, and closes nothing otherwise" {
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" > "$AGENT_ASK_ROOT/game/$1.md"; }
  "$AQ" add --project game --from shepherd --slug ga "a"
  legacy gb "after: ga" --project game "b"
  "$AQ" set gb row=game:gm-8
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "out of focus" --drop
  assert_failure; assert_output --partial "gb is work the human asked for"
  [ -n "$(item queued ga)" ] && [ -n "$(item queued gb)" ]
  ask h1 answered a human "ga only"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "out of focus" --ask h1 --drop
  assert_failure; assert_output --partial "does not name gb"
  [ -n "$(item queued ga)" ]
  ask h2 answered a human "ga gb"
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "out of focus" --ask h2 --drop
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-gb.md)" cancel_why)" = "out of focus (ask h2)" ]
  assert_called "ptask game --agent drop gm-8"
}

@test "return follows only the items that wait on it, and an item that waits on two returns with either" {
  "$AQ" add --project game --slug qa "a"
  "$AQ" add --project game --slug qx "x"
  legacy qb "after: qa qx" --project game "b"
  "$AQ" return qa --why "back to the board"
  [ -n "$(item queued qx)" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-qb.md)" end_reason)" = returned ]
  run "$AQ" return nope --why "x"
  assert_failure; assert_output --partial "nothing active with slug nope"
}

@test "add --plan resumes a chain an earlier add left part way, and still refuses a chain already whole" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  printf '# pp\n\n## Phases\n\n- [ ] 1. one\n- [ ] 2. two (independent)\n' > "$SANDBOX/pp.md"
  AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/pp.md" --project level --from shepherd --priority low >/dev/null
  # negative control: the whole chain is queued, so a second add refuses and writes nothing
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/pp.md" --project level --from shepherd --priority low
  assert_failure; assert_output --partial "the phases of $SANDBOX/pp.md are already queued"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 2 ]
  # The plan grew to a chain of four, and an add from before the queue held no gated work left its
  # first two items queued, pp-p2 after pp-p1 (it stopped on a lock it timed out on, ar-2922).
  chain_plan pp
  sed -i '/^from: /i after: pp-p1' "$(item queued pp-p2)"
  # a kept item queued with other phases than the plan gives it now is refused, nothing added
  "$AQ" set pp-p2 phases=3 >/dev/null
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/pp.md" --project level --from shepherd --priority low
  assert_failure; assert_output --partial "pp-p2 is queued with other phases than"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 2 ]
  "$AQ" set pp-p2 phases=2 >/dev/null
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/pp.md" --project level --from shepherd --priority low
  assert_success
  assert_output --partial "kept pp-p1, queued by an earlier add of"
  assert_output --partial "kept pp-p2, queued by an earlier add of"
  # The rest wait on the board, each on the row before it.
  assert_line 'held pp-p3 -> level:lv-3 (#after/lv-2)'
  assert_line 'held pp-p4 -> level:lv-4 (#after/lv-3)'
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 2 ]
}

# ar-2922: the add took the lock once per phase and gave up on the first busy one, so one busy queue left P1 only.
@test "add --plan waits on a held lock and queues every phase once it frees; one that never frees exits 75, not 1" {
  printf '# wl\n\n## Phases\n\n- [ ] 1. one\n- [ ] 2. two (independent)\n- [ ] 3. three (independent)\n' > "$SANDBOX/wl.md"
  mkdir -p "$AGENT_QUEUE_DIR"
  # The add's stderr is a fifo opened read-write here, so the first lock miss it reports is the event
  # the lock is freed on: no sleep, and a writer that never reports fails the read's timeout.
  mkfifo "$SANDBOX/err.fifo"
  exec 6<> "$SANDBOX/err.fifo"
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  AGENT_QUEUE_LOCK_WAIT=1 AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/wl.md" --project game --from shepherd --priority low \
    > "$SANDBOX/add.out" 2> "$SANDBOX/err.fifo" 9>&- 6>&- &
  WRITER=$!
  read -t 20 -r -u 6 line
  [[ "$line" == *"locked by another writer"* ]]
  flock -u 9
  wait "$WRITER" || { cat "$SANDBOX/add.out"; timeout 1 cat <&6; false; }
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 3 ]
  # negative control: a lock that never frees writes nothing and exits 75, not 1 (before: 1, "queued 0 of 3")
  printf "# w2\n\n## Phases\n\n- [ ] 1. one\n- [ ] 2. two (independent)\n" > "$SANDBOX/w2.md"
  flock 9
  AGENT_QUEUE_LOCK_WAIT=1 AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/w2.md" --project game --from shepherd --priority low 9>&-
  assert_failure 75
  assert_output --partial "the queue is busy; adding the plan again (1 of 6 tries)"
  assert_output --partial "run the same add again"
  flock -u 9
  exec 9>&- 6>&-
}

@test "set phases= takes plan checklist numbers, as add --plan writes them, and refuses anything else" {
  "$AQ" add --project game --slug ph "Phase 3 of the plan" >/dev/null
  "$AQ" set ph phases=3,4 >/dev/null
  [ "$(field "$(item queued ph)" phases)" = "3 4" ]
  run "$AQ" set ph phases=P3
  assert_failure; assert_output --partial "phases is plan checklist numbers"
  [ "$(field "$(item queued ph)" phases)" = "3 4" ]
}

@test "set review_fix= takes none or small, what a trainee's review changed before it landed the diff, and refuses anything else" {
  "$AQ" add --project game --slug rf "A trainee row" >/dev/null
  "$AQ" set rf review_fix=small >/dev/null
  [ "$(field "$(item queued rf)" review_fix)" = "small" ]
  run "$AQ" set rf review_fix=big
  assert_failure; assert_output --partial "review_fix is none or small"
  [ "$(field "$(item queued rf)" review_fix)" = "small" ]
}

# 2026-11-12: a cleanup cancelled 220 from: human items by looping a dead chain (mkt-17 after
# mkt-16, then 18, 19, 20). The judge's answer counts as any answer does (ar-4765): its policy keeps a
# bulk cancel (10 or more records) with the human.
@test "a session cancels the human's work only on an answered ask naming it; the human and other work are not held" {
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_ROOT/game/$1.md"; }
  "$AQ" add --project game --slug mkt-16 "mkt-16" >/dev/null
  for n in 17 18 19 20; do legacy "mkt-$n" "after: mkt-$((n - 1))" --project game "mkt-$n"; done
  "$AQ" add --project game --from board:game:g2-9 --tags requested --slug asked "row the human asked for" >/dev/null
  "$AQ" add --project game --from shepherd --slug chore "chore" >/dev/null
  # The terminal cancel (no session env) is the human's: mkt-16 goes, and its chain is dead.
  "$AQ" cancel mkt-16 >/dev/null
  run bash -c "'$AQ' show mkt-17 --json | jq -r .hold"
  assert_output --partial "a cancel by hand takes --why and --ask <an answered ask naming it>"
  # The replay: the dead-chain loop refuses every from: human item and the #requested one.
  for s in mkt-17 mkt-18 mkt-19 mkt-20 asked; do
    CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel "$s" --why "dead chain"
    assert_failure; assert_output --partial "$s is work the human asked for"
    [ -n "$(item queued "$s")" ]
  done
  AGENT_QUEUE_ITEM=sweeper run "$AQ" move mkt-17 done --status cancelled --why "dead chain"
  assert_failure; assert_output --partial "work the human asked for"
  # An ask nobody has answered is no decision.
  ask p1 pending
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask p1
  assert_failure; assert_output --partial "ask p1 is pending"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask nope
  assert_failure; assert_output --partial "no such ask"
  [ -n "$(item queued mkt-17)" ]
  run "$AQ" cancel mkt-17 --ask "h1=a"
  assert_failure; assert_output --partial "--ask takes an ask id"
  # An answer about other work is not about this item.
  ask h0 answered a human
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask h0
  assert_failure; assert_output --partial "ask h0 does not name mkt-17"
  # A conditional move that no longer applies is left alone (exit 3) before the guard reads it.
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move mkt-17 done --status cancelled --why "x" --if running
  [ "$status" -eq 3 ]
  # The human's answer to an ask naming the items lets them go, and the item names the ask.
  ask h1 answered a human
  echo "question: drop mkt-17, mkt-18? both wait on mkt-16, which you cancelled" >> "$AGENT_ASK_ROOT/game/h1.md"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask h1
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-mkt-17.md)"
  [ "$(field "$f" cancel_why)" = "dead chain (ask h1)" ]
  [ "$(field "$f" cancelled_by)" = sess-9 ]
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move mkt-18 done --status cancelled --why "dead chain" --ask h1
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-mkt-18.md)" cancel_why)" = "dead chain (ask h1)" ]
  # A session's own answer is no ruling, even on an ask naming the item.
  ask a1 answered a agent
  echo "question: drop mkt-19? it waits on mkt-16, which you cancelled" >> "$AGENT_ASK_ROOT/game/a1.md"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-19 --why "dead chain" --ask a1
  assert_failure; assert_output --partial "ask a1 is answered by agent"
  [ -n "$(item queued mkt-19)" ]
  # The judge's answer to an ask naming the item lets it go the same way (ar-4765).
  ask j1 answered a judge
  echo "question: drop mkt-19? it waits on mkt-16, which you cancelled" >> "$AGENT_ASK_ROOT/game/j1.md"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-19 --why "dead chain" --ask j1
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-mkt-19.md)" cancel_why)" = "dead chain (ask j1)" ]
  # Negative controls: other work cancels from a session with a reason, and --ask is cancel's alone.
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel chore --why "dup" --ask nope
  assert_failure; assert_output --partial "no such ask"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel chore --why "dup"
  assert_success
  run "$AQ" move mkt-20 done --status failed --ask h1
  assert_failure; assert_output --partial "--ask record a cancel"
  # The human at a terminal is never held.
  run "$AQ" cancel asked
  assert_success
}

@test "cancel keeps a backslash in --why as typed, refuses a multi-line one before touching the item, and carries why to a record-only cancel" {
  "$AQ" add --project game --slug b1 "b1"
  run "$AQ" cancel b1 --why $'two\nlines'
  assert_failure; assert_output --partial "one line"
  [ -n "$(item queued b1)" ]
  [ -z "$(field "$(item queued b1)" status)" ]
  "$AQ" cancel b1 --why 'C:\tmp a\nb'
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-b1.md)" cancel_why)" = 'C:\tmp a\nb' ]
}

# 2026-11-10: two probe items deleted by hand sat queued in the record for days, chain_drift 2.
@test "cancel of a slug whose file is gone closes it in the record while the record holds it active" {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
echo "notes $*" >> "$NOTES_FIXTURE/calls.log"
case "$*" in
  # the record replays a written cancel unless NOTES_DROP says the write was lost
  "log --steps --json") if grep -q 'ingest record' "$NOTES_FIXTURE/calls.log" && [ -z "${NOTES_DROP:-}" ]; then
      echo '{"steps":[{"step":"queued","items":[]},{"step":"done","items":["gone","ghost"]}]}'
    else echo '{"steps":[{"step":"queued","items":["ghost"]},{"step":"done","items":["gone"]}]}'; fi ;;
  "log --days 3650 --item ghost --json") echo '{"action":"item-added","from":"game","text":"probe","item":"ghost"}'
    echo '{"action":"item-set","from":"game","text":"probe","item":"ghost"}' ;;
esac
EOF
  chmod +x "$SANDBOX/bin/notes"
  # a write the record never took is no cancel
  NOTES_DROP=1 run "$AQ" cancel ghost
  assert_failure; assert_output --partial "ghost is still active in the record"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" cancel ghost
  assert_success
  assert_output "cancelled ghost in the record: its file was already gone"
  assert_called "notes ingest record --stage queue --action item-cancelled --from game --item ghost --to done -- probe"
  # a session's reason and name reach the event of a cancel with no file, too
  : > "$NOTES_FIXTURE/calls.log"
  NOTES_DROP=1 CLAUDE_CODE_SESSION_ID=sess-7 run "$AQ" cancel ghost --why "file deleted"
  assert_called "--item ghost --to done --by sess-7 --why file deleted -- probe"
  # one the record has closed, or never held, is still nothing active
  for s in gone never; do
    run "$AQ" cancel "$s"
    assert_failure; assert_output --partial "nothing active with slug $s"
  done
}

# 2026-11-04: cancelling an item hand-started in a hub:dotfiles window killed hub:dotfiles and
# every window in it. A hand start now records no hub session, but items that name one exist.
@test "cancel of an item recorded on a hub:dotfiles window closes its window, never the session" {
  "$AQ" add --project game --running --session hub:dotfiles --slug by-hand "by hand"
  "$AQ" set by-hand window=@9
  run "$AQ" cancel by-hand
  assert_success
  assert_output --partial "closed window @9 of dotfiles"
  run grep -- "tmux -L hub kill-window -t @9" "$NOTES_FIXTURE/calls.log"
  assert_success
  run grep -c kill-session "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a hand start on the agent world records its window, and cancel closes only that" {
  echo game-agent-1 > "$NOTES_FIXTURE/tmux.session"
  TMUX="/tmp/tmux-1000/lab,1,0" TMUX_PANE=%31 STUB_WINDOW_ID=@9 \
    "$AQ" add --project game --running --slug by-hand "by hand"
  f="$(item running by-hand)"
  [ "$(field "$f" session)" = lab:game-agent-1 ]
  [ "$(field "$f" window)" = @9 ]
  run "$AQ" cancel by-hand
  assert_success
  run grep -- "tmux -L lab kill-window -t @9" "$NOTES_FIXTURE/calls.log"
  assert_success
  run grep -c kill-session "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "cancel of a hand-started item that recorded no window kills nothing" {
  "$AQ" add --project game --running --session hub:dotfiles --slug old "recorded before windows were"
  run "$AQ" cancel old
  assert_success
  assert_output --partial "left hub:dotfiles open"
  run grep -cE "kill-(session|window)" "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "cancel never kills a world session, even one an item says dispatch made" {
  export TMUX_SERVERS_DIR="$REPO_ROOT/.config/tmux-servers"
  "$AQ" add --project game --running --session hub:dotfiles --slug wrong "a bad record"
  "$AQ" set wrong origin=run
  run "$AQ" cancel wrong
  assert_success
  assert_output --partial "dotfiles is a world session"
  run grep -c kill-session "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "the same slug finished twice in a day keeps both records" {
  "$AQ" add --project game --slug twice "1"
  "$AQ" cancel twice
  "$AQ" add --project game --slug twice "2"
  "$AQ" cancel twice
  [ "$(ls "$AGENT_QUEUE_DIR"/done/*/ | grep -c twice)" -eq 2 ]
  run bash -c "'$AQ' show twice | tail -1"
  assert_output 2
}

@test "list --since reads done items from that day on, across days" {
  local slug day
  for slug in old edge new; do "$AQ" add --project game --slug "$slug" "t"; "$AQ" cancel "$slug"; done
  for slug in old:2026-11-01 edge:2026-11-02 new:2026-11-03; do
    day="$AGENT_QUEUE_DIR/done/${slug#*:}"; mkdir -p "$day"
    mv "$AGENT_QUEUE_DIR"/done/"$(date +%F)"/*-"${slug%:*}".md "$day/"
  done
  run bash -c "'$AQ' list --state done --since 2026-11-02 --json | jq -r .slug | sort | tr '\n' ' '"
  assert_output "edge new "
}

# 2026-11-14: `stats --since 7d` read done_24h 0 against 274, since 7d sorted after every day dir.
@test "stats and list --since take 7d and 7 as days back, the same as the day, and refuse any other form" {
  "$AQ" add --project game --slug d1 "d"; "$AQ" move d1 done --status ok
  day="$(date -d '3 days ago' +%F)"
  run "$AQ" stats --json --flow --since "$day"
  assert_success
  want="$(jq -c '[.since, .recent.done_24h, .per_day, (.flow // {} | map_values(.done))]' <<<"$output")"
  assert_equal "$(jq -c '.[1]' <<<"$want")" 1
  for form in 3d 3; do
    run "$AQ" stats --json --flow --since "$form"
    assert_success
    assert_equal "$(jq -c '[.since, .recent.done_24h, .per_day, (.flow // {} | map_values(.done))]' <<<"$output")" "$want"
    run bash -c "'$AQ' list --state done --since $form --json | jq -r .slug"
    assert_output d1
  done
  # 20261114 and 99999 are digits date reads as a time of day, which would come back as today.
  for bad in 1w 3dd 2026-13-01 20261114 99999; do
    run "$AQ" stats --json --since "$bad"
    assert_failure
    assert_output --partial "--since is a day (YYYY-MM-DD) or days back (7d or 7), not '$bad'"
    run "$AQ" list --since "$bad"
    assert_failure
  done
}

@test "list groups by state and says when nothing is there" {
  run "$AQ" list
  assert_output --partial "nothing"
  "$AQ" add --project game --slug q1 "q"
  "$AQ" add --project game --running --session s1 --slug r1 "r"
  "$AQ" add --project game --slug d1 "d"; "$AQ" cancel d1
  run bash -c "'$AQ' list | cut -f1,3"
  assert_output $'running\tr1\nqueued\tq1'
  run bash -c "'$AQ' list --state all --json | jq -r .state | sort | uniq -c | awk '{print \$2\":\"\$1}' | tr '\n' ' '"
  assert_output "done:1 queued:1 running:1 "
}

@test "stats counts states, outcomes, waits, time to PR and sources from the timestamps" {
  "$AQ" add --project game --slug a "a"
  "$AQ" add --project app --slug b --from shepherd --tags ui "b"
  "$AQ" add --project game --slug c --from board:game:fix-x "c"
  "$AQ" move a running
  "$AQ" set a started=2026-11-03T10:30:00Z
  f="$(item running a)"; sed -i 's/^queued: .*/queued: 2026-11-03T10:00:00Z/' "$f"
  "$AQ" move a done --status ok
  "$AQ" set a finished=2026-11-03T11:30:00Z pr=812
  "$AQ" move b done --status cancelled
  "$AQ" set b finished=2026-11-02T09:00:00Z
  # d started the minute it was added (--running): it is counted apart, not as a 0 min wait.
  "$AQ" add --project game --slug d --running "d"
  # c can start and has sat two hours; e waits on c.
  f="$(item queued c)"; sed -i "s/^queued: .*/queued: $(date -u -d '2 hours ago' +%FT%TZ)/" "$f"
  legacy e "after: c" --project game "e"
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  [ "$(jq -r '.active.queued' <<<"$output")" = 2 ]
  [ "$(jq -r '.started_at_once' <<<"$output")" = 1 ]
  [ "$(jq -r '.wait_minutes_p90' <<<"$output")" = 30 ]
  [ "$(jq -c '.sitting | [.queued, .runnable, .held, .held_by.after, .runnable_age_minutes_median]' <<<"$output")" = '[2,1,1,1,120]' ]
  [ "$(jq -c '.sitting.oldest_runnable | map([.slug, .minutes])' <<<"$output")" = '[["c",120]]' ]
  [ "$(jq -r '.added_per_day | add' <<<"$output")" = 5 ]
  [ "$(jq -r '.done.ok' <<<"$output")" = 1 ]
  [ "$(jq -r '.done.cancelled' <<<"$output")" = 1 ]
  [ "$(jq -r '.wait_minutes_median' <<<"$output")" = 30 ]
  [ "$(jq -r '.run_minutes_median' <<<"$output")" = 60 ]
  [ "$(jq -r '.to_pr_minutes_median' <<<"$output")" = 90 ]
  [ "$(jq -c '.per_day' <<<"$output")" = '{"2026-11-02":1,"2026-11-03":1}' ]
  [ "$(jq -c '.by_source.shepherd | [.done, .cancelled, .prs]' <<<"$output")" = '[1,1,0]' ]
  [ "$(jq -c '.by_project.game | [.done, .ok, .prs, .wait_minutes_median, .to_pr_minutes_median]' <<<"$output")" = '[1,1,1,30,90]' ]
  [ "$(jq -r '.done_by_tag.ui' <<<"$output")" = 1 ]
  run "$AQ" stats
  assert_success
  assert_output --partial "done:"
  assert_output --partial "to PR:   median 90 min"
  assert_output --partial "wait:    median 30 min, p90 30 min from ready to started, 1 started at once and not counted"
  assert_output --partial "sitting: 1 can start, oldest 2h (c), median 2h; 1 held (after 1)"
  assert_output --partial "project: app 1 (0 PR), game 1 (1 PR)"
}

@test "stats wait for an after: item runs from its predecessor's finish, not from when it was queued" {
  "$AQ" add --project game --slug p "p"
  legacy f "after: p" --project game "f"
  "$AQ" move p running; "$AQ" move p done --status ok
  "$AQ" set p finished=2026-11-03T12:00:00Z
  f="$(item queued f)"; sed -i 's/^queued: .*/queued: 2026-11-03T08:00:00Z/' "$f"
  "$AQ" move f running; "$AQ" set f started=2026-11-03T12:10:00Z
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  assert_equal "$(jq -c '[.wait_minutes_median, .wait_minutes_p90]' <<<"$output")" '[10,10]'
  # negative control: with its predecessor gone from the store, the wait runs from queued
  rm "$AGENT_QUEUE_DIR"/done/*/*-p.md
  run "$AQ" stats --json --since 2000-01-01
  assert_equal "$(jq -c '.wait_minutes_median' <<<"$output")" '250'
}

@test "stats chain: handoff from the predecessor's finish to the start, by priority, over after: items only (ar-3263)" {
  "$AQ" add --project game --slug p --priority urgent "p"
  legacy f "after: p" --project game --priority urgent "f"
  "$AQ" add --project game --slug plain --priority urgent "plain"
  "$AQ" move p running; "$AQ" move p done --status ok
  "$AQ" set p finished=2026-11-03T12:00:00Z
  "$AQ" move plain running
  f="$(item queued f)"; sed -i 's/^queued: .*/queued: 2026-11-03T08:00:00Z/' "$f"
  "$AQ" move f running; "$AQ" set f started=2026-11-03T12:10:00Z
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  # one handoff of 10 min; plain has no after:, so it is not a handoff; the 2026-11 start is not in the last 24h
  assert_equal "$(jq -c '.chain.by_priority' <<<"$output")" '{"urgent":{"n":1,"p50":10,"p90":10}}'
  assert_equal "$(jq -c '.chain.h24' <<<"$output")" '{}'
  run "$AQ" stats --since 2000-01-01
  assert_output --partial "chain:   handoff p50/p90 min from the predecessor's finish to the start (n): urgent 10/10 (1); last 24h: none"
  # negative control: a start inside the last 24h lands in h24
  now=$(date +%s)   # one read, so the 10 min between the two stamps cannot straddle a minute
  "$AQ" set f started="$(date -u -d "@$((now - 3600))" +%FT%TZ)"
  "$AQ" set p finished="$(date -u -d "@$((now - 3600 - 600))" +%FT%TZ)"
  run "$AQ" stats --json --since 2000-01-01
  assert_equal "$(jq -c '.chain.h24' <<<"$output")" '{"urgent":{"n":1,"p50":10,"p90":10}}'
  # an item also gated by an event (ask, pr, nightly, rbw, hold) has no recorded ready time: left out
  "$AQ" set f tags="pr:o/r#5"
  run "$AQ" stats --json --since 2000-01-01
  assert_equal "$(jq -c '.chain.h24' <<<"$output")" '{}'
}

# ar-4436: a return to the queue clears `started`, so the restart read as the wait since the predecessor
# finished (a week, for an item that blocked on a login). It is ready again from the return.
@test "stats chain: an item returned to the queue and restarted waits from its return, not from its predecessor's finish (ar-4436)" {
  "$AQ" add --project game --slug p --priority urgent "p"
  legacy f "after: p" --project game --priority urgent "f"
  "$AQ" move p running; "$AQ" move p done --status ok
  now=$(date +%s)
  "$AQ" set p finished="$(date -u -d "@$((now - 259200))" +%FT%TZ)"
  f="$(item queued f)"; sed -i "s/^queued: .*/queued: $(date -u -d "@$((now - 259300))" +%FT%TZ)/" "$f"
  "$AQ" move f running; "$AQ" set f started="$(date -u -d "@$((now - 258600))" +%FT%TZ)"
  "$AQ" move f queued
  [ -n "$(sed -n 's/^requeued: //p' "$(item queued f)")" ]
  "$AQ" move f running
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  assert_equal "$(jq -c '.chain.h24.urgent.p90 < 5' <<<"$output")" 'true'
}

# ar-617: the Queue table shows each item's wait, so list carries the same ready stats medians.
@test "list --json carries ready: queued, else its after: item's finish when later, none while that holds it" {
  "$AQ" add --project game --slug p "p"
  legacy f "after: p" --project game "f"
  "$AQ" add --project game --slug plain "plain"
  f="$(item queued f)"; sed -i 's/^queued: .*/queued: 2026-11-03T08:00:00Z/' "$f"
  f="$(item queued plain)"; sed -i 's/^queued: .*/queued: 2026-11-03T09:00:00Z/' "$f"
  run "$AQ" list --json --state all
  assert_success
  assert_equal "$(jq -r 'select(.slug == "plain") | .ready' <<<"$output")" 2026-11-03T09:00:00Z
  # f is held after p: it is not ready yet
  assert_equal "$(jq -r 'select(.slug == "f") | .ready // "none"' <<<"$output")" none
  "$AQ" move p running; "$AQ" move p done --status ok
  "$AQ" set p finished=2026-11-03T12:00:00Z
  run "$AQ" list --json --state all
  assert_equal "$(jq -r 'select(.slug == "f") | .ready' <<<"$output")" 2026-11-03T12:00:00Z
  run "$AQ" show f --json
  assert_equal "$(jq -r .ready <<<"$output")" 2026-11-03T12:00:00Z
  # a predecessor that finished before the item was queued leaves ready at queued
  "$AQ" set p finished=2026-11-03T07:00:00Z
  run "$AQ" list --json --state queued
  assert_equal "$(jq -r 'select(.slug == "f") | .ready' <<<"$output")" 2026-11-03T08:00:00Z
}

# ar-1089: fleet-bench ages the queued step from ready, so a time hold must not read as waiting.
@test "list --json ready: none while an at: hold is pending, the tag's time once it released, else queued" {
  export TZ=America/Los_Angeles AGENT_QUEUE_NOW=2026-11-20T12:00
  mkdir -p "$AGENT_QUEUE_DIR/queued"
  mk() { printf "slug: $1\nproject: game\npriority: high\nweight: light\nqueued: $2\ntags: $3\n---\n$1\n" > "$AGENT_QUEUE_DIR/queued/$4-$1.md"; }
  mk dated 2026-11-14T17:00:00Z at:2026-11-16T09:00 20261114
  mk daily_early 2026-11-10T08:00:00Z at:09:00 20261110
  mk daily_late 2026-11-10T20:00:00Z at:09:00 20261111
  mk after_queued 2026-11-19T20:00:00Z at:2026-11-19T09:00 20261119
  mk pending 2026-11-14T17:00:00Z at:2026-11-21T09:00 20261114b
  mk pending_daily 2026-11-14T17:00:00Z at:23:59 20261114c
  run "$AQ" list --json --state queued
  assert_success
  ready() { jq -r --arg s "$1" 'select(.slug == $s) | .ready // "none"' <<<"$output"; }
  # 09:00 PST is 17:00Z
  assert_equal "$(ready dated)" 2026-11-16T17:00:00Z
  assert_equal "$(ready daily_early)" 2026-11-10T17:00:00Z
  assert_equal "$(ready daily_late)" 2026-11-10T20:00:00Z
  assert_equal "$(ready after_queued)" 2026-11-19T20:00:00Z
  # NEGATIVE CONTROL: the same items while their hold is still pending have no ready
  assert_equal "$(ready pending)" none
  assert_equal "$(ready pending_daily)" none
  run "$AQ" show pending --json
  assert_equal "$(jq -r '.hold, (.ready // "none")' <<<"$output")" $'at:2026-11-21T09:00\nnone'
  # an item started by hand before its at: time was never made to wait for it: ready stops at started
  mkdir -p "$AGENT_QUEUE_DIR/running"
  printf 'slug: early\nproject: game\npriority: high\nweight: light\nqueued: 2026-11-14T17:00:00Z\nstarted: 2026-11-20T18:00:00Z\ntags: at:2026-11-21T09:00\n---\nearly\n' \
    > "$AGENT_QUEUE_DIR/running/20261114-early.md"
  run "$AQ" show early --json
  assert_equal "$(jq -r .ready <<<"$output")" 2026-11-20T18:00:00Z
}

@test "stats flow: each stage counts on the local day it was reached, with lead, wait and run time" {
  export TZ=America/Los_Angeles
  "$AQ" add --project game --slug a "a"
  "$AQ" move a running
  "$AQ" set a started=2026-11-03T10:30:00Z
  f="$(item running a)"; sed -i 's/^queued: .*/queued: 2026-11-03T10:00:00Z/' "$f"
  "$AQ" move a done --status ok
  "$AQ" set a finished=2026-11-03T11:30:00Z
  "$AQ" add --project game --slug b "b"
  f="$(item queued b)"; sed -i 's/^queued: .*/queued: 2026-11-04T02:00:00Z/' "$f"
  "$AQ" move b done --status failed
  "$AQ" set b finished=2026-11-04T03:00:00Z
  run "$AQ" stats --json --flow --since 2026-11-03
  assert_success
  assert_equal "$(jq -c '.flow["2026-11-03"] | [.queued, .started, .done, .ok, .failed, .lead_minutes, .wait_minutes.p50, .run_minutes.p50]' <<<"$output")" '[2,1,2,1,1,{"n":2,"p50":90,"p90":90},30,60]'
  run "$AQ" stats --json --flow --since 2026-11-04
  [ "$(jq -c '.flow | has("2026-11-03")' <<<"$output")" = false ]
}

@test "stats counts the flow of the last 1, 6 and 24 hours: added by queued, started by started, done and failed by finished" {
  ago() { date -u -d "$1 ago" +%FT%TZ; }
  for spec in "a 3hours 30minutes ok" "b 10hours 5hours failed" "c 30hours 20hours ok"; do
    set -- $spec
    "$AQ" add --project game --slug "$1" "$1"
    "$AQ" move "$1" done --status "$4"
    "$AQ" set "$1" "finished=$(ago "$3")" "started=$(ago "$3")"
    f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-"$1".md)"; sed -i "s/^queued: .*/queued: $(ago "$2")/" "$f"
  done
  "$AQ" add --project game --slug d "d"
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  assert_equal "$(jq -c '.recent | [.done_1h, .done_6h, .done_24h, .added_1h, .added_6h, .added_24h]' <<<"$output")" '[1,2,3,1,2,3]'
  assert_equal "$(jq -c '.recent | [.failed_1h, .failed_6h, .failed_24h, .started_1h, .started_6h, .started_24h]' <<<"$output")" '[0,1,1,1,2,3]'
}

@test "stats shipped_today and checks_today count ok slugs since local midnight, once each, never the UTC day or a failed item" {
  export TZ=Etc/GMT+8 # west of UTC: last night's 23:59 local is already today in UTC
  today="$(date +%F)"
  at() { date -u -d "@$(date -d "$1" +%s)" +%FT%TZ; } # -u alone would read $1 as UTC
  # a: shipped twice (a repeat run) counts once; k: a check run twice counts once; b: yesterday
  # local; c: failed with a merge, the negative control, counts in neither.
  for spec in "a|$today 00:00:01|ok|abc123" "a|$today 00:00:03|ok|def456" "k|$today 00:00:04|ok|" \
    "k|$today 00:00:05|ok|" "b|$(date -d yesterday +%F) 23:59:59|ok|aaa111" "c|$today 00:00:02|failed|bbb222"; do
    IFS='|' read -r slug when status sha <<<"$spec"
    "$AQ" add --repeat --project game --slug "$slug" "$slug"
    "$AQ" move "$slug" done --status "$status"
    "$AQ" set "$slug" "finished=$(at "$when")" "started=$(at "$when")" "merged=$sha"
  done
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  assert_equal "$(jq -c '.recent | [.shipped_today, .checks_today]' <<<"$output")" '[1,1]'
}

@test "a slug is matched exactly, never as the tail of a longer one" {
  "$AQ" add --project game --slug x-first "x"
  "$AQ" add --project game --slug second --after first-missing "y" 2>/dev/null || true
  run "$AQ" add --project game --slug second --after first "y"
  assert_failure; assert_output --partial "no item has that slug"
  run "$AQ" cancel first
  assert_failure
  "$AQ" add --project game --slug first "f"
  run "$AQ" bump first urgent
  assert_success
  [ "$(field "$(item queued x-first)" priority)" = high ]
}

@test "a slow read works from a snapshot, so a writer goes in while it still derives holds (ar-2427)" {
  # The read stalls in its first rbw call, a hold it derives after reading the files: a fake rbw that
  # says it is in on one fifo and waits for the go on another. Events, not timing.
  mkfifo "$SANDBOX/rbw.in" "$SANDBOX/rbw.go"
  printf '#!/usr/bin/env bash\nif [ "$1" = unlocked ] && [ ! -e "%s/rbw.stalled" ]; then\n  : > "%s/rbw.stalled"; echo in > "%s/rbw.in"; read -r _ < "%s/rbw.go"\nfi\nexit 0\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/rbw-fake"
  chmod +x "$SANDBOX/rbw-fake"
  export AGENT_QUEUE_RBW="$SANDBOX/rbw-fake"
  legacy held "tags: rbw:trading/key" --project game "deploy the key" >/dev/null
  "$AQ" list --json > "$SANDBOX/read.out" 3>&- &
  READER=$!
  # Opened read-write, a fifo never blocks the open: the read's timeout and the go are the only waits,
  # so a reader that never stalls, or a fake already killed, fails the test instead of hanging it.
  read -t 10 -r _ <> "$SANDBOX/rbw.in"
  # The reader is mid-derive. A writer must not wait on it (timeout: the guard, under the 10s give-up).
  run timeout 5 "$AQ" add --project game --slug later "added while the read runs"
  assert_success
  echo go 1<> "$SANDBOX/rbw.go"
  wait "$READER"
  # The read answers from what it read before the write, hold included.
  [ "$(jq -sr 'map(.slug) | join(",")' "$SANDBOX/read.out")" = held ]
  [ "$(jq -r .hold "$SANDBOX/read.out")" = "rbw:trading/key (not in rbw yet)" ]
  run "$AQ" list --json
  [ "$(jq -sr 'map(.slug) | sort | join(",")' <<<"$output")" = held,later ]
}

@test "a waiting writer holds the gate, so overlapping reads cannot starve it" {
  "$AQ" add --project game "one item" >/dev/null
  # A read already in holds .lock shared; a writer arrives and waits on it.
  exec 7> "$AGENT_QUEUE_DIR/.lock"
  flock -s 7
  "$AQ" add --project game "two item" >/dev/null 2>&1 &
  WRITER=$!   # teardown frees it if an assert fails first
  # No event says another process took a flock, so sample it: one bounded loop, 50ms cadence.
  local i
  for i in $(seq 100); do flock -n "$AGENT_QUEUE_DIR/.gate" true || break; sleep 0.05; done
  run flock -n "$AGENT_QUEUE_DIR/.gate" true
  assert_failure
  # A new read queues behind the waiting writer instead of joining the shared hold.
  run timeout 1 "$AQ" list --json
  [ "$status" -eq 124 ]
  flock -u 7; exec 7>&-
  wait "$WRITER" || { cat "$SANDBOX/add.out"; timeout 1 cat <&6; false; }
  run "$AQ" list --json
  assert_success
  [ "$(jq -sr 'map(.slug) | sort | join(",")' <<<"$output")" = one-item,two-item ]
  # Once in, a taker drops the gate: nothing holds it after the writer is done.
  run flock -n "$AGENT_QUEUE_DIR/.gate" true
  assert_success
}

@test "a read waits for a writer, so a list never misses an item mid-move" {
  "$AQ" add --project game "one item" >/dev/null
  # Hold the writers' lock; a read must block on it, not read a half-moved store.
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  run timeout 1 "$AQ" list --json
  [ "$status" -eq 124 ]
  flock -u 9
  run "$AQ" list --json
  assert_success
  [ "$(jq -r .slug <<<"$output")" = one-item ]
  # A store that does not exist yet reads as empty and is not created by the read.
  rm -rf "$AGENT_QUEUE_DIR"
  run "$AQ" list
  assert_success
  [ ! -e "$AGENT_QUEUE_DIR" ]
}

@test "add files a repo with an owner under its owner, and set refuses the repo name" {
  run "$AQ" add --project tools --slug tool "x"
  assert_success
  [ "$(field "$(item queued tool)" project)" = cockpit ]
  run "$AQ" set tool project=tools
  assert_failure; assert_output --partial "unknown project: tools"
}

@test "add credits the sheet the item's row is on when it shares the checkout" {
  "$AQ" add --project game --from board:level:lv-3 --slug from-row "x"
  [ "$(field "$(item queued from-row)" project)" = level ]
  "$AQ" add --project tools --from board:cockpit:c-1 --slug from-owner-row "x"
  [ "$(field "$(item queued from-owner-row)" project)" = cockpit ]
  # Negative control: a row on a project in another checkout leaves the item where it was filed.
  "$AQ" add --project game --from board:app:a-1 --slug other-checkout "x"
  [ "$(field "$(item queued other-checkout)" project)" = game ]
}

@test "add --plan credits the sheet whose row code the plan's epic: line carries" {
  P="$SANDBOX/epic.md"
  printf '%s\n' '# Arena' '' 'epic: ar-12' '' '## Phases' '' '- [ ] P1 one' > "$P"
  run "$AQ" add --plan "$P" --project game --slug ep
  assert_success
  [ "$(field "$(item queued ep-p1)" project)" = arena ]
  printf '%s\n' 'epic: el-4' '## Phases' '- [ ] P1 one' > "$SANDBOX/far.md"
  "$AQ" add --plan "$SANDBOX/far.md" --project game --slug far
  [ "$(field "$(item queued far-p1)" project)" = game ]
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/none.md"
  "$AQ" add --plan "$SANDBOX/none.md" --project game --slug none
  [ "$(field "$(item queued none-p1)" project)" = game ]
}

@test "attribute credits the game that owns the most changed files and records every one touched" {
  "$AQ" add --project game --slug pr-a "x"
  run "$AQ" attribute pr-a <<<$'Assets/Arena/A.cs\nAssets/Arena/B.cs\nAssets/Level/L.cs\nAssets/Shared/S.cs'
  assert_success; assert_output "credited to arena (touches arena level)"
  f="$(item queued pr-a)"
  [ "$(field "$f" project)" = arena ]
  [ "$(field "$f" touches)" = "arena level" ]
  # A game's item stays in its repo's candidates: its own game's files can move it again.
  run "$AQ" attribute pr-a <<<'Assets/Level/L.cs'
  assert_output "credited to level (touches level)"
}

@test "attribute leaves the project on shared files, a tie, a prefix lookalike or a repo with no games" {
  "$AQ" add --project game --slug shared "x"
  run "$AQ" attribute shared <<<$'Assets/Shared/S.cs\nAssets/LevelEditor/E.cs\nProjectSettings/x.asset'
  assert_success; assert_output ''
  f="$(item queued shared)"
  [ "$(field "$f" project)" = game ]
  [ -z "$(field "$f" touches)" ]
  run "$AQ" attribute shared <<<$'Assets/Arena/A.cs\nAssets/Level/L.cs'
  assert_output "touches arena level"
  [ "$(field "$f" project)" = game ]
  "$AQ" add --project app --slug app-pr "y"
  run "$AQ" attribute app-pr <<<'Assets/Level/L.cs'
  assert_success; assert_output ''
  [ "$(field "$(item queued app-pr)" project)" = app ]
  run "$AQ" attribute nope </dev/null
  assert_failure; assert_output --partial "no item: nope"
}

@test "credit-of prints what attribute would record and writes nothing" {
  run "$AQ" credit-of game <<<$'Assets/Arena/A.cs\nAssets/Arena/B.cs\nAssets/Level/L.cs'
  assert_success; assert_output $'arena\tarena level'
  run "$AQ" credit-of game <<<$'Assets/Arena/A.cs\nAssets/Level/L.cs'
  assert_output $'\tarena level'
  run "$AQ" credit-of game <<<'Assets/Shared/S.cs'
  assert_success; assert_output ''
  # outside every tracker path, a directory named after the app is the app's
  run "$AQ" credit-of game <<<$'store/arena/listing.json\nstore/arena/art.png\nAssets/Level/L.cs\ndocs/x/arena.md'
  assert_output $'arena\tarena level'
  [ ! -e "$AGENT_QUEUE_DIR" ]
}

@test "a 1b sub-phase takes no place: items keep their phase numbers, and a 1b is read by its label" {
  plan_fixture
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --dry-run
  assert_line --regexp '^would queue my-plan-p6	phases 6	after my-plan-p4$'
  # Someone adds a 1b under the landed phase 1 after the items were queued, and phase 5 lands. By
  # position 5 would now be "4. Fourth" and 6 would be "5. Fifth", ticked: p6 would close, never worked.
  sed -i 's/^- \[x\] 1\. Landed thing: details/&\n- [x] 1b. Follow-up of phase 1 (#7)/; s/^- \[ \] 5\. Fifth/- [x] 5. Fifth/' "$SANDBOX/my-plan.md"
  # NEGATIVE CONTROL: by position this list would be [1,2,3,4,5,6,7] and p6 would read ticked.
  source "$BATS_TEST_DIRNAME/../../.local/lib/plan-phases.sh"
  [ "$(plan_phase_list "$SANDBOX/my-plan.md" | jq -c 'map(.n)')" = '[1,"1b",2,3,4,5,6]' ]
  # An open 1b is no queue item (no integer for `phases:`): it is named on stderr and skipped, and
  # phase 2 keeps its number and its place in the chain.
  printf '## Phases\n\n- [x] 1. One (#1)\n- [ ] 1b. Follow-up\n- [ ] 2. Two\n' > "$SANDBOX/sub.md"
  run "$AQ" add --plan "$SANDBOX/sub.md" --project game --slug sub --dry-run
  assert_success
  assert_output --partial "skipped open sub-phase(s) 1b"
  assert_line --regexp '^would queue sub-p2	phases 2	after -$'
  refute_output --partial "sub-p1b"
  # A stub's phase N is the line numbered N, not the Nth line.
  printf 'Phase 2 of %s/my-plan.md\n' "$SANDBOX" > "$SANDBOX/stub.md"
  [ "$(plan_session_phases "$SANDBOX/stub.md" | jq -c 'map(.name)')" = '["2. Second thing: details"]' ]
  # Names that only look like a label are phases with a place: `P2P sync`, `3D models`, `2D. Layout`.
  printf '## Phases\n\n- [ ] P2P sync\n- [ ] 3D models\n- [ ] 2D. Layout\n' > "$SANDBOX/look.md"
  [ "$(plan_phase_list "$SANDBOX/look.md" | jq -c 'map(.n)')" = '[1,2,3]' ]
}

# A phase session finds work its plan needs and adds it as a phase line (planning.md, Found work:): the add
# again keeps what is filed, files the new line once and gates the phase below it on that line's row.
@test "add --plan on a filed chain, from a dispatched phase's own session: the new phase line is filed once with its takes, and the later phase's row waits on it" {
  story_notes
  echo 20 > "$NOTES_FIXTURE/story.seq"
  P="$SANDBOX/mid.md"
  printf '# M\n\n## Phases\n\n- [x] P1 one (#1)\n- [ ] P2 two\n- [ ] P4 fix what P2 found, takes lv-50 (after 2; needs what P2 found)\n- [ ] P3 three\n' > "$P"
  "$AQ" add --running --project level --row lv-5 --slug mid-p2 "Phase 2 of the plan $P: two." >/dev/null
  "$AQ" set mid-p2 "plan=$P" phases=2 origin=run >/dev/null
  board() {
    jq -n --arg p "$P" '{rows: ([{project: "level", lane: "agent", id: "lv-9", state: "open", tags: ["after/lv-5"],
      details: ["Phase 3 of the plan \($p): three."]}, {project: "level", profile: "bnb", lane: "agent", id: "lv-50", state: "open", tags: [], details: ["the blocker"]}] + $ARGS.positional), done: []}' \
      --jsonargs "$@" > "$NOTES_FIXTURE/board.json"
  }
  board
  AGENT_QUEUE_ITEM=mid-p2 run "$AQ" add --plan "$P" --project level --priority normal --dry-run
  assert_success
  assert_line --partial 'would queue mid-p4	phases 4	after mid-p2	takes lv-50'
  assert_line 'would gate row lv-9 (mid-p3) on after/<row of mid-p4>'
  : > "$NOTES_FIXTURE/calls.log"
  AGENT_QUEUE_ITEM=mid-p2 run "$AQ" add --plan "$P" --project level --priority normal
  assert_success
  assert_output --partial "kept mid-p2, this session's own item"
  assert_output --partial "held mid-p4 -> level:lv-20"
  assert_output --partial "kept mid-p3 on its board row lv-9"
  assert_line 'gated row lv-9 (mid-p3) on after/lv-20'
  # lv-9 has no profile, so the tag call carries none (a tab-split read once shifted the lane into it).
  run grep -x 'notes ptask level --agent tag --add after/lv-20 lv-9' "$NOTES_FIXTURE/calls.log"
  assert_success
  # One row, the new phase's (held mid-p4 above), and none for the plan or the phases already filed.
  run grep -c ' add ' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # Run again with that row on the board, it files nothing twice.
  board "$(jq -nc --arg p "$P" '{project: "level", profile: "bnb", lane: "agent", id: "lv-20", state: "open", tags: ["after/lv-5"], details: ["Phase 4 of the plan \($p): fix what P2 found."]}')"
  : > "$NOTES_FIXTURE/calls.log"
  AGENT_QUEUE_ITEM=mid-p2 run "$AQ" add --plan "$P" --project level --priority normal
  assert_failure
  assert_output --partial "already queued or filed"
  run grep -c ' add \| tag ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "no writer leaves a queued item with a pending hold: a gated add, --plan, a set of tags= or after= and a move back to queued all wait on the row" {
  story_notes; gate_rbw
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  echo 1 > "$NOTES_FIXTURE/story.seq"
  # A session's add on a missing rbw item files its row with the gate and queues nothing.
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=s-1 run "$AQ" add --project level --priority low --tags rbw:infra/missing --slug key "chore(deploy): the key"
  assert_failure 5
  assert_output --partial "held key -> level:lv-1 (#rbw/infra/missing)"
  assert_called "#rbw/infra/missing"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-key.md 2>/dev/null)" ] || fail "a gated add wrote an item"
  no_held
  "$AQ" add --project level --slug base "feat(menu): base" >/dev/null
  run "$AQ" add --project level --after base --slug next "feat(menu): next"
  assert_failure 5
  no_held
  printf '# P\n\n## Phases\n\n- [ ] one\n- [ ] two\n- [ ] three\n' > "$SANDBOX/inv.md"
  run "$AQ" add --plan "$SANDBOX/inv.md" --project level
  assert_success
  no_held
  # Its tails wait on their rows, so the same add again refuses rather than file them twice. Negative
  # control: a row naming the plan with no gate (an un-started return) holds no phase, so the add files them.
  printf '{"rows":[{"project":"level","id":"lv-8","state":"open","tags":["after/lv-7"],"details":["Phase 2 of the plan %s: two."]},{"project":"level","id":"lv-9","state":"open","tags":["after/lv-8"],"details":["Phase 3 of the plan %s: three."]}],"done":[]}\n' "$SANDBOX/inv.md" "$SANDBOX/inv.md" > "$NOTES_FIXTURE/board.json"
  run "$AQ" add --plan "$SANDBOX/inv.md" --project level
  assert_failure; assert_output --partial "already queued or filed: inv-p1, rows lv-8 lv-9"
  sed -i 's/"after\/lv-8"/"size\/s"/' "$NOTES_FIXTURE/board.json"
  run "$AQ" add --plan "$SANDBOX/inv.md" --project level
  assert_success; assert_output --partial "held inv-p3 -> "
  rm "$NOTES_FIXTURE/board.json"
  # A set that gives a queued item a gate returns it to its row; one with no row is refused unwritten.
  "$AQ" add --project level --slug other "feat(menu): other" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" set other "tags=rbw:infra/missing"
  assert_success
  assert_called "--add rbw/infra/missing"
  [ -z "$(item queued other 2>/dev/null)" ]
  no_held
  "$AQ" add --project level --slug last "feat(menu): last" >/dev/null
  run "$AQ" set last after=base
  assert_success
  [ -z "$(item queued last 2>/dev/null)" ]
  no_held
  "$AQ" add --project game --slug bare "bare" >/dev/null
  run "$AQ" set bare "tags=rbw:infra/missing"
  assert_failure; assert_output --partial "bare has no board row to wait on its gate"
  [ -z "$(field "$(item queued bare)" tags)" ]
  no_held
  # A move back to queued (reap's requeue of a gone session) of an item that now waits sends it to its
  # row with the gate; one with no row is refused and stays where it was.
  "$AQ" add --project level --slug mv "feat(menu): moved" >/dev/null
  "$AQ" move mv running >/dev/null
  "$AQ" set mv "tags=rbw:infra/missing" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move mv queued --if running
  assert_success
  assert_called "--add rbw/infra/missing"
  [ -z "$(item queued mv 2>/dev/null)" ] && [ -z "$(item running mv 2>/dev/null)" ]
  no_held
  "$AQ" move bare running >/dev/null
  "$AQ" set bare "tags=rbw:infra/missing" >/dev/null
  run "$AQ" move bare queued
  assert_failure; assert_output --partial "give it a board row"
  [ -n "$(item running bare)" ]
  no_held
  # Negative control: a legacy item written past the writers is what no_held catches.
  legacy old "tags: rbw:infra/missing" --project game "old"
  run no_held
  assert_failure; assert_output --partial "old: "
}

@test "a canary item files no story row, and --from takes only the known origins, research:<facet> among them" {
  story_notes
  run "$AQ" add --project level --from canary --tags canary --slug c1 "check(canary): greet 2026w45"
  assert_success
  refute_output --partial 'story'
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  [ "$(field "$(item queued c1)" from)" = canary ]
  run "$AQ" add --project game --from research:dotfiles-hooks --slug r1 "research(dotfiles-hooks): look"
  assert_success
  [ "$(field "$(item queued r1)" from)" = research:dotfiles-hooks ]
  run "$AQ" add --project game --from robot --slug c2 "x"
  assert_failure
  assert_output --partial 'human, session, shepherd, canary, trainee, research:<facet>, auto:<filer>, item:<slug>, ask:<id> or board'
  run "$AQ" add --project game --from research: --slug c3 "x"
  assert_failure
}

@test "add files a started story row under the item's epic and links it as row:" {
  story_notes
  run "$AQ" add --project game --epic lv-3 --priority low --slug menus "feat(menu): live main menus #night"
  assert_success
  assert_line "story lv-9 on the level agent board, under lv-3"
  run grep '^notes --profile' "$NOTES_FIXTURE/calls.log"
  assert_line --index 0 'notes --profile bnb ptask level --agent propose -- feat(menu): live main menus'
  assert_line --index 1 'notes --profile bnb ptask level --agent add --origin agent-queue -- feat(menu): live main menus #low #of/lv-3'
  assert_line --index 2 'notes --profile bnb ptask level --agent start lv-9'
  f="$(item queued menus)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" row)" = level:lv-9 ]
  [ "$(field "$f" lane)" = agent ]
  [ "$(field "$f" profile)" = bnb ]
  [ "$(jq -r .row <<<"$("$AQ" show menus --json)")" = level:lv-9 ]
}

@test "list joins the item's board row: its points and size band, in --json and as an m/5 column" {
  story_notes
  "$AQ" add --project game --epic lv-3 --slug menus "feat(menu): live main menus" >/dev/null
  "$AQ" add --project game --slug bare --from human "chore(x): no row of its own" >/dev/null
  # The row the item works scores 5 points, band m; the other item's row is unscored.
  echo '{"rows":[{"project":"level","id":"lv-9","points":5,"size":"m"}],"done":[]}' > "$NOTES_FIXTURE/board.json"
  run "$AQ" list --json --points
  assert_success
  [ "$(jq -r 'select(.slug == "menus") | "\(.size)/\(.points)"' <<<"$output")" = m/5 ]
  run "$AQ" list
  assert_line --regexp '^queued	.*	menus	.*	m/5$'
  # NEGATIVE CONTROLS: --json without --points never reads the board; with no board feed the list is still the queue.
  run "$AQ" list --json
  assert_success
  [ "$(jq -r 'select(.slug == "menus") | .points // "none"' <<<"$output")" = none ]
  rm "$NOTES_FIXTURE/board.json"
  run "$AQ" list --json --points
  assert_success
  [ "$(jq -r 'select(.slug == "menus") | .points // "none"' <<<"$output")" = none ]
  run "$AQ" list
  assert_line --regexp '^queued	.*	menus	.*	-$'
}

@test "add files the story row with no #size/: the nightly --backlog --size pass scores it" {
  story_notes
  run "$AQ" add --project game --epic lv-3 --slug light --weight light "feat(menu): a light one"
  assert_success
  run "$AQ" add --project game --epic lv-3 --slug heavy --weight heavy "feat(menu): a heavy one"
  assert_success
  run grep -c '#size/' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

# The row's section follows the item (Now while it runs, Next up once requeued), so every move to
# running marks the row and a move back to queued unmarks it; waiting keeps the mark, and an item
# with no row writes nothing (the negative control).
@test "a move to running marks the item's row run, back to queued starts it again, waiting leaves it" {
  story_notes
  "$AQ" add --project game --epic lv-3 --slug menus "feat(menu): live main menus" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" move menus running >/dev/null
  "$AQ" move menus waiting >/dev/null
  "$AQ" move menus queued >/dev/null
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent run lv-9
notes --profile bnb ptask level --agent start lv-9'
  # Added already running, its story row is marked as soon as it is filed.
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project game --epic lv-3 --running --slug live "feat(menu): live now" >/dev/null
  run grep -c ' ptask level --agent run lv-9$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # A row the write cannot reach warns, and the move stands.
  touch "$NOTES_FIXTURE/run.rc"
  "$AQ" move live queued >/dev/null
  run "$AQ" move live running
  assert_success
  assert_output --partial 'not marked run'
  [ -n "$(item running live)" ]
  # No row, no write.
  "$AQ" add --project game --from canary --slug norow "check(canary): x" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" move norow running >/dev/null
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

# tr-71 and tr-129: added by hand with --from board:, their rows were never marked, so the merge left
# them open (merged_open_rows).
@test "an item promoted from a board row (from: board:, no row:) marks that row run like a row: item" {
  story_notes
  "$AQ" add --project game --from board:level:lv-4 --slug promoted "fix(menu): promoted" >/dev/null
  [ -z "$(field "$(item queued promoted)" row)" ] || fail "the fixture needs an item with no row: line"
  "$AQ" set promoted profile=bnb lane=agent >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" move promoted running >/dev/null
  "$AQ" move promoted queued >/dev/null
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent run lv-4
notes --profile bnb ptask level --agent start lv-4'
}

# ar-1597: an item re-pointed with set row= left its first row started with no item, which read as
# board_orphan_started until the orphan pass.
@test "set row= or from=board: un-starts the row the item leaves and marks the one it works now" {
  story_notes
  "$AQ" add --project game --epic lv-3 --slug repoint "feat(menu): repoint" >/dev/null
  [ "$(field "$(item queued repoint)" row)" = level:lv-9 ]
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" set repoint row=level:lv-2
  assert_success; assert_output --partial "board row lv-9 on level un-started"
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent unstart lv-9
notes --profile bnb ptask level --agent start lv-2'
  # The same row again writes nothing.
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set repoint row=level:lv-2 >/dev/null
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # The left row is un-started on the profile and lane it was on, even when the set moves both.
  "$AQ" move repoint running >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set repoint row=level:lv-8 profile=work lane=human >/dev/null
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent unstart lv-2
notes --profile work ptask level run lv-8'
  # A failed un-start warns with the command; the set stands and succeeds.
  printf '#!/usr/bin/env bash\n[[ " $* " != *" unstart "* ]]\n' > "$SANDBOX/bin/notes"
  run "$AQ" set repoint row=level:lv-1
  assert_success; assert_output --partial "left board row lv-8 on level, not un-started"
  [ "$(field "$(item running repoint)" row)" = level:lv-1 ]
  story_notes
  # A board-promoted item re-pointed by from= leaves its row the same way.
  "$AQ" add --project game --from board:level:lv-4 --slug promoted "fix(menu): promoted" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set promoted from=board:level:lv-6 >/dev/null
  run grep -c 'ptask level --agent unstart lv-4$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # A row another active item works stays started.
  "$AQ" add --project game --from board:level:lv-5 --slug holder "fix(menu): holder" >/dev/null
  "$AQ" set promoted from=board:level:lv-5 >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set promoted from=board:level:lv-7 >/dev/null
  run grep -c ' unstart ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A done item's rows are its close's business.
  "$AQ" move promoted done --status failed >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set promoted from=board:level:lv-3 >/dev/null
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "an item closed ok with no PR closes its row on the item; one with a PR leaves it to agent-land" {
  story_notes
  "$AQ" add --project game --epic lv-3 --slug menus "feat(menu): live main menus" >/dev/null
  "$AQ" move menus running >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move menus done --status ok
  assert_success
  assert_line 'menus: board row lv-9 closed'
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent done lv-9 --proof item:menus'
  # a board-promoted item, no profile: notes finds the project's own
  "$AQ" add --project game --from board:game:gm-7 --running --slug promoted "fix(x): y" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move promoted done --status ok
  assert_line 'promoted: board row gm-7 closed'
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes ptask game --agent done gm-7 --proof item:promoted'
  # NEGATIVE CONTROL: a merged PR's row is agent-land's, closed on the merge
  "$AQ" add --project game --epic lv-3 --running --slug landed "feat(menu): b" >/dev/null
  "$AQ" set landed pr=o/r#4 merged=abc123 >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move landed done --status ok
  assert_success
  refute_output --partial 'board row'
  run grep -c ' ptask .* done ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # and failed or cancelled leaves it to fleet-dispatch settle_row
  "$AQ" add --project game --epic lv-3 --running --slug lost "feat(menu): c" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move lost done --status failed
  run grep -c ' ptask .* done ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a row already closed stays quiet on an ok close; one the close missed, or a board that cannot be read, is named on stderr" {
  story_notes
  touch "$NOTES_FIXTURE/done.rc"
  # lv-90 is another row: the open rows are read by id, not by substring
  printf -- '- [/] docs(menu): z <!-- id:lv-90 -->\n' > "$NOTES_FIXTURE/list.out"
  "$AQ" add --project game --epic lv-3 --running --slug doc "docs(menu): a" >/dev/null
  run "$AQ" move doc done --status ok
  assert_success
  refute_output --partial 'board row'
  "$AQ" add --project game --epic lv-3 --running --slug stuck "docs(menu): b" >/dev/null
  printf -- '- [/] docs(menu): b <!-- id:lv-9 -->\n' > "$NOTES_FIXTURE/list.out"
  run "$AQ" move stuck done --status ok
  assert_success
  assert_output --partial 'agent-queue: stuck is done, but its board row lv-9 on level may still be open (no open task matches): notes --profile bnb ptask level --agent done lv-9 --proof item:stuck'
  touch "$NOTES_FIXTURE/list.rc"
  "$AQ" add --project game --epic lv-3 --running --slug blind "docs(menu): c" >/dev/null
  run "$AQ" move blind done --status ok
  assert_success
  assert_output --partial 'agent-queue: blind is done, but its board row lv-9 on level may still be open'
}

@test "a want's channel reaches the story row's writer only when --want names it" {
  story_notes
  run "$AQ" add --project game --epic lv-3 --slug voiced --want voice "feat(menu): a"
  assert_success
  run "$AQ" add --project game --epic lv-3 --slug own --from human "feat(menu): c"
  assert_success
  run grep 'ptask level --agent add' "$NOTES_FIXTURE/calls.log"
  assert_line --index 0 --partial 'add --want voice -- feat(menu): a #high #of/lv-3'
  assert_line --index 1 'notes --profile bnb ptask level --agent add --origin agent-queue -- feat(menu): c #high #of/lv-3'
}

@test "--want is refused with --plan: plan items are agent-made and carry no channel" {
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/w.md"
  run "$AQ" add --plan "$SANDBOX/w.md" --project game --slug wp --want voice
  assert_failure
  assert_output --partial '--want names a human'
}

@test "a plan item's story takes the plan's epic and a heavy item is sized m" {
  story_notes
  printf '%s\n' 'epic: lv-3' '## Phases' '- [ ] P1 one' > "$SANDBOX/lv.md"
  echo 'feat(level): one (P1)' > "$NOTES_FIXTURE/propose.out"
  run "$AQ" add --plan "$SANDBOX/lv.md" --project game --weight heavy --slug lvp
  assert_success
  run grep -c -- '--agent propose -- one (P1)$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -c -- "--agent add --detail=Phase 1 of the plan $SANDBOX/lv.md: one\. .* -- feat(level): one (P1) #high #of/lv-3$" "$NOTES_FIXTURE/calls.log"
  assert_output 1
  [ "$(field "$(item queued lvp-p1)" row)" = level:lv-9 ]
}

@test "an epic of another project is not linked, and a long title becomes the row's detail" {
  story_notes
  long="fix(menu): $(printf 'word%.0s ' {1..20})end"
  echo 'fix(menu): word word' > "$NOTES_FIXTURE/propose.out"
  "$AQ" add --project level --epic el-3 --slug far-epic -- "$long"
  run grep -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "--agent add --detail=$long --origin agent-queue -- fix(menu): word"
  refute_output --partial '#of/'
  [ "${#long}" -gt 80 ]
}

@test "the story row holds the item's whole body as its brief, less a first line that is the row's own words" {
  story_notes
  "$AQ" add --project level --slug multi -- $'feat(menu): the title screen\ngoal: one record\n  - nested'
  run cat "$NOTES_FIXTURE/calls.log"
  assert_output --partial $'--agent add --detail=goal: one record\n  - nested --origin agent-queue -- feat(menu): the title screen #high'
  # a --title that is not the body's first line keeps the body whole
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project level --slug titled --title "feat(menu): a short title" -- $'Phase 2 of the plan: do it\nthen land it'
  run cat "$NOTES_FIXTURE/calls.log"
  assert_output --partial $'--agent add --detail=Phase 2 of the plan: do it\nthen land it --origin agent-queue -- feat(menu): a short title #high'
  # NEGATIVE CONTROL: a one-line task that is the row's words writes no brief
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project level --slug one "feat(menu): one line"
  run grep -c -- '--detail' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "an open twin row is linked, and started only when no item has started it" {
  story_notes
  echo 3 > "$NOTES_FIXTURE/story.rc"
  echo 'already open on /x/agent/README.md: - [ ] feat(menu): twin #size/s <!-- id:lv-4 -->' > "$NOTES_FIXTURE/story.out"
  run "$AQ" add --project level --slug twin "feat(menu): twin"
  assert_success
  [ "$(field "$(item queued twin)" row)" = level:lv-4 ]
  run grep -c -- '--agent start lv-4' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  echo 'already open on /x/agent/README.md: - [/] feat(menu): taken <!-- id:lv-5 -->' > "$NOTES_FIXTURE/story.out"
  "$AQ" add --project level --slug taken "feat(menu): taken"
  [ "$(field "$(item queued taken)" row)" = level:lv-5 ]
  run grep -c -- '--agent start lv-5' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "--tags interrupt puts #interrupt on the row it files and on an open twin it links; other tags do not" {
  story_notes
  "$AQ" add --project level --slug hot --tags "research interrupt" "feat(menu): hot" >/dev/null
  run grep -c -- '-- feat(menu): hot #high #interrupt$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  echo 3 > "$NOTES_FIXTURE/story.rc"
  echo 'already open on /x/agent/README.md: - [ ] feat(menu): twin <!-- id:lv-4 -->' > "$NOTES_FIXTURE/story.out"
  "$AQ" add --project level --slug twin --tags "#interrupt" "feat(menu): twin" >/dev/null
  run grep -c -- '--agent tag --add interrupt lv-4' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # NEGATIVE CONTROL: a row without the tag gets no interrupt
  : > "$NOTES_FIXTURE/calls.log"
  rm "$NOTES_FIXTURE/story.rc"
  "$AQ" add --project level --slug cold --tags research "feat(menu): cold" >/dev/null
  run grep -c -- 'interrupt' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a re-queue links its last item's open row by id, whatever its words; a closed one gets a new row" {
  story_notes
  "$AQ" add --project level --slug again "feat(menu): first words" >/dev/null
  "$AQ" move again done --status failed >/dev/null
  # The row was written before rows were typed: no text the new add proposes would match it.
  echo 'feat(menu): other words entirely' > "$NOTES_FIXTURE/propose.out"
  run "$AQ" add --project level --slug again "feat(menu): first words"
  assert_success
  assert_line "story lv-9 on the level agent board"
  [ "$(field "$(item queued again)" row)" = level:lv-9 ]
  [ "$(field "$(item queued again)" profile)" = bnb ]
  run grep -c -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -c -- '--agent start lv-9$' "$NOTES_FIXTURE/calls.log"
  assert_output 2
  # negative control: a repeat after an ok close finds its row done, so it files a new one
  "$AQ" move again done --status ok >/dev/null
  touch "$NOTES_FIXTURE/closed.lv-9"
  run "$AQ" add --project level --slug again --repeat "feat(menu): first words"
  assert_success
  run grep -c -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output 2
}

@test "a notes that cannot type the words files no row and never stops the add" {
  story_notes
  touch "$NOTES_FIXTURE/propose.rc"
  run "$AQ" add --project level --slug no-verb "x"
  assert_success
  assert_output --partial "no story row filed on level: error: unrecognized subcommand 'propose'"
  [ -z "$(field "$(item queued no-verb)" row)" ]
  run grep -c -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a failed story write never stops the add: the item is written with no row" {
  story_notes
  echo 1 > "$NOTES_FIXTURE/story.rc"
  echo 'error: no such project' > "$NOTES_FIXTURE/story.out"
  run "$AQ" add --project level --slug no-sheet "x"
  assert_success
  assert_output --partial "no story row filed on level: error: no such project"
  [ -z "$(field "$(item queued no-sheet)" row)" ]
  # an item whose row: line is empty has no row to a reader, not the row "" (ar-1551)
  sed -i 's/^agent: /row: \nagent: /' "$(item queued no-sheet)"
  [ "$(grep -c '^row: $' "$(item queued no-sheet)")" = 1 ]
  run jq -sc '[.[] | select(.slug == "no-sheet") | has("row")]' <<<"$("$AQ" list --json --state all)"
  assert_output '[false]'
}

@test "--row links an open board row and starts it: no second row, and from: stays the origin" {
  story_notes
  run "$AQ" add --running --project game --row lv-2 --slug by-hand "feat(menu): the row's work"
  assert_success
  assert_line "story lv-2 on the level agent board"
  f="$(item running by-hand)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" row)" = level:lv-2 ]
  [ "$(field "$f" lane)" = agent ]
  [ "$(field "$f" profile)" = bnb ]
  [ "$(field "$f" from)" = human ]
  run grep '^notes --profile' "$NOTES_FIXTURE/calls.log"
  assert_output "$(printf '%s\n' 'notes --profile bnb ptask level --agent start lv-2' 'notes --profile bnb ptask level --agent run lv-2')"
}

@test "--row refuses an id that is not an open row, a row a live item names and a project with no board, writing nothing" {
  story_notes
  touch "$NOTES_FIXTURE/closed.lv-7"
  run "$AQ" add --project game --row lv-7 --slug shut "x"
  assert_failure; assert_output --partial "--row lv-7: not an open row on the level agent board: no open task matches"
  [ -z "$(item queued shut)" ]
  "$AQ" add --project game --row lv-2 --slug first "x"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project game --row lv-2 --slug second "y"
  assert_failure; assert_output --partial "--row lv-2: first already works that row; to take it over: agent-queue claim first"
  [ -z "$(item queued second)" ]
  run grep -c ' start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  run "$AQ" add --project elsewhere --row el-1 --slug no-board "z"
  assert_failure; assert_output --partial "--row el-1: elsewhere has no agent board"
  [ -z "$(item queued no-board)" ]
}

@test "--row links a row moved to the caller's game, which its code no longer names; open on neither is refused" {
  story_notes
  # ar-9 was moved from arena to level: it keeps its id, so the code sheet (arena) no longer has it.
  touch "$NOTES_FIXTURE/closed.arena.ar-9"
  run "$AQ" add --project level --row ar-9 --slug moved "x"
  assert_success
  assert_line "story ar-9 on the level agent board"
  f="$(item queued moved)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" row)" = level:ar-9 ]
  # Negative control: a row still on its code's sheet links there, whichever game the caller named.
  run "$AQ" add --project level --row ar-8 --slug by-code "y"
  assert_success
  [ "$(field "$(item queued by-code)" row)" = arena:ar-8 ]
  touch "$NOTES_FIXTURE/closed.arena.ar-7" "$NOTES_FIXTURE/closed.level.ar-7"
  run "$AQ" add --project level --row ar-7 --slug nowhere "z"
  assert_failure; assert_output --partial "--row ar-7: not an open row on the arena agent board"
  [ -z "$(item queued nowhere)" ]
}

@test "a title whose subject is one open row works that row; a mention, a closed row, two ids or an --epic file a story as before" {
  story_notes
  run "$AQ" add --running --project game --slug named "fix(menu): close it for good (lv-2)"
  assert_success
  assert_output --partial "named works row lv-2, which its title names"
  [ "$(field "$(item running named)" row)" = level:lv-2 ]
  run grep -c ' add ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # NEGATIVE CONTROLS: each of these files its own story (the stub mints lv-9).
  touch "$NOTES_FIXTURE/closed.lv-7"
  "$AQ" add --project level --slug said "fix(menu): redo the layout after lv-3 lands"
  [ "$(field "$(item queued said)" row)" = level:lv-9 ]
  "$AQ" add --project level --slug shut "lv-7: fix the menu again"
  [ "$(field "$(item queued shut)" row)" = level:lv-9 ]
  "$AQ" add --project level --slug two "lv-3: fix(menu) beside (lv-4)"
  [ "$(field "$(item queued two)" row)" = level:lv-9 ]
  "$AQ" add --project level --epic lv-5 --slug epic "feat(menu): under its epic (lv-3)"
  [ "$(field "$(item queued epic)" row)" = level:lv-9 ]
  run grep -c ' start lv-3' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "--row takes one row id, on one item, with no story options" {
  story_notes
  : > "$NOTES_FIXTURE/calls.log"
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/p.md"
  run "$AQ" add --plan "$SANDBOX/p.md" --project game --row lv-2
  assert_failure; assert_output --partial "--row links one item"
  run "$AQ" add --project game --row menus --slug a "x"
  assert_failure; assert_output --partial "--row is a row id"
  run "$AQ" add --project game --row lv-2 --epic lv-3 --slug b "x"
  assert_failure; assert_output --partial "--row links a row already filed"
  run "$AQ" add --project game --row lv-2 --from board:level:lv-2 --slug c "x"
  assert_failure; assert_output --partial "not --from board:level:lv-2"
  run grep -c ' start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a board item and a project with no lab sheet file no story; a board item's row is its origin" {
  story_notes
  "$AQ" add --project game --from board:level:lv-2 --slug promoted "x"
  "$AQ" add --project game --slug no-lab "y"
  # The item's own chain event is the one notes call.
  run grep -c '^notes ptask' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  [ "$(jq -r .row <<<"$("$AQ" show promoted --json)")" = level:lv-2 ]
  [ "$(jq -r '.row // "none"' <<<"$("$AQ" show no-lab --json)")" = none ]
  run "$AQ" add --project game --epic menus --slug bad "z"
  assert_failure; assert_output --partial "--epic is a row id"
}

# A repo with no sheet of its own names the board it files on (dotfiles-private -> agent-runtime): the
# item stays on its own project and checkout, and its row lives on that board. NEGATIVE CONTROL: before
# the board key, app filed nothing and --row on it was refused.
@test "a project with no sheet files its story and links --row on the board its board key names" {
  story_notes
  jq '.trackers.app.board = "level"' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m.json" && mv "$SANDBOX/m.json" "$AGENT_QUEUE_PROJECT_MAP"
  run "$AQ" add --project app --slug overlay "fix(hooks): the overlay's work"
  assert_success
  assert_line "story lv-9 on the level agent board"
  f="$(item queued overlay)"
  [ "$(field "$f" project)" = app ]
  [ "$(field "$f" row)" = level:lv-9 ]
  [ "$(field "$f" profile)" = bnb ]
  run grep '^notes --profile' "$NOTES_FIXTURE/calls.log"
  assert_line --index 1 "notes --profile bnb ptask level --agent add --origin agent-queue -- fix(hooks): the overlay's work #high"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --running --project app --row lv-2 --slug linked "x"
  assert_success
  assert_line "story lv-2 on the level agent board"
  [ "$(field "$(item running linked)" row)" = level:lv-2 ]
  [ "$(field "$(item running linked)" project)" = app ]
  run "$AQ" add --project app --row lv-2 --slug twice "y"
  assert_failure; assert_output --partial "--row lv-2: linked already works that row"
  "$AQ" move linked done --status ok >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project app --slug linked --repeat "again"
  assert_success
  assert_line "story lv-2 on the level agent board"
  run grep -c ' add ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "every item write appends one queue event naming the item, its row and its PR" {
  story_notes
  "$AQ" add --project game --from board:level:lv-2 --slug chain "x" >/dev/null
  "$AQ" set chain pr=o/r#7 merged=0123abcd >/dev/null
  "$AQ" move chain running >/dev/null
  "$AQ" move chain done --status ok >/dev/null
  "$AQ" add --project game --from board:level:lv-3 --slug gone "y" >/dev/null
  "$AQ" cancel gone >/dev/null
  run grep -o 'ingest record --stage queue --action [a-z-]* --from level --item [a-z]* --id [a-z0-9-]*' "$NOTES_FIXTURE/calls.log"
  assert_output - <<'OUT'
ingest record --stage queue --action item-added --from level --item chain --id lv-2
ingest record --stage queue --action item-set --from level --item chain --id lv-2
ingest record --stage queue --action item-moved --from level --item chain --id lv-2
ingest record --stage queue --action item-moved --from level --item chain --id lv-2
ingest record --stage queue --action item-added --from level --item gone --id lv-3
ingest record --stage queue --action item-cancelled --from level --item gone --id lv-3
OUT
  run grep -c -- '--action item-moved .*--pr o/r#7 .*--to done --why running -> done (ok)' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "an item write never fails on its event: a notes that cannot record leaves the write standing" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$AQ" add --project game --from board:level:lv-2 --slug sturdy "fix(x): y"
  assert_success
  assert_output --partial "notes row parse failed, so sturdy is untyped"
  [ -z "$(field "$(item queued sturdy)" type)" ]
  # Its row (from: board:) is marked too; that write failing warns and the move stands (mark_row).
  run "$AQ" move sturdy running
  assert_success
  assert_line --index 0 "sturdy: queued -> running"
  assert_output --partial "board row lv-2 on level not marked run"
  [ -n "$(item running sturdy)" ]
}

@test "the cap holds an add over it: no item, its board row left un-started with the whole brief, the hold logged" {
  story_notes
  export AGENT_QUEUE_CAP=2
  "$AQ" add --project level --slug one "feat(menu): one" >/dev/null
  "$AQ" add --project level --slug two "feat(menu): two" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --slug three "feat(menu): three
second line of the brief
- [ ] a step"
  assert_failure 5
  assert_output --partial "held by admission, nothing was queued: 2 items can start now against a cap of 2 (human)"
  assert_output --partial "its board row lv-9 on level is left un-started"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-three.md 2>/dev/null)" ] || fail "a held add wrote an item"
  # the brief is one value of several lines, less the row's own words; notes escapes the step
  assert_called "ptask level --agent add --detail=second line of the brief"
  assert_called "- [ ] a step -- feat(menu): three #high"
  run grep -c ' ptask level --agent start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  run jq -c '{from, slug, runnable, limit}' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output '{"from":"human","slug":"three","runnable":2,"limit":2}'
  # A gated add files its row and queues nothing, so it takes no room.
  "$AQ" cancel one >/dev/null
  run "$AQ" add --project level --slug later --after two "feat(menu): later"
  assert_failure 5
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-later.md 2>/dev/null)" ]
  run "$AQ" add --project level --slug three "feat(menu): three"
  assert_success
}

@test "an over-cap add that names --row files no second row, and a short task under a different --title keeps its words" {
  story_notes
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project level --slug one "feat(menu): one" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --row lv-2 --slug named "feat(menu): named"
  assert_failure 5
  assert_output --partial "row lv-2 is left un-started where it is"
  run grep -c ' ptask level --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  run "$AQ" add --project level --slug titled --title "feat(menu): the title" "the real wording of the task"
  assert_failure 5
  assert_called "--detail=the real wording of the task -- "
}

@test "an over-cap board pull files no second row beside the row it was promoted from" {
  story_notes
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project level --slug one "feat(menu): one" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run env AGENT_QUEUE_PULL=dispatch "$AQ" add --project level --from board:level:lv-3 --slug lv-3 --title "feat(menu): pulled" "feat(menu): pulled"
  assert_failure 5
  assert_output --partial "row lv-3 is left un-started where it is"
  run grep -c ' ptask level --agent \(add\|propose\) ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-lv-3.md 2>/dev/null)" ] || fail "a held board pull wrote an item"
}

@test "an over-cap add that is #requested files its row with --want, so it ranks first on the board" {
  story_notes
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project level --slug one "feat(menu): one" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --tags '#requested' --slug asked "feat(menu): asked"
  assert_failure 5
  assert_called "ptask level --agent add --want human -- feat(menu): asked #high"
}

@test "a project with no board gets the command to file by hand, nothing written, and a machine filer is held the same" {
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --slug held "held"
  assert_failure 5
  assert_output --partial "game has no board row to file this on: notes ptask game --agent add"
  run "$AQ" add --project game --from research:costs --slug machine-b "machine b"
  assert_failure 5
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-held.md "$AGENT_QUEUE_DIR"/queued/*-machine-b.md 2>/dev/null)" ] || fail "a held add wrote an item"
}

@test "at the cap an urgent or red add returns the last-ranked item that has a row, never the human's, urgent work or a chain head; with none it is held" {
  # The human, 2026-11-18: urgent must not skip the cap; it pushes out something less critical.
  "$AQ" add --project game --from shepherd --slug a "a" >/dev/null
  "$AQ" add --project game --priority low --slug h "the human's" >/dev/null
  "$AQ" add --project game --from shepherd --priority low --tags '#requested' --slug req "asked for" >/dev/null
  "$AQ" add --project game --from shepherd --priority low --slug head "chain head" >/dev/null
  legacy tail "after: head" --project game --from shepherd --priority low "chain tail"
  "$AQ" add --project game --from shepherd --priority low --slug b "b" >/dev/null
  for s in a req head b; do "$AQ" set "$s" row="game:gm-$s" >/dev/null; done
  export AGENT_QUEUE_CAP=6
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u1 "urgent one"
  assert_success
  assert_output --partial "returned b to its board row to make room for urgent u1 under the cap of 6"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-b.md)" end_reason)" = returned ]
  assert_called "ptask game --agent unstart gm-b"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority high --tags red --slug r1 "red one"
  assert_success
  assert_output --partial "returned a to its board row"
  # Negative controls: what is left is the human's, #requested, a chain head and urgent or red work.
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u2 "urgent two"
  assert_failure 5
  assert_output --partial "held by admission, nothing was queued: 6 items can start now against a cap of 6"
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "h,head,r1,req,tail,u1"
  run "$AQ" admission --json
  assert_equal "$(jq -c '[.held_7d, .returned_7d]' <<<"$output")" '[1,2]'
  assert_equal "$(jq -c '[.day.held, .day.why.cap, .day.why.returned]' <<<"$output")" '[1,1,null]'
  run jq -r 'select(.why == "returned") | .slug' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output "b
a"
}

@test "at the cap pull-after's pull of a row an ok close cleared returns the last-ranked item; dispatch's own pull is held" {
  # 2026-11-20 (chain-after-stuck): hc-551, ar-3027 and ar-3662 were pulled at the cap, held, and sat on
  # the backlog tier no pass takes.
  "$AQ" add --project game --from shepherd --slug a "a" >/dev/null
  "$AQ" add --project game --from shepherd --priority low --slug b "b" >/dev/null
  for s in a b; do "$AQ" set "$s" row="game:gm-$s" >/dev/null; done
  export AGENT_QUEUE_CAP=2
  # Negative control: the same row from dispatch's pass is held, and nothing is returned.
  AGENT_QUEUE_PULL=dispatch run "$AQ" add --project game --priority low --from board:game:gm-9 --slug gm-9 "feat(game): the doors"
  assert_failure 5
  refute_output --partial "returned"
  AGENT_QUEUE_PULL=after run "$AQ" add --project game --priority low --from board:game:gm-9 --slug gm-9 "feat(game): the doors"
  assert_success
  assert_output --partial "returned b to its board row to make room for low gm-9 under the cap of 2"
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "a,gm-9"
  # A low pull never returns the high item a; and a sibling the same pull-after queued (AQ_ROOM_KEEP) is
  # never returned for the next, so both are held.
  AQ_ROOM_KEEP=" gm-9" AGENT_QUEUE_PULL=after run "$AQ" add --project game --priority low --from board:game:gm-8 --slug gm-8 "feat(game): the hinges"
  assert_failure 5
  refute_output --partial "returned a"
  AQ_ROOM_KEEP=" gm-9" AGENT_QUEUE_PULL=after run "$AQ" add --project game --priority high --from board:game:gm-7 --slug gm-7 "feat(game): the locks"
  assert_success
  assert_output --partial "returned a to its board row"
  AQ_ROOM_KEEP=" gm-9 gm-7" AGENT_QUEUE_PULL=after run "$AQ" add --project game --priority high --from board:game:gm-6 --slug gm-6 "feat(game): the bolts"
  assert_failure 5
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "gm-7,gm-9"
}

@test "at the cap a low pull or an urgent add never returns a phase of a plan chain; the plain item goes" {
  # 2026-11-23 (ar-5357): P2 and P3 of a plan went back to their rows for low ar-4852 and urgent
  # bar-139, and the chain stopped there.
  printf '# P\n\n## Phases\n\n- [ ] one\n- [ ] two\n' > "$SANDBOX/plan.md"
  # b goes in first, so it ranks before the phases and the last-ranked item is a phase.
  "$AQ" add --project game --from shepherd --priority low --slug b "b" >/dev/null
  "$AQ" add --project game --from shepherd --priority low --slug p2 "feat(game): P2
Phase 2 of the plan $SANDBOX/plan.md: the doors." >/dev/null
  legacy p3 "plan: $SANDBOX/plan.md" --project game --from shepherd --priority low "feat(game): P3"
  for s in p2 p3 b; do "$AQ" set "$s" row="game:gm-$s" >/dev/null; done
  export AGENT_QUEUE_CAP=3
  AGENT_QUEUE_PULL=after run "$AQ" add --project game --priority low --from board:game:gm-9 --slug gm-9 "feat(game): the hinges"
  assert_success
  assert_output --partial "returned b to its board row to make room for low gm-9 under the cap of 3"
  # What is left is the two phases and gm-9, a sibling of this pull-after (AQ_ROOM_KEEP): all held.
  AQ_ROOM_KEEP=" gm-9" AGENT_QUEUE_PULL=after run "$AQ" add --project game --priority low --from board:game:gm-8 --slug gm-8 "feat(game): the locks"
  assert_failure 5
  refute_output --partial "returned p"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u1 "urgent one"
  assert_success
  assert_output --partial "returned gm-9 to its board row"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u2 "urgent two"
  assert_failure 5
  refute_output --partial "returned p"
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "p2,p3,u1"
}

@test "make_room returns an item held to a clock time, moves nothing for an add the lock refuses, and never returns an item that started" {
  "$AQ" add --project game --priority low --slug h "the human's" >/dev/null
  legacy n "tags: at:23:59" --project game --from shepherd --priority low "tonight"
  "$AQ" set n row=game:gm-n >/dev/null
  export AGENT_QUEUE_CAP=2
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u1 "urgent one"
  assert_success
  assert_output --partial "returned n to its board row"
  AGENT_QUEUE_CAP=0 "$AQ" add --project game --from shepherd --priority low --slug c "c" >/dev/null
  "$AQ" set c row=game:gm-c >/dev/null
  # A retry of a queued urgent add dies on the duplicate and returns nothing first.
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u1 "urgent one"
  assert_failure
  assert_output --partial "already in the queue: u1"
  refute_output --partial "returned c"
  "$AQ" move c running >/dev/null
  AQ_RETURN_QUEUED=1 run "$AQ" return c --why "make room"
  assert_failure
  assert_output --partial "c is running now, not queued: not returned"
  run jq -r 'select(.why == "returned") | .slug' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output "n"
}

@test "the cap never holds a --running, hand-started board or auto:epics verify or dispatch's canary top-up add; dispatch's own board pull it holds" {
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --slug human "human"
  assert_failure 5
  # Urgent and red are held too when nothing can be returned: "one" is the human's.
  run "$AQ" add --project game --tags red --slug broken "broken"
  assert_failure 5
  run "$AQ" add --project game --priority urgent --slug urgent "urgent"
  assert_failure 5
  "$AQ" add --project game --running --session s1 --slug mine "mine" >/dev/null
  AGENT_QUEUE_PULL=hand "$AQ" add --project game --from board:game:gm-3 --slug gm-3 "feat(game): started by hand" >/dev/null
  "$AQ" add --project game --from auto:epics --tags verify --slug verify-e-1 "verify e" >/dev/null
  run "$AQ" add --project game --from board:game:gm-4 --slug gm-4 "feat(game): dispatch's fill"
  assert_failure 5
  AGENT_QUEUE_PULL=dispatch "$AQ" add --project game --from canary --tags canary --slug canary "check(canary): x" >/dev/null
  # Negative control: the same add without dispatch's pull is a filer's, and goes to the board.
  run env -u AGENT_QUEUE_PULL "$AQ" add --project game --from canary --tags canary --slug canary-b "check(canary): y"
  assert_failure
  assert_output --partial "only the board fills the queue"
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "canary,gm-3,mine,one,verify-e-1"
  [ "$(wc -l < "$AGENT_QUEUE_DIR/admission.jsonl")" -eq 5 ]
}

@test "the cap passes dispatch's pull of a plan phase filed on its board row, as it passes the --plan; another board pull it holds" {
  story_notes
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two' > "$SANDBOX/pp.md"
  # add_plan queues P1 and files P2 on its board row behind #after/, its brief the real writer's.
  run "$AQ" add --plan "$SANDBOX/pp.md" --project level --priority low --slug pp
  assert_output --partial "held pp-p2 -> level:"
  brief=$(sed -n 's/.*--agent add --detail=\(Phase 2 of the plan .*: two\. .*\) -- two (P2) .*/\1/p' "$NOTES_FIXTURE/calls.log")
  [[ "$brief" == "Phase 2 of the plan $SANDBOX/pp.md: two. "* ]] || fail "no P2 brief in calls.log: $brief"
  export AGENT_QUEUE_CAP=1 AGENT_QUEUE_PULL=dispatch
  # Negative controls: the brief naming a plan file that is gone, a row that only mentions a plan,
  # and the same brief from no board pull are each held at the cap.
  mv "$SANDBOX/pp.md" "$SANDBOX/pp.gone"
  run "$AQ" add --project level --priority low --from board:level:lv-9 --slug lv-9 "feat(level): pp P2: two" $'\n'"$brief"
  assert_failure 5
  mv "$SANDBOX/pp.gone" "$SANDBOX/pp.md"
  run "$AQ" add --project level --priority low --from board:level:lv-7 --slug lv-7 "feat(level): the plan of the planet, phase 2"
  assert_failure 5
  run env -u AGENT_QUEUE_PULL "$AQ" add --project level --priority low --slug p-human "$brief"
  assert_failure 5
  # Dispatch's pull of that row, as fleet-dispatch pull-after promotes it, goes in past the cap.
  run "$AQ" add --project level --priority low --from board:level:lv-9 --slug lv-9 "feat(level): pp P2: two" $'\n'"$brief"
  assert_success
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "lv-9,pp-p1"
}

@test "only the board fills the queue: an agent's or a filer's add is filed as a board row, the human's and dispatch's go in" {
  story_notes
  unset AGENT_QUEUE_PULL
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --from shepherd --slug nudge "fix(menu): a filer's follow-up"
  assert_failure 5
  assert_output --partial "only the board fills the queue"
  assert_called "ptask level --agent add -- fix(menu): a filer's follow-up #high"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-nudge.md 2>/dev/null)" ] || fail "a filer's add wrote an item"
  run jq -r 'select(.slug == "nudge") | .why' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output board-only
  # The row it filed is on stdout, the one line a filer reads; stderr is prose for the log.
  rc=0; out=$("$AQ" add --project level --from shepherd --slug nudge2 "fix(menu): a second follow-up" 2>/dev/null) || rc=$?
  assert_equal "$rc" 5
  assert_equal "$out" "held nudge2 -> level:lv-9"
  # A board origin without dispatch's pull files no second row: the row it names stays put.
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --from board:level:lv-7 --slug lv-7 "feat(menu): seven"
  assert_failure 5
  assert_output --partial "its row level:lv-7 is left where it is"
  run grep -c ' ptask level --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A dispatch-run agent (its item not opened by the human) is held the same, even on --after.
  AGENT_QUEUE_PULL=dispatch "$AQ" add --project level --slug agent-item "agent item" >/dev/null
  run env AGENT_QUEUE_ITEM=agent-item "$AQ" add --project level --priority low --after agent-item --slug next "fix(menu): next phase"
  assert_failure 5
  # The human: at a terminal, in a session they started (no item, or an item they opened), or --running.
  "$AQ" add --project level --slug by-hand "feat(menu): by hand" >/dev/null
  "$AQ" set agent-item origin=hand >/dev/null
  AGENT_QUEUE_ITEM=agent-item "$AQ" add --project level --priority low --slug from-hand "feat(menu): from a hand session" >/dev/null
  AGENT_QUEUE_ITEM=agent-item "$AQ" add --project level --from shepherd --running --session s9 --slug own "own work" >/dev/null
  AGENT_QUEUE_PULL=dispatch "$AQ" add --project level --from board:level:lv-8 --slug lv-8 "feat(menu): eight" >/dev/null
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "agent-item,by-hand,from-hand,lv-8,own"
  # admission counts them as sent to the board, not as held by the cap
  run "$AQ" admission --json
  assert_equal "$(jq -c '[.held_7d, .boarded_7d]' <<<"$output")" '[0,4]'
  # A project with no board to file on: nothing was written, so the add fails rather than reads as filed.
  run "$AQ" add --project game --from shepherd --slug lost "fix(x): no board"
  assert_failure 1
  assert_output --partial "game has no board row to file this on"
}

# ar-5605: a filer's plan used to go to the board as one "run the open phases of plan X" row, which sat
# beside the phase rows or for plans nobody ran (97 rows, 93 dropped). NEGATIVE CONTROL: that row's
# brief, "Run the open phases of the approved plan", is filed no more.
@test "a filer's --plan files each open phase as its own board row, the later one #after/ the first; no plan row, nothing queued" {
  story_notes
  unset AGENT_QUEUE_PULL
  echo 20 > "$NOTES_FIXTURE/story.seq"
  printf '# P\n\n## Phases\n\n- [ ] one\n- [ ] two\n' > "$SANDBOX/orphan.md"
  run "$AQ" add --plan "$SANDBOX/orphan.md" --project level --from auto:plans
  assert_failure 5
  assert_output --partial "only the board fills the queue"
  assert_output --partial "held orphan-p1 -> level:lv-20"
  assert_output --partial "held orphan-p2 -> level:lv-21 (#after/lv-20)"
  assert_called "ptask level --agent add --detail=Phase 1 of the plan $SANDBOX/orphan.md: one."
  assert_called "ptask level --agent add --detail=Phase 2 of the plan $SANDBOX/orphan.md: two."
  assert_not_called "Run the open phases"
  # A filer that names no priority files its phases at normal; NEGATIVE CONTROL: the add default (high) tagged them before.
  run grep -e '-- one (P1, P)' "$NOTES_FIXTURE/calls.log"
  assert_output --partial '#normal'
  refute_output --regexp '#(urgent|high|low)'
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*orphan* 2>/dev/null)" ] || fail "a filer's plan queued a phase"
  # From a session (dispatch with AGENT_QUEUE_ITEM inherited) the filer is not refused for naming none.
  CLAUDE_CODE_SESSION_ID=s1 run "$AQ" add --plan "$SANDBOX/orphan.md" --project level --from auto:plans
  assert_failure 5
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*orphan* 2>/dev/null)" ] || fail "a filer's plan queued a phase"
  # The human's approved plan still queues its phases.
  run "$AQ" add --plan "$SANDBOX/orphan.md" --project level --priority low
  assert_success
}

# fleet-dispatch promote turns that row into the chain (ar-3262). NEGATIVE CONTROL: before it, --from
# board: on a --plan was refused as no filer, and promote queued the row as one item for every phase.
@test "dispatch's --plan --from board: queues the chain from auto:plan-row and puts the row on the plan's rows: line" {
  story_notes
  printf '# pp\n\n## Phases\n\n- [ ] P1 one\n- [ ] P2 two\n' > "$SANDBOX/pp.md"
  cp "$SANDBOX/pp.md" "$SANDBOX/pp.orig"
  # Without dispatch's pull the row stays where it is and nothing is written.
  run env -u AGENT_QUEUE_PULL "$AQ" add --plan "$SANDBOX/pp.md" --project level --priority low --from board:level:lv-5
  assert_failure 5
  assert_output --partial "its row lv-5 is left where it is"
  cmp "$SANDBOX/pp.md" "$SANDBOX/pp.orig" || fail "a held add wrote the plan"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/ 2>/dev/null)" ] || fail "a held add queued a phase"
  # A plan file that is gone is refused by name.
  run env AGENT_QUEUE_PULL=dispatch "$AQ" add --plan "$SANDBOX/gone.md" --project level --from board:level:lv-5
  assert_failure
  assert_output --partial "no such file"
  run env AGENT_QUEUE_PULL=dispatch "$AQ" add --plan "$SANDBOX/pp.md" --project level --priority low --from board:level:lv-5 --slug pp
  assert_success
  assert_output --partial "held pp-p2 -> level:lv-9 (#after/lv-9)"
  f=$(ls "$AGENT_QUEUE_DIR"/queued/*-pp-p1.md)
  assert_equal "$(sed -n 's/^from: //p' "$f")" auto:plan-row
  assert_equal "$(grep -x 'rows: lv-5' "$SANDBOX/pp.md")" 'rows: lv-5'
  assert_equal "$(sed -n 2p "$SANDBOX/pp.md")" 'rows: lv-5'
  ! grep -rq '^from: board:' "$AGENT_QUEUE_DIR"/queued/ || fail "a phase carries the plan row as its own row"
  # A plan whose every phase already landed queues nothing and leaves its rows: line alone.
  printf '# one\n\n## Phases\n\n- [ ] P1 one\n' > "$SANDBOX/one.md"
  AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/one.md" --project level --slug one >/dev/null
  AGENT_QUEUE_START=0 "$AQ" move one-p1 done --status ok >/dev/null
  cp "$SANDBOX/one.md" "$SANDBOX/one.orig"
  run env AGENT_QUEUE_PULL=dispatch "$AQ" add --plan "$SANDBOX/one.md" --project level --from board:level:lv-6 --slug one
  assert_failure 4
  assert_output --partial "every phase of $SANDBOX/one.md already landed"
  cmp "$SANDBOX/one.md" "$SANDBOX/one.orig" || fail "an all-landed plan got a rows: line"
}

# The project is resolved as every add resolves it: a repo whose work counts on its owner (tools ->
# cockpit, as dotfiles -> agent-runtime) files on the owner's board. NEGATIVE CONTROL: unresolved,
# tools had no board, the add failed, and reap retried every dotfiles plan each pass (ar-2787).
@test "a filer's --plan for a repo with an owner files its phase rows on the owner's board" {
  story_notes
  jq '.trackers.cockpit.lab = "bnb" | .trackers.cockpit.code = "ck"' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m.json" && mv "$SANDBOX/m.json" "$AGENT_QUEUE_PROJECT_MAP"
  unset AGENT_QUEUE_PULL
  printf '# P\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/owned.md"
  run "$AQ" add --plan "$SANDBOX/owned.md" --project tools --from auto:plans --priority low
  assert_failure 5
  assert_called "ptask cockpit --agent add --detail=Phase 1 of the plan $SANDBOX/owned.md: one."
}

@test "every queued item counts against the cap, one held to a time of day or a date too" {
  # The queue holds only work that can start (a gated add files a board row), so every queued item
  # counts: one left from before, held to a time of day or a date, too.
  export AGENT_QUEUE_CAP=2
  legacy n1 "tags: at:20:00" --project game "evening one"
  legacy dated "tags: at:2099-01-01T09:00" --project game "dated"
  run "$AQ" add --project game --slug day "day"
  assert_failure 5
  assert_output --partial "2 items can start now against a cap of 2"
  "$AQ" cancel dated >/dev/null
  run "$AQ" add --project game --slug day "day"
  assert_success
}

@test "a queue item's session adding without --from files item:<its slug>, held at the cap like any add" {
  export AGENT_QUEUE_CAP=1 AGENT_QUEUE_ITEM=parent
  run "$AQ" add --project game --priority low --slug first "first follow-up"
  assert_success
  [ "$(field "$(item queued first)" from)" = item:parent ]
  run "$AQ" add --project game --priority low --slug second "second follow-up"
  assert_failure 5
  assert_output --partial "against a cap of 1 (item:parent)"
  "$AQ" add --project game --slug own --running --session s1 "own work" >/dev/null
  # Urgent is capped too (2026-11-18): with nothing to return it is held, from the item.
  run "$AQ" add --project game --slug now --priority urgent "urgent for the human"
  assert_failure 5
  assert_output --partial "against a cap of 1 (item:parent)"
  # The session's record of its own work is from its item too (ar-4154), never the human's.
  [ "$(field "$(item running own)" from)" = item:parent ]
}

@test "AGENT_QUEUE_CAP=0 is the negative control: the same adds overflow past the cap, and admission --json counts the holds of 7 days" {
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project game --slug one "one" >/dev/null
  AGENT_QUEUE_CAP=0 run "$AQ" add --project game --from auto:x --slug free "free"
  assert_success
  run "$AQ" add --project game --from auto:x --slug held "held"
  assert_failure 5
  printf '{"at":"2000-01-01T00:00:00Z","from":"auto:x","slug":"old"}\n' >> "$AGENT_QUEUE_DIR/admission.jsonl"
  run "$AQ" admission --json
  assert_equal "$(jq -c '[.on, .runnable, .limit, .held_7d, .admits]' <<<"$output")" '[true,2,1,1,false]'
  run env AGENT_QUEUE_CAP=0 "$AQ" admission
  assert_output --partial "admission: off,"
  # A filer retrying the same item counts once, and the next hold drops lines past the window.
  run "$AQ" add --project game --from auto:x --slug held "held"
  assert_failure 5
  run "$AQ" admission --json
  assert_equal "$(jq .held_7d <<<"$output")" 1
  run jq -r .slug "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output "$(printf 'held\nheld')"
  # day is the last 24h of the same count: a hold two days old is in held_7d and not in day (ar-4985)
  printf '{"at":"%s","project":"game","slug":"old2","why":"cap"}\n' "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)" >> "$AGENT_QUEUE_DIR/admission.jsonl"
  run "$AQ" admission --json
  assert_equal "$(jq -c '[.held_7d, .day.held, .day.why]' <<<"$output")" '[2,1,{"cap":1}]'
}

@test "at the cap, an add of a slug already queued says so, not that admission held it" {
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --from auto:x --slug one "one again"
  assert_failure 1
  assert_output --partial "already in the queue: one"
  [ ! -e "$AGENT_QUEUE_DIR/admission.jsonl" ]
}

# The only write a return makes to a row besides the un-start is the gate tags of an item still held
# (see "return writes what the item still waits on"); these items wait on nothing.
@test "return writes no brief to its board row: the row already holds it, and an item with no hold adds no tag" {
  story_notes
  "$AQ" add --project game --slug ha "first line of the brief
second line of the brief"
  "$AQ" set ha row=game:gm-1
  "$AQ" add --project game --slug hb "short one-liner"
  "$AQ" set hb row=game:gm-2
  "$AQ" add --project game --from board:game:gm-3 --slug gm-3 "feat(game): row text
generated line"
  "$AQ" add --project game --slug hd "kept
already"
  "$AQ" set hd row=game:gm-4
  : > "$NOTES_FIXTURE/calls.log"
  for s in ha hb gm-3 hd; do "$AQ" return "$s" --why "back" >/dev/null; done
  run grep -cE ' ptask game --agent (edit|tag) ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  for r in gm-1 gm-2 gm-3 gm-4; do assert_called "ptask game --agent unstart $r"; done
}

@test "a partial merge cannot close ok or release after items" {
  "$AQ" add --project game --running --slug partial 'two repos' >/dev/null
  legacy next "after: partial" --project game 'next phase' >/dev/null
  "$AQ" set partial pr=o/game#1 merged=aaa111 partial=yes >/dev/null
  run "$AQ" move partial done --status ok
  assert_failure
  assert_output --partial 'has a partial landing'
  run "$AQ" show next --json
  assert_equal "$(jq -r .hold <<<"$output")" 'after partial'
  "$AQ" set partial partial= >/dev/null
  run "$AQ" move partial done --status ok
  assert_success
  run "$AQ" show next --json
  assert_equal "$(jq -r '.hold // ""' <<<"$output")" ''
}

@test "--row, a row move and --plan check the queue for a row or plan without deriving a hold (ar-2544)" {
  story_notes
  export AGENT_QUEUE_CAP=0 # the cap derives every hold to count runnable; this test is about the writers that do not
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  gh_script "echo \"gh \$*\" >> \"$SANDBOX/gh.log\"; echo OPEN"
  legacy held "tags: pr:Org/game#7" --project game "a"
  : > "$SANDBOX/gh.log"
  run "$AQ" add --project game --row lv-2 --slug by-row "feat(menu): the row's work"
  assert_success
  run "$AQ" add --project game --row lv-2 --slug twice "y"
  assert_failure; assert_output --partial "by-row already works that row"
  printf '# p\n\n## Phases\n- [ ] one\n' > "$SANDBOX/p.md"
  run "$AQ" add --project game --plan "$SANDBOX/p.md"
  assert_success
  run "$AQ" add --project game --plan "$SANDBOX/p.md"
  assert_failure; assert_output --partial "already queued"
  [ ! -s "$SANDBOX/gh.log" ] || fail "a writer asked gh: $(cat "$SANDBOX/gh.log")"
}

@test "a lock that stays busy past the wait exits 75, not 1, and writes nothing" {
  "$AQ" add --project game "one item" >/dev/null
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" add --project game "two item"
  assert_failure 75
  assert_output --partial "the queue is locked by another writer"
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" show one-item --json
  assert_failure 75
  flock -u 9
  run "$AQ" list --json
  [ "$(jq -sr 'map(.slug) | join(",")' <<<"$output")" = one-item ]
}

@test "lock-miss counts the timeouts in its window against its bound, the rotated log too; no log is no misses (ar-4471)" {
  mkdir -p "$AGENT_QUEUE_DIR"
  run "$AQ" lock-miss
  assert_success
  assert_output "0 queue lock misses in the last 1h (bound 3)"
  log="$AGENT_QUEUE_DIR/lock-miss.jsonl"
  now=$(date -u -Is) old=$(date -u -Is -d "-3 hours")
  for t in "$old" "$now" "$now"; do jq -nc --arg ts "$t" '{ts: $ts, cmd: "agent-queue list", caller: "hub"}'; done > "$log"
  jq -nc --arg ts "$now" '{ts: $ts, cmd: "agent-queue add", caller: "dispatch"}' > "$log.1"
  run "$AQ" lock-miss --max 3
  assert_success
  assert_output --partial "3 queue lock misses in the last 1h (bound 3); the latest at $now: agent-queue list from hub"
  run "$AQ" lock-miss --max 2
  assert_failure 1
  run "$AQ" lock-miss --hours 4 --max 3
  assert_failure 1
  assert_output --partial "4 queue lock misses in the last 4h"
}

# ar-3025: a timeout names who held the lock. NEGATIVE CONTROL: before it, nothing was written and
# 108 dispatch starts failed with no holder on record.
@test "a lock timeout appends one lock-miss line naming the holder, the taker and its mode" {
  "$AQ" add --project game "one item" >/dev/null
  # The holder stays alive while it holds: in a container's pid namespace the kernel hides a
  # /proc/locks entry whose taker has exited, as a bare `flock 9` does. cat opens the fifo only
  # after flock has the lock, so opening its write end here is the signal that the lock is held.
  mkfifo "$BATS_TEST_TMPDIR/hold"
  flock "$AGENT_QUEUE_DIR/.lock" cat "$BATS_TEST_TMPDIR/hold" &
  holder=$!
  exec 7> "$BATS_TEST_TMPDIR/hold"
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" add --project game "two item" 7>&-
  assert_failure 75
  assert_output --partial "lock-miss.jsonl"
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" show one-item --json 7>&-
  assert_failure 75
  exec 7>&-
  wait "$holder"
  log="$AGENT_QUEUE_DIR/lock-miss.jsonl"
  [ "$(wc -l < "$log")" = 2 ]
  run jq -r --argjson me "$holder" -s '.[] | [.mode, (.cmd | test("agent-queue (add|show)")),
    (.locks | index(".lock holds WRITE") != null), (.procs | any(.pid == $me and .file == ".lock")),
    (.procs | all(.cmd | test("agent-queue") | not))] | map(tostring) | join(" ")' "$log"
  assert_line --index 0 "exclusive true true true true"
  assert_line --index 1 "shared true true true true"
  # Past 1 MB the log moves to .1 and starts again.
  head -c 1048576 /dev/zero > "$log"
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" show one-item --json 9>&-
  assert_failure 75
  [ "$(stat -c %s "$log.1")" = 1048576 ]
  [ "$(wc -l < "$log")" = 1 ]
}

# The row is the task's record (ar-2927), against the real notes and a sandbox vault: an item's body
# is its row's brief, so a return loses nothing, the next promote briefs the new item from the row,
# and a retask rewrites the row first. NEGATIVE CONTROL: before ar-2927 the re-promoted body was the
# row line alone. The CI rust job builds notes and sets NOTES_BIN.
@test "end to end: a returned item's brief comes back from its row on the next promote, and retask rewrites the row" {
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  dir="$HOME/.notes/lab/projects/current/game"
  mkdir -p "$dir" "$HOME/.config/notes"
  : >"$dir/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  printf '%s\n' '# game' '' 'Version: v1.0.0 #beta' '' '## Inbox' '' '## Tasks' '' >"$dir/README.md"
  export PROJECT_MAP_FILE="$AGENT_QUEUE_PROJECT_MAP" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  unset NOTES_PROFILE
  jq -n --arg r "$REPO" '{paths: {($r): "game"}, trackers: {game: {code: "gm", lab: "personal"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  tail=$'goal: one record per task\n\n- a list\n  - nested\n\n```sh\n    echo hi\n```\n## Phases\n- [ ] P1 one'
  run "$AQ" add --project game --slug title -- $'feat(menu): the title screen\n'"$tail"
  assert_success
  assert_line 'story gm-1 on the game agent board'
  # the checklist in the brief is no row of its own
  run notes --profile personal ptask game --agent list
  refute_output --partial 'P1 one'

  run "$AQ" return title --why "over the cap"
  assert_success
  raw="$(notes --profile personal ptask game --agent list | awk -F'\t' '$4 ~ /id:gm-1 / { print $4 }')"
  [[ "$raw" == '- [ ] feat(menu): the title screen'* ]] || fail "row not back open: $raw"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile personal --agent --raw "$raw"
  assert_success
  assert_output --partial 'queued game: gm-1'
  f="$(item queued gm-1)"
  body="$(awk 'f { print } $0 == "---" { f = 1 }' "$f")"
  [ "$(head -1 <<<"$body")" = "${raw#- \[ \] }" ] || fail "first line: $body"
  [ "$(tail -n +2 <<<"$body")" = "$tail" ] || fail "the brief did not come back whole: $body"

  run "$AQ" retask gm-1 $'feat(menu): the title screen\nnew brief'
  assert_success
  [ "$(notes board --json | jq -r '.rows[] | select(.id == "gm-1") | .details | join("\n")')" = "new brief" ] ||
    fail "row not rewritten: $(cat "$dir/agent/README.md")"
  [ "$(awk 'f { print } $0 == "---" { f = 1 }' "$f")" = $'feat(menu): the title screen\nnew brief' ]
}

@test "ar-2943: a session's add names its priority; an add by hand keeps the high default" {
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" add --project game --slug s1 "bare from a session"
  assert_failure
  assert_output --partial "a session's add passes --priority"
  AGENT_QUEUE_ITEM=u1 run "$AQ" add --project game --slug s2 "bare from a dispatched session"
  assert_failure
  plan_fixture
  AGENT_QUEUE_ITEM=u1 run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game
  assert_failure
  assert_output --partial "a session's add passes --priority"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued")" ]
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" add --project game --priority low --slug s3 "named by the session"
  assert_success
  [ "$(field "$(item queued s3)" priority)" = low ]
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" add --project game --running --slug s4 "the session's own task"
  assert_success
  # a human channel names its want, not a priority, and an emptied session env counts as none
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" add --project game --want voice --slug s6 "a want said aloud"
  assert_success
  CLAUDE_CODE_SESSION_ID= AGENT_QUEUE_ITEM= run "$AQ" add --project game --slug s7 "a script that cleared the session"
  assert_success
  [ "$(field "$(item queued s7)" priority)" = high ]
  # negative control: the same bare add by hand, with no session around it, files high
  run "$AQ" add --project game --slug s5 "bare by hand"
  assert_success
  [ "$(field "$(item queued s5)" priority)" = high ]
}

@test "the store-sync a write starts on exit does not inherit the queue lock" {
  # A sync that held .lock waited out its own sync lock (300s) with every queue writer behind it (2026-11-18).
  printf '#!/usr/bin/env bash\nif [ -e /proc/$$/fd/8 ]; then echo "store-sync fd8=open" >> "$NOTES_FIXTURE/calls.log"; else echo "store-sync fd8=closed" >> "$NOTES_FIXTURE/calls.log"; fi\n' > "$SANDBOX/bin/store-sync"
  chmod +x "$SANDBOX/bin/store-sync"
  run "$AQ" add --project game "Menu: pick sides"
  assert_success
  run cat "$NOTES_FIXTURE/calls.log"
  assert_output --partial "store-sync fd8=closed"
  refute_output --partial "store-sync fd8=open"
}

@test "a queue call made under the write hook's own sync starts no second sync (ar-4050)" {
  # A store-sync stub that called agent-queue started the hook again from that call, and again,
  # ~600 processes that outlived their bats run. The stub stops itself at 3, so a miss fails here, not forever.
  printf '#!/usr/bin/env bash\necho "store-sync $*" >> "$NOTES_FIXTURE/sync.log"\n[ "$(wc -l < "$NOTES_FIXTURE/sync.log")" -ge 3 ] || %q list >/dev/null 2>&1\nexit 0\n' "$AQ" > "$SANDBOX/bin/store-sync"
  chmod +x "$SANDBOX/bin/store-sync"
  run "$AQ" add --project game "Menu: pick sides"
  assert_success
  assert_equal "$(cat "$NOTES_FIXTURE/sync.log")" "store-sync --now --bg"
}

@test "lag_places: a class with only held items sets no floor for the bound, as it starts nothing" {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  today="$(date +%F)"
  # This week: requested 30 of 60 (0.5), feature 10 of 10 (1.0); research none (0), but its one item is held.
  for i in $(seq 1 30); do mix_done "$today" "dr$i" human "do thing $i" 1; done
  for i in $(seq 1 10); do mix_done "$today" "df$i" shepherd "feature done $i" 1; done
  printf '%s\t%s\tgame\t%s\t1\n' "research(game): held question" research "held question" > "$NOTES_FIXTURE/row.parse"
  "$AQ" add --project game --slug r2 "asked 2"
  "$AQ" add --project game --slug r3 "asked 3"
  "$AQ" add --project game --from shepherd --slug f1 "feature 1"
  legacy z1 "after: r2" --project game --from shepherd "research(game): held question"
  n=0; for s in r2 r3 f1 z1; do n=$((n + 1)); sed -i "s/^queued: .*/queued: ${today}T00:0$n:00Z/" "$(item queued "$s")"; done
  jq '.on = true | .lag_places = 10 | del(.classes[].min_live)' "$REPO_ROOT/.config/fleet-dispatch/classes.json" > "$SANDBOX/classes.json"
  # The floor is requested's 0.5, so feature is cut to 0.6 and both requested items go before it. Had
  # held research's 0 set the floor, both would be cut to 0.1 and f1 would go second.
  run bash -c "'$AQ' list --json --state queued | jq -r .slug | paste -sd' '"
  assert_success
  assert_output 'z1 r2 r3 f1'
}

# twinkling-soaring-hinton P5: notes sends a session's agent add to the outbox and exits 4. A board-only
# add from a session (a held follow-up) then has no row, and says so; the plan's own row and the
# item's own story row name their origin, so notes writes them directly.
@test "a session's held follow-up that notes inboxes (exit 4) is reported as inboxed, with no row" {
  story_notes
  unset AGENT_QUEUE_PULL
  echo 4 > "$NOTES_FIXTURE/story.rc"
  echo "inboxed: follow-up" > "$NOTES_FIXTURE/story.out"
  : > "$NOTES_FIXTURE/calls.log"
  rc=0; out=$("$AQ" add --project level --from shepherd --slug nudge "fix(menu): a filer's follow-up" 2>"$SANDBOX/err") || rc=$?
  assert_equal "$rc" 5
  assert_equal "$out" "inboxed nudge -> inbox"
  grep -qF "in the outbox" "$SANDBOX/err"
  run grep -c ' ptask level --agent start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

# ar-3684: notes shows a hand session's add the similar open rows and exits 5. The item has no row
# then, and the shortlist reaches the session so it can join one or file with --checked.
@test "a held follow-up that notes answers with a shortlist (exit 5) has no row and prints the shortlist" {
  story_notes
  unset AGENT_QUEUE_PULL
  echo 5 > "$NOTES_FIXTURE/story.rc"
  printf 'dm-4\t62\tagent\tfix(menu): the follow-up already filed\n' > "$NOTES_FIXTURE/story.out"
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project level --from shepherd --slug nudge "fix(menu): a filer's follow-up" 2>"$SANDBOX/err" || true
  grep -qF "similar open rows" "$SANDBOX/err"
  grep -qF "dm-4" "$SANDBOX/err"
  run grep -c ' ptask level --agent start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "the item's own story row and a plan's rows name their origin, a want names none" {
  story_notes
  unset AGENT_QUEUE_PULL
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --slug own --from human "feat(menu): own row"
  assert_success
  assert_called "ptask level --agent add --origin agent-queue -- feat(menu): own row #high"
  printf '# P\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/orig.md"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --plan "$SANDBOX/orig.md" --project level --from auto:plans --priority low
  assert_failure 5
  run grep -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output --partial " --origin plan -- "
  # A filer that does name one keeps it.
  assert_output --partial "one (P1, P) #low"
}

@test "a plan phase after a live item with an open PR is stacked: no hold, stacked_on names the PR; closed unmerged it is a dead hold (ar-3852)" {
  stack_gh
  printf '# P\n' > "$SANDBOX/p.md"
  "$AQ" add --project game --slug base --running "a"
  legacy second "after: base" --project game "Phase 2 of the plan $SANDBOX/p.md: b"
  legacy hand "after: base" --project game "b, once base lands"
  # No PR yet: the dependency is live, so second waits.
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after base"
  # open_pr: is what agent-land records while the PR is open.
  "$AQ" set base open_pr=Org/game#7
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | \"[\\(.hold // \"\")] \\(.stacked_on)\"'"
  assert_output "[] base=Org/game#7"
  [ "$("$AQ" next --json | jq -r .slug)" = second ]
  # NEGATIVE CONTROL: an item that is no plan phase waits for the close, open PR or not (ar-4537).
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"hand\") | \"\\(.hold) \\(.stacked_on // \"none\")\"'"
  assert_output "after base none"
  # NEGATIVE CONTROL: the PR closing unmerged takes the stack away, the hold is live again.
  echo CLOSED > "$SANDBOX/pr-7"
  AGENT_QUEUE_PR_TTL=0 run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | \"\\(.hold) \\(.stacked_on // \"none\")\"'"
  assert_output "after base none"
  # A dependency that closed failed stays a dead hold, whatever it recorded.
  echo OPEN > "$SANDBOX/pr-7"
  "$AQ" move base done --status failed
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output --partial "after base closed failed, dead"
}

@test "gate after/<row-id> clears as stacked for a plan phase's row while the row's item has an open PR, and says which (ar-3852)" {
  stack_gh
  printf '# P\n' > "$SANDBOX/p.md"
  "$AQ" add --project game --slug base --running "a"
  "$AQ" set base row=level:ar-2
  "$AQ" set base open_pr=Org/game#7
  st() { jq -r 'select(.tag == "after/ar-2") | "\(.state)|\(.why)|\(.stack)"' <<<"$output"; }
  jq -n --arg d "Phase 2 of the plan $SANDBOX/p.md: b" '{rows: [{id: "ar-1", state: "open", tags: ["after/ar-2"], details: [$d]},
    {id: "ar-2", state: "doing", tags: []}], done: []}' > "$NOTES_FIXTURE/board.json"
  run "$AQ" gate --json --all
  assert_success
  assert_equal "$(st)" "clear|stacked on Org/game#7|base"
  # NEGATIVE CONTROLS: a row that is no plan phase carrying the same tag waits for the close (ar-4537),
  # so the tag stays pending; so does the tag asked alone with no phase's add under way.
  jq '.rows += [{id: "ar-3", state: "open", tags: ["after/ar-2"], details: ["land it once base lands"]}]' "$NOTES_FIXTURE/board.json" > "$SANDBOX/b.json"
  mv "$SANDBOX/b.json" "$NOTES_FIXTURE/board.json"
  run "$AQ" gate --json --all
  assert_failure 3
  assert_equal "$(st)" "pending|after ar-2 (open; its item's open PR Org/game#7 is a base only for a plan phase)|"
  run "$AQ" gate --json after/ar-2
  assert_failure 3
  assert_equal "$(st)" "pending|after ar-2 (open; its item's open PR Org/game#7 is a base only for a plan phase)|"
  # With no open PR the row is plain pending.
  "$AQ" set base open_pr=
  run "$AQ" gate --json after/ar-2
  assert_failure 3
  assert_equal "$(st)" "pending|after ar-2 (open)|"
}

@test "an after: on two items that each have an open PR stays held: one worktree has one base (ar-3852)" {
  stack_gh
  echo OPEN > "$SANDBOX/pr-8"
  "$AQ" add --project game --slug base-a --running "a"
  "$AQ" add --project game --slug base-b --running "b"
  "$AQ" set base-a open_pr=Org/game#7
  "$AQ" set base-b open_pr=Org/game#8
  legacy second "after: base-a base-b" --project game "c"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | \"\\(.hold) \\(.stacked_on // \"none\")\"'"
  assert_output "after base-a base-b none"
}

@test "fm_get and fm_body given no file return at once, never reading the caller's stdin (ar-3455)" {
  # An awk operand of "" reads stdin, and a tool shell's stdin never closes: a lookup that came back empty hung a local run.
  # The stand-in is a fifo held open for read and write on fd 4: no writer process to outlive the test or hold bats' fd 3.
  fns="$(sed -n '/^fm_get() {/,/^}/p; /^fm_body() {/p' "$AQ")"
  mkfifo "$BATS_TEST_TMPDIR/open-stdin"
  exec 4<>"$BATS_TEST_TMPDIR/open-stdin"
  run timeout 10 bash -c "$fns"'; declare -F fm_get fm_body >/dev/null && [ -z "$(fm_get "" slug)" ] && [ -z "$(fm_body "")" ]' <&4
  exec 4>&-
  assert_success
}

@test "ar-4349: a session's urgent plan queues at high; the human's own add, a red plan and dispatch's promote keep urgent" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  printf '## Phases\n\n- [ ] P1 One (independent)\n- [ ] P2 Two (independent)\n' > "$SANDBOX/u.md"
  CLAUDE_CODE_SESSION_ID=sid-a AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/u.md" --project level --priority urgent --slug sess
  assert_success
  assert_output --partial "a session's plan queues at high at most"
  [ "$(field "$(item queued sess-p1)" priority)" = high ]
  [ "$(field "$(item queued sess-p2)" priority)" = high ]
  cp "$SANDBOX/u.md" "$SANDBOX/r.md"; cp "$SANDBOX/u.md" "$SANDBOX/h.md"
  AGENT_QUEUE_ITEM=u1 AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/r.md" --project level --priority urgent --tags red --slug red
  assert_success
  [ "$(field "$(item queued red-p1)" priority)" = urgent ]
  cp "$SANDBOX/u.md" "$SANDBOX/b.md"
  AGENT_QUEUE_ITEM=u1 AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/b.md" --project level --priority urgent --from board:level:lv-9 --slug promo
  assert_success
  [ "$(field "$(item queued promo-p1)" priority)" = urgent ]
  # NEGATIVE CONTROL: the same urgent plan with no session around it (the human's own) keeps urgent on every phase.
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/h.md" --project level --priority urgent --slug hand
  assert_success
  refute_output --partial "queues at high at most"
  [ "$(field "$(item queued hand-p1)" priority)" = urgent ]
  [ "$(field "$(item queued hand-p2)" priority)" = urgent ]
}

@test "ar-3011: the queue ranks an item by its open board row's priority; a red keeps its own, a cleanup item on a #low row ranks high" {
  story_notes
  row_item retagged-down level:lv-1 high
  row_item retagged-up level:lv-2 low
  row_item red level:lv-3 low "red cause:x"
  row_item cleanup level:lv-4 high cleanup
  row_item gone level:lv-5 high
  jq -n '{rows: [{project: "level", id: "lv-1", state: "open", priority: "low"},
                 {project: "level", id: "lv-2", state: "doing", priority: "urgent"},
                 {project: "level", id: "lv-3", state: "open", priority: "low"},
                 {project: "level", id: "lv-4", state: "open", priority: "low"}]}' > "$NOTES_FIXTURE/board.json"
  run bash -c "'$AQ' list --json | jq -r '\"\(.slug) \(.priority)\"'"
  assert_success
  # The red goes first at its own low; lv-5 is on no open row, so it keeps its own high.
  assert_output $'red low\nretagged-up urgent\ncleanup high\ngone high\nretagged-down low'
  [ "$("$AQ" next --json | jq -r .slug)" = red ]
  # A real board (4,700 rows on 11-21) is past the argument limit as a whole map: only the rows items
  # work are bound, so the order still reads them.
  jq --argjson n 9000 '.rows += [range($n) | {project: "level", id: "lv-x\(.)", state: "open", priority: "high"}]' \
    "$NOTES_FIXTURE/board.json" > "$NOTES_FIXTURE/big.json" && mv "$NOTES_FIXTURE/big.json" "$NOTES_FIXTURE/board.json"
  run bash -c "'$AQ' list --json | jq -r '\"\(.slug) \(.priority)\"'"
  assert_success
  assert_output $'red low\nretagged-up urgent\ncleanup high\ngone high\nretagged-down low'
  # An item on a row by its from: board: alone, and a waiting one, rank by their rows among the 9,000.
  row_item boarded level:lv-x5 low
  sed -i -e '/^row: /d' -e 's/^from: session$/from: board:level:lv-x5/' "$(item queued boarded)"
  row_item parked level:lv-2 low
  mkdir -p "$AGENT_QUEUE_DIR/waiting" && mv "$(item queued parked)" "$AGENT_QUEUE_DIR/waiting/"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"boarded\" or .slug == \"parked\") | \"\(.slug) \(.priority)\"' | sort"
  assert_output $'boarded high\nparked urgent'
  rm "$(item queued boarded)" "$AGENT_QUEUE_DIR"/waiting/*parked.md
  # NEGATIVE CONTROL: a board notes cannot read ranks every item by its own line, as before.
  rm "$NOTES_FIXTURE/board.json"
  run bash -c "'$AQ' list --json | jq -r '\"\(.slug) \(.priority)\"'"
  assert_output $'red low\nretagged-down high\ncleanup high\ngone high\nretagged-up low'
}

@test "ar-4885: an item on a #normal row takes the row's normal, the queue's own word for it" {
  story_notes
  row_item on-normal level:lv-1 low
  jq -n '{rows: [{project: "level", id: "lv-1", state: "open", priority: "normal"}]}' > "$NOTES_FIXTURE/board.json"
  run bash -c "'$AQ' list --json | jq -r '\"\(.slug) \(.priority)\"'"
  assert_success
  # NEGATIVE CONTROL: the item's own low is not what it reads; the row's normal is, no longer mapped to high.
  assert_output 'on-normal normal'
}

@test "ar-3011: bump and set priority= write the item's row, which the order reads; an item with no row writes none" {
  story_notes
  row_item rowed level:lv-1 high
  "$AQ" add --project game --slug plain "plain" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" bump rowed urgent
  assert_success
  run grep -c -- '--profile bnb ptask level --agent tag --add urgent lv-1' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run "$AQ" set rowed priority=low
  assert_success
  grep -q -- 'ptask level --agent tag --add low lv-1' "$NOTES_FIXTURE/calls.log"
  [ "$(field "$(item queued rowed)" priority)" = low ]
  run "$AQ" set rowed priority=soon
  assert_failure
  assert_output --partial "urgent, high, normal or low"
  # NEGATIVE CONTROL: an item with no row has only its own line to change.
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" bump plain low >/dev/null
  run grep -c ' tag ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "ar-3011: the human's add that links a filed row gives it the --priority it names; one with no --priority, or a session's, leaves the row's" {
  story_notes
  run "$AQ" add --project level --row lv-7 --priority urgent --slug linked "work lv-7"
  assert_success
  grep -q -- 'ptask level --agent tag --add urgent lv-7' "$NOTES_FIXTURE/calls.log"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --row lv-8 --running --slug mine "work lv-8"
  assert_success
  # NEGATIVE CONTROL: a session's add names a priority every time, so its low never demotes the row.
  CLAUDE_CODE_SESSION_ID=sid-a AGENT_QUEUE_START=0 run "$AQ" add --project level --row lv-9 --priority low --slug sess "work lv-9"
  assert_success
  run grep -c ' tag ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a landing follow-up from an item with a PR recorded is gated on its blockers; any other follow-up keeps its own timing (ar-4451)" {
  story_notes
  "$AQ" add --project level --running --slug par "parent" >/dev/null
  legacy mine "after: par" --project level "the item"
  legacy nopr "after: par" --project level "an item with no PR yet"
  "$AQ" set mine pr=Kblack0610/game#12 >/dev/null
  unset AGENT_QUEUE_PULL
  run env AGENT_QUEUE_ITEM=mine "$AQ" add --project level --priority low --slug l1 "Land PR 12 on its branch"
  assert_failure 5
  assert_output --partial "held l1 -> level:lv-9 (#after/lv-9)"
  # NEGATIVE CONTROLS: a follow-up that is not a landing, an item with no PR, a task that only contains
  # a longer word, and one that names its own gate.
  run env AGENT_QUEUE_ITEM=mine "$AQ" add --project level --priority low --slug l2 "fix(x): a gap mine left"
  assert_failure 5
  refute_output --partial "#after/"
  run env AGENT_QUEUE_ITEM=nopr "$AQ" add --project level --priority low --slug l3 "land it: agent-land 13"
  assert_failure 5
  refute_output --partial "#after/"
  run env AGENT_QUEUE_ITEM=mine "$AQ" add --project level --priority low --slug l4 "chore(x): the landscape doc"
  assert_failure 5
  refute_output --partial "#after/"
  "$AQ" add --project level --running --slug other "other" >/dev/null
  run env AGENT_QUEUE_ITEM=mine "$AQ" add --project level --priority low --after other --slug l5 "land PR 12"
  assert_failure 5
  assert_output --partial "held l5 -> level:lv-9 (#after/lv-9)"
}

@test "a hand add --after an item running with an open PR is held on its row until that item closed ok; a plan phase's or validate item's add stacks; a landing follow-up waits on it too (ar-4537)" {
  story_notes; stack_gh
  # The incident: base came from the board (no row: line), runs with an open PR recorded (a partial
  # landing leaves its other PRs so), and the human's own session adds a landing after it.
  "$AQ" add --project level --slug base --from board:level:lv-1 "a" >/dev/null
  "$AQ" move base running >/dev/null
  "$AQ" set base pr=Org/game#7 >/dev/null
  unset AGENT_QUEUE_PULL
  export CLAUDE_CODE_ENTRYPOINT=cli
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --row lv-5 --after base --slug hand "chore(x): land lv-5 after base lands"
  assert_failure 5
  assert_output --partial "held hand -> level:lv-5 (#after/lv-1)"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-hand.md 2>/dev/null)" ] || fail "the held add wrote an item"
  run grep -c "fleet-dispatch start" "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # NEGATIVE CONTROL: a plan phase's add with the same after: builds on base's PR, so it queues stacked.
  printf '# P\n' > "$SANDBOX/p.md"
  run env CLAUDE_CODE_ENTRYPOINT= "$AQ" add --project level --after base --slug phase "Phase 2 of the plan $SANDBOX/p.md: b"
  assert_success
  assert_equal "$("$AQ" show phase --json | jq -r '"\(.hold // "")|\(.stacked_on)"')" "|base=Org/game#7"
  # So does fleet-dispatch validate's item, which reviews base's open PR before it lands (ar-1689).
  run env AGENT_QUEUE_PULL=dispatch AGENT_QUEUE_START=0 CLAUDE_CODE_ENTRYPOINT= "$AQ" add --project level --slug validate-base --after base --tags validate --from auto:validate "review PR 7"
  assert_success
  assert_equal "$("$AQ" show validate-base --json | jq -r '"\(.hold // "")|\(.stacked_on)"')" "|base=Org/game#7"
  # The phase's landing follow-up waits on base too: a landing is no plan phase.
  "$AQ" set phase pr=Org/game#8 >/dev/null
  run env AGENT_QUEUE_ITEM=phase CLAUDE_CODE_ENTRYPOINT= "$AQ" add --project level --priority low --slug l1 "land PR 8"
  assert_failure 5
  assert_output --partial "(#after/lv-1)"
}

# plan dispatch-event-wake: the wake file is what fleet-dispatch-kick.path watches. One write in item_event
# covers every transition, so a start (queued -> running) is no event and a kick's own starts wake nothing.
@test "an item added to the queue or closed wakes a dispatch kick; a start, a set and a running add do not (dispatch-event-wake)" {
  export FLEET_DISPATCH_DIR="$SANDBOX/dispatch"
  wake="$FLEET_DISPATCH_DIR/.wake"
  "$AQ" add --project game --slug w1 "w1"
  grep -q 'item-added w1' "$wake" || fail "an add wrote no wake: $(cat "$wake" 2>/dev/null)"
  rm -f "$wake"
  "$AQ" set w1 session=game-agent-1 account=main
  "$AQ" move w1 running
  "$AQ" move w1 waiting
  "$AQ" move w1 review
  [ ! -e "$wake" ] || fail "a set or a move to running, waiting or review wrote a wake"
  "$AQ" move w1 done --status ok
  grep -q 'item-moved w1' "$wake" || fail "a close wrote no wake"
  rm -f "$wake"
  "$AQ" add --running --project game --slug w2 "w2"
  [ ! -e "$wake" ] || fail "an add of a running item wrote a wake"
  "$AQ" add --project game --slug w3 "w3"
  rm -f "$wake"
  "$AQ" cancel w3 --why "not wanted"
  grep -q 'w3' "$wake" || fail "a cancel wrote no wake"
}
