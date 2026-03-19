#!/bin/bash

# Spawns an agent CLI in a new tmux window within a selected session
# Allows multiple agents per session

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

select_agent() {
    local default_agent="${DEFAULT_AGENT_CLI:-claude}"
    local options=()

    for agent in "$default_agent" claude codex opencode gemini aider; do
        [[ " ${options[*]} " == *" ${agent} "* ]] && continue
        command -v "$agent" >/dev/null 2>&1 || continue
        options+=("$agent")
    done

    [[ ${#options[@]} -eq 0 ]] && return 1

    printf '%s\n' "${options[@]}" | \
        fzf --reverse --border --prompt='Choose agent CLI > '
}

build_agent_command() {
    case "$1" in
        claude) echo "claude --dangerously-skip-permissions" ;;
        *) echo "$1" ;;
    esac
}

get_blacklist() {
    cat <<EOF
.git
node_modules
.venv
venv
__pycache__
build
dist
target
out
.next
.cache
.npm
.cargo
.pytest_cache
.idea
.vscode
.vs
.DS_Store
.tmp
.temp
EOF
}

# 1. Select from existing tmux sessions
SESSION=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | \
          fzf --reverse --border --prompt='Spawn agent in session > ')

# 2. Exit if cancelled
[[ -z "$SESSION" ]] && exit 0

# 3. Select target directory with blacklist
exclude_args=()
while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    exclude_args+=(-not -path "*/$pattern/*")
done < <(get_blacklist)

TARGET=$(find ~/dev -mindepth 1 -maxdepth 2 -type d "${exclude_args[@]}" 2>/dev/null | \
         fzf --reverse --border --prompt='Select directory > ')

# 4. Exit if cancelled
[[ -z "$TARGET" ]] && exit 0

# 4.5 Select which agent CLI to start
AGENT=$(select_agent)
[[ -z "$AGENT" ]] && exit 0

# 5. Setup Paths & Names
ROOT=$(cd "$TARGET" && pwd)
WINDOW_COUNT=$(tmux list-windows -t "$SESSION" 2>/dev/null | wc -l)
WINDOW_COUNT=$((WINDOW_COUNT + 1))
NAME="$(basename "$ROOT" | tr ' .:' '_')_${AGENT}_$WINDOW_COUNT"
AGENT_CMD=$(build_agent_command "$AGENT")

# 6. Create new window with the selected agent in the selected session
if [ -n "$TMUX" ]; then
    notify-send "Spawning $AGENT in $ROOT ($SESSION)" 2>/dev/null || true
    tmux new-window -t "$SESSION" -c "$ROOT" -n "$NAME" "$AGENT_CMD"
    tmux switch-client -t "$SESSION"
else
    echo "Not in a tmux session."
    exit 1
fi
