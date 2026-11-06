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
  assert_line --partial 'Judge: would take the recommendation, type not proven - the policy says'
  # No colour off a terminal: the card lands in a session's tool output as plain text.
  ! grep -q $'\e' <<< "$output"
}

@test "card leaves out a session that repeats the project and the kind of a question, and still says the judge deferred" {
  local id; id="$("$AGENT_ASK" post --project demo --session demo --options 'a=the first|b=the second' 'which?')"
  printf 'judge: human\njudge_rule: taste\njudge_reason: only you know\n' >> "$HOME/.agent/asks/demo/$id.md"
  run env COLUMNS=80 "$AGENT_ASK" card "$id"
  assert_success
  assert_line --index 0 --regexp "^asking you  demo \. [0-9]+m ago \. $id\$"
  assert_line 'Judge: deferred (taste) - only you know'
  local g; g="$("$AGENT_ASK" post --project demo --kind gate 'ship it?')"
  run env COLUMNS=80 "$AGENT_ASK" card "$g"
  assert_line --index 0 --partial 'gate - asking you  demo'
}

@test "the card's question block ends with the judge line: not judged, an answer it gave live, an override, an error" {
  local id; id="$(post demo 'which?')"
  run env COLUMNS=200 "$AGENT_ASK" card "$id"
  assert_equal "${lines[-1]}" 'Judge: not judged'
  local f="$HOME/.agent/asks/demo/$id.md"
  # A live answer sets answered_by in place; post wrote it empty, and the first key wins.
  sed -i 's/^answered_by: $/answered_by: judge/' "$f"
  printf 'judge: take-recommend\njudge_rule: ship_deploy\njudge_reason: rules say fix failing CI yourself\n' >> "$f"
  run env COLUMNS=200 "$AGENT_ASK" card "$id"
  assert_equal "${lines[-1]}" 'Judge: answered (ship_deploy) - rules say fix failing CI yourself'
  printf 'judge_override: wrong\n' >> "$f"
  run env COLUMNS=200 "$AGENT_ASK" card "$id"
  assert_line --partial 'Judge: answered, overridden: wrong (ship_deploy)'
  local e; e="$(post demo 'and this?')"
  printf 'judge: error\njudge_reason: the call failed\n' >> "$HOME/.agent/asks/demo/$e.md"
  run env COLUMNS=200 "$AGENT_ASK" card "$e"
  assert_equal "${lines[-1]}" 'Judge: error - the call failed'
}

# An ask the judge called on, its call line in a sandboxed calls.jsonl.
traced_ask() {
  local id; id="$("$AGENT_ASK" post --project demo --session agent-1 'ship it?')"
  printf 'judge: human\njudge_rule: taste\njudge_reason: only you know\njudge_call: c0ffee000001\njudged_at: 2026-11-05T10:00:04Z\n' >> "$HOME/.agent/asks/demo/$id.md"
  export AGENTCTL_CALLS="$BATS_TEST_TMPDIR/calls.jsonl"
  printf '%s\n' '{"id":"c0ffee000000","agent":"other"}' \
    '{"id":"c0ffee000001","agent":"ask-judge","duration_ms":3100,"exit":0,"gen_ai.request.model":"m1","prompt":"judge.md","prompt_sha":"fffabcc1234","session_id":"s-1","gen_ai.usage.input_tokens":2,"gen_ai.usage.output_tokens":76,"cost_usd":0.081,"raw":"VERDICT: human"}' > "$AGENTCTL_CALLS"
  echo "$id"
}

@test "trace shows the timeline, the judge's call and its Langfuse session, and --json the same as one document" {
  local id; id="$(traced_ask)"
  export AGENTCTL_CALLS="$BATS_TEST_TMPDIR/calls.jsonl" AGENT_ASK_LANGFUSE_SESSIONS='https://lf.example/project/p/sessions/'
  run "$AGENT_ASK" answer "$id" no
  run "$AGENT_ASK" trace "$id"
  assert_success
  assert_line "ask $id  demo  answered"
  assert_line 'ship it?'
  assert_line --regexp '^  [0-9-]{5} [0-9:]{8}  posted      by agent-1$'
  assert_line '  11-05 10:00:04  judged      deferred (taste) - only you know'
  assert_line --regexp '^  [0-9-]{5} [0-9:]{8}  answered    no by human$'
  assert_line 'call      c0ffee000001  ask-judge  m1  3.1s  $0.08  2 in / 76 out tokens  prompt fffabcc  exit 0'
  assert_line 'langfuse  https://lf.example/project/p/sessions/s-1'
  assert_line '  VERDICT: human'
  run "$AGENT_ASK" trace "$id" --json
  assert_success
  run jq -r '[.status, .judge, (.events | map(.event) | join(",")), .call.id, .langfuse] | join("|")' <<<"$output"
  assert_output "answered|Judge: deferred (taste) - only you know|posted,judged,answered|c0ffee000001|https://lf.example/project/p/sessions/s-1"
}

@test "trace says when the call line is gone or no Langfuse link is configured, and lists overrides and closes" {
  local id; id="$(traced_ask)"
  export AGENTCTL_CALLS="$BATS_TEST_TMPDIR/calls.jsonl" AGENT_ASK_LANGFUSE_SESSIONS=''
  printf 'judge_override: wrong\njudge_override_note: it was taste\njudge_override_at: 2026-11-05T11:00:00Z\nclosed_at: 2026-11-05T12:00:00Z\nclosed_reason: session ended\n' >> "$HOME/.agent/asks/demo/$id.md"
  run "$AGENT_ASK" trace "$id"
  assert_success
  assert_line '  11-05 11:00:00  overridden  wrong (it was taste)'
  assert_line --regexp '^  11-05 12:00:00  closed      [a-z]+: session ended$'
  assert_line 'session   s-1 (no Langfuse link: SO_LF_URL and SO_LF_PROJECT in session-outcomes.conf)'
  : > "$AGENTCTL_CALLS"
  run "$AGENT_ASK" trace "$id"
  assert_success
  assert_line "call      none (judge_call c0ffee000001 has no line in $AGENTCTL_CALLS)"
  run "$AGENT_ASK" trace nosuch
  assert_failure
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

@test "list emits 25 tab-separated fields per ask, assume_at last" {
  post demo 'ship it?' >/dev/null
  run bash -c '"$AGENT_ASK" list demo | awk -F"\t" "{print NF; exit}"'
  assert_output '25'
  local f; f="$(ls "$HOME"/.agent/asks/demo/*.md | head -1)"
  printf 'assume_at: 2026-11-06T14:30:00-0800\n' >> "$f"
  run bash -c '"$AGENT_ASK" list demo | awk -F"\t" "{print \$25; exit}"'
  assert_output '2026-11-06T14:30:00-0800'
}

@test "the last three fields are judge_rule, judge_reason and answer_note, for agent-web's Details fold" {
  local id; id="$(post demo 'ship it?')"
  printf 'judge: human\njudge_rule: taste\njudge_reason: only you know\nanswer_note: in session\n' >> "$HOME/.agent/asks/demo/$id.md"
  run bash -c '"$AGENT_ASK" list demo | cut -f22-24'
  assert_output "$(printf 'taste\tonly you know\tin session')"
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

# fake_judge <json>: a judge command that prints <json>, as agentctl-run prints a schema reply, and logs its prompt.
# Outside the sandbox dir: its path has a space, and the judge command is a word list.
# score <what> [answer] [reason]: a schema reply whose criteria derive <what>. `not-<id>` takes a
# needed criterion away, a criterion id sets it, and anything else is the ask's type, which an
# answerable verdict names. SCORE_TYPE sets the type beside a criterion.
score() {
  jq -cn --arg c "$1" --arg a "${2:-}" --arg r "${3:-x}" --arg t "${SCORE_TYPE:-ship_deploy}" '
    ["knowledge", "external", "taste", "unclear-ask", "against-precedent", "reversible", "grounded"] as $ids
    | {decision: "d"}
    + ({knowledge: 0, external: 0, taste: 0, "unclear-ask": 0, "against-precedent": 0, reversible: 1, grounded: 1}
       | with_entries(.value = {evidence: (if .value == 1 then "q \(.key)" else "" end), met: (.value == 1)}))
    | if ($c | startswith("not-")) then .[$c[4:]] = {evidence: "q not", met: false}
      elif ($ids | index($c)) then .[$c] = {evidence: "q \($c)", met: true} else . end
    | {type: (if ($ids | index($c)) or ($c | startswith("not-")) then $t else $c end), decisions: [.], reason: $r, answer: $a}'
}

fake_judge() {
  cat > "$BATS_TEST_TMPDIR/judge" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/judge.calls"
printf '%s\n' "\$AGENTCTL_CALL_ID" > "$BATS_TEST_TMPDIR/judge.id"
printf '%s\n' '$1'
SH
  chmod +x "$BATS_TEST_TMPDIR/judge"
  export AGENT_ASK_JUDGE_CMD="$BATS_TEST_TMPDIR/judge"
}

@test "judge records its call and reason, and leaves the ask pending" {
  fake_judge "$(score ship_deploy "" "landing is standing authorization")"
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'open the PR?')"
  run "$AGENT_ASK" judge "$id"
  assert_success
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: take-recommend'
  assert_line 'judge_reason: landing is standing authorization'
  assert_line 'judge_rule: ship_deploy'
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

@test "judge turns a call the ask cannot carry out into human" {
  fake_judge "$(score engineering_design)"
  local id; id="$(post demo 'no recommendation here?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: human'
}

@test "judge scores a pending ask again and replaces its old verdict, but leaves an answered one" {
  fake_judge "$(score knowledge "" "only you know")"
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'open the PR?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"; assert_line 'judge: human'; assert_line 'judge_rule: knowledge'
  fake_judge "$(score ship_deploy "" "landing is standing authorization")"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: take-recommend'
  assert_line 'judge_rule: ship_deploy'
  assert_line 'judge_reason: landing is standing authorization'
  assert_equal "$(grep -c '^judge_rule: ' "$HOME/.agent/asks/demo/$id.md")" 1
  # negative control: an answered ask keeps the verdict it is scored on, and no call is made
  "$AGENT_ASK" answer "$id" no 2>/dev/null
  rm -f "$BATS_TEST_TMPDIR/judge.calls"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  assert [ ! -e "$BATS_TEST_TMPDIR/judge.calls" ]
  run "$AGENT_ASK" show "$id"; assert_line 'judge: take-recommend'
}

@test "sweep judges the pending queue again, answers live classes as the judge and leaves the rest" {
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  local live shadow gate done
  live="$("$AGENT_ASK" post --project demo --options 'fix=fix it|wait=wait' --recommend fix 'fix the flake?')"
  shadow="$("$AGENT_ASK" post --project other --options 'a=one|b=two' --recommend a 'which mic?')"
  gate="$("$AGENT_ASK" post --project demo --kind gate 'merge #9?')"
  done="$("$AGENT_ASK" post --project demo --options 'x=x|y=y' --recommend x 'old?')"
  "$AGENT_ASK" answer "$done" y 2>/dev/null
  # the stale verdict an older policy left on the live one
  printf 'judge: human\njudge_reason: options are unlabeled\n' >> "$HOME/.agent/asks/demo/$live.md"
  cat > "$BATS_TEST_TMPDIR/judge" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/judge.calls"
case "\$*" in
  *'fix the flake?'*) printf '%s\n' '$(score ship_deploy "" "rules say fix failing CI yourself.")' ;;
  *) printf '%s\n' '$(score knowledge "" "only you can test the mic")' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/judge"
  export AGENT_ASK_JUDGE_CMD="$BATS_TEST_TMPDIR/judge"
  run "$AGENT_ASK" sweep --all
  assert_success
  assert_line "demo	$live	answered fix	ship_deploy	rules say fix failing CI yourself."
  assert_line "other	$shadow	yours	knowledge	only you can test the mic"
  assert_line --regexp "^demo	$gate	yours	gate	"
  refute_output --partial "$done"
  run "$AGENT_ASK" show "$live"
  assert_line 'status: answered'; assert_line 'answer: fix'; assert_line 'answered_by: judge'
  refute_line 'judge_reason: options are unlabeled'
  run "$AGENT_ASK" show "$shadow"; assert_line 'status: pending'
  run "$AGENT_ASK" show "$gate"; assert_line 'status: pending'
  # an ask with no live session and no resume is filed as a row, saying the judge answered
  assert_called "notes ptask"
  assert_equal "$("$AGENT_ASK" count --all)" 2
}

@test "a judge answer typed into a live session names the judge, its rule and its reason" {
  unset AGENT_ASK_NO_RESUME
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  printf '{"session_id":"sid-7","pane":"%%7","status":"idle"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  local id; id="$(CLAUDE_CODE_SESSION_ID=sid-7 "$AGENT_ASK" post --project demo --options 'fix=fix it|wait=wait' --recommend fix 'fix it here?')"
  fake_judge "$(score ship_deploy "" "rules say fix failing CI yourself.")"
  "$AGENT_ASK" sweep demo >/dev/null
  assert_called "agent-panel send --pane %7 Answer to ask $id: fix (the judge, ship_deploy: rules say fix failing CI yourself; the human can override in this session)"
  # negative control: a human answer keeps the plain text
  id="$(CLAUDE_CODE_SESSION_ID=sid-7 "$AGENT_ASK" post --project demo --options 'a=a|b=b' 'pick?')"
  "$AGENT_ASK" answer "$id" b 2>/dev/null
  assert_called "agent-panel send --pane %7 Answer to ask $id: b"
}

@test "judge records a free answer, and a reply with no verdict is an error verdict" {
  fake_judge "$(score engineering_design "the simpler one" "no product effect")"
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
  assert_line 'judge_reason: the reply had no verdict: not json'
  assert_line --regexp '^judge_call: [0-9a-f]{12}$'
}

@test "judge: prose around a verdict is an error (negative control)" {
  fake_judge 'thinking...
ASK-JUDGE-START
{"call":"human","rule":"taste","answer":"","reason":"x"}
ASK-JUDGE-END'
  id="$(AGENT_ASK_NO_JUDGE=1 post demo 'wrapped?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: error'
}

@test "judge: a partial score and a failed call are error verdicts with their reason" {
  fake_judge "$(score engineering_design | jq -c 'del(.decisions[0].knowledge)')"
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'open the PR?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: error'
  assert_line --partial 'judge_reason: the reply had no verdict'
  refute_line --partial 'judge_rule:'
  # no decisions is no score, never clear
  fake_judge '{"decisions":[],"reason":"x","answer":""}'
  id="$(post demo 'empty?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: error'
  # a call that fails says how, from its stderr
  printf '#!/usr/bin/env bash\necho "rate limited" >&2; exit 7\n' > "$BATS_TEST_TMPDIR/judge"
  id="$(post demo 'again?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: error'
  assert_line 'judge_reason: call failed (exit 7): rate limited'
}

@test "judge derives the call from the score" {
  check() {
    fake_judge "$(score "$1")"
    local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes "case $1?")"
    "$AGENT_ASK" judge "$id"
    run "$AGENT_ASK" show "$id"
    assert_line "judge: $2"
    assert_line "judge_rule: $3"
  }
  check knowledge human knowledge
  check external human external
  check taste human taste
  check unclear-ask human unclear-ask
  check not-reversible human reversible
  check not-grounded take-recommend ship_deploy
  check against-precedent human against-precedent
  check ship_deploy take-recommend ship_deploy
  check other take-recommend other
}

@test "judge: every human criterion beats the type, however safe the type looks" {
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  unset AGENT_ASK_NO_JUDGE
  fake_judge "$(SCORE_TYPE=ship_deploy score external)"
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'ship it?' 2>/dev/null)"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  assert_line 'judge_rule: external'
  assert_line 'judge_type: ship_deploy'
  assert_line 'judge_evidence: q external'
  # negative control: the same score with external clear is answered
  fake_judge "$(score ship_deploy)"
  id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'land it?' 2>/dev/null)"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: answered'
  assert_line 'judge_evidence: q grounded'
}

@test "judge: grounded is noted, never a stop: a live type answers, a shadow type only says so" {
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  unset AGENT_ASK_NO_JUDGE
  fake_judge "$(SCORE_TYPE=ship_deploy score not-grounded)"
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'ship it?' 2>/dev/null)"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: answered'
  assert_line 'answered_by: judge'
  assert_line 'judge_met: reversible'
  # negative control: the same score on a type that is not live stays with the human
  fake_judge "$(SCORE_TYPE=ci_capacity_ops score not-grounded)"
  id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'quarantine it?' 2>/dev/null)"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  assert_line 'judge_rule: ci_capacity_ops'
}

@test "judge: other is never live, even when DELAY_RULES names it" {
  export AGENT_ASK_DELAY_RULES='other=0 ship_deploy=0'
  unset AGENT_ASK_NO_JUDGE
  fake_judge "$(score other)"
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'no type fits?' 2>/dev/null)"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  assert_line 'judge: take-recommend'
  assert_line 'judge_rule: other'
  # negative control: the type beside it in the same list answers
  fake_judge "$(score ship_deploy)"
  id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'land it?' 2>/dev/null)"
  run "$AGENT_ASK" show "$id"; assert_line 'status: answered'
}

@test "judge: an answerable type that is not live says so on the card" {
  fake_judge "$(score ship_deploy "" "landing is standing")"
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'land it?')"
  "$AGENT_ASK" judge "$id"
  run env COLUMNS=200 "$AGENT_ASK" card "$id"
  assert_equal "${lines[-1]}" 'Judge: would take the recommendation, type not proven (ship_deploy) - landing is standing'
}

@test "judge: a reply with no type is no verdict" {
  fake_judge "$(score ship_deploy | jq -c 'del(.type)')"
  local id; id="$(post demo 'which?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"; assert_line 'judge: error'
}

@test "judge: a bundle scores its worst item" {
  bundle() { jq -cs '{type: .[0].type, decisions: map(.decisions[0]), reason: "x", answer: ""}' <(score engineering_design) <(score "$1"); }
  check() {
    fake_judge "$(bundle "$1")"
    local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes "bundle $1?")"
    "$AGENT_ASK" judge "$id"
    run "$AGENT_ASK" show "$id"
    assert_line "judge: $2"
    assert_line "judge_rule: $3"
  }
  check external human external
  check not-reversible human reversible
  # the type is the whole ask's, so an answerable bundle names it
  check ship_deploy take-recommend engineering_design
}

@test "judge: its own answer wins over the recommendation, and judge_met lists what held" {
  fake_judge "$(score engineering_design no)"
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' --recommend yes 'which?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: answer:no'
  assert_line 'judge_met: reversible grounded'
}

@test "judge: the policy, the schema and judge_derive name the same criteria and types" {
  . "$REPO_ROOT/.local/lib/judge.sh"
  local policy schema derive="$REPO_ROOT/.local/lib/judge.sh" file="$REPO_ROOT/.config/agent-ask/policy.md"
  local verdict="$REPO_ROOT/.config/agent-ask/verdict.schema.json"
  policy=$(judge_rules "$file" | grep -vx gate | sort)
  schema=$(jq -r '.properties.decisions.items.properties | keys[] | select(. != "decision")' "$verdict" | sort)
  assert_equal "$policy" "$schema"
  assert_equal "$(printf '%s\n' $JUDGE_HUMAN_CRITERIA $JUDGE_NEEDED_CRITERIA grounded | sort)" "$schema"
  types() { sed -n 's/^- `\([a-z_]*\)`: .*/\1/p' "$1" | sort; }
  assert_equal "$(types "$file")" "$(jq -r '.properties.type.enum[]' "$verdict" | sort)"
  assert [ "$(types "$file" | wc -l)" -ge 13 ]
  # negative control: a type dropped from the policy no longer matches the schema
  sed '/^- `ship_deploy`/d' "$file" > "$BATS_TEST_TMPDIR/policy.md"
  refute [ "$(types "$BATS_TEST_TMPDIR/policy.md")" = "$(jq -r '.properties.type.enum[]' "$verdict" | sort)" ]
}

@test "judge: every policy rule id is a hard stop, so no DELAY_RULES row can name one" {
  . "$REPO_ROOT/.local/lib/judge.sh"
  local id; for id in $(judge_rules "$REPO_ROOT/.config/agent-ask/policy.md"); do
    [[ " $JUDGE_HARD_STOPS " == *" $id "* ]] || fail "$id is not in JUDGE_HARD_STOPS"
  done
  local t; for t in product_taste human_fact human_physical_action credential_or_account other; do
    [[ " $JUDGE_HARD_STOPS " == *" $t "* ]] || fail "$t is not in JUDGE_HARD_STOPS"
  done
}

@test "judge: a gate names the gate rule and no call" {
  local id; id="$("$AGENT_ASK" post --project demo --kind gate 'merge #2?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge_rule: gate'
  refute_line --partial 'judge_call:'
}

@test "post runs the judge before it returns, unless AGENT_ASK_NO_JUDGE is set" {
  fake_judge "$(score taste "" taste)"
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
  fake_judge "$(score ship_deploy "" "rules say fix failing CI yourself.")"
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  run --separate-stderr live_post sid-1 'fix the flaky test here?'
  assert_success
  local id="$output"
  assert_regex "$id" '^[A-Za-z0-9]{6}$'
  assert_equal "$stderr" "Answered by the judge (ship_deploy): fix - rules say fix failing CI yourself. Proceed; the human can override in this session."
  run "$AGENT_ASK" show "$id"
  assert_line 'status: answered'
  assert_line 'answer: fix'
  assert_line 'answered_by: judge'
  assert_line "judge_call: $(cat "$BATS_TEST_TMPDIR/judge.id")"
  assert_equal "$("$AGENT_ASK" count demo)" 0
}

@test "live answers: a shadow rule, an empty DELAY_RULES, a gate and a human call all stay with the human" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  fake_judge "$(score engineering_design)"
  local id; id="$(live_post sid-a 'shadow rule?')"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'; assert_line 'judge: take-recommend'
  export AGENT_ASK_DELAY_RULES=
  fake_judge "$(score ship_deploy)"
  id="$(live_post sid-b 'nothing live?')"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  id="$("$AGENT_ASK" post --project demo --kind gate 'merge #4?')"
  assert [ "$(grep -c 'merge #4' "$BATS_TEST_TMPDIR/judge.calls")" = 0 ]
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  fake_judge "$(score knowledge)"
  id="$(live_post sid-c 'human call?')"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  # A demoted rule is out of the live set even while the conf lists it.
  fake_judge "$(score ship_deploy)"
  mkdir -p "$(dirname "$HOME/.local/state/agent-ask/demoted")"
  printf 'ship_deploy\t2026-11-05T00:00:00+0000\tx\n' > "$HOME/.local/state/agent-ask/demoted"
  id="$(live_post sid-d 'demoted?')"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  # negative control: the same verdict with the demote gone is answered
  rm "$HOME/.local/state/agent-ask/demoted"
  id="$(live_post sid-e 'live again?')"
  run "$AGENT_ASK" show "$id"; assert_line 'answered_by: judge'
}

@test "live answers: malformed output is an error verdict, and a stuck call times out to one; both stay pending" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
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

@test "override: the human's next message naming another option labels the live answer; one miss does not demote" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  fake_judge "$(score ship_deploy)"
  local id; id="$(live_post sid-1 'fix it here?' 2>/dev/null)"
  "$AGENT_ASK" settle-session sid-1 answered "no, wait for the row to be fixed"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge_override: wait'
  assert_line 'judge_override_note: in session: no, wait for the row to be fixed'
  assert_line 'answer: fix'
  # 1 live answer is under AGENT_ASK_DEMOTE_MIN: the type stays live and the next one is answered
  assert [ ! -e "$HOME/.local/state/agent-ask/demoted" ]
  assert_not_called 'agent-notify'
  id="$(live_post sid-2 'and this one?' 2>/dev/null)"
  run "$AGENT_ASK" show "$id"; assert_line 'answered_by: judge'
}

@test "override: a message that agrees or says nothing about the options closes the review with none" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  fake_judge "$(score ship_deploy)"
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

# live_answer_file <n> <minute> <override>: a reviewed live ship_deploy answer on disk.
live_answer_file() {
  mkdir -p "$HOME/.agent/asks/demo"
  printf 'id: L%05d\nproject: demo\nstatus: answered\noptions: fix|wait\nanswer: fix\nanswered_by: judge\nanswered_at: 2026-11-05T09:%02d:00+0000\njudge_rule: ship_deploy\njudge_override: %s\n' \
    "$1" "$2" "$3" > "$HOME/.agent/asks/demo/L$(printf %05d "$1").md"
}

@test "override: a type demotes when precision over its last live answers falls under the bar, once it has the minimum" {
  export AGENT_ASK_DELAY_RULES=ship_deploy=0 AGENT_ASK_LIVE_BAR=5 AGENT_ASK_DEMOTE_MIN=3 AGENT_ASK_DEMOTE_PRECISION=85
  local d="$HOME/.agent/asks/demo" i
  # An old override outside the window of 5, then four good answers.
  live_answer_file 1 1 wait
  for i in 2 3 4 5; do live_answer_file "$i" "$i" none; done
  # The sixth is overridden: the window is answers 2-6, 4 of 5 is 80%, under 85.
  printf 'id: L00006\nproject: demo\nclaude_session: sid-9\nstatus: answered\noptions: fix|wait\nanswer: fix\nanswered_by: judge\nanswered_at: 2026-11-05T09:06:00+0000\njudge_rule: ship_deploy\n' > "$d/L00006.md"
  "$AGENT_ASK" settle-session sid-9 answered "wait"
  run cat "$HOME/.local/state/agent-ask/demoted"
  assert_output --regexp "^ship_deploy	.+	override on ask L00006: 1 of its last 5 live answers overridden, under 85%$"
  assert_called 'agent-notify -p high -t Judge demoted'
  assert_called 'notes ptask agent-runtime --agent add check(judge): ask-judge ship_deploy went back to shadow'
  # negative control: at a 75% bar the same override keeps the type live
  rm "$HOME/.local/state/agent-ask/demoted"
  sed -i '/^judge_override/d' "$d/L00006.md"
  export AGENT_ASK_DEMOTE_PRECISION=75
  "$AGENT_ASK" settle-session sid-9 answered "wait"
  run "$AGENT_ASK" show L00006; assert_line 'judge_override: wait'
  assert [ ! -e "$HOME/.local/state/agent-ask/demoted" ]
  # under the minimum nothing demotes, even at 0%: the window counts only these two
  rm "$d"/L0000[1-4].md
  sed -i '/^judge_override/d' "$d/L00006.md"
  export AGENT_ASK_DEMOTE_PRECISION=85
  "$AGENT_ASK" settle-session sid-9 answered "wait"
  assert [ ! -e "$HOME/.local/state/agent-ask/demoted" ]
}

@test "precedents: a disagreement older than the ask reaches the judge, a newer one and an agreement do not" {
  local d="$HOME/.agent/asks/demo"
  mkdir -p "$d"
  old() { printf 'id: %s\nproject: demo\nkind: question\nstatus: answered\nquestion: %s\noptions: fix|wait\noption_notes: fix it now|leave it\nrecommend: fix\nanswer: %s\nanswered_at: %s\nanswered_by: %s\n%s' "$1" "$2" "$3" "$4" "${5:-human}" "${6:-}" > "$d/$1.md"; }
  old P1 'quarantine the flake?' wait 2026-11-01T10:00:00-0800
  old P2 'same but agreed?' fix 2026-11-01T11:00:00-0800
  old P3 'same but free text?' 'wait, and tell me why' 2026-11-01T12:00:00-0800
  old P4 'overridden live?' fix 2026-11-01T13:00:00-0800 judge $'judge_override: wait\njudge_override_at: 2026-11-02T09:00:00-0800\n'
  old P5 'reviewed live?' fix 2026-11-01T14:00:00-0800 judge $'judge_override: none\n'
  old P6 'typed in the session?' 'in session: no, wait for it' 2026-11-01T15:00:00-0800
  old N1 'decided later?' wait 2026-11-03T10:00:00-0800
  run "$AGENT_ASK" precedents 2026-11-02T18:00:00+0000
  assert_success
  assert_equal "${lines[0]}" 'P4 (demo): overridden live? | recommended: fix (fix it now) | the human chose: wait (leave it)'
  assert_equal "${lines[1]}" 'P6 (demo): typed in the session? | recommended: fix (fix it now) | the human chose: wait (leave it)'
  assert_equal "${lines[2]}" 'P1 (demo): quarantine the flake? | recommended: fix (fix it now) | the human chose: wait (leave it)'
  assert_equal "${#lines[@]}" 3
  # an offset is read, not compared as text: 16:59 UTC is before P4's override at 17:00 UTC
  run "$AGENT_ASK" precedents 2026-11-02T16:59:00+0000
  refute_output --partial 'P4'
  # the cap keeps the newest
  AGENT_ASK_PRECEDENTS=1 run "$AGENT_ASK" precedents 2026-11-02T18:00:00+0000
  assert_output --partial 'P4'
  assert_equal "${#lines[@]}" 1
  # in the judge's input, by the ask's own created time
  fake_judge "$(score knowledge)"
  local id; id="$(post demo 'quarantine this flake?')"
  sed -i 's/^created: .*/created: 2026-11-02T10:00:00-0800/' "$d/$id.md"
  "$AGENT_ASK" judge "$id"
  run cat "$BATS_TEST_TMPDIR/judge.calls"
  assert_output --partial '## Past disagreements'
  assert_output --partial 'P1 (demo): quarantine the flake?'
  refute_output --partial 'decided later?'
  # negative control: no earlier disagreement, no section
  rm "$BATS_TEST_TMPDIR/judge.calls"
  id="$(post demo 'first of its kind?')"
  sed -i 's/^created: .*/created: 2026-10-01T10:00:00-0800/' "$d/$id.md"
  "$AGENT_ASK" judge "$id"
  run cat "$BATS_TEST_TMPDIR/judge.calls"
  refute_output --partial '## Past disagreements'
}

@test "precedents: AGENT_ASK_PRECEDENTS_ROOT replaces the store they are read from" {
  local r="$BATS_TEST_TMPDIR/real/demo"
  mkdir -p "$r"
  printf 'id: R1\nproject: demo\nstatus: answered\nquestion: elsewhere?\noptions: fix|wait\nrecommend: fix\nanswer: wait\nanswered_at: 2026-11-01T10:00:00-0800\n' > "$r/R1.md"
  run "$AGENT_ASK" precedents 2026-11-02T10:00:00-0800
  assert_output ''
  AGENT_ASK_PRECEDENTS_ROOT="$BATS_TEST_TMPDIR/real" run "$AGENT_ASK" precedents 2026-11-02T10:00:00-0800
  assert_output 'R1 (demo): elsewhere? | recommended: fix | the human chose: wait'
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

# ── assume on delay: a DELAY_RULES wait arms an ask, assume-due fires it ────────

# armed <sid> <question>: a ship_deploy ask armed at post with a 30 minute wait. Prints its id.
armed() { live_post "$@" 2>/dev/null; }
# due <id>: its wait has passed.
due() { sed -i 's/^assume_at: .*/assume_at: 2026-01-01T00:00:00+0000/' "$(ask_file "$1")"; }

delay_setup() {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=30
  fake_judge "$(score ship_deploy "" "rules say fix failing CI yourself.")"
}

@test "delay: a wait arms the ask at post: it stays pending, and the card names the answer and deadline" {
  delay_setup
  run --separate-stderr armed sid-1 'fix the flake?'
  assert_success
  local id="$output"
  refute [ -n "$stderr" ]
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  assert_line 'assume_answer: fix'
  assert_line --regexp '^assume_at: 20[0-9-]+T[0-9:]+[-+][0-9]{4}$'
  run "$AGENT_ASK" card "$id"
  assert_output --regexp 'assumes "fix" at [0-9]{2}:[0-9]{2} unless you reply'
  run bash -c '"$AGENT_ASK" list demo | awk -F"\t" "{print \$25}"'
  assert_output --regexp '^20'
  # negative control: at 0 the same verdict answers at post
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  id="$(armed sid-2 'fix that flake?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'answered_by: judge'
  refute_line --partial 'assume_at:'
}

@test "delay: assume-due fires a due ask once as the judge, and leaves one not yet due" {
  delay_setup
  local a b; a="$(armed sid-1 'fix the flake?')"; b="$(armed sid-2 'fix the other?')"
  due "$a"
  run "$AGENT_ASK" assume-due
  assert_success
  run "$AGENT_ASK" show "$a"
  assert_line 'status: answered'; assert_line 'answer: fix'; assert_line 'answered_by: judge'
  assert_line 'assume_at: 2026-01-01T00:00:00+0000'
  run "$AGENT_ASK" show "$b"; assert_line 'status: pending'; assert_line 'assume_answer: fix'
  assert_equal "$(grep -c 'answered: fix (the judge; to override: agent-ask answer' "$NOTES_FIXTURE/calls.log")" 1
  # a second pass changes nothing and files nothing
  local at; at="$(grep '^answered_at: ' "$HOME/.agent/asks/demo/$a.md")"
  "$AGENT_ASK" assume-due
  assert_equal "$(grep '^answered_at: ' "$HOME/.agent/asks/demo/$a.md")" "$at"
  assert_equal "$(grep -c 'answered: fix (the judge; to override: agent-ask answer' "$NOTES_FIXTURE/calls.log")" 1
}

@test "delay: assume-due answers nothing whose verdict or rule moved inside the window" {
  delay_setup
  local d="$HOME/.agent/asks/demo" id
  # check <how>: an armed, due ask broken by <how> stays with the human and loses its arm.
  check() {
    id="$(armed "sid-$1" "case $1?")"; due "$id"
    "$2" "$d/$id.md"
    run --separate-stderr "$AGENT_ASK" assume-due
    assert_success
    run "$AGENT_ASK" show "$id"
    assert_line 'status: pending'
    refute_line --partial 'assume_at:'
    assert [ -n "$stderr" ]
  }
  errored() { sed -i 's/^judge: .*/judge: error/' "$1"; }
  empty() { sed -i 's/^judge: .*/judge: /' "$1"; }
  gate() { sed -i 's/^kind: .*/kind: gate/' "$1"; }
  approval() { sed -i 's/^kind: .*/kind: approval/' "$1"; }
  disarmed() { printf 'assume_disarmed: 2026-11-06T10:00:00-0800\n' >> "$1"; }
  rerecommended() { sed -i 's/^recommend: .*/recommend: wait/' "$1"; }
  check errored errored
  check empty empty
  check gate gate
  check approval approval
  check disarmed disarmed
  check rerecommended rerecommended
  # a demoted type, a removed row, a hard stop in the table and malformed rows
  mkdir -p "$HOME/.local/state/agent-ask"
  demote() { printf 'ship_deploy\t2026-11-05T00:00:00+0000\tx\n' > "$HOME/.local/state/agent-ask/demoted"; }
  check demoted demote
  rm "$HOME/.local/state/agent-ask/demoted"
  id="$(armed sid-rr 'removed row?')"; due "$id"
  AGENT_ASK_DELAY_RULES=engineering_design=30 "$AGENT_ASK" assume-due 2>/dev/null
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'; refute_line --partial 'assume_at:'
  local rows; for rows in 'ship_deploy=soon' 'ship_deploy' 'ship_deploy=-5'; do
    id="$(armed "sid-$rows" "malformed $rows?")"; due "$id"
    run --separate-stderr env AGENT_ASK_DELAY_RULES="$rows" "$AGENT_ASK" assume-due
    assert_regex "$stderr" "refuses '$rows'"
    run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  done
  id="$(armed sid-hs 'hard stop?')"; due "$id"
  sed -i 's/^judge_rule: .*/judge_rule: product_taste/' "$d/$id.md"
  run --separate-stderr env AGENT_ASK_DELAY_RULES='product_taste=0' "$AGENT_ASK" assume-due
  assert_regex "$stderr" 'refuses product_taste'
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  # positive control: an untouched due ask under the same table fires
  id="$(armed sid-u 'untouched?')"; due "$id"
  "$AGENT_ASK" assume-due
  run "$AGENT_ASK" show "$id"; assert_line 'answered_by: judge'
}

@test "delay: a hard stop or a malformed row in DELAY_RULES never makes a type live at post" {
  unset AGENT_ASK_NO_JUDGE
  local rows; for rows in 'gate=0' 'reversible=0' 'credential_or_account=0' 'ship_deploy' 'ship_deploy=soon'; do
    case "$rows" in ship_deploy*) fake_judge "$(score ship_deploy)" ;; *) fake_judge "$(score "${rows%%=*}")" ;; esac
    run --separate-stderr env AGENT_ASK_DELAY_RULES="$rows" CLAUDE_CODE_SESSION_ID="sid-$rows" "$AGENT_ASK" post \
      --project demo --options 'yes=do it|no=leave it' --recommend yes "row $rows?"
    assert_success
    assert_regex "$stderr" 'refuses'
    run "$AGENT_ASK" show "${output##*$'\n'}"
    assert_line 'status: pending'
    refute_line --partial 'assume_at:'
  done
}

@test "delay: a human answer during the judge's call stands; the judge writes nothing over it" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  # The judge's call is where the human answers: it finds the ask by its question and answers it.
  cat > "$BATS_TEST_TMPDIR/judge" <<SH
#!/usr/bin/env bash
grep -l '^question: race' "$HOME"/.agent/asks/demo/*.md | while IFS= read -r f; do
  grep -qx 'status: pending' "\$f" && "$AGENT_ASK" answer "\$(sed -n 's/^id: //p' "\$f")" wait >/dev/null 2>&1
done
printf '%s\n' '$(score ship_deploy)'
SH
  chmod +x "$BATS_TEST_TMPDIR/judge"
  export AGENT_ASK_JUDGE_CMD="$BATS_TEST_TMPDIR/judge"
  run --separate-stderr armed sid-r 'race at post?'
  local id="$output"
  refute_regex "$stderr" 'Answered by the judge'
  run "$AGENT_ASK" show "$id"
  assert_line 'answer: wait'; assert_line 'answered_by: human'
  assert_equal "$(grep -c '^status: ' "$HOME/.agent/asks/demo/$id.md")" 1
  # the same race in a sweep
  export AGENT_ASK_NO_JUDGE=1
  id="$(armed sid-r 'race in a sweep?')"
  unset AGENT_ASK_NO_JUDGE
  run "$AGENT_ASK" sweep demo
  assert_line --regexp "^demo	$id	yours	"
  run "$AGENT_ASK" show "$id"
  assert_line 'answer: wait'; assert_line 'answered_by: human'
}

@test "delay: a session in a dialog keeps its armed ask until the dialog closes" {
  delay_setup
  unset AGENT_ASK_NO_RESUME
  printf '{"session_id":"sid-w","pane":"%%9","status":"waiting"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  local id; id="$(armed sid-w 'fix it in the dialog?')"; due "$id"
  "$AGENT_ASK" assume-due
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'; assert_line 'assume_at: 2026-01-01T00:00:00+0000'
  assert_not_called "agent-panel send --pane %9"
  # negative control: once idle, the next pass fires it into the session
  printf '{"session_id":"sid-w","pane":"%%9","status":"idle"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  "$AGENT_ASK" assume-due
  run "$AGENT_ASK" show "$id"; assert_line 'answered_by: judge'
  assert_called "agent-panel send --pane %9 Answer to ask $id: fix (the judge, ship_deploy"
}

@test "delay: recommend drops the arm, and sweep arms again keeping the clock on the same answer" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=30
  fake_judge "$(score ship_deploy fix)"
  local id f; id="$(armed sid-1 'fix or wait?')"; f="$HOME/.agent/asks/demo/$id.md"
  run "$AGENT_ASK" show "$id"; assert_line 'judge: answer:fix'; assert_line 'assume_answer: fix'
  "$AGENT_ASK" recommend "$id" wait 2>/dev/null
  run "$AGENT_ASK" show "$id"; refute_line --partial 'assume_'
  # a hand-run sweep arms it again; the same answer on the next sweep keeps the clock
  run "$AGENT_ASK" sweep demo
  assert_line --regexp "^demo	$id	armed fix	ship_deploy	"
  sed -i 's/^assume_at: .*/assume_at: 2030-01-01T00:00:00+0000/' "$f"
  "$AGENT_ASK" sweep demo >/dev/null
  run "$AGENT_ASK" show "$id"; assert_line 'assume_at: 2030-01-01T00:00:00+0000'
  # a different answer starts a full window
  fake_judge "$(score ship_deploy wait)"
  "$AGENT_ASK" sweep demo >/dev/null
  run "$AGENT_ASK" show "$id"
  assert_line 'assume_answer: wait'
  refute_line 'assume_at: 2030-01-01T00:00:00+0000'
}

@test "delay override: in the window, another option is an override and the human's answer records" {
  delay_setup
  local a b; a="$(armed sid-1 'fix the flake?')"; b="$(armed sid-2 'fix this flake?')"
  "$AGENT_ASK" settle-session sid-1 answered "no, wait for the row"
  run "$AGENT_ASK" show "$a"
  assert_line 'judge_override: wait'
  assert_line 'judge_override_note: in session: no, wait for the row'
  assert_line --regexp '^judge_override_at: .+'
  assert_line 'answer: wait'; assert_line 'answered_by: human'
  # the same option agrees
  "$AGENT_ASK" settle-session sid-2 answered "yes fix it"
  run "$AGENT_ASK" show "$b"
  assert_line 'judge_override: none'; assert_line 'answer: fix'; assert_line 'answered_by: human'
  # neither fires later
  due "$a"; due "$b"
  "$AGENT_ASK" assume-due
  run "$AGENT_ASK" show "$a"; assert_line 'answered_by: human'
}

@test "delay override: a message naming no option disarms for good, and a later pick still counts" {
  delay_setup
  local id f; id="$(armed sid-1 'fix the flake?')"; f="$HOME/.agent/asks/demo/$id.md"
  "$AGENT_ASK" settle-session sid-1 answered "what is going on here?"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  assert_line --regexp '^assume_disarmed: .+'
  assert_line 'assume_answer: fix'
  refute_line --partial 'assume_at:'
  # neither assume-due nor a sweep answers or arms it again
  "$AGENT_ASK" assume-due
  run "$AGENT_ASK" sweep demo
  assert_line --regexp "^demo	$id	yours	"
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'; refute_line --partial 'assume_at:'
  # nor does a type at 0
  AGENT_ASK_DELAY_RULES=ship_deploy=0 "$AGENT_ASK" sweep demo >/dev/null
  run "$AGENT_ASK" show "$id"; assert_line 'status: pending'
  "$AGENT_ASK" settle-session sid-1 answered "wait"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge_override: wait'; assert_line 'answer: wait'
}

@test "delay override: after it fires, a later session pick still overrides, past an unrelated first message" {
  delay_setup
  local id; id="$(armed sid-1 'fix the flake?')"; due "$id"
  "$AGENT_ASK" assume-due
  "$AGENT_ASK" settle-session sid-1 answered "ok how many phases left?"
  run "$AGENT_ASK" show "$id"; assert_line 'judge_override: none'
  "$AGENT_ASK" settle-session sid-1 answered "wait, park it"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge_override: wait'
  assert_line 'answer: fix'; assert_line 'answered_by: judge'
  # one override closes it
  "$AGENT_ASK" settle-session sid-1 answered "fix"
  run "$AGENT_ASK" show "$id"; assert_line 'judge_override: wait'
}

@test "delay override: a board answer on a fired ask stamps the override and keeps the judge's answer" {
  delay_setup
  local a b; a="$(armed sid-1 'fix the flake?')"; b="$(armed sid-2 'fix this flake?')"
  due "$a"; due "$b"
  "$AGENT_ASK" assume-due
  "$AGENT_ASK" answer "$a" wait 2>/dev/null
  run "$AGENT_ASK" show "$a"
  assert_line 'judge_override: wait'; assert_line 'judge_override_note: from a board: wait'
  assert_line 'answer: fix'; assert_line 'answered_by: judge'
  assert_called "answered: wait (ask $a)"
  # the same option changes nothing
  "$AGENT_ASK" answer "$b" fix 2>/dev/null
  run "$AGENT_ASK" show "$b"
  refute_line --partial 'judge_override'; assert_line 'answered_by: judge'
  # a board answer on a pending armed ask records the human's and the override
  local c; c="$(armed sid-3 'fix one more?')"
  "$AGENT_ASK" answer "$c" wait 2>/dev/null
  run "$AGENT_ASK" show "$c"
  assert_line 'judge_override: wait'; assert_line 'answered_by: human'; assert_line 'answer: wait'
}

@test "override: a nested option names one option, not two" {
  unset AGENT_ASK_NO_JUDGE
  export AGENT_ASK_DELAY_RULES=ship_deploy=0
  fake_judge "$(score ship_deploy)"
  local id; id="$(CLAUDE_CODE_SESSION_ID=sid-n "$AGENT_ASK" post --project demo \
    --options 'approve=ship it|approve-with-edits=ship with edits|redo=start over' --recommend approve 'ship?' 2>/dev/null)"
  "$AGENT_ASK" settle-session sid-n answered "approve-with-edits please"
  run "$AGENT_ASK" show "$id"; assert_line 'judge_override: approve-with-edits'
  # negative control: two separate options named is no pick
  id="$(CLAUDE_CODE_SESSION_ID=sid-m "$AGENT_ASK" post --project demo \
    --options 'approve=ship it|approve-with-edits=ship with edits|redo=start over' --recommend approve 'ship again?' 2>/dev/null)"
  "$AGENT_ASK" settle-session sid-m answered "redo or approve-with-edits"
  run "$AGENT_ASK" show "$id"; assert_line 'judge_override: none'
}

@test "delay: demote counts in-window answers, agreeing or not, and precedents read an in-window override" {
  delay_setup
  export AGENT_ASK_LIVE_BAR=5 AGENT_ASK_DEMOTE_MIN=2 AGENT_ASK_DEMOTE_PRECISION=85
  local a b; a="$(armed sid-1 'fix the flake?')"; b="$(armed sid-2 'fix this flake?')"
  "$AGENT_ASK" settle-session sid-1 answered "fix"
  assert [ ! -e "$HOME/.local/state/agent-ask/demoted" ]
  "$AGENT_ASK" settle-session sid-2 answered "wait"
  # 1 of 2 overridden, under 85%: without the agreeing one the window would be under the minimum
  run cat "$HOME/.local/state/agent-ask/demoted"
  assert_output --regexp "^ship_deploy	.+	override on ask $b: 1 of its last 2 live answers overridden"
  run "$AGENT_ASK" precedents 2030-01-01T00:00:00+0000
  assert_output --partial "$b (demo): fix this flake? | recommended: fix"
  assert_output --partial 'the human chose: wait'
  refute_output --partial "$a (demo)"
  assert_equal "$(grep -c "$b (demo)" <<<"$output")" 1
  # an in-window override that picks the recommendation over the judge's own answer is kept
  rm "$HOME/.local/state/agent-ask/demoted"
  fake_judge "$(score ship_deploy wait)"
  local c; c="$(armed sid-3 'park the flake?')"
  run "$AGENT_ASK" show "$c"; assert_line 'assume_answer: wait'
  AGENT_ASK_DEMOTE_MIN=99 "$AGENT_ASK" settle-session sid-3 answered "fix"
  run "$AGENT_ASK" precedents 2030-01-01T00:00:00+0000
  assert_output --partial "$c (demo): park the flake? | recommended: wait (park until the row is fixed) | the human chose: fix"
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
