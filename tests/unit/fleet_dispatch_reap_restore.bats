#!/usr/bin/env bats
# fleet-dispatch, reap: harness run ends, orphan rows, lost hosts, and record and restore of sessions.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

@test "reap: a green tier-3 PR's lander runs on claude, and a green PR waits for admission like a red one" {
  pr_item OPEN
  run cmd_reap
  agent-queue set fix-crash agent=codex tags=tier3 >/dev/null
  fix_ended 1111111111111111111111111111111111111111 PASS
  agent-queue add --project game --slug filler "filler" >/dev/null
  AGENT_QUEUE_CAP=1 run cmd_reap
  assert_equal "$(agent-queue show fix-crash --json | jq -r '[.state, .land_tries // ""] | join("|")')" "review|"
  grep -q 'fix-crash: PR o/game#12 green at 111111111111; land held by admission' "$FLEET_DISPATCH_DIR"/log.md || fail "hold not logged"
  run cmd_reap
  assert_output --partial 'land queue item fix-crash'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .agent)" claude
}

@test "reap: a trainee's green PR gets its lander past the admission cap" {
  pr_item OPEN
  run cmd_reap
  agent-queue set fix-crash trainee=gotrain:glm >/dev/null
  fix_ended 1111111111111111111111111111111111111111 PASS
  agent-queue add --project game --slug filler "filler" >/dev/null
  AGENT_QUEUE_CAP=1 run cmd_reap
  assert_output --partial 'land queue item fix-crash (PR o/game#12 green at 111111111111, try 1 of 2)'
  assert_equal "$(agent-queue show fix-crash --json | jq -r '[.state, .pr_owner] | join("|")')" "queued|land"
}

@test "reap: a red PR in review waits for admission, and an item with no session recorded never reads as gone" {
  pr_item OPEN
  run cmd_reap
  fix_ended 1111111111111111111111111111111111111111 FAIL
  agent-queue add --project game --slug filler "filler" >/dev/null
  AGENT_QUEUE_CAP=1 run cmd_reap
  assert_success
  assert_equal "$(agent-queue show fix-crash --json | jq -r '[.state, .fix_tries // ""] | join("|")')" "review|"
  AGENT_QUEUE_CAP=1 run cmd_reap
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
@test "reap: a gone session's item with a pending ask for it goes back to its board row behind that ask, with its open PR, and the next brief continues the PR" {
  pr_item OPEN
  agent-queue move fix-crash waiting >/dev/null
  agent-queue set fix-crash "note=pushed the fix, need a call on the API" >/dev/null
  id=$(agent-ask post --project game --task fix-crash --options 'a=keep it|b=drop it' 'keep the old API?')
  : > "$NOTES_FIXTURE/calls.log"
  run cmd_reap
  assert_success
  assert_output --partial "returned queue item fix-crash to its board row behind ask $id (game-agent-1 ended)"
  # Its row waits on the ask (#ask/<id>/<options>); agent-ask start_held promotes it on the answer.
  assert_called "tag --add ask/$id/a/b fix crash"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-fix-crash.md 2>/dev/null)" ]
  it=$(agent-queue show fix-crash --json)
  assert_equal "$(jq -r '[.state, .end_reason, .tags, .pr] | join(" ")' <<<"$it")" "done returned ask:$id=a+b o/game#12"
  assert_equal "$(jq -r .note <<<"$it")" "session game-agent-1 ended on ask $id; its row waits until the human answers it; was: pushed the fix, need a call on the API"
  run item_brief "$it"
  assert_output --partial 'already opened o/game#12: check out its head branch (gh pr checkout 12 -R o/game)'
}

@test "reap: a gone session's item held only by the ask its ask: field names, with no PR, goes back to its row behind it; one with no row fails" {
  project game beta "$SANDBOX/repos/game"
  started_item p lab:game-agent-1 '' '' human waiting
  id=$(agent-ask post --project game --options 'yes=ship it|no=hold it' 'ship it?')
  agent-queue set p ask="$id" row=game:gm-4 >/dev/null
  run cmd_reap
  assert_success
  assert_equal "$(agent-queue show p --json | jq -r '[.state, .end_reason, .tags] | join(" ")')" "done returned ask:$id=yes+no"
  # no PR, so the brief names none: it once said "already opened null" (ar-1583)
  run item_brief "$(agent-queue show p --json)"
  refute_output --partial 'already opened'
  # Negative control: an item with no row has nowhere to wait, so the unclosed run fails.
  started_item q lab:game-agent-2
  agent-queue set q ask="$id" >/dev/null
  run cmd_reap
  assert_success
  assert_equal "$(agent-queue show q --json | jq -r '[.state, .status] | join(" ")')" "done failed"
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

@test "reap: a gone session's item whose after: item is not done goes back to its board row behind it, not failed" {
  project game beta "$SANDBOX/repos/game"
  # after: is a list (ar-39): zero is done ok, so first alone still holds.
  agent-queue add --project game --slug zero "the zeroth part" >/dev/null
  agent-queue move zero done --status ok >/dev/null
  agent-queue add --project game --slug first "the first part" >/dev/null
  agent-queue set first row=game:gm-1 >/dev/null
  started_item second lab:game-agent-1
  agent-queue set second after=zero,first row=game:gm-2 >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run cmd_reap
  assert_success
  assert_output --partial 'returned queue item second (game-agent-1 ended; it waits after first)'
  assert_called 'tag --add after/gm-1 gm-2'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-second.md)" end_reason)" returned
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-second.md 2>/dev/null)" ]
  # Negative control: once its after: item is done, the unclosed run is the run's own failure.
  rm "$AGENT_QUEUE_DIR"/done/*/*-second.md
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

@test "reap: a Codex run on a fleet worker that hit its usage limit is read on the worker, whose ~/.codex holds the rollout, and goes back to the queue" {
  codex_end_item th-lim '{"type":"task_complete","error":{"message":"x","codex_error_info":"usage_limit_exceeded"}}'
  worker '2.0 16 1 50'
  sed -i 's/^session: .*/&\nhost: razer-laptop/' "$(qitem running cx)"
  mkdir -p "$SANDBOX/worker"; mv "$HOME/.codex" "$SANDBOX/worker/codex"   # this machine has no rollout
  stub fleet-dispatch "echo \"fleet-dispatch \$*\" >> \"\$NOTES_FIXTURE/calls.log\"
DISPATCH_CODEX_SESSIONS='$SANDBOX/worker/codex/sessions' DISPATCH_HARNESSES='$HARNESSES' exec '$REPO_ROOT/.local/bin/fleet-dispatch' \"\$@\""
  run cmd_reap
  assert_output --partial 'requeued queue item cx (game-agent-1 ended: the plan'"'"'s usage limit)'
  assert_called 'fleet-dispatch item-end codex th-lim'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/queued/*-cx.md)" end_reason)" limit
}

@test "reap: a Codex run that hit its usage limit with its PR open goes back to the queue, not to review, and keeps the PR" {
  codex_end_item th-lim '{"type":"task_complete","error":{"message":"x","codex_error_info":"usage_limit_exceeded"}}'
  agent-queue set cx pr=o/game#12 >/dev/null
  gh_script 'echo OPEN'
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

@test "reap: an opencode run's last assistant row is classified: a quota end is provider, never requeued, and unrated; a key refusal is refused" {
  oc_end_item ses_evalq 'error|provider.quota'
  run cmd_reap
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-oc.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" end_reason)" 'failed provider'
  run grep -F 'model-lane outcome' "$NOTES_FIXTURE/calls.log"
  assert_failure
  rm -rf "$AGENT_QUEUE_DIR/done"
  oc_end_item ses_evala 'error|provider.auth'
  run cmd_reap
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-oc.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" end_reason)" 'failed refused'
}

# 2026-11-19: opencode-go's 5h budget ran out in one burst and 8 canary and trainee runs died at their first message (ar-3778).
@test "provider hold: a run that ended on a provider refusal holds its source until the harness's hold_min after its end; a source it does not name is open" {
  oc_end_item ses_evalh 'error|provider.rate-limit'
  harness_set() { jq "$@" "$HARNESSES" > "$SANDBOX/h.tmp" && mv "$SANDBOX/h.tmp" "$HARNESSES"; }
  harness_set '.harnesses.go.provider_hold_min = 300 | .harnesses.nim = {launcher: "opencode", source: "nim", timeout_min: 120, models: {glm: "nim (glm)"}}'
  run cmd_reap
  run provider_hold_scan
  run provider_hold_why go
  assert_success
  assert_output --partial 'a run on go ended on a provider refusal, so it takes no start until'
  # The window is the harness's own: 300 minutes after the end, not the 60 of the default.
  until=$(awk -F'\t' '$2 == "go" { print $3 }' "$PROVIDER_ENDS")
  [ "$until" -gt $(( $(date +%s) + 290 * 60 )) ] || fail "the hold ends at $until, short of the 300 minutes the harness names"
  # One row a run, not a slug: a requeued item runs under a new session id and is read again.
  assert_equal "$(awk -F'\t' '$2 == "go" { print $1 }' "$PROVIDER_ENDS")" "oc@ses_evalh"
  run provider_hold_why nim
  assert_failure
  # The ledger already knows the run: a scan reads its end once.
  rm -f "$HOME/.local/share/opencode/opencode.db"
  provider_hold_scan
  run provider_hold_why go
  assert_success
}

@test "provider hold: a run that ended on its own, or on a timeout, holds nothing (negative control), and a hold past its window lifts" {
  oc_end_item ses_evals 'stop'
  run cmd_reap
  provider_hold_scan
  run provider_hold_why go
  assert_failure
  assert_equal "$(awk -F'\t' '{ print $2 " " $3 }' "$PROVIDER_ENDS")" "go 0"
  mkdir -p "${PROVIDER_ENDS%/*}"
  printf 'old-run\tgo\t%s\n' "$(( $(date +%s) - 60 ))" > "$PROVIDER_ENDS"
  run provider_hold_why go
  assert_failure
  printf 'old-run\tgo\t%s\n' "$(( $(date +%s) + 600 ))" > "$PROVIDER_ENDS"
  run provider_hold_why go
  assert_success
}

@test "provider hold: a hold still standing survives a scan that reads no queue, and ladder_open_why turns the harness away" {
  mkdir -p "${PROVIDER_ENDS%/*}"
  printf 'gone-run\tgo\t%s\n' "$(( $(date +%s) + 600 ))" > "$PROVIDER_ENDS"
  jq -n '{harnesses: {go: {launcher: "opencode", source: "go", timeout_min: 120, models: {glm: "go (glm-5.3)"}}}}' > "$SANDBOX/harnesses.json"
  HARNESSES="$SANDBOX/harnesses.json"
  stub agent-queue 'exit 1'
  provider_hold_scan
  run provider_hold_why go
  assert_success
  TRAINEE_CONF='{"candidates":[{"harness":"go","model":"glm"}]}' run ladder_open_why go
  assert_failure
  assert_output --partial 'go: a run on go ended on a provider refusal'
}

@test "reap: an opencode run that finished its turn and never closed is stopped, failed and still reported to model-lane (negative control)" {
  oc_end_item ses_evals 'stop'
  run cmd_reap
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-oc.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" end_reason)" 'failed stopped'
  run grep -F 'model-lane outcome' "$NOTES_FIXTURE/calls.log"
  assert_output 'model-lane outcome r-oc failed'
}

@test "reap: an opencode run killed mid-work is a cut, or a timeout once the launcher's timeout has run; a provider fault is provider; a request the provider rejects is stopped" {
  local reason
  for spec in 'tool-calls|-|600|cut' 'tool-calls|-|7100|timeout' '-|aborted|600|cut' 'error|provider.rate-limit|60|provider' 'error|provider.error|60|provider' 'error|provider.invalid-request|60|stopped' 'error|provider.unheard-of|60|stopped'; do
    IFS='|' read -r finish etype secs reason <<<"$spec"
    rm -rf "$AGENT_QUEUE_DIR/done" "$AGENT_QUEUE_DIR/queued"
    oc_end_item ses_evalk "$finish|$etype" "$secs"
    run cmd_reap
    assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-oc.md)" end_reason)" "$reason"
  done
}

@test "reap: an opencode item whose newest session never got a model reply reads its older session" {
  oc_end_item ses_evalo 'error|provider.auth'
  sqlite3 "$OC_DB" "INSERT INTO session_message VALUES ('m9', 'ses_evalnew', 'user', 1, 1794200100000, 1794200100000, '{}')"
  agent-queue claim oc --sid ses_evalnew >/dev/null
  run cmd_reap
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-oc.md)" end_reason)" refused
}

@test "reap: an opencode item whose sessions are in no database records no end_reason" {
  oc_end_item ses_evalx 'stop'
  sqlite3 "$OC_DB" "UPDATE session_message SET session_id = 'ses_elsewhere'"   # its session is in no database
  agent-queue claim oc --sid ses_nothere >/dev/null
  run cmd_reap
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-oc.md)" end_reason)" ''
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
  gh_script 'agent-queue move fix-crash queued >/dev/null; cat "$NOTES_FIXTURE/pr.state"'
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
  export DISPATCH_T3_PROFILE=bnb
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

@test "reap: orphan sweep reads every board profile and routes unstart to the row's profile" {
  export DISPATCH_T3_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  row game agent gm-4 '- [/] outside dispatch <!-- id:gm-4 -->'
  jq -cn '{rows: [{profile: "extra", project: "game", lane: "agent", id: "gm-4", state: "doing"}]}' > "$SANDBOX/board.json"
  notes() {
    if [ "$*" = 'board --json' ]; then cat "$SANDBOX/board.json"
    else command notes "$@"; fi
  }
  run unstart_orphans
  assert_success
  grep -qP '^extra\tgame\tgm-4\t[0-9]+$' "$FLEET_DISPATCH_DIR/orphans.tsv" || fail "profile outside dispatch unseen"
  printf 'extra\tgame\tgm-4\t%s\n' "$(( $(date +%s) - 73 * 3600 ))" > "$FLEET_DISPATCH_DIR/orphans.tsv"
  run unstart_orphans
  assert_success
  assert_output --partial 'un-started game: gm-4'
  grep -qxF 'notes --profile extra ptask game --agent unstart gm-4' "$NOTES_FIXTURE/calls.log"
  [ ! -s "$FLEET_DISPATCH_DIR/orphans.tsv" ] || fail "settled orphan still tracked"
}

@test "reap: a started legacy row without an id keeps its text key" {
  row game agent 'legacy fix' '- [/] Legacy fix'
  orphan_seen game 'legacy fix' 73
  notes() {
    if [ "$*" = 'board --json' ]; then
      echo '{"rows":[{"profile":"bnb","project":"game","lane":"agent","id":null,"text":"Legacy fix","state":"doing"}]}'
    else command notes "$@"; fi
  }
  run unstart_orphans
  assert_success
  assert_output --partial 'un-started game: legacy fix'
  grep -qxF 'notes --profile bnb ptask game --agent unstart legacy fix' "$NOTES_FIXTURE/calls.log"
}

@test "reap: unreadable or malformed board preserves orphan sightings and changes no rows" {
  orphan_seen game gm-5 96
  cp "$FLEET_DISPATCH_DIR/orphans.tsv" "$SANDBOX/seen"
  notes() { return 1; }
  run unstart_orphans
  assert_success
  cmp "$SANDBOX/seen" "$FLEET_DISPATCH_DIR/orphans.tsv"
  notes() { echo '{"rows": []}'; return 1; }
  run unstart_orphans
  assert_success
  cmp "$SANDBOX/seen" "$FLEET_DISPATCH_DIR/orphans.tsv"
  notes() { echo '{"rows": null}'; }
  run unstart_orphans
  assert_success
  cmp "$SANDBOX/seen" "$FLEET_DISPATCH_DIR/orphans.tsv"
  ! grep -q ' unstart ' "$NOTES_FIXTURE/calls.log"
}

@test "reap: a done item's PR merged after its session closed it records merged: and closes the row on merge proof" {
  landed_item MERGED
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .merged)" "$OID"
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:o/game#12 commit:${OID:0:12}"
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
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:o/game#12 commit:${OID:0:12}"
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
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:o/tools#9 commit:${TOID:0:12}"
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
  export DISPATCH_T3_PROFILE=bnb
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

# NEGATIVE CONTROL: before ar-3262 no item named the plan row, so it was un-started past the grace
# while its chain still ran.
@test "reap: a started plan row keeps its start while an item of its plan's chain is active" {
  export DISPATCH_T3_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  printf '# pp\n\n## Phases\n\n- [ ] P1 one\n' > "$SANDBOX/pp.md"
  row game agent gm-9 '- [/] plan pp: run its open phases <!-- id:gm-9 -->'
  jq -cn --arg d "$(plan_row_task "$SANDBOX/pp.md")" \
    '{rows: [{profile: "bnb", project: "game", lane: "agent", id: "gm-9", state: "doing", tags: [], details: [$d]}]}' > "$SANDBOX/board.json"
  notes() {
    if [ "$*" = 'board --json' ]; then cat "$SANDBOX/board.json"
    else command notes "$@"; fi
  }
  started_item pp-p1 lab:game-agent-9 '' '' auto:plan-row queued
  sed -i "s|^mode: oneshot\$|mode: oneshot\nplan: $SANDBOX/pp.md|" "$AGENT_QUEUE_DIR"/queued/*-pp-p1.md
  orphan_seen game gm-9 96
  run unstart_orphans
  assert_success
  refute_output --partial 'un-started'
  grep -qF -- '- [/] plan pp' "$NOTES_FIXTURE/rows.game.agent" || fail "a plan row with a live chain was un-started"
  [ ! -s "$FLEET_DISPATCH_DIR/orphans.tsv" ] || fail "tracked: $(cat "$FLEET_DISPATCH_DIR/orphans.tsv")"
  # The chain gone and the row still started, it is an orphan like any other.
  rm "$AGENT_QUEUE_DIR"/queued/*-pp-p1.md
  orphan_seen game gm-9 96
  run unstart_orphans
  assert_success
  assert_output --partial 'un-started game: gm-9'
}

@test "reap: a live item's started row keeps its start when the board's key for it is its text with tags (ar-206)" {
  # NEGATIVE CONTROL: rows() keyed by the list's text column (no id from the marker), the row read as an
  # orphan, was un-started past the grace with its session still up, as agent-29's was on 2026-10-28.
  export DISPATCH_T3_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  # The real `ptask list` key is the row's text with its tags, not its id: rows() must read the id off the marker.
  row game agent 'fix(core): slots #tier/3 #size/m' '- [/] fix(core): slots #tier/3 #size/m #c1028 #low <!-- id:gm-4 run:1112 -->'
  started_item slots lab:game-agent-4 '' '' 'board:game:gm-4'
  sed -i 's/^lane: human$/lane: agent/' "$AGENT_QUEUE_DIR"/running/*-slots.md
  printf 'game-agent-4\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  # Both keys seen past the grace, so a reap that read the text key would un-start now, not just record it.
  orphan_seen game gm-4 96
  orphan_seen game 'fix(core): slots #tier/3 #size/m' 96
  run cmd_reap
  assert_success
  refute_output --partial 'un-started'
  grep -qF -- '- [/] fix(core): slots' "$NOTES_FIXTURE/rows.game.agent" || fail "a live item's tagged row was un-started"
  [ -n "$(qitem running slots)" ] || fail "the live item moved"
  [ ! -s "$FLEET_DISPATCH_DIR/orphans.tsv" ] || fail "tracked: $(cat "$FLEET_DISPATCH_DIR/orphans.tsv")"
}

@test "reap: a queue it cannot read un-starts no orphan" {
  export DISPATCH_T3_PROFILE=bnb
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

@test "a planned reboot (the session-snapshot marker, older than the boot) keeps the lost record and does not page" {
  record_setup
  : > "$HOME/.agent/maintenance"
  touch -d '-10 minutes' "$HOME/.agent/maintenance"
  export FLEET_BOOT_TIME=$(( $(date +%s) - 120 ))
  world '10 1000' "$PANE1"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  world ''
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_success
  [ -f "$LOST" ] || fail "record not kept as lost"
  ! grep -q 'agent-notify' "$NOTES_FIXTURE/calls.log" || fail "a planned reboot paged"
}

@test "a marker newer than the boot (down, no reboot yet) still pages a server death" {
  record_setup
  : > "$HOME/.agent/maintenance"
  export FLEET_BOOT_TIME=$(( $(date +%s) - 3600 ))
  world '10 1000' "$PANE1"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  world ''
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_called 'agent-notify -p high -t tmux hub server died'
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

@test "restore keeps a record that grew during its walk, so a rerun reopens the new death's conversations" {
  restore_setup
  lost_pane one "$SANDBOX/repos/game" conv-1
  # A death world_lost adds while the restore walks the record.
  stub tmx 'echo "tmx $*" >> "$NOTES_FIXTURE/calls.log"
    f="$FLEET_DISPATCH_DIR/panes/hub.lost.json"; jq ".panes += [{session: \"dotfiles\", window: \"two\", cwd: \"/x\", claude: \"conv-2\"}]" "$f" > "$f.n" && mv "$f.n" "$f"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_failure
  assert_output --partial 'hub: its record grew during the restore'
  assert_equal "$(jq -r '.panes[1].claude' "$FLEET_DISPATCH_DIR/panes/hub.lost.json")" conv-2
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
  lost_pane otheracct "$G" conv-other
  mkdir -p "$HOME/.claude-work/sessions"
  printf '{"pid":%s,"sessionId":"conv-other"}' "$$" > "$HOME/.claude-work/sessions/$$.json"
  printf '{"pid":%s,"sessionId":"conv-alive"}' "$$" > "$HOME/.claude/sessions/$$.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_called 'tmx ensure hub'
  assert_called "-n planned -c $G ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode plan --allow-dangerously-skip-permissions --resume conv-plan"
  assert_called "-n working -c $G ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume conv-work"
  for skipped in conv-armed conv-closed conv-alive conv-other conv-moved; do assert_not_called "--resume $skipped"; done
  assert_output --partial 'hub:dotfiles:armed: wound down on purpose, skipped'
  assert_output --partial 'hub:dotfiles:closed: wound down on purpose, skipped'
  assert_output --partial 'hub:dotfiles:alive: already running, skipped'
  assert_output --partial 'hub:dotfiles:otheracct: already running, skipped'
  assert_output --partial 'claude --resume conv-moved'
  assert_output --partial 'hub:dotfiles:shell: no conversation, not reopened'
  assert_output --partial 'hub: reopened 2, failed 0'
  [ -f "$FLEET_DISPATCH_DIR/panes/hub.restored.json" ] && [ ! -f "$FLEET_DISPATCH_DIR/panes/hub.lost.json" ] ||
    fail "a finished restore left its record"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_output --partial 'no lost server on record'
}

@test "restore reopens a conversation that several queue items list, with the running one updated last (ar-2676)" {
  restore_setup
  G="$SANDBOX/repos/game"
  lost_pane working "$G" conv-two
  CLAUDE_CODE_SESSION_ID=conv-two agent-queue add --project game --running --slug hub-old "hub old" >/dev/null
  agent-queue add --project game --running --slug hub-new "hub new" >/dev/null
  agent-queue claim hub-new --sid conv-two >/dev/null
  touch -d '2 hours ago' "$(qitem running hub-old)"
  # A review item written last (a PR poller) still loses to a running one.
  agent-queue add --project game --running --slug hub-pr "hub pr" >/dev/null
  agent-queue claim hub-pr --sid conv-two >/dev/null
  agent-queue move hub-pr review >/dev/null
  touch "$(qitem review hub-pr)"
  # The ambiguity mine reports to every other caller stays.
  run agent-queue mine --sid conv-two
  assert_failure 2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore --dry-run
  assert_success
  assert_output --partial "hub:dotfiles:working: would reopen conv-two in $G (bypassPermissions) for queue item hub-new, prompted to carry on"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_output --partial 'hub:dotfiles:working: reopened in bypassPermissions for queue item hub-new'
  assert_called 'AGENT_QUEUE_ITEM=hub-new'
  # A hand resume with no --item takes the same one instead of refusing.
  touch -d '3 hours ago' "$(qitem running hub-new)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server hub --session dotfiles --window hand --cwd "$G" --resume conv-two
  assert_success
  assert_called 'AGENT_QUEUE_ITEM=hub-old'
}

@test "restore reopens a conversation with the queue item that lists it, and a joined window takes no session" {
  restore_setup
  G="$SANDBOX/repos/game"
  lost_pane working "$G" conv-item
  CLAUDE_CODE_SESSION_ID=conv-item agent-queue add --project game --running --slug hub-work "hub work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_output --partial 'hub:dotfiles:working: reopened in bypassPermissions for queue item hub-work, prompted to carry on'
  # A running item's conversation gets the restore prompt as its first message, naming the item.
  assert_called "-n working -c $G AGENT_QUEUE_ITEM=hub-work ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --disallowedTools Workflow,ScheduleWakeup,Artifact --permission-mode bypassPermissions --resume conv-item fleet-dispatch\\ restore\\ reopened\\ this\\ session"
  assert_called 'Carry\ on\ with\ queue\ item\ hub-work\ from'
  f=$(qitem running hub-work)
  assert_equal "$(qfield "$f" origin)" resume
  assert_equal "$(qfield "$f" session)" ''
}

@test "restore prompts no conversation whose item waits, nor one with no item" {
  restore_setup
  G="$SANDBOX/repos/game"
  lost_pane waiting "$G" conv-wait
  lost_pane mine "$G" conv-human
  CLAUDE_CODE_SESSION_ID=conv-wait agent-queue add --project game --running --slug hub-wait "hub wait" >/dev/null
  agent-queue move hub-wait waiting >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore --dry-run
  assert_success
  assert_output --partial "hub:dotfiles:waiting: would reopen conv-wait in $G (bypassPermissions) for queue item hub-wait"
  refute_output --partial 'prompted'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_called '--resume conv-wait'
  assert_called '--resume conv-human'
  assert_not_called 'restore\ reopened'
}

@test "restore keeps the record when a reopen fails, so a rerun finishes it" {
  restore_setup
  lost_pane one "$SANDBOX/repos/game" conv-1
  tmux_script 'case "$*" in *new-window*) exit 1 ;; *has-session*) exit 0 ;; esac'
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

@test "record on the lease holder runs on every other worker with --here, says nothing of one that does not answer, and fails on one that fails" {
  record_setup
  world '10 1000' "$PANE1"
  sandbox_fleet --self hp 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_success
  assert_output 'hp: did its own'
  assert_called '192.0.2.40 PATH="$HOME/.local/bin:$PATH" LANG="${LANG:-C.UTF-8}" exec env '\''fleet-dispatch'\'' '\''record'\'' '\''--here'\'''
  assert_called 'idle-worker PATH='
  assert_not_called ' state PATH='
  [ -f "$RECORD" ] || fail "this machine's own record was not kept"
  # --here, the call a worker gets, asks no one.
  : > "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record --here
  assert_success
  assert_not_called 'ssh'
  # A machine that does not hold the fleet lease keeps its own record and asks no one: the holder fans out.
  : > "$NOTES_FIXTURE/calls.log"
  FLEET_LEASE_STUB_RC=1 run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_success
  assert_not_called 'ssh'
  sandbox_fleet --self hp 4
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_failure
  assert_output --partial 'record: hp exited 4'
}

@test "restore reopens each worker's own sessions there with its flags, and a worker that does not answer is said, not failed" {
  restore_setup
  sandbox_fleet --self hp 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore --server hub --dry-run
  assert_success
  assert_called '192.0.2.40 PATH="$HOME/.local/bin:$PATH" LANG="${LANG:-C.UTF-8}" exec env '\''fleet-dispatch'\'' '\''restore'\'' '\''--here'\'' '\''--server'\'' '\''hub'\'' '\''--dry-run'\'''
  assert_not_called ' state PATH='
  assert_line 'hp: did its own'
  assert_output --partial 'restore: idle-worker did not answer; its own record stays there'
  : > "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore --here
  assert_success
  assert_not_called 'ssh'
  sandbox_fleet --self hp 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_failure
  assert_output --partial 'restore: hp exited 1'
}

@test "a server that dies again keeps the lost record a restore only part finished, and adds the new conversations once" {
  record_setup
  PANE3=$'%3\tdotfiles\tfresh\t/fresh/dir'
  echo '{"pane":"hub/%3","session_id":"conv-3","cwd":"/fresh"}' >> "$NOTES_FIXTURE/panel.json"
  world '10 1000' "$PANE1" "$PANE2"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  sed -i 's|/work/tree|/moved/tree|' "$NOTES_FIXTURE/panel.json"
  world '11 2000' "$PANE1" "$PANE3" "$PANE2"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_equal "$(jq -c '[.panes[].claude]' "$LOST")" '["conv-1",""]'
  world ''
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_equal "$(jq -c '[.panes[].claude]' "$LOST")" '["","conv-1","conv-3"]'
  assert_equal "$(jq -r '.panes[] | select(.claude == "conv-1") | .cwd' "$LOST")" /moved/tree
  [ ! -f "$RECORD" ] || fail "the dead record stayed"
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
  worker '2.0 16 1 50'
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
  legacy next "after: fix-crash" --project game 'next phase'
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
  assert_output --partial 'human row for queue item fix-crash (on the game sheet)'
  assert_called 'notes --profile bnb ptask game add chore(land): o/game#12 merged as a partial and two runs ended without the final landing'
  # ar-2897: parked, it is settled. NEGATIVE CONTROL: before reap_stuck every later pass logged it again
  # (526 lines in two days) and nothing ever asked the human.
  run cmd_reap
  run cmd_reap
  refute_output --partial 'fix-crash'
  assert_equal "$(grep -c 'its requeued run ended without it' "$FLEET_DISPATCH_DIR/log.md")" 1
  assert_equal "$(grep -c 'ptask game add chore(land)' "$NOTES_FIXTURE/calls.log")" 1
}

# ar-2897: kblack0610/asset-library-hd#4, a repo gh does not know, logged "could not read PR" on every pass.
@test "reap: a gone item whose PR cannot be read is logged once, and goes to the human sheet once it has stood DISPATCH_ORPHAN_HOURS" {
  pr_item OPEN
  : > "$NOTES_FIXTURE/pr.state"   # gh cannot read the PR
  run cmd_reap
  refute_output --partial 'human row'
  run cmd_reap
  assert_equal "$(grep -c 'could not read PR o/game#12' "$FLEET_DISPATCH_DIR/log.md")" 1
  assert_equal "$(grep -c 'session game-agent-1 gone' "$NOTES_FIXTURE/calls.log")" 0
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" running
  # it has stood DISPATCH_ORPHAN_HOURS: one human row, then nothing more
  sed -i "1s/^[0-9]*/$(( $(date +%s) - DISPATCH_ORPHAN_HOURS * 3600 ))/" "$FLEET_DISPATCH_DIR/stuck/fix-crash"
  run cmd_reap
  assert_output --partial 'human row for queue item fix-crash (on the game sheet)'
  run cmd_reap
  refute_output --partial 'human row'
  assert_equal "$(grep -c 'ptask game add chore(review): reap has not read PR o/game#12' "$NOTES_FIXTURE/calls.log")" 1
  # read again, it settles as usual
  printf 'OPEN - 1111111111111111111111111111111111111111 PENDING\n' > "$NOTES_FIXTURE/pr.state"
  run cmd_reap
  assert_output --partial 'review queue item fix-crash (PR o/game#12 open'
  [ ! -e "$FLEET_DISPATCH_DIR/stuck/fix-crash" ] || fail "a PR read again left its stuck marker"
}

@test "reap: a merged PR whose forge reads no merge commit is logged once, and settles once the commit reads" {
  pr_item MERGED -
  run cmd_reap
  run cmd_reap
  assert_equal "$(grep -c 'merged with no merge commit its forge could read' "$FLEET_DISPATCH_DIR/log.md")" 1
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" running
  printf 'MERGED %s\n' "$OID" > "$NOTES_FIXTURE/pr.state"
  run cmd_reap
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" done
  [ ! -e "$FLEET_DISPATCH_DIR/stuck/fix-crash" ] || fail "a settled item left its stuck marker"
}

@test "reap: a stuck item whose human sheet refuses the row pages once instead, then stays quiet" {
  pr_item OPEN
  : > "$NOTES_FIXTURE/pr.state"
  touch "$NOTES_FIXTURE/refuse.game"
  run cmd_reap
  printf '%s 0\n%s\n' "$(( $(date +%s) - DISPATCH_ORPHAN_HOURS * 3600 ))" "$(sed -n 2p "$FLEET_DISPATCH_DIR/stuck/fix-crash")" > "$FLEET_DISPATCH_DIR/stuck/fix-crash"
  run cmd_reap
  assert_output --partial 'human row for queue item fix-crash (not filed: the game sheet refused the row)'
  run cmd_reap
  refute_output --partial 'human row'
  assert_equal "$(grep -cE 'agent-notify -t Needs you -d needs:dispatch:stuck:fix-crash:[0-9]+ chore\(review\): reap has not read PR o/game#12' "$NOTES_FIXTURE/calls.log")" 1
}

# ar-2897: make-logical-possum-p4b's row failed merge proof on every pass: home-config has no origin, only forgejo.
@test "reap: a Forgejo checkout with only its forgejo remote closes the row on merge proof there" {
  fj_item merged success
  git -C "$SANDBOX/repos/game" remote remove origin
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  grep -q 'evidence commit .* is an ancestor of forgejo/main' "$FLEET_DISPATCH_DIR/log.md" || fail "not proven on forgejo/main"
}

# ar-2897: fix-ci-ghw's merged: held its PR ref, so merge proof refused it on every pass.
@test "reap: a done item whose merged: is not a commit has it re-read from its forge, and its row closes; agent-queue refuses such a value" {
  pr_item MERGED
  run agent-queue set fix-crash merged=o/game#12
  assert_failure
  assert_output --partial 'merged is the merge commit sha of each PR in pr:'
  agent-queue set fix-crash "merged=$OID" >/dev/null
  agent-queue move fix-crash done --status ok >/dev/null
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)
  sed -i 's|^merged: .*|merged: o/game#12|' "$f"   # as the item held it, written before the check
  run close_row fix-crash
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  assert_equal "$(qfield "$f" merged)" "$OID"
}

# lost_host_item -- fix-crash runs on razer-laptop, which does not answer: its Claude session sid-a
# last pushed feat/fix at abc123 and left a status note. DISPATCH_HOST_DEAD is 600s.
lost_host_item() {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  remote_item fix-crash
  sed -i 's/^session: .*/&\nsessions: sid-a/' "$(qitem running fix-crash)"
  agent-queue set fix-crash branch=feat/fix@abc123 'note=patched the parser, tests next' >/dev/null
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  export DISPATCH_HOST_DEAD=600
  stub store-sync-age 'exit 0'   # this machine reached the store: its own link is up
  MISS="$FLEET_DISPATCH_DIR/host-miss/razer-laptop"
}

@test "reap re-queues the items of a host unanswered for DISPATCH_HOST_DEAD from their pushed branch, and the new brief says where the run was" {
  lost_host_item
  run cmd_reap
  assert_success
  [ -n "$(qitem running fix-crash)" ] || fail "one miss re-queued the item"
  [ -s "$MISS" ] || fail "no mark for the host that did not answer"
  # The first miss was 700s ago and the last one a pass ago: unanswered on every reap since.
  echo $(( $(date +%s) - 700 )) > "$MISS"
  touch -d '-100 seconds' "$MISS"
  run cmd_reap
  assert_success
  assert_output --partial 'requeued queue item fix-crash (its host razer-laptop is lost)'
  it=$(agent-queue show fix-crash --json)
  assert_equal "$(jq -r '[.state, .salvage, .lost] | join("|")' <<<"$it")" 'queued|feat/fix@abc123|razer-laptop sid-a'
  [[ "$(jq -r .note <<<"$it")" == "session game-agent-1 lost with its host razer-laptop, unanswered for 600s; requeued from feat/fix@abc123; was: patched the parser, tests next" ]] || fail "note: $(jq -r .note <<<"$it")"
  grep -q 'host razer-laptop lost, queue item fix-crash requeued from feat/fix@abc123' "$FLEET_DISPATCH_DIR/log.md" || fail 'no log line for the lost host'
  run item_brief "$it"
  assert_output --partial 'left its unfinished work on branch feat/fix at abc123 on origin'
  assert_output --partial 'An earlier run of this item on razer-laptop was lost when that machine stopped answering: anything it had not pushed is gone with it. Its last note: patched the parser, tests next'
}

@test "reap: a host that answers between misses clears its mark, and a gap longer than DISPATCH_HOST_DEAD starts the count again" {
  lost_host_item
  run cmd_reap
  [ -s "$MISS" ] || fail "no mark for the host that did not answer"
  # It answers, its session alive: the mark goes.
  rm "$NOTES_FIXTURE/ssh.rc"
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  [ ! -e "$MISS" ] || fail "a host that answered kept its mark"
  [ -n "$(qitem running fix-crash)" ] || fail "re-queued an item whose host answered"
  # Unanswered again, but the last miss before this one is older than the window: no reap saw it
  # down in between, so the count starts over instead of re-queueing.
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  echo $(( $(date +%s) - 2000 )) > "$MISS"
  touch -d '-1000 seconds' "$MISS"
  run cmd_reap
  assert_success
  [ -n "$(qitem running fix-crash)" ] || fail "a gap in the misses re-queued the item"
  [ "$(cat "$MISS")" -gt $(( $(date +%s) - 60 )) ] || fail "the count did not start over"
}

@test "reap: an item on a lost host with an open PR is requeued without salvage, its brief continuing the PR" {
  lost_host_item
  agent-queue set fix-crash pr=o/game#12 >/dev/null
  printf "OPEN -\n" > "$NOTES_FIXTURE/pr.state"
  gh_script 'printf "gh %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; cat "$NOTES_FIXTURE/pr.state"'
  run cmd_reap
  echo $(( $(date +%s) - 700 )) > "$MISS"
  run cmd_reap
  assert_output --partial 'requeued queue item fix-crash (its host razer-laptop is lost)'
  it=$(agent-queue show fix-crash --json)
  assert_equal "$(jq -r '[.state, .salvage // "-", .lost] | join("|")' <<<"$it")" 'queued|-|razer-laptop sid-a'
  run item_brief "$it"
  assert_output --partial 'already opened o/game#12'
  refute_output --partial 'left its unfinished work on branch'
}

@test "reap: a review item on a lost host stays parked in review" {
  lost_host_item
  agent-queue move fix-crash review >/dev/null
  sed -i 's/^session: .*/&\nhost: razer-laptop/' "$(qitem review fix-crash)"
  run cmd_reap
  echo $(( $(date +%s) - 700 )) > "$MISS"
  run cmd_reap
  assert_success
  refute_output --partial 'requeued queue item fix-crash'
  [ -n "$(qitem review fix-crash)" ] || fail "a parked review item was requeued for its lost host"
}

@test "reap counts no miss for a worker while this machine itself has not reached the store: the fault may be here" {
  lost_host_item
  stub store-sync-age 'exit 1'
  mkdir -p "${MISS%/*}"; echo $(( $(date +%s) - 700 )) > "$MISS"; touch -d '-100 seconds' "$MISS"
  run cmd_reap
  assert_success
  refute_output --partial 'requeued queue item fix-crash'
  [ -n "$(qitem running fix-crash)" ] || fail "a dispatcher cut off re-queued a worker's item"
  grep -q 'this machine has not synced the store in 30 minutes either' "$FLEET_DISPATCH_DIR/log.md" || fail 'no log line for the missing witness'
}

# paced_restore <n> -- n lost conversations, each listed by a running queue item, so each reopen is
# a wake (the restore prompt); agent-hold is the real one in the sandbox.
paced_restore() {
  restore_setup
  G="$SANDBOX/repos/game"
  export AGENT_HOLD_DIR="$SANDBOX/holds" AGENT_HOLD_ASSESS="$SANDBOX/none"
  LOST="$FLEET_DISPATCH_DIR/panes/hub.lost.json"; mkdir -p "${LOST%/*}"
  stub agent-hold "exec '$REPO_ROOT/.local/bin/agent-hold' \"\$@\""
  stub systemctl 'echo "systemctl $*" >> "$NOTES_FIXTURE/calls.log"'
  # A server restore starts must not hold the restore lock: it would block every later walk.
  stub tmx 'echo "tmx $*" >> "$NOTES_FIXTURE/calls.log"; ! ls -l /proc/$$/fd | grep -q restore.lock || echo "tmx holds the restore lock" >> "$NOTES_FIXTURE/calls.log"'
  local i
  for ((i = 1; i <= $1; i++)); do
    lost_pane "w$i" "$G" "conv-$i"
    CLAUDE_CODE_SESSION_ID="conv-$i" agent-queue add --project game --running --slug "item-$i" "item $i" >/dev/null
  done
}

@test "restore wakes a batch of 3, holds the rest under the restore hold, and the next walk on room wakes them (2026-11-17)" {
  paced_restore 5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_equal "$(grep -c 'restore\\ reopened' "$NOTES_FIXTURE/calls.log")" 3
  assert_output --partial 'hub:dotfiles:w4: waits for a wake batch (queue item item-4)'
  assert_output --partial 'hub: 2 wait for a wake batch'
  assert_output --partial 'restore: 2 wait for a wake batch of at most 3'
  assert_not_called 'holds the restore lock'
  run agent-hold show restore
  assert_output --partial 'kind: load'
  assert_output --partial 'roster: conv-4,conv-5'
  assert_equal "$(cat "$FLEET_DISPATCH_DIR/panes/.restore-owed")" 2
  [ -f "$LOST" ] || fail "a restore with wakes owed consumed its record"
  # The budget is spent: a walk inside the settle window wakes nothing more.
  printf '{"pid":%s,"sessionId":"conv-%s"}' "$$" 1 > "$HOME/.claude/sessions/1.json"
  printf '{"pid":%s,"sessionId":"conv-%s"}' "$$" 2 > "$HOME/.claude/sessions/2.json"
  printf '{"pid":%s,"sessionId":"conv-%s"}' "$$" 3 > "$HOME/.claude/sessions/3.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_output --partial 'restore: 2 wait for a wake batch'
  assert_equal "$(grep -c 'restore\\ reopened' "$NOTES_FIXTURE/calls.log")" 3
  # One wake ages out: the next walk wakes one, and the hold's roster follows what still waits.
  sed -i '1s/^[0-9]*/1/' "$XDG_STATE_HOME/wake-pace/wakes"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_output --partial 'restore: 1 wait for a wake batch'
  run agent-hold show restore
  assert_output --partial 'roster: conv-5'
  printf '{"pid":%s,"sessionId":"conv-%s"}' "$$" 4 > "$HOME/.claude/sessions/4.json"
  # The settle window passes: the next walk wakes the last one, lifts its hold and consumes the record.
  sed -i 's/^[0-9]*/1/' "$XDG_STATE_HOME/wake-pace/wakes"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_output --partial 'released the restore hold'
  assert_called '--resume conv-5'
  assert_equal "$(grep -c 'restore\\ reopened' "$NOTES_FIXTURE/calls.log")" 5
  run agent-hold show restore
  assert_failure
  [ ! -e "$FLEET_DISPATCH_DIR/panes/.restore-owed" ] || fail "the owed marker outlived the restore"
  [ -f "$FLEET_DISPATCH_DIR/panes/hub.restored.json" ] && [ ! -f "$LOST" ] || fail "a finished restore left its record"
}

@test "restore leaves a restore hold it did not set where it is" {
  paced_restore 1
  agent-hold set restore --by someone "their own pause" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  run agent-hold show restore
  assert_output --partial 'by: someone'
}

@test "the minute record starts the next batch only while wakes are owed and the budget has room" {
  paced_restore 0
  stub fleet-assess '[ -e "$NOTES_FIXTURE/hot" ] && exit 1; exit 0'
  run restore_tick
  assert_not_called 'fleet-restore'
  echo 2 > "$FLEET_DISPATCH_DIR/panes/.restore-owed"
  touch "$NOTES_FIXTURE/hot"
  run restore_tick
  assert_not_called 'fleet-restore'
  rm "$NOTES_FIXTURE/hot"
  run restore_tick
  assert_called 'systemctl --user start --no-block fleet-restore.service'
}

# settle_fixture -- asks and stubs for the settle_answered_gates tests: agent-ask show reads the ask
# file, agent-hold logs each call and `show` succeeds only for a hold named in $HELD.
settle_fixture() {
  project game beta "$SANDBOX/repos/game"
  local d="$HOME/.agent/asks/game"
  mkdir -p "$d"
  # ask <id> <status> <by> <kind> <judge_type> <answer>
  ask() { printf 'id: %s\nstatus: %s\nanswered_by: %s\nkind: %s\njudge_type: %s\nanswer: %s\nquestion: q?\n' "$@" > "$d/$1.md"; }
  ask hold1 answered human question proceed_or_hold 'a: keep it held until I say #now'
  ask skip1 answered human question credential_or_account 'b: skip it for now'
  ask mint1 answered human question credential_or_account 'b: mint a new key'
  ask appr1 answered human approval '' 'b: not yet'
  ask judge1 answered judge question credential_or_account 'b: skip it'
  ask gone1 cancelled '' question credential_or_account ''
  printf 'closed_reason: superseded by #later\n' >> "$d/gone1.md"
  ask gone2 cancelled '' question credential_or_account ''
  printf 'closed_reason: joined hold1: the same question\n' >> "$d/gone2.md"
  ask gone3 cancelled '' question credential_or_account ''
  printf 'closed_reason: joined nope99: the same question\n' >> "$d/gone3.md"
  stub agent-ask '[ "$1" = show ] && cat "$HOME"/.agent/asks/*/"$2".md'
  stub agent-hold 'echo "agent-hold $*" >> "$NOTES_FIXTURE/calls.log"; [ "$1" != show ] || [[ " ${HELD:-} " == *" $2 "* ]]'
}

@test "reap settles a row whose #ask/ gate the human answered another way: a skip drops it, any other answer holds it" {
  settle_fixture
  row game agent gm-1 "- [ ] feat(game): xbox p3 $T #ask/hold1/b <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] feat(game): posthog counts $T #ask/skip1/a <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] feat(game): judge answered $T #ask/judge1/a <!-- id:gm-3 -->"
  row game agent gm-4 "- [ ] feat(game): cancelled ask $T #ask/gone1/a <!-- id:gm-4 -->"
  row game agent gm-9 "- [ ] feat(game): joined ask $T #ask/gone2/a <!-- id:gm-9 -->"
  row game agent gm-10 "- [ ] feat(game): joined, no option $T #ask/gone2 <!-- id:gm-10 -->"
  row game agent gm-11 "- [ ] feat(game): joined a missing ask $T #ask/gone3/a <!-- id:gm-11 -->"
  row game agent gm-5 "- [ ] feat(game): still waits $T #ask/hold1/a <!-- id:gm-5 -->"
  row game agent gm-6 "- [ ] feat(game): use the old key $T #ask/mint1/a <!-- id:gm-6 -->"
  row game agent gm-7 "- [ ] feat(game): approved launch $T #ask/appr1/a <!-- id:gm-7 -->"
  row game human hm-1 "- [ ] feat(game): the human's own row $T #ask/skip1/a <!-- id:hm-1 -->"
  run settle_answered_gates
  assert_success
  local rows; rows=$(cut -f2 "$NOTES_FIXTURE/rows.game.agent")
  # held: the hold set first, then the gate swapped for #hold/row-<row id>, which the human releases;
  # a typed question answered with another path that is not a skip is held too, never dropped
  grep -q '^- \[ \] feat(game): xbox p3 .*#hold/row-gm-1 <!-- id:gm-1 -->' <<<"$rows"
  grep -q '^- \[ \] feat(game): use the old key .*#hold/row-gm-6 <!-- id:gm-6 -->' <<<"$rows"
  grep -q '^- \[ \] feat(game): approved launch .*#hold/row-gm-7 <!-- id:gm-7 -->' <<<"$rows"
  [[ $rows != *'#ask/hold1/b'* && $rows != *'#ask/mint1/a'* && $rows != *'#ask/appr1/a'* ]]
  grep -q '^agent-hold set row-gm-1 --kind resource --by fleet-dispatch the human answered "a: keep it held until I say now" to ask hold1' "$NOTES_FIXTURE/calls.log"
  # dropped, with the answer as its why
  grep -q '^- \[x\] feat(game): posthog counts .*dropped: the human answered "b: skip it for now" to ask skip1, and #ask/skip1/a waited on another answer' <<<"$rows"
  # a cancelled ask holds its row (nobody decided); one that joined another moves the gate to it
  grep -q '^- \[ \] feat(game): cancelled ask .*#hold/row-gm-4 <!-- id:gm-4 -->' <<<"$rows"
  grep -q '^- \[ \] feat(game): joined ask .*#ask/hold1/a <!-- id:gm-9 -->' <<<"$rows"
  grep -q '^- \[ \] feat(game): joined, no option .*#ask/hold1 <!-- id:gm-10 -->' <<<"$rows"
  grep -q '^- \[ \] feat(game): joined a missing ask .*#hold/row-gm-11 <!-- id:gm-11 -->' <<<"$rows"
  grep -q '^agent-hold set row-gm-4 .*ask gone1 was cancelled (superseded by later), so nobody decided' "$NOTES_FIXTURE/calls.log"
  # a judge's answer, a gate the answer releases and a human-sheet row are left alone
  grep -q '^- \[ \] feat(game): judge answered .*#ask/judge1/a' <<<"$rows"
  grep -q '^- \[ \] feat(game): still waits .*#ask/hold1/a' <<<"$rows"
  cut -f2 "$NOTES_FIXTURE/rows.game.human" | grep -q '^- \[ \] feat(game): the human'
  grep -q 'held game row gm-1 until agent-hold release row-gm-1' "$FLEET_DISPATCH_DIR/log.md"
  grep -q 'dropped game row gm-2' "$FLEET_DISPATCH_DIR/log.md"
  # settled once: the next reap finds no dead gate to act on
  : > "$NOTES_FIXTURE/calls.log"
  run settle_answered_gates
  assert_success
  run grep -E 'agent-hold set|ptask game --agent (drop|tag)' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "reap settle: a hold already set is kept, and a failed retag releases only the hold it set" {
  settle_fixture
  row game agent gm-1 "- [ ] feat(game): held by a person $T #ask/hold1/b <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] feat(game): fresh hold $T #ask/mint1/a <!-- id:gm-2 -->"
  mv "$SANDBOX/bin/notes" "$SANDBOX/bin/notes.real"
  stub notes '[[ " $* " == *" --agent tag "* ]] && exit 1; exec notes.real "$@"'
  HELD=row-gm-1 run settle_answered_gates
  assert_success
  assert_output --partial 'could not retag game row gm-1 from #ask/hold1/b to #hold/row-gm-1'
  run grep -E '^agent-hold (set|release) row-gm-1' "$NOTES_FIXTURE/calls.log"
  assert_failure
  grep -q '^agent-hold set row-gm-2 ' "$NOTES_FIXTURE/calls.log"
  grep -q '^agent-hold release row-gm-2$' "$NOTES_FIXTURE/calls.log"
  # both rows keep their gate, so the next reap tries again
  grep -q '#ask/hold1/b <!-- id:gm-1 -->' "$NOTES_FIXTURE/rows.game.agent"
  grep -q '#ask/mint1/a <!-- id:gm-2 -->' "$NOTES_FIXTURE/rows.game.agent"
}

# A headless gateway run's pane opens its transcript after its tail (gateway_launch); reap closes it
# by the record cmd_start left in $DIR/replay, since a move to queued drops the item's session.
@test "reap closes a headless run's replay once its item leaves review, keeps it in review on its session, and settles a running item whose replay opened" {
  project game beta "$SANDBOX/repos/game"
  printf '%s\n' '{"harnesses": {"paid": {"launcher": "opencode", "sandbox": "pub"}}}' > "$SANDBOX/harnesses.json"
  HARNESSES="$SANDBOX/harnesses.json"
  stub tmux-close 'echo "tmux-close $*" >> "$NOTES_FIXTURE/calls.log"'
  stub agent-panel 'exit 0'
  stub agent-ask 'exit 0'
  # landed: done, replay open. parked: in review on it. requeued: back in queued/, so no session.
  # ended: its session is gone, so no mark either. taken: done, its session live but not the replay (no mark).
  # opened: still running, its replay open: the tail did not move it.
  # old: an older run of parked whose replay is still open, since parked was requeued and restarted.
  mkdir -p "$FLEET_DISPATCH_DIR/replay"
  rec() { echo "$FLEET_DISPATCH_DIR/replay/${1%%:*}@game-agent-${1#*:}"; }
  for s in landed parked requeued ended taken opened; do
    started_item "$s" "lab:game-agent-$s"
    printf 'lab\tgame-agent-%s\t\n' "$s" > "$(rec "$s:$s")"
    case $s in taken | ended) ;; *) printf "%s\n" "$s" > "$NOTES_FIXTURE/tmux.option.game-agent-$s.@headless" ;; esac
  done
  sed -i 's/^agent: claude/agent: paid/' "$AGENT_QUEUE_DIR"/running/*.md
  agent-queue move landed done --status ok >/dev/null
  agent-queue move taken done --status ok >/dev/null
  agent-queue move parked review >/dev/null
  agent-queue move requeued queued >/dev/null
  printf 'lab\tgame-agent-old\t\n' > "$(rec parked:old)"; echo parked > "$NOTES_FIXTURE/tmux.option.game-agent-old.@headless"
  printf 'game-agent-%s\n' landed parked requeued taken opened old > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  assert_success
  for s in landed:landed requeued:requeued opened:opened parked:old; do
    assert_called "tmux-close -L lab session game-agent-${s#*:}"
    [ ! -e "$(rec "$s")" ] || fail "the record of $s outlived its close"
  done
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-opened.md)" status)" failed
  grep -q 'closed game-agent-landed: the headless run of queue item landed left its run (done)' "$FLEET_DISPATCH_DIR/log.md"
  # NEGATIVE CONTROL: a close by the record alone would kill a session another run now holds.
  for s in parked taken ended; do assert_not_called "tmux-close -L lab session game-agent-$s"; done
  [ -n "$(qitem review parked)" ] || fail "a replay in review moved its item"
  [ -e "$(rec parked:parked)" ] && [ -e "$(rec taken:taken)" ] || fail "a kept replay lost its record"
  [ ! -e "$(rec ended:ended)" ] || fail "a gone session kept its record"
  # An item waiting on its replay's session (an ask from the run) keeps it too.
  started_item asked lab:game-agent-asked '' '' human waiting
  printf 'lab\tgame-agent-asked\t\n' > "$(rec asked:asked)"; echo asked > "$NOTES_FIXTURE/tmux.option.game-agent-asked.@headless"
  echo game-agent-asked >> "$NOTES_FIXTURE/tmux.sessions.lab"
  run reap_replays
  assert_not_called "tmux-close -L lab session game-agent-asked"
  # A Claude item's open session is never read as a replay, whatever its tmux options say.
  started_item live lab:game-agent-live
  echo game-agent-live >> "$NOTES_FIXTURE/tmux.sessions.lab"
  echo live > "$NOTES_FIXTURE/tmux.option.game-agent-live.@headless"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-live:1\",\"status\":\"busy\",\"session_id\":\"sl\"}"'
  run cmd_reap
  [ -n "$(qitem running live)" ] || fail "a Claude item was settled by a replay mark"
}

# gone_remote_item -- fix-crash runs on razer-laptop, which answers: its tmux session is gone, as after
# the session closed its item there. This machine's store still reads the item running; the stubbed
# store-sync takes the close from origin ($NOTES_FIXTURE/origin-close, as razer-laptop's ok close) when it runs.
gone_remote_item() {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  remote_item fix-crash
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  # agent-queue syncs in the background (--bg) on every read and write; only the reap's own foreground sync reads origin here.
  stub store-sync 'echo "store-sync $*" >> "$NOTES_FIXTURE/calls.log"; case " $* " in *" --bg "*) exit 0 ;; esac
[ ! -e "$NOTES_FIXTURE/origin-down" ] || exit 1
[ -e "$NOTES_FIXTURE/origin-close" ] || exit 0
# the flag goes first: agent-queue syncs after a write, which would run this stub again
rm "$NOTES_FIXTURE/origin-close"; agent-queue set fix-crash "pr=o/game#12" "merged=abc123" >/dev/null && agent-queue move fix-crash done --status ok >/dev/null'
}

@test "reap reads a peer host's item from origin first: one its session closed ok there is not failed here (ar-4091)" {
  gone_remote_item
  : > "$NOTES_FIXTURE/origin-close"
  run cmd_reap
  assert_success
  grep -qx 'store-sync --now' "$NOTES_FIXTURE/calls.log" || fail "reap did not sync in the foreground before settling"
  refute_output --partial 'failed queue item fix-crash'
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)
  assert_equal "$(qfield "$f" status)" ok
  assert_equal "$(qfield "$f" merged)" abc123
}

@test "reap leaves a peer host's item running while this store cannot reach origin, and fails it once it can" {
  gone_remote_item
  : > "$NOTES_FIXTURE/origin-down"
  run cmd_reap
  assert_success
  [ -n "$(qitem running fix-crash)" ] || fail "settled a peer host's item from a store that could not read origin"
  grep -q 'queue item fix-crash left for the next pass' "$FLEET_DISPATCH_DIR/log.md" || fail 'no log line for the skipped item'
  rm "$NOTES_FIXTURE/origin-down"
  run cmd_reap
  [ -z "$(qitem running fix-crash)" ] || fail "kept an item whose remote session is gone once origin answered"
}

@test "reap counts a store whose sync reached no origin as not fresh, whatever store-sync exits" {
  gone_remote_item
  stub store-sync-age 'exit 1'
  run cmd_reap
  [ -n "$(qitem running fix-crash)" ] || fail "settled a peer host's item with no COMPLETE sync"
}
