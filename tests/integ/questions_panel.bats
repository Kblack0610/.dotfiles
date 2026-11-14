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
  assert_line --regexp $'\tnone ucp:60 +[0-9]+m  long project[?]$'
  assert_line --regexp $'\tnone demo:1 +[0-9]+m  short project[?]$'
  assert_line --regexp $'\tnone demo   +[0-9]+m  no agent number[?]$'
}

@test "a row says LIVE, none or dead before the name, and what the session is under the question" {
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
  # The second line starts under the question: mark (4) + name column (4) + age (3) + four spaces.
  assert_line --regexp "^$live	LIVE demo +[0-9]+m  live[?]~ {15}live-work\$"
  assert_line --regexp "^$ended	dead demo +[0-9]+m  ended[?]~ {15}tidy-the-board\$"
  assert_line --regexp "^$untitled	dead demo +[0-9]+m  untitled[?]\$"
  # An ask with no session (intake, headless) is none, not LIVE: its card says no session is waiting.
  assert_line --regexp "^$loose	none demo +[0-9]+m  headless[?]\$"
}

@test "live asks come first oldest first, then the open dialogs, then the dead asks oldest first" {
  mkdir -p "$HOME/.claude/sessions"
  printf '{"pid":%d,"sessionId":"sid-1"}\n' "$$" >"$HOME/.claude/sessions/$$.json"
  local dead_old live_new dead_new live_old
  dead_old="$(CLAUDE_CODE_SESSION_ID=sid-9 ask demo agent-1 'a=the first|b=the second' 'dead old?')"
  live_new="$(CLAUDE_CODE_SESSION_ID=sid-1 ask demo agent-2 'a=the first|b=the second' 'live new?')"
  dead_new="$(CLAUDE_CODE_SESSION_ID=sid-8 ask demo agent-3 'a=the first|b=the second' 'dead new?')"
  live_old="$(ask demo agent-4 'a=the first|b=the second' 'live old?')"
  created "$dead_old" 2026-11-01T10:00:00-0800
  created "$live_new" 2026-11-04T10:00:00-0800
  created "$dead_new" 2026-11-05T10:00:00-0800
  created "$live_old" 2026-11-02T10:00:00-0800
  live_agent hub/demo:2 waiting 90 ExitPlanMode 'Stop issues' >"$NOTES_FIXTURE/agent-panel.list.json"
  run rows
  assert_success
  # The oldest ask is dead, so it sorts below every live row and the dialog.
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$live_old $live_new @hub/demo:2 $dead_old $dead_new "
  assert_line --index 2 --partial $'\tLIVE demo:2'
  # live_old has no session: it reads none, and still sorts with the live asks.
  assert_line --index 0 --partial $'\tnone demo:4'
  assert_line --index 1 --partial $'\tLIVE demo:2'
  assert_line --index 3 --partial $'\tdead demo:1'
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

# live_agent <target> <status> <idle min> <doing> <summary>: one line of `agent-panel list --json`.
live_agent() {
  printf '{"target":"%s","status":"%s","idle_since":%s,"doing":"%s","summary":"%s","cwd":"/nowhere/demo"}\n' \
    "$1" "$2" "$(($(date +%s) - $3 * 60))" "$4" "$5"
}

@test "every session with a dialog open is a row after the asks, plans included, so the count matches the chip's" {
  local id
  id="$(ask demo agent-1 'a=the first|b=the second' 'filed question?')"
  {
    live_agent lab/demo-agent-4:1 waiting 30 AskUserQuestion 'Trading plan'
    live_agent hub/demo:2 waiting 90 ExitPlanMode 'Stop issues'
    live_agent hub/demo:3 waiting 10 Bash 'Needs a permission'
    live_agent lab/demo-agent-5:1 busy 5 Bash 'Has an ask'
    live_agent lab/demo-agent-6:1 busy 0 Edit 'Busy'
  } >"$NOTES_FIXTURE/agent-panel.list.json"
  run rows
  assert_success
  # The ask first, then the dialogs oldest first; a busy session adds nothing, ask or no ask.
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$id @hub/demo:2 @lab/demo-agent-4:1 @hub/demo:3 "
  assert_line --index 1 --partial 'demo:2'
  assert_line --index 1 --partial 'plan waiting for approval~'
  assert_line --index 1 --partial 'Stop issues'
  assert_line --index 2 --partial 'demo:4'
  assert_line --index 2 --partial 'question waiting for an answer'
  assert_line --index 3 --partial 'prompt waiting in its terminal: Bash'
  # The header counts each kind, and leaves out a kind with none.
  . "$Q"
  assert_equal "$(waiting $("$Q" rows | rows_count))" '1 ask . 1 plan . 1 question . 1 prompt waiting'
  assert_equal "$(waiting 3 11 2 0)" '3 asks . 11 plans . 2 questions waiting'
  assert_equal "$(waiting 0 1 0 0)" '1 plan waiting'
  assert_equal "$(waiting 0 0 0 0)" 'no questions waiting'
}

@test "count is the number of rows, so the status bar and the panel read one number" {
  ask demo agent-1 'a=the first|b=the second' 'one?' >/dev/null
  ask demo agent-2 'a=the first|b=the second' 'two?' >/dev/null
  {
    live_agent lab/demo-agent-4:1 waiting 30 AskUserQuestion 'Trading plan'
    live_agent hub/demo:2 waiting 90 ExitPlanMode 'Stop issues'
    live_agent lab/demo-agent-6:1 busy 0 Edit 'Busy'
  } >"$NOTES_FIXTURE/agent-panel.list.json"
  # agent-panel list prints a `!` glyph for a waiting status; the fixture serves both forms.
  printf 'lab/demo-agent-4:1\t!\tdemo\tx\nhub/demo:2\t!\tdemo\tx\nlab/demo-agent-6:1\t~\tdemo\tx\n' >"$NOTES_FIXTURE/agent-panel.list"
  . "$Q"
  run "$Q" count
  assert_success
  assert_output 4
  assert_equal "$("$Q" rows | rows_count | awk '{ print $1 + $2 + $3 + $4 }')" 4
  assert_equal "$("$AGENT_ASK" count --all)" 2
  # An answered or cancelled ask leaves both counts; the dialog just answered does too.
  QUESTIONS_ANSWERED=hub/demo:2 run "$Q" count
  assert_output 3
}

@test "count is 0 with nothing waiting, and a busy session adds nothing (negative control)" {
  printf 'lab/demo-agent-6:1\t~\tdemo\tx\n' >"$NOTES_FIXTURE/agent-panel.list"
  run "$Q" count
  assert_success
  assert_output 0
}

@test "with no state document, or no question at all, a dialog row never appears" {
  run rows
  assert_output ''
  fleet_doc "$(session lab/demo-agent-6:1 WORKING busy 0 Edit 'Busy')"
  run rows
  assert_success
  assert_output ''
}

# plan_dialog: the options agent-panel reads off a plan dialog's pane.
plan_dialog() {
  printf '1\t0\tYes, and switch to BYPASS PERMISSIONS\n2\t0\tYes, manually approve edits\n3\t1\tTell Claude what to change\n' >"$NOTES_FIXTURE/agent-panel.options"
}

@test "a dialog row: a number arms the option the pane shows, enter presses it there, checked against that text" {
  plan_dialog
  run "$Q" key 2 @hub/demo:2
  assert_output 'change-footer~send 2 "Yes, manually approve edits" to hub/demo:2? enter sends . esc cancels~'
  run grep -c '^agent-panel answer' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  run "$Q" key enter @hub/demo:2
  assert_success
  assert_output --partial 'sent 2 "Yes, manually approve edits" to hub/demo:2'
  assert_output --partial 'reload('
  grep -qx 'agent-panel answer hub/demo:2 2 --expect Yes, manually approve edits --' "$NOTES_FIXTURE/calls.log"
  # The state is spent: a second enter sends nothing more.
  run "$Q" key enter @hub/demo:2
  assert_output --partial 'press a number, t, d or p first'
}

@test "a dialog that changed or closed before enter is refused, said, and the list reloads" {
  plan_dialog
  printf '4\nagent-panel answer: option 2 now reads "No"; nothing sent\n' >"$NOTES_FIXTURE/agent-panel.answer"
  "$Q" key 2 @hub/demo:2 >/dev/null
  run "$Q" key enter @hub/demo:2
  assert_output --partial 'not sent: agent-panel answer: option 2 now reads "No"; nothing sent'
  assert_output --partial 'reload('
  printf '3\n' >"$NOTES_FIXTURE/agent-panel.answer"
  "$Q" key 1 @hub/demo:2 >/dev/null
  run "$Q" key enter @hub/demo:2
  assert_output --partial 'not taken: hub/demo:2 did not move on . g goes there'
}

@test "t, or the number of the option that takes text, opens the answer line; enter types it into that option" {
  plan_dialog
  run "$Q" key t @hub/demo:2
  assert_output --partial 'change-prompt~answer> ~'
  assert_output --partial 'answering hub/demo:2: Tell Claude what to change'
  # Keys type while the line is open.
  run "$Q" key 2 @hub/demo:2
  assert_output 'put(2)'
  run "$Q" key enter @hub/demo:2 'split it in two'
  assert_output --partial 'sent 3 "Tell Claude what to change" to hub/demo:2'
  grep -qx 'agent-panel answer hub/demo:2 3 --expect Tell Claude what to change -- split it in two' "$NOTES_FIXTURE/calls.log"
  run "$Q" key 3 @hub/demo:2
  assert_output --partial 'change-prompt~answer> ~'
}

@test "the panel's enter on a dialog presses it in the background, guarded on that row alone" {
  plan_dialog
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"
  "$Q" key 2 @hub/demo:2 >/dev/null
  run "$Q" key submit @hub/demo:2
  assert_output --regexp "^bg-transform\($Q key dsend hub_demo_2_ \{q\}\)"
  assert_output --partial 'sending 2 "Yes, manually approve edits" to hub/demo:2 ...'
  assert_equal "$(cat "$QUESTIONS_STATE")" ''
  run grep -c '^agent-panel answer' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # While it sends, a second enter on that row sends nothing; another row arms as ever.
  "$Q" key 2 @hub/demo:2 >/dev/null
  run "$Q" key submit @hub/demo:2
  assert_output 'change-footer~still sending to hub/demo:2 . wait for it~'
  "$Q" key 1 "$id" >/dev/null
  run "$Q" key dsend hub_demo_2_ ''
  assert_output --regexp '^reload\(QUESTIONS_ANSWERED=hub/demo:2 '
  # The choice armed on the ask meanwhile stays, and so does its footer.
  refute_output --partial 'change-footer'
  assert_equal "$(cat "$QUESTIONS_STATE")" "armed 1 $id"
  grep -qx 'agent-panel answer hub/demo:2 2 --expect Yes, manually approve edits --' "$NOTES_FIXTURE/calls.log"
  [ ! -e "$QUESTIONS_STATE.send.hub_demo_2_" ]
}

@test "a dialog row refuses what it cannot do: no option, no text field, drop, or no dialog to read" {
  printf '1\t0\tYes\n2\t0\tNo\n' >"$NOTES_FIXTURE/agent-panel.options"
  run "$Q" key 5 @hub/demo:2
  assert_output 'change-footer~no option 5 here . pick one the card shows~'
  run "$Q" key t @hub/demo:2
  assert_output 'change-footer~this one takes no typed answer . pick a number~'
  run "$Q" key d @hub/demo:2
  assert_output 'change-footer~a dialog is answered, not dropped . g goes there~'
  run "$Q" key p @hub/demo:2
  assert_output 'change-footer~a dialog is answered, not parked . g goes there~'
  rm "$NOTES_FIXTURE/agent-panel.options"
  local k
  for k in 1 t; do
    run "$Q" key "$k" @lab/demo-agent-4:1
    assert_output 'change-footer~no dialog to answer here . g goes there~'
  done
  run "$Q" key enter @lab/demo-agent-4:1
  assert_output --partial 'press a number, t, d or p first'
  run grep -c '^agent-panel answer' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  run "$Q" key g @lab/demo-agent-4:1
  assert_output 'execute-silent(agent-panel jump lab/demo-agent-4:1)+abort'
}

@test "a dialog row's card is agent-panel's, from the live pane" {
  printf 'plan waiting for your approval\n 1  Yes\n' >"$NOTES_FIXTURE/agent-panel.dialog"
  run "$Q" card @hub/demo:2
  assert_success
  assert_output $'plan waiting for your approval\n 1  Yes'
}

@test "a dialog agent-panel cannot read gets the session from the state document and the bottom of its pane" {
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
  assert_output --partial 'answered "later" . sending it to demo:1'
  assert_output --partial "key delivered $id)"
  assert_equal "$(status_of "$id")" answered
  run grep -c '^answer: later$' "$(ask_file "$id")"
  assert_output 1
  # The state is spent: a second enter sends nothing more.
  run "$Q" key enter "$id"
  assert_output --partial 'press a number, t, d or p first'
}

@test "the panel's enter answers at once and nothing locks: the row says sending until the answer went" {
  local a b; a="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"; b="$(ask demo agent-2 'go=run it now|later=run it later' 'ship it?')"
  "$Q" key 2 "$a" >/dev/null
  FZF_POS=1 run "$Q" key submit "$a"
  assert_success
  assert_equal "$(status_of "$a")" answered
  assert_output --partial 'answered "later" . sending it to demo:1'
  assert_output --partial "+bg-transform($Q key delivered $a)"
  refute_output --partial 'busy'
  # The reload's rows: the answer below the open question, tagged sending, with what was answered.
  run rows
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$b $a "
  assert_line --index 1 --regexp $'\tsending demo:1 +[0-9]+m  run the sweep[?]~ +answer: later$'
  assert_line --index 0 --regexp $'\tnone    demo:2 '
  # Once loaded, the cursor goes back to row 1, where the next question now is (--track would
  # follow the answer down), and the header counts; the jump is spent on that one load.
  run "$Q" key loaded
  assert_output 'pos(1)+change-header~1 ask waiting . 1 sending~'
  run "$Q" key loaded
  assert_output 'change-header~1 ask waiting . 1 sending~'
  # A key on the sending row only says so; the next question answers at once.
  run "$Q" key 1 "$a"
  assert_output 'change-footer~answered; sending it to demo:1 . g goes there~'
  "$Q" key 1 "$b" >/dev/null
  run "$Q" key submit "$b"
  assert_equal "$(status_of "$b")" answered
  # Once deliver sent it, the background wait reloads and says where it went; the row is gone.
  "$AGENT_ASK" deliver --all 2>/dev/null
  FZF_POS=2 run "$Q" key delivered "$a"
  assert_output --regexp '^reload\('
  assert_output --partial 'delivered to demo:1: a board row'
  # A background reload leaves the cursor where the human has it.
  run "$Q" key loaded
  refute_output --partial 'pos('
  run rows
  assert_output ''
  # The status bar never counted an answer on its way.
  run "$Q" count
  assert_output 0
}

@test "the background wait leaves a choice armed meanwhile alone, and gives up after its guard (negative control)" {
  local a b; a="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"; b="$(ask demo agent-2 'go=run it now|later=run it later' 'ship it?')"
  "$Q" key 2 "$a" >/dev/null
  "$Q" key submit "$a" >/dev/null
  # Nothing delivered it: after the guard it reloads and says the delivery has not run.
  AGENT_ASK_WAIT_TIMEOUT=1 run "$Q" key delivered "$a"
  assert_output --partial 'still sending to demo:1 . is agent-ask-deliver.path running?'
  # With a choice armed on another row the reload comes, the footer and the choice stay.
  "$Q" key 1 "$b" >/dev/null
  "$AGENT_ASK" deliver --all 2>/dev/null
  run "$Q" key delivered "$a"
  assert_output "reload($Q rows)"
  assert_equal "$(cat "$QUESTIONS_STATE")" "armed 1 $b"
}

@test "the panel's enter with nothing typed, or a failed answer, sends nothing and waits on nothing (negative control)" {
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"
  "$Q" key t "$id" >/dev/null
  run "$Q" key submit "$id" ''
  assert_output --partial 'type an answer first'
  QUESTIONS_ASK=false run "$Q" key submit "$id" 'after lunch'
  assert_output --partial 'not sent'
  refute_output --partial 'bg-transform'
  assert_equal "$(status_of "$id")" pending
}

@test "a delivery that failed stays a row with why, until d then enter clears it" {
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'run the sweep?')"
  "$AGENT_ASK" answer "$id" later 2>/dev/null
  sed -i 's/^delivery: .*/delivery: failed/' "$(ask_file "$id")"
  echo "delivery_note: its session is in a dialog, so the answer was not typed into it" >>"$(ask_file "$id")"
  run rows
  assert_line --index 0 --regexp $'\tfailed demo:1 +[0-9]+m  run the sweep[?]~ +not delivered: its session is in a dialog'
  . "$Q"
  assert_equal "$("$Q" rows | rows_count)" '0 0 0 0 0 0 1'
  assert_equal "$(waiting 0 0 0 0 0 0 1)" 'no questions waiting . 1 not delivered'
  run "$Q" key 1 "$id"
  assert_output --partial 'answered, not delivered: its session is in a dialog'
  # d then esc keeps it (negative control); d then enter clears it.
  "$Q" key d "$id" >/dev/null
  "$Q" key esc "$id" >/dev/null
  run rows
  assert_output --partial 'failed'
  run "$Q" key d "$id"
  assert_output --partial 'clear the not-delivered note'
  run "$Q" key submit "$id"
  assert_output --partial "cleared $id"
  run "$AGENT_ASK" show "$id"
  assert_line 'delivery: seen'
  run rows
  assert_output ''
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
  assert_output --partial 'answered . sending it'
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
  # The reload, then its load event counts the rows into the header.
  "$Q" rows >/dev/null
  run "$Q" key loaded
  assert_output 'change-header~1 ask waiting . 1 sending~'
  # A t on the row just answered types nothing: its answer is on its way.
  run "$Q" key t "$a"
  assert_output --partial 'sending it to demo:1'
  refute_output --partial 'show-input'
  run "$Q" key t "$b"
  assert_output --regexp '^show-input\+clear-query\+'
  assert_output --partial 'change-header~answering demo:2: second?~'
  # esc out of typing puts the count back and closes nothing.
  # While typing, a reload leaves the header on the question being answered.
  run "$Q" key loaded
  assert_output ''
  printf 'x\n' >"$QUESTIONS_STATE.jump"
  run "$Q" key loaded
  assert_output ''
  printf '2\n' >"$QUESTIONS_STATE.jump"
  run "$Q" key loaded
  assert_output 'pos(2)'
  run "$Q" key esc "$b"
  assert_output --partial 'hide-input+change-prompt~~'
  assert_output --partial 'change-header~1 ask waiting . 1 sending~'
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
  # sid-gone has no Claude transcript (a Codex thread posts under its own id): no reopen, no
  # claude --resume hint. The reopen test below covers a transcript whose directory is gone.
  run "$Q" key g "$gone"
  assert_output 'change-footer~no Claude conversation sid-gone to reopen; answer it here~'
  run "$Q" key g "$loose"
  assert_output 'change-footer~no session is waiting on this ask; answer it here~'
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

@test "a parked ask is the last row, tagged park with its date, and stays out of count" {
  local live parked
  live="$(ask demo agent-1 'a=the first|b=the second' 'live?')"
  parked="$(ask demo agent-2 'a=the first|b=the second' 'wear the headset?')"
  created "$parked" 2026-11-01T10:00:00-0800
  "$AGENT_ASK" park "$parked" --until '+3 days +5 minutes' 2>/dev/null
  run rows
  assert_success
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$live $parked "
  assert_line --index 1 --partial $'\tpark demo:2'
  # Its age column says how long until it is back, as wide as an age, so the question lines up.
  assert_line --index 1 --partial 'park demo:2  3d  wear the headset?'
  assert_equal "$(cut -f2 <<<"${lines[1]}" | grep -bo 'wear' | cut -d: -f1)" "$(cut -f2 <<<"${lines[0]}" | grep -bo 'live' | cut -d: -f1)"
  . "$Q"
  assert_equal "$("$Q" rows | rows_count)" '1 0 0 0 1 0 0'
  assert_equal "$(waiting 1 0 0 0 1)" '1 ask waiting . 1 parked'
  run "$Q" count
  assert_output 1
  # Negative control: unparked, it counts again.
  "$AGENT_ASK" unpark "$parked" 2>/dev/null
  run "$Q" count
  assert_output 2
}

@test "the panel hides parked asks until P, and P again hides them" {
  local live parked
  live="$(ask demo agent-1 'a=the first|b=the second' 'live?')"
  parked="$(ask demo agent-2 'a=the first|b=the second' 'wear the headset?')"
  "$AGENT_ASK" park "$parked" --until '+3 days' 2>/dev/null
  export QUESTIONS_PARKED="$BATS_TEST_TMPDIR/parked"
  : >"$QUESTIONS_PARKED"
  run rows
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$live "
  . "$Q"
  assert_equal "$(waiting 1 0 0 0 1)" '1 ask waiting . 1 parked (P shows)'
  run "$Q" key P "$live"
  assert_output --partial 'reload('
  assert_output --partial '1 parked (P hides)'
  assert_output --partial 'parked asks shown'
  run rows
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$live $parked "
  # A choice armed on the parked ask does not survive P hiding it: a later enter sends nothing.
  echo "armed 1 $parked" >"$QUESTIONS_STATE"
  run "$Q" key P "$parked"
  assert_output --partial 'parked asks hidden'
  assert_equal "$(cat "$QUESTIONS_STATE")" ''
  run rows
  assert_equal "$(cut -f1 <<<"$output" | tr '\n' ' ')" "$live "
  # The status bar count never counted parked asks, hidden or not.
  run "$Q" count
  assert_output 1
  # Typing an answer, P is a letter.
  echo "typing - $live" >"$QUESTIONS_STATE"
  run "$Q" key P "$live"
  assert_output 'put(P)'
}

@test "p then enter parks the question until its revisit date; p on a parked one then enter puts it back" {
  local id; id="$(ask demo agent-1 'go=run it now|later=run it later' 'fly the drone?')"
  run "$Q" key p "$id"
  assert_output --partial "park $id until its revisit date"
  "$Q" key esc "$id" >/dev/null
  run grep -c '^parked_until:' "$(ask_file "$id")"
  assert_output 0
  "$Q" key p "$id" >/dev/null
  run "$Q" key enter "$id"
  assert_success
  assert_equal "$(status_of "$id")" pending
  run grep -c '^parked_until:' "$(ask_file "$id")"
  assert_output 1
  run "$Q" key p "$id"
  assert_output --partial "put $id back on the list now?"
  "$Q" key enter "$id" >/dev/null
  run grep -c '^parked_until:' "$(ask_file "$id")"
  assert_output 0
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
