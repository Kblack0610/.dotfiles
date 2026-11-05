#!/usr/bin/env bats
# questions.sh (Prefix y): the rows it lists and what each key does. The keys are one
# transform handler that prints fzf actions and keeps the armed choice in a state file, so
# driving `questions.sh key ...` in sequence is the panel minus fzf. The real fzf and tmux
# run in tests/ui/questions_panel.bats.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  Q="$REPO_ROOT/.local/src/tmux/questions.sh"
  export QUESTIONS_ASK="$AGENT_ASK"
  export QUESTIONS_STATE="$BATS_TEST_TMPDIR/state"
  : >"$QUESTIONS_STATE"
}

ask() { "$AGENT_ASK" post --project "$1" --session "$2" --options "$3" "$4"; }
ask_file() { find "$HOME/.agent/asks" -name "$1.md"; }
created() { sed -i "s/^created: .*/created: $2/" "$(ask_file "$1")"; }
status_of() { sed -n 's/^status: //p' "$(ask_file "$1")"; }

@test "rows: this tmux session's asks first, then oldest, each row keyed by its id" {
  local old new mine
  old="$(ask alpha agent-1 'a|b' 'old question?')"
  new="$(ask beta agent-2 'a|b' 'new question?')"
  mine="$(ask gamma agent-3 'a|b' 'mine?')"
  created "$old" 2026-11-01T10:00:00-0800
  created "$new" 2026-11-04T10:00:00-0800
  created "$mine" 2026-11-05T10:00:00-0800
  echo agent-3 >"$NOTES_FIXTURE/tmux.session"
  run env TMUX=/tmp/sock,1,0 "$Q" rows
  assert_success
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$mine $old $new "
  assert_line --index 1 --partial 'old question?'
  # Outside tmux there is no session to lift: oldest first.
  run "$Q" rows
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$old $new $mine "
}

@test "rows name the asker by project slug and agent number, in a column as wide as its longest name" {
  ask unity-core-playground unity-core-playground-agent-60 'a|b' 'long project?' >/dev/null
  ask demo agent-1 'a|b' 'short project?' >/dev/null
  ask demo hub 'a|b' 'no agent number?' >/dev/null
  run bash -c '"$1" rows | sed "s/\x1b\[[0-9;]*m//g"' _ "$Q"
  assert_success
  assert_line --regexp $'\tucp:60 +[0-9]+m  long project[?]$'
  assert_line --regexp $'\tdemo:1 +[0-9]+m  short project[?]$'
  assert_line --regexp $'\tdemo   +[0-9]+m  no agent number[?]$'
}

@test "rows mark an ask whose Claude session has ended gone, and only that one" {
  mkdir -p "$HOME/.claude/sessions"
  printf '{"pid":%d,"sessionId":"sid-1"}\n' "$$" >"$HOME/.claude/sessions/$$.json"
  local live gone loose
  live="$(CLAUDE_CODE_SESSION_ID=sid-1 ask demo s 'a|b' 'live?')"
  gone="$(CLAUDE_CODE_SESSION_ID=sid-9 ask demo s 'a|b' 'gone?')"
  loose="$(ask demo s 'a|b' 'headless?')"
  run "$Q" rows
  assert_line --regexp "^$gone	.*gone"
  refute_line --regexp "^$live	.*gone"
  refute_line --regexp "^$loose	.*gone"
}

@test "rows list nothing, successfully, when no question waits" {
  run "$Q" rows
  assert_success
  assert_output ''
}

@test "a number only arms its option; enter sends exactly that one" {
  local id; id="$(ask demo agent-1 'go|later' 'run the sweep?')"
  run "$Q" key 2 "$id"
  assert_output --partial 'send 2 "later" to demo:1? enter sends'
  assert_equal "$(status_of "$id")" pending
  run "$Q" key enter "$id"
  assert_success
  assert_output --partial 'reload('
  assert_output --partial 'no questions waiting'
  assert_equal "$(status_of "$id")" answered
  run grep -c '^answer: later$' "$(ask_file "$id")"
  assert_output 1
  # The state is spent: a second enter sends nothing more.
  run "$Q" key enter "$id"
  assert_output --partial 'press a number, t or d first'
}

@test "esc after a number sends nothing, and esc with nothing armed closes" {
  local id; id="$(ask demo agent-1 'go|later' 'run the sweep?')"
  "$Q" key 1 "$id" >/dev/null
  run "$Q" key esc "$id"
  refute_output --partial abort
  run "$Q" key enter "$id"
  assert_equal "$(status_of "$id")" pending
  run "$Q" key esc "$id"
  assert_output abort
}

@test "moving to another question disarms the choice made on the last one" {
  local a b
  a="$(ask demo agent-1 'go|later' 'first?')"
  b="$(ask demo agent-1 'go|later' 'second?')"
  "$Q" key 1 "$a" >/dev/null
  run "$Q" key focus "$a"
  assert_output ''
  run "$Q" key focus "$b"
  assert_output --partial '1-9 pick'
  "$Q" key enter "$b" >/dev/null
  assert_equal "$(status_of "$a")" pending
  assert_equal "$(status_of "$b")" pending
}

@test "a number past the options says so and arms nothing" {
  local id; id="$(ask demo agent-1 'go|later' 'run the sweep?')"
  run "$Q" key 3 "$id"
  assert_output --partial 'no option 3 here'
  "$Q" key enter "$id" >/dev/null
  assert_equal "$(status_of "$id")" pending
}

@test "t opens the answer line, keys type into it, and enter sends the text" {
  local id; id="$(ask demo agent-1 'go|later' 'run the sweep?')"
  run "$Q" key t "$id"
  assert_output --partial 'show-input'
  # The header names what is answered; the prompt is only the line to type on.
  assert_output --partial 'change-prompt~answer> ~'
  assert_output --partial 'change-header~answering demo:1: run the sweep?~'
  # While typing, a digit or d is a character, not a key.
  run "$Q" key 1 "$id" 'go after 1'
  assert_output 'put(1)'
  run "$Q" key d "$id"
  assert_output 'put(d)'
  run "$Q" key g "$id"
  assert_output 'put(g)'
  run "$Q" key enter "$id" ''
  assert_output --partial 'type an answer first'
  assert_equal "$(status_of "$id")" pending
  run "$Q" key enter "$id" 'go after lunch'
  assert_output --partial 'sent your answer'
  assert_equal "$(status_of "$id")" answered
  run grep -c '^answer: go after lunch$' "$(ask_file "$id")"
  assert_output 1
}

@test "two typed answers in a row: each opens on an empty line, and the header goes back to the count" {
  local a b; a="$(ask demo agent-1 'go|later' 'first?')"; b="$(ask demo agent-2 'go|later' 'second?')"
  run "$Q" key t "$a"
  assert_output --regexp '^show-input\+clear-query\+'
  run "$Q" key enter "$a" 'one'
  assert_output --partial 'hide-input'
  assert_output --partial 'change-header~1 waiting~'
  # A t that beats the reload lands on the row just answered: it refreshes, types nothing.
  run "$Q" key t "$a"
  assert_output --partial 'reload('
  assert_output --partial 'that question was just answered'
  refute_output --partial 'show-input'
  run "$Q" key t "$b"
  assert_output --regexp '^show-input\+clear-query\+'
  assert_output --partial 'change-header~answering demo:2: second?~'
  # esc out of typing puts the count back and closes nothing.
  run "$Q" key esc "$b"
  assert_output --partial 'hide-input+change-prompt~~'
  assert_output --partial 'change-header~1 waiting~'
  refute_output --partial 'abort'
  run grep -c '^answer: one$' "$(ask_file "$a")"
  assert_output 1
  assert_equal "$(status_of "$b")" pending
}

@test "g goes to the asking session when it lives, and says why when it cannot" {
  local live gone loose
  live="$(CLAUDE_CODE_SESSION_ID=sid-live ask demo agent-1 'go|later' 'live?')"
  gone="$(CLAUDE_CODE_SESSION_ID=sid-gone ask demo agent-2 'go|later' 'gone?')"
  loose="$(ask demo agent-3 'go|later' 'loose?')"
  printf '%s\n' '{"session_id":"sid-live","target":"hub/demo:2"}' >"$NOTES_FIXTURE/agent-panel.list"
  run "$Q" key g "$live"
  assert_output 'execute-silent(agent-panel jump hub/demo:2)+abort'
  run "$Q" key g "$gone"
  assert_output 'change-footer~session ended; resume with claude --resume sid-gone~'
  run "$Q" key g "$loose"
  assert_output 'change-footer~no Claude session owns this ask~'
  # Going nowhere answers nothing.
  assert_equal "$(status_of "$live")$(status_of "$gone")" pendingpending
}

@test "d then enter drops the question; d then esc keeps it" {
  local id; id="$(ask demo agent-1 'go|later' 'run the sweep?')"
  "$Q" key d "$id" >/dev/null
  "$Q" key esc "$id" >/dev/null
  "$Q" key enter "$id" >/dev/null
  assert_equal "$(status_of "$id")" pending
  run "$Q" key d "$id"
  assert_output --partial "drop $id"
  run "$Q" key enter "$id"
  assert_output --partial "dropped $id"
  assert_equal "$(status_of "$id")" cancelled
  run grep -c '^closed_reason: dropped by the human$' "$(ask_file "$id")"
  assert_output 1
}

@test "a ~ in what the footer shows never reaches fzf as a delimiter" {
  local id; id="$(ask demo agent-1 'g~o|later' 'run the sweep?')"
  run "$Q" key 1 "$id"
  assert_output --partial 'send 1 "go" to demo:1?'
}

@test "an unknown verb or key fails instead of opening the picker" {
  run "$Q" bogus
  assert_failure
  assert_output --partial 'unknown verb: bogus'
  run "$Q" key x some-id
  assert_failure
  assert_output --partial 'unknown key: x'
}

@test "rows over 200 waiting questions draw inside the panel speed budget" {
  local i
  mkdir -p "$HOME/.agent/asks/demo"
  for i in $(seq 200); do
    printf 'id: q%03d\nproject: demo\nsession: s\ncreated: 2026-11-0%dT10:00:00-0800\nstatus: pending\nquestion: question %d?\noptions: a|b\n' \
      "$i" $((i % 5 + 1)) "$i" >"$HOME/.agent/asks/demo/q$(printf %03d "$i").md"
  done
  local t0 t1
  t0="$(date +%s%N)"
  run "$Q" rows
  t1="$(date +%s%N)"
  assert_success
  assert_equal "$(wc -l <<<"$output")" 200
  # CONVENTIONS.md "Speed": a panel draws in under 300 ms. CI runners are slower than a
  # desk, so the gate is 1 s; the old agent-ask list took 2.4 s for this many on a desk.
  [ $(((t1 - t0) / 1000000)) -lt 1000 ] || fail "rows took $(((t1 - t0) / 1000000)) ms"
}
