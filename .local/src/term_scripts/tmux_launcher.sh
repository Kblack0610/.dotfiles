#!/bin/bash

# Master launcher - unified menu for all tmux session management
# Replaces the need to remember multiple scripts

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Menu options
OPTIONS="Spawn Project (new session with nvim)
Spawn Agent (claude in directory)
Open nvim (repo root in current session)
Select Session (existing tmuxinator configs)
Switch Session (existing tmux sessions)
---
Spawn Server (api + web dev servers)"

# 1. Show menu
CHOICE=$(echo "$OPTIONS" | fzf --reverse --border --prompt='Tmux Launcher > ' --height=40%)

# 2. Exit if cancelled
[[ -z "$CHOICE" ]] && exit 0

# 3. Execute based on choice
case "$CHOICE" in
    "Spawn Project"*)
        exec "$SCRIPT_DIR/tmux_spawn_project.sh"
        ;;
    "Spawn Server"*)
        exec "$SCRIPT_DIR/tmux_spawn_server.sh"
        ;;
    "Spawn Agent"*)
        exec "$SCRIPT_DIR/tmux_agent_starter.sh"
        ;;
    "Open nvim"*)
        exec "$SCRIPT_DIR/tmux_nvim_spawner.sh"
        ;;
    "Select Session"*)
        exec "$SCRIPT_DIR/tmux_session_starter.sh"
        ;;
    "Switch Session"*)
        # Quick switch between existing tmux sessions
        SESSION=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | \
                  fzf --reverse --border --prompt='Switch to > ')
        [[ -z "$SESSION" ]] && exit 0
        if [ -n "$TMUX" ]; then
            tmux switch-client -t "$SESSION"
        else
            tmux attach-session -t "$SESSION"
        fi
        ;;
esac
