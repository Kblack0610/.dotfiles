#!/usr/bin/env bats
# Tier 3: Prefix y, the questions panel, through real fzf on a real tmux server at a laptop
# size and a desk size. The list and the card share one screen, the card beside the list by
# default; ctrl-/ moves it under the list, then hides it, and an answer is given without
# leaving. Container only.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_shim
  # The panel under test needs the real fzf, not the fast tier's stub.
  ln -sf "${REAL_FZF:?no real fzf}" "$SANDBOX/bin/fzf"
  export QUESTIONS_ASK="$AGENT_ASK"

  OLD="$("$AGENT_ASK" post --project alpha --session agent-1 --options 'stacked=list on top, card below|side=list left, card right' 'Make stacked the default?')"
  MID="$("$AGENT_ASK" post --project beta --session agent-2 --options 'keep|drop' 'Keep the merge queue?')"
  NEW="$("$AGENT_ASK" post --project gamma --session agent-3 --options 'yes|no' 'Ship the map?')"
  sed -i 's/^created: .*/created: 2026-11-01T10:00:00-0800/' "$(ask_file "$OLD")"
  sed -i 's/^created: .*/created: 2026-11-03T10:00:00-0800/' "$(ask_file "$MID")"
}

teardown() { ui_teardown; }

ask_file() { find "$HOME/.agent/asks" -name "$1.md"; }
status_of() { sed -n 's/^status: //p' "$(ask_file "$1")"; }
open_panel() { tmux_start "$REPO_ROOT/.local/src/tmux/questions.sh"; }
# keep_screen <name>: the capture the PR body shows (dashboards.md rule 14).
keep_screen() { mkdir -p "$REPO_ROOT/tests/artifacts"; screen >"$REPO_ROOT/tests/artifacts/questions_$1.screen"; }

# side_by_side: the card's first line has list text and a border to its left. Stacked, the
# card line starts at the panel's own border.
side_by_side() { screen_matches '^│.+│ asking you'; }
# card_col: the screen column the card starts at (its border), ASCII-folded so awk counts columns.
card_col() { screen | sed 's/│/|/g' | awk '/\| asking you/ { print index($0, "| asking you"); exit }'; }

@test "at 80x24 the card opens beside the list, and the keys sit in the footer" {
  local t0; t0="$(date +%s%N)"
  TM_WIDTH=80 TM_HEIGHT=24 open_panel
  wait_until 'screen_has "list on top, card below"'
  echo "# first paint with the card: $((($(date +%s%N) - t0) / 1000000)) ms" >&3
  screen_has '3 waiting'
  screen_has '1-9 pick . enter send'
  side_by_side
  keep_screen side_80x24
}

@test "side by side the card takes most of the screen and a long question is not cut" {
  local long size w
  long="$("$AGENT_ASK" post --project delta --session agent-4 --options 'now=start the sweep before the nightly run|later=wait for the nightly run to finish first' 'The nightly sweep and the cache rebuild both want the runner pool tonight, so which one goes first and which one waits for the other to finish?')"
  sed -i 's/^created: .*/created: 2026-10-30T10:00:00-0800/' "$(ask_file "$long")"
  for size in 144x33 200x50; do
    w="${size%x*}"
    TM_WIDTH="$w" TM_HEIGHT="${size#*x}" open_panel
    wait_until 'side_by_side && screen_has "waits for the other to finish?"'
    screen_has 'wait for the nightly run to finish first'
    [ "$(card_col)" -le $((w * 40 / 100)) ] || { echo "card starts at col $(card_col) of $w"; false; }
    keep_screen "side_$size"
    close_panel
  done
}

# The card reads on one screen (human, 2026-11-05): a full story (a long request, a turn with a
# table and the ask repeated, a paragraph of context) still shows its last line beside the list.
@test "at 144x33 the whole card, story and all, fits beside the list" {
  mkdir -p "$HOME/.claude/projects/p" "$HOME/.agent/sessions/delta"
  : > "$HOME/.claude/projects/p/sid-u.jsonl"
  printf '{"session_id":"sid-u","title":"runner-pool-tonight"}\n' > "$HOME/.agent/sessions/delta/sessions.jsonl"
  jq -cn --arg req "$(printf 'please sort out the runner pool for tonight %.0s' $(seq 1 12))" '{first: $req, prompt: "which goes first?",
    said: ["| job | runner |\n|---|---|\n| sweep | pool |\n\nstep 1 done.\nstep 2 done.\nstep 3 done.\nstep 4 done.\nstep 5 done.\nstep 6 done.\nstep 7 done.\n\nSweep or rebuild first?\n\n1. sweep\n2. rebuild"]}' \
    > "$NOTES_FIXTURE/agent-panel.said"
  local id; id="$(CLAUDE_CODE_SESSION_ID=sid-u "$AGENT_ASK" post --project delta --session delta-agent-4 \
    --options 'sweep=start the sweep before the nightly run so the cache is warm by morning|rebuild=rebuild the cache first and let the sweep wait for the next window' \
    --recommend sweep --why 'the sweep is shorter and the rebuild can run on the spare runner after it' \
    --context 'Both jobs want the whole runner pool tonight. The sweep takes about forty minutes and the rebuild about two hours. Whichever waits starts after the other finishes, so the order decides which result is ready by morning.' \
    'Sweep or rebuild first?')"
  sed -i 's/^created: .*/created: 2026-10-30T10:00:00-0800/' "$(ask_file "$id")"
  TM_WIDTH=144 TM_HEIGHT=33 open_panel
  wait_until 'side_by_side && screen_has "it said"'
  keep_screen story_144x33
  screen_has 'step 6 done. ...'
  screen_lacks 'step 7'
  screen_lacks '| job'
  screen_has 'runner-pool-tonight: please sort out'
}

@test "ctrl-/ puts the card under the list, then hides it" {
  TM_WIDTH=200 TM_HEIGHT=50 open_panel
  wait_until 'side_by_side'
  keep_screen side_200x50
  tmux_keys C-/
  wait_until 'screen_has "list on top, card below" && ! side_by_side'
  run screen_matches 'Keep the merge queue\?.*│ Make stacked the default\?'
  assert_failure
  keep_screen stacked_200x50
  tmux_keys C-/
  wait_until 'screen_lacks "list on top, card below"'
  screen_has 'Make stacked the default?'
}

# close_panel: esc, and wait for the panel (the server's only pane) to exit.
close_panel() { tmux_keys Escape; wait_until '! _tm has-session 2>/dev/null'; tmux_stop; }

@test "the panel reopens in the layout ctrl-/ left it in, and hidden is never kept" {
  TM_WIDTH=200 TM_HEIGHT=50 open_panel
  wait_until 'side_by_side'
  tmux_keys C-/
  wait_until 'screen_has "list on top, card below" && ! side_by_side'
  close_panel
  [ "$(cat "$XDG_STATE_HOME/panels/questions.layout")" = stacked ]
  TM_WIDTH=200 TM_HEIGHT=50 open_panel
  wait_until 'screen_has "list on top, card below"'
  run side_by_side
  assert_failure
  keep_screen reopened_stacked_200x50
  # stacked -> side -> hidden: closed while hidden, it reopens side, the last one shown.
  tmux_keys C-/
  wait_until 'side_by_side'
  tmux_keys C-/
  wait_until 'screen_lacks "list on top, card below"'
  close_panel
  [ "$(cat "$XDG_STATE_HOME/panels/questions.layout")" = side ]
  TM_WIDTH=200 TM_HEIGHT=50 open_panel
  wait_until 'side_by_side'
}

@test "a number then enter answers in place: the row leaves and the count drops" {
  TM_WIDTH=80 TM_HEIGHT=24 open_panel
  wait_until 'screen_has "list on top, card below"'
  tmux_keys 1
  wait_until 'screen_has "send 1 \"stacked\""'
  keep_screen armed_80x24
  [ "$(status_of "$OLD")" = pending ]
  tmux_keys Enter
  wait_until 'screen_has "2 waiting" && screen_lacks "Make stacked the default?"'
  screen_has 'sent "stacked" to'
  [ "$(status_of "$OLD")" = answered ]
  grep -qx 'answer: stacked' "$(ask_file "$OLD")"
}

@test "a number then esc sends nothing and keeps the panel open" {
  TM_WIDTH=80 TM_HEIGHT=24 open_panel
  wait_until 'screen_has "list on top, card below"'
  tmux_keys 1
  wait_until 'screen_has "send 1"'
  tmux_keys Escape
  wait_until 'screen_has "1-9 pick . enter send"'
  screen_has '3 waiting'
  [ "$(status_of "$OLD")" = pending ]
}

@test "t types an answer on the same screen" {
  TM_WIDTH=80 TM_HEIGHT=24 open_panel
  wait_until 'screen_has "list on top, card below"'
  tmux_keys t
  wait_until "screen_has 'answering alpha:1:'"
  screen_matches '^│ answer> +│'
  keep_screen typing_80x24
  tmux_type 'both, stacked first'
  tmux_keys Enter
  wait_until 'screen_has "2 waiting"'
  grep -qx 'answer: both, stacked first' "$(ask_file "$OLD")"
}

@test "a second typed answer starts on an empty line, not the last one's text" {
  TM_WIDTH=80 TM_HEIGHT=24 open_panel
  wait_until 'screen_has "list on top, card below"'
  tmux_keys t
  wait_until "screen_has 'answering alpha:1'"
  tmux_type 'stacked'
  tmux_keys Enter
  wait_until 'screen_has "2 waiting" && screen_lacks "Make stacked the default?"'
  tmux_keys t
  wait_until "screen_has 'answering beta:2:'"
  screen_matches '^│ answer> +│'
  screen_lacks 'stacked'
  tmux_type 'keep'
  tmux_keys Enter
  wait_until 'screen_has "1 waiting" && screen_lacks "Keep the merge queue?"'
  grep -qx 'answer: keep' "$(ask_file "$MID")"
  # esc from typing puts the count back in the header.
  tmux_keys t
  wait_until "screen_has 'answering gamma:3'"
  tmux_keys Escape
  wait_until 'screen_has "1 waiting" && screen_lacks "answering"'
}

@test "g goes to the asking session and closes the panel" {
  sed -i 's/^claude_session: .*/claude_session: sid-old/' "$(ask_file "$OLD")"
  printf '%s\n' '{"session_id":"sid-old","target":"hub/alpha:3"}' >"$NOTES_FIXTURE/agent-panel.list"
  TM_WIDTH=80 TM_HEIGHT=24 open_panel
  wait_until 'screen_has "list on top, card below"'
  tmux_keys Down
  tmux_keys g
  wait_until 'screen_has "no Claude session owns"'
  tmux_keys Up
  tmux_keys g
  wait_until 'grep -qx "agent-panel jump hub/alpha:3" "$NOTES_FIXTURE/calls.log"'
  wait_until '! _tm has-session 2>/dev/null'
  [ "$(status_of "$OLD")" = pending ]
}
