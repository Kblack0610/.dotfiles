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
# View mode: `tasks` (default) | `agents`. `a` toggles. In agents mode the same sections
# + projects render, but each project's body is the AGENTS working it (asks/gates you can
# answer, live sessions, headless runner + sprint state) - joined to the project by its
# `<!-- canonical: NAME -->` marker. A global section shows sentinel + the agentctl runners.
MODEF="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}.mode"
read_mode() { cat "$MODEF" 2>/dev/null || echo tasks; }
toggle_mode() { [ "$(read_mode)" = agents ] && printf tasks > "$MODEF" || printf agents > "$MODEF"; }
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
PFILTER="${TMPDIR:-/tmp}/notes-cockpit-${UID:-$(id -u)}.pfilter"
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

# ══ AGENTS mode ═══════════════════════════════════════════════════════════════
# Same sections/projects, but each project's body is the AGENTS working it. The join
# from a vault project to its agent runtime state is the `<!-- canonical: NAME -->`
# marker (sessions.jsonl, sprint blackboards, ~/.agent/asks are all keyed by it).

# canonical_of <profile> <project-lc> -> canonical name, or the project name if unmarked.
canonical_of() {
  local prof="$1" proj="$2" path dir canon=""
  path="$(notes --profile "$prof" projects 2>/dev/null | awk -F'\t' -v p="$proj" 'tolower($1)==p{print $2; exit}')"
  if [ -n "$path" ]; then
    dir="$(dirname "$path")"
    canon="$(grep -rhoE '<!--[[:space:]]*canonical:[[:space:]]*[^ >]+' "$dir" 2>/dev/null \
      | head -1 | sed -E 's/.*canonical:[[:space:]]*//')"
  fi
  printf '%s' "${canon:-$proj}"
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

# agent rows for ONE project: asks/gates -> live/recent sessions -> sprint -> runner.
# Wire (7 cols, DISPLAY=col7): <type> <profile> <c3> <c4> <c5=canon> <c6=sec> <DISPLAY>
#   ask:    c3=id       c4=options   sess: c3=session_id
#   sprint: c3=bb-path                runner: c3=service
_project_agents() { # $1=profile $2=lc $3=canon $4=runnerCanon $5=runnerDetail
  local prof="$1" lc="$2" canon="$3" rcanon="$4" rdetail="$5" sec="$1/$2"
  # asks / gates
  command -v agent-ask >/dev/null 2>&1 && \
  agent-ask list "$canon" --pending 2>/dev/null | awk -F'\t' \
    -v prof="$prof" -v canon="$canon" -v sec="$sec" \
    -v cq="$C_BOX" -v cg="$C_INP" -v coff="$C_OFF" -v cd="$C_DIM" '
    $1=="" {next}
    { id=$1; kind=$5; q=$6; opt=$7
      g=(kind=="gate"||kind=="approval")?"!":"?"; col=(kind=="gate"||kind=="approval")?cg:cq
      o=(opt!="")?"  " cd "(" opt ")" coff:""
      printf "ask\t%s\t%s\t%s\t%s\t%s\t  %s%s%s %s%s\n", prof, id, opt, canon, sec, col, g, coff, q, o }'
  # live / recent sessions (registry, keyed by canonical)
  local sf="$HOME/.agent/sessions/$canon/sessions.jsonl"
  if command -v jq >/dev/null 2>&1 && [ -f "$sf" ]; then
    jq -rc 'select(.session_id) | [.session_id,(.updated|tostring),(.edits|tostring)] | @tsv' "$sf" 2>/dev/null \
      | sort -t"$(printf '\t')" -k2,2rn | head -3 \
      | awk -F'\t' -v prof="$prof" -v canon="$canon" -v sec="$sec" -v cs="$C_SEL" -v coff="$C_OFF" -v cd="$C_DIM" '
        { printf "sess\t%s\t%s\t\t%s\t%s\t  %s~%s session %s  %s%s edits%s\n",
                 prof, $1, canon, sec, cs, coff, substr($1,1,8), cd, $3, coff }'
  fi
  # sprint blackboard state
  local bb; bb="$(ls -1t "$HOME/.agent/plans/$canon"/sprint-*.md 2>/dev/null | head -1)"
  if [ -n "$bb" ]; then
    local nblock; nblock="$(awk '/^## Blocks/{f=1;next}/^## /{f=0}f&&/[^[:space:]]/{c++}END{print c+0}' "$bb")"
    local extra=""; [ "${nblock:-0}" -gt 0 ] 2>/dev/null && extra=" ${C_INP}${nblock} blocked${C_OFF}"
    printf 'sprint\t%s\t%s\t\t%s\t%s\t  %s* sprint%s %s%s%s%s\n' \
      "$prof" "$bb" "$canon" "$sec" "$C_PROJ" "$C_OFF" "$C_DIM" "$(basename "$bb" .md)" "$C_OFF" "$extra"
  fi
  # headless runner working THIS project right now
  if [ -n "$rdetail" ] && [ "$rcanon" = "$canon" ]; then
    printf 'runner\tdelivery-loop\tdelivery-loop\t\t%s\t%s\t  %srunner%s working: %s%s%s\n' \
      "$canon" "$sec" "$C_INP" "$C_OFF" "$C_DIM" "$rdetail" "$C_OFF"
  fi
}

# One profile's AGENTS view: a group per project with its agent rows (or "- idle").
_profile_agents_view() { # $1=profile
  local prof="$1" name st ver lc canon body rline rcanon rdetail
  rline="$(_runner_line)"
  if printf '%s' "$rline" | grep -q "$(printf '\t')"; then
    rcanon="${rline%%$'\t'*}"; rdetail="${rline#*$'\t'}"
  else rcanon=""; rdetail=""; fi
  notes --profile "$prof" projects 2>/dev/null | while IFS=$'\t' read -r name _sum st ver; do
    [ -z "$name" ] && continue
    lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    canon="$(canonical_of "$prof" "$lc")"
    _subheader "$name" "$st" "$ver"
    body="$(_project_agents "$prof" "$lc" "$canon" "$rcanon" "$rdetail")"
    if [ -n "$body" ]; then printf '%s\n' "$body"
    else printf 'hint\t\t\t\t\t\t%s  - idle%s\n' "$C_DIM" "$C_OFF"; fi
  done
}

# The GLOBAL section (agents mode, once at the bottom): sentinel trips + agentctl runners.
_global_agents() {
  printf 'head\t\t\t\t\t\t%s── global · sentinel + runners ──%s\n' "$C_HEAD" "$C_OFF"
  local f name status any=0
  for f in "$HOME/.local/state/watch-companion"/*.state; do
    [ -f "$f" ] || continue
    status="$(cat "$f" 2>/dev/null)"; name="$(basename "$f" .state)"
    case "$status" in
      TRIP|ERROR) any=1
        printf 'sentinel\t\t%s\t\t\t\t  %s* %s%s %s%s\n' \
          "$HOME/.agent/watches/$name.yaml" "$C_INP" "$name" "$C_OFF" "$C_DIM$status$C_OFF" "" ;;
    esac
  done
  [ "$any" -eq 0 ] && printf 'hint\t\t\t\t\t\t%s  sentinel: all watches OK%s\n' "$C_DIM" "$C_OFF"
  local svc state glyph
  for svc in sentinel delivery-loop comms dream lab-sync nightly-sync project-index; do
    state="$(systemctl --user is-active "agentctl@$svc.service" 2>/dev/null)"; state="${state:-unknown}"
    [ "$state" = active ] && glyph="${C_SEL}o${C_OFF}" || glyph="${C_DIM}.${C_OFF}"
    printf 'runner\t\t%s\t\t\t\t  %s %srunner %s %s%s\n' \
      "$svc" "$glyph" "$C_DIM" "$svc" "$state" "$C_OFF"
  done
}

list_section() {
  local want="${1:-}"; [ -z "$want" ] && want="$(read_section)"
  if [ "$(read_mode)" = agents ]; then
    _profile_agents_view "$want"
    _global_agents
    return
  fi
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
  local mode; mode="$(read_mode)"
  if [ "$mode" = agents ]; then
    printf '%s SECTIONS%s   %sAGENTS%s %s(a)%s\n\n' "$C_HEAD" "$C_OFF" "$C_SEL" "$C_OFF" "$C_DIM" "$C_OFF"
  else
    printf '%s SECTIONS%s   %stasks%s %s(a agents)%s\n\n' "$C_HEAD" "$C_OFF" "$C_DIM" "$C_OFF" "$C_DIM" "$C_OFF"
  fi
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
    h / l          previous / next section
    p              cycle priority filter  (urgent -> high -> low -> all)
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
    V              roll to next version  (freezes + writes an LLM summary)
    o              overview + frozen versions  (top = where we are / next up · C-d/C-u scroll · C-s regen)
    g              accept "next up" suggestions -> sheet (+ optional ticket)
    A              archive the highlighted project
    R              restore an archived project

  other
    a              toggle AGENTS view  (per project: asks/gates you answer, live
                   sessions, sprint + runner state; !N badge = pending asks)
                   in AGENTS view: enter answers an ask / jumps a session / opens sprint
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

command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }
command -v notes >/dev/null 2>&1 || { echo "notes CLI not found (build ~/.dotfiles/.local/src/notes-cli)"; exit 1; }

# Bootstrap today's note for every profile so a fresh day never shows spurious zeros
# (the daily note is per-profile and `focus --all` only reads notes that exist).
# Idempotent — a no-op once today's notes are present.
notes today --all >/dev/null 2>&1 || true

echo personal > "$STATE" # every launch starts on personal
: > "$PFILTER"           # ...and unfiltered (priority filter cleared)
printf tasks > "$MODEF"  # ...in the tasks view (a toggles to agents)
# modal nav: printable keys that mean "command" in normal mode but must TYPE while
# searching. `i` shows the input and unbinds them; leaving search (esc) rebinds them.
# `?` is intentionally NOT modal — it opens the help pager.
MODAL='j,k,h,l,i,q,s,m,n,V,o,p,g,a,A,R,T'

list_section personal | fzf \
  --ansi --reverse --cycle --no-sort --border --no-input --wrap \
  --delimiter=$'\t' --with-nth='7..' \
  --prompt='search > ' \
  --header='a tasks/agents · enter open · ? keys' \
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
  --bind "g:become($SELF --accept-next {6})" \
  --bind "A:execute($SELF --archive-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "R:execute($SELF --restore-project {6})+reload($SELF --list)+refresh-preview" \
  --bind "p:execute-silent($SELF --cycle-pfilter)+reload($SELF --list)+refresh-preview" \
  --bind "T:execute-silent(notes today --all)+reload($SELF --list)+refresh-preview" \
  --bind "a:execute-silent($SELF --toggle-mode)+reload($SELF --list)+refresh-preview" \
  --bind "enter:transform($SELF --enter-action {1} {2} {3} {4})"
