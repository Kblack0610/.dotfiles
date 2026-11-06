#!/usr/bin/env bats
# agent-ask: the human<->agent ask queue. One file per ask at ~/.agent/asks/{project}/{id}.md,
# flat `key: value`. The cockpit's attention badges are driven by `agent-ask count`, so the
# TSV shape and the pending/answered lifecycle are a real contract, not an implementation
# detail. HOME is sandboxed, so ASKS_ROOT lands inside the test tmpdir automatically.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
}

post() { "$AGENT_ASK" post --project "${1:-demo}" "${2:-is this a question?}"; }

# ── post ─────────────────────────────────────────────────────────────────────

@test "post prints an id and creates exactly one ask file" {
  run post demo "ship it?"
  assert_success
  [ -n "$output" ]
  local n; n="$(find "$HOME/.agent/asks" -name '*.md' | wc -l)"
  assert_equal "$n" '1'
}

@test "post files the ask under its project directory" {
  local id; id="$(post demo 'ship it?')"
  assert [ -f "$HOME/.agent/asks/demo/$id.md" ]
}

@test "a new ask starts pending" {
  local id; id="$(post demo 'ship it?')"
  run "$AGENT_ASK" show "$id"
  assert_success
  assert_output --partial 'status: pending'
}

@test "post inside tmux records the tmux session unless --session names one" {
  echo agent-10 > "$NOTES_FIXTURE/tmux.session"
  local id
  id="$(TMUX=/tmp/s,1,0 TMUX_PANE=%306 post demo 'merge it?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'session: agent-10'
  id="$(TMUX=/tmp/s,1,0 "$AGENT_ASK" post --project demo --session other 'merge it?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'session: other'
  # outside tmux nothing is guessed
  id="$(post demo 'merge it?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'session: '
}

@test "post records the asking Claude session, even when --session names a tmux session" {
  local id
  id="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'merge it?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'claude_session: sid-1'
  # agents pass their own tmux name as --session; the owner is still the poster
  "$AGENT_ASK" cancel "$id" >/dev/null
  id="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo --session agent-1 'merge it?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'claude_session: sid-1'
  assert_line 'session: agent-1'
}

@test "a session with a pending ask cannot post a second one, and is told how to fold it" {
  local first; first="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'merge it?')"
  CLAUDE_CODE_SESSION_ID=sid-1 run --separate-stderr post other 'ship it too?'
  assert_failure 2
  [[ "$stderr" == *"pending ask $first"* ]]
  [[ "$stderr" == *'merge it?'* ]]
  [[ "$stderr" == *"agent-ask cancel $first superseded"* ]]
  assert_equal "$(find "$HOME/.agent/asks" -name '*.md' | wc -l)" '1'
}

@test "once its ask is answered or cancelled, the session can ask again" {
  local id; id="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'merge it?')"
  "$AGENT_ASK" answer "$id" yes 2>/dev/null
  id="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'ship it?')"
  [ -n "$id" ]
  "$AGENT_ASK" cancel "$id" >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo 'tag it?'
  assert_success
}

@test "another session, or a post with no session id, is not held by someone else's ask" {
  CLAUDE_CODE_SESSION_ID=sid-1 post demo 'merge it?' >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sid-2 "$AGENT_ASK" post --project demo 'ship it?'
  assert_success
  run post demo 'tag it?'
  assert_success
  run post demo 'and this?'
  assert_success
}

@test "an attended session files its ask and sees it in its pane, with no page per ask" {
  # 2026-10-28: agent-27 asked only in the conversation and waited unflagged; the ask file is
  # the one record every board and the phone read.
  CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_SESSION_ID=sid-1 run --separate-stderr \
    "$AGENT_ASK" post --project demo --options 'now=merge now|later=merge after review' --recommend later 'merge it?'
  assert_success
  local id="$output"
  [ -f "$HOME/.agent/asks/demo/$id.md" ]
  [[ "$stderr" == *"asking you  demo . "*"$id"* ]]
  [[ "$stderr" == *"merge it?"* ]]
  [[ "$stderr" == *"  1  now"* ]]
  [[ "$stderr" == *"  2  later  merge after review  (recommended)"* ]]
  [[ "$stderr" == *"never on 'filed as ask $id'"* ]]
  ! grep -q '^agent-notify' "$NOTES_FIXTURE/calls.log"
}

@test "a headless post neither renders nor pages: the briefing pages headless asks" {
  run --separate-stderr "$AGENT_ASK" post --project demo 'merge it?'
  assert_success
  [ -z "$stderr" ]
  ! grep -q '^agent-notify' "$NOTES_FIXTURE/calls.log"
}

@test "settle-session answers an ask with options only when the message names exactly one" {
  local id both
  id="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo --options 'go=run it now|later=run it later' --recommend go 'run the cleanup now?')"
  # Negative controls: an unrelated message, a word that only contains an option, and a message
  # naming both options all leave it pending.
  "$AGENT_ASK" settle-session sid-1 answered "whats going on here?"
  "$AGENT_ASK" settle-session sid-1 answered "ok how many phases left?"
  "$AGENT_ASK" settle-session sid-1 answered "go now or later, you pick"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  run "$AGENT_ASK" settle-session sid-1 answered "Go, run it"
  assert_success
  run "$AGENT_ASK" show "$id"
  assert_line 'status: answered'
  assert_line 'answer: go'
  assert_line 'answered_by: human'
}

@test "settle-session closes only that session's pending asks" {
  local mine other done_
  done_="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'old?')"
  "$AGENT_ASK" answer "$done_" yes 2>/dev/null
  mine="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'merge it?')"
  other="$(CLAUDE_CODE_SESSION_ID=sid-2 post demo 'ship it?')"
  run "$AGENT_ASK" settle-session sid-1 answered "yes, go ahead"
  assert_success
  run "$AGENT_ASK" show "$mine"
  assert_line 'status: answered'
  assert_line 'answer: in session: yes, go ahead'
  # Negative controls: another session's ask stays pending, an answered one keeps its answer.
  run "$AGENT_ASK" show "$other"
  assert_line 'status: pending'
  run "$AGENT_ASK" show "$done_"
  assert_line 'answer: yes'
  # Only the human typing settles an ask; there is no session-end close any more.
  run "$AGENT_ASK" settle-session sid-2 stale "session ended (exit)"
  assert_failure 2
  run "$AGENT_ASK" show "$other"
  assert_line 'status: pending'
  run "$AGENT_ASK" settle-session sid-2 bogus
  assert_failure 2
}

@test "list carries the asking Claude session as its last column" {
  CLAUDE_CODE_SESSION_ID=sid-1 post demo 'merge it?' >/dev/null
  run bash -c '"$AGENT_ASK" list demo | cut -f16'
  assert_output 'sid-1'
}

@test "the question survives the round trip" {
  local id; id="$(post demo 'ship the release?')"
  run "$AGENT_ASK" show "$id"
  assert_output --partial 'ship the release?'
}

@test "a multi-line question is collapsed to one physical line" {
  local id; id="$("$AGENT_ASK" post --project demo "$(printf 'line one\nline two?')")"
  run bash -c '"$AGENT_ASK" show "$1" | grep -c "^question: "' _ "$id"
  assert_output '1'
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^question: //p"' _ "$id"
  assert_output --partial 'line one line two?'
}

@test "post refuses a question that is not one line ending in ?, and says where the detail goes" {
  run --separate-stderr "$AGENT_ASK" post --project demo 'merge it, or wait'
  assert_failure 2
  [[ "$stderr" == *"--context"* ]]
  run --separate-stderr "$AGENT_ASK" post --project demo "$(printf 'x%.0s' $(seq 1 160))?"
  assert_failure 2
  [ -z "$(ls "$HOME/.agent/asks/demo" 2>/dev/null)" ]
  # Negative control: the same post as a short question is filed.
  run "$AGENT_ASK" post --project demo 'merge it?'
  assert_success
}

@test "slug=meaning options keep the slugs alone in options: and the meanings in option_notes:" {
  local id; id="$("$AGENT_ASK" post --project demo --options 'go=run it now|later=after the release' \
    --recommend go --context 'the sweep is ready' 'run the sweep?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'options: go|later'
  assert_line 'option_notes: run it now|after the release'
  assert_line 'context: the sweep is ready'
}

@test "post refuses options with no meanings and names the bare ones" {
  run "$AGENT_ASK" post --project demo --options 'a|b' 'which?'
  assert_failure 2
  assert_output --partial "no meaning: a, b"
  run "$AGENT_ASK" post --project demo --options 'go=run it now|later' 'run it?'
  assert_failure 2
  assert_output --partial "no meaning: later"
  run "$AGENT_ASK" list demo
  assert_output ''
  # Negative controls: every option with its meaning is filed, and so is a gate's default.
  run "$AGENT_ASK" post --project demo --options 'go=run it now|later=after the release' 'run it?'
  assert_success
  run "$AGENT_ASK" post --project demo --kind gate 'merge #3?'
  assert_success
}

@test "card shows the question, numbered options with meanings, the recommendation, context and judge" {
  local id; id="$("$AGENT_ASK" post --project demo --session agent-1 --options 'go=run it now|later=after the release' \
    --recommend later --context 'the sweep is ready' 'run the sweep?')"
  printf 'judge: take-recommend\njudge_reason: the policy says wait\n' >> "$HOME/.agent/asks/demo/$id.md"
  run env COLUMNS=80 "$AGENT_ASK" card "$id"
  assert_success
  assert_line --partial "asking you  demo:1 . "
  assert_line 'run the sweep?'
  assert_line '  1  go     run it now'
  assert_line '  2  later  after the release  (recommended)'
  assert_line 'why: the sweep is ready'
  assert_line 'the judge would take the recommendation - the policy says wait'
  # No colour off a terminal: the card lands in a session's tool output as plain text.
  ! grep -q $'\e' <<< "$output"
}

@test "card leaves out a session that repeats the project, a judge that only says needs you, and the kind of a question" {
  local id; id="$("$AGENT_ASK" post --project demo --session demo --options 'a=the first|b=the second' 'which?')"
  printf 'judge: human\njudge_reason: only you know\n' >> "$HOME/.agent/asks/demo/$id.md"
  run env COLUMNS=80 "$AGENT_ASK" card "$id"
  assert_success
  assert_line --index 0 --regexp "^asking you  demo \. [0-9]+m ago \. $id\$"
  refute_output --partial 'judge'
  refute_output --partial 'only you know'
  local g; g="$("$AGENT_ASK" post --project demo --kind gate 'ship it?')"
  run env COLUMNS=80 "$AGENT_ASK" card "$g"
  assert_line --index 0 --partial 'gate - asking you  demo'
}

# The real agentctl-session-outcomes, reading its lib from the repo and its rows from the sandbox.
outcomes_cli() {
  printf '#!/bin/sh\nSO_LIB_DIR="%s/.local/lib" exec "%s/.local/bin/agentctl-session-outcomes" "$@"\n' \
    "$REPO_ROOT" "$REPO_ROOT" > "$SANDBOX/bin/agentctl-session-outcomes"
  chmod +x "$SANDBOX/bin/agentctl-session-outcomes"
}

# The story under the card: where the ask came from, the request, the asking turn's prompt and
# words (agent-panel said, stubbed from a fixture), and the nightly outcome row, which the real
# agentctl-session-outcomes reads from the sandbox.
@test "card tells the story: source, request, the asking turn, its words, telemetry" {
  mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/p" "$HOME/.agent/sessions/demo" "$HOME/.agent/outcomes/demo"
  printf '{"pid":%d,"sessionId":"sid-s"}\n' "$$" > "$HOME/.claude/sessions/$$.json"
  : > "$HOME/.claude/projects/p/sid-s.jsonl"
  printf '{"session_id":"sid-s","title":"merge-queue-review","first_prompt":"cut"}\n' > "$HOME/.agent/sessions/demo/sessions.jsonl"
  printf '%s\n' '{"first":"review the merge queue","prompt":"should we keep it?","said":["Looked at the queue.","Keep it? 1 keep 2 drop"]}' \
    > "$NOTES_FIXTURE/agent-panel.said"
  local now iso; now="$(date +%s)"; iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  { printf '{"session_id":"sid-s","project":"demo","title":"t","updated":"%s","updated_epoch":%d,"observed":"%s","cost_usd":1.5,"duration_s":3720,"prs":[],"prs_merged":1,"prs_open":0,"corrections":{"lessons_written":1}}\n' "$iso" "$now" "$iso"
    printf '{"session_id":"sid-o","project":"demo","title":"o","updated":"%s","updated_epoch":%d,"observed":"%s","prs":[],"corrections":{"interrupts":3}}\n' "$iso" "$now" "$iso"
  } > "$HOME/.agent/outcomes/demo/2026-11.jsonl"
  outcomes_cli
  local id; id="$(CLAUDE_CODE_SESSION_ID=sid-s "$AGENT_ASK" post --project demo --session agent-3 --agent runner-x \
    --task item-y --options 'keep=keep it|drop=drop it' 'keep the merge queue?')"
  run env COLUMNS=110 "$AGENT_ASK" card "$id"
  assert_success
  assert_line 'from      queue item item-y, runner runner-x, tmux agent-3, claude sid-s (live)'
  assert_line 'request   merge-queue-review: review the merge queue'
  assert_line 'you said  should we keep it?'
  # The newest block is where the session stands; the older one is left to the session.
  assert_line 'it said   Keep it? 1 keep 2 drop'
  refute_output --partial 'Looked at the queue.'
  assert_line --regexp '^telemetry friction 2 \(#2 of 2 this week\): 2 x 1 lessons written \. \$1\.50 \. 1h2m \. 1 PRs merged \. seen 0m ago$'
  grep -qx "agent-panel said $HOME/.claude/projects/p/sid-s.jsonl --around $id" "$NOTES_FIXTURE/calls.log"
  # The asking pane's own copy is the card alone: that session already holds the story.
  run env CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_SESSION_ID=sid-s "$AGENT_ASK" post --project demo 'again?'
  refute_output --partial 'it said'
}

@test "card leaves out each story block that has no data" {
  mkdir -p "$HOME/.agent/sessions/demo"
  printf '{"session_id":"sid-t","title":"only-a-title"}\n' > "$HOME/.agent/sessions/demo/sessions.jsonl"
  # A session with a registry title but no transcript, no live process and no outcome row.
  local id; id="$(CLAUDE_CODE_SESSION_ID=sid-t "$AGENT_ASK" post --project demo --options 'a=the first|b=the second' 'which?')"
  run env COLUMNS=80 "$AGENT_ASK" card "$id"
  assert_success
  assert_line 'from      claude sid-t (ended)'
  assert_line 'request   only-a-title'
  refute_output --partial 'you said'
  refute_output --partial 'it said'
  refute_output --partial 'telemetry'
  refute_line --partial 'only-a-title:'
  # A session with no friction has no rank; its row still gives the telemetry line.
  mkdir -p "$HOME/.agent/outcomes/demo"; outcomes_cli
  printf '{"session_id":"sid-t","project":"demo","title":"t","updated":"x","updated_epoch":%d,"observed":"%s","prs":[],"prs_merged":0}\n' \
    "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HOME/.agent/outcomes/demo/2026-11.jsonl"
  run env COLUMNS=80 "$AGENT_ASK" card "$id"
  assert_line 'telemetry friction 0 . 0 PRs merged . seen 0m ago'
  # An ask no session owns, posted outside tmux, tells no story at all.
  local loose; loose="$("$AGENT_ASK" post --project demo 'headless?')"
  run env COLUMNS=80 "$AGENT_ASK" card "$loose"
  refute_output --partial 'from'
  refute_output --partial 'request'
}

# The panel's card reads on one screen (human, 2026-11-05): the newest words with the ask itself
# and tables taken out, each story block capped, long meanings hung under themselves.
@test "card fits a page: it said drops the repeated ask and tables, blocks are capped, notes hang" {
  mkdir -p "$HOME/.claude/projects/p" "$HOME/.agent/sessions/demo"
  : > "$HOME/.claude/projects/p/sid-p.jsonl"
  local long; long="$(printf 'word%.0s ' $(seq 1 120))"
  jq -cn --arg long "$long" '{first: $long, prompt: "go on", said: [
    "Older status that still says something.",
    "Merged #1 and **rebuilt** the hub.\n\n| col | col |\n|---|---|\n| a | b |\n```\ncode here\n```\nShip it now?\n\n1. yes: ship\n2. no: wait\n\nIt stays open until you answer.",
    "## Ship it now?\n\n1. yes: ship\n2. no: wait"]}' > "$NOTES_FIXTURE/agent-panel.said"
  local id; id="$(CLAUDE_CODE_SESSION_ID=sid-p "$AGENT_ASK" post --project demo \
    --options "yes=ship it to every store today, after the last check is green and the notes are in|no=wait" \
    --recommend no 'Ship it now?')"
  run env COLUMNS=60 "$AGENT_ASK" card "$id"
  assert_success
  # The newest block only repeats the ask, so the one before it speaks; its tables, code, bold
  # marks, the question and its option list are gone.
  assert_line 'it said   Merged #1 and rebuilt the hub.'
  assert_line '          It stays open until you answer.'
  refute_output --partial 'col'
  refute_output --partial 'code here'
  refute_output --partial '1. yes'
  refute_output --partial 'Older status'
  # A request of 120 words keeps three lines, the last cut with "...".
  assert_equal "$(grep -c 'word' <<<"$output")" 3
  assert_line --regexp '^          (word )+\.\.\.$'
  # The long meaning wraps under itself, past the number and slug column.
  assert_line '  1  yes  ship it to every store today, after the last'
  assert_line '          check is green and the notes are in'
  local w; w="$(awk '{ if (length > m) m = length } END { print m }' <<<"$output")"
  [ "$w" -le 60 ]
}

@test "card names an agent session the way the questions panel row does: slug:N, then the project" {
  registry
  local id; id="$("$AGENT_ASK" post --project big-platform --session big-platform-agent-60 'which?')"
  run env COLUMNS=80 "$AGENT_ASK" card "$id"
  assert_line --index 0 --regexp '^asking you  bp:60 \. big-platform \. [0-9]+m ago \. '
}

@test "card of an old ask with bare options and no notes still lists the options" {
  mkdir -p "$HOME/.agent/asks/demo"
  printf 'id: old1\nproject: demo\nkind: question\nstatus: pending\nquestion: a long old paragraph\noptions: x|y\nrecommend: y\n' \
    > "$HOME/.agent/asks/demo/old1.md"
  run "$AGENT_ASK" card old1
  assert_line 'a long old paragraph'
  assert_line '  1  x'
  assert_line '  2  y  (recommended)'
}

@test "ids are unique across rapid successive posts" {
  local a b c
  a="$(post demo one?)"; b="$(post demo two?)"; c="$(post demo three?)"
  local n; n="$(printf '%s\n%s\n%s\n' "$a" "$b" "$c" | sort -u | wc -l)"
  assert_equal "$n" '3'
}

# ── list: the TSV the cockpit's factory view consumes ────────────────────────

@test "list emits 21 tab-separated fields per ask" {
  post demo 'ship it?' >/dev/null
  run bash -c '"$AGENT_ASK" list demo | awk -F"\t" "{print NF; exit}"'
  assert_output '21'
}

@test "the last three fields are option_notes, context and recommend_why, for agent-web's answer cards" {
  "$AGENT_ASK" post --project demo --options 'a=prune it|b=grow it' --recommend a --why 'fixes the cause' --context 'disk is full' 'which fix?' >/dev/null
  run bash -c '"$AGENT_ASK" list demo | cut -f19-21'
  assert_output "$(printf 'prune it|grow it\tdisk is full\tfixes the cause')"
}

@test "the last two fields are created and session, for fleet-bench's ask digest" {
  "$AGENT_ASK" post --project demo --session lab/game-agent-1 'ship it?' >/dev/null
  run bash -c '"$AGENT_ASK" list demo | cut -f12,13'
  assert_output --regexp $'^20[0-9-]{8}T[0-9:]{8}[-+][0-9]{4}\tlab/game-agent-1$'
}

# The count is a contract, not trivia. `_factory_view` reads these with a positional
# `read -r a b c ...`, and bash puts every UNNAMED trailing field into the LAST variable —
# so adding a column without widening the reader does not error, it silently glues the new
# data onto whatever the last named field was (here: the ask's task context).
@test "the two trailing fields are answered_at and resumed_at, in that order" {
  local id; id="$(post demo 'ship it?')"
  run bash -c '"$AGENT_ASK" list demo | cut -f9,10'
  assert_output "$(printf '\t')"          # both empty while pending

  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" list demo | cut -f9 | grep -c .'
  assert_output '1'                        # answered_at is stamped
  run bash -c '"$AGENT_ASK" list demo | cut -f10'
  assert_output ''                         # resumed_at is NOT — nobody has acted yet

  "$AGENT_ASK" mark-resumed "$id" >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" list demo | cut -f10 | grep -c .'
  assert_output '1'
}

@test "list puts the id first and the status fourth" {
  local id; id="$(post demo 'ship it?')"
  run bash -c '"$AGENT_ASK" list demo | cut -f1'
  assert_output "$id"
  run bash -c '"$AGENT_ASK" list demo | cut -f4'
  assert_output 'pending'
}

@test "list --all spans every project" {
  post alpha 'a?' >/dev/null
  post beta  'b?' >/dev/null
  run bash -c '"$AGENT_ASK" list --all | cut -f2 | sort -u | tr "\n" " "'
  assert_output 'alpha beta '
}

@test "list scoped to one project excludes the others" {
  post alpha 'a?' >/dev/null
  post beta  'b?' >/dev/null
  run bash -c '"$AGENT_ASK" list alpha | cut -f2 | sort -u'
  assert_output 'alpha'
}

@test "list --pending hides answered asks" {
  local id; id="$(post demo 'ship it?')"
  post demo 'second?' >/dev/null
  "$AGENT_ASK" answer "$id" yes 2>/dev/null
  run bash -c '"$AGENT_ASK" list demo --pending | wc -l'
  assert_output '1'
}

@test "list is empty and succeeds for a project with no asks" {
  run "$AGENT_ASK" list nosuchproject
  assert_success
  assert_output ''
}

# ── count: what drives the cockpit's !n attention badges ─────────────────────

@test "count is zero for an empty queue" {
  run "$AGENT_ASK" count demo
  assert_success
  assert_output '0'
}

@test "count tracks pending asks" {
  post demo 'a?' >/dev/null
  post demo 'b?' >/dev/null
  run "$AGENT_ASK" count demo
  assert_output '2'
}

@test "count drops when an ask is answered" {
  local id; id="$(post demo 'a?')"
  post demo 'b?' >/dev/null
  "$AGENT_ASK" answer "$id" yes 2>/dev/null
  run "$AGENT_ASK" count demo
  assert_output '1'
}

@test "count drops when an ask is cancelled" {
  local id; id="$(post demo 'a?')"
  "$AGENT_ASK" cancel "$id" 2>/dev/null
  run "$AGENT_ASK" count demo
  assert_output '0'
}

# ── answer / cancel lifecycle ────────────────────────────────────────────────

@test "answer flips status and records the answer text" {
  local id; id="$(post demo 'ship it?')"
  "$AGENT_ASK" answer "$id" "yes, ship it" 2>/dev/null
  run "$AGENT_ASK" show "$id"
  assert_output --partial 'status: answered'
  assert_output --partial 'answer: yes, ship it'
}

@test "answer stamps answered_at" {
  local id; id="$(post demo 'ship it?')"
  "$AGENT_ASK" answer "$id" yes 2>/dev/null
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^answered_at: //p"' _ "$id"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
}

@test "answer does not page the human about their own answer" {
  local id; id="$(post demo 'ship it?')"
  : > "$NOTES_FIXTURE/calls.log"
  "$AGENT_ASK" answer "$id" yes 2>/dev/null
  ! grep -q '^agent-notify' "$NOTES_FIXTURE/calls.log"
}

@test "answering does not destroy the original question" {
  local id; id="$(post demo 'the original question?')"
  "$AGENT_ASK" answer "$id" yes 2>/dev/null
  run "$AGENT_ASK" show "$id"
  assert_output --partial 'the original question?'
}

@test "cancel flips status to cancelled" {
  local id; id="$(post demo 'ship it?')"
  "$AGENT_ASK" cancel "$id" 2>/dev/null
  run "$AGENT_ASK" show "$id"
  assert_output --partial 'status: cancelled'
}

@test "answering a second time overwrites rather than appending a duplicate key" {
  local id; id="$(post demo 'ship it?')"
  "$AGENT_ASK" answer "$id" first  2>/dev/null
  "$AGENT_ASK" answer "$id" second 2>/dev/null
  run bash -c '"$AGENT_ASK" show "$1" | grep -c "^answer: "' _ "$id"
  assert_output '1'
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^answer: //p"' _ "$id"
  assert_output 'second'
}

# ── error paths ──────────────────────────────────────────────────────────────

@test "show on an unknown id fails rather than printing nothing and succeeding" {
  run "$AGENT_ASK" show nope-not-real
  assert_failure
}

@test "answer on an unknown id fails" {
  run "$AGENT_ASK" answer nope-not-real yes
  assert_failure
}

@test "answer with no answer text is a usage error, not a silent no-op" {
  local id; id="$(post demo 'ship it?')"
  run "$AGENT_ASK" answer "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_output --partial 'status: pending'
}

@test "an unknown subcommand fails and prints usage" {
  run "$AGENT_ASK" definitely-not-a-subcommand
  assert_failure
}

# ── containment ──────────────────────────────────────────────────────────────

@test "every write stays inside the sandboxed HOME" {
  post demo 'ship it?' >/dev/null
  local outside
  outside="$(find "$HOME/.agent/asks" -name '*.md' | grep -vcF "$HOME" || true)"
  assert_equal "$outside" '0'
  assert [ -d "$HOME/.agent/asks" ]
  [[ "$HOME" == *"$BATS_TEST_TMPDIR"* ]]
}

# ── change signal ────────────────────────────────────────────────────────────
# fleet-state.path watches ~/.agent/asks/.changed: without the rewrite a new ask waits up to
# 10 minutes to reach the fleet state document and the phone.


@test "post, answer and cancel each rewrite the queue's change signal" {
  local id id2
  [ ! -e "$HOME/.agent/asks/.changed" ]
  id="$(post demo 'ship it?')"
  assert [ -f "$HOME/.agent/asks/.changed" ]
  rm "$HOME/.agent/asks/.changed"
  AGENT_ASK_NO_RESUME=1 "$AGENT_ASK" answer "$id" yes 2>/dev/null
  assert [ -f "$HOME/.agent/asks/.changed" ]
  id2="$(post demo 'and this?')"
  rm "$HOME/.agent/asks/.changed"
  "$AGENT_ASK" cancel "$id2" 2>/dev/null
  assert [ -f "$HOME/.agent/asks/.changed" ]
}

@test "negative control: reading the queue does not signal a change" {
  post demo 'ship it?' >/dev/null
  rm "$HOME/.agent/asks/.changed"
  "$AGENT_ASK" list --all >/dev/null
  "$AGENT_ASK" count --all >/dev/null
  assert [ ! -e "$HOME/.agent/asks/.changed" ]
}

# ── lifecycle: one home ──────────────────────────────────────────────────────
# An ask stays pending until the human answers or drops it, however old and whether or not its
# session lives. Nothing marks it stale or copies it to a board.

ask_file() { find "$HOME/.agent/asks" -name "$1.md"; }

@test "stale and expire are gone, and an old ask stays pending" {
  local id; id="$(post demo 'ship it?')"
  sed -i "s/^created: .*/created: 2026-01-01T00:00:00+0000/" "$(ask_file "$id")"
  run "$AGENT_ASK" stale "$id"
  assert_failure
  run "$AGENT_ASK" expire
  assert_failure
  grep -q '^status: pending$' "$(ask_file "$id")"
  assert_equal "$("$AGENT_ASK" count demo)" 1
}

@test "the card says where the answer goes once the session is gone" {
  local gone live loose resumed
  # A live session is a Claude process file naming it whose pid runs (this test's own pid).
  mkdir -p "$HOME/.claude/sessions"
  printf '{"pid":%d,"sessionId":"sid-1"}\n' "$$" > "$HOME/.claude/sessions/$$.json"
  # sid-9's and sid-8's files name pids that are not running, so they are gone all the same.
  printf '{"pid":999999999,"sessionId":"sid-9"}\n' > "$HOME/.claude/sessions/999999999.json"
  printf '{"pid":999999998,"sessionId":"sid-8"}\n' > "$HOME/.claude/sessions/999999998.json"
  live="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'live?')"
  gone="$(CLAUDE_CODE_SESSION_ID=sid-9 post demo 'gone?')"
  resumed="$(CLAUDE_CODE_SESSION_ID=sid-8 "$AGENT_ASK" post --project demo --resume '/captain resume' 'resumed?')"
  loose="$(post demo 'headless?')"
  run "$AGENT_ASK" card "$gone"
  assert_output --partial 'session gone: the answer becomes a row on the demo board'
  run "$AGENT_ASK" card "$resumed"
  assert_output --partial 'session gone: the answer starts `/captain resume`'
  assert_output --partial 'g reopens the session'
  # Negative controls: a live session, and an ask no session owns.
  run "$AGENT_ASK" card "$live"
  refute_output --partial 'session gone'
  refute_output --partial 'g reopens'
  run "$AGENT_ASK" card "$loose"
  refute_output --partial 'session gone'
  refute_output --partial 'g reopens'
  # The questions panel's gone mark reads the same source.
  run "$AGENT_ASK" live-sessions
  assert_output 'sid-1'
}

@test "cancel records its reason" {
  local id; id="$(post demo 'ship it?')"
  "$AGENT_ASK" cancel "$id" superseded by the v1.19 gate 2>/dev/null
  grep -q '^closed_reason: superseded by the v1.19 gate$' "$(ask_file "$id")"
}

# ── post: where an ask is filed ──────────────────────────────────────────────

registry() {
  mkdir -p "$HOME/.config/shared-hooks"
  ln -sf "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/project-name.sh"
  export PROJECT_MAP_FILE="$SANDBOX/project-map.json"
  printf '%s\n' '{"paths":{"/r/big":"big-platform"},"aliases":{"monorepo":"big-platform"},
    "trackers":{"_comment":"x","notes-cockpit":{"repo":"dotfiles"},
      "shop":{"repo":"big-platform","path":"apps/shop"}}}' > "$PROJECT_MAP_FILE"
}

@test "post refuses an explicit project the registry does not know, or an alias" {
  registry
  run "$AGENT_ASK" post --project shpo 'typo?'
  assert_failure 2
  run "$AGENT_ASK" post --project monorepo 'alias?'
  assert_failure 2
  # negative control: canonical names from every part of the registry are accepted
  for p in big-platform shop notes-cockpit; do
    run "$AGENT_ASK" post --project "$p" 'ok?'
    assert_success
  done
}

# ── the answer judge (shadow) ────────────────────────────────────────────────

# fake_judge <json>: a judge command that prints <json> between the markers, and logs its prompt.
# Outside the sandbox dir: its path has a space, and the judge command is a word list.
fake_judge() {
  cat > "$BATS_TEST_TMPDIR/judge" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/judge.calls"
printf '%s\n' "\$AGENTCTL_CALL_ID" > "$BATS_TEST_TMPDIR/judge.id"
printf 'thinking...\nASK-JUDGE-START\n%s\nASK-JUDGE-END\n' '$1'
SH
  chmod +x "$BATS_TEST_TMPDIR/judge"
  export AGENT_ASK_JUDGE_CMD="$BATS_TEST_TMPDIR/judge"
  # The real policy: its rule ids are the ones a verdict may name.
  export AGENT_ASK_POLICY="$REPO_ROOT/.config/agent-ask/policy.md"
}

@test "judge records its call and reason, and leaves the ask pending" {
  fake_judge '{"call":"take-recommend","rule":"restates-rule","answer":"","reason":"landing is standing authorization"}'
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'open the PR?')"
  run "$AGENT_ASK" judge "$id"
  assert_success
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: take-recommend'
  assert_line 'judge_reason: landing is standing authorization'
  assert_line 'judge_rule: restates-rule'
  assert_line "judge_call: $(cat "$BATS_TEST_TMPDIR/judge.id")"
  assert_line 'status: pending'
  assert_line --regexp '^judged_at: .+'
  # the input carries the ask; the policy is the agent's PROMPT, added by agentctl-run
  run cat "$BATS_TEST_TMPDIR/judge.calls"
  assert_output --partial 'open the PR?'
  refute_output --partial 'Always `human`'
}

@test "judge never sends a gate to the model, and the gate's judge is the human" {
  fake_judge '{"call":"answer","answer":"approve","reason":"x"}'
  local id; id="$("$AGENT_ASK" post --project demo --kind gate 'merge #1?')"
  run "$AGENT_ASK" judge "$id"
  assert_success
  assert [ ! -e "$BATS_TEST_TMPDIR/judge.calls" ]
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: human'
  refute_line --partial 'answer: approve'
}

@test "judge turns a call the ask cannot carry out into human, and runs once per ask" {
  fake_judge '{"call":"take-recommend","rule":"continue-work","answer":"","reason":"x"}'
  local id; id="$(post demo 'no recommendation here?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: human'
  "$AGENT_ASK" judge "$id"
  run grep -c "^question: no recommendation here?$" "$BATS_TEST_TMPDIR/judge.calls"
  assert_output '1'
}

@test "judge records a free answer, and a reply with no verdict is an error verdict" {
  fake_judge '{"call":"answer","rule":"simpler","answer":"the simpler one","reason":"no product effect"}'
  local id; id="$(post demo 'which way?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: answer:the simpler one'
  fake_judge 'not json'
  id="$(post demo 'again?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: error'
  assert_line 'judge_reason: the reply had no verdict: thinking... ASK-JUDGE-START not json ASK-JUDGE-END'
  assert_line --regexp '^judge_call: [0-9a-f]{12}$'
}

@test "judge: a rule the policy does not define, a failed call and a missing policy are error verdicts with their reason" {
  fake_judge '{"call":"take-recommend","rule":"vibes","answer":"","reason":"x"}'
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'open the PR?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: error'
  assert_line "judge_reason: rule 'vibes' is not in the policy"
  refute_line --partial 'judge_rule:'
  # a call that fails says how, from its stderr
  printf '#!/usr/bin/env bash\necho "rate limited" >&2; exit 7\n' > "$BATS_TEST_TMPDIR/judge"
  id="$(post demo 'again?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: error'
  assert_line 'judge_reason: call failed (exit 7): rate limited'
  # no policy to read the rules from
  fake_judge '{"call":"human","rule":"taste","answer":"","reason":"x"}'
  export AGENT_ASK_POLICY="$BATS_TEST_TMPDIR/none.md"
  id="$(post demo 'and again?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: error'
  assert_line --partial "judge_reason: no rules in the policy $BATS_TEST_TMPDIR/none.md"
  # negative control: the same verdict against the real policy is recorded
  export AGENT_ASK_POLICY="$REPO_ROOT/.config/agent-ask/policy.md"
  id="$(post demo 'once more?')"
  run "$AGENT_ASK" judge "$id"
  assert_success
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: human'
  assert_line 'judge_rule: taste'
}

@test "judge: a gate names the gate rule and no call" {
  local id; id="$("$AGENT_ASK" post --project demo --kind gate 'merge #2?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge_rule: gate'
  refute_line --partial 'judge_call:'
}

@test "post runs the judge before it returns, unless AGENT_ASK_NO_JUDGE is set" {
  fake_judge '{"call":"human","rule":"taste","answer":"","reason":"taste"}'
  unset AGENT_ASK_NO_JUDGE
  local id; id="$(post demo 'pick a colour?')"
  run grep -c 'pick a colour?' "$BATS_TEST_TMPDIR/judge.calls"
  assert_output '1'
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: human'
  assert_line 'status: pending'
  # negative control: with the guard, no call
  rm -f "$BATS_TEST_TMPDIR/judge.calls"
  export AGENT_ASK_NO_JUDGE=1
  id="$(post demo 'pick a shape?')"
  assert [ ! -e "$BATS_TEST_TMPDIR/judge.calls" ]
  run "$AGENT_ASK" show "$id"
  refute_line --partial 'judge:'
}

# ── live answers ─────────────────────────────────────────────────────────────

# live_post <claude_session> <question>: a post from that Claude session, the way an agent asks.
live_post() {
  CLAUDE_CODE_SESSION_ID="$1" "$AGENT_ASK" post --project demo \
    --options 'fix=fix the test in its own PR|wait=park until the row is fixed' --recommend fix "$2"
}

@test "a live rule's take-recommend is answered by the judge at post, and the asker is told to proceed" {
  fake_judge '{"call":"take-recommend","rule":"restates-rule","answer":"","reason":"rules say fix failing CI yourself."}'
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_LIVE_RULES=restates-rule
  run --separate-stderr live_post sid-1 'fix the flaky test here?'
  assert_success
  local id="$output"
  assert_regex "$id" '^[A-Za-z0-9]{6}$'
  assert_equal "$stderr" "Answered by the judge (restates-rule): fix - rules say fix failing CI yourself. Proceed; the human can override in this session."
  run "$AGENT_ASK" show "$id"
  assert_line 'status: answered'
  assert_line 'answer: fix'
  assert_line 'answered_by: judge'
  assert_line "judge_call: $(cat "$BATS_TEST_TMPDIR/judge.id")"
  assert_equal "$("$AGENT_ASK" count demo)" 0
}

@test "live answers: a shadow rule, an empty LIVE_RULES, a gate and a human call all stay with the human" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_LIVE_RULES=restates-rule
  fake_judge '{"call":"take-recommend","rule":"simpler","answer":"","reason":"x"}'
  local id; id="$(live_post sid-a 'shadow rule?')"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'; assert_line 'judge: take-recommend'
  export AGENT_ASK_LIVE_RULES=
  fake_judge '{"call":"take-recommend","rule":"restates-rule","answer":"","reason":"x"}'
  id="$(live_post sid-b 'nothing live?')"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  export AGENT_ASK_LIVE_RULES=restates-rule
  id="$("$AGENT_ASK" post --project demo --kind gate 'merge #4?')"
  assert [ "$(grep -c 'merge #4' "$BATS_TEST_TMPDIR/judge.calls")" = 0 ]
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  fake_judge '{"call":"human","rule":"restates-rule","answer":"","reason":"x"}'
  id="$(live_post sid-c 'human call?')"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  # A demoted rule is out of the live set even while the conf lists it.
  fake_judge '{"call":"take-recommend","rule":"restates-rule","answer":"","reason":"x"}'
  mkdir -p "$(dirname "$HOME/.local/state/agent-ask/demoted")"
  printf 'restates-rule\t2026-11-05T00:00:00+0000\tx\n' > "$HOME/.local/state/agent-ask/demoted"
  id="$(live_post sid-d 'demoted?')"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  # negative control: the same verdict with the demote gone is answered
  rm "$HOME/.local/state/agent-ask/demoted"
  id="$(live_post sid-e 'live again?')"
  run "$AGENT_ASK" show "$id"; assert_line 'answered_by: judge'
}

@test "live answers: malformed output is an error verdict, and a stuck call times out to one; both stay pending" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_LIVE_RULES=restates-rule
  fake_judge 'not json'
  run --separate-stderr live_post sid-1 'garbled?'
  assert_success
  run "$AGENT_ASK" show "$output"
  assert_line 'judge: error'; assert_line 'status: pending'
  # A judge that never returns: it blocks opening a fifo nobody writes, and the guard kills it.
  mkfifo "$BATS_TEST_TMPDIR/never"
  printf '#!/usr/bin/env bash\nread -r _ < "%s"\n' "$BATS_TEST_TMPDIR/never" > "$BATS_TEST_TMPDIR/judge"
  export AGENT_ASK_JUDGE_TIMEOUT=1
  run --separate-stderr env CLAUDE_CODE_SESSION_ID=sid-2 "$AGENT_ASK" post --project demo \
    --options 'fix=fix it|wait=wait' --recommend fix 'stuck?'
  assert_success
  run "$AGENT_ASK" show "$output"
  assert_line 'judge: error'
  assert_line 'judge_reason: the judge call timed out after 1s'
  assert_line 'status: pending'
}

@test "override: the human's next message naming another option labels the live answer and demotes the class" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_LIVE_RULES=restates-rule
  fake_judge '{"call":"take-recommend","rule":"restates-rule","answer":"","reason":"x"}'
  local id; id="$(live_post sid-1 'fix it here?' 2>/dev/null)"
  "$AGENT_ASK" settle-session sid-1 answered "no, wait for the row to be fixed"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge_override: wait'
  assert_line 'judge_override_note: in session: no, wait for the row to be fixed'
  assert_line 'answer: fix'
  run cat "$HOME/.local/state/agent-ask/demoted"
  assert_output --regexp "^restates-rule	.+	override on ask $id: live answer 1 of 1, 1 overridden$"
  assert_called 'agent-notify -p high -t Judge demoted'
  assert_called 'notes ptask agent-runtime --agent add check(judge): ask-judge restates-rule went back to shadow'
  # Once demoted, the class is shadow: the next one stays with the human.
  id="$(live_post sid-2 'and this one?' 2>/dev/null)"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
}

@test "override: a message that agrees or says nothing about the options closes the review with none" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_LIVE_RULES=restates-rule
  fake_judge '{"call":"take-recommend","rule":"restates-rule","answer":"","reason":"x"}'
  local a b
  a="$(live_post sid-1 'fix it here?' 2>/dev/null)"
  "$AGENT_ASK" settle-session sid-1 answered "ok how many phases left?"
  run "$AGENT_ASK" show "$a"; assert_line 'judge_override: none'
  # a later message naming the other option is about something else now
  "$AGENT_ASK" settle-session sid-1 answered "wait"
  run "$AGENT_ASK" show "$a"; assert_line 'judge_override: none'
  b="$(live_post sid-3 'fix that one too?' 2>/dev/null)"
  "$AGENT_ASK" settle-session sid-3 answered "yes, fix it"
  run "$AGENT_ASK" show "$b"; assert_line 'judge_override: none'
  assert [ ! -e "$HOME/.local/state/agent-ask/demoted" ]
  assert_not_called 'agent-notify'
}

@test "override: past the first 30 live answers, a class stays live while its precision holds 90%" {
  export AGENT_ASK_LIVE_RULES=restates-rule AGENT_ASK_LIVE_BAR=3
  local d="$HOME/.agent/asks/demo" i
  mkdir -p "$d"
  # Four live answers already reviewed, none overridden.
  for i in 1 2 3 4; do
    printf 'id: L%05d\nproject: demo\nstatus: answered\noptions: fix|wait\nanswer: fix\nanswered_by: judge\nanswered_at: 2026-11-05T09:0%d:00+0000\njudge_rule: restates-rule\njudge_override: none\n' "$i" "$i" > "$d/L$(printf %05d "$i").md"
  done
  # The fifth is overridden: 4 of 5 is 80%, under the bar.
  printf 'id: L00005\nproject: demo\nclaude_session: sid-9\nstatus: answered\noptions: fix|wait\nanswer: fix\nanswered_by: judge\nanswered_at: 2026-11-05T09:05:00+0000\njudge_rule: restates-rule\n' > "$d/L00005.md"
  export AGENT_ASK_LIVE_PRECISION=90
  "$AGENT_ASK" settle-session sid-9 answered "wait"
  assert [ -s "$HOME/.local/state/agent-ask/demoted" ]
  # negative control: at a 75% bar the same override keeps the class live
  rm "$HOME/.local/state/agent-ask/demoted"
  sed -i '/^judge_override/d' "$d/L00005.md"
  export AGENT_ASK_LIVE_PRECISION=75
  "$AGENT_ASK" settle-session sid-9 answered "wait"
  run "$AGENT_ASK" show L00005; assert_line 'judge_override: wait'
  assert [ ! -e "$HOME/.local/state/agent-ask/demoted" ]
}

@test "every answer path records answered_by" {
  local a b c
  a="$(post demo 'one?')"; b="$(post demo 'two?')"
  "$AGENT_ASK" answer "$a" yes 2>/dev/null
  "$AGENT_ASK" answer --by shepherd "$b" no 2>/dev/null
  run "$AGENT_ASK" show "$a"; assert_line 'answered_by: human'
  run "$AGENT_ASK" show "$b"; assert_line 'answered_by: shepherd'
  run "$AGENT_ASK" answer --by robot "$b" no
  assert_failure 2
  c="$("$AGENT_ASK" post --project demo --session s 'three?')"
  sed -i 's/^claude_session: .*/claude_session: sid-1/' "$HOME/.agent/asks/demo/$c.md"
  "$AGENT_ASK" settle-session sid-1 answered ok
  run "$AGENT_ASK" show "$c"; assert_line 'answered_by: human'
}

@test "judge-report scores the judge against the human's answer" {
  local agree differ session deferred failed
  agree="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'a?')"
  differ="$(post demo 'b?')"; session="$(post demo 'c?')"; deferred="$(post demo 'd?')"; failed="$(post demo 'e?')"
  sed -i 's/^judge: .*//' "$HOME/.agent/asks/demo/"*.md
  printf 'judge: take-recommend\n' >> "$HOME/.agent/asks/demo/$agree.md"
  printf 'judge: answer:left\n' >> "$HOME/.agent/asks/demo/$differ.md"
  printf 'judge: answer:left\n' >> "$HOME/.agent/asks/demo/$session.md"
  printf 'judge: human\n' >> "$HOME/.agent/asks/demo/$deferred.md"
  printf 'judge: error\n' >> "$HOME/.agent/asks/demo/$failed.md"
  "$AGENT_ASK" answer "$agree" Yes 2>/dev/null
  "$AGENT_ASK" answer "$differ" right 2>/dev/null
  "$AGENT_ASK" answer "$session" "in session: left" 2>/dev/null
  "$AGENT_ASK" answer "$deferred" whatever 2>/dev/null
  "$AGENT_ASK" answer "$failed" whatever 2>/dev/null
  run "$AGENT_ASK" judge-report demo
  assert_success
  assert_line --regexp "^$agree	agree	take-recommend	Yes$"
  assert_line --regexp "^$differ	differ	answer:left	right$"
  assert_line --regexp "^$session	unscored	"
  assert_line --regexp "^$deferred	asks-you	human	"
  assert_line --regexp "^$failed	error	error	"
  assert_line 'judged 5 answered asks: the judge would have answered 3, scored 2, agreed 1'
}

# list and the card read each file once; this is what makes Prefix y open fast.
@test "list reads 400 asks well inside a second and keeps each key's first value" {
  local d="$HOME/.agent/asks/demo" i
  mkdir -p "$d"
  for i in $(seq 1 400); do
    printf 'id: q%03d\nproject: demo\nstatus: %s\nkind: question\nquestion: a: b?\ncreated: 2026-11-05T09:00:00+0000\nstatus: answered\n' \
      "$i" "$([ $((i % 4)) = 0 ] && echo pending || echo answered)" > "$d/q$(printf %03d "$i").md"
  done
  local t0 t1
  t0="$(date +%s%N)"
  run "$AGENT_ASK" list demo --pending
  t1="$(date +%s%N)"
  assert_success
  assert_equal "$(printf '%s\n' "$output" | grep -c .)" 100
  # The first `status:` line wins, and a value holding ": " survives whole.
  assert_line --partial $'\tpending\tquestion\ta: b?\t'
  # Budget: the per-field loop this replaced took about 2.5 s here.
  [ $(( (t1 - t0) / 1000000 )) -lt 1000 ]
}

@test "an empty asks dir lists nothing and succeeds" {
  mkdir -p "$HOME/.agent/asks/demo"
  run "$AGENT_ASK" list demo
  assert_success
  assert_output ''
}
