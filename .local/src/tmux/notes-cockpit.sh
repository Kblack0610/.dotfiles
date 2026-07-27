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
# Per-instance state suffix. The section/mode/filter files are keyed on UID alone, which is
# right for a popup (only one can be open) but wrong the moment two copies run at once —
# the persistent cockpit session keeps a `bridge` window and a `notes` window both running
# this script, and without a suffix they would stomp each other's view on every keypress.
# Empty by default, so the popup's paths are byte-identical to what they always were.
INSTANCE="${NOTES_COCKPIT_INSTANCE:-}"
STATE="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}${INSTANCE:+-$INSTANCE}.section"
# THREE views, cycled by `a`  (tasks -> agents -> bridge -> tasks):
#   tasks   your task lists (the default; unchanged).
#   agents  WHO is working each project and what the finished ones cost: live Claude
#           sessions (status/branch/what), then the sessions that shipped the CURRENT
#           version with their tokens and USD, then a version total. Plus a headless
#           runner row and a global sentinel/runners section. Joined by
#           `<!-- canonical: NAME -->`, which may list several runtime names.
#           It shows SESSIONS - asks and sprint rows belong to the bridge.
#   bridge  THE middle ground: open QUESTIONS agents raised on your tasks. Answer (enter,
#           round-trips to resume the agent) or add work (ctrl-a). Task-anchored.
# Each is its own render; none overwrites another.
MODEF="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}${INSTANCE:+-$INSTANCE}.mode"
read_mode() { cat "$MODEF" 2>/dev/null || echo tasks; }
toggle_mode() { # cycle tasks -> agents -> bridge -> tasks
  case "$(read_mode)" in
    tasks)  printf agents > "$MODEF" ;;
    agents) printf bridge > "$MODEF" ;;
    *)      printf tasks  > "$MODEF" ;;
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

read_section() { cat "$STATE" 2>/dev/null || echo personal; }

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

# ── one task row: type profile file line key section cleantext ──
# Shared formatter for both daily `## Focus` tasks and project-sheet `## Wave` tasks (both
# arrive as `path<TAB>line<TAB>key<TAB>rawtext`). `section` places the row: `<profile>` for
# an untagged/main task, `<profile>/<project>` for a project task.
_task_row() { # $1=profile $2=file $3=line $4=key $5=section $6=rawtext
  local clean glyph lane="" tid=""
  # `#ai` is the LANE marker: this item belongs to the agents (a `/wave` picks these up),
  # everything untagged is the human's. Show it, so one list reads as two lanes.
  case "$6" in *'#ai'*) lane="${C_PROJ}@ai${C_OFF} " ;; esac
  # A stamped ticket id means the wave has already scoped this one — surface it dimly so
  # the burn-down is visible without opening the sheet.
  tid="$(printf '%s' "$6" | grep -oE '<!--[[:space:]]*(vk|cu):[0-9]+' | grep -oE '[0-9]+' | head -1)"
  [ -n "$tid" ] && tid=" ${C_DIM}#${tid}${C_OFF}"
  clean="$(printf '%s' "$6" | sed -E 's/ *<!--[^>]*-->//; s/^[[:space:]]*- \[[ /xX]\] //; s/[[:space:]]*#ai\b//')"
  if [[ "$6" =~ ^[[:space:]]*-\ \[/\] ]]; then glyph="${C_INP}[/]${C_OFF}"; else glyph="${C_BOX}[ ]${C_OFF}"; fi
  printf 'task\t%s\t%s\t%s\t%s\t%s\t%s %s%s%s\n' "$1" "$2" "$3" "$4" "$5" "$glyph" "$lane" "$clean" "$tid"
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

# ══ AGENTS mode ═══════════════════════════════════════════════════════════════
# Same sections/projects, but each project's body is the AGENTS working it. The join
# from a vault project to its agent runtime state is the `<!-- canonical: NAME -->`
# marker (sessions.jsonl, sprint blackboards, ~/.agent/asks are all keyed by it).

# canonical_of <profile> <project-lc> -> canonical name(s), or the project name if
# unmarked. A marker may name SEVERAL runtime projects, comma-separated:
#
#   <!-- canonical: notes-cockpit, dotfiles -->
#
# because a vault project and a repo are not the same axis. `notes-cockpit` is a product
# the user tracks; the sessions that build it register under `dotfiles`, the repo they
# ran in. Keying on one name made the agents view render "- idle" for the very project
# being actively worked on. Callers treat the result as a LIST (see _canon_list).
canonical_of() {
  local prof="$1" proj="$2" path dir canon=""
  path="$(notes --profile "$prof" projects 2>/dev/null | awk -F'\t' -v p="$proj" 'tolower($1)==p{print $2; exit}')"
  if [ -n "$path" ]; then
    dir="$(dirname "$path")"
    canon="$(grep -rhoE '<!--[[:space:]]*canonical:[[:space:]]*[^>]+' "$dir" 2>/dev/null \
      | head -1 | sed -E 's/.*canonical:[[:space:]]*//; s/[[:space:]]*--[[:space:]]*$//; s/[[:space:]]+$//')"
  fi
  # PRIMARY name only. Every other consumer - the bridge's `agent-ask list <canon>`,
  # _sprint_items, _ckpt_file - passes this straight to a tool as a project name, so
  # returning the raw "a, b" string here silently broke all of them: `agent-ask list
  # 'notes-cockpit, dotfiles'` matches nothing, so the bridge rendered empty while a
  # gate ask sat pending. Callers that want every name ask for it explicitly.
  printf '%s' "${canon%%,*}" | sed 's/[[:space:]]*$//'
}

# Every runtime name a vault project claims, one per line. Only the agents view uses
# this: it LOOKS in several places for existing state. Anything that WRITES, or that
# passes a name to another tool, wants canonical_of (the primary) instead.
canonicals_of() { # $1=profile $2=project-lc
  local prof="$1" proj="$2" path dir raw=""
  path="$(notes --profile "$prof" projects 2>/dev/null | awk -F'\t' -v p="$proj" 'tolower($1)==p{print $2; exit}')"
  if [ -n "$path" ]; then
    dir="$(dirname "$path")"
    raw="$(grep -rhoE '<!--[[:space:]]*canonical:[[:space:]]*[^>]+' "$dir" 2>/dev/null \
      | head -1 | sed -E 's/.*canonical:[[:space:]]*//; s/[[:space:]]*--[[:space:]]*$//')"
  fi
  _canon_list "${raw:-$proj}"
}

# "a, b" -> one name per line. The primary (first) name is what new state is keyed by;
# the rest are additional places to LOOK for existing state.
_canon_list() { printf '%s' "${1:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

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

# agent rows for ONE project: who is working now, then what shipped this version.
# Wire (7 cols, DISPLAY=col7): <type> <profile> <c3> <c4> <c5=canon> <c6=sec> <DISPLAY>
#   sess: c3=session_id  (enter -> --resume-session, unchanged)
#
# NO ask rows and NO sprint row, on purpose. Both were duplicated verbatim from the
# BRIDGE view - same `agent-ask list --pending` call, same newest sprint-*.md - so on a
# project whose only state was a pending ask, this view and the bridge rendered the same
# bytes. The bridge owns questions and work items (cockpit.sh pins a window to it); this
# view owns sessions. Re-adding either here re-creates the duplication.
_project_agents() { # $1=profile $2=lc $3=canon $4=summary-path $5=runnerCanon $6=runnerDetail
  local prof="$1" lc="$2" canon="$3" summary="${4:-}" rcanon="${5:-}" rdetail="${6:-}" sec="$1/$2"
  local vstart; vstart="$(_version_start "$summary")"

  # A project may claim several runtime names (see canonicals_of); gather from each.
  # $canon arrives as the PRIMARY name; the full list is looked up here so the rest of
  # the cockpit keeps receiving a single usable project name.
  #
  # Resolved FIRST: everything below matches against it, including the runner check.
  local names; names="$(canonicals_of "$prof" "$lc")"
  [ -n "$names" ] || names="$canon"
  local primary="$canon"

  # A headless delivery-loop runner on THIS project is an agent working it, and is not
  # shown by the bridge - so unlike asks and sprint rows it belongs here. The global
  # footer lists every runner, but not which project each is on.
  if [ -n "$rdetail" ] && printf '%s\n' "$names" | grep -qxF "$rcanon"; then
    printf 'runner\tdelivery-loop\tdelivery-loop\t\t%s\t%s\t  %s~ runner%s %s%s%s\n' \
      "$primary" "$sec" "$C_INP" "$C_OFF" "$C_DIM" "$rdetail" "$C_OFF"
  fi

  # --- running right now (live <pid>.json, project-resolved by `sessions rows`) ---
  # No tokens/cost here: a running session's usage is incomplete by definition.
  local id st proj branch started what glyph col n
  if command -v sessions >/dev/null 2>&1; then
    while IFS=$'\t' read -r id st proj branch started what; do
      [ -n "$id" ] || continue
      case "$st" in
        busy)    glyph='~'; col="$C_INP" ;;
        waiting) glyph='!'; col="$C_SEL" ;;
        *)       glyph='o'; col="$C_DIM" ;;
      esac
      [ "$branch" = "-" ] && branch=""
      # A session that just started has no ai-title yet.
      [ "$what" = "-" ] && what="(just started)"
      printf 'sess\t%s\t%s\t\t%s\t%s\t  %s%s %s%s %s%s%s  %s%s%s\n' \
        "$prof" "$id" "$primary" "$sec" \
        "$col" "$glyph" "$st" "$C_OFF" \
        "$C_DIM" "${branch:+$branch }$(_elapsed "$started")" "$C_OFF" \
        "$C_OFF" "$what" "$C_OFF"
    done < <(while IFS= read -r n; do sessions rows "$n" 2>/dev/null; done <<< "$names")
  fi

  # --- finished, this version only (registry + its telemetry) ---
  command -v agent-usage >/dev/null 2>&1 || return 0
  local rows
  rows="$(while IFS= read -r n; do
            agent-usage rows "$n" --since "$vstart" 2>/dev/null
          done <<< "$names" | sort -t"$(printf '\t')" -k2,2rn | head -6)"
  [ -n "$rows" ] || return 0

  printf 'head\t\t\t\t\t\t%s    --- shipped this version ---%s\n' "$C_DIM" "$C_OFF"

  local _u ed cost nocost tok models dur label
  while IFS=$'\t' read -r id _u ed cost nocost tok models dur label; do
    [ -n "$id" ] || continue
    [ "$models" = "-" ] && models=""
    [ "$label" = "-" ] && label="(no commit recorded)"
    printf 'sess\t%s\t%s\t\t%s\t%s\t  %s*%s %s  %s%s ed  %s tok  %s%s\n' \
      "$prof" "$id" "$primary" "$sec" \
      "$C_PROJ" "$C_OFF" "$(printf '%.48s' "$label")" \
      "$C_DIM" "$ed" "$(_human_tok "$tok")" \
      "$([ "$nocost" = 1 ] && printf -- '-' || printf '$%.2f' "$cost")" "$C_OFF"
  done <<< "$rows"

  # --- the version total ---
  local n te tt tc anyunk
  read -r n te tt tc anyunk <<< "$(printf '%s\n' "$rows" \
    | awk -F'\t' '{n++; e+=$3; c+=$4; t+=$6; if($5=="1") u++}
                  END{printf "%d %d %d %.2f %d\n", n, e, t, c, u+0}')"
  printf 'hint\t\t\t\t\t\t%s    -- %s session%s - %s edits - %s tok - $%.2f%s --%s\n' \
    "$C_DIM" "$n" "$([ "$n" = 1 ] || printf s)" "$te" "$(_human_tok "$tt")" "$tc" \
    "$([ "${anyunk:-0}" -gt 0 ] 2>/dev/null && printf ' (+%s untracked)' "$anyunk")" "$C_OFF"
}

# 1234567 -> 1.2M / 340k / 512
_human_tok() {
  awk -v n="${1:-0}" 'BEGIN{
    if (n >= 1000000) printf "%.1fM", n/1000000;
    else if (n >= 1000) printf "%.0fk", n/1000;
    else printf "%d", n }'
}

# One profile's AGENTS view: a group per project with its agent rows (or "- idle").
# The summary path comes straight out of the `notes projects` row we are already
# reading, so neither canonical_of nor _version_start needs to shell out again.
_profile_agents_view() { # $1=profile
  local prof="$1" name sum st ver lc canon body rline rcanon rdetail
  rline="$(_runner_line)"
  if printf '%s' "$rline" | grep -q "$(printf '\t')"; then
    rcanon="${rline%%$'\t'*}"; rdetail="${rline#*$'\t'}"
  else rcanon=""; rdetail=""; fi
  notes --profile "$prof" projects 2>/dev/null | while IFS=$'\t' read -r name sum st ver; do
    [ -z "$name" ] && continue
    lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    canon="$(canonical_of "$prof" "$lc")"
    _subheader "$name" "$st" "$ver"
    body="$(_project_agents "$prof" "$lc" "$canon" "$sum" "$rcanon" "$rdetail")"
    if [ -n "$body" ]; then printf '%s\n' "$body"
    else printf 'hint\t\t\t\t\t\t%s  - idle%s\n' "$C_DIM" "$C_OFF"; fi
  done
}

# The GLOBAL section (agents mode, once at the bottom): sentinel trips + agentctl runners.
#
# The rows come from fleet.sh, which is the single owner of "what is running headless".
# This used to enumerate a SEVEN-NAME HARDCODED LIST of units, which is precisely how it
# went stale — a runner added to ~/.config/agentctl/agents/ never appeared here. fleet.sh
# derives the roster from that conf dir, so delegating fixes the staleness at the source
# rather than re-listing the names in a second place that can drift again.
#
# fleet emits `type<TAB>id<TAB>target<TAB>state<TAB>DISPLAY`; this view's wire format is
# 7 fields (see the header). Only the reshape lives here.
#
# Watches are still filtered to TRIP/ERROR: this is the compact global footer of a
# task-shaped view, and an all-OK wall of green is noise here. The cockpit's `fleet`
# window is where the full roster belongs.
_global_agents() {
  printf 'head\t\t\t\t\t\t%s── global · sentinel + runners ──%s\n' "$C_HEAD" "$C_OFF"
  local fleet="${FLEET_SH:-$(dirname "$SELF")/fleet.sh}"
  [ -x "$fleet" ] || { printf 'hint\t\t\t\t\t\t%s  fleet.sh not found%s\n' "$C_DIM" "$C_OFF"; return 0; }

  local type id target state disp any=0
  while IFS=$'\t' read -r type id target state disp; do
    case "$type" in
      watch)
        case "$state" in
          TRIP|ERROR) any=1; printf 'sentinel\t\t%s\t\t\t\t%s\n' "$target" "$disp" ;;
        esac ;;
    esac
  done < <("$fleet" --watches 2>/dev/null)
  [ "$any" -eq 0 ] && printf 'hint\t\t\t\t\t\t%s  sentinel: all watches OK%s\n' "$C_DIM" "$C_OFF"

  while IFS=$'\t' read -r type id target state disp; do
    [ "$type" = runner ] || continue
    printf 'runner\t\t%s\t\t\t\t%s\n' "$id" "$disp"
  done < <("$fleet" --runners 2>/dev/null)
  return 0
}

# ══ BRIDGE view (the 3rd view) ══════════════════════════════════════════════
# The middle ground: open QUESTIONS agents raised, anchored to the task they concern.
# Per project (joined by canonical): each open ask, its task shown as context. Enter
# answers it (round-trips to resume the agent); ctrl-a adds work to that project.
# ══ BRIDGE work items ═══════════════════════════════════════════════════════
# Parse the newest sprint blackboard's Rows/Queue table into work items. Schema-
# tolerant: map columns by header name, derive a lifecycle stage from the Status
# keyword, pull a PR number. TSV out: ticket \t stage \t title \t pr \t sentinel.
_sprint_items() { # $1=canon
  local bb; bb="$(ls -1t "$HOME/.agent/plans/$1"/sprint-*.md 2>/dev/null | head -1)"
  [ -n "$bb" ] || return 0
  awk -F'|' '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    !cols && /\|/ && (tolower($0) ~ /ticket/ && tolower($0) ~ /status/) {
      for(i=2;i<=NF;i++){ h=tolower(trim($i)); if(h!="") col[h]=i }
      cols=1; next
    }
    /^\|[ ]*:?-+/ { next }
    cols && /^\|/ {
      tk=trim($(col["ticket"])); st=trim($(col["status"])); ti=trim($(col["title"]))
      sen=(col["sentinel"])?trim($(col["sentinel"])):""
      if(tk=="" || tolower(tk)=="ticket") next
      low=tolower(st" "sen)
      if(low ~ /merged|status: *done|\bdone\b/) stage="merged"
      else if(low ~ /blocked/) stage="blocked"
      else if(low ~ /error|failed/) stage="error"
      else if(low ~ /pr[- ]?open|pr *#|pull\/[0-9]|merge it|ready/) stage="review"
      else if(low ~ /queued|filed|not dispatched|n\/a|returns/) stage="queued"
      else stage="working"
      pr=""; if(match(st,/pull\/[0-9]+/)) pr=substr(st,RSTART+5,RLENGTH-5)
      else if(match(st,/#[0-9]+/)) pr=substr(st,RSTART+1,RLENGTH-1)
      # US-delimited (\037) so a `read` on empty pr/sen does not collapse fields
      printf "%s\037%s\037%s\037%s\037%s\n", tk, stage, ti, pr, sen
    }
  ' "$bb"
}

# terminal sentinel of a checkpoint (DONE|FAILED|PARTIAL), or empty
_ckpt_sentinel() { # $1=file
  [ -f "$1" ] || return 0
  grep -oE 'STATUS:? *(DONE|FAILED|PARTIAL)' "$1" 2>/dev/null | tail -1 | awk '{print $NF}'
}

# resolve a ticket's checkpoint file: sentinel hint -> ticket.md -> first-token.md
_ckpt_file() { # $1=canon $2=ticket $3=sentinel -> path or empty
  local d="$HOME/.agent/plans/$1/checkpoints" base
  case "$3" in
    *checkpoints/*) base="$(printf '%s' "$3" | sed -E 's#.*checkpoints/##; s/\.md.*//; s/[ `]//g')"
      [ -f "$d/$base.md" ] && { printf '%s' "$d/$base.md"; return; } ;;
  esac
  [ -f "$d/$2.md" ] && { printf '%s' "$d/$2.md"; return; }
  local first="${2%% *}"; [ -f "$d/$first.md" ] && printf '%s' "$d/$first.md"
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

# The bridge: per project, the WORK ITEMS agents are moving (sprint rows + checkpoint
# progress) followed by open QUESTIONS. Top line = the status header (where we are).
_bridge_view() { # $1=profile
  local prof="$1" name st ver lc canon
  local body="" cw=0 cn=0 cr=0 cb=0 cm=0
  while IFS=$'\t' read -r name _sum st ver; do
    [ -z "$name" ] && continue
    lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    canon="$(canonical_of "$prof" "$lc")"
    local pbody="" sec="$prof/$lc"
    # --- sprint work items ---
    local tk stage title pr sen cf prog glyph col prbadge progd ssent
    while IFS=$'\037' read -r tk stage title pr sen; do
      [ -z "$tk" ] && continue
      cf="$(_ckpt_file "$canon" "$tk" "$sen")"; prog="$(_ckpt_progress "$cf")"
      # the checkpoint's terminal sentinel is ground truth - it overrides the Status cell
      ssent="$(_ckpt_sentinel "$cf")"
      case "$ssent" in DONE) stage=merged ;; FAILED) stage=error ;; PARTIAL) stage=blocked ;; esac
      case "$stage" in working) cw=$((cw+1));; review) cr=$((cr+1));; blocked|error) cb=$((cb+1));; merged) cm=$((cm+1));; esac
      IFS=$'\t' read -r glyph col < <(_stage_gc "$stage")
      prbadge=""; [ -n "$pr" ] && prbadge="  ${C_SEL}PR#${pr}${C_OFF}"
      progd=""; [ -n "$prog" ] && progd="  ${C_DIM}${prog}${C_OFF}"
      # wire: item <profile> <ckptfile> <pr> <canon> <sec> <DISPLAY>
      pbody="${pbody}$(printf 'item\t%s\t%s\t%s\t%s\t%s\t  %s%s%s %s%s  %s[%s]%s%s' \
        "$prof" "$cf" "$pr" "$canon" "$sec" "$col" "$glyph" "$C_OFF" "$title" "$prbadge" "$C_DIM" "$tk" "$C_OFF" "$progd")"$'\n'
    done < <(_sprint_items "$canon")
    # --- open questions (needs-you) ---
    local id p2 pr2 status2 kind q opt task ag col2 o tctx
    # US-delimited (tr) so an empty profile/task column does not collapse under `read`
    while IFS=$'\037' read -r id p2 pr2 status2 kind q opt task; do
      [ -z "$id" ] && continue
      cn=$((cn+1))
      if [ "$kind" = gate ] || [ "$kind" = approval ]; then ag="!"; col2="$C_INP"; else ag="?"; col2="$C_BOX"; fi
      o=""; [ -n "$opt" ] && o="  ${C_DIM}(${opt})${C_OFF}"
      tctx=""; [ -n "$task" ] && tctx="  ${C_DIM}task: ${task}${C_OFF}"
      # wire: ask <profile> <id> <options> <canon> <sec> <DISPLAY>
      pbody="${pbody}$(printf 'ask\t%s\t%s\t%s\t%s\t%s\t  %s%s%s %s%s%s' \
        "$prof" "$id" "$opt" "$canon" "$sec" "$col2" "$ag" "$C_OFF" "$q" "$tctx" "$o")"$'\n'
    done < <(agent-ask list "$canon" --pending 2>/dev/null | tr '\t' '\037')
    [ -n "$pbody" ] && body="${body}$(_subheader "$name" "$st" "$ver")"$'\n'"${pbody}"
  done < <(notes --profile "$prof" projects 2>/dev/null)
  # status header — always-on "where we are"
  printf 'head\t\t\t\t\t\t%s  where we are:%s  %s~%d working%s  %s?%d need-you%s  %s>%d review%s  %sx%d blocked%s  %s*%d done%s\n' \
    "$C_HEAD" "$C_OFF" "$C_INP" "$cw" "$C_OFF" "$C_BOX" "$cn" "$C_OFF" "$C_SEL" "$cr" "$C_OFF" "$C_INP" "$cb" "$C_OFF" "$C_DIM" "$cm" "$C_OFF"
  if [ -n "$body" ]; then printf '%s' "$body"
  else
    printf 'hint\t\t\t\t\t\t%s  nothing in flight — agents post work items + questions here as they run.%s\n' "$C_DIM" "$C_OFF"
    printf 'hint\t\t\t\t\t\t%s  enter opens/answers · C-a add work · a cycles views%s\n' "$C_DIM" "$C_OFF"
  fi
}

list_section() {
  local want="${1:-}"; [ -z "$want" ] && want="$(read_section)"
  case "$(read_mode)" in
    bridge) _bridge_view "$want"; return ;;
    agents) _profile_agents_view "$want"; _global_agents; return ;;
  esac
  local rows; rows="$(emit_tasks)"
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
answer_ask() { # $1=id $2=options(pipe)
  local id="$1" options="${2:-}" ans
  [ -n "$id" ] || return 0
  if [ -n "$options" ]; then
    ans="$(printf '%s\n' "${options//|/$'\n'}" | fzf --prompt="answer $id > " --height=40% --reverse)"
  else
    printf 'answer for %s: ' "$id" >&2; read -r ans
  fi
  [ -n "$ans" ] || return 0
  agent-ask answer "$id" "$ans" >/dev/null 2>&1
}

# enter dispatch: print the fzf action for the highlighted row (task or any agent row).
_enter_action() { # $1=type $2=profile $3=c3 $4=c4
  case "$1" in
    ask)      printf 'execute(%s --answer %q %q)+reload(%s --list)+refresh-preview' "$SELF" "$3" "$4" "$SELF" ;;
    item)     printf 'execute-silent(%s --open-file %q)+abort' "$SELF" "$3" ;;
    sess)     printf 'execute-silent(%s --resume-session %q)+abort' "$SELF" "$3" ;;
    sprint|sentinel) printf 'execute-silent(%s --open-file %q)+abort' "$SELF" "$3" ;;
    runner)   printf 'execute-silent(%s --journal %q)+abort' "$SELF" "$3" ;;
    task)     printf 'execute-silent(%s --jump task %q %q)+abort' "$SELF" "$3" "$4" ;;
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
      canon="$(canonical_of "$p" "$proj")"
      map+="$proj=$p"$'\n'          # vault name -> profile
      [ "$canon" != "$proj" ] && map+="$canon=$p"$'\n'  # canonical name -> profile
    done
  done < <(profiles)
  agent-ask list --all --pending 2>/dev/null | awk -F'\t' -v map="$map" '
    BEGIN { n=split(map, L, "\n"); for(i=1;i<=n;i++) if(split(L[i],kv,"=")==2) prof_of[kv[1]]=kv[2] }
    $1=="" { next }
    { p = ($3!="") ? $3 : prof_of[$2]; if (p!="") { c[p]++; t++ } }
    END { for (k in c) print k, c[k]; if (t) print "all", t }'
}

# ── the left sidebar rail: sections + counts, active marked ─────────
rail() {
  local cur ct at s n a badge
  cur="$(read_section)"
  ct="$(emit_tasks | awk -F'\t' '{ c[$2]++; t++ } END { for (k in c) print k, c[k]; print "all", t }')"
  at="$(attention_counts)"
  # view indicator: highlight the active of the three (a cycles them)
  local mode t_c a_c b_c; mode="$(read_mode)"
  t_c="$C_DIM"; a_c="$C_DIM"; b_c="$C_DIM"
  case "$mode" in tasks) t_c="$C_SEL" ;; agents) a_c="$C_SEL" ;; bridge) b_c="$C_SEL" ;; esac
  printf '%s SECTIONS%s   %stasks%s %s·%s %sagents%s %s·%s %sbridge%s %s(a)%s\n\n' \
    "$C_HEAD" "$C_OFF" "$t_c" "$C_OFF" "$C_DIM" "$C_OFF" "$a_c" "$C_OFF" \
    "$C_DIM" "$C_OFF" "$b_c" "$C_OFF" "$C_DIM" "$C_OFF"
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
# Toggle the `#ai` LANE on the highlighted task: hand it to the agents, or take it back.
# One list, two lanes — `/wave <app>` picks up exactly the `#ai` items and never touches
# the rest. Done in place with a line edit rather than a CLI verb because the notes CLI has
# no ptask tag/untag (focus has `mv --tag`, ptask never got one), and rm+add would lose the
# item's position and its `<!-- vk:ID -->` stamp.
toggle_ai() { # $1=file $2=line
  local file="${1:-}" line="${2:-}"
  [ -f "$file" ] || return 0
  [[ "$line" =~ ^[0-9]+$ ]] || return 0
  # The delimiters matter: a bare /#ai/ would also match `#aid`, and `\>` is a GNU-awk
  # extension this must not depend on.
  awk -v n="$line" '
    NR==n {
      if ($0 ~ /(^|[[:space:]])#ai([[:space:]]|$)/) {
        sub(/[[:space:]]*#ai([[:space:]]|$)/, " ")
      } else {
        $0 = $0 " #ai"
      }
      sub(/[[:space:]]+$/, "")
    }
    { print }
  ' "$file" > "$file.tmp$$" && mv "$file.tmp$$" "$file"
}

# Start a wave for the project the highlighted row belongs to, WITHOUT leaving the
# cockpit. Capture already lived here (C-a, C-t); starting was the one step that made you
# open a Claude session. `wave-start` backgrounds a headless pass that scopes the `#ai`
# lane into tickets, cuts the branch and writes the board as `Approval: PENDING` — then
# posts the approval as an ask you answer in the bridge (a a). It never delivers anything
# on its own; delivery-loop refuses to drain an unapproved board.
start_wave() { # $1=section (<profile>/<project>)
  local section="${1:-}" proj
  case "$section" in
    */*) proj="${section#*/}" ;;
    *)   echo "wave: highlight a PROJECT row (this is the '$section' lane)"; sleep 2; return 0 ;;
  esac
  command -v wave-start >/dev/null 2>&1 || { echo "wave: wave-start not on PATH"; sleep 2; return 0; }
  local n
  n="$(notes --profile "${section%%/*}" ptask "$proj" list 2>/dev/null | grep -cF '#ai' || true)"
  if [ "${n:-0}" -eq 0 ]; then
    echo "wave: no @ai tasks on ${proj}'s wave — press C-t on the ones you want the agents to do."
    sleep 3; return 0
  fi
  echo "starting a wave for ${proj} (${n} @ai task(s))…"
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
# sheet-model rollover; falls back to a version-note bump for legacy projects). After the
# freeze, generate an LLM summary block on the just-frozen note (best-effort — a gateway
# outage or missing config never fails the roll).
roll_project() { # $1 = section of the highlighted row (<profile>/<project>)
  local section="${1:-}" profile name cur lvl flag out frozen
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
  out="$(notes --profile "$profile" projects --roll "$name" $flag 2>&1)" \
    || { echo "$out"; echo "roll failed"; sleep 2; return 0; }
  echo "$out"
  # summarize the note that was just frozen (path is in the `(froze <path>)` line)
  frozen="$(sed -n 's/.*(froze \(.*\))$/\1/p' <<<"$out")"

  # The AGENT CHANGELOG: what the agents did for the version we just froze, appended to
  # the frozen note so it ships with the release rather than living only in the cockpit.
  #
  # The window runs from the PREVIOUS version's `rolled:` stamp up to now. `_version_start`
  # reads the newest versions/*.md, which at this point is the note just written - so the
  # window has to be taken from the note BEFORE it.
  if [ -n "$frozen" ] && command -v agent-usage >/dev/null 2>&1; then
    local canon prev since block
    canon="$(canonical_of "$profile" "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')")"
    prev="$(ls -1 "$(dirname "$frozen")"/*.md 2>/dev/null | sort -rV | sed -n 2p)"
    since=0
    if [ -n "$prev" ]; then
      since="$(sed -n 's/.*<!-- *rolled: *\([0-9]\{1,\}\).*/\1/p' "$prev" | head -1)"
      [ -n "$since" ] || since="$(stat -c %Y "$prev" 2>/dev/null || echo 0)"
    fi
    block="$(while IFS= read -r cn; do
               [ -n "$cn" ] && agent-usage changelog "$cn" --since "${since:-0}" 2>/dev/null
             done < <(_canon_list "$canon"))"
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
  # pin the project overview (summary.md — the "where we are / next up" index) at the very TOP,
  # above the version list. Enter opens it; C-s regenerates the overview (vs a version summary).
  local pinned="" all
  [ -n "$summary" ] && [ -f "$summary" ] && pinned="$(printf '= overview =\t%s' "$summary")"
  if [ -n "$pinned" ] && [ -n "$rows" ]; then all="$pinned"$'\n'"$rows"
  elif [ -n "$pinned" ]; then all="$pinned"
  else all="$rows"; fi
  if [ -z "$all" ]; then
    echo "nothing for $name yet — roll a version with V, or generate an overview"; sleep 1.5; exec "$SELF"
  fi
  if command -v bat >/dev/null 2>&1; then
    prev="bat --color=always --style=plain --language=markdown {2}"
  else
    prev="cat {2}"
  fi
  printf '%s\n' "$all" | fzf \
    --ansi --reverse --delimiter='\t' --with-nth=1 \
    --preview "$prev" --preview-window 'right:62%:wrap' \
    --prompt "$name > " \
    --header 'enter: nvim   C-d/C-u: scroll   C-s: (re)generate   q/esc: back' \
    --bind 'enter:execute(nvim {2})' --bind 'q:abort' \
    --bind 'ctrl-d:preview-half-page-down' \
    --bind 'ctrl-u:preview-half-page-up' \
    --bind "ctrl-s:execute(f={2}; if [ \"\$(basename \"\$f\" .md)\" = summary ]; then notes-version-summary --overview '$profile' '$name'; else notes-version-summary --force '$profile' '$name' \"\$f\"; fi)+refresh-preview"
  exec "$SELF" # versions fzf exited (q/esc) — relaunch the cockpit in the same window
}

# ── accept the overview's "Next up" suggestions (the `g` key) ────────
# Read the `- [ ]` tasks from a project's summary.md nextup:auto block, multi-select them, and for
# each accepted one: add it to the project sheet (ptask), then optionally file it as a tracker ticket.
nextup_tasks() { # $1 = summary.md path -> one suggested task per line (marker + checkbox stripped)
  awk '/<!-- nextup:auto -->/{s=1;next} /<!-- \/nextup:auto -->/{s=0} s' "$1" \
    | sed -n 's/^- \[ \] //p'
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
  summary_md="$(notes --profile "$profile" projects 2>/dev/null \
    | awk -F'\t' -v n="$name" 'tolower($1)==tolower(n){print $2; exit}')"
  [ -n "$summary_md" ] && [ -f "$summary_md" ] \
    || { echo "no summary.md for $name"; sleep 1.5; exec "$SELF"; }
  tasks="$(nextup_tasks "$summary_md")"
  if [ -z "$tasks" ]; then
    echo "no suggestions for $name yet — press o, then C-s on the overview to generate them"; sleep 2; exec "$SELF"
  fi
  selected="$(printf '%s\n' "$tasks" | fzf --multi --ansi --reverse \
    --prompt "accept for $name > " \
    --header 'TAB mark · enter accept selected · esc cancel')"
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
    K / J          previous / next section   (h / l also work)
    C-u / C-d      scroll the preview
    p              cycle priority filter  (urgent -> high -> low -> all)
    i              search  (esc leaves search)
    enter          edit the task in nvim

  task
    s              toggle in-progress  ( [ ] <-> [/] )
    C-x            mark done
    C-a            add a task to the section
    C-t            hand the task to the AI  (toggles the @ai lane)
    W              start a wave on this project's @ai tasks  (no session needed)
    d              delete the task  (asks first)
    u              undo the last delete
    m              move to another section / project

  project
    n              new project in this section
    V              roll to next version  (freezes + writes an LLM summary)
    o              overview + frozen versions  (top = where we are / next up · C-d/C-u scroll · C-s regen)
    g              accept "next up" suggestions -> sheet (+ optional ticket)
    A              archive the highlighted project
    R              restore an archived project

  waves  (hand a batch of work to the agents)
    1. C-t on each task you want the agents to do  ->  it shows @ai
    2. press  W  on the project row — that is the whole trigger.
         a headless agent turns every @ai task into a ticket, cuts ONE
         branch, and stops; the approval arrives as a question below
    3. come back here and press  a a  for the bridge view to watch it,
         and to answer questions it raises  (enter on a "?" row)
    4. it asks you once more before merging
    full runbook:  ~/.config/shared-hooks/WAVES.md

  other
    a              cycle views: tasks -> agents -> bridge -> tasks
                     tasks   your task lists
                     agents  who is working this project + what shipped this
                             version cost (tokens/$); V freezes it into the
                             version note as the agent changelog
                     bridge  open QUESTIONS agents raised on your tasks -
                             enter = answer (resumes the agent), C-a = add work
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
  --delete-task) shift; confirm_delete "$@"; exit 0 ;;
  --undo-delete) shift; undo_delete; exit 0 ;;
  --toggle-ai) shift; toggle_ai "$@"; exit 0 ;;
  --start-wave) shift; start_wave "${1:-}"; exit 0 ;;
  --move) shift; move_task "$@"; exit 0 ;;
  --jump) shift; jump_row "$@"; exit 0 ;;
  --cycle-pfilter) cycle_pfilter; exit 0 ;;
  --toggle-mode) toggle_mode; exit 0 ;;
  --enter-action) shift; _enter_action "$@"; exit 0 ;;
  --answer) shift; answer_ask "${1:-}" "${2:-}"; exit 0 ;;
  --resume-session) [ -n "${2:-}" ] && tmux new-window "sessions resume '$2'" 2>/dev/null; exit 0 ;;
  --open-file) [ -f "${2:-}" ] && tmux new-window "nvim '$2'" 2>/dev/null; exit 0 ;;
  --journal) [ -n "${2:-}" ] && tmux new-window "journalctl --user -u 'agentctl@$2.service' -e -n 200 || journalctl --user -u 'agentctl@$2.service'" 2>/dev/null; exit 0 ;;
  --new-project) new_project "${2:-}"; exit 0 ;;
  --roll-project) roll_project "${2:-}"; exit 0 ;;
  --browse-versions) browse_versions "${2:-}"; exit 0 ;;
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

echo personal > "$STATE" # every launch starts on personal
: > "$PFILTER"           # ...and unfiltered (priority filter cleared)
# ...in the tasks view (a cycles tasks -> agents -> bridge). NOTES_COCKPIT_MODE lets a
# caller pin the opening view, which is how the cockpit session's `bridge` window opens
# on the ask queue instead of making you press `a` twice every time it restarts.
printf '%s' "${NOTES_COCKPIT_MODE:-tasks}" > "$MODEF"
# modal nav: printable keys that mean "command" in normal mode but must TYPE while
# searching. `i` shows the input and unbinds them; leaving search (esc) rebinds them.
# `?` is intentionally NOT modal — it opens the help pager.
MODAL='j,k,h,l,i,q,s,m,n,V,o,p,g,a,A,R,T'

list_section personal | fzf \
  --ansi --reverse --cycle --no-sort --border --no-input --wrap \
  --delimiter=$'\t' --with-nth='7..' \
  --prompt='search > ' \
  --header='a views · enter open/answer · C-a add · C-t ai · ? keys' \
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
  --bind "ctrl-t:execute-silent($SELF --toggle-ai {3} {4})+reload($SELF --list)+refresh-preview" \
  --bind "W:execute($SELF --start-wave {6})+reload($SELF --list)+refresh-preview" \
  --bind "m:execute($SELF --move {6} {2} {5})+reload($SELF --list)+refresh-preview" \
  --bind "n:execute($SELF --new-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "V:execute($SELF --roll-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "o:become($SELF --browse-versions {6})" \
  --bind "g:become($SELF --accept-next {6})" \
  --bind "A:execute($SELF --archive-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "R:execute($SELF --restore-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "p:execute-silent($SELF --cycle-pfilter)+reload($SELF --list)+refresh-preview" \
  --bind "T:execute-silent(notes today --all)+reload($SELF --list)+refresh-preview" \
  --bind "a:execute-silent($SELF --toggle-mode)+reload($SELF --list)+refresh-preview" \
  --bind "enter:transform($SELF --enter-action {1} {2} {3} {4})"
