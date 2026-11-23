# shellcheck shell=bash
# tmux-pane.sh - what every script that types keys into an existing tmux pane runs first.
# Sourced by claude-acct, servers.sh (tmx) and editor.sh.

# leave_mode <server> <pane> -- take the pane out of any tmux mode before keys are typed into
# it; fails if it is still in one. Copy and view mode read typed keys as mode commands (`:` opens
# a goto-line prompt that send-keys blocks on, which froze `tmx root`), and the session picker
# (choose-tree) acts on them: its x then y kill a session. A failed run-shell leaves its error in
# view mode on the active pane. `copy-mode -q` cancels every mode, and does nothing to a pane in
# none. Left means a read 0: #{pane_in_mode} counts the stacked modes (tree mode over copy mode
# reads 2, ar-3942), and a pane it cannot read is not known to be out of one. An empty <server> is
# the one this script runs under.
leave_mode() {
  tmux ${1:+-L "$1"} copy-mode -q -t "$2" 2>/dev/null
  [[ "$(tmux ${1:+-L "$1"} display-message -p -t "$2" '#{pane_in_mode}' 2>/dev/null)" == 0 ]]
}
