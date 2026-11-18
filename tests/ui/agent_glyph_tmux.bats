#!/usr/bin/env bats
# Tier 3: claude-status.sh copies each agent's live glyph onto its tmux window (project_glyphs),
# and .tmux.conf's @agent_fmt draws it on the window list, against a REAL tmux server under the
# sandbox's $TMUX_TMPDIR, inside the container and nowhere else (fleet_stage_tmux.bats pattern).
# project_glyphs calls plain `tmux`, so the server is the sandbox's own `default` socket.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  t new-session -d -s one
  t new-window -d -t '=one:'
  t new-window -d -t '=one:'
  # A glyph left on a window whose agent has gone, by an earlier refresh.
  t set-option -w -t '=one:2' @agent_glyph '~'
  # The repo's own format, not a copy.
  t set-option -g @agent_fmt "$(sed -n "s/^set -g @agent_fmt '\(.*\)'$/\1/p" "$REPO_ROOT/.tmux.conf")"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/src/tmux/claude-status.sh"
}

teardown() {
  tmux_kill_named default
  return 0
}

t() { "$REAL_TMUX" -L default -f /dev/null "$@"; }
# shown <window>: what @agent_fmt renders there, styles stripped.
shown() { t display-message -p -t "$1" '#{E:@agent_fmt}' | sed 's/#\[[^]]*\]//g'; }
# colour <window>: the fg colour @agent_fmt picks there.
colour() { t display-message -p -t "$1" '#{E:@agent_fmt}' | sed -n 's/^#\[fg=\([^]]*\)\].*/\1/p'; }

@test "a refresh puts each agent's glyph on its window, in its colour, and clears a window with none" {
  [ -n "$(t display-message -p '#{@agent_fmt}')" ] || fail "@agent_fmt not found in .tmux.conf"
  project_glyphs "$(printf 'default/one:0\t~\tp\ts\ndefault/one:1\t!\tp\ts\nelsewhere/one:2\t~\tp\ts\n')"
  assert_equal "$(t show-options -wv -t '=one:0' @agent_glyph)" '~'
  assert_equal "$(t show-options -wv -t '=one:1' @agent_glyph)" '!'
  assert_equal "$(t show-options -wqv -t '=one:2' @agent_glyph)" ''
  assert_equal "$(shown '=one:0')" '~'
  assert_equal "$(colour '=one:0')" colour214
  assert_equal "$(shown '=one:1')" '!'
  assert_equal "$(colour '=one:1')" colour203
  assert_equal "$(shown '=one:2')" ''
}

@test "an idle agent shows the check in green" {
  project_glyphs "$(printf 'default/one:0\t\342\234\223\tp\ts\n')"
  assert_equal "$(shown '=one:0')" "$(printf '\342\234\223')"
  assert_equal "$(colour '=one:0')" colour114
}
