# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# agent-board.sh — ONE reader for the sprint blackboard.
#
# The board at ~/.agent/plans/{project}/sprint-*.md is the handoff between a wave
# or /kb:sprint and everything that watches it. Five consumers read it and, until
# this file, each parsed it its own way:
#
#   notes-cockpit.sh   _sprint_items    the good one — header keyed by NAME
#   wave-session.sh    rows_of          header keyed by a literal `#` first column,
#                                       so `| Ticket | P | Title | ... |` read ZERO rows
#   delivery-loop      a single regex   grep for `queued|in-progress|pr-open` anywhere in a
#   captain-watchdog   (same regex)     pipe row — three of five real boards contain none of
#                                       those words, so both daemons were blind to them
#   wave-start         board glob only  (finds the file; does not parse it)
#
# Divergence here is expensive in a specific way: a board the daemons cannot see is
# not an error, it is SILENCE. delivery-loop reports "no active queue" and stops,
# which is exactly what it reports when there is genuinely nothing to do.
#
# The parser is the one from notes-cockpit.sh, extracted after two bugs were fixed
# in it (#159) that the other parsers still have:
#
#   * A new H2 ENDS the table. Without it the column map latched on the first
#     ticket+status header and every later pipe table in the file was read with the
#     queue's indices — the wave schema's `## Wave gate` table rendered as six
#     phantom "working" items, one of which was its own header row.
#   * A row whose Ticket cell is EMPTY still renders, keyed `~<row>`. A wave writes
#     its stub board BEFORE the approval gate, deliberately, so a gate stop leaves a
#     durable artifact — which means every row legitimately has an empty Ticket until
#     the human approves. Skipping them hid the entire proposal at exactly the moment
#     the human needed to read it.
#
# Precedent for a public lib sourced by private binaries: .local/lib/agent-proof.sh.
# They are siblings at runtime (~/.local/lib/), not in their source trees.

# ── the approval marker ──────────────────────────────────────────────────────
# The one machine-checkable token saying a human approved this board for autonomous
# delivery. Written by the human at the plan gate, never by an agent. Documented in
# .claude/commands/kb/sprint.md ("The approval gate") and wave.md.
#
# Two readers, asymmetric ON PURPOSE:
#   delivery-loop   fails closed — no marker, no drain. It merges code unattended.
#   captain-watchdog does NOT filter on it — an unapproved board is precisely what a
#                   human wants surfaced, and gating would self-disarm the watchdog
#                   on the boards that most need eyes.
BOARD_APPROVAL_RE='^- *Approval: *APPROVED-FOR-AUTONOMOUS-DELIVERY *$'

# ── board discovery ──────────────────────────────────────────────────────────
# board_newest PROJECT -> path of the newest board, or nothing.
#
# NEWEST BY MTIME, never by name. A wave is a patch version, so boards are named
# both `sprint-2026-07-27.md` and `sprint-v1.10.1.md`; `sprint-2026-...` sorts after
# `sprint-v...` in some collations and before it in others, so sorting by name picks
# a different board depending on locale.
board_newest() { # $1=project
  [ -n "${1:-}" ] || return 0
  ls -1t "${AGENT_PLANS_DIR:-$HOME/.agent/plans}/$1"/sprint-*.md 2>/dev/null | head -1
}

# ── stage vocabulary ─────────────────────────────────────────────────────────
#   queued  working  review        -> OPEN, there is work left
#   blocked error                  -> ATTENTION, a human is needed
#   merged  skipped                -> TERMINAL
# Consumers branch on the STAGE and never on raw cell text; that is the whole point
# of having one reader.
board_stage_of() { # $1=status text [$2=sentinel text] -> stage
  _board_stage "$(printf '%s %s' "${1:-}" "${2:-}")"
}

# The single source of the mapping, shared by board_stage_of and the awk in
# board_rows. Kept as one ordered case so the two can never disagree.
_board_stage() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    # `in-wave` is TERMINAL: the fix is squashed onto the wave branch and the work is
    # done, pending delivery. It must be tested before the generic fallthrough or it
    # reads as `working` and a finished row gets a tmux window it does not need.
    *in-wave*)                                       printf 'merged' ;;
    *reverted-from-wave*)                            printf 'queued' ;;
    # ATTENTION is tested BEFORE terminal, deliberately. "blocked - PR #1036 merged,
    # CI red" is BLOCKED; the reverse order (which every earlier parser used) reads it
    # as done and the row stops asking for the human it needs.
    *blocked*)                                       printf 'blocked' ;;
    *error*|*failed*)                                printf 'error' ;;
    *merged*|*"status: done"*|*done*)                printf 'merged' ;;
    *skipped*)                                       printf 'skipped' ;;
    *pr-open*|*"pr open"*|*"pr #"*|*pull/*|*"merge it"*|*ready*) printf 'review' ;;
    *queued*|*filed*|*"not dispatched"*|*n/a*|*returns*) printf 'queued' ;;
    *)                                               printf 'working' ;;
  esac
}

board_is_open()      { case "${1:-}" in queued|working|review) return 0 ;; *) return 1 ;; esac; }
board_is_attention() { case "${1:-}" in blocked|error)         return 0 ;; *) return 1 ;; esac; }

# ── the parser ───────────────────────────────────────────────────────────────
# board_rows FILE -> one record per queue row, US(\037)-delimited:
#     ticket \037 stage \037 title \037 pr \037 sentinel
# US rather than TAB because an empty pr/sentinel cell collapses under bash `read`
# when the delimiter is whitespace.
board_rows() { # $1=board file
  [ -f "${1:-}" ] || return 0
  awk -F'|' '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    function stage(s,  low) {
      low=tolower(s)
      if (low ~ /in-wave/)                              return "merged"
      if (low ~ /reverted-from-wave/)                   return "queued"
      # ATTENTION before terminal - see the note in _board_stage.
      if (low ~ /blocked/)                              return "blocked"
      if (low ~ /error|failed/)                         return "error"
      if (low ~ /merged|status:? *done|\<done\>/)       return "merged"
      if (low ~ /skipped/)                              return "skipped"
      if (low ~ /pr[- ]?open|pr *#[0-9]|pull\/[0-9]|merge it|ready/) return "review"
      if (low ~ /queued|filed|not dispatched|n\/a|returns/) return "queued"
      return "working"
    }
    # A new H2 ends the table. See the header note: without this the column map
    # latches on the first ticket+status header and every later pipe table in the
    # file is parsed with the queue`s indices.
    /^## / { cols=0; next }
    !cols && /\|/ && (tolower($0) ~ /ticket/ && tolower($0) ~ /status/) {
      for(i=2;i<=NF;i++){ h=tolower(trim($i)); if(h!="") col[h]=i }
      cols=1; next
    }
    /^\|[ ]*:?-+/ { next }
    cols && /^\|/ {
      tk=trim($(col["ticket"])); st=trim($(col["status"])); ti=trim($(col["title"]))
      sen=(col["sentinel"])?trim($(col["sentinel"])):""
      # A PROPOSED row has no ticket yet - the wave writes its stub board before the
      # approval gate so a gate stop leaves an artifact. Key it by row number so it
      # still renders; dropping these hid the whole proposal while a wave waited.
      if(tk=="" && ti!="" && col["#"]) tk="~" trim($(col["#"]))
      if(tk=="" || tolower(tk)=="ticket") next
      pr=""; if(match(st,/pull\/[0-9]+/)) pr=substr(st,RSTART+5,RLENGTH-5)
      else if(match(st,/#[0-9]+/)) pr=substr(st,RSTART+1,RLENGTH-1)
      printf "%s\037%s\037%s\037%s\037%s\n", tk, stage(st" "sen), ti, pr, sen
    }
  ' "$1"
}

# ── board-level predicates ───────────────────────────────────────────────────
board_approved() { grep -Eq "$BOARD_APPROVAL_RE" "${1:-/dev/null}" 2>/dev/null; }
board_started()  { grep -Eq '^- *Started: *[0-9]' "${1:-/dev/null}" 2>/dev/null; }

# board_has_stage FILE open|attention -> 0 if any row qualifies
board_has_stage() {
  local f="${1:-}" class="${2:-}" _t stage
  while IFS=$'\037' read -r _t stage _; do
    case "$class" in
      open)      board_is_open      "$stage" && return 0 ;;
      attention) board_is_attention "$stage" && return 0 ;;
    esac
  done < <(board_rows "$f")
  return 1
}

# delivery-loop's predicate: approved AND work left. Fails closed on approval.
board_drainable() { board_approved "${1:-}" && board_has_stage "${1:-}" open; }

# captain-watchdog's predicate: deliberately NOT approval-gated, and it includes
# ATTENTION — a board whose every row is `blocked` is exactly when the watchdog must
# not self-disarm.
board_needs_eyes() { board_has_stage "${1:-}" open || board_has_stage "${1:-}" attention; }

# ── checkpoint sentinel ──────────────────────────────────────────────────────
# The dispatcher/overseer trust the SENTINEL, never an Agent "completed" event: a
# "completed" with no STATUS: DONE is a false-completion (the agent died mid-run).
board_sentinel_of() { # $1=checkpoint file -> DONE|FAILED|PARTIAL, or empty
  [ -f "${1:-}" ] || return 0
  grep -oE 'STATUS:? *(DONE|FAILED|PARTIAL)' "$1" 2>/dev/null | tail -1 | awk '{print $NF}'
}

# board_checkpoint_of PROJECT TICKET [SENTINEL_HINT] -> path or empty
board_checkpoint_of() {
  local d="${AGENT_PLANS_DIR:-$HOME/.agent/plans}/${1:-}/checkpoints" base
  case "${3:-}" in
    *checkpoints/*) base="$(printf '%s' "$3" | sed -E 's#.*checkpoints/##; s/\.md.*//; s/[ `]//g')"
      [ -f "$d/$base.md" ] && { printf '%s' "$d/$base.md"; return; } ;;
  esac
  [ -f "$d/${2:-}.md" ] && { printf '%s' "$d/${2:-}.md"; return; }
  local first="${2%% *}"; [ -f "$d/$first.md" ] && printf '%s' "$d/$first.md"
}
