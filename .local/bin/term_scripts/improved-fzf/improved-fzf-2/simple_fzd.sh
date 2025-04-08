#!/bin/bash

# Simple improved fzf script with directory navigation
# This is a simplified version focusing on directory navigation

# Function for directory navigation
simple_fzd() {
    # Directory to start search from
    start_dir="$(pwd)"
    
    # Find directories up to depth 3
    dirs=$(find . -type d -maxdepth 3 -not -path "*/\.*" | sed 's|^\./||')
    
    # Use fzf to let user select a directory
    selected=$(echo "$dirs" | fzf --height 40% --reverse --header="Select directory to navigate to:" --prompt="Directory > ")
    
    # If user selected a directory, navigate to it
    if [ -n "$selected" ]; then
        echo "Changing to directory: $selected"
        cd "$selected"
    fi
}

# Execute the function immediately when sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced, run the function
    simple_fzd
else
    # Script is being executed directly
    echo "This script must be sourced, not executed."
    echo "Please run: source $(basename "${BASH_SOURCE[0]}") or . $(basename "${BASH_SOURCE[0]}")"
    exit 1
fi
