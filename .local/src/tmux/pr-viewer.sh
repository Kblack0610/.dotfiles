#!/bin/bash

# PR Viewer - Display open pull requests from configured repositories
# Shows PR status with CI checks and review status
# Usage: pr-viewer.sh

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# ANSI color codes for status indicators
COLOR_RED='\033[1;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[1;32m'
COLOR_DIM='\033[2m'
COLOR_BLUE='\033[1;34m'
COLOR_RESET='\033[0m'

# Configuration
CONFIG_FILE="$HOME/.dotfiles/.local/src/tmux/pr-repos.conf"
PR_LIMIT=50

# Colorize a status character for display
colorize_status() {
    case "$1" in
        '!') printf "${COLOR_RED}!${COLOR_RESET}" ;;
        '~') printf "${COLOR_YELLOW}~${COLOR_RESET}" ;;
        '✓') printf "${COLOR_GREEN}✓${COLOR_RESET}" ;;
        '·') printf "${COLOR_DIM}·${COLOR_RESET}" ;;
        *)   printf "%s" "$1" ;;
    esac
}

# Load and validate repository configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file not found: $CONFIG_FILE"
        echo "Create a config file with owner/repo format (one per line)"
        exit 1
    fi

    # Read config, filter comments and empty lines
    grep -v '^#' "$CONFIG_FILE" | grep -v '^[[:space:]]*$' | while read -r repo; do
        # Validate format (owner/repo)
        if [[ "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
            echo "$repo"
        else
            echo "Warning: Invalid repo format: $repo" >&2
        fi
    done
}

# Calculate human-readable age from ISO timestamp
get_pr_age() {
    local created_at="$1"
    local created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo 0)
    local now_epoch=$(date +%s)
    local age_seconds=$((now_epoch - created_epoch))

    if [ $age_seconds -lt 3600 ]; then
        # Less than 1 hour
        local minutes=$((age_seconds / 60))
        echo "${minutes}m"
    elif [ $age_seconds -lt 86400 ]; then
        # Less than 1 day
        local hours=$((age_seconds / 3600))
        echo "${hours}h"
    elif [ $age_seconds -lt 604800 ]; then
        # Less than 1 week
        local days=$((age_seconds / 86400))
        echo "${days}d"
    elif [ $age_seconds -lt 2592000 ]; then
        # Less than 30 days
        local weeks=$((age_seconds / 604800))
        echo "${weeks}w"
    else
        # Months
        local months=$((age_seconds / 2592000))
        echo "${months}mo"
    fi
}

# Parse CI status from statusCheckRollup using python3
get_ci_status() {
    local pr_json="$1"

    # Use python3 to parse the statusCheckRollup array
    python3 -c "
import json
import sys

try:
    pr = json.loads('''$pr_json''')
    checks = pr.get('statusCheckRollup', [])

    if not checks:
        print('·')
        sys.exit(0)

    # Count check states
    failed = sum(1 for c in checks if c.get('state') in ['FAILURE', 'ERROR'])
    pending = sum(1 for c in checks if c.get('state') in ['PENDING', 'QUEUED', 'IN_PROGRESS'])

    if failed > 0:
        print('!')
    elif pending > 0:
        print('~')
    else:
        print('✓')

except Exception as e:
    print('·')
" 2>/dev/null || echo '·'
}

# Parse review status from reviewDecision
get_review_status() {
    local pr_json="$1"

    python3 -c "
import json
import sys

try:
    pr = json.loads('''$pr_json''')
    decision = pr.get('reviewDecision', '')

    if decision == 'APPROVED':
        print('✓')
    elif decision == 'CHANGES_REQUESTED':
        print('!')
    elif decision == 'REVIEW_REQUIRED':
        print('~')
    else:
        print('·')

except Exception as e:
    print('·')
" 2>/dev/null || echo '·'
}

# Get combined PR status (priority: ! > ~ > ✓ > ·)
get_pr_status() {
    local ci_status="$1"
    local review_status="$2"

    # Priority logic
    if [[ "$ci_status" == "!" ]] || [[ "$review_status" == "!" ]]; then
        echo "!"
    elif [[ "$ci_status" == "~" ]] || [[ "$review_status" == "~" ]]; then
        echo "~"
    elif [[ "$ci_status" == "✓" ]] && [[ "$review_status" == "✓" ]]; then
        echo "✓"
    else
        echo "·"
    fi
}

# Fetch PRs from a repository
fetch_prs() {
    local repo="$1"

    # Fetch PRs using gh CLI
    gh pr list -R "$repo" \
        --json number,title,author,createdAt,state,isDraft,reviewDecision,statusCheckRollup,url,headRefName \
        --limit "$PR_LIMIT" \
        --state open 2>/dev/null
}

# Build PR list with loading progress
build_pr_list() {
    local repos=("$@")
    local total_repos=${#repos[@]}
    local current=0
    local tmp_dir="/tmp/pr-viewer-$$"

    mkdir -p "$tmp_dir"

    # Fetch PRs from each repo with progress
    for repo in "${repos[@]}"; do
        current=$((current + 1))
        echo -ne "${COLOR_BLUE}Loading PRs from $repo... ($current/$total_repos)${COLOR_RESET}\r" >&2

        # Fetch PRs
        local prs_json=$(fetch_prs "$repo")

        if [[ -z "$prs_json" ]] || [[ "$prs_json" == "[]" ]]; then
            echo -ne "${COLOR_DIM}No PRs from $repo ($current/$total_repos)${COLOR_RESET}\r" >&2
            sleep 0.2
            continue
        fi

        # Save PRs JSON to temp file for Python processing
        local repo_safe="${repo//\//-}"
        local json_file="$tmp_dir/$repo_safe.json"
        echo "$prs_json" > "$json_file"

        # Use python to parse all PRs at once and generate formatted output
        python3 <<PYTHON > "$tmp_dir/$repo_safe.txt" 2>/dev/null
import json
import sys
from datetime import datetime

with open('$json_file', 'r') as f:
    prs = json.load(f)
repo = '$repo'

for pr in prs:
    number = pr.get('number', '')
    title = pr.get('title', '')[:60]
    created_at = pr.get('createdAt', '')
    url = pr.get('url', '')
    is_draft = pr.get('isDraft', False)

    # Calculate age
    try:
        created = datetime.fromisoformat(created_at.replace('Z', '+00:00'))
        age_seconds = (datetime.now().astimezone() - created).total_seconds()
        if age_seconds < 3600:
            age = f"{int(age_seconds / 60)}m"
        elif age_seconds < 86400:
            age = f"{int(age_seconds / 3600)}h"
        elif age_seconds < 604800:
            age = f"{int(age_seconds / 86400)}d"
        elif age_seconds < 2592000:
            age = f"{int(age_seconds / 604800)}w"
        else:
            age = f"{int(age_seconds / 2592000)}mo"
    except:
        age = "?"

    # CI status
    checks = pr.get('statusCheckRollup', [])
    if not checks:
        ci_status = '·'
    else:
        failed = sum(1 for c in checks if c.get('conclusion') in ['FAILURE', 'ERROR'])
        pending = sum(1 for c in checks if c.get('status') in ['PENDING', 'QUEUED', 'IN_PROGRESS'])
        if failed > 0:
            ci_status = '!'
        elif pending > 0:
            ci_status = '~'
        else:
            ci_status = '✓'

    # Review status
    decision = pr.get('reviewDecision', '')
    if decision == 'APPROVED':
        review_status = '✓'
    elif decision == 'CHANGES_REQUESTED':
        review_status = '!'
    elif decision == 'REVIEW_REQUIRED':
        review_status = '~'
    else:
        review_status = '·'

    # Combined status (priority: ! > ~ > ✓ > ·)
    if ci_status == '!' or review_status == '!':
        combined_status = '!'
    elif ci_status == '~' or review_status == '~':
        combined_status = '~'
    elif ci_status == '✓' and review_status == '✓':
        combined_status = '✓'
    else:
        combined_status = '·'

    # Output: status|repo|number|title|age|ci|review|url|is_draft
    print(f"{combined_status}|{repo}|{number}|{title}|{age}|{ci_status}|{review_status}|{url}|{is_draft}")
PYTHON

        echo -ne "${COLOR_GREEN}✓ Loaded $repo ($current/$total_repos)${COLOR_RESET}\r" >&2
        sleep 0.1
    done

    echo -e "${COLOR_GREEN}Loading complete, displaying results...${COLOR_RESET}          " >&2
    sleep 0.3

    # Build grouped output for fzf
    local output=""

    for repo in "${repos[@]}"; do
        local repo_safe="${repo//\//-}"
        local repo_file="$tmp_dir/$repo_safe.txt"

        if [[ ! -f "$repo_file" ]] || [[ ! -s "$repo_file" ]]; then
            continue
        fi

        # Count statuses for this repo
        local count_fail=$(grep -c '^!' "$repo_file" 2>/dev/null)
        local count_pend=$(grep -c '^~' "$repo_file" 2>/dev/null)
        local count_good=$(grep -c '^✓' "$repo_file" 2>/dev/null)
        local total_prs=$(wc -l < "$repo_file")

        # Build status summary
        local status_summary=""
        [[ $count_fail -gt 0 ]] && status_summary+=$(colorize_status '!')
        [[ $count_pend -gt 0 ]] && status_summary+=$(colorize_status '~')
        [[ $count_good -gt 0 ]] && status_summary+=$(colorize_status '✓')

        # Add repo header
        output+="─── ${repo} ${status_summary} (${total_prs}) ───"$'\n'

        # Add each PR
        while IFS='|' read -r status repo_name number title age ci review url is_draft; do
            local status_colored=$(colorize_status "$status")
            local ci_colored=$(colorize_status "$ci")
            local review_colored=$(colorize_status "$review")
            local draft_mark=""
            [[ "$is_draft" == "True" || "$is_draft" == "true" ]] && draft_mark=" ${COLOR_DIM}[draft]${COLOR_RESET}"

            # Format: repo|number TAB formatted_display
            # We'll use TAB as separator and fzf will show everything
            output+=$(printf "%s|%s\t  %b #%-5s %-45s %5s  [%b CI][%b Rev]%b\n" \
                "$repo_name" "$number" \
                "$status_colored" "$number" "$title" "$age" \
                "$ci_colored" "$review_colored" "$draft_mark")
        done < "$repo_file"

        output+=$'\n'
    done

    # Cleanup temp files
    rm -rf "$tmp_dir"

    echo -e "$output"
}

# Check gh authentication
check_gh_auth() {
    if ! gh auth status &>/dev/null; then
        echo "Error: Not authenticated with GitHub CLI"
        echo "Run: gh auth login"
        exit 1
    fi
}

# Main execution
main() {
    # Check authentication
    check_gh_auth

    # Load repositories
    mapfile -t repos < <(load_config)

    if [ ${#repos[@]} -eq 0 ]; then
        echo "Error: No valid repositories found in config"
        echo "Add repositories to: $CONFIG_FILE"
        exit 1
    fi

    # Build PR list with loading progress
    pr_list=$(build_pr_list "${repos[@]}")

    # Check if any PRs found
    if [[ -z "$pr_list" ]] || [[ "$pr_list" =~ ^[[:space:]]*$ ]]; then
        echo "No open pull requests found in configured repositories"
        read -n 1 -s -r -p "Press any key to exit..."
        exit 0
    fi

    # Display in fzf
    selected=$(echo -e "$pr_list" | fzf \
        --ansi \
        --reverse \
        --border \
        --cycle \
        --no-sort \
        --delimiter=$'\t' \
        --with-nth=2.. \
        --prompt='Select PR > ' \
        --header=$'Enter=open in browser | ^d=details | ^r=reload | esc=exit\n' \
        --bind "ctrl-r:reload(bash $0)" \
        --bind "ctrl-d:execute(echo {} | cut -f1 | IFS='|' read -r repo num; gh pr view \$num -R \$repo)")

    # Handle selection
    if [[ -n "$selected" ]] && [[ ! "$selected" =~ ^─── ]]; then
        # Extract repo and PR number from the first field (before TAB)
        repo_and_number=$(echo "$selected" | cut -f1)

        if [[ "$repo_and_number" =~ ^([^|]+)\|([0-9]+)$ ]]; then
            repo="${BASH_REMATCH[1]}"
            pr_number="${BASH_REMATCH[2]}"

            # Open PR in browser
            gh pr view "$pr_number" -R "$repo" --web 2>/dev/null
        fi
    fi
}

# Run main function
main
