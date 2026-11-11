#!/usr/bin/env bats
# fleet-dispatch, reap: settling finished, lost and parked sessions and their queue items.
# One file of six (tests/unit/fleet_dispatch*.bats), split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

@test "reap: a gone session with no PR but its report recorded closes its item ok, not failed" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug d "research(game): which engine"
  stub wt 'echo "game-d"'
  cmd_start --item d >/dev/null
  agent-queue set d report="$SANDBOX/doc.md" ask=abc123
  run cmd_reap
  assert_success
  refute_output --partial 'failed queue item d'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-d.md)" status)" ok
}

@test "unpark: a preempt ledger is resumed when its units are free and no urgent item waits; a budget park is not" {
  five_of_six_units
  park_stub
  ledger game-agent-l1 preempt
  ledger game-agent-h1 park
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'claude-acct unpark game-agent-l1'
  assert_not_called 'claude-acct unpark game-agent-h1'
}

@test "unpark: a preempt ledger waits while an urgent item is runnable, or while its units are not free" {
  six_of_six_units
  ledger game-agent-l2 preempt
  agent-queue add --project game --slug now-one --priority urgent "now one" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'claude-acct unpark'
  # l2's parked unit was free, so the urgent item started in it and waits no more
  [ -n "$(qitem running now-one)" ] || fail "the urgent item did not start"
  # l2 parked frees its unit, which a new runner session then took: 6 of 6 again
  started_item l3 lab:game-agent-l3 run area-l3
  echo game-agent-l3 >> "$NOTES_FIXTURE/tmux.sessions.lab"
  : > "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'claude-acct unpark'
}

@test "reap queues the open phases of an approved plan whose session is gone, as low night items, and starts nothing" {
  stub agent-ask 'echo other-session'
  approved_plan orphan gone-session
  run reconcile_plans
  assert_success
  run agent-queue list --json --state queued
  assert_equal "$(jq -r .slug <<<"$output" | paste -sd,)" 'orphan-p2,orphan-p3'
  assert_equal "$(jq -r .tags <<<"$output" | sort -u)" 'night'
  assert_equal "$(jq -r .from <<<"$output" | sort -u)" 'auto:plans'
  assert_equal "$(jq -r .priority <<<"$output" | sort -u)" 'low'
  grep -q 'orphan.md for the night' "$FLEET_DISPATCH_DIR/log.md"
}

@test "reap queues nothing for a live session, a recent transcript, a finished plan or a plan an item names" {
  stub agent-ask 'echo live-session'
  approved_plan live live-session
  approved_plan fresh fresh-session
  mkdir -p "$HOME/.claude-x/projects/p"; : > "$HOME/.claude-x/projects/p/fresh-session.jsonl"
  approved_plan finished gone-session '- [x] one\n- [-] two'
  approved_plan none gone-session 'no checklist here'
  approved_plan named gone-session
  agent-queue add --project game --from shepherd --slug peer "carry on with $SANDBOX/named.md" >/dev/null
  run reconcile_plans
  assert_success
  assert_equal "$(agent-queue list --json --state queued | jq -r .slug)" peer
}

@test "reap reads a queue too big for one argument: plans_orphaned finds the orphan and honours an item that names a plan" {
  stub agent-ask 'echo other-session'
  approved_plan orphan gone-session
  approved_plan named gone-session
  # 600 items of about 1 KB each: past MAX_ARG_STRLEN (128 KB), so --argjson would fail with E2BIG
  stub agent-queue 'pad=$(head -c 1000 /dev/zero | tr "\0" x)
for i in $(seq 600); do printf "{\"slug\":\"i%s\",\"task\":\"%s\"}\n" "$i" "$pad"; done
printf "{\"slug\":\"last\",\"task\":\"carry on with %s/named.md\"}\n" "'"$SANDBOX"'"'
  run plans_orphaned
  assert_success
  assert_equal "$(jq -r .plan <<<"$output")" "$SANDBOX/orphan.md"
}

@test "reap acts on nothing when it cannot read the sessions, or when reconcile is off" {
  approved_plan orphan gone-session
  stub agent-ask 'exit 1'
  run reconcile_plans
  assert_equal "$(agent-queue list --json --state queued | jq -r .slug)" ''
  stub agent-ask 'echo other-session'
  DISPATCH_PLAN_RECONCILE=0 run reconcile_plans
  assert_equal "$(agent-queue list --json --state queued | jq -r .slug)" ''
}

@test "reap queues a plan once: a phase that failed or was cancelled does not come back" {
  stub agent-ask 'echo other-session'
  approved_plan orphan gone-session
  reconcile_plans
  agent-queue cancel orphan-p3 >/dev/null
  agent-queue cancel orphan-p2 >/dev/null
  run reconcile_plans
  assert_success
  assert_equal "$(agent-queue list --json --state queued | jq -r .slug)" ''
}

@test "reap fails a board item whose session ended without closing it, un-starts its row, records failed" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  started_item fix-crash lab:game-agent-1 run '' 'board:game:fix crash'
  run cmd_reap
  assert_success
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "row still started"
  assert_equal "$(jq -r .verdict "$FLEET_DISPATCH_DIR/verdicts.jsonl")" failed
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" failed
}

@test "reap leaves a board item its session closed ok, and its row, alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [x] fix crash'
  started_item fix-crash lab:game-agent-1 run '' 'board:game:fix crash'
  agent-queue move fix-crash done --status ok >/dev/null
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  assert_not_called 'start'
  # Closed, it holds no slot even while the human reuses its tmux session.
  run live_runs
  assert_output ''
}

@test "reap leaves a live session's item running while it neither waits nor asks" {
  project game beta "$SANDBOX/repos/game"
  started_item fix-crash lab:game-agent-1 run
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  assert_success
  [ -n "$(qitem running fix-crash)" ] || fail "moved a working session's item"
  # 2026-11-04: the weight field after state read as "runningheavy", and every pass re-moved every live item.
  ! grep -q reaped "$FLEET_DISPATCH_DIR/log.md" 2>/dev/null || fail "reaped an item already in its state: $(cat "$FLEET_DISPATCH_DIR/log.md")"
  assert_not_called 'start'
}

# 2026-11-03: a plan item sat in running/ at its plan, and the Overview's "Waiting for you" was empty.
@test "reap moves an item to waiting while its session waits on the human or stopped on a pending ask, and back after" {
  project game beta "$SANDBOX/repos/game"
  started_item p lab:game-agent-1
  started_item q lab:game-agent-2
  started_item r lab:game-agent-3
  started_item s lab:game-agent-4
  printf 'game-agent-%s\n' 1 2 3 4 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'for x in 1:waiting 2:idle 3:busy 4:shell; do echo "{\"target\":\"lab/game-agent-${x%:*}:1\",\"status\":\"${x#*:}\"}"; done'
  stub agent-ask 'for n in 2 3 4; do printf "a$n\tgame\t\tpending\tquestion\tq?\ta|b\t\t\t\tb\t2026-11-03\tgame-agent-$n\n"; done'
  run cmd_reap
  assert_success
  [ -n "$(qitem waiting p)" ] || fail "the session at its plan is not waiting"
  [ -n "$(qitem waiting q)" ] || fail "the session stopped on a pending ask is not waiting"
  # carrying on past its ask: busy, or in a shell (agent-panel's own working pair, so a gate never flaps)
  [ -n "$(qitem running r)" ] && [ -n "$(qitem running s)" ] || fail "a session still working past its ask moved to waiting"

  stub agent-panel 'printf "%s\n" "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\"}" "{\"target\":\"lab/game-agent-2:1\",\"status\":\"idle\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem running p)" ] && [ -n "$(qitem running q)" ] || fail "an answered session stayed waiting"
}

@test "reap leaves a live session's item in review while it works at its PR, and moves it to waiting only when it asks the human" {
  project game beta "$SANDBOX/repos/game"
  started_item v lab:game-agent-1 '' '' human review
  started_item w lab:game-agent-2 '' '' human review
  sed -i "s/^started: .*/&\nreview: 2026-11-03T11:00:00Z/" "$AGENT_QUEUE_DIR"/review/*-w.md
  printf 'game-agent-%s\n' 1 2 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'for x in 1:idle 2:waiting; do echo "{\"target\":\"lab/game-agent-${x%:*}:1\",\"status\":\"${x#*:}\"}"; done'
  stub agent-ask 'exit 0'
  run cmd_reap
  assert_success
  [ -n "$(qitem review v)" ] || fail "a session idle at its PR left review"
  [ -n "$(qitem waiting w)" ] || fail "a session on a PR that asks the human is not waiting"
  stub agent-panel 'for x in 1:idle 2:idle; do echo "{\"target\":\"lab/game-agent-${x%:*}:1\",\"status\":\"${x#*:}\"}"; done'
  run cmd_reap
  assert_success
  [ -n "$(qitem review w)" ] || fail "an answered session on a PR did not go back to review"
}

# 2026-11-05: about a fifth of running items were dead: a shell kept the tmux session after claude
# exited, or a hub-window item had no session of its own, and reap read both as live forever.
@test "reap settles an item whose claude exited though its tmux session lives; a parked pane, a live Codex run and a fresh start are kept" {
  project game beta "$SANDBOX/repos/game"
  started_item gone lab:game-agent-1
  started_item parked lab:game-agent-2
  started_item codex lab:game-agent-3
  sed -i 's/^agent: claude/agent: codex/' "$AGENT_QUEUE_DIR"/running/*-codex.md
  started_item fresh lab:game-agent-4
  sed -i "s/^started: .*/started: $(date -u +%FT%TZ)/" "$AGENT_QUEUE_DIR"/running/*-fresh.md
  started_item kept lab:game-agent-5
  printf 'game-agent-%s\n' 1 2 3 4 5 > "$NOTES_FIXTURE/tmux.sessions.lab"
  mkdir -p "$HOME/.agent/parked"; : > "$HOME/.agent/parked/game-agent-2:1"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-5:1\",\"status\":\"busy\",\"session_id\":\"s5\"}"'
  stub agent-ask 'exit 0'
  codex_run codex   # its Codex run is live (codex_gone has its own test)
  export DISPATCH_REAP_CONFIRM=0   # the second witness has its own test
  cmd_reap >/dev/null
  run cmd_reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-gone.md 2>/dev/null)" ] || fail "an item whose claude exited stayed active"
  for k in parked codex fresh kept; do [ -n "$(qitem running "$k")" ] || fail "reaped $k"; done
}

@test "reap: a Codex item whose tmux session a Claude item took over settles once its run is gone, on two reaps (ar-1087)" {
  project game beta "$SANDBOX/repos/game"
  started_item cxgone lab:game-agent-7 && started_item cxlive lab:game-agent-8 && started_item claudeitem lab:game-agent-7
  sed -i 's/^agent: claude/agent: codex/' "$AGENT_QUEUE_DIR"/running/*-cxgone.md "$AGENT_QUEUE_DIR"/running/*-cxlive.md
  printf 'game-agent-%s\n' 7 8 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-7:1\",\"status\":\"busy\",\"session_id\":\"c7\"}"'
  stub agent-ask 'exit 0'
  codex_run cxlive claudeitem   # a process that is not the launcher's would not be listed; the slug decides
  cmd_reap >/dev/null
  [ -n "$(qitem running cxgone)" ] || fail "one reap is one witness, and it settled"
  grep -q "queue item cxgone's Codex run is not live" "$FLEET_DISPATCH_DIR/log.md" || fail "no miss logged: $(cat "$FLEET_DISPATCH_DIR/log.md")"
  echo $(( $(date +%s) - DISPATCH_REAP_CONFIRM - 1 )) > "$FLEET_DISPATCH_DIR/reap-miss/cxgone"
  run cmd_reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cxgone.md 2>/dev/null)" ] || fail "a Codex item whose run is gone stayed active"
  for k in cxlive claudeitem; do [ -n "$(qitem running "$k")" ] || fail "reaped $k"; done
  # pgrep failing cannot tell, and cannot-tell is live (negative control)
  started_item cxblind lab:game-agent-8
  sed -i 's/^agent: claude/agent: codex/' "$AGENT_QUEUE_DIR"/running/*-cxblind.md
  stub pgrep 'exit 3'
  export DISPATCH_REAP_CONFIRM=0
  cmd_reap >/dev/null; cmd_reap >/dev/null
  [ -n "$(qitem running cxblind)" ] || fail "reaped a Codex item on a pgrep that could not read"
  # a listed run whose environment will not read cannot tell either; one that exited (no dir) is skipped
  mkdir -p "$DISPATCH_PROC/4999"; printf 'AGENT_QUEUE_ITEM=x\0' > "$DISPATCH_PROC/4999/environ"; chmod 000 "$DISPATCH_PROC/4999/environ"
  stub pgrep "[ \"\$*\" = \"-u $(id -u) -f agent-codex (run|resume)\" ] || exit 2; echo 4998; echo 4999"
  cmd_reap >/dev/null; cmd_reap >/dev/null
  [ -n "$(qitem running cxblind)" ] || fail "reaped a Codex item on an environment that would not read"
  chmod 600 "$DISPATCH_PROC/4999/environ"
  stub pgrep "[ \"\$*\" = \"-u $(id -u) -f agent-codex (run|resume)\" ] || exit 2; echo 4998"
  cmd_reap >/dev/null; cmd_reap >/dev/null
  [ -z "$(qitem running cxblind)" ] || fail "a run that exited after pgrep listed it kept its item live"
}

@test "reap settles a hub-window item once none of its Claude sessions is live, and keeps one whose session is" {
  project game beta "$SANDBOX/repos/game"
  started_item hubgone '' && started_item hublive ''
  sed -i '/^session: *$/d; s/^agent: claude/agent: claude\nsessions: h1 h2/' "$AGENT_QUEUE_DIR"/running/*-hubgone.md
  sed -i '/^session: *$/d; s/^agent: claude/agent: claude\nsessions: h3/' "$AGENT_QUEUE_DIR"/running/*-hublive.md
  stub agent-panel 'echo "{\"target\":\"hub/dotfiles:2\",\"status\":\"idle\",\"session_id\":\"h3\"}"'
  stub agent-ask 'exit 0'
  export DISPATCH_REAP_CONFIRM=0   # the second witness has its own test
  cmd_reap >/dev/null
  run cmd_reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-hubgone.md 2>/dev/null)" ] || fail "a hub item with no live session stayed active"
  [ -n "$(qitem running hublive)" ] || fail "reaped a hub item whose session is live"
  grep -q 'reaped h2' "$FLEET_DISPATCH_DIR/log.md" || fail "the log does not name the session: $(cat "$FLEET_DISPATCH_DIR/log.md")"
  stub agent-panel 'exit 0'
  started_item hubblind ''
  sed -i '/^session: *$/d; s/^agent: claude/agent: claude\nsessions: h9/' "$AGENT_QUEUE_DIR"/running/*-hubblind.md
  cmd_reap >/dev/null
  run cmd_reap
  [ -n "$(qitem running hubblind)" ] || fail "reaped on an empty panel"
}

# PRs #909 and #910: their items recorded no session, so reap never read them. NEGATIVE CONTROL: with
# item_sessions dropping such an item, the merged one stays waiting and nothing is flagged.
@test "reap: an item with no session settles by its PR, and is flagged once when it cannot" {
  pr_item MERGED
  agent-queue move fix-crash waiting >/dev/null
  sed -i '/^session: /d' "$AGENT_QUEUE_DIR"/waiting/*-fix-crash.md
  started_item nopr '' '' '' human waiting
  sed -i '/^session: *$/d' "$AGENT_QUEUE_DIR"/waiting/*-nopr.md
  run cmd_reap
  assert_success
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" merged)" "ok $OID"
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  # No PR: no witness says it ended, so it is never failed, and the flag says what to do.
  [ -n "$(qitem waiting nopr)" ] || fail "moved an item nothing says has ended"
  assert_output --partial 'flagged queue item nopr (no session recorded: nothing watches this item'
  assert_equal "$(qfield "$(qitem waiting nopr)" note)" 'no session recorded: nothing watches this item; agent-queue claim it from a session, or close it'
  run cmd_reap
  refute_output --partial 'flagged queue item nopr'
  run grep -c 'queue item nopr: no session recorded' "$FLEET_DISPATCH_DIR/log.md"
  assert_output 1
  run live_runs
  assert_output ''
  # A claim gives it a witness: from then on it is an ordinary item, flagged no more.
  agent-queue claim nopr --sid live-1 >/dev/null
  stub agent-panel 'echo "{\"target\":\"hub/d:1\",\"status\":\"busy\",\"session_id\":\"live-1\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem running nopr)$(qitem waiting nopr)" ] || fail "a claimed live item closed"
}

@test "reap: an item with no session and an open or closed PR parks or fails on it, flagged while it is open" {
  pr_item OPEN
  sed -i '/^session: /d' "$AGENT_QUEUE_DIR"/running/*-fix-crash.md
  run cmd_reap
  assert_success
  [ -n "$(qitem review fix-crash)" ] || fail "an open PR did not park it in review"
  assert_output --partial 'flagged queue item fix-crash (no session recorded (PR o/game#12)'
  # Parked on its open PR, later passes neither flag it again nor record another reap.
  run cmd_reap
  refute_output --partial 'flagged queue item fix-crash'
  run grep -c 'action reaped --from game --item fix-crash' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  printf 'CLOSED \n' > "$NOTES_FIXTURE/pr.state"
  run cmd_reap
  assert_success
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" failed
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.agent" || fail "the row was not handed back"
  refute_output --partial 'flagged queue item fix-crash'
}

@test "reap: an item with no session and a report is done; a flag keeps the note it had" {
  started_item withreport '' && started_item noted ''
  agent-queue set withreport report=/tmp/r.md >/dev/null
  agent-queue set noted 'note=waiting on the vendor' >/dev/null
  run cmd_reap
  assert_success
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-withreport.md)" status)" ok
  assert_equal "$(qfield "$(qitem running noted)" note)" 'no session recorded: nothing watches this item; agent-queue claim it from a session, or close it; was: waiting on the vendor'
  run cmd_reap
  refute_output --partial 'flagged queue item noted'
}

@test "reap leaves an item with no session alone inside its start grace" {
  started_item fresh '' '' '' human
  sed -i "/^session: *\$/d; s/^started: .*/started: $(date -u +%FT%TZ)/" "$AGENT_QUEUE_DIR"/running/*-fresh.md
  run cmd_reap
  assert_success
  refute_output --partial 'flagged'
  [ -n "$(qitem running fresh)" ] || fail "moved a fresh item"
}

# 2026-11-07 ar-900: one agent-panel read under load 33 left a live session out, and reap failed an
# urgent item whose re-read a minute later listed it. A miss is one witness; the gone verdict needs a
# second reap, DISPATCH_REAP_CONFIRM seconds or more later, that misses it too.
@test "reap fails a live-looking item only on two misses: one miss keeps it, a sighting between resets it, a quick re-run is no witness" {
  project game beta "$SANDBOX/repos/game"
  started_item flaky lab:game-agent-1 '' '' board:game:gm-7
  sed -i 's/^agent: claude/agent: claude\nsessions: s1\nrow: game:gm-7/' "$AGENT_QUEUE_DIR"/running/*-flaky.md
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-ask 'exit 0'
  miss() { stub agent-panel 'echo "{\"target\":\"lab/other-agent-9:1\",\"status\":\"busy\",\"session_id\":\"s9\"}"'; }
  seen() { stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\",\"session_id\":\"s1\"}"'; }
  mark="$FLEET_DISPATCH_DIR/reap-miss/flaky"
  # The 09:35 read: a non-empty panel that leaves the session out. One miss is not the verdict.
  miss; run cmd_reap; assert_success
  [ -n "$(qitem running flaky)" ] || fail "one agent-panel miss failed the item"
  [ -s "$mark" ] || fail "the miss was not recorded"
  # A re-run seconds later shares the same load, so it is no second witness.
  run cmd_reap
  [ -n "$(qitem running flaky)" ] || fail "a re-run inside DISPATCH_REAP_CONFIRM counted as a second witness"
  # The next read lists it: the miss is forgotten, and a later single miss starts over.
  seen; run cmd_reap
  [ -n "$(qitem running flaky)" ] && [ ! -e "$mark" ] || fail "a sighting did not clear the miss"
  miss; run cmd_reap
  [ -n "$(qitem running flaky)" ] || fail "a miss after a sighting failed the item"
  # A second miss a reap later (the mark aged past DISPATCH_REAP_CONFIRM) settles it, and its close
  # drops the mark at once, so an item agent-queue reopen puts back starts with no miss on record.
  echo $(( $(date +%s) - DISPATCH_REAP_CONFIRM - 1 )) > "$mark"
  run cmd_reap; assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-flaky.md 2>/dev/null)" ] || fail "two misses a reap apart did not settle the item"
  [ ! -e "$mark" ] || fail "the closed item's mark survived its close"
  # A mark whose slug is no longer active (an item closed some other way) is pruned on a pass that read
  # active items; a pass that read none (the queue may not have been readable) keeps them.
  echo 1 > "$mark"
  run cmd_reap
  [ -e "$mark" ] || fail "a pass that read no active item pruned the marks"
  started_item other lab:game-agent-1
  run cmd_reap
  [ ! -e "$mark" ] || fail "a stale mark survived a reap that read active items"
}

# steam-beta-cut-1106 was failed "session ended" while its Claude worked: agent-panel left it out.
@test "reap keeps an item whose recorded Claude process is running though agent-panel leaves it out, and settles it once the process is gone" {
  project game beta "$SANDBOX/repos/game"
  started_item busy lab:game-agent-1
  sed -i 's/^agent: claude/agent: claude\nsessions: s1 s2/' "$AGENT_QUEUE_DIR"/running/*-busy.md
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-ask 'exit 0'
  stub agent-panel 'echo "{\"target\":\"lab/other-agent-9:1\",\"status\":\"busy\",\"session_id\":\"s9\"}"'
  export DISPATCH_REAP_CONFIRM=0
  tail -f /dev/null >/dev/null 2>&1 3>&- & pid=$!   # sleep is a stub here
  mkdir -p "$HOME/.claude-bnb/sessions"
  jq -nc --argjson p "$pid" '{pid: $p, sessionId: "s2"}' > "$HOME/.claude-bnb/sessions/$pid.json"
  cmd_reap >/dev/null; cmd_reap >/dev/null; cmd_reap >/dev/null
  [ -n "$(qitem running busy)" ] || { kill "$pid"; fail "reaped an item whose Claude process is running"; }
  # procStart is the pid's /proc start time: a match keeps the item, a different one is a reused pid.
  st=$(sed 's/.*) //' "/proc/$pid/stat" | cut -d' ' -f20)
  jq -nc --argjson p "$pid" --arg s "$st" '{pid: $p, sessionId: "s2", procStart: $s}' > "$HOME/.claude-bnb/sessions/$pid.json"
  echo '{"pid": 1' > "$HOME/.claude-bnb/sessions/0.json"   # a half-written file hides no other
  cmd_reap >/dev/null; cmd_reap >/dev/null
  [ -n "$(qitem running busy)" ] || { kill "$pid"; fail "a matching procStart did not keep the item"; }
  jq -nc --argjson p "$pid" '{pid: $p, sessionId: "s2", procStart: "1"}' > "$HOME/.claude-bnb/sessions/$pid.json"
  cmd_reap >/dev/null; cmd_reap >/dev/null
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-busy.md 2>/dev/null)" ] || { kill "$pid"; fail "a reused pid kept the item"; }
  rm -f "$FLEET_DISPATCH_DIR"/reap-miss/*
  agent-queue reopen busy --why test >/dev/null
  # A pid file for another session id, or a dead pid, is not this item's Claude.
  jq -nc --argjson p "$pid" '{pid: $p, sessionId: "other"}' > "$HOME/.claude-bnb/sessions/$pid.json"
  cmd_reap >/dev/null; cmd_reap >/dev/null
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-busy.md 2>/dev/null)" ] || { kill "$pid"; fail "another session's process kept the item"; }
  kill "$pid"; wait "$pid" 2>/dev/null || true
  rm -f "$FLEET_DISPATCH_DIR"/reap-miss/*
  agent-queue reopen busy --why test >/dev/null
  jq -nc --argjson p "$pid" '{pid: $p, sessionId: "s2"}' > "$HOME/.claude-bnb/sessions/$pid.json"
  cmd_reap >/dev/null; cmd_reap >/dev/null
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-busy.md 2>/dev/null)" ] || fail "a dead pid kept the item"
}

# Confirmed gone stays gone: settle_item leaves an item whose PR is open waiting, and it must not
# re-enter the mark-then-confirm cycle, logging a fresh miss and settling half as often.
@test "reap keeps a confirmed miss for an item it parks in review on its open PR" {
  pr_item OPEN
  agent-queue move fix-crash waiting >/dev/null
  sed -i 's/^agent: claude$/agent: claude\nsessions: old-1/' "$AGENT_QUEUE_DIR"/waiting/*-fix-crash.md
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\",\"session_id\":\"new-1\"}"'
  stub agent-ask 'exit 0'
  export DISPATCH_REAP_CONFIRM=0
  for _ in 1 2 3 4; do cmd_reap >/dev/null; done
  [ -n "$(qitem review fix-crash)" ] || fail "the item did not park in review"
  [ -e "$FLEET_DISPATCH_DIR/reap-miss/fix-crash" ] || fail "the confirmed mark was dropped"
  run grep -c 'is not on agent-panel' "$FLEET_DISPATCH_DIR/log.md"
  assert_output 1
}

@test "reap moves nothing when it cannot read the sessions or the asks" {
  project game beta "$SANDBOX/repos/game"
  started_item p lab:game-agent-1 '' '' human waiting
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'exit 1'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem waiting p)" ] || fail "moved an item on an unreadable agent-panel"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\"}"'
  stub agent-ask 'exit 1'
  run cmd_reap
  [ -n "$(qitem waiting p)" ] || fail "moved an item on an unreadable agent-ask"
}

@test "reap reads the server from the item: a live session on default is kept, one gone from it is settled" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  started_item fix-crash default:game-agent-1 run '' 'board:game:fix crash'
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  stub agent-panel 'exit 0'; stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem running fix-crash)" ] || fail "reaped a session live on the server its item names"
  assert_not_called 'start'

  # The same name live on lab only is not this session.
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  [ -z "$(qitem running fix-crash)" ] || fail "kept an item whose session is gone from its server"
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "row still started"
}

@test "cleanup lane: a tier-3 cleanup row S or M is a merging item at noon behind the red-fix gate; feat, a deps bump, L and night rows are not" {
  night_ready
  export AGENT_QUEUE_NIGHT=01:00-06:00 AGENT_QUEUE_NOW=12:00
  row agent-runtime agent 'drop the dead timer' '- [ ] chore(timer): drop the dead timer #tier/3 #low'
  row agent-runtime agent 'prune the hooks' '- [ ] refactor(hooks): prune the dead hooks #tier/3'
  row agent-runtime agent 'add a panel' '- [ ] feat(panel): add a timer panel #tier/3'
  # A chore that bumps a dependency is shared infrastructure (DISPATCH_CLEANUP_NOT), not cleanup.
  row agent-runtime agent 'bump jq' '- [ ] chore(deps): bump jq to 1.8 #tier/3'
  night_verdict 'drop the dead timer' timer; night_verdict 'prune the hooks' hooks true L; night_verdict 'add a panel' panel; night_verdict 'bump jq' jq

  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "ready") | "\(.key) \(.worker)"' <<<"$output")" 'drop the dead timer tier3-cleanup'
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | sort | paste -sd, -)" 'add a panel,bump jq'
  fill
  assert_success
  f=$(agent-queue list --json --state queued | jq -r 'select(.title | test("drop the dead timer")) | .slug')
  [ -n "$f" ] || fail "the cleanup row was not queued"
  run agent-queue show "$f" --json
  assert_equal "$(jq -r '"\(.tags) | \(.priority) | \(.hold // "")"' <<<"$output")" 'cleanup tier3 | high | '
  run item_brief "$output"
  refute_output --partial -- '--pr-only'
  assert_output --partial 'agent-land refuses a tier-3 PR without that line'
  assert_output --partial 'Merge with agent-land'
  # The L cleanup row is neither merging nor night: plan_skips sends it to inbox-plan.
  [ "$(state_of 'prune the hooks')" = '- [ ]' ] || fail "an L cleanup row was started"
  assert_equal "$(night_keys)" 'add a panel,bump jq'
}

@test "cleanup lane: a tier-3 cleanup pick ranks with its project's #prio, as a day pick does" {
  night_ready
  sed -i '1s/$/ #prio\/focus/' "$SANDBOX/sheets/agent-runtime/README.md"
  row agent-runtime agent 'drop the dead timer' '- [ ] chore(timer): drop the dead timer #tier/3'
  night_verdict 'drop the dead timer' timer
  run t3_cleanup_picks "$(night_rows '')"
  assert_success
  assert_equal "$(jq -r '"\(.pprio) \(.why)"' <<<"$output")" '0 cleanup, focus project, tier3-cleanup, #high, alpha'
}

@test "reap closes a queue item whose session ended: ok with a PR, failed without; a closed one is left alone" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug b "do b"
  agent-queue add --project game --slug c "do c"
  stub wt 'echo "game-$WT_N"'
  for s in a b c; do WT_N=$s cmd_start --item "$s" >/dev/null; done
  agent-queue set a pr=12 merged=0123abcd
  agent-queue move c done --status ok
  printf 'game-c\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  assert_success
  assert_output --partial 'failed queue item b'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-a.md)" status)" ok
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-b.md)" status)" failed
}

@test "reap: a waiting item without a PR stays waiting with a note after its session ends" {
  project game beta "$SANDBOX/repos/game"
  started_item blocked lab:game-agent-1 run '' human waiting
  started_item no-note lab:game-agent-2 run '' human waiting
  agent-queue set blocked 'note=waiting for the human to answer ask abc' lane_run=trial-1 >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"'

  run cmd_reap
  assert_success
  refute_output --partial 'failed queue item'
  assert_equal "$(agent-queue show blocked --json | jq -r .state)" waiting
  assert_equal "$(qfield "$(qitem waiting blocked)" note)" 'waiting for the human to answer ask abc'
  assert_equal "$(agent-queue show no-note --json | jq -r .state)" waiting
  assert_equal "$(qfield "$(qitem waiting no-note)" note)" 'session game-agent-2 ended; waiting without a PR'
  assert_not_called 'model-lane'
  mtime=$(stat -c %y "$(qitem waiting blocked)")
  dispatch_event() { echo "$*" >> "$NOTES_FIXTURE/events.log"; }

  run cmd_reap
  assert_success
  assert [ ! -e "$NOTES_FIXTURE/events.log" ]
  assert_equal "$(stat -c %y "$(qitem waiting blocked)")" "$mtime"
  assert_equal "$(agent-queue show blocked --json | jq -r .state)" waiting
  assert_equal "$(agent-queue show no-note --json | jq -r .state)" waiting
  assert_not_called 'model-lane'
}

@test "reap: a gone session's merged PR closes the item ok with merged:, and its started row on merge proof" {
  pr_item MERGED
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" merged)" "ok $OID"
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:12 commit:${OID:0:12}"
  # The reap and the settle are on the chain log, as the runner's own writes.
  run grep -o 'stage dispatch --action [a-z]* --from game --item fix-crash.* -- .*' "$NOTES_FIXTURE/calls.log"
  assert_output - <<OUT
stage dispatch --action reaped --from game --item fix-crash --why item was running --by fleet-dispatch -- session game-agent-1 gone
stage dispatch --action settled --from game --item fix-crash --id fix crash --pr o/game#12 --sha $OID --by fleet-dispatch -- row closed on merge proof
OUT
}

@test "reap: a merged PR whose commit is not on origin/main closes the item but never the row" {
  pr_item MERGED 0123456789abcdef0123456789abcdef01234567
  run cmd_reap
  assert_success
  refute_output --partial 'closed game'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" ok
  run grep -c 'ptask .* done ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  grep -q 'row left started, no merge proof' "$FLEET_DISPATCH_DIR"/log.md || fail "no reason logged"
}

@test "reap: a gone session's open PR moves its item to review once, row untouched" {
  pr_item OPEN
  run cmd_reap
  assert_output --partial 'review queue item fix-crash (PR o/game#12 open'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" review
  run cmd_reap
  refute_output --partial 'review queue item'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" review
  grep -qF -- '- [/] fix crash' "$NOTES_FIXTURE/rows.game.agent" || fail "row moved"
}

# 2026-11-08 to 11-10: fix-traefik's home-config PR was open on Forgejo, and every reap pass asked gh,
# which sees only the GitHub mirror, and logged "could not read" (270 lines).
@test "reap: a Forgejo-canonical repo's PR is read from its Forgejo API, never gh: merged closes the item and row" {
  fj_item merged success
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" merged)" "ok $OID"
  run grep -c '^gh pr view' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  grep -qx 'https://git.example.test/api/v1/repos/o/game/pulls/12' "$NOTES_FIXTURE/fj.urls" || fail "Forgejo not asked"
  run grep -c sekret-token "$NOTES_FIXTURE/fj.urls"
  assert_output 0
  # every read, the checks too, carries the token on stdin, and rbw is asked once
  run grep -vc 'header = "Authorization: token sekret-token"' "$NOTES_FIXTURE/fj.auth"
  assert_output 0
  grep -q '/commits/1111111111111111111111111111111111111111/status' "$NOTES_FIXTURE/fj.auth" || fail "checks not read"
  run grep -c 'rbw get forgejo_repo_admin' "$RBW_FIXTURE/calls.log"
  assert_output 1
}

@test "reap: a Forgejo PR open parks its item in review, then its red check gets a fix-ci owner; closed fails it" {
  fj_item open success
  run cmd_reap
  assert_output --partial 'review queue item fix-crash (PR o/game#12 open'
  # a warning is a pass, as Forgejo's combined state reads it: still parked
  jq -c '.statuses[0].status = "warning"' "$NOTES_FIXTURE/fj.status" > "$NOTES_FIXTURE/s" && mv "$NOTES_FIXTURE/s" "$NOTES_FIXTURE/fj.status"
  run cmd_reap
  refute_output --partial 'fix-ci'
  jq -cn '{state: "failure", statuses: [{status: "failure"}, {status: "success"}]}' > "$NOTES_FIXTURE/fj.status"
  run cmd_reap
  assert_output --partial 'fix-ci queue item fix-crash (PR o/game#12 red at 111111111111, try 1 of 2)'
  agent-queue move fix-crash running >/dev/null; agent-queue set fix-crash session=lab:game-agent-1 >/dev/null
  fj_pr closed
  run cmd_reap
  assert_output --partial 'failed queue item fix-crash (PR o/game#12 closed unmerged)'
}

@test "reap: a Forgejo PR on a host not listed is never asked (no token leaves) and the item is left; a bare pr: needs its Item stamp" {
  fj_item merged success
  SO_FORGEJO_HOSTS=git.other.test run cmd_reap
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" running
  [ ! -e "$NOTES_FIXTURE/fj.urls" ] || fail "an unlisted host was called"
  grep -q 'queue item fix-crash left: could not read PR o/game#12' "$FLEET_DISPATCH_DIR"/log.md || fail "no reason logged"
  # a bare number is read from the project's checkout, and only a PR whose body stamps the item counts
  agent-queue set fix-crash pr=12 >/dev/null
  fj_pr merged "$OID" 'Item: other-item'
  run cmd_reap
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" running
  fj_pr merged
  run cmd_reap
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" ok
}

# 2026-11-09: 16 of 20 PRs parked in review were red and nothing restarted them.
@test "reap: a red PR parked in review gets a fix-ci owner twice per head, then one human-sheet row; a new head starts again" {
  local h1=1111111111111111111111111111111111111111 h2=2222222222222222222222222222222222222222
  pr_item OPEN
  run cmd_reap
  assert_output --partial 'review queue item fix-crash'
  # checks still running or green: it stays parked, no owner
  for ci in PENDING PASS NONE; do
    fix_ended "$h1" "$ci"
    run cmd_reap
    assert_success
    assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" review
  done
  fix_ended "$h1" FAIL
  agent-queue set fix-crash mode=plan >/dev/null
  run cmd_reap
  assert_success
  assert_output --partial "fix-ci queue item fix-crash (PR o/game#12 red at ${h1:0:12}, try 1 of 2)"
  assert_equal "$(agent-queue show fix-crash --json | jq -r '[.state, .fix_tries, .mode] | join("|")')" "queued|1 $h1|oneshot"
  # its brief is the fix, on the PR's own branch, and it never merges
  run item_brief "$(agent-queue show fix-crash --json)"
  assert_line --index 0 '/my:fix-ci o/game#12'
  assert_output --partial 'gh pr checkout 12 -R o/game'
  assert_output --partial 'fix-ci try 1 of 2'
  assert_output --partial 'run agent-queue move fix-crash review'
  refute_output --partial 'Run agent-land in the foreground'
  echo '{"harnesses": {"opencode": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief "$(agent-queue show fix-crash --json)" opencode
  assert_line --index 0 'Read ~/.claude/commands/my/fix-ci.md and follow it for PR o/game#12.'
  # the fix session pushed and it is red again: the second try
  fix_ended "$h2" FAIL
  run cmd_reap
  assert_output --partial 'try 2 of 2'
  # spent: one row on the project's human sheet and one page, the item left parked on its PR
  fix_ended "$h2" FAIL
  run cmd_reap
  assert_output --partial 'human row for queue item fix-crash (PR o/game#12 red after 2 fix-ci tries, on the game sheet)'
  assert_equal "$(agent-queue show fix-crash --json | jq -r '[.state, .fix_human] | join("|")')" "review|$h2"
  assert_called "notes --profile bnb ptask game add fix(ci): PR o/game#12 is red at ${h2:0:12} after 2 fix-ci tries"
  run cmd_reap
  refute_output --partial 'fix-crash'
  assert_equal "$(grep -c 'ptask game add fix(ci)' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(grep -c "agent-notify .*PR o/game#12 red" "$NOTES_FIXTURE/calls.log")" 1
  # the human pushed a new head and it is red: the count starts again
  fix_ended "$h1" FAIL
  run cmd_reap
  assert_output --partial 'try 1 of 2'
  assert_equal "$(agent-queue show fix-crash --json | jq -r '[.state, .fix_human // ""] | join("|")')" "queued|"
}

@test "reap: a red PR in review waits for admission, and an item with no session recorded never reads as gone" {
  pr_item OPEN
  run cmd_reap
  fix_ended 1111111111111111111111111111111111111111 FAIL
  AGENT_QUEUE_ADMIT_MIN=0 run cmd_reap
  assert_success
  assert_equal "$(agent-queue show fix-crash --json | jq -r '[.state, .fix_tries // ""] | join("|")')" "review|"
  AGENT_QUEUE_ADMIT_MIN=0 run cmd_reap
  assert_equal "$(grep -c 'fix-crash: PR o/game#12 red at 111111111111; fix-ci held by admission' "$FLEET_DISPATCH_DIR"/log.md)" 1
  # no session recorded (a cloud run): settle_sessionless keeps it parked, never requeued
  sed -i '/^session: /d; /^sessions: /d' "$(qitem review fix-crash)"
  run cmd_reap
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" review
}

# 2026-11-07: ar-255 sat waiting on its open PR, its lane got a new Claude, and reap read that one
# as the item's: back to running, and fleet-sessions held the new session STALLED on it.
@test "reap: a recycled lane is not the session of an item that records its own ids" {
  pr_item OPEN
  agent-queue move fix-crash waiting >/dev/null
  sed -i 's/^agent: claude$/agent: claude\nsessions: old-1/' "$AGENT_QUEUE_DIR"/waiting/*-fix-crash.md
  started_item mine lab:game-agent-2
  sed -i 's/^agent: claude$/agent: claude\nsessions: s2/' "$AGENT_QUEUE_DIR"/running/*-mine.md
  started_item lane lab:game-agent-3
  started_item away lab:game-agent-4
  sed -i 's/^agent: claude$/agent: claude\nsessions: s4/' "$AGENT_QUEUE_DIR"/running/*-away.md
  printf 'game-agent-%s\n' 1 2 3 4 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'for x in 1:busy:new-1 2:idle:s2 3:busy:s3 4:busy:new-4; do IFS=: read -r n st id <<<"$x"; echo "{\"target\":\"lab/game-agent-$n:1\",\"status\":\"$st\",\"session_id\":\"$id\"}"; done
    echo "{\"target\":\"hub/dotfiles:5\",\"status\":\"waiting\",\"session_id\":\"s4\"}"'
  stub agent-ask 'printf "a1\tgame\t\tpending\tquestion\tq?\ta|b\t\t\t\tb\t2026-11-07\tgame-agent-2\t\t\ts2\n"'
  run cmd_reap
  assert_success
  [ -n "$(qitem waiting fix-crash)" ] || fail "a new Claude in the lane flipped the item back to running"
  # its own Claude, matched by id, stopped on an ask: waiting; no ids recorded: the lane decides
  [ -n "$(qitem waiting mine)" ] || fail "the item's own Claude on a pending ask did not read waiting"
  [ -n "$(qitem running lane)" ] || fail "an item with no ids lost its lane"
  [ -n "$(qitem waiting away)" ] || fail "the flip read the lane's busy Claude, not the item's own waiting one"
  # agent-panel lists no codex thread, so a codex item's ids say nothing and its lane still decides
  started_item cx lab:game-agent-5 '' '' human waiting
  sed -i 's/^agent: claude$/agent: codex\nsessions: thread-1/' "$AGENT_QUEUE_DIR"/waiting/*-cx.md
  printf 'game-agent-%s\n' 1 2 3 4 5 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-5:1\",\"status\":\"waiting\",\"session_id\":\"c5\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem waiting cx)" ] || fail "a codex item's thread ids flipped it to running"
  # a running item whose lane went to another Claude settles on its open PR: the passes above missed it once already
  agent-queue move fix-crash running >/dev/null
  DISPATCH_REAP_CONFIRM=0 run cmd_reap
  assert_output --partial 'review queue item fix-crash (PR o/game#12 open'
  # its own Claude back on the panel: running is left alone
  agent-queue move fix-crash running >/dev/null
  stub agent-panel 'echo "{\"target\":\"hub/dotfiles:3\",\"status\":\"busy\",\"session_id\":\"old-1\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem running fix-crash)" ] || fail "reaped an item whose own Claude is live"
}

@test "reap: an item an older pass parked waiting on its open PR moves to review, and closes ok with merged: once the PR merges" {
  pr_item OPEN
  agent-queue move fix-crash waiting >/dev/null
  run cmd_reap
  assert_output --partial 'review queue item fix-crash (PR o/game#12 open'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" review
  printf 'MERGED %s\n' "$OID" > "$NOTES_FIXTURE/pr.state"
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" merged)" "ok $OID"
}

# 2026-11-10 audit: 4 of 24 Codex runs that asked stopped without `requeue --ask`; their items failed
# or sat in review, and the answer became a board row instead of restarting the work.
@test "reap: a gone session's item with a pending ask for it is held on that ask, with its open PR, and the next brief continues the PR" {
  pr_item OPEN
  agent-queue move fix-crash waiting >/dev/null
  agent-queue set fix-crash "note=pushed the fix, need a call on the API" >/dev/null
  id=$(agent-ask post --project game --task fix-crash --options 'a=keep it|b=drop it' 'keep the old API?')
  run cmd_reap
  assert_success
  assert_output --partial "held queue item fix-crash (ask $id pending, game-agent-1 ended)"
  it=$(agent-queue show fix-crash --json)
  assert_equal "$(jq -r '[.state, .tags, .pr] | join(" ")' <<<"$it")" "queued ask:$id=a+b o/game#12"
  assert_equal "$(jq -r .note <<<"$it")" "session game-agent-1 ended on ask $id; held until the human answers it; was: pushed the fix, need a call on the API"
  run item_brief "$it"
  assert_output --partial 'already opened o/game#12: check out its head branch (gh pr checkout 12 -R o/game)'
}

@test "reap: a gone session's item held only by the ask its ask: field names, with no PR, is held on it" {
  project game beta "$SANDBOX/repos/game"
  started_item p lab:game-agent-1 '' '' human waiting
  id=$(agent-ask post --project game --options 'yes=ship it|no=hold it' 'ship it?')
  agent-queue set p ask="$id" >/dev/null
  run cmd_reap
  assert_success
  assert_equal "$(agent-queue show p --json | jq -r '[.state, .tags] | join(" ")')" "queued ask:$id=yes+no"
  # no PR, so the brief names none: it once said "already opened null" (ar-1583)
  run item_brief "$(agent-queue show p --json)"
  refute_output --partial 'already opened'
}

@test "reap: an answered ask holds nothing, so the unclosed run still fails (negative control)" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  started_item fix-crash lab:game-agent-1 run '' 'board:game:fix crash'
  id=$(agent-ask post --project game --task fix-crash --options 'a=yes|b=no' 'ship it?')
  AGENT_ASK_NO_RESUME=1 agent-ask answer "$id" a >/dev/null 2>&1
  run cmd_reap
  assert_success
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" failed
}

@test "reap: a gone session's item whose after: item is not done goes back to queued behind it, not failed" {
  project game beta "$SANDBOX/repos/game"
  # after: is a list (ar-39): zero is done ok, so first alone still holds.
  agent-queue add --project game --slug zero "the zeroth part" >/dev/null
  agent-queue move zero done --status ok >/dev/null
  agent-queue add --project game --slug first "the first part" >/dev/null
  started_item second lab:game-agent-1
  agent-queue set second after=zero,first >/dev/null
  run cmd_reap
  assert_success
  assert_output --partial 'requeued queue item second (game-agent-1 ended: it waits after first)'
  assert_equal "$(agent-queue show second --json | jq -r '[.state, .hold] | join(":")')" 'queued:after first'
  # Negative control: once its after: item is done, the unclosed run is the run's own failure.
  rm "$AGENT_QUEUE_DIR"/queued/*-second.md
  started_item second lab:game-agent-1
  agent-queue set second after=zero,first >/dev/null
  agent-queue move first done --status ok >/dev/null
  run cmd_reap
  assert_output --partial 'failed queue item second'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-second.md)" status)" failed
}

@test "reap: a gone session's closed PR fails its item and hands the row back" {
  pr_item CLOSED
  run cmd_reap
  assert_output --partial 'failed queue item fix-crash (PR o/game#12 closed unmerged)'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" failed
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.agent" || fail "row still started"
}

@test "reap: a Codex run that hit its usage limit goes back to the queue with end_reason limit and model-lane gets no outcome" {
  codex_end_item th-lim '{"type":"task_complete","error":{"message":"x","codex_error_info":"usage_limit_exceeded"}}'
  run cmd_reap
  assert_output --partial 'requeued queue item cx (game-agent-1 ended: the plan'"'"'s usage limit)'
  [ -z "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cx.md 2>/dev/null)" ] || fail "a limit end is not a failure"
  f=$(ls "$AGENT_QUEUE_DIR"/queued/*-cx.md)
  assert_equal "$(qfield "$f" end_reason) $(qfield "$f" session)" 'limit '
  assert_equal "$(qfield "$f" note)" "session game-agent-1 ended: the plan's usage limit; requeued (end_reason: limit)"
  run grep -F 'model-lane outcome' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "reap: a Codex run that hit its usage limit with its PR open goes back to the queue, not to review, and keeps the PR" {
  codex_end_item th-lim '{"type":"task_complete","error":{"message":"x","codex_error_info":"usage_limit_exceeded"}}'
  agent-queue set cx pr=o/game#12 >/dev/null
  stub gh 'echo OPEN'
  run cmd_reap
  assert_success
  assert_output --partial "requeued queue item cx (game-agent-1 ended: the plan's usage limit, with PR o/game#12 open)"
  it=$(agent-queue show cx --json)
  assert_equal "$(jq -r '[.state, .pr, .end_reason] | join(" ")' <<<"$it")" 'queued o/game#12 limit'
}

@test "reap: a Codex run its login refused (unauthorized) still fails: a requeue would only meet the same refusal (negative control)" {
  codex_end_item th-auth '{"type":"task_complete","error":{"codex_error_info":"unauthorized"}}'
  run cmd_reap
  assert_output --partial 'end_reason refused'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cx.md)" status)" failed
}

@test "reap: a Codex run that ended its turn clean and never closed is stopped, still failed, and still reported to model-lane (negative control)" {
  codex_end_item th-stop '{"type":"task_complete","error":null}'
  run cmd_reap
  assert_output --partial 'end_reason stopped'
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-cx.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" end_reason)" 'failed stopped'
  run grep -F 'model-lane outcome' "$NOTES_FIXTURE/calls.log"
  assert_output 'model-lane outcome r-cx failed'
}

@test "reap: a Codex rollout cut mid-turn is a cut, or a timeout once the launcher's timeout has run; a provider error is provider; neither rates the model" {
  codex_end_item th-cut 'null' 600
  run cmd_reap
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cx.md)" end_reason)" cut
  rm -rf "$AGENT_QUEUE_DIR/done"
  codex_end_item th-tmo 'null' 7100
  run cmd_reap
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cx.md)" end_reason)" timeout
  rm -rf "$AGENT_QUEUE_DIR/done"
  codex_end_item th-prov '{"type":"task_complete","error":{"codex_error_info":"server_overloaded"}}'
  run cmd_reap
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cx.md)" end_reason)" provider
  rm -rf "$AGENT_QUEUE_DIR/done"
  # a variant that carries data is an object keyed by the variant
  codex_end_item th-obj '{"type":"task_complete","error":{"codex_error_info":{"http_connection_failed":{"http_status_code":502}}}}'
  run cmd_reap
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cx.md)" end_reason)" provider
  run grep -F 'model-lane outcome' "$NOTES_FIXTURE/calls.log"
  assert_output 'model-lane outcome r-cx failed'   # only the timeout rated: it is the run's own length
}

@test "reap: a Claude item, and a Codex item whose rollout is missing, record no end_reason" {
  started_item cl lab:game-agent-2 run
  agent-queue set cl lane_run=r-cl >/dev/null
  codex_end_item th-none '{"type":"task_complete","error":null}'
  rm -f "$HOME"/.codex/sessions/2026/11/09/*   # the thread the item names has no rollout
  run cmd_reap
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cl.md)" end_reason)" ''
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cx.md)" end_reason)" ''
}

@test "reap: an item moved while reap reads its PR is left as it is, no note written" {
  pr_item OPEN
  # gh answers after a human requeued the item: the move reap planned is from a state it no longer has.
  stub gh 'agent-queue move fix-crash queued >/dev/null; cat "$NOTES_FIXTURE/pr.state"'
  run cmd_reap
  assert_success
  refute_output --partial 'waiting queue item'
  f=$(qitem queued fix-crash)
  [ -n "$f" ] || fail "the requeue was undone"
  assert_equal "$(qfield "$f" note)" ''
}

@test "reap: a PR gh cannot read leaves the item where it is" {
  pr_item OPEN
  : > "$NOTES_FIXTURE/pr.state"
  run cmd_reap
  assert_success
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" running
}

@test "reap: an agent row started with no queue item is un-started only once it stays orphaned DISPATCH_ORPHAN_HOURS" {
  export DISPATCH_NIGHT_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 '- [/] fix x <!-- id:gm-1 -->'
  run cmd_reap
  assert_success
  grep -qF -- '- [/] fix x' "$NOTES_FIXTURE/rows.game.agent" || fail "un-started on first sight"
  grep -qP '^bnb\tgame\tgm-1\t[0-9]+$' "$FLEET_DISPATCH_DIR/orphans.tsv" || fail "first sighting not recorded"
  : > "$FLEET_DISPATCH_DIR/orphans.tsv"; orphan_seen game gm-1 73
  run cmd_reap
  assert_output --partial 'un-started game: gm-1'
  grep -qF -- '- [ ] fix x' "$NOTES_FIXTURE/rows.game.agent" || fail "row still started"
  assert_equal "$(jq -r 'select(.key == "gm-1") | .verdict + ": " + .reason' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'failed: started 72h with no queue item'
  ! grep -q gm-1 "$FLEET_DISPATCH_DIR/orphans.tsv" || fail "un-started row still tracked"
}

@test "reap: a done item's PR merged after its session closed it records merged: and closes the row on merge proof" {
  landed_item MERGED
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .merged)" "$OID"
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:12 commit:${OID:0:12}"
}

@test "reap: a done item with merged: recorded closes its row with no gh call" {
  landed_item MERGED
  agent-queue set fix-crash "merged=$OID" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run cmd_reap
  assert_output --partial 'closed game: fix crash'
  ! grep -q '^gh ' "$NOTES_FIXTURE/calls.log" || fail "read gh for a recorded merge"
}

@test "reap: an item with one PR per repo closes its row on its first PR's merge proof" {
  # NEGATIVE CONTROL: the whole list as one ref gave merge_proof "pr 9" and a two-sha commit, so no proof.
  landed_item MERGED 'o/game#12 o/tools#9'
  agent-queue set fix-crash "merged=$OID 1111111111111111111111111111111111111111" >/dev/null
  run cmd_reap
  assert_output --partial 'closed game: fix crash'
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:12 commit:${OID:0:12}"
}

@test "reap: an item whose PR is in another of the project's repos proves its commit in that repo's checkout" {
  # NEGATIVE CONTROL: proved in the project's own checkout (game), the tools commit read
  # "evidence ... is not a commit in .../repos/game" and the row stayed started every pass (ar-965).
  landed_item MERGED 'o/tools#9'
  git init -q --bare "$SANDBOX/tools.git"
  git -c init.defaultBranch=main init -q "$SANDBOX/repos/tools"
  git -C "$SANDBOX/repos/tools" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "tools fix (#9)"
  git -C "$SANDBOX/repos/tools" remote add origin "$SANDBOX/tools.git"
  git -C "$SANDBOX/repos/tools" push -q origin HEAD:main
  TOID=$(git -C "$SANDBOX/repos/tools" rev-parse HEAD)
  jq --arg d "$SANDBOX/repos/tools" '.trackers.tools = {repo: "tools"} | .paths[$d] = "tools"' "$DISPATCH_PROJECT_MAP" > "$SANDBOX/map.next"
  mv "$SANDBOX/map.next" "$DISPATCH_PROJECT_MAP"
  agent-queue set fix-crash "merged=$TOID" >/dev/null
  run cmd_reap
  assert_output --partial 'closed game: fix crash'
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:9 commit:${TOID:0:12}"
}

@test "reap: an item whose PR names a repo with no checkout leaves its row started" {
  landed_item MERGED 'o/tools#9'
  agent-queue set fix-crash "merged=$OID" >/dev/null
  run cmd_reap
  refute_output --partial 'closed game'
  grep -qF 'no merge proof: no checkout of the repo o/tools#9 names' "$FLEET_DISPATCH_DIR"/log.md || fail "no reason logged"
}

@test "reap: a done item's open PR keeps its row started past the orphan grace" {
  landed_item OPEN
  orphan_seen game 'fix crash' 73
  run cmd_reap
  assert_success
  refute_output --partial 'un-started'
  grep -qF -- '- [/] fix crash' "$NOTES_FIXTURE/rows.game.agent" || fail "row lost its start"
}

@test "reap: a done item's PR closed unmerged leaves the row to the orphan timer" {
  landed_item CLOSED
  orphan_seen game 'fix crash' 73
  run cmd_reap
  assert_output --partial 'un-started game: fix crash'
}

@test "reap: a bare pr: reads the project's checkout and counts a PR whose body has the item's stamp" {
  bare_pr $'Summary\r\nItem: fix-crash\r\nTask: gm-1'
  run cmd_reap
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR 12 merged)'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .merged)" "$OID"
  grep -q "^gh pr view 12 .* in $SANDBOX/repos/game$" "$NOTES_FIXTURE/calls.log" || fail "not read from the project's checkout"
}

@test "reap: a bare pr: whose PR stamps another item, even one this slug prefixes, never closes the row" {
  bare_pr $'Summary\nItem: fix-crash-two'
  run cmd_reap
  assert_success
  refute_output --partial 'closed game'
  assert_equal "$(agent-queue show fix-crash --json | jq -r '.merged // "none"')" none
}

@test "reap: a row an active item names, and a human-lane row, are never orphans" {
  export DISPATCH_NIGHT_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  row game agent gm-2 '- [/] linked <!-- id:gm-2 -->'
  row game human 'mine' '- [/] the human is on it'
  started_item linked lab:game-agent-9 '' '' 'board:game:gm-2' queued
  sed -i 's/^lane: human$/lane: agent/' "$AGENT_QUEUE_DIR"/queued/*-linked.md
  orphan_seen game gm-2 96
  run cmd_reap
  assert_success
  grep -qF -- '- [/] linked' "$NOTES_FIXTURE/rows.game.agent" || fail "a linked row was un-started"
  grep -qF -- '- [/] the human is on it' "$NOTES_FIXTURE/rows.game.human" || fail "a human row was un-started"
  [ ! -s "$FLEET_DISPATCH_DIR/orphans.tsv" ] || fail "tracked: $(cat "$FLEET_DISPATCH_DIR/orphans.tsv")"
}

@test "reap: a queue it cannot read un-starts no orphan" {
  export DISPATCH_NIGHT_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  row game agent gm-3 '- [/] fix y <!-- id:gm-3 -->'
  orphan_seen game gm-3 96
  stub agent-queue 'exit 1'
  run cmd_reap
  grep -qF -- '- [/] fix y' "$NOTES_FIXTURE/rows.game.agent" || fail "un-started blind"
  grep -q gm-3 "$FLEET_DISPATCH_DIR/orphans.tsv" || fail "first sighting lost"
}

@test "reap: a session several Claudes share says nothing about one item, so it never flips to waiting and a false waiting comes back" {
  started_item shared-1 hub:dotfiles
  started_item shared-2 hub:dotfiles '' '' human waiting
  started_item alone lab:game-agent-1
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.hub"
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'printf "%s\n" "{\"target\":\"hub/dotfiles:1\",\"status\":\"waiting\"}" "{\"target\":\"hub/dotfiles:2\",\"status\":\"busy\"}" "{\"target\":\"lab/game-agent-1:1\",\"status\":\"waiting\"}" "{\"target\":\"lab/game-agent-1:2\",\"status\":\"shell\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  assert_success
  [ -n "$(qitem running shared-1)" ] || fail "a shared session flipped its item to waiting"
  [ -n "$(qitem running shared-2)" ] || fail "a false waiting on a shared session stayed"
  # Negative control: a shell window does not make a session shared, so its one Claude still counts.
  [ -n "$(qitem waiting alone)" ] || fail "a session with one Claude stopped reading as waiting"
}

@test "record keeps each pane's session, window and cwd, with the conversation found under the pane" {
  record_setup
  world '10 1000' "$PANE1" "$PANE2"
  echo '{"pane":"lab/%2","session_id":"another-world","cwd":"/x"}' >> "$NOTES_FIXTURE/panel.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_success
  assert_equal "$(jq -c '[.server, .instance]' "$RECORD")" '["hub","10 1000"]'
  assert_equal "$(jq -c '.panes[0]' "$RECORD")" '{"session":"dotfiles","window":"crash","cwd":"/work/tree","claude":"conv-1"}'
  assert_equal "$(jq -c '.panes[1]' "$RECORD")" '{"session":"dotfiles","window":"zsh","cwd":"/plain/dir","claude":""}'
  assert_not_called 'agent-notify'
}

@test "record keeps the last record when agent-panel fails, and still sees a server die" {
  record_setup
  world '10 1000' "$PANE1"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  stub agent-panel 'exit 1'
  world '10 1000' "$PANE2"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_output --partial 'agent-panel failed'
  assert_equal "$(jq -r '.panes[0].claude' "$RECORD")" conv-1
  world ''
  "$REPO_ROOT/.local/bin/fleet-dispatch" record 2>/dev/null
  assert_called 'tmux hub server died 1 conversation(s)'
  [ -f "$LOST" ] || fail "record not kept as lost"
}

@test "record pages once when a server dies and keeps its last record for restore" {
  record_setup
  world '10 1000' "$PANE1"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  world ''
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_success
  assert_called 'agent-notify -p high -t tmux hub server died 1 conversation(s) were on it'
  [ -f "$LOST" ] && [ ! -f "$RECORD" ] || fail "record not kept as lost"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_equal "$(grep -c 'agent-notify' "$NOTES_FIXTURE/calls.log")" 1
}

@test "record sees a server restarted between two records, and a later empty death keeps the lost record" {
  record_setup
  world '10 1000' "$PANE1"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  world '11 2000' "$PANE2"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_called 'tmux hub server died 1 conversation(s)'
  assert_equal "$(jq -r '.panes[0].claude' "$LOST")" conv-1
  assert_equal "$(jq -r .instance "$RECORD")" '11 2000'
  world ''
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_called 'tmux hub server died 0 conversation(s)'
  assert_equal "$(jq -r '.panes[0].claude' "$LOST")" conv-1
  [ ! -f "$RECORD" ] || fail "an empty record stayed"
}

@test "restore reopens each conversation in its last mode and skips what must not come back" {
  restore_setup
  G="$SANDBOX/repos/game"
  lost_pane planned "$G" conv-plan
  lost_pane working "$G" conv-work
  lost_pane armed "$G" conv-armed
  lost_pane closed "$G" conv-closed
  lost_pane alive "$G" conv-alive
  lost_pane moved "$SANDBOX/no-such-dir" conv-moved
  lost_pane shell "$G" ''
  transcript conv-plan '{"permissionMode":"bypassPermissions"}
{"type":"permission-mode","permissionMode":"plan"}'
  transcript conv-work '{"permissionMode":"bypassPermissions"}'
  : > "$HOME/.agent/spin-down/conv-armed.request"
  : > "$HOME/.agent/spin-down/conv-closed.fired"
  printf '{"pid":%s,"sessionId":"conv-alive"}' "$$" > "$HOME/.claude/sessions/$$.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_called 'tmx ensure hub'
  assert_called "-n planned -c $G ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode plan --allow-dangerously-skip-permissions --resume conv-plan"
  assert_called "-n working -c $G ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume conv-work"
  for skipped in conv-armed conv-closed conv-alive conv-moved; do assert_not_called "--resume $skipped"; done
  assert_output --partial 'hub:dotfiles:armed: wound down on purpose, skipped'
  assert_output --partial 'hub:dotfiles:closed: wound down on purpose, skipped'
  assert_output --partial 'hub:dotfiles:alive: already running, skipped'
  assert_output --partial 'claude --resume conv-moved'
  assert_output --partial 'hub:dotfiles:shell: no conversation, not reopened'
  assert_output --partial 'hub: reopened 2, failed 0'
  [ -f "$FLEET_DISPATCH_DIR/panes/hub.restored.json" ] && [ ! -f "$FLEET_DISPATCH_DIR/panes/hub.lost.json" ] ||
    fail "a finished restore left its record"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_output --partial 'no lost server on record'
}

@test "restore reopens a conversation with the queue item that lists it, and a joined window takes no session" {
  restore_setup
  G="$SANDBOX/repos/game"
  lost_pane working "$G" conv-item
  CLAUDE_CODE_SESSION_ID=conv-item agent-queue add --project game --running --slug hub-work "hub work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_output --partial 'hub:dotfiles:working: reopened in bypassPermissions for queue item hub-work'
  assert_called "-n working -c $G AGENT_QUEUE_ITEM=hub-work ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --disallowedTools Workflow,ScheduleWakeup,Artifact --permission-mode bypassPermissions --resume conv-item"
  f=$(qitem running hub-work)
  assert_equal "$(qfield "$f" origin)" resume
  assert_equal "$(qfield "$f" session)" ''
}

@test "restore keeps the record when a reopen fails, so a rerun finishes it" {
  restore_setup
  lost_pane one "$SANDBOX/repos/game" conv-1
  stub tmux 'case "$*" in *new-window*) exit 1 ;; *has-session*) exit 0 ;; esac'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_failure
  assert_output --partial 'hub: reopened 0, failed 1'
  [ -f "$FLEET_DISPATCH_DIR/panes/hub.lost.json" ] || fail "lost the record"
}

@test "restore --dry-run says what it would do and touches nothing" {
  restore_setup
  lost_pane one "$SANDBOX/repos/game" conv-1
  transcript conv-1 '{"permissionMode":"plan"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore --dry-run
  assert_success
  assert_output --partial "would reopen conv-1 in $SANDBOX/repos/game (plan)"
  assert_not_called 'tmx ensure'
  assert_not_called '--resume'
  [ -f "$FLEET_DISPATCH_DIR/panes/hub.lost.json" ] || fail "a dry run consumed the record"
}

@test "reap settles a claude-lazer item whose claude exited, like claude's; an opencode one waits for its session to end" {
  project game beta "$SANDBOX/repos/game"
  started_item lazer lab:game-agent-1
  sed -i 's/^agent: claude/agent: claude-lazer/' "$AGENT_QUEUE_DIR"/running/*-lazer.md
  started_item oc lab:game-agent-2
  sed -i 's/^agent: claude/agent: opencode/' "$AGENT_QUEUE_DIR"/running/*-oc.md
  printf 'game-agent-%s\n' 1 2 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-9:1\",\"status\":\"busy\",\"session_id\":\"s9\"}"'
  stub agent-ask 'exit 0'
  export DISPATCH_REAP_CONFIRM=0   # a miss settles on the second reap
  "$REPO_ROOT/.local/bin/fleet-dispatch" reap >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-lazer.md 2>/dev/null)" ] || fail "a claude-lazer item whose claude exited stayed active"
  [ -n "$(qitem running oc)" ] || fail "an opencode run was settled while its session lives"
}

@test "reap settles a lazer-reserve item whose claude exited: its launcher is claude-lazer" {
  route_ready
  started_item routed lab:game-agent-1
  sed -i 's/^agent: claude/agent: lazer-reserve/' "$AGENT_QUEUE_DIR"/running/*-routed.md
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-9:1\",\"status\":\"busy\",\"session_id\":\"s9\"}"'
  stub agent-ask 'exit 0'
  export DISPATCH_REAP_CONFIRM=0   # a miss settles on the second reap
  "$REPO_ROOT/.local/bin/fleet-dispatch" reap >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-routed.md 2>/dev/null)" ] || fail "a routed item whose claude exited stayed active"
}

@test "reap leaves an item alone while its worker does not answer, and settles it once the worker says the session is gone" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1'
  remote_item fix-crash
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  run cmd_reap
  assert_success
  [ -n "$(qitem running fix-crash)" ] || fail "reaped an item whose worker did not answer"
  # cannot-tell is live to every reader: its unit stays held on the worker.
  run live_runs
  assert_output 'game/ light razer-laptop'
  rm "$NOTES_FIXTURE/ssh.rc"
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  [ -n "$(qitem running fix-crash)" ] || fail "reaped a live remote session"
  run live_runs
  assert_output 'game/ light razer-laptop'
  assert_equal "$(units_on '' <<<"$output") $(units_on razer-laptop <<<"$output")" '0 1'
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  [ -z "$(qitem running fix-crash)" ] || fail "kept an item whose remote session is gone"
}

# ucp-162 merged its unity-core half on 2026-11-08, its session ended, and it sat in review for good.
@test "reap: a partial merge whose session is gone goes back to the queue for its final landing, keeping its row and after items open" {
  pr_item MERGED
  agent-queue set fix-crash "merged=$OID" partial=yes >/dev/null
  agent-queue add --project game --slug next --after fix-crash 'next phase' >/dev/null
  run cmd_reap
  assert_success
  assert_output --partial 'requeued queue item fix-crash (game-agent-1 ended: its final landing, after o/game#12 merged as a partial)'
  it=$(agent-queue show fix-crash --json)
  assert_equal "$(jq -r '[.state, .partial, .merged] | join(" ")' <<<"$it")" "queued yes $OID"
  run item_brief "$it"
  assert_output --partial 'merged o/game#12 as a partial landing'
  refute_output --partial 'check out its head branch'
  run cmd_reap
  assert_success
  run agent-queue show next --json
  assert_equal "$(jq -r .hold <<<"$output")" 'after fix-crash'
  grep -qF -- '- [/] fix crash' "$NOTES_FIXTURE/rows.game.agent" || fail 'partial row closed'
  # Its requeued run also ends without the final landing: it parks in review, no loop.
  agent-queue move fix-crash running >/dev/null
  agent-queue set fix-crash session=lab:game-agent-1 >/dev/null
  run cmd_reap
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" review
  grep -q 'its requeued run ended without it' "$FLEET_DISPATCH_DIR/log.md" || fail 'no log line for the parked partial'
}
