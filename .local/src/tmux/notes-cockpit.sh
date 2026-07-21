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
# Optional machine-local prefix->project alias file (keeps private project names OUT of
# this public script). Format: `prefix=project` per line (e.g. a short tag -> its full
# project name), so a `tag:` prefix classifies under that project.
ALIAS_FILE="${NOTES_COCKPIT_ALIASES:-$HOME/.config/notes-cockpit/aliases}"

alias_of() { # $1=prefix -> mapped project name (or nothing)
  [ -f "$ALIAS_FILE" ] || return 0
  awk -F= -v k="$1" '!/^[[:space:]]*#/ && $1==k { print $2; exit }' "$ALIAS_FILE"
}

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
    local mapped; mapped="$(alias_of "$prefix")"    # short tag -> full project (machine-local)
    [ -n "$mapped" ] && prefix="$mapped"
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
    # `/` is the in-progress state (the editor's <leader>t cycle) and is a genuine open
    # task, so it must strip like ` `/`x` — otherwise the row renders as "[ ] - [/] text".
    clean="$(printf '%s' "$text" | sed -E 's/ *<!--[^>]*-->//; s/^[[:space:]]*- \[[ /xX]\] //')"
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
_work_groups() { # $1=rows — one header per distinct work/<profile>
  local names n
  names="$(printf '%s\n' "$1" | awk -F'\t' '$6 ~ /^work\// { sub(/^work\//,"",$6); print $6 }' | sort -u)"
  while IFS= read -r n; do [ -n "$n" ] && _group "$1" "work/$n" "$n"; done <<< "$names"
}
# The projects VIEW lists EVERY lab project (from `notes projects`), even empty ones,
# with a selectable placeholder so C-a can add to a project that has no tasks yet.
_all_projects() { # $1=rows
  local n lc body
  notes projects 2>/dev/null | cut -f1 | while IFS= read -r n; do
    [ -z "$n" ] && continue
    lc="$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')"
    _header "$n"
    body="$(_flat "$1" "projects/$lc")"
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    else
      # placeholder row: selectable (type=add), carries the section so C-a targets it
      printf 'add\t\t\t\t\tprojects/%s\t%s(no tasks — C-a to add)%s\n' "$lc" "$C_DIM" "$C_OFF"
    fi
  done
}

list_section() {
  local want="${1:-}"; [ -z "$want" ] && want="$(read_section)"
  local rows; rows="$(emit_tasks)"
  # A fresh day has no daily note yet, so `focus --all` is empty and every section
  # reads 0 — which looks like data loss. Say so, and offer the one-key fix.
  if [ -z "$rows" ]; then
    printf 'hint\t\t\t\t\t\t%s(no daily note for today — press T to create it and carry tasks forward)%s\n' \
      "$C_DIM" "$C_OFF"
  fi
  case "$want" in
    all)
      _group "$rows" personal personal
      _work_groups "$rows"
      _all_projects "$rows"
      ;;
    projects) _all_projects "$rows" ;;
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
}

_cycle_section() { # $1 = +1 (next) or -1 (prev)
  local cur i n=${#SECTIONS[@]}; cur="$(read_section)"
  for i in "${!SECTIONS[@]}"; do
    if [ "${SECTIONS[$i]}" = "$cur" ]; then
      echo "${SECTIONS[$(((i + $1 + n) % n))]}" > "$STATE"; return
    fi
  done
  echo all > "$STATE"
}
next_section() { _cycle_section 1; }
prev_section() { _cycle_section -1; }

# Add a task to whatever SECTION you're on: work/<profile> -> that job profile;
# projects/<name> -> a personal task tagged `<name>:` (so it re-classifies to that
# project); else a plain personal task. Lets you add to pmp while browsing projects.
add_task() {
  local section="${1:-personal}" profile="personal" prefix="" text
  case "$section" in
    work/*) profile="${section#work/}" ;;
    projects/*) prefix="${section#projects/}: " ;;
  esac
  read -r -p "add to ${section}: " text || return 0
  [ -n "${text// /}" ] && notes --profile "$profile" focus add "${prefix}${text}"
}

# ── move a task between sections (personal / work profile / project) ──
# A job section IS a profile; a project section is a `<project>:` prefix on a personal
# task. `focus mv` handles both, carrying the task's original age across the move.
move_task() { # $1=row section  $2=row profile  $3=row key
  local section="${1:-}" profile="${2:-}" key="${3:-}" dest
  if [ -z "$key" ] || [ -z "$profile" ]; then
    echo "not on a task row"; sleep 1; return 0
  fi
  dest="$( {
      echo personal
      notes config --profiles 2>/dev/null | grep -vx personal | sed 's|^|work/|'
      notes projects 2>/dev/null | cut -f1 | sed 's|^|projects/|'
    } | grep -vxF "$section" | fzf --prompt='move to > ' --height=100% --reverse )" || return 0
  [ -z "$dest" ] && return 0
  case "$dest" in
    personal) notes --profile "$profile" focus mv "$key" --to personal --untag ;;
    work/*) notes --profile "$profile" focus mv "$key" --to "${dest#work/}" --untag ;;
    projects/*) notes --profile "$profile" focus mv "$key" --to personal --tag "${dest#projects/}" ;;
  esac
}

# ── project lifecycle (create / archive / restore), via the notes CLI ──
new_project() {
  local name
  read -r -p "new project name: " name || return 0
  [ -n "${name// /}" ] && notes projects --new "$name"
}

archive_project() { # $1 = section of the highlighted row (projects/<name>)
  local section="${1:-}" name ans
  case "$section" in
    projects/*) name="${section#projects/}" ;;
    *) echo "not on a project row (go to the projects section)"; sleep 1; return 0 ;;
  esac
  read -r -p "archive project '$name'? [y/N] " ans || return 0
  case "$ans" in y | Y) notes projects --archive "$name" ;; esac
}

restore_project() {
  local pick name
  pick="$(notes projects --archived 2>/dev/null \
    | fzf --delimiter=$'\t' --with-nth=1 --prompt='restore project > ' --height=100% --reverse)" || return 0
  name="$(printf '%s' "$pick" | cut -f1)"
  [ -n "$name" ] && notes projects --restore "$name"
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
  --prev-section) prev_section; exit 0 ;;
  --add) add_task "${2:-}"; exit 0 ;;
  --jump) shift; jump_row "$@"; exit 0 ;;
  --move) shift; move_task "$@"; exit 0 ;;
  --new-project) new_project; exit 0 ;;
  --archive-project) archive_project "${2:-}"; exit 0 ;;
  --restore-project) restore_project; exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }
command -v notes >/dev/null 2>&1 || { echo "notes CLI not found (build ~/.dotfiles/.local/src/notes-cli)"; exit 1; }

echo all > "$STATE" # every launch starts on the all-tasks view
HEADER='j/k move   h/l section   i search   enter edit   C-x done   C-a add   C-d del   m move   n/A/R project   T today   q quit'
# modal nav: the printable keys that mean "command" in normal mode but must TYPE while
# searching. `i` shows the input and unbinds them; leaving search (esc) rebinds them.
MODAL='j,k,h,l,i,q,m,n,A,R,T,1,2,3,4'

# start in --no-input (browse) mode: no query box, hjkl navigate, i enters search.
list_section all | fzf \
  --ansi --reverse --cycle --no-sort --border --no-input \
  --delimiter=$'\t' --with-nth='7..' \
  --prompt='search > ' \
  --header="$HEADER" \
  --preview "$SELF --rail" \
  --preview-window 'left:22%:wrap:border-right' \
  --bind 'ctrl-/:toggle-preview' \
  --bind 'j:down+transform:[ {1} = head ] && echo down' \
  --bind 'k:up+transform:[ {1} = head ] && echo up' \
  --bind 'up:up+transform:[ {1} = head ] && echo up' \
  --bind 'down:down+transform:[ {1} = head ] && echo down' \
  --bind 'load:transform:[ {1} = head ] && echo down' \
  --bind "h:execute-silent($SELF --prev-section)+reload($SELF --list)+refresh-preview" \
  --bind "l:execute-silent($SELF --next-section)+reload($SELF --list)+refresh-preview" \
  --bind "1:execute-silent(echo all > $STATE)+reload($SELF --list)+refresh-preview" \
  --bind "2:execute-silent(echo personal > $STATE)+reload($SELF --list)+refresh-preview" \
  --bind "3:execute-silent(echo work > $STATE)+reload($SELF --list)+refresh-preview" \
  --bind "4:execute-silent(echo projects > $STATE)+reload($SELF --list)+refresh-preview" \
  --bind "tab:execute-silent($SELF --next-section)+reload($SELF --list)+refresh-preview" \
  --bind "i:show-input+unbind($MODAL)" \
  --bind "esc:transform:[ \"\$FZF_INPUT_STATE\" = hidden ] && echo abort || echo \"clear-query+hide-input+rebind($MODAL)\"" \
  --bind 'q:abort' \
  --bind "ctrl-x:execute-silent(notes --profile {2} focus done {5})+reload($SELF --list)+refresh-preview" \
  --bind "ctrl-d:execute-silent(notes --profile {2} focus rm {5})+reload($SELF --list)+refresh-preview" \
  --bind "ctrl-a:execute($SELF --add {6})+reload($SELF --list)+refresh-preview" \
  --bind "m:execute($SELF --move {6} {2} {5})+reload($SELF --list)+refresh-preview" \
  --bind "n:execute($SELF --new-project)+reload($SELF --list)+refresh-preview" \
  --bind "A:execute($SELF --archive-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "R:execute($SELF --restore-project)+reload($SELF --list)+refresh-preview" \
  --bind "T:execute-silent(notes today --all)+reload($SELF --list)+refresh-preview" \
  --bind "enter:execute-silent($SELF --jump {1} {3} {4})+abort"
