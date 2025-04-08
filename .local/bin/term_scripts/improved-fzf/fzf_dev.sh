#!/bin/bash

# Enhanced fzf_dev.sh - A more responsive version of fzf for developers
# Features:
# - Saves command history
# - Provides suggestions based on current directory context
# - More responsive and user-friendly

# Configuration
HISTORY_FILE="$HOME/.fzf_dev_history"
MAX_HISTORY_ENTRIES=1000
SEARCH_DEPTH=3  # How deep to search for context-aware suggestions

# Create history file if it doesn't exist
if [ ! -f "$HISTORY_FILE" ]; then
    touch "$HISTORY_FILE"
    chmod 600 "$HISTORY_FILE"  # Secure permissions
fi

# Function to add a command to history
add_to_history() {
    local cmd="$1"
    # Don't add empty commands or duplicates at the end
    if [ -n "$cmd" ] && [ "$(tail -n 1 "$HISTORY_FILE")" != "$cmd" ]; then
        echo "$cmd" >> "$HISTORY_FILE"
        # Keep history file at a reasonable size
        if [ "$(wc -l < "$HISTORY_FILE")" -gt "$MAX_HISTORY_ENTRIES" ]; then
            tail -n "$MAX_HISTORY_ENTRIES" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
            mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
        fi
    fi
}

# Function to get directory-aware suggestions
get_dir_suggestions() {
    local current_dir="$(pwd)"
    local dir_hash="$(echo "$current_dir" | md5sum | cut -d' ' -f1)"
    local cache_file="/tmp/fzf_dev_cache_${dir_hash}"
    local cache_timeout=300  # 5 minutes
    
    # Use cached results if available and recent
    if [ -f "$cache_file" ] && [ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt "$cache_timeout" ]; then
        cat "$cache_file"
        return
    fi
    
    # Generate fresh suggestions based on current directory
    {
        # 1. Files in current directory (most relevant)
        find . -maxdepth 1 -type f -not -path "*/\.*" | sed 's|^\./||' 
        
        # 2. Recently modified files (within last day)
        find . -type f -mtime -1 -not -path "*/\.*" | sed 's|^\./||'
        
        # 3. Common developer commands based on file types in directory
        if [ -f "package.json" ]; then
            echo "npm start"
            echo "npm test"
            echo "npm run build"
            echo "npm install"
        fi
        
        if [ -f "Makefile" ]; then
            echo "make"
            echo "make clean"
            echo "make test"
            echo "make install"
        fi
        
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            echo "docker-compose up"
            echo "docker-compose down"
            echo "docker-compose build"
        fi
        
        if [ -f "go.mod" ]; then
            echo "go run ."
            echo "go test ./..."
            echo "go build"
        fi
        
        if [ -f "requirements.txt" ] || [ -d "venv" ] || [ -f "setup.py" ]; then
            echo "python -m venv venv"
            echo "source venv/bin/activate"
            echo "pip install -r requirements.txt"
            echo "python manage.py runserver"
        fi
        
        # 4. Directories (for easy navigation)
        find . -maxdepth "$SEARCH_DEPTH" -type d -not -path "*/\.*" | grep -v "node_modules\|__pycache__" | sed 's|^\./||' | sed 's|^|cd |'
        
    } | sort | uniq > "$cache_file"
    
    cat "$cache_file"
}

# Function to execute the command
execute_command() {
    local cmd="$1"
    
    # Handle special case for cd
    if [[ "$cmd" == cd* ]]; then
        $cmd
        return
    fi
    
    # Execute the command
    eval "$cmd"
    add_to_history "$cmd"
}

# Main function
main() {
    # Combine history and directory suggestions with higher priority for history
    local selected_cmd=$(
        (
            # Most recent history first (higher priority)
            tac "$HISTORY_FILE" | awk '!seen[$0]++' 
            # Directory-aware suggestions (lower priority)
            get_dir_suggestions
        ) | fzf --height 40% --reverse --tac \
            --preview 'echo {}' \
            --preview-window=up:3:wrap \
            --header="↑↓:navigate ↵:execute ctrl-c:cancel" \
            --bind "enter:accept" \
            --prompt="$(pwd) > "
    )
    
    if [ -n "$selected_cmd" ]; then
        echo "Executing: $selected_cmd"
        execute_command "$selected_cmd"
    fi
}

# Run the main function
main
