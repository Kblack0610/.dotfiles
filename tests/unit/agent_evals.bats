#!/usr/bin/env bats
# agent-evals.sh — the ONE reader for the session-eval corpus, shared by
# eval-report.sh and notes-cockpit's usage view.
#
# Every case below is drawn from real data in ~/.agent/evals (300 files, 2671
# sessions), and most reproduce a bug the previous parser (eval-report.sh's per-line
# grep loop) actually had. The failure mode here is the same as the board parser's:
# not a crash, but a SCORE THAT QUIETLY VANISHES — a dimension parsed out of the file
# and then never displayed reads identically to a dimension the judge never wrote.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  . "$AGENT_EVALS_LIB"
  export AGENT_EVALS_DIR="$BATS_TEST_TMPDIR/evals"
  EVAL_ROOT="$AGENT_EVALS_DIR"
  mkdir -p "$EVAL_ROOT/proj"
}

# write_eval <date> <<'EOF' ... EOF
write_eval() { mkdir -p "$EVAL_ROOT/${2:-proj}"; cat > "$EVAL_ROOT/${2:-proj}/$1.md"; }
rows()  { eval_rows "$EVAL_ROOT"/*/*.md; }
# field <row> <col>
field() { rows | sed -n "${1}p" | cut -f"$2"; }
# dim_col <name> -> the 1-based TSV column for that dimension
dim_col() {
  local i
  for i in "${!EVAL_DIMS[@]}"; do
    [ "${EVAL_DIMS[$i]}" = "$1" ] && { echo $(( i + 8 )); return; }
  done
  echo 0
}

# ── the dimension list itself ────────────────────────────────────────────────
# NEGATIVE CONTROL for every column assertion below: with an empty EVAL_DIMS the
# parser emits no dimension columns at all, and each "the score landed in its column"
# test would pass vacuously by comparing "" to "". Assert the list is real first.

@test "EVAL_DIMS is populated and EVAL_HEADS is parallel to it" {
  [ "${#EVAL_DIMS[@]}" -ge 6 ]
  assert_equal "${#EVAL_DIMS[@]}" "${#EVAL_HEADS[@]}"
}

@test "a row has exactly 6 fixed + one-per-dimension + 1 flag columns" {
  write_eval 2026-07-01 <<'EOF'
## Session 1 (a label)

- **Workflow**: 9/10 — fine
EOF
  assert_equal "$(rows | awk -F'\t' '{print NF}')" "$(( 7 + ${#EVAL_DIMS[@]} + 1 ))"
}

# ── the Lessons sentinel (364 occurrences in the real corpus) ────────────────
# The judge template says: "if no user correction occurred this turn, write
# `- **Lessons**: 0 — no correction`". A bare 0 is therefore the BEST outcome, not a
# floor score. eval-report.sh dropped these entirely (its regex demands `/10`), and
# any parser that reads them as a zero both drags the Lessons mean down and dumps 364
# clean sessions into the below-7 attention lane.

@test "a bare Lessons 0 is the no-correction sentinel, not a score" {
  write_eval 2026-07-01 <<'EOF'
## Session 1 (clean run)

- **Workflow**: 9/10 — fine
- **Lessons**: 0 — no correction
EOF
  assert_equal "$(field 1 "$(dim_col Lessons)")" '-'
  assert_equal "$(field 1 "$(rows | awk -F'\t' '{print NF}')")" '1'
}

@test "a bare Lessons 1 is a correction COUNT, not a 1/10 score" {
  # The corpus has 8 of these and they all read "1 captured" / "1 user correction this
  # turn" — i.e. the agent did the right thing. Scoring them put 8 of the BEST sessions
  # in the attention lane. Caught only by diffing this parser's findings against the old
  # one and asking why 8 had appeared from nowhere.
  write_eval 2026-07-01 <<'EOF'
## Session 1 (captured a lesson)

- **Workflow**: 9/10 — fine
- **Lessons**: 1 captured — `~/.agent/lessons/proj.md` now has the pattern
EOF
  assert_equal "$(field 1 "$(dim_col Lessons)")" '-'
  assert_equal "$(field 1 "$(rows | awk -F'\t' '{print NF}')")" '0'
}

@test "an explicit Lessons 0/10 IS a real floor score, unlike the bare sentinel" {
  # The pair that makes the test above meaningful: if the parser simply blanked every
  # Lessons 0 it would pass that test and fail this one.
  write_eval 2026-07-01 <<'EOF'
## Session 1 (genuinely bad)

- **Lessons**: 0/10 — ignored the correction twice
EOF
  assert_equal "$(field 1 "$(dim_col Lessons)")" '0'
  assert_equal "$(field 1 "$(rows | awk -F'\t' '{print NF}')")" '0'
}

# ── decimals (45 in the real corpus, 11 of them 9.5/10) ─────────────────────

@test "a decimal score keeps its fraction" {
  # eval-report.sh's `grep -oE '[0-9]*' | head -1` read 9.5 as 9, and its later
  # `[ "$val" -lt 7 ]` then ERRORED on the decimal — swallowed by 2>/dev/null.
  write_eval 2026-07-01 <<'EOF'
## Session 1 (decimals)

- **Workflow**: 9.5/10 — nearly
**Summary:** ok. Overall: 8.5/10.
EOF
  assert_equal "$(field 1 "$(dim_col Workflow)")" '9.5'
  assert_equal "$(field 1 7)" '8.5'
}

@test "eval_is_na accepts a decimal but rejects a dash, so callers never test -lt on one" {
  run eval_is_na '9.5'; assert_failure    # 9.5 IS comparable
  run eval_is_na '-';   assert_success    # a dash is not
  run eval_is_na '';    assert_success
  run eval_is_na 'n/a'; assert_success
}

# ── non-numeric cells ───────────────────────────────────────────────────────

@test "n/a and prose render as a dash, not as zero" {
  write_eval 2026-07-01 <<'EOF'
## Session 1 (mixed)

- **Workflow**: 8/10 — fine
- **Code Hygiene**: n/a — no code changes
- **Verification**: PASS
EOF
  assert_equal "$(field 1 "$(dim_col Workflow)")"       '8'
  assert_equal "$(field 1 "$(dim_col 'Code Hygiene')")" '-'
  assert_equal "$(field 1 "$(dim_col Verification)")"   '-'
}

@test "Overall: n/a leaves the overall column a dash" {
  write_eval 2026-07-01 <<'EOF'
## Session 1 (q and a only)

- **Workflow**: 9/10 — fine
**Summary:** nothing shipped. Overall: n/a.
EOF
  assert_equal "$(field 1 7)" '-'
}

# ── unknown dimensions ──────────────────────────────────────────────────────

@test "an unknown dimension is dropped while a known one in the same session survives" {
  # `MAJOR/P1` is real, in-corpus. The corpus carries 39 distinct labels; columnising
  # them would make the row width depend on the data. The paired Workflow assertion is
  # the control — a parser that dropped EVERYTHING would pass the first half alone.
  write_eval 2026-07-01 <<'EOF'
## Session 1 (one-off labels)

- **MAJOR/P1**: 3/10 — a one-off the judge invented
- **Workflow**: 7/10 — fine
EOF
  assert_equal "$(rows | awk -F'\t' '{print NF}')" "$(( 7 + ${#EVAL_DIMS[@]} + 1 ))"
  assert_equal "$(field 1 "$(dim_col Workflow)")" '7'
  # The dropped 3/10 must not have landed in ANY dimension column. Checked positionally
  # rather than with a substring refute, which would also match the `3` inside a date.
  run bash -c "cut -f8- <<<\"\$(sed -n 1p <<<'$(rows)')\" | tr '\t' '\n' | grep -cx 3"
  assert_output '0'
}

@test "a lowercase dimension variant lands in its proper column" {
  # `Code hygiene` and `Scope alignment` both occur; case drift used to lose them.
  write_eval 2026-07-01 <<'EOF'
## Session 1 (case drift)

- **Code hygiene**: 6/10 — sloppy
- **scope alignment**: 5/10 — drifted
EOF
  assert_equal "$(field 1 "$(dim_col 'Code Hygiene')")"    '6'
  assert_equal "$(field 1 "$(dim_col 'Scope Alignment')")" '5'
}

# ── the session id, the join key to the registry and to Prometheus ──────────

@test "a session with a sid emits it and one without emits a dash" {
  # Both, in one file. ~87% of the real corpus has no sid (the judge only started
  # writing the marker recently), so a parser that hardcoded `-` would look correct
  # against real data and silently make the cost join impossible.
  write_eval 2026-07-01 <<'EOF'
## Session 1 (old, no marker)

- **Workflow**: 9/10 — fine

## Session 2 (new) <!-- sid: 9d5e5467-1111-2222-3333-444455556666 -->

- **Workflow**: 8/10 — fine
EOF
  assert_equal "$(field 1 5)" '-'
  assert_equal "$(field 2 5)" '9d5e5467-1111-2222-3333-444455556666'
}

@test "project and date come from the path, and the label from the header" {
  write_eval 2026-07-02 <<'EOF'
## Session 3 (repair the thing)

- **Workflow**: 9/10 — fine
EOF
  assert_equal "$(field 1 1)" 'proj'
  assert_equal "$(field 1 2)" '2026-07-02'
  assert_equal "$(field 1 4)" '3'
  assert_equal "$(field 1 6)" 'repair the thing'
}

@test "a non-numeric session header still emits a row, keyed with a dash" {
  # `## Session N+1` and `## Session Eval - ...` both occur in the corpus.
  write_eval 2026-07-01 <<'EOF'
## Session N+1 (a continuation)

- **Workflow**: 9/10 — fine
EOF
  assert_equal "$(rows | wc -l)" '1'
  assert_equal "$(field 1 4)" '-'
}

# ── file discovery ──────────────────────────────────────────────────────────

@test "only YYYY-MM-DD.md counts as an eval file" {
  # A delta-audit `findings.md` really does sit under ~/.agent/evals and would parse
  # as one long junk session. This used to be excluded by a -maxdepth heuristic that
  # was also, accidentally, the only thing excluding _archive.
  write_eval 2026-07-01 <<'EOF'
## Session 1 (real)

- **Workflow**: 9/10 — fine
EOF
  mkdir -p "$EVAL_ROOT/proj/delta-audit-2026-06-18"
  cat > "$EVAL_ROOT/proj/delta-audit-2026-06-18/findings.md" <<'EOF'
## Session 1 (NOT an eval)

- **Workflow**: 1/10 — junk
EOF
  run eval_files
  assert_success
  refute_output --partial 'findings.md'
  assert_output --partial '2026-07-01.md'
}

@test "_archive is pruned" {
  mkdir -p "$EVAL_ROOT/_archive/old"
  cat > "$EVAL_ROOT/_archive/old/2026-01-01.md" <<'EOF'
## Session 1 (archived)

- **Workflow**: 1/10 — old
EOF
  write_eval 2026-07-01 <<'EOF'
## Session 1 (current)

- **Workflow**: 9/10 — fine
EOF
  run eval_files
  refute_output --partial '_archive'
  assert_output --partial '2026-07-01.md'
}

@test "the since window filters by filename and keeps the boundary day" {
  write_eval 2026-06-01 <<'EOF'
## Session 1 (old)

- **Workflow**: 1/10 — old
EOF
  write_eval 2026-07-15 <<'EOF'
## Session 1 (boundary)

- **Workflow**: 5/10 — mid
EOF
  write_eval 2026-08-01 <<'EOF'
## Session 1 (new)

- **Workflow**: 9/10 — new
EOF
  run eval_files 2026-07-15
  refute_output --partial '2026-06-01'
  assert_output --partial '2026-07-15'   # inclusive
  assert_output --partial '2026-08-01'
}

# ── multi-session / multi-file state ────────────────────────────────────────

@test "scores do not leak between sessions or across files" {
  # flush() must clear the score map. A leak here is invisible in aggregate — it just
  # makes a thin session look complete by inheriting the previous one's columns.
  write_eval 2026-07-01 <<'EOF'
## Session 1 (full)

- **Workflow**: 9/10 — fine
- **Verification**: 8/10 — fine

## Session 2 (thin)

- **Workflow**: 7/10 — fine
EOF
  write_eval 2026-07-02 <<'EOF'
## Session 1 (thin, new file)

- **Verification**: 6/10 — fine
EOF
  assert_equal "$(field 2 "$(dim_col Verification)")" '-'
  assert_equal "$(field 3 "$(dim_col Workflow)")"     '-'
  assert_equal "$(field 3 "$(dim_col Verification)")" '6'
}

@test "no field is ever emitted blank" {
  # TAB is IFS whitespace in bash, so one blank middle field shifts every later field
  # left on `read` and the label lands in some numeric variable.
  write_eval 2026-07-01 <<'EOF'
## Session 1

- **Workflow**: 9/10 — fine
EOF
  # Materialise first: eval_rows is a sourced shell function and is not visible inside a
  # `bash -c` subshell, which silently made an earlier version of this test assert on the
  # output of a command-not-found.
  rows > "$BATS_TEST_TMPDIR/rows.tsv"
  [ -s "$BATS_TEST_TMPDIR/rows.tsv" ]
  run grep -c -P '\t\t|\t$' "$BATS_TEST_TMPDIR/rows.tsv"
  assert_output '0'
}

# ── the reason this lib exists at all ───────────────────────────────────────

@test "parsing stays fast enough for a render path" {
  # notes-cockpit's list_section runs on every keypress. eval-report.sh's per-line
  # grep loop took 15.7s on the real corpus, which is why evals could never be shown.
  # Control: this same assertion must be watched FAILING against that old loop.
  local i
  for i in $(seq 1 200); do
    printf '## Session 1 (perf %s) <!-- sid: 0000-%s -->\n\n- **Workflow**: 9/10 — x\n- **Lessons**: 0 — no correction\n' \
      "$i" "$i" > "$EVAL_ROOT/proj/2026-01-$(printf '%02d' $(( i % 28 + 1 ))).md"
  done
  local start end
  start=$(date +%s%N)
  eval_rows "$EVAL_ROOT"/*/*.md > /dev/null
  end=$(date +%s%N)
  [ $(( (end - start) / 1000000 )) -lt 2000 ]
}
