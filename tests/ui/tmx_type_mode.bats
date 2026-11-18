#!/usr/bin/env bats
# Tier 3: servers.sh _type, which every keystroke tmx types into a pane that already exists
# goes through, against a REAL tmux server under the sandbox's $TMUX_TMPDIR, inside the
# container and nowhere else (agent_glyph_tmux.bats pattern).
#
# The bug: a failed run-shell left the hub pane in view mode, whose vi key table binds `:` to a
# goto-line command-prompt. `tmx root hub` typed `:e <daily>` into it and send-keys blocked on
# that prompt with no one to answer it, so the terminal froze.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  t new-session -d -s one
  t set-option -g mode-keys vi
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/src/tmux/servers.sh"
}

teardown() {
  tmux_kill_named w
  return 0
}

t() { "$REAL_TMUX" -L w -f /dev/null "$@"; }
in_mode() { t display-message -p -t '=one:' '#{pane_in_mode}'; }

@test "keys typed into a pane in copy mode reach the program, and do not hang on a prompt" {
  t copy-mode -t '=one:'
  assert_equal "$(in_mode)" 1
  # Bounded, since the failure is a hang: a subshell, as timeout cannot run a function.
  run timeout 5 bash -c "source '$REPO_ROOT/.local/src/tmux/servers.sh'; _type w '=one:' ':' Enter"
  assert_success
  assert_equal "$(in_mode)" 0
}

@test "a pane in no mode is not put into copy mode by _type" {
  _type w '=one:' 'true' Enter
  assert_equal "$(in_mode)" 0
}
