#!/bin/bash

# Interactive cleanup workflow for stale tmux windows
# Shows stale windows in fzf, confirms before deletion, saves history

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$SCRIPT_DIR/tmux-manager.conf"

# Load config if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Defaults
AUTO_SAVE_HISTORY="${AUTO_SAVE_HISTORY:-1}"
STALE_THRESHOLD="${STALE_THRESHOLD:-900}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get stale windows
STALE_OUTPUT=$("$SCRIPT_DIR/stale-detector.sh" --json)
STALE_COUNT=$(echo "$STALE_OUTPUT" | grep -c '"session"')

if [[ $STALE_COUNT -eq 0 ]]; then
    echo -e "${GREEN}No stale windows found${NC}"
    echo ""
    echo -e "Threshold: $((STALE_THRESHOLD / 60)) minutes"
    echo ""
    read -n 1 -s -r -p "Press any key to exit..."
    exit 0
fi

echo -e "${YELLOW}Found $STALE_COUNT stale window(s)${NC}"
echo ""

# Build fzf input
FZF_INPUT=""
while IFS= read -r line; do
    session=$(echo "$line" | sed -n 's/.*"session": "\([^"]*\)".*/\1/p')
    window_idx=$(echo "$line" | sed -n 's/.*"window_index": \([0-9]*\).*/\1/p')
    window_name=$(echo "$line" | sed -n 's/.*"window_name": "\([^"]*\)".*/\1/p')
    idle_fmt=$(echo "$line" | sed -n 's/.*"idle_formatted": "\([^"]*\)".*/\1/p')
    path=$(echo "$line" | sed -n 's/.*"path": "\([^"]*\)".*/\1/p')

    [[ -z "$session" ]] && continue

    # Format: session:idx  window_name  idle_time  path
    short_path=$(basename "$path")
    FZF_INPUT+="${session}:${window_idx}\t${window_name}\t${idle_fmt}\t${short_path}\n"
done <<< "$(echo "$STALE_OUTPUT" | grep -E '"session"|"window_index"|"window_name"|"idle_formatted"|"path"' | paste - - - - -)"

# Preview function - show last 20 lines of window
preview_cmd="tmux capture-pane -t {1} -p -S -20 2>/dev/null || echo 'Unable to capture'"

# Run fzf with multi-select
SELECTED=$(echo -e "$FZF_INPUT" | column -t -s $'\t' | \
    fzf --multi --reverse --border \
        --prompt='Select windows to clean > ' \
        --header=$'Tab=select  Enter=confirm  Esc=cancel\n─────────────────────────────────────────' \
        --preview="$preview_cmd" \
        --preview-window=right:50%:wrap \
        --ansi)

if [[ -z "$SELECTED" ]]; then
    echo "Cancelled"
    exit 0
fi

# Parse selections
TARGETS=()
while IFS= read -r line; do
    target=$(echo "$line" | awk '{print $1}')
    [[ -n "$target" ]] && TARGETS+=("$target")
done <<< "$SELECTED"

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "No windows selected"
    exit 0
fi

# Confirmation
echo ""
echo -e "${YELLOW}Selected ${#TARGETS[@]} window(s) for cleanup:${NC}"
for target in "${TARGETS[@]}"; do
    echo "  - $target"
done
echo ""

if [[ $AUTO_SAVE_HISTORY -eq 1 ]]; then
    echo -e "${CYAN}History will be saved before deletion${NC}"
fi
echo ""

read -p "Proceed? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 0
fi

echo ""

# Process each target
SAVED_FILES=()
KILLED=0

for target in "${TARGETS[@]}"; do
    echo -e "Processing ${CYAN}$target${NC}..."

    # Save history if enabled
    if [[ $AUTO_SAVE_HISTORY -eq 1 ]]; then
        saved_path=$("$SCRIPT_DIR/history-capture.sh" "$target" --quiet 2>/dev/null | tail -1)
        if [[ -n "$saved_path" && -f "$saved_path" ]]; then
            SAVED_FILES+=("$saved_path")
            echo -e "  ${GREEN}Saved:${NC} $(basename "$saved_path")"
        else
            echo -e "  ${YELLOW}Warning: Could not save history${NC}"
        fi
    fi

    # Kill window
    if tmux kill-window -t "$target" 2>/dev/null; then
        echo -e "  ${GREEN}Killed${NC}"
        ((KILLED++))
    else
        echo -e "  ${RED}Failed to kill${NC}"
    fi
done

# Summary
echo ""
echo -e "${GREEN}═══ Summary ═══${NC}"
echo -e "Cleaned: ${KILLED}/${#TARGETS[@]} windows"

if [[ ${#SAVED_FILES[@]} -gt 0 ]]; then
    echo -e "History saved to:"
    for f in "${SAVED_FILES[@]}"; do
        echo "  $f"
    done
fi

echo ""
read -n 1 -s -r -p "Press any key to exit..."
