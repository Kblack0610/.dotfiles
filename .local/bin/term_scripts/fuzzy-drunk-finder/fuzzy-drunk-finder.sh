#!/bin/bash

# Enhanced FZF directory navigation script
# Features:
# - Specify starting directory with parameter
# - Option to show hidden files with --hidden flag
# - Simple and fast directory navigation

# Function for enhanced directory navigation
enhanced_fzd() {
    # Default values
    local start_dir="$(pwd)"
    local show_hidden=false
    local depth=3
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hidden)
                show_hidden=true
                shift
                ;;
            --depth)
                if [[ "$2" =~ ^[0-9]+$ ]]; then
                    depth="$2"
                    shift 2
                else
                    echo "Error: --depth requires a number"
                    return 1
                fi
                ;;
            -*)
                echo "Unknown option: $1"
                echo "Usage: enhanced_fzd [--hidden] [--depth N] [directory]"
                return 1
                ;;
            *)
                # Assume it's a directory
                if [ -d "$1" ]; then
                    start_dir="$1"
                    shift
                else
                    echo "Error: '$1' is not a valid directory"
                    return 1
                fi
                ;;
        esac
    done
    
    # Go to the start directory
    cd "$start_dir" || return 1
    
    # Build the find command based on options
    local find_cmd
    if [ "$show_hidden" = true ]; then
        # Include hidden files/directories
        find_cmd="find . -type d -maxdepth $depth | sed 's|^\\./||'"
    else
        # Exclude hidden files/directories
        find_cmd="find . -type d -maxdepth $depth -not -path \"*/\\.*\" | sed 's|^\\./||'"
    fi
    
    # Execute the find command
    local dirs=$(eval "$find_cmd")
    
    # Use fzf to let user select a directory
    local selected=$(echo "$dirs" | fzf --height 40% --reverse \
        --header="Select directory to navigate to (from: $start_dir)" \
        --prompt="Directory > ")
    
    # If user selected a directory, navigate to it
    if [ -n "$selected" ]; then
        echo "Changing to directory: $selected"
        # Check if it's a relative or absolute path
        if [[ "$selected" == /* ]]; then
            cd "$selected" || return 1
        else
            cd "$start_dir/$selected" || return 1
        fi
        
        # Return success
        return 0
    fi
    
    # User cancelled, return to original directory
    return 0
}

# Create an easy-to-type alias
alias fzd="enhanced_fzd"

# Usage examples function
fzd_help() {
    echo "Enhanced FZD - Simple Directory Navigation"
    echo ""
    echo "Usage:"
    echo "  enhanced_fzd [--hidden] [--depth N] [directory]"
    echo ""
    echo "Options:"
    echo "  --hidden     Include hidden directories in the search"
    echo "  --depth N    Set search depth (default: 3)"
    echo "  directory    Starting directory (default: current directory)"
    echo ""
    echo "Examples:"
    echo "  enhanced_fzd                         # Navigate from current directory"
    echo "  enhanced_fzd --hidden                # Include hidden directories"
    echo "  enhanced_fzd --depth 5               # Search 5 levels deep"
    echo "  enhanced_fzd /home                   # Start from /home"
    echo "  enhanced_fzd --hidden --depth 2 ~    # Navigate from home, show hidden, depth 2"
    echo ""
    echo "Note: This script must be sourced, not executed."
    echo "Please run: source enhanced_fzd.sh or . enhanced_fzd.sh"
}

# Execute the function immediately when sourced with any provided arguments
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced
    echo "Enhanced FZD loaded. Type 'fzd' to use or 'fzd_help' for help."
else
    # Script is being executed directly
    echo "⚠️  This script must be sourced, not executed."
    echo "Please run: source $(basename "${BASH_SOURCE[0]}") or . $(basename "${BASH_SOURCE[0]}")"
    exit 1
fi
