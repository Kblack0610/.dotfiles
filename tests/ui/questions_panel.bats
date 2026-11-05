#!/usr/bin/env bats
# Tier 3: Prefix y, the questions panel, through real fzf on a real tmux server at a laptop
# size and a desk size. The list and the card share one screen, ctrl-/ moves the card beside
# the list and then hides it, and an answer is given without leaving. Container only.

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

@test "at 80x24 the list sits on top, the card below, and the keys in the footer" {
  local t0; t0="$(date +%s%N)"
  TM_WIDTH=80 TM_HEIGHT=24 open_panel
  wait_until 'screen_has "list on top, card below"'
  echo "# first paint with the card: $((($(date +%s%N) - t0) / 1000000)) ms" >&3
  screen_has '3 waiting'
  screen_has 'Make stacked the default?'
  screen_has 'Ship the map?'
  screen_has '1-9 pick . enter send'
  # Stacked: no row has the card beside it.
  run screen_matches 'Keep the merge queue\?.*│ Make stacked the default\?'
  assert_failure
  keep_screen stacked_80x24
}

@test "ctrl-/ puts the card beside the list, then hides it" {
  TM_WIDTH=200 TM_HEIGHT=50 open_panel
  wait_until 'screen_has "list on top, card below"'
  keep_screen stacked_200x50
  tmux_keys C-/
  wait_until 'screen_matches "Keep the merge queue\?.*│ Make stacked the default\?"'
  keep_screen side_200x50
  tmux_keys C-/
  wait_until 'screen_lacks "list on top, card below"'
  screen_has 'Make stacked the default?'
}

# close_panel: esc, and wait for the panel (the server's only pane) to exit.
close_panel() { tmux_keys Escape; wait_until '! _tm has-session 2>/dev/null'; tmux_stop; }

@test "the panel reopens in the layout ctrl-/ left it in, and hidden is never kept" {
  TM_WIDTH=200 TM_HEIGHT=50 open_panel
  wait_until 'screen_has "list on top, card below"'
  tmux_keys C-/
  wait_until 'screen_matches "Keep the merge queue\?.*│ Make stacked the default\?"'
  close_panel
  [ "$(cat "$XDG_STATE_HOME/panels/questions.layout")" = side ]
  TM_WIDTH=200 TM_HEIGHT=50 open_panel
  wait_until 'screen_matches "Keep the merge queue\?.*│ Make stacked the default\?"'
  keep_screen reopened_side_200x50
  # side -> stacked -> hidden: closed while hidden, it reopens stacked, the last one shown.
  tmux_keys C-/
  wait_until 'screen_has "list on top, card below" && ! screen_matches "Keep the merge queue\?.*│ Make stacked"'
  tmux_keys C-/
  wait_until 'screen_lacks "list on top, card below"'
  close_panel
  [ "$(cat "$XDG_STATE_HOME/panels/questions.layout")" = stacked ]
  TM_WIDTH=200 TM_HEIGHT=50 open_panel
  wait_until 'screen_has "list on top, card below"'
  run screen_matches 'Keep the merge queue\?.*│ Make stacked the default\?'
  assert_failure
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
  screen_has 'sent "stacked" to agent-1'
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
  wait_until "screen_has 'answer $OLD>'"
  tmux_type 'both, stacked first'
  tmux_keys Enter
  wait_until 'screen_has "2 waiting"'
  grep -qx 'answer: both, stacked first' "$(ask_file "$OLD")"
}
