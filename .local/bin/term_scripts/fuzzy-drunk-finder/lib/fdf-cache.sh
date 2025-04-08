#!/bin/bash
# fdf-cache.sh - Cache management for Fuzzy Drunk Finder
# This module handles all cache-related functionality

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

# Function to clear cache
fdf_clear_cache() {
    # Clear the cache without prompting
    if [ -d "$CACHE_DIR" ]; then
        rm -rf "${CACHE_DIR:?}"/* 2>/dev/null
        echo "Cache cleared successfully."
    else
        echo "Cache directory does not exist."
    fi
    
    # For backwards compatibility, also check the old cache location
    local old_cache_dir="$HOME/.cache/fdf"
    if [ -d "$old_cache_dir" ]; then
        rm -rf "${old_cache_dir:?}"/* 2>/dev/null
        echo "Old cache directory cleared for compatibility."
    fi
}
