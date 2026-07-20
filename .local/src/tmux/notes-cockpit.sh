#!/usr/bin/env bash
# notes-cockpit.sh — a native fzf task cockpit over EVERY notes profile + projects,
# organized into navigable SECTIONS (all / personal / work / projects).
#   work = any non-personal (job) profile, grouped per profile.
#
# Same practice as agent-panel / sessionizer.sh: fzf + tmux stay the UI, the `notes`
# Rust CLI stays the data + mutation core. NO editor hosts the picker, so Esc just
# closes the popup. nvim opens ONLY when you deliberately press Enter to edit a line.
#
# Data:   `notes focus --all`  -> profile<TAB>file<TAB>line<TAB>key<TAB>text
#         `notes projects`     -> name<TAB>summary<TAB>status   (project-name source)
# Writes: `notes --profile <p> focus done|rm|add …`  (the vault-safe CLI verbs)
#
# Sections: a slim LEFT sidebar (the fzf preview pane) lists all/personal/machines/
# projects with open counts + the active one marked. fzf has ONE selectable list, so
# you switch sections with number keys 1-4 or Tab (the rail is the indicator); the
# main list is the selectable, actionable task pane.
#
# Row wire format (TAB-delimited), consumed by fzf with --with-nth=7..:
#   1 type(task|head)  2 profile  3 file  4 line  5 key  6 section  7 DISPLAY(ANSI)
#
# Modes: (no args)=UI · --list [section] · --rail · --next-section · --add · --jump

set -uo pipefail
SELF="$(realpath "$0")"
STATE="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}.section"
SECTIONS=(all personal work projects)

C_BOX=$'\033[36m'    # checkbox (cyan)
C_HEAD=$'\033[1;37m' # group header (bold white)
C_SEL=$'\033[1;32m'  # active section (bold green)
C_DIM=$'\033[90m'    # dim
C_OFF=$'\033[0m'

read_section() { cat "$STATE" 2>/dev/null || echo all; }

# ── classify one task's text into a section ─────────────────────────
# Precedence: any non-personal (job) profile → work; then an explicit `prefix:` or a
# keyword that matches a live project name (from `notes projects`) → projects; else
# personal. Project/profile names are RUNTIME data — never hardcoded here.
classify() {
  local text="$1" profile="$2" projects_lc="$3" lc prefix p
  [ "$profile" != "personal" ] && { echo "work/$profile"; return; }
  lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lc" =~ ^([a-z0-9_-]+): ]]; then
    prefix="${BASH_REMATCH[1]}"
    for p in $projects_lc; do [ "$prefix" = "$p" ] && { echo "projects/$p"; return; }; done
    echo "personal"; return
  fi
  for p in $projects_lc; do case "$lc" in *"$p"*) echo "projects/$p"; return ;; esac; done
  echo "personal"
}

# ── emit every open task as: type profile file line key section cleantext ──
emit_tasks() {
  local PROJECTS_LC
  PROJECTS_LC="$(notes projects 2>/dev/null | cut -f1 | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
  notes focus --all 2>/dev/null | while IFS=$'\t' read -r profile file line key text; do
    [ -z "$profile" ] && continue
    local section clean
    # strip the checkbox + <!-- since --> comment FIRST, then classify on the clean text
    # so a leading `prefix:` (pmp:, home-config:) is at the start of the string.
    clean="$(printf '%s' "$text" | sed -E 's/ *<!--[^>]*-->//; s/^[[:space:]]*- \[[ xX]\] //')"
    section="$(classify "$clean" "$profile" "$PROJECTS_LC")"
    printf 'task\t%s\t%s\t%s\t%s\t%s\t%s\n' "$profile" "$file" "$line" "$key" "$section" "$clean"
  done
}

# ── render helpers (final fzf rows: col7 = "[ ] text", headers are type=head) ──
_flat() { # $1=rows $2=exact-section
  printf '%s\n' "$1" | awk -F'\t' -v w="$2" -v b="$C_BOX" -v o="$C_OFF" \
    '$6==w { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s[ ]%s %s\n", $1,$2,$3,$4,$5,$6,b,o,$7 }'
}
_header() { printf 'head\t\t\t\t\t\t%s── %s ──%s\n' "$C_HEAD" "$1" "$C_OFF"; }
_group() { # $1=rows $2=exact-section $3=label — header only when non-empty
  local body; body="$(_flat "$1" "$2")"
  [ -z "$body" ] && return 0
  _header "$3"; printf '%s\n' "$body"
}
_project_groups() { # $1=rows — one header per distinct projects/<name>
  local names n
  names="$(printf '%s\n' "$1" | awk -F'\t' '$6 ~ /^projects\// { sub(/^projects\//,"",$6); print $6 }' | sort -u)"
  while IFS= read -r n; do [ -n "$n" ] && _group "$1" "projects/$n" "$n"; done <<< "$names"
}
_work_groups() { # $1=rows — one header per distinct work/<profile>
  local names n
  names="$(printf '%s\n' "$1" | awk -F'\t' '$6 ~ /^work\// { sub(/^work\//,"",$6); print $6 }' | sort -u)"
  while IFS= read -r n; do [ -n "$n" ] && _group "$1" "work/$n" "$n"; done <<< "$names"
}

list_section() {
  local want="${1:-}"; [ -z "$want" ] && want="$(read_section)"
  local rows; rows="$(emit_tasks)"
  case "$want" in
    all)
      _group "$rows" personal personal
      _work_groups "$rows"
      _project_groups "$rows"
      ;;
    projects) _project_groups "$rows" ;;
    work) _work_groups "$rows" ;;
    personal) _flat "$rows" "$want" ;;
    *) _flat "$rows" "$want" ;;
  esac
}

# ── the left sidebar rail (fzf preview): sections + counts, active marked ──
rail() {
  local cur ct s n
  cur="$(read_section)"
  ct="$(emit_tasks | awk -F'\t' '{ s=$6; sub(/\/.*/,"",s); c[s]++; t++ } END { for (k in c) print k, c[k]; print "all", t }')"
  printf '%s SECTIONS%s\n\n' "$C_HEAD" "$C_OFF"
  for s in "${SECTIONS[@]}"; do
    n="$(awk -v k="$s" '$1==k{print $2}' <<< "$ct")"; n="${n:-0}"
    if [ "$s" = "$cur" ]; then
      printf '%s> %-9s %s%s\n' "$C_SEL" "$s" "$n" "$C_OFF"
    else
      printf '  %-9s %s%s%s\n' "$s" "$C_DIM" "$n" "$C_OFF"
    fi
  done
  printf '\n%s 1-4 / Tab%s\n%s to switch%s\n' "$C_DIM" "$C_OFF" "$C_DIM" "$C_OFF"
}

next_section() {
  local cur i; cur="$(read_section)"
  for i in "${!SECTIONS[@]}"; do
    if [ "${SECTIONS[$i]}" = "$cur" ]; then
      echo "${SECTIONS[$(((i + 1) % ${#SECTIONS[@]}))]}" > "$STATE"; return
    fi
  done
  echo all > "$STATE"
}

add_task() {
  local profile="$1"
  [ -z "$profile" ] && return 0
  local text
  read -r -p "add to ${profile}: " text || return 0
  [ -n "${text// /}" ] && notes --profile "$profile" focus add "$text"
}

jump_row() { # $1=type $2=file $3=line — deliberate edit in a new tmux window
  local type="$1" file="$2" line="$3"
  [ "$type" = "task" ] || return 0
  [ -f "$file" ] || return 0
  local ln="${line:-1}"; [[ "$ln" =~ ^[0-9]+$ ]] || ln=1
  tmux new-window "nvim +${ln} '$file'"
}

case "${1:-}" in
  --list) shift; list_section "${1:-}"; exit 0 ;;
  --rail) rail; exit 0 ;;
  --next-section) next_section; exit 0 ;;
  --add) add_task "${2:-}"; exit 0 ;;
  --jump) shift; jump_row "$@"; exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }
command -v notes >/dev/null 2>&1 || { echo "notes CLI not found (build ~/.dotfiles/.local/src/notes-cli)"; exit 1; }

echo all > "$STATE" # every launch starts on the all-tasks view
HEADER='1-4/Tab section   enter edit   C-x done   C-a add   C-d del   esc quit'

list_section all | fzf \
  --ansi --reverse --cycle --no-sort --border \
  --delimiter=$'\t' --with-nth='7..' \
  --prompt='cockpit > ' \
  --header="$HEADER" \
  --preview "$SELF --rail" \
  --preview-window 'left:22%:wrap:border-right' \
  --bind 'ctrl-/:toggle-preview' \
  --bind 'up:up+transform:[ {1} = head ] && echo up' \
  --bind 'down:down+transform:[ {1} = head ] && echo down' \
  --bind 'load:transform:[ {1} = head ] && echo down' \
  --bind "1:execute-silent(echo all > $STATE)+reload($SELF --list)+refresh-preview" \
  --bind "2:execute-silent(echo personal > $STATE)+reload($SELF --list)+refresh-preview" \
  --bind "3:execute-silent(echo work > $STATE)+reload($SELF --list)+refresh-preview" \
  --bind "4:execute-silent(echo projects > $STATE)+reload($SELF --list)+refresh-preview" \
  --bind "tab:execute-silent($SELF --next-section)+reload($SELF --list)+refresh-preview" \
  --bind "ctrl-x:execute-silent(notes --profile {2} focus done {5})+reload($SELF --list)+refresh-preview" \
  --bind "ctrl-d:execute-silent(notes --profile {2} focus rm {5})+reload($SELF --list)+refresh-preview" \
  --bind "ctrl-a:execute($SELF --add {2})+reload($SELF --list)+refresh-preview" \
  --bind "enter:execute-silent($SELF --jump {1} {3} {4})+abort"
