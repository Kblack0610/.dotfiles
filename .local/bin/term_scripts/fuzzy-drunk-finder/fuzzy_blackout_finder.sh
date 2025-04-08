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
    if [ -n "$cmd" ] && [ "$(tail -n 1 "$HISTORY_FILE" 2>/dev/null)" != "$cmd" ]; then
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
        # 1. Directories for easy navigation
        find . -maxdepth "$SEARCH_DEPTH" -type d -not -path "*/\.*" | 
        grep -v "node_modules\|__pycache__" | 
        sed 's|^\./||'
        
        # 2. Files in current directory
        find . -maxdepth 1 -type f -not -path "*/\.*" | 
        sed 's|^\./||' |
        awk '{print "[FILE] " $0}'
        
        # 3. Recently modified files (within last day)
        find . -type f -mtime -1 -not -path "*/\.*" | 
        sed 's|^\./||' |
        awk '{print "[FILE] " $0}'
        
        # 4. Common developer commands based on file types in directory
        if [ -f "package.json" ]; then
            echo "[CMD] npm start"
            echo "[CMD] npm test"
            echo "[CMD] npm run build"
            echo "[CMD] npm install"
        fi
        
        if [ -f "Makefile" ]; then
            echo "[CMD] make"
            echo "[CMD] make clean"
            echo "[CMD] make test"
            echo "[CMD] make install"
        fi
        
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            echo "[CMD] docker-compose up"
            echo "[CMD] docker-compose down"
            echo "[CMD] docker-compose build"
        fi
        
        if [ -f "go.mod" ]; then
            echo "[CMD] go run ."
            echo "[CMD] go test ./..."
            echo "[CMD] go build"
        fi
        
        if [ -f "requirements.txt" ] || [ -d "venv" ] || [ -f "setup.py" ]; then
            echo "[CMD] python -m venv venv"
            echo "[CMD] source venv/bin/activate"
            echo "[CMD] pip install -r requirements.txt"
            echo "[CMD] python manage.py runserver"
        fi
        
    } | sort | uniq > "$cache_file"
    
    cat "$cache_file"
}

# Function to handle file selection
handle_file() {
    local file="$1"
    # Check if file is executable
    if [ -x "$file" ]; then
        # Execute the file
        ./"$file"
    else
        # Determine action by file type
        case "$(file -b --mime-type "$file")" in
            text/*)
                # For text files, open with preferred editor
                ${EDITOR:-vi} "$file"
                ;;
            application/pdf)
                # For PDFs
                xdg-open "$file" 2>/dev/null &
                ;;
            image/*|video/*|audio/*)
                # For media files
                xdg-open "$file" 2>/dev/null &
                ;;
            *)
                # Default action
                xdg-open "$file" 2>/dev/null &
                ;;
        esac
    fi
}

# Help text for the help screen
HELP_TEXT="
FZF Developer Navigation Tool
-----------------------------
NAVIGATION:
  ↑/↓: Move selection up/down
  Enter: Select item/execute command
  Esc/Ctrl+C: Exit

FILTERING:
  /: Filter items
  Alt+d: Show only directories
  Alt+f: Show only files 
  Alt+c: Show only commands

SHORTCUTS:
  F1/?: Show this help screen
"

# Main function 
function improved_fzf_dev {
    # Start timer to measure boot time
    local start_time=$(date +%s.%N)
    
    # Use a multi-line preview with improved info
    local preview_cmd='
        if [[ ! "{}" =~ ^\[(FILE|CMD)\] ]]; then
            # Directory preview
            echo -e "\033[1;34mDirectory:\033[0m {}"
            ls -la "{}" 2>/dev/null | head -20
        elif [[ "{}" == \[FILE\]* ]]; then
            # File preview
            file="${1#[FILE] }"
            echo -e "\033[1;33mFile:\033[0m $file"
            echo -e "\033[1;36mType:\033[0m $(file -b "$file" 2>/dev/null || echo "Unknown")"
            echo -e "\033[1;36mSize:\033[0m $(du -h "$file" 2>/dev/null | cut -f1)"
            echo "----------------------------------------"
            head -50 "$file" 2>/dev/null || echo "[Binary file]"
        else
            # Command preview
            echo -e "\033[1;35mCommand:\033[0m {}"
            echo "----------------------------------------"
            echo "Press Enter to execute"
        fi
    '

    # Prepare for fzf call - calculate boot time here before showing UI
    local suggestions=$(
        (
            # Most recent history first (higher priority)
            tac "$HISTORY_FILE" 2>/dev/null | awk '!seen[$0]++' | awk '{print "[CMD] " $0}'
            # Directory-aware suggestions
            get_dir_suggestions
        )
    )
    
    # Calculate and display boot time BEFORE showing the UI
    local end_time=$(date +%s.%N)
    local boot_time=$(echo "$end_time - $start_time" | bc)
    
    # Show fzf interface
    local selected=$(echo "$suggestions" | fzf --height 50% --reverse --tac \
        --ansi \
        --preview "$preview_cmd" \
        --preview-window=right:50%:wrap \
        --header="↑↓:Navigate Enter:Select Alt+D:Dirs Alt+F:Files Esc:Exit F1:Help" \
        --bind "enter:accept" \
        --bind "alt-d:reload(echo -n '' && get_dir_suggestions | grep -v '^\[FILE\]\|^\[CMD\]')" \
        --bind "alt-f:reload(echo -n '' && get_dir_suggestions | grep '^\[FILE\]')" \
        --bind "alt-c:reload(echo -n '' && (tac \"$HISTORY_FILE\" 2>/dev/null | awk '!seen[\$0]++' | awk '{print \"[CMD] \" \$0}'; get_dir_suggestions | grep '^\[CMD\]'))" \
        --bind "f1:preview($HELP_TEXT)" \
        --bind "?:preview($HELP_TEXT)" \
        --prompt="$(pwd) > "
    )
    
    echo "Boot time: ${boot_time}s"
    
    if [ -n "$selected" ]; then
        echo "Selected: $selected"
        
        # Handle directory navigation (directories have no prefix)
        if [[ ! "$selected" =~ ^\[(FILE|CMD)\] ]]; then
            echo "Changing to directory: $selected"
            cd "$selected"
        
        # Handle file selection
        elif [[ "$selected" == \[FILE\]* ]]; then
            file="${selected#[FILE] }"
            echo "Opening file: $file"
            handle_file "$file"
            add_to_history "open $file"
        
        # Handle command execution
        elif [[ "$selected" == \[CMD\]* ]]; then
            cmd="${selected#[CMD] }"
            echo "Executing command: $cmd"
            eval "$cmd"
            add_to_history "$cmd"
            
        # Handle legacy format (for backward compatibility)
        else
            echo "Executing command: $selected"
            # Special handling for cd commands
            if [[ "$selected" == cd* ]]; then
                dir="${selected#cd }"
                cd "$dir"
                add_to_history "$selected"
            else
                eval "$selected"
                add_to_history "$selected"
            fi
        fi
    fi
}

# Create an alias for ease of use
alias fzdev="improved_fzf_dev"

# Run the main function if this script is being sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced, run the function directly
    improved_fzf_dev
else
    # Script is being executed directly, show warning
    echo "⚠️  This script must be sourced, not executed, to allow directory changes."
    echo "Please run: source $(basename "${BASH_SOURCE[0]}") or . $(basename "${BASH_SOURCE[0]}")"
    exit 1
fi
