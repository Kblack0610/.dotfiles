#!/bin/bash
SESSION="agent-run-$$" # Use process ID for a unique session name

tmux new-session -d -s $SESSION

# Pane 1: Main Agent
tmux send-keys -t $SESSION:0 "python main_agent.py --id=1" C-m

# Pane 2: Split horizontally for a worker
tmux split-window -h -t $SESSION:0
tmux send-keys -t $SESSION:0 "python worker_agent.py --id=2" C-m

# Pane 3: Split vertically for logging
tmux split-window -v -t $SESSION:0.0 # Target the first pane
tmux send-keys -t $SESSION:0 "tail -f logs/main.log" C-m

# Attach to the session
tmux attach-session -t $SESSION
