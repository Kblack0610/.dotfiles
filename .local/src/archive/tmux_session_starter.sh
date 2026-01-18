#!/bin/bash

# Ensure we can find user installed binaries (cargo, brew, etc)
export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# 1. Select project
PROJECT=$(find -L ~/.config/tmuxinator -name "*.yml" | xargs -n 1 basename -s .yml | fzf --reverse --border --prompt='Select Project > ')

# 2. Exit if cancelled
[[ -z "$PROJECT" ]] && exit 0

# 3. Switch or Start
# If we are in tmux, tell tmuxinator to switch the client, not attach inside the popup
if [ -n "$TMUX" ]; then
    tmuxinator start "$PROJECT" --no-attach
    # Manually switch to the session tmuxinator just created
    tmux switch-client -t "$PROJECT"
else
    tmuxinator start "$PROJECT"
fi
