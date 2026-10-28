# shellcheck shell=bash
#
# _tmux_rename_window -- name this shell's tmux window after its git branch, else its dir.
# Sourced by ~/.zshrc, which runs it as a precmd hook so it updates after a checkout, not
# just a cd. Written to the bash/zsh common subset so the unit tier can source it as-is.
#
# No verb dispatch, so sourcing only defines the function and no
# `[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0` guard is needed.

_tmux_rename_window() {
    [[ -n "$TMUX" ]] || return
    # A window tmx declared (hub.conf's hub:infra) keeps its declared name.
    [[ -n "$(tmux show-options -wqv -t "$TMUX_PANE" @tmx_window 2>/dev/null)" ]] && return
    local name
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    else
        name=${PWD##*/}
    fi
    # -t: THIS shell's window. Without it tmux renames the session's active window, so a
    # background shell's prompt renamed whatever window you were looking at.
    tmux rename-window -t "$TMUX_PANE" "$name"
}
