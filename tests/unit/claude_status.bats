#!/usr/bin/env bats
# claude-status.sh generates the tmux status-left string: the !n / ~n / checkmark-n / dot-n
# counts that tell you at a glance which agent windows need you. It classifies each Claude
# pane by grepping its last 15 lines, so every branch is drivable from canned pane content.
#
# This is the surface where a wrong answer is worst: a missed `!` means an agent sat blocked
# on a permission prompt while the status bar said everything was fine.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$STATUS_SH"
}

# pane <session> <idx> <cmd> -- register a pane in the fake `list-panes -a` output
pane() {
  printf '%s:%s:%s:%s:1234:/tmp\n' "$1" "$2" "win$2" "$3" >> "$NOTES_FIXTURE/tmux.panes"
}
# content <session> <idx> <text...> -- what capture-pane returns for that pane
content() {
  local s="$1" i="$2"; shift 2
  printf '%s\n' "$@" > "$NOTES_FIXTURE/tmux.capture.${s}_${i}"
}
# activity <session> <idx> <seconds-ago>
activity() {
  printf '%s' "$(( $(date +%s) - $3 ))" > "$NOTES_FIXTURE/tmux.activity.${1}_${2}"
}

# ── no Claude panes ──────────────────────────────────────────────────────────

@test "an empty pane list yields an empty status, not a stray glyph" {
  run get_session_status ""
  assert_success
  assert_output ''
}

@test "panes that are not claude are ignored entirely" {
  pane work 0 zsh
  pane work 1 nvim
  run get_session_status work
  assert_output ''
}

# ── attention: the branch that matters most ──────────────────────────────────

@test "a [y/N] prompt counts as needing attention" {
  pane work 0 claude
  content work 0 'Do you want to continue? [y/N]'
  activity work 0 60
  run get_session_status work
  assert_output '!1'
}

@test "a [Y/n] prompt counts as needing attention" {
  pane work 0 claude
  content work 0 'Proceed? [Y/n]'
  activity work 0 60
  run get_session_status work
  assert_output '!1'
}

@test "an Allow once permission prompt counts as needing attention" {
  pane work 0 claude
  content work 0 'Allow once' 'Allow always' 'Deny'
  activity work 0 60
  run get_session_status work
  assert_output '!1'
}

@test "a Do you want to prompt counts as needing attention" {
  pane work 0 claude
  content work 0 'Do you want to make this edit?'
  activity work 0 60
  run get_session_status work
  assert_output '!1'
}

@test "attention wins over working even when output is recent" {
  pane work 0 claude
  content work 0 'Do you want to continue? [y/N]'
  activity work 0 0          # actively outputting
  run get_session_status work
  assert_output '!1'
}

@test "multiple blocked panes are counted, not collapsed to one" {
  pane work 0 claude; content work 0 'Do you want to continue? [y/N]'; activity work 0 60
  pane work 1 claude; content work 1 'Allow once'                    ; activity work 1 60
  run get_session_status work
  assert_output '!2'
}

# ── working / idle ───────────────────────────────────────────────────────────

@test "recent output with no prompt counts as working" {
  pane work 0 claude
  content work 0 'writing the file...'
  activity work 0 0
  run get_session_status work
  assert_output '~1'
}

@test "a pane sitting at the prompt counts as idle" {
  pane work 0 claude
  content work 0 '> ' 'bypass permissions'
  activity work 0 60
  run get_session_status work
  assert_output --partial '1'
  refute_output --partial '!'
  refute_output --partial '~'
}

@test "attention outranks working when both are present" {
  pane work 0 claude; content work 0 'Do you want to continue? [y/N]'; activity work 0 60
  pane work 1 claude; content work 1 'writing...'                    ; activity work 1 0
  run get_session_status work
  assert_output '!1'
}

@test "working outranks idle when both are present" {
  pane work 0 claude; content work 0 'writing...'  ; activity work 0 0
  pane work 1 claude; content work 1 '> '          ; activity work 1 60
  run get_session_status work
  assert_output '~1'
}

# ── session scoping and window dedup ─────────────────────────────────────────

@test "status is scoped to the requested session" {
  pane alpha 0 claude; content alpha 0 'Do you want to continue? [y/N]'; activity alpha 0 60
  pane beta  0 claude; content beta  0 'writing...'                    ; activity beta  0 0
  run get_session_status alpha
  assert_output '!1'
  run get_session_status beta
  assert_output '~1'
}

@test "two panes in one window count once, not twice" {
  # Same session:window_index twice -- a split. seen_windows must dedup it.
  pane work 0 claude
  pane work 0 claude
  content work 0 'Do you want to continue? [y/N]'
  activity work 0 60
  run get_session_status work
  assert_output '!1'
}

@test "an empty target session counts every claude pane across sessions" {
  pane alpha 0 claude; content alpha 0 'Do you want to continue? [y/N]'; activity alpha 0 60
  pane beta  1 claude; content beta  1 'Allow once'                    ; activity beta  1 60
  run get_session_status ""
  assert_output '!2'
}

# ── get_short_name ───────────────────────────────────────────────────────────

@test "get_short_name maps the known sessions" {
  run get_short_name dotfiles;  assert_output 'dot'
  run get_short_name platform;  assert_output 'plt'
  run get_short_name hub;       assert_output 'hub'
  run get_short_name network;   assert_output 'net'
}

@test "get_short_name truncates an unknown session to three characters" {
  run get_short_name somethinglong
  assert_output 'som'
}

@test "get_short_name tolerates a short session name" {
  run get_short_name ab
  assert_output 'ab'
}

@test "get_short_name tolerates an empty session name" {
  run get_short_name ""
  assert_success
  assert_output ''
}
