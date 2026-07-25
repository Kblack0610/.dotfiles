#!/usr/bin/env bash
# Window tags - mark tmux windows as important / pinned / agent, or group them.
#
# A tag is stored as a tmux WINDOW user-option, one option per tag:
#
#     @tag_important 1        flag tags: present = set
#     @tag_pinned    1
#     @tag_agent     1
#     @tag_group     work     valued tag: one group per window
#
# Why window user-options and not the window name: ~/.zshrc installs a precmd
# hook that rewrites the window name to the git branch on EVERY prompt, so a
# name-based marker is wiped the moment you hit enter. Options survive renames,
# detach/reattach and index renumbering. They do NOT survive `tmux kill-server`
# - tags are deliberately server-lifetime only (see the plan's "Future seam").
#
# Windows are always addressed by #{window_id} (@N), never window_index -
# indexes renumber, and a bare `display-message` returns the session's ACTIVE
# window rather than the calling pane's window. Same rule as wind-down.sh.
#
# Subcommands:
#   toggle <tag> [-t <win>]    flip a tag                        (Prefix+a i/p/a)
#   add|rm <tag> [-t <win>]    set / unset a tag
#   clear [-t <win>]           drop every tag on a window        (Prefix+a x)
#   get [-t <win>]             tags on one window, space-separated
#   ls [--tag <tag>] [--json]  every tagged window
#   targets [--tag <tag>]      bare window_ids, one per line (for xargs)
#   protected <win>            exit 0 if the window is pinned/important
#   vocab                      print the reserved tag vocabulary
#
# Group verbs - a tag is a group:
#   gather --tag <t> --into <session>   move every tagged window into a session
#   next --tag <t>                      cycle to the next window in the group
#   kill --tag <t> [--force]            kill the group, honouring pinned/important
#   pick                                fzf picker over tagged windows (Prefix+W)
#
# No registry file: tmux itself is the store, `show-options -w` the enumerator.

set -uo pipefail

export PATH="$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin"

# ── vocabulary ───────────────────────────────────────────────────────────────
# Adding a tag is a one-line change here. FLAG tags are boolean; VALUED tags
# carry a payload and are written as `<tag>:<value>` (e.g. group:work).
FLAG_TAGS=(important pinned agent)
VALUED_TAGS=(group)
# Tags that protect a window from automated kills (cleanup.sh, wind-down.sh).
PROTECT_TAGS=(pinned important)

SELF="$0"

# Always stderr - scripts and agents call this CLI and need the reason, not just
# the exit code. The tmux flash is additive, for keybinding use.
warn() {
    printf 'tags: %s\n' "$*" >&2
    tmux display-message "tags: $*" 2>/dev/null || true
}

# `fail` returns; `die` exits. Helpers that run inside a command substitution
# MUST use fail + `return 1` - an `exit` there only kills the subshell, leaving
# the caller to continue with an empty result (and, for a filter, to silently
# fall back to matching everything).
fail() { warn "$@"; return 1; }
die()  { warn "$@"; exit 1; }

in_list() {  # in_list <needle> <haystack...>
    local n="$1"; shift
    local x
    for x in "$@"; do [ "$x" = "$n" ] && return 0; done
    return 1
}

# ── target resolution ────────────────────────────────────────────────────────
# Default target is the window of the CALLING pane, resolved via $TMUX_PANE.
# Never `tmux display-message -p '#{window_id}'` bare - that answers for the
# session's active window, which is not necessarily ours.
resolve_target() {
    local want="${1:-}"
    if [ -n "$want" ]; then
        # Accept @N directly; otherwise let tmux resolve session:index forms.
        case "$want" in
            @*) printf '%s\n' "$want"; return 0 ;;
        esac
        tmux display-message -p -t "$want" '#{window_id}' 2>/dev/null && return 0
        die "no such window: $want"
    fi
    local pane="${TMUX_PANE:-}"
    if [ -n "$pane" ]; then
        tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null && return 0
    fi
    # `run-shell` does not export TMUX_PANE, so fall back to the attached
    # client's active window - for an interactive verb that IS the window the
    # user is looking at. Deliberately last: when a caller needs ITS OWN window
    # (wind-down) rather than the focused one, it must pass -t explicitly.
    #
    # Derive it from the client's SESSION, not `display-message -p
    # '#{window_id}'` - that reports whichever session tmux picks as default,
    # not the client's, so it silently answers about the wrong window.
    local sess wid
    sess=$(tmux list-clients -F '#{client_session}' 2>/dev/null | head -1)
    if [ -n "$sess" ]; then
        wid=$(tmux list-windows -t "$sess" -f '#{window_active}' -F '#{window_id}' 2>/dev/null | head -1)
        [ -n "$wid" ] && { printf '%s\n' "$wid"; return 0; }
    fi
    die "not inside tmux and no attached client; pass -t <window>"
}

# Pull an optional `-t <target>` out of the argument list. Sets TARGET_ARG and
# rewrites ARGV_REST with what remains.
ARGV_REST=()
TARGET_ARG=""
split_target() {
    ARGV_REST=(); TARGET_ARG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -t|--target) TARGET_ARG="${2:-}"; shift 2 || die "-t needs a window" ;;
            *) ARGV_REST+=("$1"); shift ;;
        esac
    done
}

# ── tag <-> option mapping ───────────────────────────────────────────────────
# Prints "<option-name> <value>" for a tag string, or dies on unknown tags.
# Keeping this strict is what lets agents rely on the vocabulary.
tag_opt() {
    local tag="$1" name value
    case "$tag" in
        *:*) name="${tag%%:*}"; value="${tag#*:}" ;;
        *)   name="$tag";       value="1" ;;
    esac
    if in_list "$name" "${FLAG_TAGS[@]}"; then
        [ "$value" = "1" ] || { fail "'$name' is a flag tag and takes no value"; return 1; }
        printf '@tag_%s 1\n' "$name"
    elif in_list "$name" "${VALUED_TAGS[@]}"; then
        [ -n "$value" ] && [ "$value" != "1" ] \
            || { fail "'$name' needs a value, e.g. ${name}:work"; return 1; }
        printf '@tag_%s %s\n' "$name" "$value"
    else
        fail "unknown tag '$tag' (vocab: ${FLAG_TAGS[*]} ${VALUED_TAGS[*]/%/:<value>})"
        return 1
    fi
}

# A tmux format string that renders a window's tags space-separated, built from
# the vocabulary so it never drifts from it. One tmux call renders every window.
tags_format() {
    local f fmt=""
    for f in "${FLAG_TAGS[@]}";   do fmt+="#{?@tag_${f},${f} ,}"; done
    for f in "${VALUED_TAGS[@]}"; do fmt+="#{?@tag_${f},${f}:#{@tag_${f}} ,}"; done
    printf '%s' "$fmt"
}

# A tmux filter selecting windows carrying any tag at all.
any_tag_filter() {
    local f expr=""
    for f in "${FLAG_TAGS[@]}" "${VALUED_TAGS[@]}"; do
        if [ -z "$expr" ]; then expr="#{@tag_${f}}"
        else expr="#{||:#{@tag_${f}},${expr}}"; fi
    done
    printf '%s' "$expr"
}

# A tmux filter for one tag: a bare flag, a bare valued name (any value), or
# a valued tag pinned to a specific value.
tag_filter() {
    local tag="$1" name value
    case "$tag" in
        *:*) name="${tag%%:*}"; value="${tag#*:}" ;;
        *)   name="$tag";       value="" ;;
    esac
    in_list "$name" "${FLAG_TAGS[@]}" || in_list "$name" "${VALUED_TAGS[@]}" \
        || { fail "unknown tag '$tag'"; return 1; }
    if [ -n "$value" ]; then
        printf '#{==:#{@tag_%s},%s}' "$name" "$value"
    else
        printf '#{@tag_%s}' "$name"
    fi
}

# ── write verbs ──────────────────────────────────────────────────────────────
set_tag() {  # set_tag <window_id> <tag>
    local wid="$1" spec opt val
    spec=$(tag_opt "$2") || return 1
    read -r opt val <<<"$spec"
    tmux set-option -w -t "$wid" "$opt" "$val" 2>/dev/null \
        || { fail "could not set $opt on $wid"; return 1; }
}

unset_tag() {  # unset_tag <window_id> <tag>
    local wid="$1" spec opt val
    spec=$(tag_opt "$2") || return 1
    read -r opt val <<<"$spec"
    tmux set-option -uw -t "$wid" "$opt" 2>/dev/null || true
}

has_tag() {  # has_tag <window_id> <tag>
    local wid="$1" spec opt val cur
    spec=$(tag_opt "$2") || return 1
    read -r opt val <<<"$spec"
    cur=$(tmux show-options -wqv -t "$wid" "$opt" 2>/dev/null)
    [ -n "$cur" ] && [ "$cur" = "$val" ]
}

cmd_add() {
    split_target "$@"
    [ ${#ARGV_REST[@]} -ge 1 ] || die "usage: add <tag> [-t <window>]"
    local wid; wid=$(resolve_target "$TARGET_ARG") || exit 1
    local t
    for t in "${ARGV_REST[@]}"; do set_tag "$wid" "$t" || exit 1; done
    tmux display-message "tags: $(cmd_get_raw "$wid")" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

cmd_rm() {
    split_target "$@"
    [ ${#ARGV_REST[@]} -ge 1 ] || die "usage: rm <tag> [-t <window>]"
    local wid; wid=$(resolve_target "$TARGET_ARG") || exit 1
    local t
    for t in "${ARGV_REST[@]}"; do unset_tag "$wid" "$t" || exit 1; done
    tmux display-message "tags: $(cmd_get_raw "$wid")" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

cmd_toggle() {
    split_target "$@"
    [ ${#ARGV_REST[@]} -eq 1 ] || die "usage: toggle <tag> [-t <window>]"
    local wid; wid=$(resolve_target "$TARGET_ARG") || exit 1
    local tag="${ARGV_REST[0]}"
    # Validate once up front so an unknown tag cannot fall through to `set`.
    tag_opt "$tag" >/dev/null || exit 1
    # For a valued tag, toggling the SAME value clears it; a different value
    # replaces it (one group per window).
    if has_tag "$wid" "$tag"; then unset_tag "$wid" "$tag"; else set_tag "$wid" "$tag"; fi
    local now; now=$(cmd_get_raw "$wid")
    tmux display-message "tags: ${now:-(none)}" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

cmd_clear() {
    split_target "$@"
    local wid; wid=$(resolve_target "$TARGET_ARG") || exit 1
    local f
    for f in "${FLAG_TAGS[@]}" "${VALUED_TAGS[@]}"; do
        tmux set-option -uw -t "$wid" "@tag_${f}" 2>/dev/null || true
    done
    tmux display-message "tags: cleared" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# ── read verbs ───────────────────────────────────────────────────────────────
cmd_get_raw() {  # cmd_get_raw <window_id>
    tmux display-message -p -t "$1" "$(tags_format)" 2>/dev/null \
        | sed 's/[[:space:]]*$//'
}

cmd_get() {
    split_target "$@"
    local wid; wid=$(resolve_target "$TARGET_ARG") || exit 1
    cmd_get_raw "$wid"
}

# Emit TSV rows: window_id \t session \t index \t name \t path \t tags
rows() {  # rows [filter]
    local filter="${1:-$(any_tag_filter)}"
    local fmt
    fmt="#{window_id}	#{session_name}	#{window_index}	#{window_name}	#{pane_current_path}	$(tags_format)"
    tmux list-windows -a -f "$filter" -F "$fmt" 2>/dev/null \
        | sed 's/[[:space:]]*$//'
}

cmd_ls() {
    local tag="" json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) tag="${2:-}"; shift 2 || die "--tag needs a value" ;;
            --json) json=true; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    # Do NOT collapse this into `$(... && tag_filter || any_tag_filter)` - a
    # rejected tag would fall through to the any-tag filter and list everything
    # with exit 0, which is a silently wrong answer for a scripted caller.
    local filter
    if [ -n "$tag" ]; then filter=$(tag_filter "$tag") || exit 1
    else filter=$(any_tag_filter); fi
    local out; out=$(rows "$filter")

    if [ "$json" = true ]; then
        command -v jq >/dev/null 2>&1 || die "--json needs jq"
        if [ -z "$out" ]; then echo '[]'; return 0; fi
        printf '%s\n' "$out" | jq -R -s '
            split("\n") | map(select(length > 0)) | map(split("\t")) | map({
                window_id: .[0], session: .[1], window_index: (.[2]|tonumber),
                name: .[3], path: .[4],
                tags: ((.[5] // "") | split(" ") | map(select(length > 0)))
            })'
        return 0
    fi

    if [ -z "$out" ]; then
        echo "No tagged windows." >&2
        return 0
    fi
    printf '%-6s  %-16s  %-28s  %s\n' "WIN" "SESSION" "NAME" "TAGS"
    printf '%s\n' "$out" | while IFS=$'\t' read -r wid sess idx name path tags; do
        printf '%-6s  %-16s  %-28s  %s\n' "$wid" "${sess}:${idx}" "${name:0:28}" "$tags"
    done
}

cmd_targets() {
    local tag=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) tag="${2:-}"; shift 2 || die "--tag needs a value" ;;
            *) die "unknown option: $1" ;;
        esac
    done
    local filter
    if [ -n "$tag" ]; then filter=$(tag_filter "$tag") || exit 1
    else filter=$(any_tag_filter); fi
    tmux list-windows -a -f "$filter" -F '#{window_id}' 2>/dev/null
}

# Exit 0 if the window carries a protect tag. Used by cleanup.sh / wind-down.sh
# so the guard is defined in exactly one place.
cmd_protected() {
    split_target "$@"
    local wid; wid=$(resolve_target "$TARGET_ARG") || exit 1
    local t
    for t in "${PROTECT_TAGS[@]}"; do
        has_tag "$wid" "$t" && { printf '%s\n' "$t"; return 0; }
    done
    return 1
}

# ── group verbs ──────────────────────────────────────────────────────────────
# A tag is a group. These operate on every window carrying it.

require_tag() {  # require_tag <tag> -> prints filter, or exits
    [ -n "${1:-}" ] || die "this verb needs --tag <tag>"
    tag_filter "$1" || exit 1
}

cmd_gather() {
    local tag="" into=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag)  tag="${2:-}";  shift 2 || die "--tag needs a value" ;;
            --into) into="${2:-}"; shift 2 || die "--into needs a session" ;;
            *) die "unknown option: $1" ;;
        esac
    done
    local filter; filter=$(require_tag "$tag")
    [ -n "$into" ] || die "usage: gather --tag <tag> --into <session>"

    local wids; wids=$(tmux list-windows -a -f "$filter" -F '#{window_id}' 2>/dev/null)
    [ -n "$wids" ] || die "no windows tagged '$tag'"

    tmux has-session -t="$into" 2>/dev/null || tmux new-session -ds "$into" \
        || die "could not create session '$into'"

    local wid moved=0
    while IFS= read -r wid; do
        [ -n "$wid" ] || continue
        # Skip windows already in the destination, else move-window churns them.
        [ "$(tmux display-message -p -t "$wid" '#{session_name}' 2>/dev/null)" = "$into" ] && continue
        if tmux move-window -s "$wid" -t "${into}:" 2>/dev/null; then
            moved=$((moved+1))
        else
            warn "could not move $wid into $into"
        fi
    done <<<"$wids"
    echo "gathered $moved window(s) tagged '$tag' into '$into'"
}

cmd_next() {
    local tag="" from=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) tag="${2:-}"; shift 2 || die "--tag needs a value" ;;
            -t|--from) from="${2:-}"; shift 2 || die "-t needs a window" ;;
            *) die "unknown option: $1" ;;
        esac
    done
    local filter; filter=$(require_tag "$tag")
    local wids; wids=$(tmux list-windows -a -f "$filter" -F '#{window_id}' 2>/dev/null)
    [ -n "$wids" ] || die "no windows tagged '$tag'"

    # -t says "cycle as if I were here". Without it the starting point is the
    # caller's own window, which for a key binding is what you want.
    local here; here=$(resolve_target "$from") || exit 1
    # Pick the entry after the current window, wrapping to the first.
    local next
    next=$(printf '%s\n' "$wids" | awk -v cur="$here" '
        { rows[NR]=$0; if ($0==cur) idx=NR }
        END { if (idx=="" || idx==NR) print rows[1]; else print rows[idx+1] }')
    [ -n "$next" ] || die "could not pick a next window"
    focus_window "$next"
}

focus_window() {  # focus_window <window_id>
    local wid="$1" sess cli
    sess=$(tmux display-message -p -t "$wid" '#{session_name}' 2>/dev/null) \
        || die "no such window: $wid"

    # Resolve a client EXPLICITLY. A bare `switch-client -t` silently no-ops
    # when there is no "current client" - which is the case under `run-shell`
    # and for any agent driving this CLI, not just from a key binding. Prefer
    # the invoking client, else the sole attached one; with several attached,
    # switching someone else's view would be a guess, so don't.
    cli=$(tmux display-message -p '#{client_name}' 2>/dev/null)
    if [ -z "$cli" ] && [ "$(tmux list-clients -F x 2>/dev/null | wc -l)" = "1" ]; then
        cli=$(tmux list-clients -F '#{client_name}' 2>/dev/null | head -1)
    fi

    if [ -n "$cli" ]; then
        tmux switch-client -c "$cli" -t "$sess" 2>/dev/null
    elif [ -z "${TMUX:-}" ]; then
        tmux attach -t "$sess" 2>/dev/null &
        return 0
    fi
    tmux select-window -t "$wid" 2>/dev/null || die "could not select $wid"
}

cmd_kill() {
    local tag="" force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) tag="${2:-}"; shift 2 || die "--tag needs a value" ;;
            --force) force=true; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    local filter; filter=$(require_tag "$tag")
    local wids; wids=$(tmux list-windows -a -f "$filter" -F '#{window_id}' 2>/dev/null)
    [ -n "$wids" ] || die "no windows tagged '$tag'"

    local wid killed=0 skipped=0 reason
    while IFS= read -r wid; do
        [ -n "$wid" ] || continue
        if [ "$force" != true ] && reason=$(cmd_protected -t "$wid"); then
            echo "skip $wid (tagged $reason)"
            skipped=$((skipped+1))
            continue
        fi
        tmux kill-window -t "$wid" 2>/dev/null && killed=$((killed+1))
    done <<<"$wids"
    echo "killed $killed, skipped $skipped"
}

# fzf picker over tagged windows - type a tag to filter, Enter to jump.
# Bound to Prefix+W via display-popup.
cmd_pick() {
    command -v fzf >/dev/null 2>&1 || die "pick needs fzf"
    local out
    out=$(rows | awk -F'\t' '{ printf "%-6s  %-18s  %-26s  %s\n", $1, $2":"$3, substr($4,1,26), $6 }' \
        | fzf --reverse --border \
              --prompt="tag > " \
              --header="Enter = jump to window" \
              --no-multi)
    [ -n "$out" ] || return 0
    focus_window "$(printf '%s' "$out" | awk '{print $1}')"
}

cmd_vocab() {
    printf 'flags:  %s\n' "${FLAG_TAGS[*]}"
    printf 'valued: %s\n' "${VALUED_TAGS[*]/%/:<value>}"
    printf 'protect: %s\n' "${PROTECT_TAGS[*]}"
}

usage() {
    # Print the header block, however long it grows - no hardcoded line range.
    awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SELF"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
sub="${1:-ls}"; shift || true
case "$sub" in
    toggle)     cmd_toggle "$@" ;;
    add)        cmd_add "$@" ;;
    rm|remove)  cmd_rm "$@" ;;
    clear)      cmd_clear "$@" ;;
    get)        cmd_get "$@" ;;
    ls|list)    cmd_ls "$@" ;;
    targets)    cmd_targets "$@" ;;
    protected)  cmd_protected "$@" ;;
    gather)     cmd_gather "$@" ;;
    next)       cmd_next "$@" ;;
    kill)       cmd_kill "$@" ;;
    pick)       cmd_pick ;;
    vocab)      cmd_vocab ;;
    -h|--help|help) usage ;;
    *)          die "unknown subcommand: $sub (try --help)" ;;
esac
