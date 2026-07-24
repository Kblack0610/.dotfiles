#!/usr/bin/env bash
# agent-bridge.sh — the human<->agent BRIDGE: one fzf surface for "what needs me".
#
# The prefix-g surface. Composes, most-actionable first:
#   ?  asks    — open questions from agents        (agent-ask list --pending --all)
#   !  gates   — human approval/decision gates      (sprint blackboard ## Human/Hard gates)
#   *  trips   — sentinel watches currently tripped (~/.local/state/watch-companion/*.state)
#   .  live    — drop into the live-agent chooser   (delegates to agent-panel)
#
# Same practice as notes-cockpit.sh / agent-panel: fzf + tmux stay the UI, the small
# CLIs (agent-ask, agent-panel) stay the data + mutation core. Answering an ask writes
# back via `agent-ask answer`, which flips it to answered and pings agent-notify — the
# round-trip a headless producer (delivery-loop, /kb:sprint) consumes on its next fire.
#
# Row wire format (TAB), consumed by fzf with --with-nth=6..:
#   1 kind(ask|gate|trip|live|head|hint)  2 id/name  3 project  4 file  5 options  6 DISPLAY

set -uo pipefail
SELF="$(realpath "$0")"

WATCH_STATE="${SENTINEL_STATE:-$HOME/.local/state/watch-companion}"
WATCH_DIR="$HOME/.agent/watches"
PLANS="$HOME/.agent/plans"

C_ASK=$'\033[1;36m'   # ask (cyan)
C_GATE=$'\033[1;33m'  # gate (yellow)
C_TRIP=$'\033[1;31m'  # trip (red)
C_LIVE=$'\033[1;32m'  # live (green)
C_HEAD=$'\033[1;37m'  # section header (bold white)
C_DIM=$'\033[90m'
C_OFF=$'\033[0m'

_head() { printf 'head\t\t\t\t\t%s── %s ──%s\n' "$C_HEAD" "$1" "$C_OFF"; }

# ── ? asks ─────────────────────────────────────────────────────────
# awk (FS='\t') NOT `while read`: `read` treats tab as IFS-whitespace and collapses
# empty fields, which shifts every column when profile/task is blank.
emit_asks() {
  agent-ask list --all --pending 2>/dev/null \
  | awk -F'\t' -v cask="$C_ASK" -v cgate="$C_GATE" -v coff="$C_OFF" -v cdim="$C_DIM" '
      $1 == "" { next }
      {
        id=$1; project=$2; kind=$5; question=$6; options=$7
        glyph="?"; col=cask
        if (kind=="gate" || kind=="approval") { glyph="!"; col=cgate }
        opt = (options != "") ? "  " cdim "(" options ")" coff : ""
        # wire: ask <id> <project> <file=empty> <options> <DISPLAY>
        printf "ask\t%s\t%s\t\t%s\t%s%s%s %s[%s]%s %s%s\n",
          id, project, options, col, glyph, coff, cdim, project, coff, question, opt
      }'
}

# ── ! gates ────────────────────────────────────────────────────────
# First cut: the newest sprint blackboard per project, non-checked lines under a
# `## Human gates` / `## Hard gates` section. (Live Vikunja HUMAN: / GitHub approval
# issue detection is a follow-up.)
emit_gates() {
  local d project bb line
  [ -d "$PLANS" ] || return 0
  for d in "$PLANS"/*/; do
    project="$(basename "$d")"
    bb="$(ls -1t "$d"sprint-*.md 2>/dev/null | head -1)"
    [ -n "$bb" ] || continue
    awk '
      /^## +(Human gates|Hard gates)/ { f=1; next }
      /^## / { f=0 }
      f && /- \[ \]/ { print }
    ' "$bb" 2>/dev/null | while IFS= read -r line; do
      local clean; clean="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*- \[ \] //')"
      printf 'gate\t%s\t%s\t%s\t\t%s!%s %s%s[%s]%s %s\n' \
        "$project" "$project" "$bb" \
        "$C_GATE" "$C_OFF" "$C_DIM" "" "$project" "$C_OFF" "$clean"
    done
  done
}

# ── * sentinel trips ───────────────────────────────────────────────
emit_trips() {
  local f name status desc
  [ -d "$WATCH_STATE" ] || return 0
  for f in "$WATCH_STATE"/*.state; do
    [ -f "$f" ] || continue
    status="$(cat "$f" 2>/dev/null)"
    case "$status" in TRIP|ERROR) ;; *) continue ;; esac
    name="$(basename "$f" .state)"
    desc="$(sed -n 's/^description: //p' "$WATCH_DIR/$name.yaml" 2>/dev/null | head -1)"
    printf 'trip\t%s\t\t\t\t%s*%s %s%s%s  %s%s%s\n' \
      "$name" "$C_TRIP" "$C_OFF" "$name" "" "" "$C_DIM" "${status} — ${desc}" "$C_OFF"
  done
}

# ── . live agents ──────────────────────────────────────────────────
emit_live() {
  command -v agent-panel >/dev/null 2>&1 || return 0
  printf 'live\t\t\t\t\t%s.%s %sopen live-agent chooser (jump to a running pane)%s\n' \
    "$C_LIVE" "$C_OFF" "$C_DIM" "$C_OFF"
}

list_all() {
  local asks gates trips
  asks="$(emit_asks)"; gates="$(emit_gates)"; trips="$(emit_trips)"
  if [ -n "$asks" ]; then _head "asks — answer to unblock"; printf '%s\n' "$asks"; fi
  if [ -n "$gates" ]; then _head "gates — your decision"; printf '%s\n' "$gates"; fi
  if [ -n "$trips" ]; then _head "sentinel — tripped"; printf '%s\n' "$trips"; fi
  _head "live"; emit_live
  if [ -z "$asks$gates$trips" ]; then
    printf 'hint\t\t\t\t\t%s(nothing needs you right now)%s\n' "$C_DIM" "$C_OFF"
  fi
}

# preview pane: full detail of the selected row
preview() { # $1=kind $2=id/name $3=project $4=file
  case "$1" in
    ask)  agent-ask show "$2" 2>/dev/null ;;
    trip) printf '%s%s%s\n\n' "$C_TRIP" "$2" "$C_OFF"; cat "$WATCH_DIR/$2.yaml" 2>/dev/null ;;
    gate) printf '%s%s%s\n\n' "$C_HEAD" "$3" "$C_OFF"
          awk '/^## +(Human gates|Hard gates)/{f=1} /^## /{if(f&&!/gates/)f=0} f' "$4" 2>/dev/null ;;
    live) printf 'Enter: open the live-agent chooser (agent-panel).\nprefix G still jumps to the next attention pane.' ;;
    *)    printf '%sagent bridge%s\n\nAnswer asks, clear gates, see sentinel trips.\nq to quit.' "$C_DIM" "$C_OFF" ;;
  esac
}

# answer an ask: pick from options if any, else read free text; then write back
answer_ask() { # $1=id $2=options(pipe)
  local id="$1" options="${2:-}" ans
  [ -n "$id" ] || return 0
  if [ -n "$options" ]; then
    ans="$(printf '%s\n' "${options//|/$'\n'}" | fzf --prompt="answer $id > " --height=40% --reverse)"
  else
    printf 'answer for %s: ' "$id" >&2
    read -r ans
  fi
  [ -n "$ans" ] || return 0
  agent-ask answer "$id" "$ans"
}

open_row() { # $1=kind $2=id/name $3=project $4=file $5=options
  case "$1" in
    ask)  answer_ask "$2" "$5" ;;
    gate) [ -f "$4" ] && tmux new-window "nvim '$4'" ;;
    trip) [ -f "$WATCH_DIR/$2.yaml" ] && tmux new-window "nvim '$WATCH_DIR/$2.yaml'" ;;
    live) exec agent-panel ;;
  esac
}

case "${1:-}" in
  --list)    list_all; exit 0 ;;
  --preview) shift; preview "$@"; exit 0 ;;
  --answer)  shift; answer_ask "$@"; exit 0 ;;
  --open)    shift; open_row "$@"; exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }
command -v agent-ask >/dev/null 2>&1 || { echo "agent-ask not found (build ~/.dotfiles/.local/bin/agent-ask)"; exit 1; }

list_all | fzf \
  --ansi --reverse --cycle --no-sort --border --wrap \
  --delimiter=$'\t' --with-nth='6..' \
  --prompt='bridge > ' \
  --header='enter answer/open · r refresh · q quit' \
  --preview "$SELF --preview {1} {2} {3} {4}" \
  --preview-window 'right:45%:wrap:border-left' \
  --bind 'ctrl-/:toggle-preview' \
  --bind 'j:down+transform:[ {1} = head ] && echo down' \
  --bind 'k:up+transform:[ {1} = head ] && echo up' \
  --bind 'load:transform:[ {1} = head ] && echo down' \
  --bind "r:reload($SELF --list)+refresh-preview" \
  --bind 'q:abort' \
  --bind "enter:execute($SELF --open {1} {2} {3} {4} {5})+reload($SELF --list)+refresh-preview"
