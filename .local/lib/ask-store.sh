# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# ask-store.sh - where agent-ask keeps its asks, and whether one is still open.
#
#   ask_root            the store: $AGENT_ASK_ROOT, else ~/.agent/asks (one <project>/<id>.md per ask)
#   ask_open <file>     0 when the ask is still open (`status: pending`), parked or not
#   ask_open_files      the open ones of the ask files named on stdin, one a line, in one grep;
#                       always 0, since an empty list and a missing file just mean none open
#
# Pending for the human (the Needs you count, `agent-ask list --pending`) is open and not parked:
# agent-ask is_parked. A reader asking only whether an ask is still filed (a session's own ask, a
# reopen on its answer) wants ask_open, since a parked ask is still filed and still gets an answer.
# agent-core asks.rs `root` is the Rust twin of ask_root.

ask_root() { printf '%s\n' "${AGENT_ASK_ROOT:-$HOME/.agent/asks}"; }

ASK_OPEN_LINE='status: pending'

ask_open() { grep -qxF "$ASK_OPEN_LINE" "$1" 2>/dev/null; }

ask_open_files() { xargs -r -d '\n' grep -lxF "$ASK_OPEN_LINE" 2>/dev/null; return 0; }
