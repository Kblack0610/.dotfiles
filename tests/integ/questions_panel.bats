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
# rows [VAR=value...]: the panel's rows, one per line with ~ for the break between a row's two
# lines and the bold and faint stripped.
rows() { env "$@" "$Q" rows | tr '\n\0' '~\n' | sed 's/\x1b\[[0-9;]*m//g'; }

@test "rows: this tmux session's asks first, then oldest, each row keyed by its id" {
  local old new mine
  old="$(ask alpha agent-1 'a=the first|b=the second' 'old question?')"
  new="$(ask beta agent-2 'a=the first|b=the second' 'new question?')"
  mine="$(ask gamma agent-3 'a=the first|b=the second' 'mine?')"
  created "$old" 2026-11-01T10:00:00-0800
  created "$new" 2026-11-04T10:00:00-0800
  created "$mine" 2026-11-05T10:00:00-0800
  echo agent-3 >"$NOTES_FIXTURE/tmux.session"
  run rows TMUX=/tmp/sock,1,0
  assert_success
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$mine $old $new "
  assert_line --index 1 --partial 'old question?'
  # Outside tmux there is no session to lift: oldest first.
  run rows
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$old $new $mine "
}

@test "rows name the asker by project slug and agent number, in a column as wide as its longest name" {
  ask unity-core-playground unity-core-playground-agent-60 'a=the first|b=the second' 'long project?' >/dev/null
  ask demo agent-1 'a=the first|b=the second' 'short project?' >/dev/null
  ask demo hub 'a=the first|b=the second' 'no agent number?' >/dev/null
  run rows
  assert_success
  assert_line --regexp $'\tucp:60 +[0-9]+m  long project[?]$'
  assert_line --regexp $'\tdemo:1 +[0-9]+m  short project[?]$'
  assert_line --regexp $'\tdemo   +[0-9]+m  no agent number[?]$'
}

@test "a row's second line says what the session is, and ended once it has, under the question" {
  mkdir -p "$HOME/.claude/sessions" "$HOME/.agent/sessions/demo"
  printf '{"pid":%d,"sessionId":"sid-1"}\n' "$$" >"$HOME/.claude/sessions/$$.json"
  printf '%s\n' '{"session_id":"sid-1","title":"live-work"}' '{"session_id":"sid-9","title":""}' \
    '{"session_id":"sid-9","title":"tidy-the-board"}' >"$HOME/.agent/sessions/demo/sessions.jsonl"
  local live ended untitled loose
  live="$(CLAUDE_CODE_SESSION_ID=sid-1 ask demo s 'a=the first|b=the second' 'live?')"
  ended="$(CLAUDE_CODE_SESSION_ID=sid-9 ask demo s 'a=the first|b=the second' 'ended?')"
  untitled="$(CLAUDE_CODE_SESSION_ID=sid-8 ask demo s 'a=the first|b=the second' 'untitled?')"
  loose="$(ask demo s 'a=the first|b=the second' 'headless?')"
  run rows
  assert_success
  # The second line starts under the question: name column (4) + age (3) + three spaces.
  assert_line --regexp "^$live	demo +[0-9]+m  live[?]~ {10}live-work\$"
  assert_line --regexp "^$ended	demo +[0-9]+m  ended[?]~ {10}ended [.] tidy-the-board\$"
  assert_line --regexp "^$untitled	demo +[0-9]+m  untitled[?]~ {10}ended\$"
  assert_line --regexp "^$loose	demo +[0-9]+m  headless[?]\$"
}

# The selected row is drawn on colour 8, the grey of the dim colour (and of some themes'
# magenta): a coloured name or age vanished there (human, 2026-11-05). Bold and faint take fzf's
# own selected-row white.
@test "rows carry bold and faint but no colour, so the selected row still reads" {
  ask demo agent-1 'a=the first|b=the second' 'colour?' >/dev/null
  run bash -c '"$1" rows | tr "\0" "\n"' _ "$Q"
  assert_success
  assert_output --partial $'\033[1mdemo:1'
  assert_output --partial $'\033[2m'
  refute_output --regexp $'\033\\[[0-9;]*(3[0-7]|9[0-7])m'
}

@test "rows list nothing, successfully, when no question waits" {
  run rows
  assert_success
  assert_output ''
}

# fleet_doc <session json>...: the fleet state document fleet-sessions writes, those sessions in it.
fleet_doc() {
  mkdir -p "$XDG_STATE_HOME/fleet"
  local IFS=,
  printf '{"sessions":[%s]}\n' "$*" >"$XDG_STATE_HOME/fleet/state.json"
}
# session <target> <bucket> <reason> <idle min> <doing> <topic>: one session object.
session() {
  printf '{"target":"%s","bucket":"%s","reason":"%s","idle_min":%s,"doing":"%s","topic":"%s","said":"the last thing it said","cwd":"/nowhere/demo"}' "$@"
}

@test "a session waiting on a prompt in its terminal is a row after the questions, so the count matches the chip's" {
  local id
  id="$(ask demo agent-1 'a=the first|b=the second' 'filed question?')"
  fleet_doc "$(session lab/demo-agent-4:1 NEEDS 'waiting on a prompt or permission' 30 AskUserQuestion 'Trading plan')" \
    "$(session hub/demo:2 NEEDS 'waiting on a prompt or permission' 90 ExitPlanMode 'Stop issues')" \
    "$(session lab/demo-agent-5:1 NEEDS '1 pending ask(s)' 5 Bash 'Has an ask')" \
    "$(session lab/demo-agent-6:1 WORKING busy 0 Edit 'Busy')"
  run rows
  assert_success
  # The ask first, then the prompts oldest first; an ask's NEEDS and a WORKING session add nothing.
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$id @hub/demo:2 @lab/demo-agent-4:1 "
  assert_line --index 1 --partial 'demo:2'
  assert_line --index 1 --partial 'plan waiting for approval in its terminal~'
  assert_line --index 1 --partial 'Stop issues'
  assert_line --index 2 --partial 'demo:4'
  assert_line --index 2 --partial 'question waiting in its terminal'
  # The header names both, and each alone.
  . "$Q"
  assert_equal "$(waiting $("$Q" rows | rows_count))" '1 question . 2 prompts waiting'
  assert_equal "$(waiting 0 1)" '1 prompt waiting'
  assert_equal "$(waiting 3 0)" '3 questions waiting'
  assert_equal "$(waiting 0 0)" 'no questions waiting'
}

@test "with no state document, or no question at all, a prompt row never appears" {
  run rows
  assert_output ''
  fleet_doc "$(session lab/demo-agent-6:1 WORKING busy 0 Edit 'Busy')"
  run rows
  assert_success
  assert_output ''
}

@test "a prompt row is answered in its session: g goes there, the answer keys say so and arm nothing" {
  run "$Q" key g @lab/demo-agent-4:1
  assert_output 'execute-silent(agent-panel jump lab/demo-agent-4:1)+abort'
  local k
  for k in 1 t d; do
    run "$Q" key "$k" @lab/demo-agent-4:1
    assert_output 'change-footer~answer this one in its session . g goes there~'
  done
  run "$Q" key enter @lab/demo-agent-4:1
  assert_output --partial 'press a number, t or d first'
}

@test "a prompt row's card is the session from the state document and the bottom of its pane" {
  fleet_doc "$(session lab/demo-agent-4:1 NEEDS 'waiting on a prompt or permission' 30 AskUserQuestion 'Trading plan')"
  printf 'earlier output\n\nWhich check forms should this build?\n1. KPI key only\n\n\n' >"$NOTES_FIXTURE/tmux.capture.demo-agent-4_1"
  run "$Q" card @lab/demo-agent-4:1
  assert_success
  assert_line --index 0 'lab/demo-agent-4:1  waiting on a prompt or permission'
  assert_line 'topic  Trading plan'
  assert_line 'doing  AskUserQuestion'
  assert_line 'Which check forms should this build?'
  # The pane's trailing blank lines are not the card's last lines.
  assert_equal "${lines[-1]}" '1. KPI key only'
}

@test "a number only arms its option; enter sends exactly that one" {
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"
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
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"
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
  a="$(ask demo agent-1 'go=run it now|later=run it later' 'first?')"
  b="$(ask demo agent-1 'go=run it now|later=run it later' 'second?')"
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
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"
  run "$Q" key 3 "$id"
  assert_output --partial 'no option 3 here'
  "$Q" key enter "$id" >/dev/null
  assert_equal "$(status_of "$id")" pending
}

@test "t opens the answer line, keys type into it, and enter sends the text" {
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"
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
  local a b; a="$(ask demo agent-1 'go=run it now|later=run it later' 'first?')"; b="$(ask demo agent-2 'go=run it now|later=run it later' 'second?')"
  run "$Q" key t "$a"
  assert_output --regexp '^show-input\+clear-query\+'
  run "$Q" key enter "$a" 'one'
  assert_output --partial 'hide-input'
  assert_output --partial 'change-header~1 question waiting~'
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
  assert_output --partial 'change-header~1 question waiting~'
  refute_output --partial 'abort'
  run grep -c '^answer: one$' "$(ask_file "$a")"
  assert_output 1
  assert_equal "$(status_of "$b")" pending
}

@test "g goes to the asking session when it lives, and says why when it cannot" {
  local live gone loose
  live="$(CLAUDE_CODE_SESSION_ID=sid-live ask demo agent-1 'go=run it now|later=run it later' 'live?')"
  gone="$(CLAUDE_CODE_SESSION_ID=sid-gone ask demo agent-2 'go=run it now|later=run it later' 'gone?')"
  loose="$(ask demo agent-3 'go=run it now|later=run it later' 'loose?')"
  printf '%s\n' '{"session_id":"sid-live","target":"hub/demo:2"}' >"$NOTES_FIXTURE/agent-panel.list"
  run "$Q" key g "$live"
  assert_output 'execute-silent(agent-panel jump hub/demo:2)+abort'
  run "$Q" key g "$gone"
  assert_output 'change-footer~session ended and its directory is gone; resume with claude --resume sid-gone~'
  run "$Q" key g "$loose"
  assert_output 'change-footer~no Claude session owns this ask~'
  # Going nowhere answers nothing.
  assert_equal "$(status_of "$live")$(status_of "$gone")" pendingpending
}

# transcript <claude session> <cwd>: the conversation's transcript, first line naming its cwd.
transcript() {
  mkdir -p "$HOME/.claude/projects/p"
  printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$2" "$1" >"$HOME/.claude/projects/p/$1.jsonl"
}

@test "g reopens an ended session through fleet-dispatch in its first directory and world, then jumps there" {
  local gone here alive lost
  sandbox_worlds
  mkdir -p "$HOME/.dotfiles" "$BATS_TEST_TMPDIR/plain"
  # fleet-dispatch is the one path that opens sessions; the stub records the call and opens nothing.
  printf '#!/usr/bin/env bash\nprintf "fleet-dispatch %%s\\n" "$*" >>"$NOTES_FIXTURE/calls.log"\n[ -f "$NOTES_FIXTURE/dispatch.fail" ] && { echo "start: session busy"; exit 1; }\necho "started $6"\n' >"$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/fleet-dispatch"
  gone="$(CLAUDE_CODE_SESSION_ID=sid-gone ask demo dotfiles 'go=run it now|later=run it later' 'gone?')"
  transcript sid-gone "$HOME/.dotfiles"
  run "$Q" key g "$gone"
  assert_output "execute-silent(agent-panel jump hub/dotfiles:ask-$gone)+abort"
  assert_called "fleet-dispatch start --project demo --server hub --session dotfiles --window ask-$gone --cwd $HOME/.dotfiles --resume sid-gone"
  # A directory no manifest claims reopens in the panel's own world.
  here="$(CLAUDE_CODE_SESSION_ID=sid-here ask demo agent-4 'go=run it now|later=run it later' 'here?')"
  transcript sid-here "$BATS_TEST_TMPDIR/plain"
  TMUX=/tmp/tmux-1000/lab,1,0 run "$Q" key g "$here"
  assert_output --regexp "^execute-silent\(agent-panel jump lab/[^:]+:ask-$here\)\+abort$"
  # Negative controls. A start that fails says why and jumps nowhere.
  : >"$NOTES_FIXTURE/dispatch.fail"
  run "$Q" key g "$gone"
  assert_output 'change-footer~could not reopen: start: session busy~'
  rm "$NOTES_FIXTURE/dispatch.fail"
  # A conversation still running outside tmux is not resumed a second time.
  alive="$(CLAUDE_CODE_SESSION_ID=sid-alive ask demo agent-5 'go=run it now|later=run it later' 'alive?')"
  transcript sid-alive "$HOME/.dotfiles"
  mkdir -p "$HOME/.claude/sessions"
  printf '{"pid":%d,"sessionId":"sid-alive"}\n' "$$" >"$HOME/.claude/sessions/$$.json"
  run "$Q" key g "$alive"
  assert_output 'change-footer~session sid-alive still runs outside tmux; nothing to go to~'
  assert_not_called "--resume sid-alive"
  # A directory that is gone has nowhere to resume from.
  lost="$(CLAUDE_CODE_SESSION_ID=sid-lost ask demo agent-6 'go=run it now|later=run it later' 'lost?')"
  transcript sid-lost "$BATS_TEST_TMPDIR/deleted"
  run "$Q" key g "$lost"
  assert_output "change-footer~session ended and its directory $BATS_TEST_TMPDIR/deleted is gone; resume with claude --resume sid-lost~"
  assert_not_called "--resume sid-lost"
  # Plain target only reports; it never starts anything.
  run "$AGENT_ASK" target "$gone"
  assert_failure
  assert_output 'session ended; target --reopen starts it again (claude --resume sid-gone)'
  assert_equal "$(grep -c '^fleet-dispatch' "$NOTES_FIXTURE/calls.log")" 3
  # Going to a session answers nothing.
  assert_equal "$(status_of "$gone")" pending
}

@test "d then enter drops the question; d then esc keeps it" {
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"
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
  local id; id="$(ask demo agent-1 'g~o=run it now|later=run it later' 'run the sweep?')"
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
  run rows
  t1="$(date +%s%N)"
  assert_success
  assert_equal "$(wc -l <<<"$output")" 200
  # CONVENTIONS.md "Speed": a panel draws in under 300 ms. CI runners are slower than a
  # desk, so the gate is 1 s; the old agent-ask list took 2.4 s for this many on a desk.
  [ $(((t1 - t0) / 1000000)) -lt 1000 ] || fail "rows took $(((t1 - t0) / 1000000)) ms"
}
