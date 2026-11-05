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
  id="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo --session agent-1 'merge it?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'claude_session: sid-1'
  assert_line 'session: agent-1'
}

@test "an attended session files its ask and sees it in its pane, with no page per ask" {
  # 2026-10-28: agent-27 asked only in the conversation and waited unflagged; the ask file is
  # the one record every board and the phone read.
  CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_SESSION_ID=sid-1 run --separate-stderr \
    "$AGENT_ASK" post --project demo --options 'now|later' --recommend later 'merge it?'
  assert_success
  local id="$output"
  [ -f "$HOME/.agent/asks/demo/$id.md" ]
  [[ "$stderr" == *"ASK $id (question) - waiting on you"* ]]
  [[ "$stderr" == *"merge it?"* ]]
  [[ "$stderr" == *"  1  now"* ]]
  [[ "$stderr" == *"  2  later  (recommended)"* ]]
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
  id="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo --options 'go|later' --recommend go 'run the cleanup now?')"
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
  mine="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'merge it?')"
  other="$(CLAUDE_CODE_SESSION_ID=sid-2 post demo 'ship it?')"
  done_="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'old?')"
  "$AGENT_ASK" answer "$done_" yes 2>/dev/null
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
  # Plain options carry no notes.
  id="$("$AGENT_ASK" post --project demo --options 'a|b' 'which?')"
  run "$AGENT_ASK" show "$id"
  assert_line 'options: a|b'
  assert_line 'option_notes: '
}

@test "card shows the question, numbered options with meanings, the recommendation, context and judge" {
  local id; id="$("$AGENT_ASK" post --project demo --session agent-1 --options 'go=run it now|later=after the release' \
    --recommend later --context 'the sweep is ready' 'run the sweep?')"
  printf 'judge: take-recommend\njudge_reason: the policy says wait\n' >> "$HOME/.agent/asks/demo/$id.md"
  run env COLUMNS=80 "$AGENT_ASK" card "$id"
  assert_success
  assert_line --partial "ASK $id (question) - waiting on you  demo . agent-1"
  assert_line 'run the sweep?'
  assert_line '  1  go     run it now'
  assert_line '  2  later  after the release  (recommended)'
  assert_line 'why: the sweep is ready'
  assert_line 'judge: would take the recommendation - the policy says wait'
  # No colour off a terminal: the card lands in a session's tool output as plain text.
  ! grep -q $'\e' <<< "$output"
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

@test "pick answers the chosen option only after Enter, and q leaves the ask pending" {
  local id; id="$("$AGENT_ASK" post --project demo --options 'go|later' 'run the sweep?')"
  # Negative control: a digit then a non-Enter key sends nothing; q closes.
  run bash -c 'printf "2xq" | "$AGENT_ASK" pick "$1"' _ "$id"
  assert_success
  assert_output --partial 'not sent'
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  # A digit out of range is ignored.
  run bash -c 'printf "9q" | "$AGENT_ASK" pick "$1"' _ "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  run bash -c 'printf "2\n" | "$AGENT_ASK" pick "$1"' _ "$id"
  assert_success
  run "$AGENT_ASK" show "$id"
  assert_line 'status: answered'
  assert_line 'answer: later'
}

@test "pick with no id goes back to the list after each card, and says so when nothing waits" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # fzf stub: chooses the first row it is offered, the way Enter on the list would.
  printf '#!/bin/sh\nhead -1\n' > "$BATS_TEST_TMPDIR/bin/fzf"; chmod +x "$BATS_TEST_TMPDIR/bin/fzf"
  local a b
  a="$("$AGENT_ASK" post --project demo --options 'go|later' 'run the sweep?')"
  b="$("$AGENT_ASK" post --project demo --options 'yes|no' 'ship it?')"
  # Two answers on one keyboard: the second card came from the list after the first.
  run bash -c 'PATH="$1:$PATH"; printf "1\n1\n" | "$AGENT_ASK" pick' _ "$BATS_TEST_TMPDIR/bin"
  assert_success
  run "$AGENT_ASK" show "$a"; assert_line 'status: answered'
  run "$AGENT_ASK" show "$b"; assert_line 'status: answered'
  run bash -c 'printf "x" | "$AGENT_ASK" pick'
  assert_success
  assert_output 'no questions waiting; any key closes'
}

@test "pick drops a question only after Enter" {
  local id; id="$("$AGENT_ASK" post --project demo 'run the sweep?')"
  run bash -c 'printf "dxq" | "$AGENT_ASK" pick "$1"' _ "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: pending'
  run bash -c 'printf "d\n" | "$AGENT_ASK" pick "$1"' _ "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'status: cancelled'
  assert_line 'closed_reason: dropped by the human'
}

@test "ids are unique across rapid successive posts" {
  local a b c
  a="$(post demo one?)"; b="$(post demo two?)"; c="$(post demo three?)"
  local n; n="$(printf '%s\n%s\n%s\n' "$a" "$b" "$c" | sort -u | wc -l)"
  assert_equal "$n" '3'
}

# ── list: the TSV the cockpit's factory view consumes ────────────────────────

@test "list emits 18 tab-separated fields per ask" {
  post demo 'ship it?' >/dev/null
  run bash -c '"$AGENT_ASK" list demo | awk -F"\t" "{print NF; exit}"'
  assert_output '18'
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
  printf '{"session_id":"sid-1","pane":"lab/%%1","status":"idle"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  live="$(CLAUDE_CODE_SESSION_ID=sid-1 post demo 'live?')"
  gone="$(CLAUDE_CODE_SESSION_ID=sid-9 post demo 'gone?')"
  resumed="$(CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --resume '/captain resume' 'resumed?')"
  loose="$(post demo 'headless?')"
  run "$AGENT_ASK" card "$gone"
  assert_output --partial 'session gone: the answer becomes a row on the demo board'
  run "$AGENT_ASK" card "$resumed"
  assert_output --partial 'session gone: the answer starts `/captain resume`'
  # Negative controls: a live session, and an ask no session owns.
  run "$AGENT_ASK" card "$live"
  refute_output --partial 'session gone'
  run "$AGENT_ASK" card "$loose"
  refute_output --partial 'session gone'
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
printf 'thinking...\nASK-JUDGE-START\n%s\nASK-JUDGE-END\n' '$1'
SH
  chmod +x "$BATS_TEST_TMPDIR/judge"
  export AGENT_ASK_JUDGE_CMD="$BATS_TEST_TMPDIR/judge" AGENT_ASK_POLICY="$REPO_ROOT/.config/agent-ask/policy.md"
}

@test "judge records its call and reason, and leaves the ask pending" {
  fake_judge '{"call":"take-recommend","answer":"","reason":"landing is standing authorization"}'
  local id; id="$("$AGENT_ASK" post --project demo --options 'yes|no' --recommend yes 'open the PR?')"
  run "$AGENT_ASK" judge "$id"
  assert_success
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: take-recommend'
  assert_line 'judge_reason: landing is standing authorization'
  assert_line 'status: pending'
  assert_line --regexp '^judged_at: .+'
  # the prompt carries the policy and the ask
  run cat "$BATS_TEST_TMPDIR/judge.calls"
  assert_output --partial 'open the PR?'
  assert_output --partial 'Always `human`'
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
  fake_judge '{"call":"take-recommend","answer":"","reason":"x"}'
  local id; id="$(post demo 'no recommendation here?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: human'
  "$AGENT_ASK" judge "$id"
  run grep -c "^## The ask$" "$BATS_TEST_TMPDIR/judge.calls"
  assert_output '1'
}

@test "judge records a free answer, and a reply with no verdict records nothing" {
  fake_judge '{"call":"answer","answer":"the simpler one","reason":"no product effect"}'
  local id; id="$(post demo 'which way?')"
  "$AGENT_ASK" judge "$id"
  run "$AGENT_ASK" show "$id"
  assert_line 'judge: answer:the simpler one'
  fake_judge 'not json'
  id="$(post demo 'again?')"
  run "$AGENT_ASK" judge "$id"
  assert_failure
  run "$AGENT_ASK" show "$id"
  refute_line --partial 'judge:'
}

@test "post starts the judge unless AGENT_ASK_NO_JUDGE is set" {
  fake_judge '{"call":"human","answer":"","reason":"taste"}'
  # The fake judge also writes to a fifo, so the test waits on the call itself, not a timer.
  mkfifo "$BATS_TEST_TMPDIR/called"
  sed -i "2i echo called > '$BATS_TEST_TMPDIR/called'" "$BATS_TEST_TMPDIR/judge"
  unset AGENT_ASK_NO_JUDGE
  local id got; id="$(post demo 'pick a colour?')"
  # Opened read-write so the open itself never blocks; -t is the timeout guard on the read.
  exec 7<>"$BATS_TEST_TMPDIR/called"   # not 3: bats owns it
  read -r -t 10 -u 7 got || true
  exec 7<&-
  assert_equal "$got" called
  run grep -c 'pick a colour?' "$BATS_TEST_TMPDIR/judge.calls"
  assert_output '1'
  # negative control: with the guard, no call
  rm -f "$BATS_TEST_TMPDIR/judge.calls"
  export AGENT_ASK_NO_JUDGE=1
  id="$(post demo 'pick a shape?')"
  run "$AGENT_ASK" judge-report demo
  assert [ ! -e "$BATS_TEST_TMPDIR/judge.calls" ]
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
  local agree differ session deferred
  agree="$("$AGENT_ASK" post --project demo --options 'yes|no' --recommend yes 'a?')"
  differ="$(post demo 'b?')"; session="$(post demo 'c?')"; deferred="$(post demo 'd?')"
  sed -i 's/^judge: .*//' "$HOME/.agent/asks/demo/"*.md
  printf 'judge: take-recommend\n' >> "$HOME/.agent/asks/demo/$agree.md"
  printf 'judge: answer:left\n' >> "$HOME/.agent/asks/demo/$differ.md"
  printf 'judge: answer:left\n' >> "$HOME/.agent/asks/demo/$session.md"
  printf 'judge: human\n' >> "$HOME/.agent/asks/demo/$deferred.md"
  "$AGENT_ASK" answer "$agree" Yes 2>/dev/null
  "$AGENT_ASK" answer "$differ" right 2>/dev/null
  "$AGENT_ASK" answer "$session" "in session: left" 2>/dev/null
  "$AGENT_ASK" answer "$deferred" whatever 2>/dev/null
  run "$AGENT_ASK" judge-report demo
  assert_success
  assert_line --regexp "^$agree	agree	take-recommend	Yes$"
  assert_line --regexp "^$differ	differ	answer:left	right$"
  assert_line --regexp "^$session	unscored	"
  assert_line --regexp "^$deferred	asks-you	human	"
  assert_line 'judged 4 answered asks: the judge would have answered 3, scored 2, agreed 1'
}
