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
# board_list PROJECT -> every board for a project, one per line, NEWEST FIRST.
#
# NEWEST BY MTIME, never by name. A wave is a patch version, so boards are named
# both `sprint-2026-07-27.md` and `sprint-v1.10.1.md`; `sprint-2026-...` sorts after
# `sprint-v...` in some collations and before it in others, so sorting by name picks
# a different board depending on locale.
#
# This is the ONLY place the board glob is written. It used to appear in six: here,
# wave-session, wave-start, session-preflight, captain-watchdog and delivery-loop
# (twice). The glob is not the interesting part — `sprint-*.md` is easy to copy
# correctly — but every copy also re-decided, silently, what counts as a board and
# in what order. Adding an archive convention (`sprint-*.md.done`, a `stale/`
# subdirectory) then has to be found in six places, and the one that is missed does
# not error: it just keeps handing out a board everything else has stopped counting.
board_list() { # $1=project
  [ -n "${1:-}" ] || return 0
  # `|| true` because EVERY consumer of this library sets `pipefail` (wave-session.sh,
  # wave-start and notes-cockpit all open with `set -uo pipefail`). With pipefail a
  # project that simply has no board yet made `ls` exit 2 and took the whole pipeline's
  # status with it, so discovery reported FAILURE for the ordinary, expected case of
  # "nothing scheduled here". Empty output is the answer; a non-zero status is a lie that
  # any caller writing `board_newest x || die` would act on.
  ls -1t "${AGENT_PLANS_DIR:-$HOME/.agent/plans}/$1"/sprint-*.md 2>/dev/null || true
}

# board_newest PROJECT -> path of the newest board, or nothing.
board_newest() { # $1=project
  board_list "${1:-}" | head -1
}

# board_find PROJECT PREDICATE -> newest board satisfying PREDICATE, or nothing.
#
# PREDICATE is the NAME of a function taking a board path (board_needs_eyes,
# board_drainable, board_approved...). Every scheduled reader of the board wants
# exactly this — "the newest one that still matters to me" — and each had written
# out the same six-line loop with its own predicate inlined. captain-watchdog and
# delivery-loop even said so in a comment: "same contract as captain-watchdog's
# active_blackboard - now literally the same code, rather than 'kept in sync
# deliberately'." It was not the same code. Now it is.
#
# Returns 0 with empty output when nothing matches: "no board needs me" is the
# normal state of a quiet project, not a failure, and these run on timers where a
# non-zero status is noise.
board_find() { # $1=project $2=predicate fn
  local _f
  [ -n "${2:-}" ] || return 0
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    if "$2" "$_f"; then printf '%s\n' "$_f"; return 0; fi
  done < <(board_list "${1:-}")
  return 0
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

# THE mapping. One implementation, as awk source, used verbatim by both board_stage_of
# and board_rows.
#
# It used to be two: a shell `case` here and an awk `stage()` in board_rows, with a
# comment claiming they were "kept as one ordered case so the two can never disagree."
# They disagreed. The shell arm `*done*` is a SUBSTRING match, so the status "abandoned"
# classified as `merged` through board_stage_of and as `working` through board_rows --
# the same word, two readers, opposite answers, which is the exact failure this library
# was extracted to end. A rule written down twice is a rule that will diverge twice, and
# no amount of comment prevents it.
#
# awk (not the shell case) is the survivor because only it can express a word boundary:
# \<done\> matches "done" and not "abandoned". board_stage_of pays one subprocess per
# call for this; it has exactly one caller (wave-session's _is_live, once per row), so
# the cost is a rounding error against a class of silent misclassification.
_BOARD_STAGE_AWK='
# WHERE a verdict appears decides whether it is THIS row`s verdict.
#
# A status cell is prose, and prose mentions other things. A real row read
#   "1st run: IPA built OK but submit REJECTED - dup buildNumber 1.
#    FIX: PR #1008 bumped ->2 (merged). RE-RUN 29263920302 building 1.0.0(2)."
# and classified as `merged`, because `merged` was tested as a bare substring anywhere in
# the cell -- and this cell mentions a DIFFERENT PR having been merged, in the course of
# saying the row is still running. A live row read as terminal is the exact silent failure
# this library exists to end: delivery-loop skips it and the cockpit stops showing it,
# and "no open rows" is indistinguishable from "done".
#
# So the VERDICT rules (merged / skipped / review / queued) look only at LEAD, the text
# before the first sentence break. A cell states its verdict up front -- `MERGED (PR
# #1004, CI green)`, `**DONE — PR #1036 merged**`, `filed, not dispatched` -- and
# everything after the first `. ` is elaboration, which is where another PR`s fate,
# a retry, or a follow-up gets mentioned.
#
# ATTENTION (blocked / error) and the SENTINEL keep matching the WHOLE cell. Those are not
# elaboration: "blocked - PR #1036 merged, CI red" is BLOCKED no matter where the word
# sits, and `STATUS: DONE` is a controlled token an agent writes, not prose. Getting
# attention wrong strands a human; that asymmetry is deliberate and is why it is tested
# first.
function board_stage(s,  low, lead, i) {
  low=tolower(s)
  # `in-wave` is TERMINAL: the fix is squashed onto the wave branch and the work is done,
  # pending delivery. Tested before the generic fallthrough or it reads as `working` and
  # a finished row gets a tmux window it does not need.
  if (low ~ /in-wave/)                              return "merged"
  if (low ~ /reverted-from-wave/)                   return "queued"
  # ATTENTION is tested BEFORE terminal, deliberately. "blocked - PR #1036 merged, CI
  # red" is BLOCKED; the reverse order (which every earlier parser used) reads it as done
  # and the row stops asking for the human it needs.
  if (low ~ /blocked/)                              return "blocked"
  if (low ~ /error|failed/)                         return "error"
  # The sentinel: a controlled token, authoritative wherever it sits. board_rows appends
  # it to the status, so restricting it to LEAD would throw it away on any row whose
  # status runs past one sentence -- the rows most likely to have one.
  if (low ~ /status:? *done/)                       return "merged"
  i = index(low, ". ")
  lead = (i > 0) ? substr(low, 1, i - 1) : low
  if (lead ~ /merged|\<done\>/)                     return "merged"
  if (lead ~ /skipped/)                             return "skipped"
  if (lead ~ /pr[- ]?open|pr *#[0-9]|pull\/[0-9]|merge it|ready/) return "review"
  if (lead ~ /queued|filed|not dispatched|n\/a|returns/) return "queued"
  return "working"
}
'

_board_stage() {
  awk -v s="$1" "$_BOARD_STAGE_AWK"'BEGIN { printf "%s", board_stage(s) }' </dev/null
}

board_is_open()      { case "${1:-}" in queued|working|review) return 0 ;; *) return 1 ;; esac; }
board_is_attention() { case "${1:-}" in blocked|error)         return 0 ;; *) return 1 ;; esac; }

# The CLASSES a consumer may ask about. `eyes` (open OR attention) is a class in its
# own right rather than an `||` at each call site, because it is the one every
# human-facing surface actually wants and the one each surface got subtly wrong:
# session-preflight open-coded it as a five-way awk comparison on stage names, and
# captain-watchdog as `board_has_stage open || board_has_stage attention` — which
# parses the whole board twice, and silently stops agreeing the moment a sixth stage
# is added to one list and not the other.
#
# An unknown class returns 1 (no match) rather than erroring: a typo'd class must not
# take down a timer-driven daemon. It is caught in tests instead, where it is cheap.
board_in_class() { # $1=stage $2=class
  case "${2:-}" in
    open)      board_is_open      "${1:-}" ;;
    attention) board_is_attention "${1:-}" ;;
    eyes)      board_is_open "${1:-}" || board_is_attention "${1:-}" ;;
    *)         return 1 ;;
  esac
}

# ── the parser ───────────────────────────────────────────────────────────────
# board_rows FILE -> one record per queue row, US(\037)-delimited:
#     ticket \037 stage \037 title \037 pr \037 sentinel
# US rather than TAB because an empty pr/sentinel cell collapses under bash `read`
# when the delimiter is whitespace.
board_rows() { # $1=board file
  [ -f "${1:-}" ] || return 0
  awk -F'|' "$_BOARD_STAGE_AWK"'
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
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
      # Every lookup MUST be guarded. In awk an unset col[k] is "", and $("") is
      # $0 - so a board with no Title column emitted the ENTIRE RAW ROW as the
      # title rather than an empty string. `sprint-2026-07-12-time-tangle.md` is
      # headed `| # | Wave | Ticket | Branch | Agent | Status | Sentinel |` and did
      # exactly that. ticket/status are safe by construction (the header is only
      # accepted when both are present) but are guarded anyway so the next column
      # added here cannot reintroduce this.
      tk=(col["ticket"])?trim($(col["ticket"])):""
      st=(col["status"])?trim($(col["status"])):""
      ti=(col["title"])?trim($(col["title"])):""
      # No Title column at all (the `| # | Wave | Ticket | ... |` shape). Fall back to
      # the first non-empty cell that is not one of the structural columns, so the row
      # still says what it is about instead of rendering blank in the cockpit.
      if (ti=="") {
        for (j=2; j<=NF; j++) {
          if (j==col["ticket"] || j==col["status"] || j==col["sentinel"] || j==col["#"]) continue
          if (trim($j) != "" && trim($j) != "-") { ti=trim($j); break }
        }
      }
      sen=(col["sentinel"])?trim($(col["sentinel"])):""
      # A PROPOSED row has no ticket yet - the wave writes its stub board before the
      # approval gate so a gate stop leaves an artifact. Key it by row number so it
      # still renders; dropping these hid the whole proposal while a wave waited.
      if(tk=="" && ti!="" && col["#"]) tk="~" trim($(col["#"]))
      if(tk=="" || tolower(tk)=="ticket") next
      pr=""; if(match(st,/pull\/[0-9]+/)) pr=substr(st,RSTART+5,RLENGTH-5)
      else if(match(st,/#[0-9]+/)) pr=substr(st,RSTART+1,RLENGTH-1)
      printf "%s\037%s\037%s\037%s\037%s\n", tk, board_stage(st" "sen), ti, pr, sen
    }
  ' "$1"
}

# ── board-level predicates ───────────────────────────────────────────────────
board_approved() { grep -Eq "$BOARD_APPROVAL_RE" "${1:-/dev/null}" 2>/dev/null; }
board_started()  { grep -Eq '^- *Started: *[0-9]' "${1:-/dev/null}" 2>/dev/null; }

# board_is_wave FILE -> 0 if the board DECLARES wave mode in its `## Meta` block.
#
# Which driver a board gets is decided by this one test, and getting it wrong is
# silent both ways: a wave board handed to /kb:sprint is branched, PR'd and merged
# with no wave semantics at all, and a sprint board handed to /wave waits forever
# for a branch nobody cut.
#
# THE ANCHOR IS THE WHOLE POINT. `- Mode: wave:1` is a declaration; the same words
# inside a `## Run log` line ("refused: board is Mode: wave:1, needs /wave") are a
# description of one. An unanchored matcher cannot tell them apart, so a plain
# sprint board acquires wave mode the moment anything writes prose about a wave
# into its log — including this harness's own refusal messages, which is exactly
# the shape that makes it self-inflicted. `^- *` pins it to a Meta list item.
#
# Case-insensitive because the Meta block is hand-editable and `Mode: Wave` is the
# same declaration; the leading `- ` is not negotiable, the capital W is.
#
# It lives HERE rather than in delivery-loop (where it started) for the reason this
# whole file exists: it had two readers that did not agree. delivery-loop's was
# anchored, wave-overseer/SKILL.md told the model to run a bare `grep -q 'Mode:
# wave'`. All four wave boards on disk today declare it anchored, so the two have
# not yet split on a real board — this is a latent divergence being closed before
# it fires, not a post-mortem. Worth closing early precisely because the failure is
# a silent mode mismatch, which presents as "the timer fires and nothing moves".
board_is_wave() { grep -qiE '^- *Mode: *wave' "${1:-/dev/null}" 2>/dev/null; }

# board_has_stage FILE open|attention|eyes -> 0 if any row qualifies
board_has_stage() {
  local f="${1:-}" class="${2:-}" _t stage
  while IFS=$'\037' read -r _t stage _; do
    board_in_class "$stage" "$class" && return 0
  done < <(board_rows "$f")
  return 1
}

# board_count FILE open|attention|eyes -> how many rows qualify. Always prints a
# number, including 0, so a caller can use it unquoted in arithmetic.
board_count() {
  local f="${1:-}" class="${2:-}" _t stage n=0
  while IFS=$'\037' read -r _t stage _; do
    board_in_class "$stage" "$class" && n=$((n + 1))
  done < <(board_rows "$f")
  printf '%s\n' "$n"
}

# delivery-loop's predicate: approved AND work left. Fails closed on approval.
board_drainable() { board_approved "${1:-}" && board_has_stage "${1:-}" open; }

# captain-watchdog's predicate: deliberately NOT approval-gated, and it includes
# ATTENTION — a board whose every row is `blocked` is exactly when the watchdog must
# not self-disarm.
board_needs_eyes() { board_has_stage "${1:-}" eyes; }

# ── checkpoint sentinel ──────────────────────────────────────────────────────
# The dispatcher/overseer trust the SENTINEL, never an Agent "completed" event: a
# "completed" with no STATUS: DONE is a false-completion (the agent died mid-run).
board_sentinel_of() { # $1=checkpoint file -> DONE|FAILED|PARTIAL, or empty
  [ -f "${1:-}" ] || return 0
  # `|| true` for the same pipefail reason as board_newest: a checkpoint with no sentinel
  # yet is the normal in-progress case, and grep exiting 1 must not read as an error.
  grep -oE 'STATUS:? *(DONE|FAILED|PARTIAL)' "$1" 2>/dev/null | tail -1 | awk '{print $NF}' || true
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
