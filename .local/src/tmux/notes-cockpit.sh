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
# Modes: (no args)=UI · --list [section] · --rail [section] · --next/prev-section · --add
#        --move · --jump · --new-project · --archive-project · --restore-project
#        --preview-version <kind> <file> <version> <profile> <project>
#                             (the rendered pane every note is read through; `wave` slices
#                              the live sheet, anything else renders the whole file)
#        --roll-now <profile> <project> [patch|minor|major]  (headless; no key binding)
#        --browse-versions <profile>/<project>   (the `o` roadmap + release-note browser)
#        --wave-rows / --wave-add / --wave-plan   (that browser's internals)
#
# Both preview panes render markdown through md-render.sh rather than showing its source,
# and neither preview window is `wrap`: the renderer word-wraps to $FZF_PREVIEW_COLUMNS
# itself, which is what removed the mid-word cuts and the continuation glyphs fzf's own
# column wrap produced.

set -uo pipefail
SELF="$(realpath "$0")"

# The one board parser, shared with wave-session and the headless daemons. Lookup order:
# explicit override (tests), deployed path, then the in-repo sibling so a checkout
# works before stow has run.
# shellcheck source=/dev/null
. "${AGENT_BOARD_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.local/lib/agent-board.sh" 2>/dev/null \
  || . "$(dirname "$SELF")/../../lib/agent-board.sh" 2>/dev/null \
  || { echo "notes-cockpit: agent-board.sh not found" >&2; exit 1; }
# The project registry accessor (project_map_file). Same lookup order. SOFT-FAIL with a
# fallback definition rather than exit: this file is public and the registry is private,
# so a public-only checkout must still open. canon_namespaces then finds no `repo`
# relation and returns just the project name, which is the correct degraded answer.
# shellcheck source=/dev/null
. "${PROJECT_NAME_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.config/shared-hooks/project-name.sh" 2>/dev/null \
  || . "$(dirname "$SELF")/../../../.config/shared-hooks/project-name.sh" 2>/dev/null \
  || true
declare -F project_map_file >/dev/null 2>&1 \
  || project_map_file() { printf '%s' "${PROJECT_MAP_FILE:-$HOME/.config/shared-hooks/project-map.json}"; }
# The one lab-feed parser, shared with lab-sync's regen-project-index.sh — so a project row
# here and its row in `lab/projects/index.md` cannot disagree. Same lookup order as the
# board lib, and HARD-fail for the same reason: every view renders project rows through
# _status_gist, so a missing parser is not a degraded cockpit, it is a blank one.
# shellcheck source=/dev/null
. "${LAB_FEED_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.local/lib/lab-feed.sh" 2>/dev/null \
  || . "$(dirname "$SELF")/../../lib/lab-feed.sh" 2>/dev/null \
  || { echo "notes-cockpit: lab-feed.sh not found" >&2; exit 1; }
# The one eval-corpus parser, shared with eval-report.sh. Same lookup order as the board
# lib, but SOFT-FAIL: tasks, agents and bridge do not need it, so a machine with no eval
# corpus should still get three working views rather than a cockpit that refuses to start.
# The usage view checks HAVE_EVALS and says so instead of rendering an empty panel.
HAVE_EVALS=1
# shellcheck source=/dev/null
. "${AGENT_EVALS_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.local/lib/agent-evals.sh" 2>/dev/null \
  || . "$(dirname "$SELF")/../../lib/agent-evals.sh" 2>/dev/null \
  || HAVE_EVALS=0
# The markdown renderer every preview pane goes through. Same lookup order again, SOFT-FAIL
# with a `cat` shim: an unrendered note is ugly but readable, and refusing to open the whole
# cockpit because a cosmetic library is missing would be the wrong trade. The shim is
# deliberately `cat` rather than a second stripper — one renderer or none, never two that
# disagree about what a note looks like.
# shellcheck source=/dev/null
. "${MD_RENDER_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.local/lib/md-render.sh" 2>/dev/null \
  || . "$(dirname "$SELF")/../../lib/md-render.sh" 2>/dev/null \
  || true
declare -F md_render >/dev/null 2>&1 || md_render() {
  if [ "${1:--}" = - ]; then cat; else cat -- "$1"; fi
}
# Per-instance state suffix. The section/mode/filter files are keyed on UID alone, which is
# right for a popup (only one can be open) but wrong the moment two copies run at once —
# the persistent cockpit session keeps a `bridge` window and a `notes` window both running
# this script, and without a suffix they would stomp each other's view on every keypress.
# Empty by default, so the popup's paths are byte-identical to what they always were.
INSTANCE="${NOTES_COCKPIT_INSTANCE:-}"
STATE="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}${INSTANCE:+-$INSTANCE}.section"
# THREE views, cycled by `a`  (tasks -> factory -> usage -> tasks):
#   tasks   your task lists (the default; unchanged).
#   factory WHAT is in flight, grouped by the STAGE it is in: needs-you, triage,
#           building, reviewing, shipped. One line per item; an empty stage renders
#           nothing; `shipped` folds to a per-project version total with its cost
#           COVERAGE beside it. Cross-profile, so a question anywhere is visible from
#           anywhere. Enter answers a question or opens a checkpoint; ctrl-a adds work.
#
#           It replaces the former `agents` and `bridge` views, which between them
#           answered ONE question -- what is in flight and who is on it -- across two
#           screens, and which duplicated each other's asks and sprint rows until a
#           comment had to forbid re-adding them. Stage comes from board_rows_effective,
#           so the stage on screen and the stage in the event log are the same value.
#   usage   HOW WELL and HOW EXPENSIVELY the agents are working, over a window that `w`
#           cycles (today / 7d / 30d). Joins two corpora that nothing joined before: the
#           eval markdown (~/.agent/evals, quality) and the session registry (tokens and
#           USD), on the session uuid they both carry. Cross-profile like the bridge,
#           because "what did this week cost" is not a per-profile question.
#           It shows TRENDS; the agents view shows who is working right now.
# Each is its own render; none overwrites another.
MODEF="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}${INSTANCE:+-$INSTANCE}.mode"
read_mode() { cat "$MODEF" 2>/dev/null || echo tasks; }
toggle_mode() { # cycle tasks -> factory -> usage -> tasks
  case "$(read_mode)" in
    tasks)   printf factory > "$MODEF" ;;
    factory) printf usage   > "$MODEF" ;;
    # `*)`, not `usage)`, so an unreadable or garbage mode file lands somewhere valid
    # rather than wedging the cycle on a name no renderer answers to. This also carries
    # the retired `agents`/`bridge` names home: a mode file left behind by an older
    # version resolves to `tasks` instead of rendering nothing.
    *)       printf tasks   > "$MODEF" ;;
  esac
}
# Optional machine-local prefix->project alias file (keeps private project names OUT of
# this public script). Format: `prefix=project` per line (e.g. a short tag -> its full
# project name), so a `tag:` prefix classifies under that project.
ALIAS_FILE="${NOTES_COCKPIT_ALIASES:-$HOME/.config/notes-cockpit/aliases}"
# Optional machine-local project->repo map (same dir/format as notes-version-summary uses):
# `project=/abs/repo[:pathfilter]` per line. Lets the accept flow `cd` into a project's repo to
# file a Vikunja ticket; absent/unmapped -> the accept flow adds to the sheet only.
REPOS_FILE="${NOTES_COCKPIT_REPOS:-$HOME/.config/notes-cockpit/repos}"

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

profiles() { notes config --profiles 2>/dev/null; }

# active_profile -> the org this machine resolves to (--profile / $NOTES_PROFILE / hostname map
# / default_profile). The one org the cockpit may treat specially, because it is the one the
# human is actually in -- as opposed to a name compiled into the file.
active_profile() { notes config 2>/dev/null | awk '$1=="profile"{print $2; exit}'; }

# The org to fall back to when there is no saved/valid selection. Never a literal: the active
# org, else the first configured one, else empty. A hardcoded `personal` here meant a machine
# whose profile is a job opened the cockpit on an org it may not even use, and it broke silently
# if that org were ever renamed.
active_profile_or_first() {
  local a
  a="$(active_profile)"
  [ -n "$a" ] || a="$(profiles | head -1)"
  printf '%s' "$a"
}

read_section() { cat "$STATE" 2>/dev/null || active_profile_or_first; }

# Priority filter: `p` cycles the view through #urgent -> #high -> #low -> (all).
# Same levels as md::PRIORITIES / the nvim <leader>tp cycle (the shared source of truth).
PFILTER="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}${INSTANCE:+-$INSTANCE}.pfilter"
read_pfilter() { cat "$PFILTER" 2>/dev/null || true; }
cycle_pfilter() {
  # read the current value BEFORE opening the file for write (a `case … > "$PFILTER"`
  # redirect truncates it first, so read_pfilter would always see empty).
  local cur next; cur="$(read_pfilter)"
  case "$cur" in
    "")     next=urgent ;;
    urgent) next=high ;;
    high)   next=low ;;
    *)      next="" ;; # low (or anything) -> back to all
  esac
  printf '%s' "$next" > "$PFILTER"
}

# Usage-view time window: `w` cycles 7d -> 30d -> today -> 7d. Same shape as the priority
# filter above, and for the same reason — it is view state, so it belongs in a file keyed
# per instance, not in a variable that dies with each `$SELF --list` subprocess.
#
# 7d leads because it is the only window that is usefully populated on a normal day:
# `today` is often two or three sessions, and `30d` reaches past Prometheus's one-week
# retention so its dollar column is mostly `-`.
WINF="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}${INSTANCE:+-$INSTANCE}.window"
read_window() { cat "$WINF" 2>/dev/null || echo 7d; }
cycle_window() {
  # Read BEFORE opening for write — a `case … > "$WINF"` redirect truncates first, so
  # read_window would always see empty. Exactly the bug cycle_pfilter documents.
  local cur next; cur="$(read_window)"
  case "$cur" in
    7d)  next=30d ;;
    30d) next=today ;;
    *)   next=7d ;;
  esac
  printf '%s' "$next" > "$WINF"
}

# The active window as `<epoch>\t<YYYY-MM-DD>` — epoch feeds agent-usage --since, the
# date feeds eval_files. One function so the two corpora can never be asked about
# different spans, which would silently pair this week's cost with last month's scores.
_window_since() {
  local w; w="$(read_window)"
  local days=7
  case "$w" in today) days=0 ;; 30d) days=30 ;; *) days=7 ;; esac
  if [ "$days" -eq 0 ]; then
    printf '%s\t%s\n' "$(date -d 'today 00:00' +%s 2>/dev/null || echo 0)" "$(date +%F)"
  else
    printf '%s\t%s\n' "$(date -d "-$days days" +%s 2>/dev/null || echo 0)" \
                      "$(date -d "-$days days" +%F 2>/dev/null || echo 1970-01-01)"
  fi
}

# Filter emitted rows to the active priority. A task row survives only if its display
# carries `#<pf>`; a HEAD row (project sub-header / "in progress") survives only if a
# matching task follows it before the next head; add-placeholders drop; hints stay.
_apply_pfilter() {
  local pf; pf="$(read_pfilter)"
  [ -n "$pf" ] || { cat; return; }
  awk -F'\t' -v tag="#$pf" '
    { n++; type[n]=$1; row[n]=$0; disp[n]=$7 }
    END {
      for (i=1;i<=n;i++) {
        if (type[i]=="task") { if (index(disp[i], tag)) print row[i] }
        else if (type[i]=="head") {
          keep=0
          for (j=i+1;j<=n && type[j]!="head";j++)
            if (type[j]=="task" && index(disp[j], tag)) { keep=1; break }
          if (keep) print row[i]
        }
        else if (type[i]=="hint") print row[i]
      }
    }'
}

# the sidebar: one section per profile, ACTIVE org first, then the rest.
#
# This used to `grep -xF personal` for the head of the list. Two things were wrong with naming
# an org here. It is silent if that org is ever renamed or retired -- the grep matches nothing,
# the list quietly falls back to alphabetical, and nothing reports it. And it is simply the
# wrong org to lead with on a machine whose active profile is a job: the sidebar opened on
# someone else's section.
#
# `_bridge_profiles` in this same file already did active-first-then-the-rest with no hardcoded
# name; this is that pattern, applied to the sidebar it should always have matched.
sections_list() {
  local active
  active="$(active_profile)"
  if [ -n "$active" ]; then
    profiles | grep -xF -- "$active"
    profiles | grep -vxF -- "$active"
  else
    profiles
  fi
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
    # lowercase it: the alias file holds the project's DISPLAY name (`cp=Cockpit`), but
    # projects_lc is lowercased, so an unfolded value would never match and the task
    # would silently fall back to the profile lane.
    [ -n "$mapped" ] && prefix="$(printf '%s' "$mapped" | tr '[:upper:]' '[:lower:]')"
    for p in $projects_lc; do [ "$prefix" = "$p" ] && { echo "$profile/$p"; return; }; done
    echo "$profile"; return
  fi
  for p in $projects_lc; do case "$lc" in *"$p"*) echo "$profile/$p"; return ;; esac; done
  echo "$profile"
}

# The pending gate a sheet line is stamped with, if any: `<id><TAB><options>`, else nothing.
#
# This is the JOIN between the two views. `tasks` is your task sheet and `bridge` is the
# agent queue; they are deliberately separate surfaces, but a wave that stops to ask you
# something is BOTH — an item on your list and a question in the queue. A `/wave` stamps
# `<!-- ask:<id> -->` on the source line when it posts the gate, the same way it stamps
# `<!-- vk:<id> -->` once a ticket exists, and that stamp is the whole link.
#
# Before this, the link ran one way only: the board named the sheet, the ask named the
# board, and the sheet named nothing. So a wave could be scoped, blocked, and waiting on
# you while your own list showed three ordinary unchecked boxes.
#
# `--pending` is re-checked rather than trusted: a wave that dies between answering and
# unstamping would otherwise leave a line that offers to answer a settled question.
# `(approve|hold|cancel)` with the RECOMMENDED option lit and the rest dim.
#
# Colour rather than a marker character: the row is already tight, and every punctuation
# glyph this cockpit uses (~ ? > x *) already means a state in the header vocabulary.
# Reusing one here would read as a status. No recommendation renders exactly as before.
_opts_render() { # $1=options(pipe) $2=recommended
  local options="${1:-}" rec="${2:-}" o out=""
  [ -n "$options" ] || return 0
  if [ -z "$rec" ]; then printf '%s(%s)%s' "$C_DIM" "$options" "$C_OFF"; return; fi
  while IFS= read -r o; do
    [ -z "$o" ] && continue
    if [ "$o" = "$rec" ]; then out="${out:+$out${C_DIM}|${C_OFF}}${C_SEL}${o}${C_OFF}"
    else out="${out:+$out${C_DIM}|${C_OFF}}${C_DIM}${o}${C_OFF}"; fi
  done < <(printf '%s\n' "${options//|/$'\n'}")
  printf '%s(%s%s)%s' "$C_DIM" "$out" "$C_DIM" "$C_OFF"
}

_line_ask() { # $1=rawtext -> "id<TAB>options<TAB>recommended" or empty
  case "$1" in *'<!--'*ask:*) ;; *) return 0 ;; esac
  local id; id="$(printf '%s' "$1" | sed -nE 's/.*<!--[[:space:]]*ask:([A-Za-z0-9_-]+).*/\1/p' | head -1)"
  [ -n "$id" ] || return 0
  command -v agent-ask >/dev/null 2>&1 || return 0
  agent-ask show "$id" 2>/dev/null | awk -F': ' '
    $1=="status"  { st=$2 }
    $1=="options" { o=substr($0, index($0,": ")+2) }
    $1=="recommend" { r=substr($0, index($0,": ")+2) }
    END { if (st=="pending") printf "%s\t%s\t%s", id, o, r }' id="$id"
}

# The same, for a row that only carries file+line (the enter binding). One file read on a
# keypress, versus _line_ask's zero — the render path already has the raw text.
_line_ask_at() { # $1=file $2=line -> "id<TAB>options<TAB>recommended" or empty
  [ -f "$1" ] && [ -n "${2:-}" ] || return 0
  _line_ask "$(sed -n "${2}p" "$1" 2>/dev/null)"
}

# ── one task row: type profile file line key section cleantext ──
# Shared formatter for both daily `## Focus` tasks and project-sheet `## Wave` tasks (both
# arrive as `path<TAB>line<TAB>key<TAB>rawtext`). `section` places the row: `<profile>` for
# an untagged/main task, `<profile>/<project>` for a project task.
_task_row() { # $1=profile $2=file $3=line $4=key $5=section $6=rawtext
  local clean glyph lane="" tid="" gate="" aid="" aopt="" arec=""
  # A stamped ticket id means the wave has already scoped this one — surface it dimly so
  # the burn-down is visible without opening the sheet.
  tid="$(printf '%s' "$6" | grep -oE '<!--[[:space:]]*(vk|cu):[0-9]+' | grep -oE '[0-9]+' | head -1)"
  [ -n "$tid" ] && tid=" ${C_DIM}#${tid}${C_OFF}"
  # A pending gate on this line outranks the checkbox: the item is not "not started", it
  # is stopped ON you. Enter answers it here rather than opening the file (_enter_action).
  IFS=$'\t' read -r aid aopt arec < <(_line_ask "$6")
  clean="$(printf '%s' "$6" | sed -E 's/ *<!--[^>]*-->//; s/^[[:space:]]*- \[[ /xX]\] //')"
  if [ -n "$aid" ]; then
    glyph="${C_INP}[!]${C_OFF}"
    gate=" ${C_INP}needs you${C_OFF}${aopt:+ $(_opts_render "$aopt" "$arec")}"
  elif [[ "$6" =~ ^[[:space:]]*-\ \[/\] ]]; then glyph="${C_INP}[/]${C_OFF}"
  else glyph="${C_BOX}[ ]${C_OFF}"; fi
  printf 'task\t%s\t%s\t%s\t%s\t%s\t%s %s%s%s%s\n' "$1" "$2" "$3" "$4" "$5" "$glyph" "$lane" "$clean" "$tid" "$gate"
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
#
# `badge` is an optional pre-coloured tally (the bridge's per-project counts). It sits
# between the version and the status rather than at the end, because the status is
# truncated to fit one row and anything after it can be the part that falls off.
_subheader() { # $1=name $2=status $3=version [$4=badge]
  local name="$1" status="${2:-}" version="${3:-}" badge="${4:-}" short ver=""
  [ -n "$version" ] && ver=" ${C_BOX}${version}${C_OFF}"
  [ -n "$badge" ] && badge="   ${badge}"
  if [ -n "$status" ]; then
    short="$(printf '%s' "$status" | tr '\n\t' '  ' | sed -E 's/^_[0-9-]+_ *(—|-) *//; s/  +/ /g' | cut -c1-64)"
    printf 'head\t\t\t\t\t\t%s  %s%s%s%s   %s%s%s\n' "$C_PROJ" "$name" "$C_OFF" "$ver" "$badge" "$C_DIM" "$short" "$C_OFF"
  else
    printf 'head\t\t\t\t\t\t%s  %s%s%s%s\n' "$C_PROJ" "$name" "$C_OFF" "$ver" "$badge"
  fi
}

# One profile's view: its untagged tasks, then a group per project. Both the profile's own
# (non-project) lane AND each empty project get a selectable "(no tasks — C-a to add)"
# placeholder, so an empty profile (e.g. a fresh job) still has a row to add/move onto.
_profile_view() { # $1=rows $2=profile
  local rows="$1" prof="$2" n sum st ver lc body untagged
  untagged="$(_flat "$rows" "$prof")"
  if [ -n "$untagged" ]; then
    printf '%s\n' "$untagged"
  else
    printf 'add\t%s\t\t\t\t%s\t%s  (no tasks — C-a to add)%s\n' \
      "$prof" "$prof" "$C_DIM" "$C_OFF"
  fi
  # US-delimited (\037), NOT tab. A `notes projects` row is `name<TAB>path<TAB>status<TAB>ver`
  # and MOST projects have an empty status — but tab is an IFS *whitespace* character, so
  # `IFS=$'\t' read` folds the two adjacent tabs into one delimiter and every field after the
  # gap shifts left. The version landed in `st` and `ver` came back empty, which is why a
  # status-less project appeared to be "showing its version" when it was really rendering the
  # version AS its status, and why adding a real status made the version vanish. \037 is not
  # IFS whitespace, so an empty column stays an empty column. Same idiom as the bridge's ask
  # and sprint reads, for the same reason.
  notes --profile "$prof" projects 2>/dev/null | tr '\t' '\037' \
    | while IFS=$'\037' read -r n sum st ver; do
    [ -z "$n" ] && continue
    lc="$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')"
    _subheader "$n" "$(_status_gist "$sum" "$st")" "$ver"
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

# ══ AGENTS mode ═══════════════════════════════════════════════════════════════
# Same sections/projects, but each project's body is the AGENTS working it.
#
# THE JOIN IS IDENTITY. A lab project's directory name IS its runtime project name --
# ~/.agent/{plans,asks,sessions,evals,...}/<name> -- because project-map.json is the
# sole registry AND the sole minter of names, and every lab directory has an entry in
# it (project-map-doctor enforces exactly that).
#
# This used to be a `<!-- canonical: NAME -->` marker inside each summary.md. The
# marker did not POINT INTO the runtime namespace, it MINTED names nothing else had
# heard of: ~/.agent/plans/notes-cockpit/ existed while `notes-cockpit` appeared zero
# times in the registry, and resolve_project_name could never return that string. A
# second source of truth for names, not a join. It was introduced 2026-06-24 to bridge
# one specific gap and the `apps.<repo>` map closed that gap directly a month later.
#
# The one real thing it carried survives, and now comes from the registry instead of a
# hand-maintained comment: a project's state can ALSO live under the repo it belongs
# to, because a session registers under the repo it ran in. `notes-cockpit` is a
# product the user tracks; the sessions that build it register under `dotfiles`. That
# relation is `trackers.<project>.repo` in the map, which already existed and is
# already validated -- so nobody has to remember to keep a marker in sync with it.

# canon_namespaces <project> -> every ~/.agent namespace this project's state can be
# in, one per line, most specific first. Used only where the cockpit LOOKS for existing
# state; anything that WRITES, or passes a name to another tool, uses the project name.
canon_namespaces() { # $1=project
  local p="${1:-}" repo
  [ -n "$p" ] || return 0
  printf '%s\n' "$p"
  repo="$(jq -r --arg p "$p" '.trackers[$p].repo // empty' "$(project_map_file)" 2>/dev/null || true)"
  [ -n "$repo" ] && [ "$repo" != "$p" ] && printf '%s\n' "$repo"
  return 0
}

# which canonical project a headless runner is on right now (delivery-loop status is
# read-only + cheap). Prints "<canonical>\t<detail>" or nothing.
_runner_line() {
  command -v delivery-loop >/dev/null 2>&1 || return 0
  delivery-loop status 2>/dev/null | awk '
    /^project:/ { p=$2 }
    /^sprint:/  { s=$2; for(i=3;i<=NF;i++) s=s" "$i }
    END { if (p!="" && s!="" && s !~ /none|idle/) printf "%s\t%s\n", p, s }'
}

# _elapsed <epoch> -> compact age ("12m", "3h", "2d"). Same vocabulary as `sessions`.
_elapsed() {
  local t="${1:-0}" now d
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  [ "$t" -eq 0 ] && { printf '-'; return; }
  now=$(date +%s); d=$(( now - t )); [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 3600 ];  then printf '%dm' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%dh' $(( d / 3600 ))
  else                          printf '%dd' $(( d / 86400 ))
  fi
}

# When the CURRENT version started = when the PREVIOUS one was frozen.
#
# `notes projects --roll` stamps `<!-- rolled: <epoch> -->` into the note it freezes,
# and that stamp is the boundary. The mtime fallback is only for notes frozen before
# the stamp existed: `C-s` in the version browser regenerates a summary and rewrites an
# old frozen note, which would silently drag the boundary forward by months.
#
# 0 means "no released version yet" - show everything.
_version_start() { # $1=summary path -> epoch
  local path="${1:-}" dir newest ts
  [ -n "$path" ] || { printf 0; return; }
  dir="$(dirname "$path")"
  newest="$(ls -1 "$dir"/versions/*.md 2>/dev/null | sort -rV | head -1)"
  [ -n "$newest" ] || { printf 0; return; }
  ts="$(sed -n 's/.*<!-- *rolled: *\([0-9]\{1,\}\).*/\1/p' "$newest" 2>/dev/null | head -1)"
  [ -n "$ts" ] || ts="$(stat -c %Y "$newest" 2>/dev/null)"
  printf '%s' "${ts:-0}"
}


# 1234567 -> 1.2M / 340k / 512
_human_tok() {
  awk -v n="${1:-0}" 'BEGIN{
    if (n >= 1000000) printf "%.1fM", n/1000000;
    else if (n >= 1000) printf "%.0fk", n/1000;
    else printf "%d", n }'
}



# The factory's footer: the same global rows, but ONLY when one of them is asking for
# something. `sentinel: all watches OK` and a roster of idle runners are true, useless and
# permanent - three lines of reassurance under every render. A trip is the only part that
# changes what you do next, so a quiet fleet renders nothing at all and the full roster
# stays one keypress away in the cockpit's `fleet` window.
_global_agents_tripped() {
  local fleet="${FLEET_SH:-$(dirname "$SELF")/fleet.sh}"
  [ -x "$fleet" ] || return 0
  local type id target state disp out=""
  while IFS=$'\t' read -r type id target state disp; do
    [ "$type" = watch ] || continue
    case "$state" in
      TRIP|ERROR) out="${out}$(printf 'sentinel\t\t%s\t\t\t\t%s' "$target" "$disp")"$'\n' ;;
    esac
  done < <("$fleet" --watches 2>/dev/null)
  [ -n "$out" ] || return 0
  printf 'head\t\t\t\t\t\t%s  sentinel%s\n' "$C_INP" "$C_OFF"
  printf '%s' "$out"
}

# ══ USAGE view (the 4th view) ═══════════════════════════════════════════════
# How well and how expensively the agents are working, over the window `w` cycles.
#
# KEYED ON THE RUNTIME PROJECT NAME, not on a vault profile, and therefore NOT scoped by
# the active section. Both corpora this view reads — ~/.agent/sessions/<project>/ and
# ~/.agent/evals/<project>/ — are keyed by the runtime project name, and the vault's
# per-profile project lists are a presentation of the same names, not a second
# namespace. Re-resolving them per profile would be a lossy round trip. And the
# question the view answers ("what did this week cost, and did it go well") is a
# portfolio question: splitting it per profile would just hide half the spend.
#
# TOKEN-FIRST, DOLLAR-SECOND, and that is not a style choice. Cost coverage is ~2%:
# Prometheus retains a week, the register hook races its 60s export interval, and 848 of
# the last 865 sessions carry no cost at all. Tokens are on 100% of rows. So tokens lead,
# the dollar column renders `-` rather than `$0.00` where it is unknown, and every total
# states how many sessions it could not see. A cost panel that quietly reports 2% of the
# truth as if it were all of it is worse than one that reports nothing.
_usage_evals=""   # eval TSV for the window, computed once per render
_usage_rollup=""  # agent-usage rollup for the window, likewise

_usage_load() { # $1=since-epoch $2=since-date
  # SHAPE-CHECK the rollup rather than trusting the exit code. `agent-usage` predating the
  # rollup verb prints its help to STDOUT and exits 0, so an unguarded read renders four
  # lines of usage text as four projects with 0 tokens each — which looks like data, not
  # like a missing feature. Keep only lines that are 6 fields with a numeric session
  # count; help text cannot satisfy that.
  _usage_rollup=""
  if command -v agent-usage >/dev/null 2>&1; then
    _usage_rollup="$(agent-usage rollup --since "$1" 2>/dev/null \
      | awk -F'\t' 'NF==6 && $2 ~ /^[0-9]+$/')"
  fi
  _usage_evals=""
  if [ "${HAVE_EVALS:-0}" = 1 ]; then
    # An ARRAY, not a word-split string. $HOME can contain a space (the test sandbox
    # uses `sb space/` precisely to catch this), and `eval_rows $files` then hands awk
    # two halves of one path, neither of which exists — so the quality half of the view
    # silently empties while the spend half still renders.
    local -a files=()
    mapfile -t files < <(eval_files "$2" 2>/dev/null)
    [ "${#files[@]}" -gt 0 ] && _usage_evals="$(eval_rows "${files[@]}" 2>/dev/null)"
  fi
}

# `overall` per session id, for the quality x cost join. Only ~12% of eval sessions carry
# a sid (the judge only started writing the marker recently), so this map is deliberately
# sparse and every consumer must tolerate a miss.
_usage_score_of() { # $1=sid
  [ -n "${1:-}" ] && [ "$1" != "-" ] || return 0
  printf '%s\n' "$_usage_evals" | awk -F'\t' -v s="$1" '$5==s && $7!="-" {print $7; exit}'
}

# The one-line quality summary for a project (or all of them when $1 is empty):
# "avg N.N over M scored - weakest <dim> N.N". Averages exclude `-`, and Lessons is
# excluded from the weakest-dimension search because its column holds only the minority
# of sessions that carried a real score (see agent-evals.sh on the correction count).
_usage_quality() { # $1=project (empty = all)
  [ -n "$_usage_evals" ] || return 0
  printf '%s\n' "$_usage_evals" | awk -F'\t' \
    -v want="${1:-}" -v dims="$(printf '%s|' "${EVAL_DIMS[@]}")" '
    BEGIN { nd = split(dims, D, "|"); if (D[nd] == "") nd-- }
    want != "" && $1 != want { next }
    { if ($7 != "-") { osum += $7; on++ }
      for (i = 1; i <= nd; i++) { v = $(7 + i)
        if (v != "-" && D[i] != "Lessons") { s[i] += v; n[i]++ } }
      if ($NF == 1) clean++; else corr++ }
    END {
      if (!on && !corr && !clean) exit
      wi = 0; wv = 99
      for (i = 1; i <= nd; i++) if (n[i] >= 3 && s[i]/n[i] < wv) { wv = s[i]/n[i]; wi = i }
      out = (on ? sprintf("avg %.1f over %d scored", osum/on, on) : "no scores")
      if (wi) out = out sprintf(" - weakest %s %.1f", D[wi], wv)
      if (corr) out = out sprintf(" - %d correction%s", corr, corr == 1 ? "" : "s")
      print out }'
}

_usage_view() {
  local since date
  IFS=$'\t' read -r since date < <(_window_since)
  _usage_load "$since" "$date"

  local w; w="$(read_window)"
  printf 'head\t\t\t\t\t\t%s── usage · %s ──%s %s(w cycles today/7d/30d)%s\n' \
    "$C_HEAD" "$w" "$C_OFF" "$C_DIM" "$C_OFF"

  # ── the global rollup ──
  if [ -n "$_usage_rollup" ]; then
    printf '%s\n' "$_usage_rollup" | awk -F'\t' '$1=="TOTAL"{print}' \
      | while IFS=$'\t' read -r _t n ed tok cost nocost; do
          printf 'roll\t\t\t\t\t\t%s  %s sessions · %s ed · %s tok · %s%s\n' \
            "$C_DIM" "$n" "$ed" "$(_human_tok "$tok")" \
            "$(_usage_money "$cost" "$n" "$nocost")" "$C_OFF"
        done
  else
    # Names both causes, because they are indistinguishable from here and the second one
    # is the likely one on a machine mid-upgrade: an agent-usage without `rollup` prints
    # help and exits 0, which the shape-check in _usage_load discards.
    printf 'hint\t\t\t\t\t\t%s  no spend data — empty session registry, or an agent-usage without `rollup`%s\n' \
      "$C_DIM" "$C_OFF"
  fi
  local q; q="$(_usage_quality)"
  [ -n "$q" ] && printf 'roll\t\t\t\t\t\t%s  quality: %s%s\n' "$C_DIM" "$q" "$C_OFF"
  [ "${HAVE_EVALS:-0}" = 1 ] || \
    printf 'hint\t\t\t\t\t\t%s  agent-evals.sh not found — quality columns unavailable%s\n' \
      "$C_DIM" "$C_OFF"

  _usage_attention
  _usage_projects "$since"
}

# Everything below the floor in the window, newest first. Enter opens the eval AT the
# session. Omitted entirely when empty — an always-present "0 alerts" header is noise in
# a view whose whole job is to surface the exceptions.
_usage_attention() {
  [ -n "$_usage_evals" ] || return 0
  local rows
  rows="$(printf '%s\n' "$_usage_evals" | awk -F'\t' \
    -v dims="$(printf '%s|' "${EVAL_DIMS[@]}")" -v floor="${EVAL_ATTENTION_FLOOR:-7}" '
    BEGIN { nd = split(dims, D, "|"); if (D[nd] == "") nd-- }
    { for (i = 1; i <= nd; i++) { v = $(7 + i)
        if (v != "-" && v + 0 < floor)
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", $2, $1, $3, $4, D[i], v } }' \
    | sort -r | head -12)"
  [ -n "$rows" ] || return 0

  printf 'head\t\t\t\t\t\t%s── attention · below %s ──%s\n' \
    "$C_HEAD" "${EVAL_ATTENTION_FLOOR:-7}" "$C_OFF"
  local d p ln sn dim v
  while IFS=$'\t' read -r d p ln sn dim v; do
    [ -n "$p" ] || continue
    printf 'eval\t\t%s\t%s\t%s\t\t  %s!%s %s%s S%s%s  %s %s/10%s\n' \
      "$EVAL_ROOT/$p/$d.md" "$ln" "$p" \
      "$C_INP" "$C_OFF" "$C_DIM" "$p $d" "$sn" "$C_OFF" "$dim" "$v" "$C_OFF"
  done <<< "$rows"
}

# One group per project, ordered by spend (the rollup already sorts that way), each with
# a quality+spend summary and its most expensive sessions.
_usage_projects() { # $1=since-epoch
  [ -n "$_usage_rollup" ] || return 0
  local p n ed tok cost nocost
  while IFS=$'\t' read -r p n ed tok cost nocost; do
    [ -n "$p" ] && [ "$p" != TOTAL ] || continue
    _subheader "$p" "" ""
    printf 'hint\t\t\t\t%s\t\t%s    %s sess · %s tok · %s%s\n' \
      "$p" "$C_DIM" "$n" "$(_human_tok "$tok")" \
      "$(_usage_money "$cost" "$n" "$nocost")" "$C_OFF"
    local q; q="$(_usage_quality "$p")"
    [ -n "$q" ] && printf 'hint\t\t\t\t%s\t\t%s    %s%s\n' "$p" "$C_DIM" "$q" "$C_OFF"
    _usage_sessions "$p" "$1"
  done <<< "$_usage_rollup"
}

# The quality x cost join: a project's priciest sessions in the window, each carrying its
# eval score when the two corpora share a session id. Enter resumes the session.
_usage_sessions() { # $1=project $2=since-epoch
  command -v agent-usage >/dev/null 2>&1 || return 0
  local rows; rows="$(agent-usage rows "$1" --since "$2" 2>/dev/null \
                      | sort -t"$(printf '\t')" -k4,4rn | head -5)"
  [ -n "$rows" ] || return 0
  local id upd ed cost nocost tok models dur label score
  while IFS=$'\t' read -r id upd ed cost nocost tok models dur label; do
    [ -n "$id" ] || continue
    score="$(_usage_score_of "$id")"
    printf 'sess\t\t%s\t\t%s\t\t  %s*%s %s%s%s ed · %s tok · %s%s  %s\n' \
      "$id" "$1" \
      "$C_PROJ" "$C_OFF" \
      "$([ -n "$score" ] && printf '%s[%s]%s ' "$C_SEL" "$score" "$C_OFF")" \
      "$C_DIM" "$ed" "$(_human_tok "$tok")" \
      "$([ "$nocost" = 1 ] && printf -- '-' || printf '$%.2f' "$cost")" "$C_OFF" \
      "$(printf '%.44s' "$label")"
  done <<< "$rows"
}

# A money total that never lies by omission: the sum, plus how many of the sessions in it
# had no telemetry at all. `-` when NONE of them did, because `$0.00` reads as "free".
_usage_money() { # $1=cost $2=sessions $3=nocost-count
  local cost="$1" n="${2:-0}" nc="${3:-0}"
  if [ "$nc" = "$n" ]; then printf -- '- (%s untracked)' "$nc"; return; fi
  if [ "${nc:-0}" -gt 0 ] 2>/dev/null; then
    printf '$%.2f (+%s untracked)' "$cost" "$nc"
  else
    printf '$%.2f' "$cost"
  fi
}

# ══ BRIDGE view (the 3rd view) ══════════════════════════════════════════════
# The middle ground: open QUESTIONS agents raised, anchored to the task they concern.
# Per project (joined by canonical): each open ask, its task shown as context. Enter
# answers it (round-trips to resume the agent); ctrl-a adds work to that project.
# ══ BRIDGE work items ═══════════════════════════════════════════════════════
# Parse the newest sprint blackboard's Rows/Queue table into work items. Schema-
# tolerant: map columns by header name, derive a lifecycle stage from the Status
# keyword, pull a PR number. TSV out: ticket \t stage \t title \t pr \t sentinel.
# All three of these delegate to ~/.local/lib/agent-board.sh, the ONE board parser.
# The awk that used to live here was the only correct one of five readers; extracting
# it is what lets wave-session, delivery-loop and captain-watchdog stop guessing.
_sprint_items() { # $1=canon
  board_rows "$(board_newest "$1")"
}

# terminal sentinel of a checkpoint (DONE|FAILED|PARTIAL), or empty
_ckpt_sentinel() { # $1=file
  board_sentinel_of "$1"
}

# resolve a ticket's checkpoint file: sentinel hint -> ticket.md -> first-token.md
_ckpt_file() { # $1=canon $2=ticket $3=sentinel -> path or empty
  board_checkpoint_of "$1" "$2" "$3"
}

# latest progress leg + age from a checkpoint file (the "where we're at")
_ckpt_progress() { # $1=file -> "leg  age"
  [ -f "$1" ] || return 0
  local last now mt d age
  last="$(grep -vE '^[[:space:]]*$|^#' "$1" | tail -1 \
    | sed -E 's/^- *//; s/^[0-9]{4}-[0-9T:.+Z-]+ *\|? *//; s/^(LEG[^:]*:|STATUS:) *//' | cut -c1-56)"
  now="$(date +%s)"; mt="$(stat -c %Y "$1" 2>/dev/null || echo "$now")"
  d=$(( (now - mt) / 60 ))
  if [ "$d" -lt 60 ]; then age="${d}m"; elif [ "$d" -lt 1440 ]; then age="$((d/60))h"; else age="$((d/1440))d"; fi
  printf '%s  %s' "$last" "$age"
}

# stage -> "glyph<TAB>colour" (ASCII glyphs only)
_stage_gc() { # $1=stage
  case "$1" in
    working) printf '~\t%s' "$C_INP" ;;   review)  printf '>\t%s' "$C_SEL" ;;
    merged)  printf '*\t%s' "$C_DIM" ;;    blocked) printf 'x\t%s' "$C_INP" ;;
    error)   printf 'x\t%s' "$C_INP" ;;    queued)  printf '.\t%s' "$C_DIM" ;;
    *)       printf '~\t%s' "$C_BOX" ;;
  esac
}

# The ONE line of an ask that goes on the row. An agent writes a gate question as a full
# briefing - a live wave posted 900 characters of findings, options and reasoning, and
# pasting that verbatim into a picker row turns the whole bridge into an
# unreadable wall. Nothing is lost: `enter` opens the ask, which holds the full text.
#
# The QUESTION is the last sentence, not the first. An agent leads with what it found and
# closes with what it needs ("... Create the 3 tickets and cut the branch?"), so a naive
# head-of-string truncation reliably cuts off the only part you have to answer. Prefer the
# trailing interrogative; fall back to the head when there is no question mark.
# What is actually going on with a project, from its summary's AUTO block — the
# `## <- Release & status feed` that lab-sync mirrors out of git + GitHub + the tracker.
#
# The parser moved to ~/.local/lib/lab-feed.sh so that lab-sync's regen-project-index.sh
# can read the SAME feed the same way: `lab/projects/index.md` and these rows are now two
# renderings of one answer rather than two scrapes that agree by luck. Every edge case the
# body used to carry (the sheet -> sibling summary hop, the repo-less version shape, the
# monorepo tag prefix, the `(+N more)` elision) went with it and is tested there.
_feed_gist() { # $1=summary path -> "shipped v1.10.0, 6 to ship, 18 open, 1 PR"
  lab_feed_gist "${1:-}"
}

# The trailing status on a project header, in EVERY view. The live feed beats the prose,
# and the fallback is what keeps a never-lab-synced project from going blank.
#
# This lived inline in the bridge, so the fix landed on exactly one of the three views: the
# tasks list — the one you are looking at most of the time — still carried the stale STATUS
# block, or nothing at all for the many projects that have no STATUS line. One helper, so
# a project row says the same thing wherever you are standing.
_status_gist() { # $1=sheet/summary path $2=STATUS prose
  local g; g="$(_feed_gist "${1:-}")"
  printf '%s' "${g:-${2:-}}"
}

# project_row <profile> <project> -> that project's `notes projects` row, verbatim
# (name<TAB>summary-path<TAB>status<TAB>version). The name match is case-insensitive because
# a section carries the LOWERCASED name while the vault stores the display one -- which is
# also why the row is returned whole: a caller that renders a header wants the vault's
# capitalisation, not the section's. Two callers had this awk inline; a third is where a
# lookup starts to drift.
project_row() {
  notes --profile "$1" projects 2>/dev/null \
    | awk -F'\t' -v n="$2" 'tolower($1)==tolower(n){print; exit}'
}

summary_of() { project_row "$1" "$2" | cut -f2; }

_ask_gist() { # $1=question -> one short line
  local q="$1" tail
  q="$(printf '%s' "$q" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ +| +$//g')"
  # the last `?`-terminated clause, when it is short enough to be a real question
  tail="$(printf '%s' "$q" | grep -oE '[^.?!]*\?[[:space:]]*$' | sed -E 's/^ +//' || true)"
  if [ -n "$tail" ] && [ "${#tail}" -le 72 ] && [ "${#tail}" -ge 8 ]; then
    printf '%s' "$tail"
    return
  fi
  if [ "${#q}" -le 88 ]; then printf '%s' "$q"; else printf '%.85s...' "$q"; fi
}

# The profile order the factory view renders in: the one you are standing on first, then the
# rest. An `$active` that is not a profile at all (the `all` pseudo-section) falls through
# to "every profile, declared order" rather than to nothing.
_factory_profiles() { # $1=active
  local active="${1:-}"
  [ -n "$active" ] || { profiles; return; }
  profiles | grep -xF -- "$active"
  profiles | grep -vxF -- "$active"
}


# ── the FACTORY view ─────────────────────────────────────────────────────────
# One list of work, grouped by the stage it is IN, newest attention first. It replaces
# the bridge (which grouped the same rows by project) and the agents view (which showed
# the sessions moving them), because those two answered one question between them --
# "what is in flight and who is on it" -- and made you read two screens to get it.
#
# THE NOISE BUDGET IS THE DESIGN, not a preference. On the live corpus 15 of 21 board
# rows are terminal, so a per-project listing spends 71% of the screen on work that is
# already done. Hence: an empty stage group does not render at all, `shipped` folds to
# one line per project, and there is exactly one line per item.
#
# CROSS-PROFILE, like the bridge it replaces, and for the reason recorded there: a
# per-section view showed one section's questions while a wave in another sat blocked and
# invisible, and the sidebar badge (which counts `--all`) openly disagreed with the list.
# The `p` filter NARROWS this view; it does not define its scope.
#
# Stage comes from board_rows_effective -- board_rows composed with the checkpoint
# sentinel -- so the stage recorded in the event log and the stage on screen are the same
# value from the same function, not two derivations that agree by luck.
_stage_age() { # $1=canon $2=ticket -> "3d" since the last recorded transition, or empty
  local last
  last="$(board_events "$1" "$2" 2>/dev/null | tail -1 \
    | grep -o '"epoch":[0-9]*' | grep -o '[0-9]*' || true)"
  [ -n "$last" ] || return 0
  _elapsed "$last"
}

# One stage group: header with its count, then its rows. Renders NOTHING when empty --
# `reviewing 0` is a line that only ever costs you a line.
_factory_group() { # $1=label $2=count $3=rows $4=colour
  [ "${2:-0}" -gt 0 ] 2>/dev/null || return 0
  printf 'head\t\t\t\t\t\t%s  %s%s %s%s%s\n' "${4:-$C_HEAD}" "$1" "$C_OFF" "$C_DIM" "$2" "$C_OFF"
  printf '%s' "$3"
}

_factory_view() { # $1=active profile
  local active="$1" prof name st ver lc canon label
  local g_need="" g_tri="" g_bld="" g_rev="" g_shp=""
  local n_need=0 n_tri=0 n_bld=0 n_rev=0 n_shp=0
  # A project tag is only worth a column when the list actually mixes projects.
  local showproj=1; [ -n "$(read_pfilter 2>/dev/null)" ] && showproj=0
  local _FACT_SEEN="|"
  while IFS= read -r prof; do
  [ -z "$prof" ] && continue
  while IFS=$'\037' read -r name sum st ver; do
    [ -z "$name" ] && continue
    lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    canon="$lc"
    label="$name"; [ "$prof" = "$active" ] || label="$prof/$name"
    local sec="$prof/$lc" ptag=""
    [ "$showproj" = 1 ] && ptag="${C_PROJ}${label}${C_OFF} "

    # Board lookup is by the LAB PROJECT's own name, never widened to its repo namespace.
    #
    # Tried and reverted: resolving through canon_namespaces (as the session lookup does)
    # makes a repo-level board visible, but MISATTRIBUTES it. Several lab products share
    # the platform monorepo, so the first one whose namespace matched claimed the whole
    # bnb-platform board and, with it, 1666 sessions and $394 of that repo's entire
    # history under a v0.1.0 with one item. A board that is invisible is a gap; a board
    # filed under the wrong product is a wrong number on screen, which is worse.
    #
    # Sessions can widen safely because a session names its own project; a board cannot,
    # because nothing in it says which product of a monorepo it belongs to. Surfacing
    # repo-level boards needs a repo-level group, not a guess - left for later.
    local board; board="$(board_newest "$canon")"

    # --- board rows -> their stage bucket ---
    local tk stage title pr sen cf prog glyph col prbadge age row
    local shipn=0
    while IFS=$'\037' read -r tk stage title pr sen; do
      [ -z "$tk" ] && continue
      cf="$(_ckpt_file "$canon" "$tk" "$sen")"; prog="$(_ckpt_progress "$cf")"
      IFS=$'\t' read -r glyph col < <(_stage_gc "$stage")
      prbadge=""; [ -n "$pr" ] && prbadge="  ${C_SEL}PR#${pr}${C_OFF}"
      age="$(_stage_age "$canon" "$tk")"
      # wire: item <profile> <ckptfile> <TICKET> <canon> <sec> <DISPLAY>
      #
      # Field 4 carries the TICKET, not the PR the bridge used to put there. Nothing reads
      # field 4 for an item row (enter uses field 3 only), the PR is already on the row as
      # a badge, and the ticket is what the preview needs to look up this row's recorded
      # history. Identity in the wire, artefacts derived from it.
      # A board row without a real ticket carries a placeholder ("n/a", or the `~N`
      # row-number key a pre-approval stub gets). Rendering `[n/a]` spends a badge saying
      # nothing; the row still selects and still opens.
      local tkbadge=""
      case "$tk" in n/a|N/A|~*) ;; *) [ -n "$tk" ] && tkbadge="  ${C_DIM}[${tk}]${C_OFF}" ;; esac
      row="$(printf 'item\t%s\t%s\t%s\t%s\t%s\t  %s%s%s %s%s%s%s%s%s' \
        "$prof" "$cf" "$tk" "$canon" "$sec" \
        "$col" "$glyph" "$C_OFF" "$ptag" "$title" "$prbadge" \
        "$tkbadge" "${age:+  ${C_DIM}${age}${C_OFF}}" "$C_OFF")"$'\n'
      case "$stage" in
        blocked|error)   g_need="${g_need}${row}"; n_need=$((n_need+1)) ;;
        review)          g_rev="${g_rev}${row}";   n_rev=$((n_rev+1)) ;;
        working)         g_bld="${g_bld}${row}";   n_bld=$((n_bld+1)) ;;
        merged|skipped)  shipn=$((shipn+1)) ;;
        # queued on an UNAPPROVED board is a proposal waiting for the gate; on an
        # approved one it is simply next. Both read as triage, which is where you look
        # when deciding what to start.
        *)               g_tri="${g_tri}${row}";   n_tri=$((n_tri+1)) ;;
      esac
    done < <(board_rows_effective "$board" "$canon")

    # NO sheet tasks here, on purpose. An earlier cut listed every open wave task
    # from every board-less project as triage, and on the live corpus that was 19 rows
    # against 4 of real work - the backlog swamping the thing in flight. A task nobody has
    # scoped into a wave is not in the factory; it is in the TASKS view, which is the
    # backlog view and already lists it. A project with nothing running correctly
    # contributes nothing here.
    #
    # This also sidesteps the join it would have needed: deciding whether a sheet line is
    # already a board row means fuzzy title matching, and a wrong match is worse than an
    # absent row.

    # --- who is actually working it, right now ---
    # A live session IS work in progress, so it belongs in `building` beside the rows it
    # is moving rather than in a separate view you have to switch to. This is the part of
    # the retired agents view that carried its weight; the per-session cost table it also
    # rendered is now the one folded `shipped` line.
    #
    # DEDUPED ACROSS PROJECTS, which is not optional: canon_namespaces resolves a project
    # to its REPO's ~/.agent namespace as well as its own, so every lab project backed by
    # the same repo returns the same sessions. Un-deduped, one session working the
    # dotfiles repo rendered once under `agent-runtime` and again under `notes-cockpit`,
    # and one working the platform repo appeared three times. Field 3 is the session id;
    # first project to claim it keeps it.
    local lrow lid
    while IFS= read -r lrow; do
      [ -n "$lrow" ] || continue
      lid="$(printf '%s' "$lrow" | cut -f3)"
      case "$_FACT_SEEN" in *"|$lid|"*) continue ;; esac
      _FACT_SEEN="${_FACT_SEEN}${lid}|"
      g_bld="${g_bld}${lrow}"$'\n'; n_bld=$((n_bld+1))
    done < <(_factory_live "$prof" "$lc" "$canon" "$sec" "$ptag")

    # --- open questions: always needs-you, always first ---
    local id p2 pr2 status2 kind q opt task aat rat rec ag col2 o
    while IFS=$'\037' read -r id p2 pr2 status2 kind q opt task aat rat rec; do
      [ -z "$id" ] && continue
      if [ "$kind" = gate ] || [ "$kind" = approval ]; then ag="!"; col2="$C_INP"; else ag="?"; col2="$C_BOX"; fi
      o=""; [ -n "$opt" ] && o="  $(_opts_render "$opt" "$rec")"
      # wire: ask <profile> <id> <options> <canon> <sec> <DISPLAY>
      g_need="$(printf 'ask\t%s\t%s\t%s\t%s\t%s\t  %s%s%s %s%s%s' \
        "$prof" "$id" "$opt" "$canon" "$sec" "$col2" "$ag" "$C_OFF" \
        "$ptag" "$(_ask_gist "$q")" "$o")"$'\n'"$g_need"
      n_need=$((n_need+1))
    done < <(agent-ask list "$canon" --pending 2>/dev/null | tr '\t' '\037')

    # --- shipped: ONE line, the version total ---
    if [ "$shipn" -gt 0 ]; then
      g_shp="${g_shp}$(_factory_shipped "$prof" "$lc" "$canon" "$sum" "$ver" "$shipn" "$sec" "$label")"$'\n'
      n_shp=$((n_shp+1))
    fi
  done < <(notes --profile "$prof" projects 2>/dev/null | tr '\t' '\037')
  done < <(_factory_profiles "$active")

  _factory_group "needs you" "$n_need" "$g_need" "$C_INP"
  _factory_group "triage"    "$n_tri"  "$g_tri"  "$C_HEAD"
  _factory_group "building"  "$n_bld"  "$g_bld"  "$C_HEAD"
  _factory_group "reviewing" "$n_rev"  "$g_rev"  "$C_HEAD"
  _factory_group "shipped"   "$n_shp"  "$g_shp"  "$C_DIM"
  if [ $((n_need + n_tri + n_bld + n_rev + n_shp)) -eq 0 ]; then
    printf 'hint\t\t\t\t\t\t%s  nothing in flight - agents post work here as they run.%s\n' "$C_DIM" "$C_OFF"
    printf 'hint\t\t\t\t\t\t%s  enter opens/answers - C-a add work - a cycles views%s\n' "$C_DIM" "$C_OFF"
  fi
  _global_agents_tripped
}

# Live agents on one project: a wave still scoping, and any running Claude session.
#
# The scoping row is driven by wave-start's own pid lock rather than inferred from a
# session, because a scope-out runs for minutes before it writes a board, posts an ask or
# touches a ticket - and without this row, pressing `W` looks like it did nothing. The pid
# is checked so a crashed run does not leave a wave that appears to run forever.
#
# State can live under this project AND under the repo it belongs to, hence
# canon_namespaces; the rest of the view keeps receiving one usable project name.
_factory_live() { # $1=prof $2=lc $3=canon $4=sec $5=ptag
  local prof="$1" lc="$2" canon="$3" sec="$4" ptag="${5:-}"
  local names; names="$(canon_namespaces "$lc")"; [ -n "$names" ] || names="$canon"

  local wname wlock wpid
  while IFS= read -r wname; do
    [ -n "$wname" ] || continue
    wlock="$HOME/.local/state/agentctl/wave/${wname}.pid"
    [ -f "$wlock" ] || continue
    wpid="$(cat "$wlock" 2>/dev/null)"
    case "$wpid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$wpid" 2>/dev/null || continue
    printf 'wave\t%s\t%s\t\t%s\t%s\t  %s~%s %s%sscoping a wave %s%s\n' \
      "$prof" "$wname" "$canon" "$sec" "$C_INP" "$C_OFF" "$ptag" "$C_DIM" \
      "$(_elapsed "$(stat -c %Y "$wlock" 2>/dev/null || echo 0)")" "$C_OFF"
  done <<< "$names"

  # A headless delivery-loop runner on THIS project is an agent working it. It is the one
  # worker with no session row of its own, so without this it is invisible everywhere
  # except the fleet window.
  local rline rcanon rdetail
  rline="$(_runner_line)"
  if printf '%s' "$rline" | grep -q "$(printf '\t')"; then
    rcanon="${rline%%$'\t'*}"; rdetail="${rline#*$'\t'}"
    if printf '%s\n' "$names" | grep -qxF "$rcanon"; then
      printf 'runner\t%s\tdelivery-loop\t\t%s\t%s\t  %s~%s %s%s%s%s\n' \
        "$prof" "$canon" "$sec" "$C_INP" "$C_OFF" "$ptag" "$C_DIM" "$rdetail" "$C_OFF"
    fi
  fi

  command -v sessions >/dev/null 2>&1 || return 0
  local id st proj branch started what kind glyph col label n
  while IFS=$'\t' read -r id st proj branch started what kind; do
    [ -n "$id" ] || continue
    case "$st" in
      busy)    glyph='~'; col="$C_INP" ;;
      waiting) glyph='!'; col="$C_SEL" ;;
      *)       glyph='o'; col="$C_DIM" ;;
    esac
    label="$st"
    # A headless run has nobody watching it and its status sits at the CLI default, so
    # without this it renders as the same dim `o idle` an abandoned session gets.
    [ "$kind" = headless ] && { glyph='~'; col="$C_INP"; label=headless; }
    [ "$branch" = "-" ] && branch=""
    [ "$what" = "-" ] && what="(just started)"
    printf 'sess\t%s\t%s\t\t%s\t%s\t  %s%s%s %s%s  %s%s%s\n' \
      "$prof" "$id" "$canon" "$sec" \
      "$col" "$glyph" "$C_OFF" "$ptag" "$what" \
      "$C_DIM" "${branch:+$branch }$(_elapsed "$started") ${label}" "$C_OFF"
  done < <(while IFS= read -r n; do sessions rows "$n" 2>/dev/null; done <<< "$names")
}

# The shipped line for one project: what this version cost, and how much of that number
# is actually known. NEVER a bare dollar figure -- cost coverage on this machine is ~8%
# (the OTel export is gated on the home LAN), and agent-usage already refuses to print a
# total without its coverage beside it. A wrong number in a summary is worse than none.
_factory_shipped() { # $1=prof $2=lc $3=canon $4=summary $5=ver $6=n $7=sec $8=label
  local prof="$1" canon="$3" summary="${4:-}" ver="${5:-}" n="$6" sec="$7" label="$8"
  local vstart rows tot
  vstart="$(_version_start "$summary")"
  tot=""
  # vstart 0 means "no released version yet", i.e. there is no lower bound - and
  # `--since 0` returns the project's ENTIRE history. On a project backed by a busy
  # monorepo that rendered "v0.1.0 - 1 item - 1666 sess - $394.15", which reads as the
  # cost of one item. With no window there is no total worth printing, so print none.
  if [ "${vstart:-0}" -gt 0 ] 2>/dev/null && command -v agent-usage >/dev/null 2>&1; then
    rows="$(agent-usage rows "$canon" --since "$vstart" 2>/dev/null)"
    [ -n "$rows" ] && tot="$(printf '%s\n' "$rows" | awk -F'\t' '
      {s++; t+=$6; if($5=="1") u++; else {c+=$4; k++}}
      END{ if(s) printf "%d sess - %s tok - %s", s,
             (t>=1000000 ? sprintf("%.1fM", t/1000000) : (t>=1000 ? sprintf("%.0fk", t/1000) : t)),
             (k ? sprintf("$%.2f (cost known for %d of %d)", c, k, s) : "cost not tracked") }')"
  fi
  printf 'ship\t%s\t\t\t%s\t%s\t  %s*%s %s%s%s %s%s%s%s\n' \
    "$prof" "$canon" "$sec" \
    "$C_DIM" "$C_OFF" "$C_PROJ" "$label" "$C_OFF" \
    "$C_DIM" "${ver:+$ver - }$n item$([ "$n" = 1 ] || printf s)" "${tot:+ - $tot}" "$C_OFF"
}

# The oldest pending question, anywhere. `answer_next` is what the `!` key runs, and
# _ask_banner is the line that tells you it exists.
#
# Both are deliberately CROSS-PROFILE, like the factory view and unlike every other
# tasks-view behaviour: a question is a person being blocked, and which section you happen
# to be standing on has nothing to do with whether you should answer it.
_oldest_pending() { # -> "id<TAB>options<TAB>project" or empty
  command -v agent-ask >/dev/null 2>&1 || return 0
  agent-ask list --all --pending 2>/dev/null \
    | sort -t"$(printf '\t')" -k9,9 \
    | awk -F'\t' 'NR==1 { printf "%s\t%s\t%s", $1, $7, $2 }'
}

# One unmissable line at the top of the tasks view whenever something is waiting on you.
#
# The rows already say `[!] needs you`, but you have to be looking at the right project in
# the right section to see one - and a question posted against a project you are not
# standing on was invisible from here entirely. This says the count and the key, always.
_ask_banner() {
  local n
  command -v agent-ask >/dev/null 2>&1 || return 0
  n="$(agent-ask count --all 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 0
  printf 'hint\t\t\t\t\t\t%s  ! %s question%s waiting on you%s %s- press ! to answer%s\n' \
    "$C_INP" "$n" "$([ "$n" -gt 1 ] && printf s)" "$C_OFF" "$C_DIM" "$C_OFF"
}

# Answer the oldest pending question without having to go and find its row.
answer_next() {
  local id opt proj
  IFS=$'\t' read -r id opt proj < <(_oldest_pending)
  if [ -z "$id" ]; then
    printf '  nothing is waiting on you.\n' >&2; sleep 1; return 0
  fi
  answer_ask "$id" "$opt"
}

list_section() {
  local want="${1:-}"; [ -z "$want" ] && want="$(read_section)"
  case "$(read_mode)" in
    factory) _factory_view "$want"; return ;;
    usage)  _usage_view; return ;;
  esac
  local rows; rows="$(emit_tasks)"
  _ask_banner
  # A fresh day has no daily note yet, so `focus --all` is empty and every section
  # reads 0 — which looks like data loss. Say so, and offer the one-key fix.
  {
    if [ -z "$rows" ]; then
      printf 'hint\t\t\t\t\t\t%s(no daily note for today — press T to create it and carry tasks forward)%s\n' \
        "$C_DIM" "$C_OFF"
    fi
    _profile_view "$rows" "$want"
  } | _apply_pfilter
}

# answer an ask inline: fzf-pick from options, else read free text; then write back.
# The option list an ask offers, one per line, RECOMMENDED FIRST and marked.
#
# Split out so the picker's ordering is testable without driving fzf. The recommendation
# leads because that is where the eye lands and where fzf parks the cursor: the common case
# becomes enter-enter, and the human still sees every alternative.
_ask_choices() { # $1=options(pipe) $2=recommended -> one per line
  local options="${1:-}" rec="${2:-}" o
  [ -n "$options" ] || return 0
  if [ -n "$rec" ]; then
    printf '%s  (recommended)\n' "$rec"
    while IFS= read -r o; do [ "$o" = "$rec" ] || printf '%s\n' "$o"; done < <(printf '%s\n' "${options//|/$'\n'}")
  else
    printf '%s\n' "${options//|/$'\n'}"
  fi
}

# Answer an ask: pick an option, then optionally say more about it.
#
# This used to be a bare fzf list of `approve|hold|cancel` — no question text, no indication
# of what the agent that asked would do, and no way to say "approve, but drop the mobile
# one". That last part was not a missing nicety: `wave.md` has always specified that
# per-item choices belong in the human's FREE TEXT alongside the option, and there was no
# surface anywhere that could produce one. The contract existed; the UI did not.
#
# So: the question on the header, the full ask one keypress away in the preview, the
# recommended option marked and first, and a notes line that is genuinely optional.
answer_ask() { # $1=id $2=options(pipe)
  local id="$1" options="${2:-}" ans notes rec="" question=""
  [ -n "$id" ] || return 0
  if [ -n "$options" ]; then
    if command -v agent-ask >/dev/null 2>&1; then
      rec="$(agent-ask show "$id" 2>/dev/null | sed -n 's/^recommend: //p' | head -1)"
      question="$(agent-ask show "$id" 2>/dev/null | sed -n 's/^question: //p' | head -1)"
    fi
    # The header carries the question AND the fact that a note comes next. Announcing the
    # note only after the option was chosen made it undiscoverable: you cannot decide
    # "approve, but only T1 and T2" if you believe the three words are the whole answer.
    local hdr=""
    [ -n "$question" ] && hdr="$(printf '%s' "$question" | fold -s -w "${COLUMNS:-100}" | head -8)"$'\n'
    hdr="${hdr}enter picks - then say WHY, or what to change (optional)"
    ans="$(_ask_choices "$options" "$rec" | fzf \
      --prompt="answer $id > " --height=80% --reverse --no-sort --wrap \
      --header="$hdr" \
      --preview="agent-ask show $id" --preview-window='right,55%,wrap,border-left')"
    # strip the marker back off — the ask's vocabulary is fixed, and `approve  (recommended)`
    # is not a word any consumer knows
    ans="${ans%%  (recommended)}"
    [ -n "$ans" ] || return 0
    # The free text is the point, not a footnote. An option on its own says WHAT you decided
    # and never why, and `wave.md` acts on the reasoning - "approve, drop the mobile one",
    # "hold, wait for the 1.11.0 release". Enter alone still skips, so approving stays two
    # keys for anyone who has nothing to add.
    printf '\n  %s%s%s - why, or what to change? %s(enter to skip)%s\n  > ' \
      "$C_SEL" "$ans" "$C_OFF" "$C_DIM" "$C_OFF" >&2
    IFS= read -r notes
    if [ -n "$notes" ]; then
      ans="$ans - $notes"
      printf '  %ssending:%s %s\n' "$C_DIM" "$C_OFF" "$ans" >&2
    fi
  else
    printf 'answer for %s: ' "$id" >&2; read -r ans
  fi
  [ -n "$ans" ] || return 0
  agent-ask answer "$id" "$ans" >/dev/null 2>&1
  # Answering IS starting. `agent-ask answer` only records the decision and notifies —
  # for a whole release cycle nothing consumed those answers, so approving a wave gate in
  # this picker changed a field on disk and did literally nothing else. ask-resume runs
  # the ask's `resume` command; it exits silently for an ask that has none, which is most
  # of them, so this is safe on every answer.
  command -v ask-resume >/dev/null 2>&1 && ask-resume "$id" >/dev/null 2>&1 &
}

# enter dispatch: print the fzf action for the highlighted row (task or any agent row).
_enter_action() { # $1=type $2=profile $3=c3 $4=c4
  case "$1" in
    ask)      printf 'execute(%s --answer %q %q)+reload(%s --list)+refresh-preview' "$SELF" "$3" "$4" "$SELF" ;;
    # An already-answered ask is read-only here: opening it shows the full question, your
    # answer, and whether the resume ever ran. Re-answering is deliberately not offered —
    # the producer has consumed it, and a second answer would be a no-op that looks real.
    aans)     printf 'execute-silent(%s --show-ask %q)+abort' "$SELF" "$3" ;;
    item)     printf 'execute-silent(%s --open-file %q)+abort' "$SELF" "$3" ;;
    sess)     printf 'execute-silent(%s --resume-session %q)+abort' "$SELF" "$3" ;;
    sprint|sentinel) printf 'execute-silent(%s --open-file %q)+abort' "$SELF" "$3" ;;
    # --jump, not --open-file: an eval file reaches 36KB and the finding is one line in
    # it, so losing the line number means landing at the top and hunting.
    eval)     printf 'execute-silent(%s --jump eval %q %q)+abort' "$SELF" "$3" "$4" ;;
    runner)   printf 'execute-silent(%s --journal %q)+abort' "$SELF" "$3" ;;
    # A scoping wave has no board or ask to open yet - its log is the only thing
    # to look at, and "what is it doing right now" is the whole reason for the row.
    wave)     printf 'execute-silent(%s --wave-log %q)+abort' "$SELF" "$3" ;;
    # A sheet line stamped with a PENDING gate answers it in place. The tasks view stays a
    # task sheet — this is the one affordance it borrows from the bridge, and only on the
    # lines a wave has actually stopped on. Everything else still opens the file.
    task)
      local _aid _aopt
      IFS=$'\t' read -r _aid _aopt _arec < <(_line_ask_at "$3" "$4")
      if [ -n "$_aid" ]; then
        printf 'execute(%s --answer %q %q)+reload(%s --list)+refresh-preview' "$SELF" "$_aid" "$_aopt" "$SELF"
      else
        printf 'execute-silent(%s --jump task %q %q)+abort' "$SELF" "$3" "$4"
      fi ;;
    *) printf '' ;;
  esac
}

# ── per-section attention badge: pending agent-ask count bucketed by profile ──
# An ask carries a `profile` when the producer set one; otherwise bucket it by mapping
# its `project` to the profile that owns that project. All in awk (FS='\t') so empty
# fields don't collapse. Emits `<profile> <count>` lines. Total across all -> `all`.
attention_counts() {
  command -v agent-ask >/dev/null 2>&1 || return 0
  local p proj canon map=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    for proj in $(projects_of "$p"); do
      canon="$proj"
      map+="$proj=$p"$'\n'          # vault name -> profile
      [ "$canon" != "$proj" ] && map+="$canon=$p"$'\n'  # canonical name -> profile
    done
  done < <(profiles)
  agent-ask list --all --pending 2>/dev/null | awk -F'\t' -v map="$map" '
    BEGIN { n=split(map, L, "\n"); for(i=1;i<=n;i++) if(split(L[i],kv,"=")==2) prof_of[kv[1]]=kv[2] }
    $1=="" { next }
    # t++ is OUTSIDE the p!="" guard on purpose. It used to be inside, so an ask whose
    # profile column is empty AND whose project is in no profile map counted toward NO
    # section and was missing from the `all` total too - the one number whose whole job
    # is "how many things want you". A question nobody can bucket is still a question.
    # Live example of the shape: every ask under ~/.agent/asks/bnb-platform/ carries an
    # empty profile column, and bnb-platform is a repo, not a vault project, so it is in
    # no map. Bucketing stays guarded; counting does not.
    { t++; p = ($3!="") ? $3 : prof_of[$2]; if (p!="") c[p]++ }
    END { for (k in c) print k, c[k]; if (t) print "all", t }'
}

# ── the left sidebar rail: sections + counts, active marked ─────────
# Cap stdin at N lines and SAY SO. A silent truncation in a pane reads as "that is all there
# is", which is how a stale surface goes unnoticed; the `...` is the difference between a
# summary and a lie. Also avoids `head` closing the pipe under pipefail.
_rail_cap() { # $1 = max lines
  awk -v n="$1" -v dim="$C_DIM" -v off="$C_OFF" \
    'NR<=n {print; next} {more=1} END {if (more) printf "%s  ...%s\n", dim, off}'
}

# The project brief under the sections list, in the TASKS view only.
#
# WHY: the rail rendered the same bytes no matter which row the cursor was on, so the widest
# pane in the default view answered nothing about the project you were standing in. The three
# facts worth having there are what shipped, where we are, and what is next — and all three
# already exist: `_feed_gist` counts the AUTO feed, and the nextup:auto block IS "## Now /
# ## Next". Nothing new is computed here; it is rendered where you are already looking.
#
# CAPPED, because this is a sidebar and not the document: `o` opens the full overview, and a
# forty-line Now paragraph would push the sections list off the top of the pane.
_rail_brief() { # $1 = <profile>/<project>
  local section="${1:-}" profile name row title summary gist block now next w
  case "$section" in */*) profile="${section%%/*}"; name="${section#*/}" ;; *) return 0 ;; esac
  row="$(project_row "$profile" "$name")"
  title="$(cut -f1 <<<"$row")"        # the vault's capitalisation, not the section's
  summary="$(cut -f2 <<<"$row")"
  [ -n "$summary" ] && [ -f "$summary" ] || return 0
  block="$(nextup_block "$summary")"
  gist="$(_feed_gist "$summary")"
  [ -n "$block" ] || [ -n "$gist" ] || return 0

  printf '\n%s── %s ──%s\n' "$C_HEAD" "${title:-$name}" "$C_OFF"
  [ -n "$gist" ] && printf '%s  %s%s\n' "$C_SEL" "$gist" "$C_OFF"
  [ -n "$block" ] || return 0

  # Now and Next are capped SEPARATELY. Capping the block as one unit spends the whole budget
  # on the Now paragraph and truncates Next away entirely -- which drops the half of this pane
  # that is actionable. The two headings are the shape notes-version-summary's `generate_overview`
  # is prompted to produce, so splitting on them is reading a contract, not guessing; a block
  # that carries neither falls through to the whole thing, capped.
  now="$(awk 'f && /^## /{exit} /^##[ \t]+[Nn]ow/{f=1} f' <<<"$block")"
  next="$(awk '/^##[ \t]+[Nn]ext/{f=1} f' <<<"$block")"
  # md_render reads FZF_PREVIEW_COLUMNS itself; the rail is narrow, so keep a hard floor
  # rather than inheriting an 80-column default when the variable is absent (a headless
  # `--rail` call, which is exactly what the tests make).
  #
  # The pane stays at 24%, deliberately: a percentage already adapts, and on a real terminal
  # that is ~45 columns -- enough for this. Widening it to 30% to buy a few columns in the
  # 100-column test terminal instead truncated the body's key header, which is a worse trade
  # than a slightly narrower brief. `wrap` also stays on the window: the brief never reaches
  # the pane width (md_render already wrapped it), but the rail's own view-indicator line is
  # 35 columns and has always relied on it.
  w="${FZF_PREVIEW_COLUMNS:-40}"
  printf '\n'
  if [ -n "$now" ] || [ -n "$next" ]; then
    [ -n "$now" ] && MD_WIDTH="$w" md_render - <<<"$now" | _rail_cap "${RAIL_NOW_LINES:-10}"
    if [ -n "$next" ]; then
      # md_render suppresses a LEADING blank (each call starts a fresh document), so the gap
      # between the two sections has to come from here.
      [ -n "$now" ] && printf '\n'
      MD_WIDTH="$w" md_render - <<<"$next" | _rail_cap "${RAIL_NEXT_LINES:-16}"
    fi
  else
    MD_WIDTH="$w" md_render - <<<"$block" | _rail_cap "${RAIL_NOW_LINES:-10}"
  fi
  printf '%s  o for the full overview%s\n' "$C_DIM" "$C_OFF"
}

rail() { # $1 = section of the highlighted row (optional; drives the brief)
  local cur ct at s n a badge
  cur="$(read_section)"
  ct="$(emit_tasks | awk -F'\t' '{ c[$2]++; t++ } END { for (k in c) print k, c[k]; print "all", t }')"
  at="$(attention_counts)"
  # view indicator: highlight the active of the four (a cycles them).
  # Back to ONE line. The two-line split existed because four names plus the `(a)` hint
  # ran to 35 columns in a preview pane sized at a fraction of the terminal; three names
  # is 27, which fitted even then.
  local mode t_c f_c u_c; mode="$(read_mode)"
  t_c="$C_DIM"; f_c="$C_DIM"; u_c="$C_DIM"
  case "$mode" in
    tasks)   t_c="$C_SEL" ;; factory) f_c="$C_SEL" ;;
    usage)   u_c="$C_SEL" ;;
  esac
  printf '%s SECTIONS%s %s(a)%s\n %stasks%s %s·%s %sfactory%s %s·%s %susage%s\n\n' \
    "$C_HEAD" "$C_OFF" "$C_DIM" "$C_OFF" \
    "$t_c" "$C_OFF" "$C_DIM" "$C_OFF" "$f_c" "$C_OFF" \
    "$C_DIM" "$C_OFF" "$u_c" "$C_OFF"
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    n="$(awk -v k="$s" '$1==k{print $2}' <<< "$ct")"; n="${n:-0}"
    a="$(awk -v k="$s" '$1==k{print $2}' <<< "$at")"; a="${a:-0}"
    badge=""; [ "$a" -gt 0 ] 2>/dev/null && badge="${C_INP}!${a}${C_OFF} "
    if [ "$s" = "$cur" ]; then
      printf '%s> %-20s %s%s%s\n' "$C_SEL" "$s" "$badge" "$n" "$C_OFF"
    else
      printf '  %-20s %s%s%s%s\n' "$s" "$badge" "$C_DIM" "$n" "$C_OFF"
    fi
  done < <(sections_list)
  local pf; pf="$(read_pfilter)"
  [ -n "$pf" ] && printf '\n  %sfilter #%s%s %s(p)%s\n' "$C_INP" "$pf" "$C_OFF" "$C_DIM" "$C_OFF"
  # Shown only in the usage view, where it is the one piece of state that changes what
  # the body means. In the other three `w` does nothing, and a window readout beside
  # task counts would just invite the question of what it filters.
  [ "$(read_mode)" = usage ] && \
    printf '\n  %swindow %s%s %s(w)%s\n' "$C_INP" "$(read_window)" "$C_OFF" "$C_DIM" "$C_OFF"
  # Tasks only. The other three views already answer a question per row in the body — agents
  # says who is working, the bridge what they asked, usage what it cost — and repeating a
  # project brief beside each would be the duplication the agents view was pruned of.
  [ "$(read_mode)" = tasks ] && _rail_brief "${1:-}"
  [ "$(read_mode)" = factory ] && _rail_timeline "${2:-}" "${3:-}"
  return 0
}

# This row's recorded history: every stage it passed through, how long it sat there, and
# what that stage cost. Newest first, because "where is it now and how long has it been
# stuck" is the question; the origin story is below it.
#
# Durations are EXACT and come from nothing but the event log - board_observe stamps each
# transition when the board is edited. Cost is the honest part: it is attributed by TIME
# OVERLAP against the session registry (a session spans [updated - duration_s, updated]),
# because there is no per-ticket cost anywhere and the branch cannot supply one - 8 of 9
# rows on a real board share the wave branch.
#
# What it will NOT do:
#   * give a seed event a duration. A seed records where a row already WAS when first
#     observed, not a transition into it, so the time before it is unmeasured, not zero.
#   * divide a session between the stages it overlaps. It is marked `shared` instead;
#     prorating would invent precision that does not exist.
#   * print $0.00. Cost coverage is ~8% (the OTel export is gated on the home LAN), so an
#     unknown cost is `-`, exactly as agent-usage renders it.
_rail_timeline() { # $1=canon $2=ticket
  local canon="${1:-}" tk="${2:-}"
  [ -n "$canon" ] && [ -n "$tk" ] || return 0
  local ev; ev="$(board_events "$canon" "$tk" 2>/dev/null)"
  [ -n "$ev" ] || { printf '\n  %sno recorded history yet%s\n' "$C_DIM" "$C_OFF"; return 0; }

  printf '\n%s  %s%s\n' "$C_HEAD" "$tk" "$C_OFF"
  # Reverse the log, carrying each event's successor epoch so the dwell time is the gap to
  # the NEXT stage (or to now, for the stage it is in).
  printf '%s\n' "$ev" | awk -v now="$(date +%s)" \
      -v dim="$C_DIM" -v off="$C_OFF" -v sel="$C_SEL" '
    function fld(s, k,   r) { if (match(s, "\"" k "\":\"[^\"]*\"")) { r=substr(s, RSTART, RLENGTH); sub("\"" k "\":\"", "", r); sub("\"$", "", r) } else r=""; return r }
    function num(s, k,   r) { if (match(s, "\"" k "\":[0-9]+")) { r=substr(s, RSTART+length(k)+3, RLENGTH-length(k)-3) } else r=0; return r+0 }
    function dur(a, b,   d) { d=b-a; if (d<0) return "-";
      if (d<3600) return sprintf("%dm %02ds", int(d/60), d%60);
      if (d<86400) return sprintf("%dh %02dm", int(d/3600), int((d%3600)/60));
      return sprintf("%dd %02dh", int(d/86400), int((d%86400)/3600)) }
    { e[NR]=$0; ep[NR]=num($0,"epoch") }
    END {
      for (i=NR; i>=1; i--) {
        to=fld(e[i],"to"); src=fld(e[i],"src"); ts=fld(e[i],"ts")
        nxt=(i<NR) ? ep[i+1] : now
        d=(src=="seed") ? "" : dur(ep[i], nxt)
        printf "  %s%-9s%s %s%s%s\n", (i==NR?sel:dim), to, off, dim, substr(ts,1,16), off
        if (d != "") printf "  %s          %s%s%s\n", dim, d, (i==NR?" (still)":""), off
        else printf "  %s          first seen here%s\n", dim, off
      }
    }'
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
  # the `all` lane spans orgs, so it is not a write target: fall back to the ACTIVE org
  [ "$section" = all ] && section="$(active_profile_or_first)"
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
# Start a wave for the project the highlighted row belongs to, WITHOUT leaving the
# cockpit. Capture already lived here (C-a); starting was the one step that made you open
# a Claude session. `wave-start` backgrounds a headless pass that scopes the current wave
# into tickets, cuts the branch and writes the board as `Approval: PENDING` — then
# posts the approval as an ask you answer in the bridge (a a). It never delivers anything
# on its own; delivery-loop refuses to drain an unapproved board.
start_wave() { # $1=section (<profile>/<project>)
  local section="${1:-}" proj
  case "$section" in
    */*) proj="${section#*/}" ;;
    *)   echo "wave: highlight a PROJECT row (this is the '$section' lane)"; sleep 2; return 0 ;;
  esac
  command -v wave-start >/dev/null 2>&1 || { echo "wave: wave-start not on PATH"; sleep 2; return 0; }
  # Every open row on the wave is the wave's work. Counting a tag here is what made this
  # refuse on a full board: the lane is the agent SHEET now, not a marker on this one.
  local n
  n="$(notes --profile "${section%%/*}" ptask "$proj" list 2>/dev/null | grep -c . || true)"
  if [ "${n:-0}" -eq 0 ]; then
    echo "wave: ${proj}'s current wave has no open tasks — add one with C-a."
    sleep 3; return 0
  fi
  echo "starting a wave for ${proj} (${n} open task(s))…"
  wave-start "$proj"
  sleep 3
}

# ── delete, undo ─────────────────────────────────────────────────────────────
# Deleting used to be C-d, one keystroke from ctrl-u/ctrl-d scrolling and with no
# confirmation, which is exactly how a task got destroyed by accident. Delete is
# now `d` + a yes/no, and the last one is recoverable.

UNDOF="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}${INSTANCE:+-$INSTANCE}.undo"

# Stash what is about to be deleted so `u` can put it back.
_capture_undo() { # $1=section $2=key
  local section="${1:-}" key="${2:-}" profile proj text
  profile="${section%%/*}"
  case "$section" in
    */*) proj="${section#*/}"
         text="$(notes --profile "$profile" ptask "$proj" list 2>/dev/null \
                 | awk -F'\t' -v k="$key" '$3==k{print $4; exit}')" ;;
    *)   text="$(notes --profile "$profile" focus list 2>/dev/null \
                 | grep -F -- "$key" | head -1)" ;;
  esac
  [ -n "$text" ] || return 0
  printf '%s\t%s\n' "$section" "$text" > "$UNDOF"
}

# Strip what the vault RENDERS onto a line (checkbox, age, since-marker) so the text
# can go back through `add` rather than being spliced into the file by hand.
_undo_text() { # $1=raw line -> the bare task text
  printf '%s' "${1:-}" \
    | sed -E 's/^[[:space:]]*- \[[^]]*\][[:space:]]*//; s/ *\([0-9]+d\) */ /g; s/<!--[^>]*-->//g; s/  +/ /g; s/^ +//; s/ +$//'
}

confirm_delete() { # $1=section $2=key
  local section="${1:-}" key="${2:-}" ans
  [ -n "$key" ] || { echo "not on a task row"; sleep 1; return 0; }
  printf 'delete: %s\n' "$key"
  read -r -p "are you sure? [y/N] " ans || return 0
  case "$ans" in
    y | Y)
      _capture_undo "$section" "$key"
      task_op rm "$section" "$key"
      echo "deleted — press u to undo"; sleep 1 ;;
    *) echo "cancelled"; sleep 1 ;;
  esac
}

# Put the last deleted task back. It returns via `add`, so it lands at the end of its
# list rather than its old position - the text is what matters, and re-inserting at a
# line number would mean hand-editing the vault instead of going through the CLI.
undo_delete() {
  local line section text profile proj
  [ -f "$UNDOF" ] || { echo "nothing to undo"; sleep 1; return 0; }
  line="$(cat "$UNDOF" 2>/dev/null)"
  section="${line%%$'\t'*}"; text="$(_undo_text "${line#*$'\t'}")"
  if [ -z "$text" ] || [ -z "$section" ]; then
    echo "nothing to undo"; sleep 1; return 0
  fi
  profile="${section%%/*}"
  case "$section" in
    */*) proj="${section#*/}"; notes --profile "$profile" ptask "$proj" add "$text" >/dev/null 2>&1 ;;
    *)   notes --profile "$profile" focus add "$text" >/dev/null 2>&1 ;;
  esac
  if [ $? -eq 0 ]; then
    rm -f "$UNDOF"
    echo "restored: $text"
  else
    echo "could not restore: $text"
  fi
  sleep 1.5
}

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
  # the `all` lane spans orgs, so it is not a write target: fall back to the ACTIVE org
  [ "$section" = all ] && section="$(active_profile_or_first)"
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
# sheet-model rollover; falls back to a version-note bump for legacy projects). After the
# freeze, generate an LLM summary block on the just-frozen note (best-effort — a gateway
# outage or missing config never fails the roll).
roll_project() { # $1 = section of the highlighted row (<profile>/<project>)
  local section="${1:-}" profile name cur lvl flag
  case "$section" in
    */*) profile="${section%%/*}"; name="${section#*/}" ;;
    *) echo "not on a project row"; sleep 1; return 0 ;;
  esac
  cur="$(notes --profile "$profile" projects --version-of "$name" 2>/dev/null)"
  read -r -p "roll '$name' ${cur:-v?} -> next  [enter=patch / m=minor / M=major / other=cancel]: " lvl || return 0
  case "$lvl" in
    '' | p | P) flag='' ;;
    m) flag='--minor' ;;
    M) flag='--major' ;;
    *) return 0 ;;
  esac
  # The pause is the interactive half: this runs in a popup that closes on return, so a
  # failure the human never gets to read is a failure they never learn about.
  roll_do "$profile" "$name" "$flag" || sleep 2
}

# The roll itself plus everything that has to happen after it: the agent changelog, then
# the LLM summaries. NO PROMPT — the bump level arrives as an argument.
#
# Extracted out of roll_project so a headless caller writes the same artifacts a human
# pressing `V` does. A wave IS a patch version, so a merged wave rolls itself; but the only
# way into this code used to be through roll_project's `read -p`, which a headless run
# cannot answer. The wave would have frozen a version note with no agent changelog and no
# summary inside it — a release record that recorded nothing.
roll_do() { # $1=profile $2=project $3=flag ('' | --minor | --major)
  local profile="$1" name="$2" flag="${3:-}" out frozen
  # shellcheck disable=SC2086  # $flag is one optional word, deliberately unquoted
  out="$(notes --profile "$profile" projects --roll "$name" $flag 2>&1)" \
    || { echo "$out"; echo "roll failed"; return 1; }
  echo "$out"
  # the note that was just frozen (path is in the `(froze <path>)` line)
  frozen="$(sed -n 's/.*(froze \(.*\))$/\1/p' <<<"$out")"

  # The AGENT CHANGELOG: what the agents did for the version we just froze, appended to
  # the frozen note so it ships with the release rather than living only in the cockpit.
  #
  # The window runs from the PREVIOUS version's `rolled:` stamp up to now. `_version_start`
  # reads the newest versions/*.md, which at this point is the note just written - so the
  # window has to be taken from the note BEFORE it.
  if [ -n "$frozen" ] && command -v agent-usage >/dev/null 2>&1; then
    local canon prev since block
    canon="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    prev="$(ls -1 "$(dirname "$frozen")"/*.md 2>/dev/null | sort -rV | sed -n 2p)"
    since=0
    if [ -n "$prev" ]; then
      since="$(sed -n 's/.*<!-- *rolled: *\([0-9]\{1,\}\).*/\1/p' "$prev" | head -1)"
      [ -n "$since" ] || since="$(stat -c %Y "$prev" 2>/dev/null || echo 0)"
    fi
    block="$(while IFS= read -r cn; do
               [ -n "$cn" ] && agent-usage changelog "$cn" --since "${since:-0}" 2>/dev/null
             done < <(canon_namespaces "$canon"))"
    if [ -n "$block" ]; then
      printf '\n%s\n' "$block" >> "$frozen"
      echo "wrote the agent changelog into $(basename "$frozen")"
    else
      echo "(no agent sessions recorded for this version — skipping the agent changelog)"
    fi
  fi

  if [ -n "$frozen" ] && command -v notes-version-summary >/dev/null 2>&1; then
    echo "summarizing $(basename "$frozen") ..."
    notes-version-summary "$profile" "$name" "$frozen" \
      || echo "(summary skipped — see ~/.config/notes-cockpit/llm.env)"
    # a new release changes "what's next" — refresh the project overview too (best-effort)
    echo "refreshing overview ..."
    notes-version-summary --overview "$profile" "$name" || true
  fi
}

# `--roll-now <profile> <project> [patch|minor|major]` — the headless entry a merged wave
# calls. Defaults to PATCH, because that is what a wave is; a minor (a release) or a major
# stays a human act through `V`, and passing anything else is rejected rather than guessed.
roll_now() { # $1=profile $2=project [$3=level]
  local profile="${1:-}" name="${2:-}" level="${3:-patch}" flag
  [ -n "$profile" ] && [ -n "$name" ] || { echo "usage: --roll-now <profile> <project> [patch|minor|major]" >&2; return 2; }
  case "$level" in
    patch) flag='' ;;
    minor) flag='--minor' ;;
    major) flag='--major' ;;
    *) echo "roll-now: unknown level '$level' (patch|minor|major)" >&2; return 2 ;;
  esac
  roll_do "$profile" "$name" "$flag"
}

# The wave rows of the version browser: the project's ROADMAP, read from
# `notes projects --waves` (TSV `version<TAB>state<TAB>open<TAB>done<TAB>heading`).
#
# Ordered planned-first DESCENDING, so the list reads DOWN out of the future and into the
# past: furthest plan, ..., next plan, the current wave, then the frozen versions below it.
# Wire: `DISPLAY<TAB>path<TAB>kind<TAB>version`.
_wave_rows() { # $1=profile $2=project $3=sheet-path
  local profile="$1" name="$2" sheet="$3"
  [ -n "$sheet" ] && [ -f "$sheet" ] || return 0
  notes --profile "$profile" projects --waves "$name" 2>/dev/null | awk -v s="$sheet" '
    BEGIN { FS="\t"; OFS="\t" }
    { ver[NR]=$1; state[NR]=$2; open[NR]=$3; n=NR }
    END {
      # planned, furthest first
      for (i=n; i>=2; i--) printf "  + %-9s %-8s %s open\t%s\twave\t%s\n", ver[i], state[i], open[i], s, ver[i]
      if (n >= 1) printf "  > %-9s %-8s %s open\t%s\twave\t%s\n", ver[1], state[1], open[1], s, ver[1]
    }'
}

# Browse a project's ROADMAP and its release notes, in one list that runs future -> past:
# the overview, the planned waves, the current wave, then the frozen per-version `.md` from
# BOTH `versions/` (sheet-model rollovers) and `changelog/` (release-managed projects keep
# their release notes here), newest first.
#
# Reached via fzf `become` (the `o` bind), so THIS runs as the sole fzf in the cockpit's
# window — a fresh fzf that owns the terminal, not a nested one (fzf-in-fzf-execute / a
# popup launched from execute are both fragile inside the cockpit's display-popup — see
# move_task; they render the cockpit instead). `q`/esc returns by re-`exec`ing the cockpit.
#
# Rows are `DISPLAY<TAB>path<TAB>kind<TAB>version`, kind ∈ overview|wave|frozen. The kind is
# what lets one list hold three things that answer `enter`, the preview and `C-s`
# differently, without a second picker.
#
# The row list itself, so the `a`/`N` binds can `reload` it after adding to a wave. Emitting
# only the wave rows there would have replaced the whole list with them.
browse_rows() { # $1=profile $2=project
  local profile="$1" name="$2" summary root rows d sheet waverows all=""
  summary="$(summary_of "$profile" "$name")"
  [ -n "$summary" ] && root="$(dirname "$summary")"
  [ -n "$root" ] || return 0
  # the working sheet — README.md when it carries the waves, else tasks.md
  for d in "$root/README.md" "$root/tasks.md"; do
    [ -f "$d" ] && grep -q '^## *Wave' "$d" 2>/dev/null && { sheet="$d"; break; }
  done
  waverows="$(_wave_rows "$profile" "$name" "${sheet:-}")"
  # frozen notes from versions/ + changelog/; show basename, keep the path for preview
  rows="$( for d in "$root/versions" "$root/changelog"; do
             [ -d "$d" ] && ls -1 "$d"/*.md 2>/dev/null
           done | awk -F/ 'NF{print "    "$NF"\t"$0"\tfrozen\t"$NF}' | sort -rV )"
  # pin the project overview (summary.md — the "where we are / next up" index) at the very TOP,
  # above everything. Enter opens it; C-s regenerates the overview (vs a version summary).
  [ -n "$summary" ] && [ -f "$summary" ] &&
    all="$(printf '= overview =\t%s\toverview\t-' "$summary")"
  for d in "$waverows" "$rows"; do
    [ -n "$d" ] || continue
    if [ -n "$all" ]; then all="$all"$'\n'"$d"; else all="$d"; fi
  done
  [ -n "$all" ] && printf '%s\n' "$all"
  return 0
}

browse_versions() { # $1 = section of the highlighted row (<profile>/<project>)
  local section="${1:-}" profile name prev all
  case "$section" in
    */*) profile="${section%%/*}"; name="${section#*/}" ;;
    *) exec "$SELF" ;; # not a project row — just go back to the cockpit
  esac
  all="$(browse_rows "$profile" "$name")"
  if [ -z "$all" ]; then
    echo "nothing for $name yet — roll a version with V, or generate an overview"; sleep 1.5; exec "$SELF"
  fi
  # The pane renders the note (md-render.sh) instead of syntax-highlighting its SOURCE, and
  # the preview window is deliberately NOT `wrap`: the renderer has already word-wrapped to
  # $FZF_PREVIEW_COLUMNS, and fzf's own wrap is what used to cut words mid-syllable and stamp
  # a continuation glyph on every second line.
  prev="$SELF --preview-version {3} {2} {4} '$profile' '$name'"
  printf '%s\n' "$all" | fzf \
    --ansi --reverse --delimiter='\t' --with-nth=1 \
    --preview "$prev" --preview-window 'right:62%:border-left' \
    --prompt "$name > " \
    --header 'enter: nvim   a: add to wave   N: plan a version   C-s: (re)generate   q/esc: back' \
    --bind 'enter:execute(nvim {2})' --bind 'q:abort' \
    --bind 'ctrl-d:preview-half-page-down' \
    --bind 'ctrl-u:preview-half-page-up' \
    --bind "a:execute($SELF --wave-add '$profile' '$name' {3} {4})+reload($SELF --wave-rows '$profile' '$name')+refresh-preview" \
    --bind "N:execute($SELF --wave-plan '$profile' '$name')+reload($SELF --wave-rows '$profile' '$name')+refresh-preview" \
    --bind "ctrl-s:execute(k={3}; f={2}; case \"\$k\" in overview) notes-version-summary --overview '$profile' '$name' ;; frozen) notes-version-summary --force '$profile' '$name' \"\$f\" ;; *) echo 'nothing to summarize until the version is rolled'; sleep 1 ;; esac)+refresh-preview"
  exec "$SELF" # versions fzf exited (q/esc) — relaunch the cockpit in the same window
}

# The preview pane for one browser row, dispatched on its KIND. An overview or a frozen
# version note is a file, and renders as one; a WAVE is a section of the live sheet plus
# the version's AI note, neither of which is a whole file.
preview_version() { # $1=kind $2=path $3=version $4=profile $5=project
  local kind="${1:-}" path="${2:-}" ver="${3:-}" profile="${4:-}" name="${5:-}" ai
  case "$kind" in
    wave) : ;;
    *) md_render "${path:--}"; return $? ;;
  esac
  # The wave's own section of the sheet, heading included, up to the next `## `.
  #
  # The version is compared as a space-delimited SUBSTRING, not used as a regex. For a
  # well-formed `vX.Y.Z` the two happen to agree - the `.` wildcards land on the literal
  # dots - so this is not fixing a live bug, and there is no test that can prove it is:
  # the equivalent regex was tried against a decoy heading in both directions and matched
  # neither. It is here because that agreement is a coincidence of the format rather than
  # a property of the match, and a heading that ever carries a suffix (`v1.14.0-rc1`) or a
  # second version in its text breaks it silently, in a preview pane where a wrong answer
  # looks exactly like a right one.
  awk -v v=" $ver " '
    /^## / {
      if (inw) exit
      if ($0 ~ /^## *Wave/ && index($0 " ", v) > 0) { inw = 1; print }
      next
    }
    inw { print }
  ' "$path" 2>/dev/null | md_render -
  # then the version's AI note — the proof and the working log behind those checkboxes
  ai="$(dirname "$path")/ai/${ver}.md"
  if [ -f "$ai" ]; then
    printf '\n'
    md_render "$ai"
  else
    printf '\n(no AI notes for %s yet)\n' "$ver"
  fi
}

# `a` in the version browser — add a task to the HIGHLIGHTED wave. On a non-wave row it
# says so rather than guessing which version the human meant.
wave_add() { # $1=profile $2=project $3=kind $4=version
  local profile="$1" name="$2" kind="$3" ver="$4" text
  [ "$kind" = wave ] || { echo "not a wave row — highlight the current or a planned version"; sleep 1.5; return 0; }
  read -r -p "add to $ver: " text || return 0
  [ -n "${text// /}" ] || return 0
  notes --profile "$profile" ptask "$name" add --to "$ver" "$text" || sleep 2
}

# `N` in the version browser — open a PLANNED version on the roadmap. A version is opened
# with its first task rather than empty: an empty planned wave is a heading that says
# nothing, and `ptask add --to` mints the section anyway, so there is no second verb to keep
# in sync.
wave_plan() { # $1=profile $2=project
  local profile="$1" name="$2" ver text
  read -r -p "plan version (vX.Y.Z): " ver || return 0
  [ -n "${ver// /}" ] || return 0
  read -r -p "first task for $ver: " text || return 0
  [ -n "${text// /}" ] || { echo "a version opens with its first task — nothing added"; sleep 1.5; return 0; }
  notes --profile "$profile" ptask "$name" add --to "$ver" "$text" || sleep 2
}

# ── accept the overview's "Next up" suggestions (the `g` key) ────────
# The `<!-- nextup:auto -->` block of a project's summary.md — the "## Now / ## Next" index
# notes-version-summary --overview writes. Two readers on one extractor: the rail brief wants
# the whole block as prose, the `g` accept flow wants only its unchecked tasks.
nextup_block() { # $1 = summary.md path -> the block, markers excluded
  awk '/<!-- nextup:auto -->/{s=1;next} /<!-- \/nextup:auto -->/{s=0} s' "$1" 2>/dev/null
}

nextup_tasks() { # $1 = summary.md path -> one suggested task per line (marker + checkbox stripped)
  nextup_block "$1" | sed -n 's/^- \[ \] //p'
}

# repo_path_of <project> -> /abs/repo from REPOS_FILE (pathfilter stripped), or nothing.
repo_path_of() {
  [ -f "$REPOS_FILE" ] || return 0
  local v
  v="$(awk -F= -v k="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" \
    '!/^[[:space:]]*#/ { key=tolower($1); gsub(/[[:space:]]/,"",key); if (key==k){ sub(/^[^=]*=/,""); print; exit } }' \
    "$REPOS_FILE")"
  v="${v%%:*}"; v="${v/#\~/$HOME}"; printf '%s' "$v"
}

# epic_of <summary.md> -> the tracker epic id from the `<!-- cockpit: … -->` marker
# (prefers release-epic, falls back to the vikunja project id). Empty when unset.
epic_of() {
  local m e
  m="$(grep -o '<!-- cockpit:[^>]*-->' "$1" 2>/dev/null | head -1)"
  e="$(sed -n 's/.*release-epic=\([0-9][0-9]*\).*/\1/p' <<<"$m")"
  [ -z "$e" ] && e="$(sed -n 's/.*[[:space:]]vikunja=\([0-9][0-9]*\).*/\1/p' <<<"$m")"
  printf '%s' "$e"
}

accept_next() { # $1 = section of the highlighted row (<profile>/<project>)
  local section="${1:-}" profile name summary_md tasks selected repo epic task ans line can_ticket=0
  case "$section" in
    */*) profile="${section%%/*}"; name="${section#*/}" ;;
    *) exec "$SELF" ;; # not a project row
  esac
  summary_md="$(summary_of "$profile" "$name")"
  [ -n "$summary_md" ] && [ -f "$summary_md" ] \
    || { echo "no summary.md for $name"; sleep 1.5; exec "$SELF"; }
  tasks="$(nextup_tasks "$summary_md")"
  if [ -z "$tasks" ]; then
    echo "no suggestions for $name yet — press o, then C-s on the overview to generate them"; sleep 2; exec "$SELF"
  fi
  selected="$(printf '%s\n' "$tasks" | fzf --multi --ansi --reverse \
    --prompt "add to $name's sheet > " \
    --header "SUGGESTIONS from the overview - picking these ADDS them to your task sheet.
Not questions: to answer one, esc then press !
TAB mark · enter add selected · esc cancel")"
  [ -z "$selected" ] && exec "$SELF"
  repo="$(repo_path_of "$name")"
  epic="$(epic_of "$summary_md")"
  [ -n "$repo" ] && [ -d "$repo" ] && command -v ticket >/dev/null 2>&1 && [ -n "$epic" ] && can_ticket=1
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    if notes --profile "$profile" ptask "$name" add "$task" >/dev/null 2>&1; then
      echo "+ sheet: $task"
    else
      echo "! sheet add failed: $task"; continue
    fi
    if [ "$can_ticket" -eq 1 ]; then
      read -r -p "  file '$task' as a ticket? [y/N] " ans </dev/tty
      case "$ans" in
        y | Y)
          if line="$( (cd "$repo" && ticket create "$epic" "$task" --labels=todo) 2>&1 )"; then
            echo "  -> $line"
          else
            echo "  (ticket create failed: $line)"
          fi
          ;;
      esac
    fi
  done <<< "$selected"
  echo "refreshing overview ..."
  notes-version-summary --overview "$profile" "$name" >/dev/null 2>&1 || true
  sleep 1; exec "$SELF"
}

restore_project() {
  local section="${1:-}" profile pick i
  [ -z "$section" ] && section="$(read_section)"
  # the `all` lane spans orgs, so it is not a write target: fall back to the ACTIVE org
  [ "$section" = all ] && section="$(active_profile_or_first)"
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
    K / J          previous / next section   (h / l also work)
    C-u / C-d      scroll the preview
    p              cycle priority filter  (urgent -> high -> low -> all)
    w              cycle the usage window (7d -> 30d -> today), usage view only
    i              search  (esc leaves search)
    enter          edit the task in nvim

  task
    s              toggle in-progress  ( [ ] <-> [/] )
    C-x            mark done
    C-a            add a task to the section
    W              start a wave on this project's open tasks  (no session needed)
    d              delete the task  (asks first)
    u              undo the last delete
    m              move to another section / project

  project
    n              new project in this section
    V              roll to next version  (freezes + writes an LLM summary)
    o              overview + frozen versions  (top = where we are / next up · C-d/C-u scroll · C-s regen)
    g              accept "next up" suggestions from the overview -> your sheet
                     (these are IDEAS to add, not questions to answer - that is !)
    !              answer the oldest question waiting on you (any project)
    A              archive the highlighted project
    R              restore an archived project

  waves  (hand a batch of work to the agents)
    1. press  W  on the project row — that is the whole trigger.
         a headless agent turns every open task on the wave into a ticket,
         cuts ONE branch, and stops; the approval arrives as a question below
    2. come back here and press  a  for the factory view to watch it,
         and to answer questions it raises  (enter on a "?" row)
    3. it asks you once more before merging
    full runbook:  ~/.config/shared-hooks/WAVES.md

  other
    a              cycle views: tasks -> factory -> usage -> tasks

  the left pane, in the tasks view, follows the cursor: standing on a project
  shows what shipped, the overview's "Now", and its "Next" checklist. It is a
  capped summary — `o` opens the whole thing.

  usage  how well and how expensively the agents are working, over the window
         `w` cycles. Joins eval scores to session cost on the session id, so a
         row reads [9] $2.11 3 ed <what it did>. Enter resumes that session;
         enter on an attention row opens the eval AT the finding.
         Tokens lead and dollars trail on purpose: cost telemetry covers ~2% of
         sessions (Prometheus keeps a week), so `-` means unknown, never free,
         and every total says how many sessions it could not see.
                     tasks   your task lists (the backlog)
                     factory what is IN FLIGHT, grouped by stage: needs-you,
                             triage, building, reviewing, shipped. One line per
                             item; an empty stage is not shown; shipped folds to
                             a version total with its cost coverage beside it.
                             Cross-profile, so a question anywhere shows here.
                             enter = answer a "?" / open a checkpoint
                             C-a  = add work,  V freezes the version's telemetry
                             the left pane shows that row's recorded history:
                             each stage, when it started, how long it sat there
    T              create today's notes (all profiles)
    ?              this help
    q / esc        quit

EOF
}

jump_row() { # $1=type $2=file $3=line — deliberate edit in a new tmux window
  local type="$1" file="$2" line="$3"
  # Still a WHITELIST. Relaxed to admit eval rows, not opened up: a `*)` here would spawn
  # nvim on whatever c3 happens to hold for every row type in every view.
  case "$type" in task|eval) ;; *) return 0 ;; esac
  [ -f "$file" ] || return 0
  local ln="${line:-1}"; [[ "$ln" =~ ^[0-9]+$ ]] || ln=1
  tmux new-window "nvim +${ln} '$file'"
}

case "${1:-}" in
  --list) shift; list_section "${1:-}"; exit 0 ;;
  --rail) rail "${2:-}" "${3:-}" "${4:-}"; exit 0 ;;
  --next-section) next_section; exit 0 ;;
  --prev-section) prev_section; exit 0 ;;
  --add) add_task "${2:-}"; exit 0 ;;
  --task-op) shift; task_op "$@"; exit 0 ;;
  --delete-task) shift; confirm_delete "$@"; exit 0 ;;
  --undo-delete) shift; undo_delete; exit 0 ;;
  --start-wave) shift; start_wave "${1:-}"; exit 0 ;;
  --move) shift; move_task "$@"; exit 0 ;;
  --jump) shift; jump_row "$@"; exit 0 ;;
  --cycle-pfilter) cycle_pfilter; exit 0 ;;
  --cycle-window) cycle_window; exit 0 ;;
  --toggle-mode) toggle_mode; exit 0 ;;
  --enter-action) shift; _enter_action "$@"; exit 0 ;;
  --answer) shift; answer_ask "${1:-}" "${2:-}"; exit 0 ;;
  --answer-next) answer_next; exit 0 ;;
  --show-ask) [ -n "${2:-}" ] && tmux new-window "agent-ask show '$2' | ${PAGER:-less}" 2>/dev/null; exit 0 ;;
  --resume-session) [ -n "${2:-}" ] && tmux new-window "sessions resume '$2'" 2>/dev/null; exit 0 ;;
  --open-file) [ -f "${2:-}" ] && tmux new-window "nvim '$2'" 2>/dev/null; exit 0 ;;
  --journal) [ -n "${2:-}" ] && tmux new-window "journalctl --user -u 'agentctl@$2.service' -e -n 200 || journalctl --user -u 'agentctl@$2.service'" 2>/dev/null; exit 0 ;;
  --wave-log) [ -n "${2:-}" ] && tmux new-window "tail -f '$HOME/.local/state/agentctl/wave/$2.log'" 2>/dev/null; exit 0 ;;
  --new-project) new_project "${2:-}"; exit 0 ;;
  --roll-project) roll_project "${2:-}"; exit 0 ;;
  --roll-now) roll_now "${2:-}" "${3:-}" "${4:-patch}"; exit $? ;;  # headless: a merged wave rolls its own patch
  --browse-versions) browse_versions "${2:-}"; exit 0 ;;
  --wave-rows) browse_rows "${2:-}" "${3:-}"; exit 0 ;;          # the `o` list, for reload
  --preview-version) preview_version "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"; exit $? ;;
  --wave-add) wave_add "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit 0 ;;
  --wave-plan) wave_plan "${2:-}" "${3:-}"; exit 0 ;;
  --accept-next) accept_next "${2:-}"; exit 0 ;;
  --archive-project) archive_project "${2:-}"; exit 0 ;;
  --restore-project) restore_project "${2:-}"; exit 0 ;;
  --help-view) help_view; exit 0 ;;
esac

# Sourced (by the test suite) rather than run: stop here with every function defined but
# the UI never launched. Must sit after the verb dispatch so `--verb` still works, and
# before the fzf preflight so sourcing never needs fzf/notes on PATH.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }
command -v notes >/dev/null 2>&1 || { echo "notes CLI not found (build ~/.dotfiles/.local/src/notes-cli)"; exit 1; }

# Bootstrap today's note for every profile so a fresh day never shows spurious zeros
# (the daily note is per-profile and `focus --all` only reads notes that exist).
# Idempotent — a no-op once today's notes are present.
notes today --all >/dev/null 2>&1 || true

# Keep the section you were last on. This used to hard-reset to `personal` on every
# launch, and several actions relaunch the cockpit (`roll_project`, `browse_versions`,
# `start_wave` all `exec "$SELF"` or return through it). So pressing W on the `bnb`
# section and coming back landed you on `personal` - where that project does not exist
# and therefore neither do its agent rows. A wave would be running perfectly well and
# the cockpit would be showing you a section that structurally could not display it.
#
# Still validated, not merely trusted: a section naming a profile that no longer exists
# (renamed, removed from the notes config) would render an empty cockpit with no
# explanation, so anything unrecognised falls back to `personal`.
_last="$(cat "$STATE" 2>/dev/null)"
case "$_last" in
  all) : ;;                                            # the cross-profile lane is valid
  */*) sections_list | grep -qxF "${_last%%/*}" || _last="" ;;   # <profile>/<project>
  ?*)  sections_list | grep -qxF "$_last" || _last="" ;;
  *)   _last="" ;;
esac
echo "${_last:-$(active_profile_or_first)}" > "$STATE"
: > "$PFILTER"           # ...and unfiltered (priority filter cleared)
: > "$WINF"              # ...and the usage window back to its 7d default
# ...in the tasks view (a cycles tasks -> agents -> bridge). NOTES_COCKPIT_MODE lets a
# caller pin the opening view, which is how the cockpit session's `bridge` window opens
# on the ask queue instead of making you press `a` twice every time it restarts.
printf '%s' "${NOTES_COCKPIT_MODE:-tasks}" > "$MODEF"
# modal nav: printable keys that mean "command" in normal mode but must TYPE while
# searching. `i` shows the input and unbinds them; leaving search (esc) rebinds them.
# `?` is intentionally NOT modal — it opens the help pager.
MODAL='j,k,h,l,i,q,s,m,n,V,o,p,w,g,a,A,R,T,!'

# No argument: the FIRST render reads the section that was just validated above, the same
# one every `reload($SELF --list)` reads. This was pinned to `personal` while the rail
# preview (and every reload after the first keypress) followed $STATE — so relaunching on
# any other section opened with the sidebar pointing at `bnb` and the body listing
# `personal`. The two surfaces openly disagreed about where you were standing.
list_section | fzf \
  --ansi --reverse --cycle --no-sort --border --no-input --wrap --wrap-sign='  ' \
  --delimiter=$'\t' --with-nth='7..' \
  --prompt='search > ' \
  --header='! answer · a views · enter open/answer · C-a add · C-t ai · ? keys' \
  --preview "$SELF --rail {6} {5} {4}" \
  --preview-window 'left:24%:wrap:border-right' \
  --bind 'ctrl-/:toggle-preview' \
  --bind "?:execute($SELF --help-view | less -R)" \
  --bind "!:execute($SELF --answer-next)+reload($SELF --list)+refresh-preview" \
  --bind 'j:down+transform:[ {1} = head ] && echo down' \
  --bind 'k:up+transform:[ {1} = head ] && echo up' \
  --bind 'up:up+transform:[ {1} = head ] && echo up' \
  --bind 'down:down+transform:[ {1} = head ] && echo down' \
  --bind 'load:transform:[ {1} = head ] && echo down' \
  --bind "h:execute-silent($SELF --prev-section)+reload($SELF --list)+refresh-preview" \
  --bind "l:execute-silent($SELF --next-section)+reload($SELF --list)+refresh-preview" \
  --bind "K:execute-silent($SELF --prev-section)+reload($SELF --list)+refresh-preview" \
  --bind "J:execute-silent($SELF --next-section)+reload($SELF --list)+refresh-preview" \
  --bind "tab:execute-silent($SELF --next-section)+reload($SELF --list)+refresh-preview" \
  --bind "i:show-input+unbind($MODAL)" \
  --bind "esc:transform:[ \"\$FZF_INPUT_STATE\" = hidden ] && echo abort || echo \"clear-query+hide-input+rebind($MODAL)\"" \
  --bind 'q:abort' \
  --bind "ctrl-x:execute-silent($SELF --task-op done {6} {5})+reload($SELF --list)+refresh-preview" \
  --bind "s:execute-silent($SELF --task-op start {6} {5})+reload($SELF --list)+refresh-preview" \
  --bind "d:execute($SELF --delete-task {6} {5})+reload($SELF --list)+refresh-preview" \
  --bind "u:execute($SELF --undo-delete)+reload($SELF --list)+refresh-preview" \
  --bind 'ctrl-d:preview-half-page-down' \
  --bind 'ctrl-u:preview-half-page-up' \
  --bind "ctrl-a:execute($SELF --add {6})+reload($SELF --list)+refresh-preview" \
  --bind "W:execute($SELF --start-wave {6})+reload($SELF --list)+refresh-preview" \
  --bind "m:execute($SELF --move {6} {2} {5})+reload($SELF --list)+refresh-preview" \
  --bind "n:execute($SELF --new-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "V:execute($SELF --roll-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "o:become($SELF --browse-versions {6})" \
  --bind "g:become($SELF --accept-next {6})" \
  --bind "A:execute($SELF --archive-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "R:execute($SELF --restore-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "p:execute-silent($SELF --cycle-pfilter)+reload($SELF --list)+refresh-preview" \
  --bind "w:execute-silent($SELF --cycle-window)+reload($SELF --list)+refresh-preview" \
  --bind "T:execute-silent(notes today --all)+reload($SELF --list)+refresh-preview" \
  --bind "a:execute-silent($SELF --toggle-mode)+reload($SELF --list)+refresh-preview" \
  --bind "enter:transform($SELF --enter-action {1} {2} {3} {4})"
