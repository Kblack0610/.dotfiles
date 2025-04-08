#!/bin/bash
# fdf-core.sh - Core functionality for Fuzzy Drunk Finder
# This module contains the main fdf function and related utilities

FDF_VERSION="1.2.0"

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
    local show_version=false
    
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
            --version)
                show_version=true
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

    # Show version if requested
    if [ "$show_version" = true ]; then
        echo "Fuzzy Drunk Finder v$FDF_VERSION"
        echo "Copyright (c) 2025"
        echo "Repository: https://github.com/yourusername/fuzzy-drunk-finder"
        return 0
    }
    
    # Set the target directory for search to the current directory if not specified
    local start_dir="${start_dir:-$(pwd)}"
    
    # Ensure the directory exists and is accessible
    if [ ! -d "$start_dir" ]; then
        echo "Error: Directory '$start_dir' does not exist or is not accessible."
        return 1
    fi
    
    # Load configuration if it exists
    load_config
    
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
    if [ -f "$HISTORY_FILE" ] && [ "$use_history" = true ]; then
        history_entries=$(get_context_history "$from_dir")
    fi
    
    # Main execution logic differs between test mode and interactive mode
    if [ "$test_mode" = true ]; then
        # Running in test mode - display what would be searched
        handle_test_mode "$dirs" "$history_entries" "$search_term" "$debug_mode"
    else
        # Running in interactive mode - use fzf for selection
        handle_interactive_mode "$dirs" "$history_entries" "$from_dir" "$start_dir" "$use_history" "$debug_mode"
    fi
    
    # Clean up temp files
    rm -f "$tmp_dirs" "$tmp_history"
}

# Function to handle test mode (--search flag)
handle_test_mode() {
    local dirs="$1"
    local history_entries="$2"
    local search_term="$3"
    local debug_mode="$4"
    
    # Display test mode header
    echo "=== TEST MODE: Showing entries that would be searched ==="
    [ -n "$search_term" ] && echo "Search term: '$search_term'"
    
    # Display history entries
    echo "=== History Entries ==="
    if [ -n "$history_entries" ]; then
        echo "$history_entries" | while read -r entry; do
            echo "HISTORY: $entry"
        done
    else
        echo "No history entries found for this directory."
    fi
    
    # Process directories
    echo "=== Regular Directories ==="
    local filtered_dirs="$dirs"
    if [ -n "$search_term" ]; then
        if [ "$debug_mode" = true ]; then
            local dir_count=$(echo "$dirs" | grep -v '^$' | wc -l)
            echo "Debug: Searching for '$search_term' in $dir_count directories"
        fi
        filtered_dirs=$(echo "$dirs" | grep -i "$search_term" 2>/dev/null)
    fi
    
    if [ -n "$filtered_dirs" ]; then
        # Limit output for very large results
        local filtered_count=$(echo "$filtered_dirs" | grep -v '^$' | wc -l)
        if [ "$filtered_count" -gt 20 ]; then
            echo "$filtered_dirs" | head -n 20
            echo "... ($((filtered_count - 20)) more matches)"
        else
            echo "$filtered_dirs"
        fi
    else
        echo "No directory entries match the search term."
    fi
    
    # Display summary
    local history_count=$([ -n "$history_entries" ] && echo "$history_entries" | wc -l || echo 0)
    local dir_count=$([ -n "$filtered_dirs" ] && echo "$filtered_dirs" | grep -v '^$' | wc -l || echo 0)
    local total_count=$((history_count + dir_count))
    
    echo "=== Summary ==="
    echo "Total history matches: $history_count"
    echo "Total directory matches: $dir_count"
    echo "Total matches: $total_count"
    echo "Test complete. Exiting without selection."
}

# Function to handle interactive mode (regular usage)
handle_interactive_mode() {
    local dirs="$1"
    local history_entries="$2"
    local from_dir="$3"
    local start_dir="$4"
    local use_history="$5"
    local debug_mode="$6"
    
    # Prepare display for fzf
    echo "$dirs" > "$tmp_dirs"
    
    # Use history if available
    if [ -n "$history_entries" ]; then
        echo "$history_entries" | while read -r entry; do
            echo "HISTORY: $entry"
        done > "$tmp_history"
        
        # Count items for debugging
        if [ "$debug_mode" = true ]; then
            local history_count=$(wc -l < "$tmp_history")
            echo "Debug: History entries: $history_count"
        fi
    fi
    
    # Count directories for debugging
    if [ "$debug_mode" = true ]; then
        local dir_count=$(wc -l < "$tmp_dirs")
        echo "Debug: Total directories: $dir_count"
    fi
    
    # Record start time for debugging
    if [ "$debug_mode" = true ]; then
        local start_time=$(date +%s.%N)
    fi
    
    # Combine history and directories, prioritizing history
    local selection
    if [ -s "$tmp_history" ]; then
        selection=$(cat "$tmp_history" "$tmp_dirs" | fzf --ansi --height 40% --reverse)
    else
        selection=$(cat "$tmp_dirs" | fzf --ansi --height 40% --reverse)
    fi
    
    # Nothing selected, exit gracefully
    if [ -z "$selection" ]; then
        return 0
    fi
    
    # Record end time and calculate duration for debugging
    if [ "$debug_mode" = true ]; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc)
        echo "Debug: Boot time: ${duration}s"
    fi
    
    # Process the selection
    # If it's a history entry, extract the path
    if [[ "$selection" == HISTORY:* ]]; then
        selection="${selection#HISTORY: }"
    else
        # Otherwise, prepend the start_dir if the selection is not an absolute path
        if [[ "$selection" != /* ]]; then
            selection="$start_dir/$selection"
        fi
    fi
    
    # Normalize path by resolving any .. or . components
    selection=$(realpath -s "$selection")
    
    # Change to the selected directory
    if [ -d "$selection" ]; then
        # Add the target to history if we're using history
        if [ "$use_history" = true ]; then
            add_to_history "$selection"
        fi
        
        # Actually change directory
        cd "$selection" || return 1
        echo "Changed to: $selection"
    else
        echo "Error: $selection is not a valid directory."
        return 1
    fi
}
