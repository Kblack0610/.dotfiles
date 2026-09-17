#!/bin/bash

# Waybar module for AI agents
# One glyph per agent, grouped by PROJECT (working directory) not session, e.g.
# "ghe <ok><busy><attn> | dot <busy>". Glyphs come from agent-panel: ! needs
# attention, ~ in progress, check mark ready.
#
# Reads `agent-panel list` rather than scraping tmux itself. Sessions live on several
# tmux servers (hub, lab, ... see .local/src/tmux/servers.sh), and a bare
# `tmux list-panes -a` from waybar reaches none of them. agent-panel already walks every
# server and joins panes to ~/.claude/sessions, so this is one implementation, not two.
#
# Full path: waybar's exec PATH does not carry ~/.local/bin.
AGENT_PANEL="${AGENT_PANEL:-$HOME/.local/bin/agent-panel}"

# Pango color spans for per-status coloring (Catppuccin theme)
C_RED="<span color='#f38ba8'>"    # needs attention
C_YEL="<span color='#f9e2af'>"   # working
C_GRN="<span color='#a6e3a1'>"   # ready/idle
C_END="</span>"

# Short project label for the bar
short_project() {
    case "$1" in
        gheeggle*) echo "ghe" ;;
        shack) echo "shk" ;;
        dotfiles) echo "dot" ;;
        binks*) echo "bnk" ;;
        myapp) echo "pmp" ;;
        ai-lab) echo "lab" ;;
        *) echo "${1:0:3}" ;;
    esac
}

# JSON string escaping for the tooltip/summary text
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

get_ai_agent_status() {
    declare -A project_agents    # project -> coloured status glyphs
    declare -A project_sessions  # project -> tooltip lines
    local has_urgent=false has_working=false
    local target glyph project summary short status

    if [[ ! -x "$AGENT_PANEL" ]]; then
        echo '{"text": " ?", "tooltip": "agent-panel not built (cargo build --release in .local/src/agent-panel)", "class": "inactive"}'
        return
    fi

    while IFS=$'\t' read -r target glyph project summary; do
        [[ -n "$target" ]] || continue
        short=$(short_project "$project")
        case "$glyph" in
            '!') status="${C_RED}!${C_END}"; has_urgent=true ;;
            '~') status="${C_YEL}~${C_END}"; has_working=true ;;
            *)   status="${C_GRN}✓${C_END}" ;;
        esac
        project_agents[$short]+="$status"
        if [[ -n "$summary" ]]; then
            project_sessions[$short]+="${glyph} ${target} - $(json_escape "${summary:0:60}")\\n"
        else
            project_sessions[$short]+="${glyph} ${target}\\n"
        fi
    done < <("$AGENT_PANEL" list 2>/dev/null)

    local display="" tooltip="" p
    local sorted_projects
    mapfile -t sorted_projects < <(printf '%s\n' "${!project_agents[@]}" | sort)

    for p in "${sorted_projects[@]}"; do
        [[ -n "$p" ]] || continue
        [[ -n "$display" ]] && display+=" │ "
        display+="${p} ${project_agents[$p]}"
        tooltip+="${p}:\\n${project_sessions[$p]}"
    done
    tooltip="${tooltip%\\n}"

    local css_class="idle"
    if $has_urgent; then
        css_class="urgent"
    elif $has_working; then
        css_class="working"
    elif [[ -n "$display" ]]; then
        css_class="ready"
    fi

    if [[ -n "$display" ]]; then
        echo "{\"text\": \" ${display}\", \"tooltip\": \"AI Agents:\\n${tooltip}\", \"class\": \"${css_class}\"}"
    else
        echo "{\"text\": \" \", \"tooltip\": \"No AI agents running\", \"class\": \"inactive\"}"
    fi
}

get_ai_agent_status
