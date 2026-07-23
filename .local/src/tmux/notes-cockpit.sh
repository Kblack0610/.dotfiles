#!/usr/bin/env bash
# notes-cockpit.sh — a native fzf task cockpit over every notes profile + its projects.
#
# SECTIONS ARE PROFILES. Each profile (personal + every job) is its own section, and a
# profile's own projects are nested inside it — because projects are per-profile in the
# vault (each profile config points at its own `projects/current` root). So the sidebar
# reads `all / personal / <job> / <job>`, and drilling into one shows that context's
# untagged tasks followed by a group per project.
#
# Same practice as agent-panel / sessionizer.sh: fzf + tmux stay the UI, the `notes`
# Rust CLI stays the data + mutation core. NO editor hosts the picker, so Esc just
# closes the popup. nvim opens ONLY when you deliberately press Enter to edit a line.
#
# Data:   `notes focus --all`            -> profile<TAB>file<TAB>line<TAB>key<TAB>text
#         `notes config --profiles`      -> the section list
#         `notes --profile P projects`   -> that profile's projects
# Writes: `notes --profile P focus add|done|rm|mv …`   (the vault-safe CLI verbs)
#
# A task belongs to a project via a `<project>:` text prefix; a task belongs to a
# profile by living in that profile's daily note. So `section` is `<profile>` for an
# untagged task and `<profile>/<project>` for a tagged one, and moving a task is
# `focus mv --to <profile> [--tag <project>|--untag]`.
#
# Row wire format (TAB-delimited), consumed by fzf with --with-nth=7..:
#   1 type(task|head|add|hint)  2 profile  3 file  4 line  5 key  6 section  7 DISPLAY
#
# Modes: (no args)=UI · --list [section] · --rail · --next/prev-section · --add
#        --move · --jump · --new-project · --archive-project · --restore-project

set -uo pipefail
SELF="$(realpath "$0")"
STATE="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}.section"
# Optional machine-local prefix->project alias file (keeps private project names OUT of
# this public script). Format: `prefix=project` per line (e.g. a short tag -> its full
# project name), so a `tag:` prefix classifies under that project.
ALIAS_FILE="${NOTES_COCKPIT_ALIASES:-$HOME/.config/notes-cockpit/aliases}"

alias_of() { # $1=prefix -> mapped project name (or nothing)
  [ -f "$ALIAS_FILE" ] || return 0
  awk -F= -v k="$1" '!/^[[:space:]]*#/ && $1==k { print $2; exit }' "$ALIAS_FILE"
}

C_BOX=$'\033[36m'    # todo checkbox (cyan)
C_INP=$'\033[1;33m'  # in-progress checkbox (yellow)
C_HEAD=$'\033[1;37m' # profile header (bold white)
C_PROJ=$'\033[1;35m' # project sub-header (magenta)
C_SEL=$'\033[1;32m'  # active section (bold green)
C_DIM=$'\033[90m'    # dim
C_OFF=$'\033[0m'

read_section() { cat "$STATE" 2>/dev/null || echo personal; }

profiles() { notes config --profiles 2>/dev/null; }
# the sidebar: one section per profile, personal first, then the rest
sections_list() {
  profiles | grep -xF personal
  profiles | grep -vxF personal
}

# projects_of <profile> -> space-separated lowercase project names
projects_of() {
  notes --profile "$1" projects 2>/dev/null | cut -f1 | tr '[:upper:]' '[:lower:]' | tr '\n' ' '
}

# ── classify a task into `<profile>` or `<profile>/<project>` ───────
# A leading `tag:` (optionally via the alias file) that names one of THAT PROFILE's
# projects wins; else a bare mention of one of them; else the profile itself.
classify() {
  local text="$1" profile="$2" projects_lc="$3" lc prefix p
  lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lc" =~ ^([a-z0-9_-]+): ]]; then
    prefix="${BASH_REMATCH[1]}"
    local mapped; mapped="$(alias_of "$prefix")" # short tag -> full project name
    [ -n "$mapped" ] && prefix="$mapped"
    for p in $projects_lc; do [ "$prefix" = "$p" ] && { echo "$profile/$p"; return; }; done
    echo "$profile"; return
  fi
  for p in $projects_lc; do case "$lc" in *"$p"*) echo "$profile/$p"; return ;; esac; done
  echo "$profile"
}

# ── one task row: type profile file line key section cleantext ──
# Shared formatter for both daily `## Focus` tasks and project-sheet `## Wave` tasks (both
# arrive as `path<TAB>line<TAB>key<TAB>rawtext`). `section` places the row: `<profile>` for
# an untagged/main task, `<profile>/<project>` for a project task.
_task_row() { # $1=profile $2=file $3=line $4=key $5=section $6=rawtext
  local clean glyph
  clean="$(printf '%s' "$6" | sed -E 's/ *<!--[^>]*-->//; s/^[[:space:]]*- \[[ /xX]\] //')"
  if [[ "$6" =~ ^[[:space:]]*-\ \[/\] ]]; then glyph="${C_INP}[/]${C_OFF}"; else glyph="${C_BOX}[ ]${C_OFF}"; fi
  printf 'task\t%s\t%s\t%s\t%s\t%s\t%s %s\n' "$1" "$2" "$3" "$4" "$5" "$glyph" "$clean"
}

# ── the profile's UNTAGGED/main lane: its daily `## Focus` tasks (project tasks live in the
# project sheets, read per-project in _profile_view — NOT prefix-classified here) ──
emit_tasks() {
  notes focus --all 2>/dev/null | while IFS=$'\t' read -r profile file line key text; do
    [ -n "$profile" ] || continue
    _task_row "$profile" "$file" "$line" "$key" "$profile" "$text"
  done
}

# ── render helpers (final rows: col7 = "[ ] text"; headers are type=head) ──
# Tasks of one section, grouped by STATUS: todo first, then an "in progress" sub-lane
# for [/] tasks (the glyph in col7). Done ([x]) lives in the note's ### Done, not here.
_flat() { # $1=rows $2=exact-section
  local rows="$1" sec="$2" ip
  printf '%s\n' "$rows" | awk -F'\t' -v w="$sec" '$6==w && $7 !~ /\[\/\]/ { print }'
  ip="$(printf '%s\n' "$rows" | awk -F'\t' -v w="$sec" '$6==w && $7 ~ /\[\/\]/ { print }')"
  if [ -n "$ip" ]; then
    printf 'head\t\t\t\t\t\t%s  in progress%s\n' "$C_INP" "$C_OFF"
    printf '%s\n' "$ip"
  fi
}
_header() { printf 'head\t\t\t\t\t\t%s── %s ──%s\n' "$C_HEAD" "$1" "$C_OFF"; }
# A project sub-header: name, its version (dim cyan), then its `notes projects` status
# trailing dim (like the `## Current Projects` status in the vault). Status can be
# long/multi-line — collapse and truncate so it fits one row.
_subheader() { # $1=name $2=status $3=version
  local name="$1" status="${2:-}" version="${3:-}" short ver=""
  [ -n "$version" ] && ver=" ${C_BOX}${version}${C_OFF}"
  if [ -n "$status" ]; then
    short="$(printf '%s' "$status" | tr '\n\t' '  ' | sed -E 's/^_[0-9-]+_ *(—|-) *//; s/  +/ /g' | cut -c1-64)"
    printf 'head\t\t\t\t\t\t%s  %s%s%s   %s%s%s\n' "$C_PROJ" "$name" "$C_OFF" "$ver" "$C_DIM" "$short" "$C_OFF"
  else
    printf 'head\t\t\t\t\t\t%s  %s%s%s\n' "$C_PROJ" "$name" "$C_OFF" "$ver"
  fi
}

# One profile's view: its untagged tasks, then a group per project. Both the profile's own
# (non-project) lane AND each empty project get a selectable "(no tasks — C-a to add)"
# placeholder, so an empty profile (e.g. a fresh job) still has a row to add/move onto.
_profile_view() { # $1=rows $2=profile
  local rows="$1" prof="$2" n st lc body untagged
  untagged="$(_flat "$rows" "$prof")"
  if [ -n "$untagged" ]; then
    printf '%s\n' "$untagged"
  else
    printf 'add\t%s\t\t\t\t%s\t%s  (no tasks — C-a to add)%s\n' \
      "$prof" "$prof" "$C_DIM" "$C_OFF"
  fi
  notes --profile "$prof" projects 2>/dev/null | while IFS=$'\t' read -r n _summary st ver; do
    [ -z "$n" ] && continue
    lc="$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')"
    _subheader "$n" "$st" "$ver"
    # project tasks come from the SHEET's `## Wave` (ptask), keyed for done/start/rm on it
    body="$(notes --profile "$prof" ptask "$n" list 2>/dev/null \
      | while IFS=$'\t' read -r path line key text; do
          [ -n "$key" ] && _task_row "$prof" "$path" "$line" "$key" "$prof/$lc" "$text"
        done)"
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    else
      printf 'add\t%s\t\t\t\t%s/%s\t%s  (no tasks — C-a to add)%s\n' \
        "$prof" "$prof" "$lc" "$C_DIM" "$C_OFF"
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
  _profile_view "$rows" "$want"
}

# ── the left sidebar rail: sections + counts, active marked ─────────
rail() {
  local cur ct s n
  cur="$(read_section)"
  ct="$(emit_tasks | awk -F'\t' '{ c[$2]++; t++ } END { for (k in c) print k, c[k]; print "all", t }')"
  printf '%s SECTIONS%s\n\n' "$C_HEAD" "$C_OFF"
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    n="$(awk -v k="$s" '$1==k{print $2}' <<< "$ct")"; n="${n:-0}"
    if [ "$s" = "$cur" ]; then
      printf '%s> %-20s %s%s\n' "$C_SEL" "$s" "$n" "$C_OFF"
    else
      printf '  %-20s %s%s%s\n' "$s" "$C_DIM" "$n" "$C_OFF"
    fi
  done < <(sections_list)
}

_cycle_section() { # $1 = +1 (next) or -1 (prev)
  local cur i n; cur="$(read_section)"
  local -a s=(); while IFS= read -r i; do [ -n "$i" ] && s+=("$i"); done < <(sections_list)
  n=${#s[@]}
  for i in "${!s[@]}"; do
    if [ "${s[$i]}" = "$cur" ]; then
      echo "${s[$(((i + $1 + n) % n))]}" > "$STATE"; return
    fi
  done
  echo all > "$STATE"
}
next_section() { _cycle_section 1; }
prev_section() { _cycle_section -1; }

# Every place a task can live: each profile, plus each of its projects.
destinations() {
  local p n
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    echo "$p"
    for n in $(projects_of "$p"); do echo "$p/$n"; done
  done < <(profiles)
}

# Add to whatever SECTION you're on. A `<profile>/<project>` row adds to the project's
# SHEET (`## Wave`, the project analog of the daily `## Focus`); a bare `<profile>` adds an
# untagged/main task to the daily note.
add_task() {
  local section="${1:-}" profile proj text
  [ -z "$section" ] && section="$(read_section)"
  [ "$section" = all ] && section=personal
  profile="${section%%/*}"
  read -r -p "add to ${section}: " text || return 0
  [ -n "${text// /}" ] || return 0
  case "$section" in
    */*) proj="${section#*/}"; notes --profile "$profile" ptask "$proj" add "$text" ;;
    *)   notes --profile "$profile" focus add "$text" ;;
  esac
}

# Route a task op (done|start|rm) to the right store based on the row's SECTION: a project
# row edits the project sheet's `## Wave` (`ptask`); an untagged/profile row edits the daily
# `## Focus` (`focus`, then a sweep to re-lane it). Called from the fzf key binds.
task_op() { # $1=verb(done|start|rm)  $2=section  $3=key
  local verb="${1:-}" section="${2:-}" key="${3:-}" profile proj
  [ -n "$key" ] || return 0
  profile="${section%%/*}"
  case "$section" in
    */*) proj="${section#*/}"; notes --profile "$profile" ptask "$proj" "$verb" "$key" ;;
    *)   notes --profile "$profile" focus "$verb" "$key"
         [ "$verb" = rm ] || notes --profile "$profile" focus sweep ;;
  esac
}

# Move a task to another profile and/or project. A numbered read prompt rather than a
# nested fzf: fzf-inside-fzf-execute is fragile in a tmux popup.
move_task() { # $1=row section  $2=row profile  $3=row key
  local section="${1:-}" profile="${2:-}" key="${3:-}" dest pick i
  if [ -z "$key" ] || [ -z "$profile" ]; then
    echo "not on a task row"; sleep 1; return 0
  fi
  local -a dests=()
  while IFS= read -r dest; do
    [ -n "$dest" ] && [ "$dest" != "$section" ] && dests+=("$dest")
  done < <(destinations)
  if [ ${#dests[@]} -eq 0 ]; then
    echo "no destinations available"; sleep 1; return 0
  fi
  printf 'move: %s\n' "$key"
  for i in "${!dests[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${dests[$i]}"; done
  read -r -p "destination [1-${#dests[@]}]: " pick || return 0
  case "$pick" in '' | *[!0-9]*) return 0 ;; esac
  if [ "$pick" -lt 1 ] || [ "$pick" -gt ${#dests[@]} ]; then return 0; fi
  dest="${dests[$((pick - 1))]}"
  case "$dest" in
    */*) notes --profile "$profile" focus mv "$key" --to "${dest%%/*}" --tag "${dest#*/}" ;;
    *) notes --profile "$profile" focus mv "$key" --to "$dest" --untag ;;
  esac || { echo "move failed"; sleep 2; }
}

# ── project lifecycle, scoped to the section's profile ──────────────
new_project() {
  local section="${1:-}" profile name
  [ -z "$section" ] && section="$(read_section)"
  [ "$section" = all ] && section=personal
  profile="${section%%/*}"
  read -r -p "new project in ${profile}: " name || return 0
  [ -n "${name// /}" ] && notes --profile "$profile" projects --new "$name"
}

archive_project() { # $1 = section of the highlighted row (<profile>/<project>)
  local section="${1:-}" profile name ans
  case "$section" in
    */*) profile="${section%%/*}"; name="${section#*/}" ;;
    *) echo "not on a project row"; sleep 1; return 0 ;;
  esac
  read -r -p "archive project '$name' in $profile? [y/N] " ans || return 0
  case "$ans" in y | Y) notes --profile "$profile" projects --archive "$name" ;; esac
}

# Roll a project to its next version: freeze the current version + open the next (the
# sheet-model rollover; falls back to a version-note bump for legacy projects).
roll_project() { # $1 = section of the highlighted row (<profile>/<project>)
  local section="${1:-}" profile name cur lvl
  case "$section" in
    */*) profile="${section%%/*}"; name="${section#*/}" ;;
    *) echo "not on a project row"; sleep 1; return 0 ;;
  esac
  cur="$(notes --profile "$profile" projects --version-of "$name" 2>/dev/null)"
  read -r -p "roll '$name' ${cur:-v?} -> next  [enter=patch / m=minor / M=major / other=cancel]: " lvl || return 0
  case "$lvl" in
    '' | p | P) notes --profile "$profile" projects --roll "$name" ;;
    m) notes --profile "$profile" projects --roll "$name" --minor ;;
    M) notes --profile "$profile" projects --roll "$name" --major ;;
    *) return 0 ;;
  esac || { echo "roll failed"; sleep 2; }
}

# Browse a project's release notes — per-version `.md` from BOTH `versions/` (sheet-model
# rollovers) and `changelog/` (release-managed projects keep their release notes here),
# newest first, previewed. Reached via fzf `become` (the `o` bind), so THIS runs as the sole
# fzf in the cockpit's window — a fresh fzf that owns the terminal, not a nested one
# (fzf-in-fzf-execute / a popup launched from execute are both fragile inside the cockpit's
# display-popup — see move_task; they render the cockpit instead). `q`/esc returns by
# re-`exec`ing the cockpit; enter opens a version in nvim. Rows are `basename<TAB>fullpath`.
browse_versions() { # $1 = section of the highlighted row (<profile>/<project>)
  local section="${1:-}" profile name summary root rows prev d
  case "$section" in
    */*) profile="${section%%/*}"; name="${section#*/}" ;;
    *) exec "$SELF" ;; # not a project row — just go back to the cockpit
  esac
  summary="$(notes --profile "$profile" projects 2>/dev/null \
    | awk -F'\t' -v n="$name" 'tolower($1)==tolower(n){print $2; exit}')"
  [ -n "$summary" ] && root="$(dirname "$summary")"
  # gather version notes from versions/ + changelog/; show basename, keep the path for preview
  rows="$( for d in "$root/versions" "$root/changelog"; do
             [ -d "$d" ] && ls -1 "$d"/*.md 2>/dev/null
           done | awk -F/ 'NF{print $NF"\t"$0}' | sort -rV )"
  if [ -z "$rows" ]; then
    echo "no release notes for $name yet — roll one with V (or backfill changelog/)"; sleep 1.5; exec "$SELF"
  fi
  if command -v bat >/dev/null 2>&1; then
    prev="bat --color=always --style=plain --language=markdown {2}"
  else
    prev="cat {2}"
  fi
  printf '%s\n' "$rows" | fzf \
    --ansi --reverse --delimiter='\t' --with-nth=1 \
    --preview "$prev" --preview-window 'right:62%:wrap' \
    --prompt "versions: $name > " \
    --header 'enter: open in nvim    q / esc: back to cockpit' \
    --bind 'enter:execute(nvim {2})' --bind 'q:abort'
  exec "$SELF" # versions fzf exited (q/esc) — relaunch the cockpit in the same window
}

restore_project() {
  local section="${1:-}" profile pick i
  [ -z "$section" ] && section="$(read_section)"
  [ "$section" = all ] && section=personal
  profile="${section%%/*}"
  local -a names=()
  while IFS= read -r pick; do [ -n "$pick" ] && names+=("$pick"); done \
    < <(notes --profile "$profile" projects --archived 2>/dev/null | cut -f1)
  if [ ${#names[@]} -eq 0 ]; then
    echo "no archived projects in $profile"; sleep 1; return 0
  fi
  echo "restore which project in $profile?"
  for i in "${!names[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${names[$i]}"; done
  read -r -p "project [1-${#names[@]}]: " pick || return 0
  case "$pick" in '' | *[!0-9]*) return 0 ;; esac
  if [ "$pick" -lt 1 ] || [ "$pick" -gt ${#names[@]} ]; then return 0; fi
  notes --profile "$profile" projects --restore "${names[$((pick - 1))]}"
}

# `?` opens this in a pager (press q to return to the cockpit).
help_view() {
  cat <<'EOF'

  notes cockpit — keys        (press q to close)

  navigate
    j / k          move down / up
    h / l          previous / next section
    i              search  (esc leaves search)
    enter          edit the task in nvim

  task
    s              toggle in-progress  ( [ ] <-> [/] )
    C-x            mark done
    C-a            add a task to the section
    C-d            delete the task
    m              move to another section / project

  project
    n              new project in this section
    V              roll the highlighted project to its next version
    o              browse the project's old (frozen) versions
    A              archive the highlighted project
    R              restore an archived project

  other
    T              create today's notes (all profiles)
    ?              this help
    q / esc        quit

EOF
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
  --task-op) shift; task_op "$@"; exit 0 ;;
  --move) shift; move_task "$@"; exit 0 ;;
  --jump) shift; jump_row "$@"; exit 0 ;;
  --new-project) new_project "${2:-}"; exit 0 ;;
  --roll-project) roll_project "${2:-}"; exit 0 ;;
  --browse-versions) browse_versions "${2:-}"; exit 0 ;;
  --archive-project) archive_project "${2:-}"; exit 0 ;;
  --restore-project) restore_project "${2:-}"; exit 0 ;;
  --help-view) help_view; exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }
command -v notes >/dev/null 2>&1 || { echo "notes CLI not found (build ~/.dotfiles/.local/src/notes-cli)"; exit 1; }

# Bootstrap today's note for every profile so a fresh day never shows spurious zeros
# (the daily note is per-profile and `focus --all` only reads notes that exist).
# Idempotent — a no-op once today's notes are present.
notes today --all >/dev/null 2>&1 || true

echo personal > "$STATE" # every launch starts on personal
# modal nav: printable keys that mean "command" in normal mode but must TYPE while
# searching. `i` shows the input and unbinds them; leaving search (esc) rebinds them.
# `?` is intentionally NOT modal — it opens the help pager.
MODAL='j,k,h,l,i,q,s,m,n,V,o,A,R,T'

list_section personal | fzf \
  --ansi --reverse --cycle --no-sort --border --no-input --wrap \
  --delimiter=$'\t' --with-nth='7..' \
  --prompt='search > ' \
  --header='?  keys' \
  --preview "$SELF --rail" \
  --preview-window 'left:24%:wrap:border-right' \
  --bind 'ctrl-/:toggle-preview' \
  --bind "?:execute($SELF --help-view | less -R)" \
  --bind 'j:down+transform:[ {1} = head ] && echo down' \
  --bind 'k:up+transform:[ {1} = head ] && echo up' \
  --bind 'up:up+transform:[ {1} = head ] && echo up' \
  --bind 'down:down+transform:[ {1} = head ] && echo down' \
  --bind 'load:transform:[ {1} = head ] && echo down' \
  --bind "h:execute-silent($SELF --prev-section)+reload($SELF --list)+refresh-preview" \
  --bind "l:execute-silent($SELF --next-section)+reload($SELF --list)+refresh-preview" \
  --bind "tab:execute-silent($SELF --next-section)+reload($SELF --list)+refresh-preview" \
  --bind "i:show-input+unbind($MODAL)" \
  --bind "esc:transform:[ \"\$FZF_INPUT_STATE\" = hidden ] && echo abort || echo \"clear-query+hide-input+rebind($MODAL)\"" \
  --bind 'q:abort' \
  --bind "ctrl-x:execute-silent($SELF --task-op done {6} {5})+reload($SELF --list)+refresh-preview" \
  --bind "s:execute-silent($SELF --task-op start {6} {5})+reload($SELF --list)+refresh-preview" \
  --bind "ctrl-d:execute-silent($SELF --task-op rm {6} {5})+reload($SELF --list)+refresh-preview" \
  --bind "ctrl-a:execute($SELF --add {6})+reload($SELF --list)+refresh-preview" \
  --bind "m:execute($SELF --move {6} {2} {5})+reload($SELF --list)+refresh-preview" \
  --bind "n:execute($SELF --new-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "V:execute($SELF --roll-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "o:become($SELF --browse-versions {6})" \
  --bind "A:execute($SELF --archive-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "R:execute($SELF --restore-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "T:execute-silent(notes today --all)+reload($SELF --list)+refresh-preview" \
  --bind "enter:execute-silent($SELF --jump {1} {3} {4})+abort"
