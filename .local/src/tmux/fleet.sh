#!/usr/bin/env bash
# fleet.sh — the HEADLESS half of the cockpit: what is running that has no terminal.
#
# agent-panel (Prefix+g) can only see agents that OWN A PANE: it joins tmux panes against
# ~/.claude/sessions/<pid>.json, so anything without a pane is structurally invisible to it.
# That is most of the fleet — the agentctl units, their timers, and the sentinel watches all
# run under `systemd --user` with no terminal attached. Before this script the only readout
# was notes-cockpit's `_global_agents`, which hardcoded a seven-name roster and showed a bare
# active/inactive. This is the surface that answers "what is running, and does it need me".
#
# THE ROSTER IS THE CONF DIR, NOT A LIST IN THIS FILE. Every runner row is derived from
# ~/.config/agentctl/agents/*.conf. Drop a conf in, it appears here; no edit to this script.
# A hardcoded roster is exactly how the old view went stale, so the enumeration is the fix.
#
# State is read with `systemctl --user show -p key=value` rather than by parsing the
# `agentctl list` table: show's output is already key=value, survives column-width changes,
# and stubs cleanly in the test suite. agentctl stays the MUTATION verb (start/stop/restart).
#
# Data (all under $HOME, so the test sandbox's HOME redirect relocates it for free):
#   ~/.config/agentctl/agents/*.conf          the roster
#   ~/.local/state/agentctl/<n>/activity.log  last thing that runner actually did
#   ~/.local/state/agentctl/<n>/status        the runner status contract (state/project/
#                                             item/detail/updated) — see agentctl
#   ~/.agent/watches/*.yaml                   sentinel watch definitions
#   ~/.local/state/watch-companion/<n>.state  OK | TRIP | ERROR
#   ~/.local/state/watch-companion/<n>.lastrun  epoch of last poll (staleness)
# Writes: `agentctl start|stop|restart <n>` and `agent-ask answer` — nothing else mutates.
#
# Deliberately NO enable/disable: those change durable schedule state, and a nightly job
# switched off from a TUI is not noticed for a week. Edit the conf for that.
#
# Row wire format (TAB-delimited), consumed by fzf with --with-nth=5..:
#   1 type(head|runner|watch|ask|agent|hint)  2 id  3 target  4 state  5 DISPLAY
#
# Modes: (no args)=UI · --list · --runners · --watches · --asks · --agents
#        --runner-op <start|stop|restart> <name> · --journal <name> · --enter <type> <id> <target>

set -uo pipefail
SELF="$(realpath "$0")"

AGENTCTL_CONF_DIR="${AGENTCTL_CONF_DIR:-$HOME/.config/agentctl/agents}"
AGENTCTL_STATE_DIR="${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}"
WATCH_DIR="${WATCH_DIR:-$HOME/.agent/watches}"
WATCH_STATE_DIR="${WATCH_STATE_DIR:-$HOME/.local/state/watch-companion}"

# Same palette as notes-cockpit.sh:63-69 so the two surfaces read as one system.
C_HEAD=$'\033[1;37m' # section header (bold white)
C_SEL=$'\033[1;32m'  # healthy / active (bold green)
C_INP=$'\033[1;33m'  # needs attention (yellow)
C_ERR=$'\033[1;31m'  # tripped / failed (bold red)
C_DIM=$'\033[90m'    # dim
C_OFF=$'\033[0m'

# Glyph vocabulary shared with claude-status.sh, pr-viewer.sh and agent-panel:
#   ! needs you   ~ working   ✓ healthy   · idle
G_ATTN='!'; G_BUSY='~'; G_OK='✓'; G_IDLE='·'

row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
head_row() { row head '' '' '' "${C_HEAD}── $1 ──${C_OFF}"; }
hint_row() { row hint '' '' '' "${C_DIM}  $1${C_OFF}"; }

# _age <epoch> -> coarse human age (3d14h / 22m / 41s). Empty epoch -> "-".
_age() {
  local then="${1:-}" now d h m
  [[ "$then" =~ ^[0-9]+$ ]] || { printf -- '-'; return; }
  now="$(date +%s)"
  local s=$(( now - then ))
  (( s < 0 )) && s=0
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if   (( d > 0 )); then printf '%dd%dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh%dm' "$h" "$m"
  elif (( m > 0 )); then printf '%dm' "$m"
  else printf '%ds' "$s"; fi
}

# _yaml_desc <file> -> the watch's `description:`, flattened to one line.
# Handles both the inline form and YAML's folded/literal block scalars (`>-`, `>`, `|`,
# `|-`), which several manifests use — a naive one-line grep returns the literal ">-" for
# those, which is what the first cut of this rendered.
_yaml_desc() {
  awk '
    /^description:[[:space:]]*$/ || /^description:[[:space:]]*[|>][-+]?[[:space:]]*$/ {
      block = 1; next
    }
    /^description:[[:space:]]*/ && !block {
      sub(/^description:[[:space:]]*/, ""); print; exit
    }
    block {
      if ($0 ~ /^[^[:space:]]/) exit          # dedent ends the block
      sub(/^[[:space:]]+/, "")
      printf "%s%s", (n++ ? " " : ""), $0
    }
    END { if (block) print "" }
  ' "$1" 2>/dev/null
}

# _clip <text> <width> -> text truncated to width with an ellipsis marker.
# Watch descriptions are paragraphs (one is 300+ chars); unclipped they wrap and destroy
# the column alignment that makes the list scannable.
_clip() {
  local s="$1" w="${2:-60}"
  (( ${#s} <= w )) && { printf '%s' "$s"; return; }
  printf '%s…' "${s:0:w-1}"
}

# _show <unit> <prop> -> the value of one systemd property, or empty.
# `show` never fails on a missing unit (it prints an empty value), which is what we want:
# a conf whose unit was never installed renders as inactive rather than blowing up the row.
_show() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user show "$1" -p "$2" --value 2>/dev/null
}

# _status_get <name> <key> -> the runner's own reported value for one key, or empty.
#
# The status contract (agentctl:~120): a runner publishes key=value at
# ~/.local/state/agentctl/<n>/status — state, project, item, detail, updated. systemd can
# only say whether a unit is running; this is the half that says on WHAT. Read as a file
# rather than via `agentctl report`, deliberately: the file IS the contract, so a runner
# that never adopted it just yields empty and the row falls back to the activity tail.
_status_get() {
  local f="$AGENTCTL_STATE_DIR/$1/status"
  [ -f "$f" ] || return 0
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$f" 2>/dev/null
}

# ── runners: the agentctl units, enumerated from their conf dir ──────────────
runners() {
  head_row 'runners · agentctl'
  local conf name svc state pid rc started next glyph col detail act
  local r_state r_project r_item r_updated
  local any=0
  for conf in "$AGENTCTL_CONF_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    any=1
    name="$(basename "$conf" .conf)"
    svc="agentctl@$name.service"

    state="$(_show "$svc" ActiveState)"; state="${state:-unknown}"
    pid="$(_show "$svc" MainPID)"
    rc="$(_show "$svc" ExecMainStatus)"
    started="$(_show "$svc" ActiveEnterTimestamp)"
    next="$(_show "agentctl-$name.timer" NextElapseUSecRealtime)"

    r_state="$(_status_get "$name" state)"
    r_project="$(_status_get "$name" project)"
    r_item="$(_status_get "$name" item)"
    r_updated="$(_status_get "$name" updated)"

    # A oneshot spends nearly all its life inactive, so "inactive" is NOT a fault here;
    # only a non-zero last exit is. That distinction is the whole point of the glyph.
    #
    # `blocked` and `error` outrank the systemd view: a runner waiting on a human is a
    # perfectly healthy process, and that is precisely the case a unit state cannot show.
    if [ "$r_state" = blocked ] || [ "$r_state" = error ]; then
      glyph="$G_ATTN"; col="$C_INP"
      [ "$r_state" = error ] && col="$C_ERR"
    elif [ "$state" = active ]; then
      glyph="$G_BUSY"; col="$C_SEL"
    elif [ -n "$rc" ] && [ "$rc" != 0 ]; then
      glyph="$G_ATTN"; col="$C_ERR"
    else
      glyph="$G_IDLE"; col="$C_DIM"
    fi

    detail=""
    if [ "$state" = active ] && [ -n "$started" ]; then
      detail="up $(_age "$(date -d "$started" +%s 2>/dev/null)")"
    elif [ -n "$next" ]; then
      # NextElapseUSecRealtime is named for usec but systemctl --value renders it as a
      # formatted local timestamp ("Fri 2026-07-24 17:36:00 PDT"). Reformat it rather
      # than doing the usec arithmetic the name implies.
      detail="next $(date -d "$next" '+%a %H:%M' 2>/dev/null)"
    fi
    [ -n "$rc" ] && [ "$rc" != 0 ] && detail="${detail:+$detail · }exit $rc"

    # A reported `item` is the runner saying what it is on, in a shape this script agreed
    # to. Falling back to the last activity.log line keeps every runner that never adopted
    # the contract rendering exactly as before — adoption is per-runner, not a flag day.
    # Clip BEFORE appending the age, never after: _clip counts bytes, so clipping a string
    # that already carries SGR escapes can cut one in half and bleed colour down the list.
    if [ -n "$r_item" ]; then
      act="$(_clip "$r_item" 42)"
      [ -n "$r_updated" ] && act="$act $(_age "$r_updated") ago"
    else
      act="$(tail -n 1 "$AGENTCTL_STATE_DIR/$name/activity.log" 2>/dev/null)"
      act="$(_clip "${act#\[*\] }" 42)"
    fi

    # Field 4 stays the SYSTEMD state, as documented in the wire format at the top. The
    # reported state is shown through the glyph; folding two vocabularies into one field
    # would make `$4` mean different things on different rows.
    row runner "$name" "$svc" "$state" \
      "$(printf '  %s%s %-16s%s %s%-18s%s %s%-14s%s %s%s%s' \
        "$col" "$glyph" "$name" "$C_OFF" \
        "$C_DIM" "${detail:--}" "$C_OFF" \
        "$C_DIM" "${r_project:--}" "$C_OFF" \
        "$C_DIM" "$act" "$C_OFF")"
  done
  [ "$any" -eq 0 ] && hint_row "no agentctl confs in $AGENTCTL_CONF_DIR"
  return 0
}

# ── watches: sentinel's declarative manifests joined to their poll state ─────
watches() {
  head_row 'watches · sentinel'
  local y name state lastrun desc glyph col age
  local any=0
  for y in "$WATCH_DIR"/*.yaml; do
    [ -f "$y" ] || continue
    any=1
    name="$(basename "$y" .yaml)"
    state="$(cat "$WATCH_STATE_DIR/$name.state" 2>/dev/null)"; state="${state:-unknown}"
    lastrun="$(cat "$WATCH_STATE_DIR/$name.lastrun" 2>/dev/null)"
    desc="$(_yaml_desc "$y")"

    case "$state" in
      OK)         glyph="$G_OK";   col="$C_SEL" ;;
      TRIP)       glyph="$G_ATTN"; col="$C_ERR" ;;
      ERROR)      glyph="$G_ATTN"; col="$C_INP" ;;
      *)          glyph="$G_IDLE"; col="$C_DIM" ;;
    esac
    age="$(_age "$lastrun")"

    row watch "$name" "$y" "$state" \
      "$(printf '  %s%s %-24s%s %s%-5s%s %s%s%s' \
        "$col" "$glyph" "$name" "$C_OFF" \
        "$col" "$state" "$C_OFF" \
        "$C_DIM" "$(_clip "${desc:-$name}" 52) · ${age} ago" "$C_OFF")"
  done
  [ "$any" -eq 0 ] && hint_row "no watches in $WATCH_DIR"
  return 0
}

# ── asks: the human<->agent queue, the only rows that are literally blocking ─
asks() {
  head_row 'asks · waiting on you'
  command -v agent-ask >/dev/null 2>&1 || { hint_row 'agent-ask not on PATH'; return 0; }
  local out
  out="$(agent-ask list --all --pending 2>/dev/null)"
  if [ -z "$out" ]; then hint_row 'nothing pending'; return 0; fi
  # agent-ask list is TSV: id project profile status kind question options
  local id project kind question opts
  while IFS=$'\t' read -r id project _ _ kind question opts; do
    [ -n "$id" ] || continue
    row ask "$id" "$project" "${kind:-question}" \
      "$(printf '  %s%s %-14s%s %s%s%s %s%s%s' \
        "$C_INP" "$G_ATTN" "$project" "$C_OFF" \
        "$C_OFF" "${question:0:58}" "$C_OFF" \
        "$C_DIM" "${opts:+[$opts]}" "$C_OFF")"
  done <<< "$out"
  return 0
}

# ── agents: interactive Claude panes living OUTSIDE the session you are in ───
# agent-panel already owns the pane x ~/.claude/sessions join; shelling out to it keeps
# one implementation of that join rather than a second one that drifts.
agents() {
  head_row 'agents · other sessions'
  command -v agent-panel >/dev/null 2>&1 || { hint_row 'agent-panel not built'; return 0; }
  local here rows target glyph project summary col any=0
  here="$(tmux display-message -p '#{session_name}' 2>/dev/null)"
  rows="$(agent-panel list 2>/dev/null)"
  [ -z "$rows" ] && { hint_row 'no live agent panes'; return 0; }
  # agent-panel list is TSV: target glyph project summary
  while IFS=$'\t' read -r target glyph project summary; do
    [ -n "$target" ] || continue
    # "Outside" is the point of this section — an agent in the session you are already
    # attached to is one Prefix+g away and does not need a cockpit row.
    [ -n "$here" ] && [ "${target%%:*}" = "$here" ] && continue
    any=1
    case "$glyph" in
      "$G_ATTN") col="$C_INP" ;;
      "$G_BUSY") col="$C_SEL" ;;
      *)         col="$C_DIM" ;;
    esac
    row agent "$target" "$target" "$glyph" \
      "$(printf '  %s%s %-18s%s %s%-14s%s %s%s%s' \
        "$col" "$glyph" "$target" "$C_OFF" \
        "$C_DIM" "$project" "$C_OFF" \
        "$C_DIM" "${summary:0:52}" "$C_OFF")"
  done <<< "$rows"
  [ "$any" -eq 0 ] && hint_row 'every live agent is in this session'
  return 0
}

list_all() {
  asks
  runners
  watches
  agents
}

# ── mutation verbs ───────────────────────────────────────────────────────────

# Reversible, per-invocation verbs only. `enable`/`disable` are deliberately absent.
runner_op() {
  local op="${1:-}" name="${2:-}"
  [ -n "$name" ] || return 0
  case "$op" in
    start|stop|restart) ;;
    *) return 0 ;;
  esac
  command -v agentctl >/dev/null 2>&1 || return 0
  agentctl "$op" "$name" >/dev/null 2>&1
}

journal() { # same shape notes-cockpit.sh already uses for --journal
  local name="${1:-}"
  [ -n "$name" ] || return 0
  tmux new-window "journalctl --user -u 'agentctl@$name.service' -e -n 200 || journalctl --user -u 'agentctl@$name.service'" 2>/dev/null
}

enter_action() { # $1=type $2=id $3=target — what Enter means for each row kind
  local type="${1:-}" id="${2:-}" target="${3:-}"
  case "$type" in
    ask)    tmux new-window "agent-ask show '$id'; agent-ask answer '$id'" 2>/dev/null ;;
    watch)  [ -f "$target" ] && tmux new-window "nvim '$target'" 2>/dev/null ;;
    runner) journal "$id" ;;
    agent)  tmux switch-client -t "$target" 2>/dev/null || tmux attach -t "$target" 2>/dev/null ;;
  esac
}

help_view() {
  cat <<'EOF'
fleet — headless agents, watches and asks

  nav
    j / k          down / up
    enter          ask: answer it · runner: journal · watch: edit manifest · agent: jump
    r              refresh

  runner  (agentctl units, roster = ~/.config/agentctl/agents/*.conf)
    s              start
    x              stop
    R              restart
    l              journalctl for the unit

  glyphs
    !  needs you / last run failed      ~  active now
    ✓  healthy                          ·  idle (normal for a oneshot)

  enable/disable are deliberately NOT here: they change durable schedule state.
  Edit the unit's .conf instead.

  q / esc        quit
EOF
}

case "${1:-}" in
  --list) list_all; exit 0 ;;
  --runners) runners; exit 0 ;;
  --watches) watches; exit 0 ;;
  --asks) asks; exit 0 ;;
  --agents) agents; exit 0 ;;
  --runner-op) shift; runner_op "$@"; exit 0 ;;
  --journal) shift; journal "$@"; exit 0 ;;
  --enter) shift; enter_action "$@"; exit 0 ;;
  --help-view) help_view; exit 0 ;;
esac

# Sourced by the test suite rather than run: stop here with every function defined but the
# UI never launched. Must sit after the verb dispatch (so --verb still works) and before
# the fzf preflight (so sourcing never needs fzf on PATH). Same seam as notes-cockpit.sh.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }

list_all | fzf \
  --ansi --reverse --cycle --no-sort --border --no-input --wrap \
  --delimiter=$'\t' --with-nth='5..' \
  --prompt='search > ' \
  --header='enter act · s/x/R start/stop/restart · l logs · ? keys' \
  --bind "?:execute($SELF --help-view | less -R)" \
  --bind 'j:down+transform:[ {1} = head ] && echo down' \
  --bind 'k:up+transform:[ {1} = head ] && echo up' \
  --bind 'load:transform:[ {1} = head ] && echo down' \
  --bind 'q:abort' \
  --bind "r:reload($SELF --list)" \
  --bind "enter:execute-silent($SELF --enter {1} {2} {3})+reload($SELF --list)" \
  --bind "s:execute-silent($SELF --runner-op start {2})+reload($SELF --list)" \
  --bind "x:execute-silent($SELF --runner-op stop {2})+reload($SELF --list)" \
  --bind "R:execute-silent($SELF --runner-op restart {2})+reload($SELF --list)" \
  --bind "l:execute-silent($SELF --journal {2})"
