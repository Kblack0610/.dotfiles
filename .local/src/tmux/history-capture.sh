#!/bin/bash

# Captures full scrollback buffer from a tmux window
# Usage: history-capture.sh [session:window] [--quiet]
#
# If no target specified, captures current window
# Returns the path to the saved file

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$SCRIPT_DIR/tmux-manager.conf"

# Load config if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Defaults
HISTORY_DIR="${HISTORY_DIR:-$HOME/.local/share/tmux-history}"
QUIET=0

# Parse args
TARGET=""
for arg in "$@"; do
    case "$arg" in
        --quiet|-q)
            QUIET=1
            ;;
        *)
            TARGET="$arg"
            ;;
    esac
done

# If no target, use current window
if [[ -z "$TARGET" ]]; then
    if [[ -n "$TMUX" ]]; then
        TARGET=$(tmux display-message -p '#{session_name}:#{window_index}')
    else
        echo "Error: No target specified and not in tmux session" >&2
        exit 1
    fi
fi

# Parse session:window
SESSION=$(echo "$TARGET" | cut -d: -f1)
WINDOW_IDX=$(echo "$TARGET" | cut -d: -f2)

# Validate target exists
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Error: Session '$SESSION' not found" >&2
    exit 1
fi

if ! tmux list-windows -t "$SESSION" -F "#{window_index}" | grep -q "^${WINDOW_IDX}$"; then
    echo "Error: Window '$WINDOW_IDX' not found in session '$SESSION'" >&2
    exit 1
fi

# Get window metadata
WINDOW_NAME=$(tmux display-message -t "$TARGET" -p "#{window_name}" 2>/dev/null)
PANE_PATH=$(tmux display-message -t "$TARGET" -p "#{pane_current_path}" 2>/dev/null)
PANE_CMD=$(tmux display-message -t "$TARGET" -p "#{pane_current_command}" 2>/dev/null)
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
ISO_TIMESTAMP=$(date -Iseconds)

# Create save directory
SAVE_DIR="$HISTORY_DIR/$SESSION"
mkdir -p "$SAVE_DIR"

# Sanitize window name for filename
SAFE_NAME=$(echo "$WINDOW_NAME" | tr -c '[:alnum:]-_' '_' | sed 's/_*$//')
FILENAME="${WINDOW_IDX}_${SAFE_NAME}_${TIMESTAMP}.log"
FILEPATH="$SAVE_DIR/$FILENAME"

# Capture scrollback with metadata header
{
    echo "# ═══════════════════════════════════════════════════════════════════"
    echo "# Tmux History Capture"
    echo "# ═══════════════════════════════════════════════════════════════════"
    echo "# Session:   $SESSION"
    echo "# Window:    $WINDOW_IDX ($WINDOW_NAME)"
    echo "# Command:   $PANE_CMD"
    echo "# Path:      $PANE_PATH"
    echo "# Captured:  $ISO_TIMESTAMP"
    echo "# ═══════════════════════════════════════════════════════════════════"
    echo ""
    # -S - = start of history, -E - = end of history (full buffer)
    tmux capture-pane -t "$TARGET" -p -S - -E -
} > "$FILEPATH"

# Count lines (excluding header)
LINE_COUNT=$(tail -n +11 "$FILEPATH" | wc -l)

# Add line count to header (sed in place)
sed -i "8a# Lines:     $LINE_COUNT" "$FILEPATH"

if [[ $QUIET -eq 0 ]]; then
    echo "Saved: $FILEPATH ($LINE_COUNT lines)"
fi

# Output just the path (for scripting)
echo "$FILEPATH"
