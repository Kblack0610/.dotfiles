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

# ── the EFFECTIVE stage ──────────────────────────────────────────────────────
# board_rows_effective FILE PROJECT -> same five fields as board_rows, but with the
# stage a human actually sees.
#
# board_rows reads the Status CELL. The cockpit then overrides it with the checkpoint's
# terminal sentinel, because that sentinel is ground truth: the dispatcher and overseer
# trust `STATUS: DONE` over an Agent "completed" event, since a completed with no
# sentinel is an agent that died mid-run (see board_sentinel_of). That override lived
# inline in _bridge_view, which meant the EFFECTIVE stage — the composition of the two —
# existed only inside one renderer.
#
# That is the exact shape this library was extracted to end. A second consumer (the
# transition observer) computing stage from board_rows alone would record `working` for
# a row the cockpit renders as `merged`, and the two would disagree forever without
# either being obviously wrong. So the composition moves here, and both call it.
#
# PROJECT is required to locate the checkpoints; with none, this degrades to board_rows.
board_rows_effective() { # $1=board file $2=project
  local f="${1:-}" proj="${2:-}" tk stage title pr sen cf ssent
  [ -f "$f" ] || return 0
  if [ -z "$proj" ]; then board_rows "$f"; return 0; fi
  while IFS=$'\037' read -r tk stage title pr sen; do
    [ -n "$tk" ] || continue
    cf="$(board_checkpoint_of "$proj" "$tk" "$sen")"
    if [ -n "$cf" ]; then
      ssent="$(board_sentinel_of "$cf")"
      case "$ssent" in
        DONE)    stage=merged ;;
        FAILED)  stage=error ;;
        PARTIAL) stage=blocked ;;
      esac
    fi
    printf '%s\037%s\037%s\037%s\037%s\n' "$tk" "$stage" "$title" "$pr" "$sen"
  done < <(board_rows "$f")
}

# ── stage history ────────────────────────────────────────────────────────────
# board_observe FILE — record every stage transition since the last look.
#
# WHY AN OBSERVER AND NOT A WRITER. A row's Status cell is edited by an LLM agent
# (the /wave dispatcher, kb-coordinator, wave-overseer) doing Edit on markdown, and
# the edit OVERWRITES the previous value — so the board holds a current stage and no
# history at all. The obvious fix is a `board_set_status` writer the dispatchers call
# instead of editing. That fix is the one this file's header already warns about: it
# puts the rule in a second place (the prompt) that has to agree with the first, and
# the five parsers this library replaced all drifted exactly that way. A dispatcher
# that forgets to call the writer does not error, it just silently records nothing.
#
# So nothing is asked of the agents. This diffs `board_rows` against what it saw last
# time and writes down what changed. It is correct no matter who edited the board or
# how — including a human with an editor, a sed one-liner, or a future dispatcher that
# has never heard of it.
#
# IDEMPOTENT BY CONSTRUCTION, because it is called from more than one place (a
# PostToolUse hook on the real edit, plus opportunistically from render paths and the
# 12-minute timers as a safety net for edits made outside Claude Code). Calling it
# twice in a row emits nothing the second time; two callers racing are serialised by
# flock below. "No change" costs one board parse and no write at all.
#
# RESOLUTION IS BOUNDED BY OBSERVATION. If nothing looks between two transitions, the
# net change is what gets recorded, not the intermediate. queued->working->review with
# no look in between lands as a single queued->review event. This is a real limit and
# is why the primary caller is an edit hook rather than a timer.
#
# Emits nothing and returns 0 for a missing/unparseable board: a project with no board
# is the normal quiet case, and this runs on hook and timer paths where a non-zero
# status is noise.
# board_project_of FILE -> the project a board belongs to, from its PATH.
#
# From the path and never from $PWD or resolve_project_name: `.claude/worktrees/agent-*`
# checkouts exist, and an agent editing a board from a worktree would otherwise file the
# event under the worktree's name. `~/.agent/plans/<project>/sprint-*.md` already encodes
# the answer unambiguously.
board_project_of() { # $1=board file
  local d; d="$(dirname "${1:-}")"
  printf '%s' "${d##*/}"
}

# Where the derived snapshot lives. NOT beside the board, deliberately.
#
# ~/.agent is `git add .`-committed every 15 minutes and synced between machines. An
# append-only log is the best possible shape for that; a file REWRITTEN on every
# observation is the worst — it conflicts on every divergence, and git-sync-agent.sh
# resolves conflicts with `git checkout --theirs .`, which would silently pick one
# machine's cache and drop the other. The snapshot is a pure derived cache (replaying
# the event log rebuilds it), so it belongs in machine-local state, next to the other
# agentctl runtime state, and is allowed to differ per machine.
_board_state_dir() {
  printf '%s' "${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}/board"
}

# board_events_file PROJECT -> the append-only transition log for a project.
#
# PER-PROJECT, not per-board, for two reasons. A ticket outlives a board: row 639 appears
# on both sprint-2026-07-28.md and sprint-v1.11.1.md ("absorbed", per the Run log), and
# the factory view groups by work item, so a per-board log would split one item's history
# in two. And the name deliberately does NOT start with `sprint-`: board_list's glob is
# the one definition of "a board", and a sibling matching it is a trap for whoever widens
# that glob next (see the archive-convention warning on board_list).
board_events_file() { # $1=project
  printf '%s/%s/board-events.jsonl' "${AGENT_PLANS_DIR:-$HOME/.agent/plans}" "${1:-}"
}

board_observe() { # $1=board file -> appends to board_events_file(project)
  local f="${1:-}"
  [ -f "$f" ] || return 0
  command -v flock >/dev/null 2>&1 || return 0

  # Separate `local` statements, not one. `local a=x b="$a"` expands the WHOLE command
  # line before the builtin assigns anything, so `$b` sees the OLD (here unset) `a` —
  # which under the `set -u` every consumer of this library sets is a hard error, not a
  # quietly empty string.
  local proj; proj="$(board_project_of "$f")"
  [ -n "$proj" ] || return 0
  local ev;   ev="$(board_events_file "$proj")"
  local sdir; sdir="$(_board_state_dir)"
  local snap; snap="$sdir/${proj}.snapshot"
  local board; board="$(basename "$f")"

  mkdir -p "$sdir" "$(dirname "$ev")" 2>/dev/null || return 0

  # The whole read-modify-write is one critical section. Without it two callers both read
  # the old snapshot, both decide the same transition is new, and both append it — and a
  # duplicate event is indistinguishable from a row that genuinely bounced between two
  # stages. This is not hypothetical: agentctl-delivery-loop, -wave-watchdog and
  # -captain-watchdog are all `OnCalendar=*:0/12` with no RandomizedDelaySec, so they fire
  # on the same wall-clock second every time.
  #
  # NOTE: this is the first use of flock in this repo (only vendored bats had one), hence
  # the availability check above rather than assuming it. The lock is a dedicated file, not
  # the snapshot, because the snapshot is replaced by rename. Bounded wait because a hook
  # sits on the Edit path: on timeout we return 0 and let the next timer catch it, since a
  # late event beats a stalled editor.
  local lock="$sdir/${proj}.lock"
  exec {_bo_fd}>>"$lock" 2>/dev/null || return 0
  flock -w 2 "$_bo_fd" 2>/dev/null || { exec {_bo_fd}>&-; return 0; }

  local now epoch seeded=0 host src rc=0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"
  host="${HOSTNAME:-$(uname -n 2>/dev/null)}"
  src="${BOARD_OBSERVE_SRC:-observe}"
  [ -f "$snap" ] || seeded=1

  # In the SNAPSHOT's directory so the mv below is an atomic same-filesystem rename: a
  # concurrent reader must never see a half-written cache.
  local tmp; tmp="$(mktemp "${snap}.XXXXXX" 2>/dev/null)" || { exec {_bo_fd}>&-; return 0; }

  # The diff is one awk pass, so a board of any size costs one subprocess.
  #
  # Keyed on TICKET, never on row number. The queue is re-ordered in practice (the real
  # v1.11.1 board runs 1,2,3,4,9,5,6,7,8) and a proposed row is keyed `~<rownum>` until the
  # gate fills its ticket in, so a row-keyed differ would report a rename as delete+create.
  # `row` rides along as metadata only.
  #
  # SEEDING. First sight of a project writes one row per ticket with an EMPTY `from`,
  # marked `"src":"seed"`. A board that predates this code must not have a history
  # invented for it: a seed row says "this is where it already was when I first looked",
  # which is true. A synthesised queued->merged chain would be a fabrication, and would
  # date a three-week-old merge to today. Renderers must never compute a dwell time from
  # a seed row.
  #
  # LINE LENGTH IS A CORRECTNESS PROPERTY, not tidiness: an O_APPEND write under PIPE_BUF
  # (4096) is atomic on Linux, which is what keeps a lost lock degrading to duplicate
  # events rather than interleaved corrupt ones. Hence the truncated title and no raw
  # status cell.
  board_rows_effective "$f" "$proj" | awk -F'\037' \
      -v snap="$snap" -v ev="$ev" -v now="$now" -v epoch="$epoch" -v seeded="$seeded" \
      -v tmp="$tmp" -v host="$host" -v board="$board" -v src="$src" '
    function jesc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/[\t\r\n]/," ",s); return s }
    BEGIN {
      while ((getline line < snap) > 0) {
        n = index(line, "\037")
        if (n > 0) prev[substr(line, 1, n-1)] = substr(line, n+1)
      }
      close(snap)
    }
    { cur[$1]=$2; title[$1]=$3; prnum[$1]=$4 }
    END {
      for (tk in cur) {
        from = (tk in prev) ? prev[tk] : ""
        # Never emit from == to. board_stage() reads `blocked` and `error|failed` against
        # the WHOLE status cell (deliberately), so a watchdog appending prose like
        # "confirmed not blocked" re-classifies a row; suppressing the no-op is the only
        # thing standing between that and a stream of phantom transitions.
        if (from == cur[tk]) continue
        printf "{\"ts\":\"%s\",\"epoch\":%s,\"ticket\":\"%s\",\"from\":\"%s\",\"to\":\"%s\",\"pr\":\"%s\",\"title\":\"%.60s\",\"board\":\"%s\",\"host\":\"%s\",\"src\":\"%s\"}\n", \
          now, epoch, jesc(tk), jesc(from), jesc(cur[tk]), jesc(prnum[tk]), \
          jesc(title[tk]), jesc(board), jesc(host), (seeded == 1 ? "seed" : src) >> ev
        changed = 1
      }
      # A row that VANISHED is not a transition. Boards get rows re-keyed, re-ordered and
      # moved between waves ("moved OUT of the wave - not dropped", per a real Run log),
      # and a board being archived would otherwise read as every row completing at once.
      # It simply drops out of the snapshot; the view renders from the live board, so a
      # vanished row disappears rather than parking in a stage forever.
      for (tk in cur) printf "%s\037%s\n", tk, cur[tk] > tmp
      close(tmp)
      # Tell the shell whether anything moved, so an unchanged board does no write at all.
      exit (changed ? 0 : 9)
    }
  ' || rc=$?
  # `|| rc=$?` and NOT a bare `local rc=$?` on the next line. awk exits 9 to say "parsed
  # fine, nothing moved", and a consumer running under `set -e` (bats does, and so would
  # any hook that adopted -e) treats that non-zero pipeline as a fatal error and abandons
  # the function right here — leaving the lock fd open and the snapshot unwritten. The
  # `||` makes the non-zero status an expected value rather than a failure.

  # rc 9 = parsed fine, nothing changed. Seed still needs its baseline written, but an
  # unchanged board must never rewrite the cache.
  if [ "$rc" = 0 ] || [ "$seeded" = 1 ]; then
    [ -s "$tmp" ] && mv "$tmp" "$snap" 2>/dev/null
  fi
  rm -f "$tmp" 2>/dev/null
  exec {_bo_fd}>&-
  return 0
}

# board_events PROJECT [TICKET] -> recorded transitions, OLDEST FIRST, as JSONL.
# Empty (status 0) when nothing has been observed yet.
#
# SORTED, never file order. The log is append-only per machine, but `merge=union` (see
# git-sync-agent.sh) interleaves two machines' appends at the hunk level rather than by
# time — verified: a divergence produced 1,3,2. File order is therefore per-machine
# chronological and globally not, so anything computing a dwell time from adjacent lines
# would get a negative one. `epoch` is on every event for exactly this; a stable sort keeps
# same-second events in the order they were observed.
board_events() { # $1=project [$2=ticket]
  local ev; ev="$(board_events_file "${1:-}")"
  [ -f "$ev" ] || return 0
  local src
  if [ -n "${2:-}" ]; then
    src="$(grep -F "\"ticket\":\"$2\"" "$ev" 2>/dev/null || true)"
  else
    src="$(cat "$ev" 2>/dev/null || true)"
  fi
  [ -n "$src" ] || return 0
  # Key on the numeric epoch field, wherever it sits in the object.
  printf '%s\n' "$src" \
    | awk '{ e=""; if (match($0, /"epoch":[0-9]+/)) e=substr($0, RSTART+8, RLENGTH-8); printf "%s\t%s\n", (e==""?0:e), $0 }' \
    | sort -s -n -k1,1 | cut -f2-
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
