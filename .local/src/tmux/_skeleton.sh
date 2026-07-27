#!/usr/bin/env bash
# _skeleton.sh - copy me to start a new panel. Everything below line 1 up to the first
# non-comment line IS the --help text, so write it for a reader.
#
# Usage: _skeleton.sh [verb]
#
# Verbs:
#   --list        the rows, TSV, one per line. The data behind the picker, split out so it
#                 is assertable without a terminal.
#   --help, -h    this text
#   (no verb)     open the picker
#
# This file is runnable. `_skeleton.sh --list` prints three rows; `_skeleton.sh` opens a real
# picker over them. That is deliberate -- a template you can execute is worth more than a doc
# nobody copies, and it means the conformance tier covers the template itself.

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

# Every tunable is ${VAR:-default}, right here at the top. No sourced sibling .conf, and
# never a $HOME/.dotfiles absolute path -- that breaks the moment the repo moves, and it
# makes the script untestable because a fixture cannot redirect it.
SKELETON_GREETING="${SKELETON_GREETING:-hello}"

# ── Rows ─────────────────────────────────────────────────────────────────────
# One row per line, TSV. Keep the machine-readable key columns first and the human-readable
# label last, so the picker can hide the former with --with-nth.
#
# THREE rows, not two. Anything ordered or cyclic needs three before a test can tell
# forwards from backwards -- with two they are the same operation, and seven direction
# assertions in this repo once passed while asserting nothing for exactly that reason.
cmd_list() {
  local i
  for i in one two three; do
    printf '%s\t%s%s %s%s\n' "$i" "$C_SEL" "$SKELETON_GREETING" "$i" "$C_OFF"
  done
}

# ── Picker ───────────────────────────────────────────────────────────────────
cmd_pick() {
  panel_need fzf

  panel_fzf_opts
  panel_fzf_table

  local picked
  # $SELF, never a bare script name and never $0: fzf re-invokes this script from inside the
  # picker, where $0 may be relative and PATH is whatever the tmux server had.
  picked="$(cmd_list | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" \
    --with-nth=2 \
    --prompt='skeleton > ' \
    --bind="ctrl-r:reload($(printf '%q' "$SELF") --list)" \
    "$(panel_fzf_preview right 40)" \
    --preview="printf 'row: %s' {1}" \
    | cut -f1)"

  [ -n "$picked" ] || return 0
  panel_warn "picked $picked"
}

# ── The test seam ────────────────────────────────────────────────────────────
# Sourced by the unit tier rather than run: every function gets defined and no verb executes.
#
# This ONE line stays copy-pasted in every panel and is deliberately not a library function:
# `return` has to run at the script's top-level scope, and wrapped in a function it would
# only exit that function. Keep it above the dispatch and below the definitions.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# ── Dispatch ─────────────────────────────────────────────────────────────────
# Always have a default arm that REJECTS. Two panels in this repo fall through to the picker
# on an unknown verb, which means a typo'd verb silently opens a UI instead of erroring -- and
# in a headless test it blocks forever rather than failing.
case "${1:-}" in
--list) cmd_list ;;
'') cmd_pick ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
