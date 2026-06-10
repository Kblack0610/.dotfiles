#!/bin/bash

# Lists all tmux windows running claude agents
# Groups by PROJECT (working directory) and lets you jump via fzf
# Usage: agent-chooser.sh [-n|--next]
#   -n, --next  Jump to next agent needing attention (or next in list)

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# ANSI color codes for status indicators
COLOR_RED='\033[1;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[1;32m'
# Title is bold-only so it inherits the active terminal theme's foreground
# (works in both jackie-brown and tokyonight without re-tweaking).
COLOR_TITLE='\033[1m'
# Count uses dim because it's secondary metadata, not content.
COLOR_DIM='\033[2m'
COLOR_RESET='\033[0m'

# Short heavy bar — fits on one line so fzf's --wrap doesn't break it.
# Visual divider, not a viewport-spanning rule (which conflicted with --wrap).
SEP='━━━━━━━━━━━━'

# --- Claude session metadata helpers ---
# Claude Code maintains ~/.claude/sessions/<pid>.json with the canonical
# pid -> sessionId + cwd + status mapping. Use it instead of /proc-poking
# or mtime heuristics.

# Build pane_pid -> claude_pid map ONCE per script run. The old per-pane
# implementation walked /proc ancestry of every claude session for every pane
# (O(panes × sessions × depth) — ~1.8s with 18 of each). Walking from each
# claude session upward and recording every ancestor pid lets every pane
# lookup be O(1) afterward. Total /proc walks drop ~18x.
declare -A PANE_TO_CLAUDE
__build_claude_pid_map() {
    local sf cpid cur ppid depth
    for sf in "$HOME/.claude/sessions/"*.json; do
        [ -f "$sf" ] || continue
        cpid=$(basename "$sf" .json)
        [ -d "/proc/$cpid" ] || continue
        PANE_TO_CLAUDE[$cpid]=$cpid   # direct hit
        cur="$cpid"
        depth=0
        while [ -n "$cur" ] && [ "$cur" != "1" ] && [ "$cur" != "0" ] && [ $depth -lt 20 ]; do
            ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$cur/status" 2>/dev/null)
            [ -z "$ppid" ] && break
            PANE_TO_CLAUDE[$ppid]=$cpid
            cur="$ppid"
            depth=$((depth+1))
        done
    done
}
__build_claude_pid_map

resolve_claude_pid() {
    local pane_pid="$1"
    [ -z "$pane_pid" ] && return 1
    local cpid="${PANE_TO_CLAUDE[$pane_pid]}"
    [ -n "$cpid" ] && { echo "$cpid"; return 0; }
    return 1
}

# Read pid -> status<TAB>sessionId<TAB>cwd. One jq invocation instead of two.
# Caller splits on TAB; empty status means file missing or .status absent.
read_session_record() {
    local pid="$1"
    local f="$HOME/.claude/sessions/${pid}.json"
    [ -f "$f" ] || return 1
    jq -r '"\(.status // "")\t\(.sessionId)\t\(.cwd)"' "$f" 2>/dev/null
}

# Compute JSONL path from sessionId + cwd. Claude encodes '/', '.', and '_'
# all as '-' in the project dir name (verified across all live sessions).
session_jsonl_path() {
    local sid="$1" cwd="$2"
    local enc="${cwd//\//-}"
    enc="${enc//./-}"
    enc="${enc//_/-}"
    echo "$HOME/.claude/projects/$enc/$sid.jsonl"
}

# Pluck the most recent assistant/user event from a JSONL.
# Returns "tool: <name>" / "say: <truncated>" / "user: input" / "(no events)".
last_event() {
    local file="$1"
    [ -f "$file" ] || { echo "(no events)"; return; }
    # Read last 200 lines only — long-lived sessions grow to thousands; tac+slurp
    # of the full file was the dominant boot cost. 200 always covers the last
    # assistant/user turn in normal use.
    tail -n 200 "$file" 2>/dev/null | jq -rR --slurp '
        split("\n")
        | map(fromjson? // empty)
        | map(select(.type == "assistant" or .type == "user"))
        | last
        | if . == null then "(no events)"
          elif .type == "assistant" then
            (.message.content[0]) as $c
            | if $c.type == "tool_use" then "tool: \($c.name)"
              elif $c.type == "text"   then "say: \(($c.text // "") | gsub("\\s+"; " ") | .[0:300])"
              else                          "asst: \($c.type // "?")"
              end
          else "user: input"
          end' 2>/dev/null || echo "?"
}

# Colorize a status character for display
colorize_status() {
    case "$1" in
        '!') printf "${COLOR_RED}!${COLOR_RESET}" ;;
        '~') printf "${COLOR_YELLOW}~${COLOR_RESET}" ;;
        '✓') printf "${COLOR_GREEN}✓${COLOR_RESET}" ;;
        *)   printf "%s" "$1" ;;
    esac
}

# Parse arguments
NEXT_MODE=false
[[ "$1" == "-n" || "$1" == "--next" ]] && NEXT_MODE=true

# Extract project name from working directory path
get_project_from_path() {
    local path="$1"
    local dir_name=$(basename "$path")

    # Strip agent suffixes (gheeggle-agent-2 -> gheeggle)
    dir_name=$(echo "$dir_name" | sed -E 's/-agent-?[0-9]*$//')

    # Normalize common variations
    case "$dir_name" in
        .dotfiles|_dotfiles) echo "dotfiles" ;;
        *) echo "$dir_name" ;;
    esac
}

# Build list of windows with AI agents
declare -A seen_windows
declare -A project_agents  # project -> list of "status|session:window|agent_type"
declare -a all_agents      # flat list of all "status|target" for next mode
AGENT_PATTERN="^(claude|claude-real|aider|opencode)$"

# Target -> JSONL path map; written during the per-pane loop, read by
# agent-preview.sh on every fzf preview keystroke. tab-separated.
JSONL_MAP_FILE="${TMPDIR:-/tmp}/agent-chooser-$$.map"
: > "$JSONL_MAP_FILE"
trap 'rm -f "$JSONL_MAP_FILE"' EXIT

# Detect agent type from pane (returns type or empty)
detect_agent_type() {
    local session="$1"
    local window_idx="$2"
    local pane_cmd="$3"

    # Direct match
    if [[ "$pane_cmd" =~ $AGENT_PATTERN ]]; then
        echo "$pane_cmd"
        return 0
    fi

    # Check if shell (bash/zsh) is running claude wrapper
    # Look for ✳ in title (Claude's task indicator)
    if [[ "$pane_cmd" =~ ^(bash|zsh)$ ]]; then
        local title=$(tmux display-message -p -t "${session}:${window_idx}" "#{pane_title}" 2>/dev/null)

        # Check for Claude's ✳ indicator in title
        if [[ "$title" =~ ✳ ]]; then
            # If we see ✳, it's a claude session (wrapped by default now)
            echo "claude-wrapped"
            return 0
        fi
    fi

    return 1
}

while IFS=$'\t' read -r session window_idx window_name pane_cmd pane_path pane_pid pane_title; do
    window_key="${session}:${window_idx}"
    [[ -n "${seen_windows[$window_key]}" ]] && continue

    # Detect agent type
    agent_type=$(detect_agent_type "$session" "$window_idx" "$pane_cmd")

    if [[ -n "$agent_type" ]]; then
        seen_windows[$window_key]=1

        # Get project from working directory
        project=$(get_project_from_path "$pane_path")

        # Determine status + summary.
        # Claude panes: read both from ~/.claude/sessions/<pid>.json (canonical).
        # Other agents (aider, opencode): fall back to scrollback heuristic for status; empty summary.
        status=""
        summary=""
        if [[ "$agent_type" =~ ^claude ]]; then
            claude_pid=$(resolve_claude_pid "$pane_pid")
            record=$(read_session_record "$claude_pid")
            IFS=$'\t' read -r raw_status sid cwd <<<"$record"
            case "$raw_status" in
                waiting) status="!" ;;
                busy)    status="~" ;;
                *)       status="✓" ;;
            esac
            jsonl=""
            if [ -n "$sid" ] && [ -n "$cwd" ]; then
                jsonl=$(session_jsonl_path "$sid" "$cwd")
                summary=$(last_event "$jsonl")
            fi
        else
            last_lines=$(tmux capture-pane -t "${session}:${window_idx}" -p -S -15 2>/dev/null | tail -15)
            last_activity=$(tmux display-message -p -t "${session}:${window_idx}" "#{window_activity}" 2>/dev/null)
            now=$(date +%s)
            activity_diff=9999
            [ -n "$last_activity" ] && activity_diff=$((now - last_activity))
            if echo "$last_lines" | grep -qE '\[Y/n\]|\[y/N\]|yes.*no.*:|proceed\?|Allow.*once|Allow.*always|Deny|Do you want to'; then
                status="!"
            elif [ $activity_diff -lt 3 ]; then
                status="~"
            elif echo "$last_lines" | grep -qE '^> |^❯ |⏵⏵|bypass permissions|Context left'; then
                status="✓"
            elif [ $activity_diff -gt 10 ]; then
                status="✓"
            else
                status="~"
            fi
        fi

        # Prefer Claude's pane_title (the AI session title — what you see at
        # the top of the tmux window) over the JSONL "say:" text. Strip the
        # leading status glyph (✳, ⠐, ⠂ etc.) + space if present; the row's
        # own status marker already conveys that state. Full "say:" text is
        # still in the preview pane on the right.
        if [ -n "$pane_title" ]; then
            cleaned="$pane_title"
            case "$cleaned" in
                [^[:alnum:][:space:]]\ *) cleaned="${cleaned#? }" ;;
            esac
            [ -n "$cleaned" ] && summary="$cleaned"
        fi

        # Format agent type label
        agent_label=""
        case "$agent_type" in
            claude-wrapped) agent_label="[claude]" ;;
            claude-real)    agent_label="[direct]" ;;
            claude)         agent_label="[claude]" ;;
            aider)          agent_label="[aider]" ;;
            opencode)       agent_label="[opencode]" ;;
            *)              agent_label="[${agent_type}]" ;;
        esac

        # Short target: strip the project name from the tmux session so rows
        # under e.g. "platform" show "agent-2:1" instead of "platform-agent-2:1".
        # The project header already names the project. The full target stays
        # in field 1 of the row (hidden via fzf --with-nth) for tmux ops.
        short_session="$session"
        short_session="${short_session#_}"; short_session="${short_session#.}"
        case "$short_session" in
            "$project")     short_session="" ;;
            "$project"-*)   short_session="${short_session#"$project"-}" ;;
        esac
        short_target="${short_session}:${window_idx}"

        # Add to project group and flat list
        project_agents[$project]+="${status}|${session}:${window_idx}|${short_target}|${agent_label}|${summary}\n"
        all_agents+=("${status}|${session}:${window_idx}")

        # Persist target -> (jsonl, project, summary, repo_full) for preview.
        # repo_full keeps the agent suffix (e.g. "platform-agent-2") so the
        # preview header shows the exact worktree the user is in; $project
        # is the normalized name used to group rows in the sidebar.
        repo_full=$(basename "$pane_path")
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${session}:${window_idx}" "${jsonl:-}" "$project" "$summary" "$repo_full" \
            >>"$JSONL_MAP_FILE"
    fi
done < <(tmux list-panes -a -F $'#{session_name}\t#{window_index}\t#{window_name}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_pid}\t#{pane_title}' 2>/dev/null)

# Check if any agents found
if [ ${#project_agents[@]} -eq 0 ]; then
    echo "No claude agents running"
    $NEXT_MODE || read -n 1 -s -r -p "Press any key to exit..."
    exit 0
fi

# Handle next mode - jump directly without fzf
if $NEXT_MODE; then
    current_target=""
    [[ -n "$TMUX" ]] && current_target=$(tmux display-message -p "#{session_name}:#{window_index}")

    # Find current index in list
    current_idx=-1
    for i in "${!all_agents[@]}"; do
        if [[ "${all_agents[$i]}" == *"|$current_target" ]]; then
            current_idx=$i
            break
        fi
    done

    # First, look for next agent needing attention (!) after current position
    target=""
    total=${#all_agents[@]}
    for ((i=1; i<=total; i++)); do
        idx=$(( (current_idx + i) % total ))
        entry="${all_agents[$idx]}"
        if [[ "$entry" == "!|"* ]]; then
            target="${entry#*|}"
            break
        fi
    done

    # If no attention needed, just go to next agent
    if [[ -z "$target" ]]; then
        next_idx=$(( (current_idx + 1) % total ))
        target="${all_agents[$next_idx]#*|}"
    fi

    # Jump
    if [[ -n "$target" ]]; then
        if [ -n "$TMUX" ]; then
            tmux switch-client -t "$target"
        else
            tmux attach -t "$target"
        fi
    fi
    exit 0
fi

# Build grouped output for fzf
agent_list=""
sorted_projects=($(echo "${!project_agents[@]}" | tr ' ' '\n' | sort))

for project in "${sorted_projects[@]}"; do
    agents="${project_agents[$project]}"

    # Count agents and collect statuses
    count=0
    statuses=""
    while IFS='|' read -r status target short_target agent_label _summary; do
        [ -z "$status" ] && continue
        ((count++))
        statuses+="$(colorize_status "$status")"
    done <<< "$(echo -e "$agents")"

    # Row format: <full_target>\t<display>. fzf --with-nth=2.. hides field 1
    # so the user sees only the display; on select we recover full target
    # from field 1 to drive tmux switch-client.
    # Project header has empty field 1 (not selectable; pattern-skipped below).
    # No trailing separator bar — sidebar is narrow, every column counts.
    agent_list+="\t${COLOR_TITLE}━━━ ${project}${COLOR_RESET} ${statuses} ${COLOR_DIM}(${count})${COLOR_RESET}\n"

    # Individual agent rows: status, label, short_target, summary.
    # Single-space gaps, no leading indent — keeps rows on ONE LINE in narrow
    # sidebars instead of wrapping. The preview pane shows the full content.
    while IFS='|' read -r status target short_target agent_label summary; do
        [ -z "$status" ] && continue
        colored=$(colorize_status "$status")
        # Drop the [claude] label for the common case (density). Keep
        # [aider] / [opencode] so the exception is visually flagged.
        label_display=""
        [[ "$agent_label" != "[claude]" ]] && label_display="${agent_label} "
        if [[ -n "$summary" ]]; then
            agent_list+="${target}\t ${colored} ${label_display}${short_target} ${COLOR_DIM}${summary}${COLOR_RESET}\n"
        else
            agent_list+="${target}\t ${colored} ${label_display}${short_target}\n"
        fi
    done <<< "$(echo -e "$agents")"
done

# Position cursor on currently active agent
restore_pos=""
if [[ -n "$TMUX" ]]; then
    current_target=$(tmux display-message -p "#{session_name}:#{window_index}")
    line_num=$(echo -e "$agent_list" | grep -nF "$current_target" | head -1 | cut -d: -f1)
    [[ -n "$line_num" ]] && restore_pos="--bind load:pos($line_num)"
fi

PREVIEW_SCRIPT="${0%/*}/agent-preview.sh"

# Select with fzf
selected=$(echo -e "$agent_list" | fzf --reverse --border --cycle \
    --prompt='Select agent > ' \
    --header=$'Enter=jump  n=next-attention  C-/ toggle preview  C-d/C-u scroll  ·  \033[1;31m!\033[0m input  \033[1;33m~\033[0m busy  \033[1;32m✓\033[0m idle' \
    --ansi \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth='2..' \
    --preview "$PREVIEW_SCRIPT '$JSONL_MAP_FILE' {}" \
    --preview-window 'right:75%:wrap' \
    --bind 'ctrl-/:change-preview-window(hidden|right:75%:wrap)' \
    --bind 'ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up' \
    --bind "n:execute-silent($0 -n)+abort" \
    --bind 'up:up+transform:case {} in *━━*) echo up ;; esac' \
    --bind 'down:down+transform:case {} in *━━*) echo down ;; esac' \
    $restore_pos)

[[ -z "$selected" ]] && exit 0

# Skip if header line selected (heavy bar prefix, with optional ANSI color)
if [[ "$selected" == *━━* ]]; then
    exit 0
fi

# Field 1 of each row holds the full tmux target (hidden from display by
# fzf --with-nth=2..). fzf returns the entire line on selection, tabs intact.
target=$(printf '%s' "$selected" | cut -f1)

# Jump to it
if [ -n "$TMUX" ]; then
    tmux switch-client -t "$target"
else
    tmux attach -t "$target"
fi
