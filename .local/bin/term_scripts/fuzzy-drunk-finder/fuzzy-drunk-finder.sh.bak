#!/bin/bash

# Fuzzy Drunk Finder - Directory Navigation Script
# Features:
# - Specify starting directory with parameter
# - Option to show hidden files with --hidden flag
# - Simple and fast directory navigation
# - History tracking to prioritize frequently visited directories
# - Context-aware history based on your current location
# - Caching for faster startup in large directories

# Configuration
HISTORY_FILE="$HOME/.fdf_history"
MAX_HISTORY_ENTRIES=1000
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CACHE_DIR="$SCRIPT_DIR/.fdf_cache"
CACHE_TIMEOUT=3600  # Cache timeout in seconds (1 hour)

# Create necessary directories and files
if [ ! -f "$HISTORY_FILE" ]; then
    touch "$HISTORY_FILE"
    chmod 600 "$HISTORY_FILE"  # Secure permissions
fi

# Create cache directory
if [ ! -d "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"  # Secure permissions
fi

# Function to add a directory to history with context
add_to_history() {
    local from_dir="$1"
    local visited_dir="$2"
    
    # Only add valid entries with both from and to directories
    if [ -n "$visited_dir" ] && [ -n "$from_dir" ]; then
        echo "$from_dir:$visited_dir" >> "$HISTORY_FILE"
        
        # Limit history file entries to MAX_HISTORY_ENTRIES
        if [ -f "$HISTORY_FILE" ]; then
            local line_count=$(wc -l < "$HISTORY_FILE")
            if [ "$line_count" -gt "$MAX_HISTORY_ENTRIES" ]; then
                # Keep only the last MAX_HISTORY_ENTRIES lines
                tail -n "$MAX_HISTORY_ENTRIES" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
                mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
            fi
        fi
    fi
}

# Function to create a unique cache key for a directory search
get_cache_key() {
    local dir="$1"
    local hidden="$2"
    local depth="$3"
    local unlimited="$4"
    
    # Create a unique hash based on the directory path, hidden flag, depth, and unlimited flag
    # This ensures different search parameters get different cache files
    echo "$dir-$hidden-$depth-$unlimited" | md5sum | cut -d' ' -f1
}

# Function to get directories with caching
get_directories() {
    local dir="$1"
    local hidden="$2"
    local depth="$3"
    local unlimited="$4"
    local debug_mode="$5"  # Pass in debug_mode as a parameter
    
    # Create a unique cache key
    local cache_key=$(get_cache_key "$dir" "$hidden" "$depth" "$unlimited")
    local cache_file="$CACHE_DIR/$cache_key"
    
    # Ensure cache directory exists
    mkdir -p "$CACHE_DIR"
    
    # Check if we have a valid cache file and it's not too old
    if [ -f "$cache_file" ] && [ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt "$CACHE_TIMEOUT" ]; then
        if [ "$debug_mode" = true ]; then
            echo "Debug: Using cached directory list from $cache_file" >&2
            # Count the number of entries in the cache file
            local cache_entries=$(wc -l < "$cache_file")
            echo "Debug: Cache contains $cache_entries entries" >&2
        fi
        cat "$cache_file"
        return
    fi
    
    if [ "$debug_mode" = true ]; then
        echo "Debug: Building fresh directory list for $dir (hidden=$hidden, depth=$depth, unlimited=$unlimited)" >&2
    fi
    
    # For unlimited depth in very large directories, we need a pragmatic approach
    # to avoid hanging - limit to a reasonable max depth
    local max_depth_limit=7
    local actual_depth="$depth"
    
    if [ "$unlimited" = true ]; then
        actual_depth="$max_depth_limit"
    fi
    
    # Create a temporary file for the results
    local temp_results=$(mktemp)
    
    # Change to the directory to use relative paths in find
    # This avoids issues with special characters in path names
    (
        cd "$dir" 2>/dev/null || { 
            echo "Error: Cannot access directory $dir" >&2
            exit 1
        }
        
        # Run the appropriate find command based on hidden flag
        if [ "$hidden" = true ]; then
            # Include hidden directories
            if [ "$debug_mode" = true ]; then
                echo "Debug: Running find command with hidden=true, depth=$actual_depth" >&2
            fi
            # Use -L to follow symlinks for more complete results
            find -L . -maxdepth "$actual_depth" -type d 2>/dev/null | sed 's|^./||'
        else
            # Exclude hidden directories
            if [ "$debug_mode" = true ]; then
                echo "Debug: Running find command with hidden=false, depth=$actual_depth" >&2
            fi
            find -L . -maxdepth "$actual_depth" -type d -not -path "*/\.*" 2>/dev/null | sed 's|^./||'
        fi
    ) > "$temp_results"
    
    # Count the results for debugging
    if [ "$debug_mode" = true ]; then
        local result_count=$(wc -l < "$temp_results")
        echo "Debug: Found $result_count directories" >&2
    fi
    
    # Move the temp file to the cache location
    mv "$temp_results" "$cache_file"
    
    # Return the results
    cat "$cache_file"
}

# Function to get context-specific history entries
get_context_history() {
    local current_dir="$1"
    if [ -f "$HISTORY_FILE" ]; then
        # Find directories visited from this location
        grep "^$current_dir:" "$HISTORY_FILE" | 
        sed "s|^$current_dir:||" | 
        sort | uniq -c | sort -nr | 
        sed 's/^ *[0-9]* *//' | 
        grep -v '^$'
    fi
}

# Function for fuzzy directory navigation
fdf() {
    # Parse options and set defaults
    local show_hidden=false
    local depth=3
    local unlimited=false
    local use_history=true
    local debug_mode=false
    local test_mode=false
    local search_term=""
    local force_rebuild_cache=false
    
    # Original directory - store this BEFORE any directory changes
    local from_dir="$(pwd)"
    
    # Process arguments
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --hidden)
                show_hidden=true
                shift
                ;;
            --depth)
                depth="$2"
                shift 2
                ;;
            --unlimited)
                unlimited=true
                shift
                ;;
            --no-history)
                use_history=false
                shift
                ;;
            --debug)
                debug_mode=true
                shift
                ;;
            --rebuild-cache)
                force_rebuild_cache=true
                shift
                ;;
            --search)
                test_mode=true
                if [ "$#" -gt 1 ] && [ "${2:0:1}" != "-" ]; then
                    search_term="$2"
                    shift
                fi
                shift
                ;;
            *)
                # Last argument is the directory
                start_dir="$1"
                shift
                ;;
        esac
    done

    # Set the target directory for search to the current directory if not specified
    local start_dir="${start_dir:-$(pwd)}"
    
    # Ensure the directory exists and is accessible
    if [ ! -d "$start_dir" ]; then
        echo "Error: Directory '$start_dir' does not exist or is not accessible."
        return 1
    fi
    
    # Debug information
    if [ "$debug_mode" = true ]; then
        echo "Debug: Current directory: $from_dir"
        echo "Debug: Target search directory: $start_dir"
        echo "Debug: Show hidden: $show_hidden"
        echo "Debug: Depth: $depth (effective: $([ "$unlimited" = true ] && echo "unlimited" || echo "$depth"))"
        echo "Debug: Unlimited: $unlimited"
    fi
    
    # For very large directories like /home/username, limit the depth
    # even with --unlimited to prevent hanging
    local max_depth=7
    local effective_depth="$depth"
    
    # If in a home directory with unlimited depth, show a notice but keep unlimited=true
    if [[ "$start_dir" =~ ^/home/.* ]] && [ "$unlimited" = true ]; then
        effective_depth="$max_depth"
        echo "Notice: Using maximum depth of $max_depth for home directory to prevent system hang"
    fi
    
    # If force_rebuild_cache is set, remove any existing cache for this configuration
    if [ "$force_rebuild_cache" = true ] && [ "$debug_mode" = true ]; then
        local cache_key=$(get_cache_key "$start_dir" "$show_hidden" "$effective_depth" "$unlimited")
        local cache_file="$CACHE_DIR/$cache_key"
        if [ -f "$cache_file" ]; then
            echo "Debug: Forcing cache rebuild, removing $cache_file" >&2
            rm -f "$cache_file"
        fi
    fi
    
    # Get directories with caching
    # Pass all needed parameters including debug_mode
    local dirs=$(get_directories "$start_dir" "$show_hidden" "$effective_depth" "$unlimited" "$debug_mode")
    
    # Create temporary files
    local tmp_dirs=$(mktemp)
    local tmp_history=$(mktemp)
    
    # Get history entries for the current directory
    local history_entries=""
    local history_count=0
    if [ "$use_history" = true ]; then
        history_entries=$(get_context_history "$from_dir")
        # Create temporary file for history
        cat /dev/null > "$tmp_history"
        if [ -n "$history_entries" ]; then
            # Process history entries
            while IFS= read -r hentry; do
                if [ -n "$hentry" ]; then
                    if [ -n "$search_term" ] && ! echo "$hentry" | grep -q -i "$search_term"; then
                        continue  # Skip entries that don't match search term
                    fi
                    
                    if [ "$debug_mode" = true ]; then
                        # Add tag in debug mode
                        echo "HISTORY: $hentry" >> "$tmp_history"
                    else
                        # Simple entry in normal mode
                        echo "$hentry" >> "$tmp_history"
                    fi
                    history_count=$((history_count + 1))
                fi
            done <<< "$history_entries"
        fi
    else
        cat /dev/null > "$tmp_history"
    fi
    
    # Calculate boot time before showing UI
    local start_time=$(date +%s.%N)
    local boot_time=$(echo "$(date +%s.%N) - $start_time" | bc)
    
    # Setup FZF preview text
    local header_text="Directory: $start_dir"
    [ "$show_hidden" = true ] && header_text="$header_text [Hidden: ON]" 
    [ "$unlimited" = true ] && header_text="$header_text [Depth: Unlimited]"
    [ "$debug_mode" = true ] && header_text="$header_text [DEBUG MODE]"
    header_text="$header_text [Boot: ${boot_time}s]"
    
    # Debug output
    if [ "$debug_mode" = true ]; then
        echo "Debug: Current directory: $from_dir"
        echo "Debug: Show hidden: $show_hidden"
        echo "Debug: Depth: $depth (effective: $effective_depth)"
        echo "Debug: Unlimited: $unlimited"
        echo "Debug: History entries: $history_count"
        echo "Debug: Total directories: $(echo "$dirs" | wc -l)"
        echo "Debug: Boot time: ${boot_time}s"
    fi
    
    # Get directories based on parameters
    echo "$dirs" > "$tmp_dirs"
    
    # Exit if there's nothing to search
    if [ ! -s "$tmp_dirs" ] && [ ! -s "$tmp_history" ]; then
        echo "No directories or history entries found to search."
        return 1
    fi
    
    # Test mode - simulate a search without using FZF
    if [ "$test_mode" = true ]; then
        echo "=== TEST MODE: Showing entries that would be searched ==="
        echo "Search term: '${search_term}'"
        echo "=== History Entries ==="
        
        if [ -s "$tmp_history" ]; then
            cat "$tmp_history"
            history_count=$(wc -l < "$tmp_history")
        else
            echo "No history entries found for this directory."
            history_count=0
        fi
        
        echo "=== Regular Directories ==="
        local dirs_count=0
        
        if [ -n "$search_term" ]; then
            # Search within directories
            if [ "$debug_mode" = true ]; then
                echo "Debug: Searching for '$search_term' in $(echo "$dirs" | wc -l) directories" >&2
            fi
            
            matched_dirs=$(echo "$dirs" | grep -i "$search_term" || echo "")
            
            if [ -n "$matched_dirs" ]; then
                # Display the first 20 matched directories
                echo "$matched_dirs" | head -20
                
                dirs_count=$(echo "$matched_dirs" | wc -l)
                if [ "$dirs_count" -gt 20 ]; then
                    echo "... ($(($dirs_count - 20)) more matches)"
                fi
            else
                echo "No directory entries match the search term."
                dirs_count=0
            fi
        else
            # Show sample of directories
            echo "$dirs" | head -20
            dirs_count=$(echo "$dirs" | wc -l)
            if [ "$dirs_count" -gt 20 ]; then
                echo "... ($(($dirs_count - 20)) more entries)"
            fi
        fi
        
        echo "=== Summary ==="
        echo "Total history matches: $history_count"
        echo "Total directory matches: $dirs_count"
        echo "Total matches: $(($history_count + $dirs_count))"
        echo "Test complete. Exiting without selection."
        
        # Cleanup and stay in original directory
        rm -f "$tmp_history" "$tmp_dirs"
        # DO NOT CHANGE DIRECTORY - explicitly return to stay in current directory
        return 0
    fi
    
    # Use FZF for selection with improved options
    local fzf_opts=(
        --height 40%
        --reverse
        --header="$header_text"
        --prompt="Fuzzy Drunk Finder > "
        --preview="ls -la ${start_dir}/{} 2>/dev/null || ls -la {} 2>/dev/null || echo 'No preview available'"
        --bind="ctrl-y:execute-silent(echo {} | tr -d '\n' | xclip -selection clipboard)+abort"
    )
    
    if [ "$debug_mode" = true ]; then
        echo "Debug: FZF options: ${fzf_opts[*]}"
        echo "Debug: History entries count: $history_count"
        echo "Debug: Directory entries count: $(wc -l < "$tmp_dirs")"
    fi
    
    # Use FZF to select from the combined file and capture the exit code
    local selected=""
    selected=$(cat "$tmp_history" "$tmp_dirs" | fzf "${fzf_opts[@]}")
    local fzf_exit_code=$?
    
    # Debug the exit code
    if [ "$debug_mode" = true ]; then
        echo "Debug: FZF exit code: $fzf_exit_code"
    fi
    
    # Clean up all temporary files
    rm -f "$tmp_history" "$tmp_dirs"
    
    # ONLY navigate if the user actually made a selection and pressed Enter
    if [ -n "$selected" ] && [ $fzf_exit_code -eq 0 ]; then
        # Remove the history prefix if present
        selected=$(echo "$selected" | sed 's/^HISTORY: //')
        
        # Debug output
        if [ "$debug_mode" = true ]; then
            echo "Debug: Selected: $selected"
        else
            echo "Navigating to: $selected"
        fi
        
        # Check if the selection is a relative or absolute path
        if [ "${selected:0:1}" = "/" ]; then
            # Absolute path
            cd "$selected" || return 1
        else
            # Relative path - combine with search directory not the current directory
            cd "${start_dir}/${selected}" || return 1
        fi
        
        # Add to history - always use the original directory as the from_dir
        if [ "$use_history" = true ]; then
            add_to_history "$from_dir" "$(pwd)"
        fi
    elif [ $fzf_exit_code -eq 1 ] && [ -n "$selected" ]; then
        # User pressed Ctrl+Y to copy to clipboard
        if [ "$debug_mode" = true ]; then
            echo "Debug: Path copied to clipboard."
        else
            echo "Path copied to clipboard."
        fi
    else
        # User cancelled or exited without selection - do nothing and stay in current directory
        if [ "$debug_mode" = true ]; then
            echo "Debug: No selection made (exit code $fzf_exit_code). Staying in original directory ($from_dir)."
        fi
        # Silently stay in the current directory - no need for a message
    fi
    
    # Return success
    return 0
}

# Create a default alias 
alias fdf_quick="fdf"

# Function to clear cache
fdf_clear_cache() {
    echo "Clearing FDF cache..."
    if [ -d "$CACHE_DIR" ]; then
        rm -rf "${CACHE_DIR:?}"/* 2>/dev/null
        echo "Cache cleared successfully."
    else
        echo "No cache directory found."
    fi
    
    # Also check for old cache location for backward compatibility
    if [ -d "$HOME/.cache/fdf" ]; then
        echo "Found old cache directory. Clearing..."
        rm -rf "${HOME:?}/.cache/fdf"/* 2>/dev/null
        echo "Old cache cleared successfully."
    fi
}

# Function to clear history file
fdf_clear_history() {
    if [ -f "$HISTORY_FILE" ]; then
        echo "Clearing FDF history file: $HISTORY_FILE"
        rm -f "$HISTORY_FILE"
        touch "$HISTORY_FILE"
        chmod 600 "$HISTORY_FILE"
        echo "History file cleared."
    else
        echo "No history file found at $HISTORY_FILE"
    fi
}

# Function for fuzzy directory navigation help
fdf_help() {
    echo "Fuzzy Drunk Finder (FDF) - Simple Directory Navigation"
    echo ""
    echo "Usage:"
    echo "  fdf [--hidden] [--depth N] [--unlimited] [--no-history] [--debug] [--search [TERM]] [directory]"
    echo ""
    echo "Options:"
    echo "  --hidden      Include hidden directories in the search"
    echo "  --depth N     Set search depth (default: 3)"
    echo "  --unlimited   Remove depth limit for searches (may be slow in large directories)"
    echo "  --no-history  Don't use or update the directory history"
    echo "  --debug       Enable debug mode with detailed information"
    echo "  --rebuild-cache  Force rebuild of cache for this search"
    echo "  --search      Test mode: show what would be searched (optional: provide search term)"
    echo "  directory     Starting directory (default: current directory)"
    echo ""
    echo "Commands:"
    echo "  fdf           Launch fuzzy directory finder"
    echo "  fdf_help      Display this help message"
    echo "  fdf_clear_history  Clear the history file"
    echo ""
    echo "Keyboard Shortcuts:"
    echo "  Enter         Select directory and navigate to it"
    echo "  Escape        Cancel and stay in current directory"
    echo "  Ctrl+Y        Copy selected path to clipboard and exit"
    echo ""
    echo "Examples:"
    echo "  fdf                         # Search from current directory"
    echo "  fdf --hidden                # Include hidden directories"
    echo "  fdf --depth 5               # Search to a depth of 5 directories"
    echo "  fdf --unlimited             # No depth limit (may be slow in large directories)"
    echo "  fdf --debug                 # Show debug information"
    echo "  fdf /home                   # Search from /home directory"
    echo "  fdf --search dot            # Test what would be searched for 'dot'"
    echo "  fdf_clear_history           # Clear the history file"
}

# Execute the function immediately when sourced with any provided arguments
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced, make the command available
    alias ff=fdf
    echo "Fuzzy Drunk Finder loaded. Type 'fdf' to use or 'fdf_help' for help."
else
    # Script is being executed directly
    echo "This script must be sourced, not executed."
    echo "Please run: source $(basename "${BASH_SOURCE[0]}") or . $(basename "${BASH_SOURCE[0]}")"
    # Do not execute the function if script is run directly
    exit 1
fi
