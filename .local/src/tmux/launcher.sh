#!/bin/bash

# Master launcher - unified menu for all tmux session management
# Replaces the need to remember multiple scripts

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Menu options
OPTIONS="Spawn Project (new session with nvim)
Spawn Agent (claude in directory)
Open nvim (repo root in current session)
Select Session (smug configs)
Switch Session (existing tmux sessions)
---
Session Dashboard (view all sessions)
Cleanup Stale Windows (remove idle agents)
Save Window History (capture scrollback)
---
Spawn Server (api + web dev servers)"

# 1. Show menu
CHOICE=$(echo "$OPTIONS" | fzf --reverse --border --prompt='Tmux Launcher > ' --height=40%)

# 2. Exit if cancelled
[[ -z "$CHOICE" ]] && exit 0

# 3. Execute based on choice
case "$CHOICE" in
    "Spawn Project"*)
        exec "$SCRIPT_DIR/spawn-project.sh"
        ;;
    "Spawn Server"*)
        exec "$SCRIPT_DIR/../archive/tmux_spawn_server.sh"
        ;;
    "Spawn Agent"*)
        exec "$SCRIPT_DIR/agent-starter.sh"
        ;;
    "Open nvim"*)
        exec "$SCRIPT_DIR/../archive/tmux_nvim_spawner.sh"
        ;;
    "Select Session"*)
        # Select from smug configs
        PROJECT=$(smug list | fzf --reverse --border --prompt='Select Project > ')
        [[ -z "$PROJECT" ]] && exit 0
        if [ -n "$TMUX" ]; then
            smug start "$PROJECT" --detach
            tmux switch-client -t "$PROJECT"
        else
            smug start "$PROJECT"
        fi
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
    "Session Dashboard"*)
        exec "$SCRIPT_DIR/dashboard.sh"
        ;;
    "Cleanup Stale"*)
        exec "$SCRIPT_DIR/cleanup.sh"
        ;;
    "Save Window History"*)
        # Capture current window's scrollback
        RESULT=$("$SCRIPT_DIR/history-capture.sh")
        echo "$RESULT"
        read -n 1 -s -r -p "Press any key to exit..."
        ;;
esac
