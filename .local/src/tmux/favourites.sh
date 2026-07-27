#!/usr/bin/env bash
# Session favourites — star a claude/opencode conversation and re-open it later.
#
# A favourite is just a pointer to a chat: {tool, session_id, cwd, label}.
# Restoring it switches to (or creates) a tmux session at the chat's directory
# and resumes the exact conversation (claude --resume / opencode --session).
#
# Subcommands:
#   add [label]   star the agent in the CURRENT pane            (Prefix+s)
#   open          fzf picker over favourites; Enter = restore    (Prefix+o)
#   add-pick      browse recent claude/opencode sessions, star one
#   restore <tool> <id> <cwd>   re-open a favourite
#   remove <tool> <id>          drop a favourite
#   _list | _preview ...        internal helpers for fzf
#
# Registry: ~/.local/state/tmux-favourites/favourites.tsv  (runtime axis, not in repo)
#   tab-separated: tool \t session_id \t cwd \t label \t added_at

# Absolute, and from BASH_SOURCE rather than $0: fzf --bind re-invokes this script from
# INSIDE the picker (five actions do), where a relative $0 does not resolve. It used to be a
# bare SELF="$0", which broke on any relative launch.
SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

STATE_DIR="${FAVOURITES_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-favourites}"
REG="$STATE_DIR/favourites.tsv"
OPENCODE_DB="${OPENCODE_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}"
CLAUDE_SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"

mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$REG" ] || : >"$REG"

# Palette and diagnostics come from panel-lib.sh. The old local set was a third naming
# scheme (BOLD/DIM/CYAN/...), and the old die() REPLACED stderr with the tmux flash -- but
# this script is also a CLI that other scripts call, and they need the reason, not just an
# exit code. panel_warn does both.
die() { panel_die "$@"; }

# ── claude pane → session resolver (mirrors agent-chooser.sh) ────────────────
# Claude maintains ~/.claude/sessions/<pid>.json mapping pid -> sessionId+cwd.
# Build pane_pid -> claude_pid by walking each session pid up to its ancestors.
declare -A PANE_TO_CLAUDE
__build_claude_pid_map() {
    local sf cpid cur ppid depth
    for sf in "$CLAUDE_SESSIONS_DIR/"*.json; do
        [ -f "$sf" ] || continue
        cpid=$(basename "$sf" .json)
        [ -d "/proc/$cpid" ] || continue
        PANE_TO_CLAUDE[$cpid]=$cpid
        cur="$cpid"; depth=0
        while [ -n "$cur" ] && [ "$cur" != "1" ] && [ "$cur" != "0" ] && [ $depth -lt 20 ]; do
            ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$cur/status" 2>/dev/null)
            [ -z "$ppid" ] && break
            PANE_TO_CLAUDE[$ppid]=$cpid
            cur="$ppid"; depth=$((depth+1))
        done
    done
}

# pid -> "sessionId\tcwd" from the per-pid metadata file
claude_record() {
    local f="$CLAUDE_SESSIONS_DIR/${1}.json"
    [ -f "$f" ] || return 1
    jq -r '"\(.sessionId)\t\(.cwd)"' "$f" 2>/dev/null
}

# Claude encodes '/', '.', '_' all as '-' in the project dir name.
claude_jsonl() {
    local sid="$1" cwd="$2" enc
    enc="${cwd//\//-}"; enc="${enc//./-}"; enc="${enc//_/-}"
    echo "$HOME/.claude/projects/$enc/$sid.jsonl"
}

# Best-effort human label for a claude session: last ai-title, else slug, else "".
claude_label() {
    local jsonl="$1"
    [ -f "$jsonl" ] || return 0
    tail -n 800 "$jsonl" 2>/dev/null | jq -rR --slurp '
        split("\n") | map(fromjson? // empty)
        | (map(select(.type=="ai-title")) | last | .aiTitle // empty) as $t
        | (map(select(.slug != null)) | last | .slug // empty) as $s
        | ($t // "") | if . != "" then . else $s end' 2>/dev/null
}

# ── opencode (read-only db / cli) ────────────────────────────────────────────
# No per-pid file like claude, so resolve by directory (the --continue heuristic).
oc_sql() {
    [ -f "$OPENCODE_DB" ] || return 1
    command -v sqlite3 >/dev/null 2>&1 || return 1
    # read-only: file: URI with mode=ro never writes to the db.
    sqlite3 -separator $'\t' "file:$OPENCODE_DB?mode=ro" "$1" 2>/dev/null
}

# Most-recently-updated opencode session whose directory == $1 -> "id\ttitle"
oc_latest_for_dir() {
    local cwd="$1" esc
    esc="${cwd//\'/\'\'}"   # double single-quotes for SQL literal
    oc_sql "SELECT id, title FROM session WHERE directory='$esc' ORDER BY time_updated DESC LIMIT 1;"
}

# ── registry ops ─────────────────────────────────────────────────────────────
reg_remove() {  # tool id  — drop matching line
    [ $# -eq 2 ] || return 0
    local tool="$1" id="$2" tmp
    tmp=$(mktemp "$STATE_DIR/.reg.XXXXXX") || return 1
    awk -F'\t' -v t="$tool" -v i="$id" '!($1==t && $2==i)' "$REG" >"$tmp" 2>/dev/null
    mv "$tmp" "$REG"
}

reg_add() {  # tool id cwd label
    local tool="$1" id="$2" cwd="$3" label="$4" added
    added=$(date '+%Y-%m-%d %H:%M')
    reg_remove "$tool" "$id"   # dedup: re-star refreshes label/time
    printf '%s\t%s\t%s\t%s\t%s\n' "$tool" "$id" "$cwd" "$label" "$added" >>"$REG"
}

# ── subcommands ──────────────────────────────────────────────────────────────
cmd_add() {
    panel_need jq   # unchecked before this migration, two lines from a sqlite3 check
    local override="${1:-}"
    [ -n "${TMUX:-}" ] || die "not in tmux"

    local info pane_pid cwd title
    info=$(tmux display-message -p $'#{pane_pid}\t#{pane_current_path}\t#{pane_title}' 2>/dev/null)
    IFS=$'\t' read -r pane_pid cwd title <<<"$info"

    local tool="" id="" label=""

    # 1) Authoritative: is a claude session a descendant of this pane?
    __build_claude_pid_map
    local cpid="${PANE_TO_CLAUDE[$pane_pid]:-}"
    if [ -n "$cpid" ]; then
        local rec sid ccwd
        rec=$(claude_record "$cpid") && IFS=$'\t' read -r sid ccwd <<<"$rec"
        if [ -n "${sid:-}" ]; then
            tool="claude"; id="$sid"; cwd="${ccwd:-$cwd}"
            label=$(claude_label "$(claude_jsonl "$sid" "$cwd")")
        fi
    fi

    # 2) opencode: pane title is "✳ opencode" (set by _tmux_agent_wrap)
    if [ -z "$tool" ] && [[ "$title" == *"✳ opencode"* ]]; then
        local row oid otitle
        row=$(oc_latest_for_dir "$cwd") && IFS=$'\t' read -r oid otitle <<<"$row"
        if [ -n "${oid:-}" ]; then
            tool="opencode"; id="$oid"; label="${otitle:-}"
        else
            die "no opencode session found for $cwd"
        fi
    fi

    [ -n "$tool" ] || die "no resumable claude/opencode session in this pane"

    [ -n "$override" ] && label="$override"
    [ -n "$label" ] || label=$(basename "$cwd")

    reg_add "$tool" "$id" "$cwd" "$label"
    tmux display-message "★ favourited: $tool · $(basename "$cwd") · ${label}" 2>/dev/null
}

# Emit fzf rows: tool \t id \t cwd \t <colored display>   (fzf --with-nth=4)
cmd_list() {
    [ -s "$REG" ] || return 0
    local tool id cwd label added disp badge dir
    while IFS=$'\t' read -r tool id cwd label added; do
        [ -n "$tool" ] || continue
        case "$tool" in
            claude)   badge="${C_BOX}claude  ${C_OFF}" ;;
            opencode) badge="${C_SEL}opencode${C_OFF}" ;;
            *)        badge="$tool" ;;
        esac
        dir=$(basename "$cwd")
        disp="${badge} ${C_HEAD}${label}${C_OFF} ${C_DIM}${dir} · ${added}${C_OFF}"
        printf '%s\t%s\t%s\t%s\n' "$tool" "$id" "$cwd" "$disp"
    done <"$REG"
}

cmd_preview() {  # tool id cwd
    panel_need jq   # unchecked before this migration, two lines from a sqlite3 check
    local tool="$1" id="$2" cwd="$3"
    printf '%s\n' "${C_BOX}${C_HEAD}── ${tool}: ${cwd} ──${C_OFF}"
    printf '%s\n\n' "${C_DIM}session ${id}${C_OFF}"
    if [ "$tool" = "claude" ]; then
        local jsonl; jsonl=$(claude_jsonl "$id" "$cwd")
        if [ -f "$jsonl" ]; then
            printf '%s\n' "${C_BOX}${C_HEAD}── recent events ──${C_OFF}"
            tail -n 200 "$jsonl" 2>/dev/null | jq -rR --slurp '
                split("\n") | map(fromjson? // empty)
                | map(select(.type=="assistant" or .type=="user"))
                | .[-8:] | reverse | .[]
                | if .type=="assistant" then
                    (.message.content[0]) as $c
                    | if $c.type=="tool_use" then "  [33m⚙[0m \($c.name)"
                      elif $c.type=="text" then "  [32m▸[0m \(($c.text // "") | gsub("\\s+";" ") | .[0:400])"
                      else "  ? \($c.type // "?")" end
                  else "  [36m◂[0m \(((.message.content // "") | tostring) | gsub("\\s+";" ") | .[0:400])" end' 2>/dev/null
        else
            printf '%s\n' "${C_DIM}(transcript not found — may have been deleted)${C_OFF}"
        fi
    else
        local row title tu
        row=$(oc_sql "SELECT title, datetime(time_updated/1000,'unixepoch','localtime') FROM session WHERE id='${id//\'/\'\'}' LIMIT 1;")
        if [ -n "$row" ]; then
            IFS=$'\t' read -r title tu <<<"$row"
            printf '  %s\n  %s\n' "${C_HEAD}${title}${C_OFF}" "${C_DIM}updated ${tu}${C_OFF}"
        else
            printf '%s\n' "${C_DIM}(session not found in opencode db)${C_OFF}"
        fi
    fi
}

cmd_open() {
    if [ ! -s "$REG" ]; then
        printf 'No favourites yet.\n\nStar the current agent pane with Prefix+s,\nor press ctrl-a here to browse recent sessions.\n'
        read -rsn1 -p "Press any key…" _ 2>/dev/null
        # Still offer add-pick on empty list
        cmd_add_pick
        return
    fi
    local sel
    panel_fzf_opts
    local q; q="$(printf '%q' "$SELF")"
    sel=$("$SELF" _list | fzf "${PANEL_FZF_OPTS[@]}" --cycle \
        --delimiter=$'\t' --with-nth=4 \
        --prompt='Restore favourite > ' \
        --header=$'Enter=restore  ctrl-x=remove  ctrl-a=browse-recent  ctrl-r=reload' \
        --preview "$q _preview {1} {2} {3}" \
        "$(panel_fzf_preview right 60)" \
        --bind "ctrl-x:execute-silent($q remove {1} {2})+reload($q _list)" \
        --bind "ctrl-r:reload($q _list)" \
        --bind "ctrl-a:become($q add-pick)")
    [ -n "$sel" ] || exit 0
    local tool id cwd
    tool=$(printf '%s' "$sel" | cut -f1)
    id=$(printf '%s' "$sel" | cut -f2)
    cwd=$(printf '%s' "$sel" | cut -f3)
    cmd_restore "$tool" "$id" "$cwd"
}

# Browse recent claude + opencode sessions and star the selected one.
cmd_add_pick() {
    panel_need jq   # unchecked before this migration, two lines from a sqlite3 check
    local rows=""
    # claude: one row per session metadata file
    local sf cpid sid cwd label
    for sf in "$CLAUDE_SESSIONS_DIR/"*.json; do
        [ -f "$sf" ] || continue
        IFS=$'\t' read -r sid cwd < <(jq -r '"\(.sessionId)\t\(.cwd)"' "$sf" 2>/dev/null)
        [ -n "${sid:-}" ] && [ -n "${cwd:-}" ] || continue
        label=$(claude_label "$(claude_jsonl "$sid" "$cwd")")
        [ -n "$label" ] || label=$(basename "$cwd")
        rows+="claude"$'\t'"$sid"$'\t'"$cwd"$'\t'"${C_BOX}claude  ${C_OFF} ${C_HEAD}${label}${C_OFF} ${C_DIM}$(basename "$cwd")${C_OFF}"$'\n'
    done
    # opencode: recent sessions from the db
    if [ -f "$OPENCODE_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
        while IFS=$'\t' read -r sid cwd label; do
            [ -n "${sid:-}" ] || continue
            [ -n "$label" ] || label=$(basename "$cwd")
            rows+="opencode"$'\t'"$sid"$'\t'"$cwd"$'\t'"${C_SEL}opencode${C_OFF} ${C_HEAD}${label}${C_OFF} ${C_DIM}$(basename "$cwd")${C_OFF}"$'\n'
        done < <(oc_sql "SELECT id, directory, title FROM session ORDER BY time_updated DESC LIMIT 50;")
    fi

    [ -n "$rows" ] || die "no recent sessions found"

    local sel
    panel_fzf_opts
    local q; q="$(printf '%q' "$SELF")"
    sel=$(printf '%b' "$rows" | fzf "${PANEL_FZF_OPTS[@]}" --cycle \
        --delimiter=$'\t' --with-nth=4 \
        --prompt='Star recent session > ' \
        --header=$'Enter=favourite this session' \
        --preview "$q _preview {1} {2} {3}" \
        "$(panel_fzf_preview right 60)")
    [ -n "$sel" ] || exit 0
    local tool id cwd
    tool=$(printf '%s' "$sel" | cut -f1)
    id=$(printf '%s' "$sel" | cut -f2)
    cwd=$(printf '%s' "$sel" | cut -f3)
    local lbl; lbl=$(printf '%s' "$sel" | cut -f4 | sed -E 's/\x1b\[[0-9;]*m//g' | sed -E 's/^[a-z]+ +//; s/ +[^ ]*$//')
    reg_add "$tool" "$id" "$cwd" "${lbl:-$(basename "$cwd")}"
    tmux display-message "★ favourited: $tool · $(basename "$cwd")" 2>/dev/null || true
}

cmd_restore() {  # tool id cwd
    [ $# -eq 3 ] || die "usage: restore <tool> <id> <cwd>"
    local tool="$1" id="$2" cwd="$3"
    [ -d "$cwd" ] || die "directory gone: $cwd"

    local name inner
    name=$(basename "$cwd" | tr . _)
    case "$tool" in
        claude)   inner="claude --resume $id || claude" ;;
        opencode) inner="opencode --session $id || opencode" ;;
        *)        die "unknown tool: $tool" ;;
    esac
    # Run through an interactive shell so PATH + the _tmux_agent_wrap functions
    # (opencode title glyphs) load. On stale id, the `|| <tool>` falls back to a
    # fresh agent in the same dir.
    local runcmd="exec ${SHELL:-/bin/zsh} -ic '$inner'"

    # panel_ensure_session + panel_focus_session replace a `pgrep -x tmux` probe: whether a
    # server happens to be running was never the question, $TMUX is. The old code could also
    # take the attached-new-session path and skip the new-window entirely, so the SAME verb
    # produced a session-with-one-window or a session-plus-window depending on an unrelated
    # process check.
    panel_ensure_session "$name" "$cwd"
    tmux new-window -t "=$name" -c "$cwd" -n "$tool" "$runcmd"
    panel_focus_session "$name"
}

# Sourced by the unit tier rather than run: every function is defined, no subcommand runs.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# ── dispatch ─────────────────────────────────────────────────────────────────
sub="${1:-open}"; shift || true
case "$sub" in
    add)      cmd_add "$@" ;;
    open|"")  cmd_open ;;
    add-pick) cmd_add_pick ;;
    restore)  cmd_restore "$@" ;;
    remove)   reg_remove "$@" ;;
    _list)    cmd_list ;;
    _preview) cmd_preview "$@" ;;
    -h|--help) panel_usage ;;
    *)        die "unknown subcommand: $sub" ;;
esac
