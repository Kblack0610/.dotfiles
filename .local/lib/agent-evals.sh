# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# agent-evals.sh — ONE reader for the session-eval corpus.
#
# The corpus at ~/.agent/evals/{project}/YYYY-MM-DD.md is written by the LLM judge
# (.claude/hooks/llm-judge.sh, dispatched from stop-post.d/90-eval-gate.sh) and is the
# only record of how well a session actually went. Until this file it had exactly one
# reader — .config/shared-hooks/eval-report.sh — which nothing called, so the corpus
# was effectively write-only.
#
# Extracted for two reasons, in order of importance:
#
#   1. SPEED. eval-report.sh parses with a `while read` loop that forks four
#      grep/sed subshells PER LINE. Measured on the real corpus (327 files, 2770
#      sessions): `--days 7` took 15.7s. The single-pass awk below does the FULL
#      corpus in 0.03s — ~190x. That gap is the whole reason the cockpit could not
#      show evals: notes-cockpit's list_section runs on every keypress.
#   2. ONE GRAMMAR, ONE PARSER. Same lesson as agent-board.sh (#170, "five readers
#      disagreed silently"). A second copy of these regexes in the cockpit would
#      drift from the judge template the same way eval-report.sh's column list did.
#
# Four parse bugs in eval-report.sh that this fixes, all found in real corpus data:
#
#   * `9.5/10` (10 occurrences) was read as `9` by `grep -oE '[0-9]*' | head -1`, and
#     the later `[ "$val" -lt 7 ]` then ERRORS on the decimal — swallowed by 2>/dev/null,
#     so the row silently lost its colour.
#   * `- **Lessons**: 0 — no correction` (364 occurrences) was dropped entirely: the
#     regex demands `/10`. See the sentinel note below — it is not a zero score.
#   * Case variants (`Code hygiene`, `Scope alignment`) fell out of their columns.
#   * The session id lives in an HTML comment and was never captured at all, so the
#     corpus could not be joined to the session registry or to Prometheus.

# ── the dimensions ───────────────────────────────────────────────────────────
# Declared ONCE, here, because this list has drifted before: eval-report.sh's header
# records that it was "pasted into four places", which is how its columns ended up
# asking for retired dimensions while "Compact Handoff" — scored on every session —
# was parsed out of the file and then never displayed.
#
# These MUST track the sections in ~/.config/llm-judge/prompt-template-eval.md. A name
# here the judge never writes renders as `-` forever; a name the judge writes that is
# missing here is DROPPED (see the unknown-dimension rule in eval_rows).
#
# `Infrastructure` is deliberately included though the base template omits it: it is
# added per-session by the `sections=+Infrastructure` delta documented in CLAUDE.md.
EVAL_DIMS=("Workflow" "Verification" "Code Hygiene" "Scope Alignment" "Compact Handoff" "Lessons" "Infrastructure")
EVAL_HEADS=("Wkflw" "Verif" "Hygie" "Scope" "Handoff" "Lessn" "Infra")

# Anything strictly below this wants a human's attention.
EVAL_ATTENTION_FLOOR=7

EVAL_ROOT="${AGENT_EVALS_DIR:-$HOME/.agent/evals}"

# ── discovery ────────────────────────────────────────────────────────────────
# eval_files <since-YYYY-MM-DD> [project] -> one path per line, oldest first.
#
# Windows on the FILENAME, never on file contents or mtime. The eval's date axis IS
# its name (one file per project per day), so a window costs zero file reads — which
# is what keeps `today` cheap on a render path. mtime would be wrong anyway: appending
# session 3 to today's file does not move sessions 1 and 2 into a later window.
#
# AN EVAL FILE IS ONE NAMED `YYYY-MM-DD.md`. Stated as a rule rather than inferred from
# directory depth, because depth silently did two different jobs at once: a `-maxdepth 2`
# correctly excluded `platform-agent-2/delta-audit-2026-06-18/findings.md` (a delta-audit
# artifact that is not an eval and would have parsed as one long junk session) while ALSO
# excluding the entire `_archive/<project>/` tree by accident. Two different intents, one
# incidental mechanism — so the moment archives were flattened or a project nested, the
# junk file would come back. The name rule handles the first case for good; `_archive` is
# pruned explicitly below because "archived" is a real decision, not a side effect.
eval_files() { # $1=since (YYYY-MM-DD, empty = all) $2=project (empty = all)
  local since="${1:-}" project="${2:-}" dir="$EVAL_ROOT"
  [ -d "$dir" ] || return 0
  if [ -n "$project" ]; then
    dir="$dir/$project"
    [ -d "$dir" ] || return 0
  fi
  find "$dir" -name '_archive' -prune -o \
       -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md' -print 2>/dev/null | sort | {
    if [ -n "$since" ]; then
      # String compare is correct and total for ISO dates, and needs no date(1) fork.
      while IFS= read -r f; do
        local base="${f##*/}"; base="${base%.md}"
        [[ "$base" < "$since" ]] || printf '%s\n' "$f"
      done
    else
      cat
    fi
  }
}

# ── the parser ───────────────────────────────────────────────────────────────
# eval_rows <file>... -> TSV, one row per session, in file order.
#
#   1 project   2 date   3 line   4 session_n   5 sid   6 label   7 overall
#   8..(7+N)    one column per EVAL_DIMS, in order
#   last        nocorrection  (1 when the Lessons line carried a zero correction count)
#
# `line` is the 1-based line of the `## Session` header in that file. Carried so a caller
# can open the eval AT the session rather than at the top of a 36KB file — the cockpit's
# usage view jumps there from its attention lane.
#
# Empty is emitted as `-`, NEVER blank: TAB is IFS whitespace in bash, so `read`
# collapses runs of it and one empty middle field shifts every later field left. Same
# reason agent-usage:cmd_rows and sessions:live_lines sentinel their columns.
#
# THE LESSONS LINE CARRIES TWO DIFFERENT QUANTITIES, and telling them apart is the whole
# reason this dimension gets special handling.
#
#   `- **Lessons**: 8/10 — note`     a SCORE, like every other dimension
#   `- **Lessons**: 0 — no correction`   a COUNT: the template (prompt-template-eval.md
#                                        line 30) mandates this exact form for "no user
#                                        correction occurred this turn"
#   `- **Lessons**: 1 captured — ...`    also a COUNT, and the corpus has 8 of these:
#                                        "1 user correction this turn", "1 lesson worth
#                                        capturing", "1 captured".
#
# So the rule is: WITH `/10` it is a score, WITHOUT it is a count of corrections. Every
# bare number in the corpus (373 zeros + 8 ones) is a count, and none is a score.
#
# Getting this wrong is not symmetrical. Reading the bare 0 as a score drags the Lessons
# mean toward zero and dumps 373 clean sessions into the below-7 attention lane; reading
# the bare 1 as a score flags 8 sessions that had done exactly the right thing (captured
# the lesson) as near-worst-possible. Both were observed before this rule was written.
#
# A count therefore never enters the Lessons score column — it sets the trailing
# `nocorrection` flag (1 when the count was zero) and nothing else. `0/10`, with the
# slash, remains a genuine floor score and is kept.
eval_rows() { # $1..=files
  [ $# -gt 0 ] || return 0
  local dims; dims="$(printf '%s|' "${EVAL_DIMS[@]}")"; dims="${dims%|}"
  awk -v DIMS="$dims" '
    function flush(   i) {
      if (!open) return
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s", proj, date, lineno, snum, sid, label, (ov=="" ? "-" : ov)
      for (i = 1; i <= nd; i++) printf "\t%s", (sc[D[i]] == "" ? "-" : sc[D[i]])
      # `nocorr+0`, not `nocorr`: an awk variable never assigned is the empty string, so
      # every session that did not hit the sentinel emitted a BLANK last field — the exact
      # trailing-blank hazard the `-` convention exists to prevent.
      printf "\t%s\n", nocorr + 0
      open = 0; nocorr = 0; ov = ""
      delete sc
    }
    BEGIN {
      nd = split(DIMS, D, "|")
      for (i = 1; i <= nd; i++) LC[tolower(D[i])] = D[i]
    }
    # A new file ends whatever session was still open in the previous one.
    FNR == 1 {
      flush()
      date = FILENAME; sub(/\.md$/, "", date); sub(/.*\//, "", date)
      proj = FILENAME; sub(/\/[^\/]*$/, "", proj); sub(/.*\//, "", proj)
    }
    /^## Session/ {
      flush()
      open = 1; sid = "-"; label = "-"; snum = "-"; lineno = FNR
      # `## Session 3`, but also `## Session N+1` and `## Session Eval - ...` occur.
      if (match($0, /^## Session +[0-9]+/)) {
        snum = substr($0, RSTART, RLENGTH); sub(/^## Session +/, "", snum)
      }
      if (match($0, /<!-- *sid: *[0-9a-fA-F-]+/)) {
        sid = substr($0, RSTART, RLENGTH); sub(/.*sid: */, "", sid)
      }
      if (match($0, /\([^)]*\)/)) { label = substr($0, RSTART + 1, RLENGTH - 2) }
      next
    }
    # `- **Dimension**: <value> — note`
    /^- \*\*[^*]+\*\*:/ {
      if (!open) next
      d = $0; sub(/^- \*\*/, "", d); sub(/\*\*:.*/, "", d)
      k = LC[tolower(d)]
      # An unknown dimension is DROPPED, not columnised. The corpus carries 39 distinct
      # labels including one-offs like `MAJOR/P1` and `Observability ROI (cumulative)`;
      # columnising them would make the row width depend on the data.
      if (k == "") next
      v = $0; sub(/^[^:]*: */, "", v)
      if (v ~ /^[0-9]+(\.[0-9]+)?\/10/) {          # 8/10, 9.5/10
        sub(/\/10.*/, "", v); sc[k] = v + 0
      } else if (v ~ /^[0-9]+(\.[0-9]+)?([^0-9\/.]|$)/) {   # bare number, no /10
        sub(/[^0-9.].*/, "", v)
        # On Lessons a bare number is a CORRECTION COUNT, never a score - see the header.
        # Every bare number in the corpus is one, and treating them as scores put 373
        # clean sessions and 8 correctly-captured lessons in the attention lane.
        if (k == "Lessons") { nocorr = (v + 0 == 0) ? 1 : 0 }
        else { sc[k] = v + 0 }
      }
      # anything else (n/a, N/A, PASS, prose) leaves the cell unset -> `-`
      next
    }
    # `**Summary:** ... Overall: 9/10.`  (`Overall: n/a.` occurs 307 times -> `-`)
    /Overall: *[0-9]/ {
      if (!open) next
      o = $0; sub(/.*Overall: */, "", o); sub(/\/10.*/, "", o); sub(/[^0-9.].*/, "", o)
      if (o != "") ov = o + 0
    }
    END { flush() }
  ' "$@"
}

# eval_is_na <cell> -> 0 (true) when the cell carries no comparable score.
# Use this rather than testing `= "-"` at each site: `[ "$c" -lt 7 ]` ERRORS on both `-`
# and on a decimal like `9.5`, and that error is what eval-report.sh was swallowing.
eval_is_na() { # $1=cell
  case "${1:-}" in
    ''|'-') return 0 ;;
    *[!0-9.]*) return 0 ;;
    *) return 1 ;;
  esac
}
