#!/usr/bin/env bats
# Tier 3: no agent closer kills the human's hub dotfiles session, on a REAL tmux server,
# container only. 2026-11-04 `agent-queue cancel` of an item hand-started in a hub:dotfiles
# window killed the session and every window in it. Each closer here runs the way it runs for
# real (wind-down arm then fire, agent-queue add --running then cancel) from a window of
# dotfiles, and must leave the session and its other windows alive. The integ tier pins the
# commands; this pins what tmux does with them.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  SRV=hub
  WD="$REPO_ROOT/.local/src/tmux/wind-down.sh"
  AQ="$REPO_ROOT/.local/bin/agent-queue"
  # The world manifests, where tmux-close reads them by default.
  mkdir -p "$HOME/.config" "$HOME/.dotfiles"
  ln -s "$REPO_ROOT/.config/tmux-servers" "$HOME/.config/tmux-servers"
  unset CLAUDE_CODE_SESSION_ID
  export CLAUDE_PROJECT_DIR="$HOME/.dotfiles"

  # hub as the human has it: the landing session, and dotfiles with a chat, the shepherd pass
  # and an agent window. Every window close signals channel closed, so a test waits on the
  # event, never on the clock.
  t new-session -d -s hub -n daily -c "$HOME"
  t set-hook -g window-unlinked 'wait-for -S closed'
  t new-session -d -s dotfiles -n chat -c "$HOME/.dotfiles"
  t new-window -d -t '=dotfiles:' -n shepherd -c "$HOME/.dotfiles"
  t new-window -d -t '=dotfiles:' -n agent -c "$HOME/.dotfiles"
  SOCK="$(t display-message -p -t '=hub:' '#{socket_path}')"
  SPID="$(t display-message -p -t '=hub:' '#{pid}')"
}

teardown() {
  tmux_kill_named "${SRV:-}"
  return 0
}

t() { "$REAL_TMUX" -L "$SRV" -f /dev/null "$@"; }
pane_of() { t display-message -p -t "=dotfiles:=$1" '#{pane_id}'; }
window_of() { t display-message -p -t "=dotfiles:=$1" '#{window_id}'; }
windows() { t list-windows -t '=dotfiles' -F '#{window_name}' 2>/dev/null | paste -sd' '; }
sessions() { t list-sessions -F '#{session_name}' 2>/dev/null | sort | paste -sd' '; }
# in_window <name> <cmd...>: run cmd as if typed in that window's pane.
in_window() { local p; p="$(pane_of "$1")"; shift; TMUX="$SOCK,$SPID,0" TMUX_PANE="$p" "$@"; }
# closed: block until a window has gone (the window-unlinked hook), 10s guard.
closed() { timeout 10 "$REAL_TMUX" -L "$SRV" wait-for closed || fail "no window closed"; }
# wind_down <window> [--session]: arm in that window, then fire as the Stop hook does.
wind_down() {
  local w="$1"; shift
  in_window "$w" bash "$WD" arm "$@" || fail "arm failed"
  # No session id, so the sentinel is keyed by project alone (CLAUDE_PROJECT_DIR's basename).
  in_window "$w" bash "$WD" fire "$HOME/.agent/spin-down/dotfiles.request" || fail "fire failed"
}

@test "closing the shepherd window closes that window only" {
  wind_down shepherd
  closed
  assert_equal "$(sessions)" 'dotfiles hub'
  assert_equal "$(windows)" 'chat agent'
}

@test "a session wind-down in a hub dotfiles window closes that window, not the session" {
  wind_down agent --session
  closed
  assert_equal "$(sessions)" 'dotfiles hub'
  assert_equal "$(windows)" 'chat shepherd'
}

@test "agent-queue cancel of an item recorded as hub:dotfiles closes its window only" {
  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n --arg r "$HOME/.dotfiles" '{paths: {($r): "dotfiles"}}' > "$AGENT_QUEUE_PROJECT_MAP"
  # A hand start from hub records none of this now; items written before that still do.
  "$AQ" add --project dotfiles --running --session hub:dotfiles --slug by-hand "hand-started in hub dotfiles"
  "$AQ" set by-hand "window=$(window_of agent)"
  # The canceller is another session, as it was on 2026-11-04.
  run "$AQ" cancel by-hand
  assert_success
  closed
  assert_equal "$(sessions)" 'dotfiles hub'
  assert_equal "$(windows)" 'chat shepherd'
}
