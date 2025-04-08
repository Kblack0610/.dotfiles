#!/bin/bash
# fdf-history.sh - History management for Fuzzy Drunk Finder
# This module handles the history tracking functionality

# Function to add a directory to history
add_to_history() {
    local dir="$1"
    
    # Create the history file if it doesn't exist
    if [ ! -f "$HISTORY_FILE" ]; then
        mkdir -p "$(dirname "$HISTORY_FILE")"
        touch "$HISTORY_FILE"
    fi
    
    # Normalize the path by resolving any .. or . components
    dir=$(realpath -s "$dir")
    
    # Format the history entry with a timestamp
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local entry="$timestamp:$dir"
    
    # Remove any existing entries for this directory
    if [ -f "$HISTORY_FILE" ]; then
        grep -v ":$dir$" "$HISTORY_FILE" > "$HISTORY_FILE.tmp"
        mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
    fi
    
    # Add the new entry at the beginning
    echo "$entry" > "$HISTORY_FILE.tmp"
    cat "$HISTORY_FILE" >> "$HISTORY_FILE.tmp"
    mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
    
    # Keep only the most recent entries (limit to 100)
    if [ -f "$HISTORY_FILE" ]; then
        head -n 100 "$HISTORY_FILE" > "$HISTORY_FILE.tmp"
        mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
    fi
}

# Function to get context-specific history entries
get_context_history() {
    local current_dir="$1"
    
    # If history file doesn't exist, return empty
    if [ ! -f "$HISTORY_FILE" ]; then
        return
    fi
    
    # Get recent history entries, but exclude the current directory
    grep -v ":$current_dir$" "$HISTORY_FILE" | head -n 10 | sed 's/^[^:]*://'
}

# Function to clear history file
fdf_clear_history() {
    # Check if the history file exists
    if [ -f "$HISTORY_FILE" ]; then
        # Prompt for confirmation
        read -r -p "Are you sure you want to clear the history? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -f "$HISTORY_FILE"
            echo "History cleared."
        else
            echo "Operation cancelled."
        fi
    else
        echo "History file does not exist."
    fi
}
