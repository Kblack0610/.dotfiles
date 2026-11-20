# shellcheck shell=bash
# This file is SOURCED, never executed. One reader for a plan's `## Phases` checklist, used by
# fleet-sessions (live sessions), ask-sweep (plans whose session has gone) and regen-anchor (Active plans).

# The one parse of the checklist: `- [x]` landed and `- [-]` deferred count as done, `- [ ]`
# does not. Only unindented items are phases; an indented item is a step inside one.
# mode=count prints "done \t total \t first unchecked"; mode=list prints "state \t name" per
# phase in file order, state one of done, deferred, open.
_PLAN_PHASES_AWK='
  /^## / { inp = ($0 ~ /^## Phases([[:space:]]|$)/); next }
  !inp { next }
  /^[-*] \[[xX-]\] / {
    d++; t++
    if (mode == "list") { n = $0; st = (n ~ /^[-*] \[-\] / ? "deferred" : "done")
      sub(/^[-*] \[[xX-]\] /, "", n); gsub(/\t/, " ", n); printf "%s\t%s\n", st, n }
    next
  }
  /^[-*] \[ \] / {
    t++; n = $0; sub(/^[-*] \[ \] /, "", n); gsub(/\t/, " ", n)
    if (mode == "list") printf "open\t%s\n", n
    if (nx == "") nx = n
  }
  END { if (mode == "count" && t) printf "%d\t%d\t%s\n", d, t, (nx == "" ? "-" : nx) }'

# plan_phases <plan file> -> "done \t total \t first unchecked". A missing file, no such
# section, or a section with no checklist lines prints "- \t - \t -".
plan_phases() {
  local out=""
  [ -f "$1" ] && out="$(awk -v mode=count "$_PLAN_PHASES_AWK" "$1")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else printf -- '-\t-\t-\n'; fi
}

# plan_superseded <plan file> -> succeeds when the first line under its `# ` title says `Superseded by`
# (global CLAUDE.md, Plan Lifecycle), in any case: its open phases are another plan's now.
plan_superseded() {
  [ -f "$1" ] && awk '!t { t = /^# /; next } /^[[:space:]]*$/ { next } { s = tolower($0) ~ /^[>*_ ]*superseded by/; exit } END { exit !s }' "$1"
}

# plan_open <plan file> -> succeeds while the plan is live work: a file, not superseded, and a phase still
# unchecked, or no checklist and no `## Results` yet (a single-change plan gets one when it lands). A
# pointer stub is judged as the plan it names (plan_pointer).
plan_open() {
  local f="$1" canon p
  IFS=$'\t' read -r canon _ < <(plan_pointer "$f") || true
  f="${canon:-$f}"
  [ -f "$f" ] && ! plan_superseded "$f" || return 1
  p=$(plan_phases "$f")
  case "$p" in
    -*) ! grep -qi '^## results' "$f" ;;
    *) awk -F'\t' '{ exit !($1 < $2) }' <<<"$p" ;;
  esac
}

# plan_phase_key <plan file> -> its checklist's phase names, one line each, without the PR numbers a
# landed tick appends (` (#2651)`, ` (o/r#5, #6)`), so a copy and the plan it was copied from have one
# key however far each is ticked; nothing for a plan with fewer than two phases, too little to tell
# two plans apart.
plan_phase_key() {
  [ -f "$1" ] || return 0
  awk -v mode=list "$_PLAN_PHASES_AWK" "$1" | cut -f2- \
    | sed -E 's/([[:space:]]*\([^()]*#[0-9]+[^()]*\))+[[:space:]]*$//' | awk '{ k[NR] = $0 } END { if (NR >= 2) for (i = 1; i <= NR; i++) print k[i] }'
}

# A jq def: does this queue item (agent-queue list --json) carry phases of plan $p? By file name,
# since a plan is read from ~/.claude*/plans/ and its cache in ~/.agent/plans/<project>/: its
# `plan:` field (agent-queue add --plan), or a task that names the plan's file (queued by hand).
# shellcheck disable=SC2016,SC2034  # literal jq; read by the scripts that source this file
PLAN_ITEMS_JQ='def names_plan($p): ($p | split("/") | last) as $b
  | (((.plan // "") | split("/") | last) == $b) or ((.task // "") | contains("/" + $b));'

# plan_gated_rows -> each open board row that waits on a gate (after/, at/, ask/, pr/, hold/, rbw/, nightly/), one
# queue-item-shaped JSON line ({slug: the row id, task: its brief}) for PLAN_ITEMS_JQ: agent-queue add --plan
# files a phase whose wait is not met on its row, its brief naming the plan, so the row holds that phase as
# a queued item did. Nothing when the board cannot be read. Why: the queue holds no gated work (ar-3121).
# [<board json>]: a `notes board --json` feed the caller already read, instead of reading it again.
plan_gated_rows() {
  { if [ $# -gt 0 ]; then printf '%s\n' "$1"; else notes board --json 2>/dev/null; fi; } | jq -c '.rows[]? | select(.state == "open")
    | select(any(.tags[]?; test("^(after|at|ask|pr|hold|rbw|nightly)/")))
    | {slug: .id, task: ((.details // []) | if type == "array" then join("\n") else tostring end)}' 2>/dev/null || true
}

# plan_pointer <plan file> -> "<canonical plan path> TAB <N>" when the file is a pointer stub, whose
# opening lines say `Phase N of <path>.md` (a phase plan agent-queue wrote into ~/.claude*/plans/),
# and that plan exists; else nothing. The queue items name the canonical plan, not the stub, and
# hold its phase numbers, so a stub's open phase is the canonical's phase N. 2026-11-14: three
# sessions with a stub read LANDED, next phase, while their phases were queue items.
plan_pointer() {
  [ -f "$1" ] || return 0
  local path n
  # A stub is short (agent-queue writes about ten lines); a longer plan that opens the same way is its own.
  [ "$(wc -l <"$1")" -le 40 ] || return 0
  IFS=$'\t' read -r n path < <(awk 'NR <= 8' "$1" | sed -nE '/^Phase ([0-9]+) of ((~|\/)[^(:]*\.md).*$/{s//\1\t\2/p;q;}')
  [ -n "${path:-}" ] || return 0
  path="${path/#\~/$HOME}"
  [ -f "$path" ] || return 0
  printf '%s\t%s\n' "$(realpath -q -- "$path" || printf '%s' "$path")" "$((10#$n))"
}

# plan_session_phases <plan file> -> plan_phase_list of the phases the session on this plan works: the
# file's own, or for a pointer stub only the canonical plan's phase N (the stub owns no checklist).
plan_session_phases() {
  local tgt n
  IFS=$'\t' read -r tgt n < <(plan_pointer "$1") || true
  if [ -z "${tgt:-}" ]; then plan_phase_list "$1"; return; fi
  plan_phase_list "$tgt" | jq -c --argjson n "$n" 'if $n < 1 then [] else [first(.[] | select(.n == $n)) // empty] end'
}

# plan_epic <plan file> -> the `<code>-<N>` of the plan's lowercase `epic:` line, or nothing.
plan_epic() { _epic_line epic "$1"; }

# The plan stores an epic's plans are read from, in order. The first file of a name wins, so a plan
# in ~/.claude/plans (the _live store) is read once; ~/.agent/plans adds the plans only a project holds.
: "${PLAN_DIRS:=$HOME/.claude/plans:$HOME/.claude-personal/plans:$HOME/.agent/plans}"

# epic_plans -> one JSON line per plan whose `epic:` line names an epic: {file, epic, phases}, from
# the colon-separated PLAN_DIRS (grep -r skips ~/.agent/plans' project links into _live).
# fleet-bench epics and fleet-dispatch take_epic both read an epic's plans here.
epic_plans() {
  local d f e seen=" " dirs
  IFS=: read -ra dirs <<<"$PLAN_DIRS"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      case "$seen" in *" ${f##*/} "*) continue ;; esac
      seen+="${f##*/} "
      e=$(plan_epic "$f"); [ -n "$e" ] || continue
      jq -cn --arg f "$f" --arg e "$e" --argjson ph "$(plan_phase_list "$f")" '{file: $f, epic: $e, phases: $ph}'
    done < <(grep -rl --include='*.md' '^epic:' "$d" 2>/dev/null | sort)
  done
}

# plan_rows <plan file> -> each `<code>-<N>` on the plan's lowercase `rows:` line, one a line: the
# open rows the plan answers (a request row like ucp-134), which agent-land closes once the plan's
# last phase lands, so the row the human filed closes with the work and not by hand.
plan_rows() {
  [ -f "$1" ] || return 0
  sed -nE '/^rows: *(.*)$/{s//\1/p;q;}' "$1" | tr -cs 'A-Za-z0-9-' '\n' | { grep -xiE '[a-z0-9]+-[0-9]+' || true; } | tr 'A-Z' 'a-z' | sort -u
}

# phase_takes <phase text> -> each board row the phase line says it takes (`takes ucp-2701`, `takes board
# row ucp-2701`, `takes row ucp-2701`), lowercase, one a line. The one reader of that marker: agent-queue
# add --plan ranks the phase by those rows, and agent-land closes them when the phase merges. A bare
# `takes <row-id>` in prose names no row (an id needs digits), so a plan that documents the marker is safe.
phase_takes() {
  printf '%s\n' "$1" | { grep -oiE '(^|[^a-z])takes (board )?(row )?[a-z]{2,4}-[0-9]+' || true; } |
    grep -oiE '[a-z]{2,4}-[0-9]+$' | tr 'A-Z' 'a-z' | awk '!seen[$0]++'
}

# plan_rows_add <plan file> <row id> -- put <row id> on the plan's `rows:` line, a new line under its
# `epic:` line (else its title, else the top) when it has none, so agent-land closes that row with
# the plan's last phase. A row already on it is left as is. Written in place, so a link stays a link.
plan_rows_add() {
  [ -f "$1" ] || return 1
  ! plan_rows "$1" | grep -qxF -- "$2" || return 0
  local out
  out="$(awk -v id="$2" -v has="$(grep -c '^rows:' "$1")" '
    has > 0 { if (!done && /^rows:/) { sub(/[[:space:]]*$/, ""); $0 = $0 " " id; done = 1 } print; next }
    { line[NR] = $0 }
    END {
      if (has > 0) exit
      for (i = 1; i <= NR && !at; i++) if (line[i] ~ /^epic:/) at = i
      for (i = 1; i <= NR && !at; i++) if (line[i] ~ /^# /) at = i
      if (!at) print "rows: " id
      for (i = 1; i <= NR; i++) { print line[i]; if (i == at) print "rows: " id }
    }' "$1")" || return 1
  printf '%s\n' "$out" > "$1"
}

# plan_row_task <plan file> -> the brief of the one board row `agent-queue add --plan` files when it
# may not queue (a dispatched session, a filer): the plan's absolute path in one fixed sentence,
# which fleet-dispatch's promote reads back (plan_row_plan) to file the plan's chain on that row.
plan_row_task() {
  printf "Run the open phases of the approved plan %s in order, one PR each, marking each done in the plan's ## Phases." "$1"
}

# plan_row_plan <text> -> the plan a plan row's brief names (plan_row_task), whether or not that file
# still exists (a caller that queues it checks); nothing for any other text.
plan_row_plan() {
  local re='(^|[[:space:]])Run the open phases of the approved plan (/.+\.md) in order, one PR each'
  [[ "$1" =~ $re ]] && printf '%s\n' "${BASH_REMATCH[2]}"
}

# brief_epic <brief file> -> the `<code>-<N>` of the brief's `Epic:` head line, or nothing.
brief_epic() { _epic_line Epic "$1"; }

# _epic_line <key> <file>: the one parse of an epic id after `<key>:`
_epic_line() {
  [ -f "$2" ] && sed -nE "/^$1: *([a-z0-9]+-[0-9]+)([^0-9].*)?\$/{s//\\1/p;q;}" "$2"
}

# plan_phase_list <plan file> -> one compact JSON array [{state, name, n}] in file order, [] when
# the file or its checklist is missing. `n` is the phase's number, the one numbering every reader
# of a phase shares (agent-queue's `phases:` and item slugs, fleet-sessions): the line's own
# `P<N>` label when it opens with one (`- [ ] P8 freellmapi ...`), else its place in the
# checklist. A plan that files P9 above P8 is numbered by its labels, never by position.
# A sub-phase line (`1b. ...`: a digit, a lowercase letter, a punctuation mark) is numbered by that
# label, a string ("1b"), and takes no place: the phases below it keep their numbers, so adding a 1b to a plan whose phases are
# queued shifts no item (lesson 2026-11-09, `phases: 6` read as the ticked "5").
plan_phase_list() {
  { [ -f "$1" ] && awk -v mode=list "$_PLAN_PHASES_AWK" "$1"; } \
    | jq -cRn '[inputs | split("\t") | {state: .[0], name: (.[1:] | join(" "))}]
      | reduce .[] as $p ({pos: 0, out: []};
          (($p.name | capture("^(?<l>[0-9]+[a-z])[.:)]") | .l) // null) as $sub
          | (($p.name | capture("^[Pp](?<l>[0-9]+)([^0-9A-Za-z]|$)") | .l | tonumber) // null) as $lab
          | if $sub != null then .out += [$p + {n: $sub}]
            else .pos += 1 | .out += [$p + {n: ($lab // .pos)}] end)
      | .out'
}

# The approved-plan ledger: one JSON line per approval, written only by the ExitPlanMode hook
# (plan-approved.sh). A session that lasts past PLAN_LEDGER_DAYS is not looked at again.
PLAN_LEDGER_DAYS=30
PLAN_QUIET_MIN=60   # a session restored after a reboot is back well inside this

# plans_orphaned -> one ledger line for each approved plan, its newest approval, that still has an
# open phase and is not superseded (plan_superseded) while no active queue item names it and its session
# is neither running nor recently written to. Fails when the sessions or the queue cannot be read: a
# blind pass acts on nothing.
plans_orphaned() {
  local ledger="${PLAN_LEDGER:-$HOME/.agent/plans/approved.jsonl}" live items line plan sid t
  [ -s "$ledger" ] || return 0
  live=$(agent-ask live-sessions 2>/dev/null) || return 1
  # The queue goes in by file: as an argument it passes ARG_MAX and jq dies before it looks.
  items=$(mktemp) || return 1
  if ! agent-queue list --json --state active >"$items" 2>/dev/null || ! jq empty "$items" 2>/dev/null; then
    rm -f "$items"; return 1
  fi
  while IFS= read -r line; do
    plan=$(jq -r .plan <<<"$line"); sid=$(jq -r .session <<<"$line")
    ! plan_superseded "$plan" && plan_phases "$plan" | awk -F'\t' '$1 != "-" && $1 < $2 { ok = 1 } END { exit !ok }' || continue
    t=$(find "$HOME"/.claude*/projects -maxdepth 2 -name "$sid.jsonl" -mmin "-$PLAN_QUIET_MIN" -print -quit 2>/dev/null)
    [ -n "$t" ] || printf '%s\n' "$line"
  done < <(jq -sc --arg live "$live" --slurpfile items "$items" \
    --argjson since "$(( $(date +%s) - PLAN_LEDGER_DAYS * 86400 ))" "$PLAN_ITEMS_JQ"'
    ($live | split("\n")) as $live
    | map(select(.epoch >= $since)) | group_by(.plan) | map(max_by(.epoch))[]
    | . as $l | select(($live | index($l.session) | not) and ($items | any(.[]; names_plan($l.plan)) | not))' "$ledger")
  rm -f "$items"
}
