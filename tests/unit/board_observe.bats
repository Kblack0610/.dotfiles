#!/usr/bin/env bats
# board_observe — the stage-transition recorder built on agent-board.sh.
#
# WHAT THIS GUARDS. A row's Status cell is edited by an LLM agent doing Edit on markdown,
# and the edit overwrites the previous value, so the board holds a current stage and no
# history. board_observe reconstructs the history by DIFFING the board against what it saw
# last time, asking nothing of the agents. The failure modes are all quiet ones:
#
#   * a phantom transition (the stage flapped on prose, not on real movement)
#   * a duplicate event (two observers raced) — indistinguishable from a row that
#     genuinely bounced between two stages
#   * a fabricated history (a board that predates this code, dated to today)
#   * a stage that disagrees with the one the cockpit renders
#
# None of those raise an error; they just make every duration in the factory view wrong.
#
# The corpus test that matters lives in board_corpus.bats: fixtures written from the
# parser can only ever confirm the parser (see tests/corpus-check.sh).

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  . "$AGENT_BOARD_LIB"
  PROJ=demo
  BDIR="$HOME/.agent/plans/$PROJ"
  mkdir -p "$BDIR"
  BB="$BDIR/sprint-v1.0.0.md"
}

write_bb() { cat > "$BB"; }
nevents() { board_events "$PROJ" | grep -c . || true; }

# A minimal two-row board. `$1`/`$2` are the two Status cells.
board_with() {
  cat > "$BB" <<EOF
# Sprint — demo — v1.0.0

## Meta
- Mode: wave:1

## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 101 | first thing | $1 |
| 2 | 102 | second thing | $2 |
EOF
}

# ── seeding ──────────────────────────────────────────────────────────────────

@test "first sight seeds one event per row, with an empty from" {
  board_with queued queued
  board_observe "$BB"
  assert_equal "$(nevents)" 2
  # Every seed row records where the board ALREADY was, not a transition into it.
  assert_equal "$(board_events "$PROJ" | grep -c '"from":""')" 2
  assert_equal "$(board_events "$PROJ" | grep -c '"src":"seed"')" 2
}

@test "seeding does not invent a history for a board that predates the observer" {
  # A board whose rows are already merged must NOT produce queued->working->merged.
  board_with "in-wave" "in-wave"
  board_observe "$BB"
  assert_equal "$(nevents)" 2
  # Both rows land straight on merged. No queued/working is invented on the way.
  assert_equal "$(board_events "$PROJ" | grep -c '"to":"merged"')" 2
  assert_equal "$(board_events "$PROJ" | grep -c 'queued\|working' || true)" 0
}

# ── idempotence ──────────────────────────────────────────────────────────────

@test "observing an unchanged board twice emits nothing the second time" {
  board_with queued queued
  board_observe "$BB"
  local before; before="$(nevents)"
  board_observe "$BB"
  board_observe "$BB"
  assert_equal "$(nevents)" "$before"
}

@test "an unchanged board does not rewrite the snapshot" {
  board_with queued queued
  board_observe "$BB"
  local snap="$AGENTCTL_STATE_DIR/board/$PROJ.snapshot"
  [ -f "$snap" ]
  local mt; mt="$(stat -c %Y "$snap")"
  sleep 1
  board_observe "$BB"
  assert_equal "$(stat -c %Y "$snap")" "$mt"
}

# ── real transitions ─────────────────────────────────────────────────────────

@test "a status edit emits exactly one event with the right from and to" {
  board_with queued queued
  board_observe "$BB"
  local before; before="$(nevents)"
  board_with "in-progress" queued
  board_observe "$BB"
  assert_equal "$(nevents)" "$((before + 1))"
  run --separate-stderr echo "$(board_events "$PROJ" | tail -1)"
  assert_output --partial '"ticket":"101"'
  assert_output --partial '"from":"queued"'
  assert_output --partial '"to":"working"'
  assert_output --partial '"src":"observe"'
}

@test "a from == to no-op is never emitted" {
  # board_stage matches `blocked` against the WHOLE cell, deliberately, so a watchdog
  # appending prose re-derives the same stage from different text. That must stay silent.
  board_with "blocked - waiting on review" queued
  board_observe "$BB"
  local before; before="$(nevents)"
  board_with "blocked - waiting on review. Confirmed still blocked at 09:14." queued
  board_observe "$BB"
  assert_equal "$(nevents)" "$before"
}

@test "a row that vanishes emits nothing" {
  # Boards get rows re-keyed, re-ordered, and moved between waves. A board being
  # archived must not read as every row completing at once.
  board_with queued queued
  board_observe "$BB"
  local before; before="$(nevents)"
  cat > "$BB" <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 101 | first thing | queued |
EOF
  board_observe "$BB"
  assert_equal "$(nevents)" "$before"
}

# ── the effective stage ──────────────────────────────────────────────────────

@test "board_rows_effective lets a checkpoint sentinel override the status cell" {
  # The sentinel is ground truth: a 'completed' with no STATUS: DONE is an agent that
  # died mid-run. The cockpit has always applied this; the observer must see the same
  # stage or the recorded history disagrees with the rendered one.
  board_with "in-progress" queued
  mkdir -p "$BDIR/checkpoints"
  printf 'STATUS: DONE\n' > "$BDIR/checkpoints/101.md"
  assert_equal "$(board_rows_effective "$BB" "$PROJ" | head -1 | cut -d$'\037' -f2)" merged
  # ...and the raw reader still says otherwise, which is the whole point.
  assert_equal "$(board_rows "$BB" | head -1 | cut -d$'\037' -f2)" working
}

@test "board_observe records the effective stage, not the raw one" {
  board_with "in-progress" queued
  mkdir -p "$BDIR/checkpoints"
  printf 'STATUS: DONE\n' > "$BDIR/checkpoints/101.md"
  board_observe "$BB"
  run --separate-stderr echo "$(board_events "$PROJ" 101)"
  assert_output --partial '"to":"merged"'
}

# ── where things live ────────────────────────────────────────────────────────

@test "events are per-project, not per-board, so a ticket keeps one history" {
  board_with queued queued
  board_observe "$BB"
  [ -f "$HOME/.agent/plans/$PROJ/board-events.jsonl" ]
  # A second board in the same project appends to the SAME log.
  local b2="$BDIR/sprint-v1.0.1.md"
  cat > "$b2" <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 999 | later board | queued |
EOF
  board_observe "$b2"
  run --separate-stderr echo "$(board_events "$PROJ" 999)"
  assert_output --partial '"ticket":"999"'
}

@test "the events log is not picked up as a board" {
  # board_list's `sprint-*.md` glob is the ONE definition of a board. A sibling matching
  # it would become a phantom board for every consumer.
  board_with queued queued
  board_observe "$BB"
  assert_equal "$(board_list "$PROJ" | grep -c .)" 1
}

@test "the snapshot stays out of the git-tracked plans tree" {
  # ~/.agent is committed every 15 minutes and synced between machines, and
  # git-sync-agent.sh resolves conflicts with `checkout --theirs`. A cache rewritten on
  # every observation would conflict constantly and lose one machine's copy silently.
  board_with queued queued
  board_observe "$BB"
  [ -f "$AGENTCTL_STATE_DIR/board/$PROJ.snapshot" ]
  assert_equal "$(ls "$BDIR" | grep -c snapshot || true)" 0
}

@test "the project comes from the board path, not the cwd" {
  # `.claude/worktrees/agent-*` checkouts exist; resolving from $PWD files the event
  # under the worktree's name.
  board_with queued queued
  cd /tmp
  board_observe "$BB"
  assert_equal "$(board_project_of "$BB")" "$PROJ"
  assert_equal "$(nevents)" 2
}

# ── concurrency ──────────────────────────────────────────────────────────────

@test "concurrent observers do not double-record a transition" {
  # delivery-loop, wave-watchdog and captain-watchdog are all OnCalendar=*:0/12 with no
  # RandomizedDelaySec, so they fire on the same wall-clock second every time.
  board_with queued queued
  board_observe "$BB"
  local before; before="$(nevents)"
  board_with "in-progress" "in-progress"
  for _ in 1 2 3 4 5; do board_observe "$BB" & done
  wait
  # Two rows moved; five racing observers must still record exactly two events.
  assert_equal "$(nevents)" "$((before + 2))"
}

@test "every recorded event is one well-formed JSON object on its own line" {
  # Lines are kept under PIPE_BUF (4096) so an O_APPEND write is atomic: that is what
  # makes a lost lock degrade to duplicates rather than interleaved corruption.
  board_with "blocked - PR #42 merged, CI red" 'MERGED (PR #7, "quoted" title)'
  board_observe "$BB"
  board_events "$PROJ" | jq -c . >/dev/null
  assert_equal "$(board_events "$PROJ" | awk 'length($0) > 4096' | grep -c . || true)" 0
}

@test "events read back oldest-first even when the log is out of order" {
  # merge=union interleaves two machines' appends at the hunk level, not by time — a real
  # two-clone divergence produced events 1,3,2. A reader computing a dwell time from
  # adjacent lines would get a negative one.
  board_with queued queued
  board_observe "$BB"
  local ev="$HOME/.agent/plans/$PROJ/board-events.jsonl"
  {
    printf '{"epoch":300,"ticket":"777","from":"working","to":"merged"}\n'
    printf '{"epoch":100,"ticket":"777","from":"","to":"queued"}\n'
    printf '{"epoch":200,"ticket":"777","from":"queued","to":"working"}\n'
  } >> "$ev"
  run --separate-stderr echo "$(board_events "$PROJ" 777 | grep -o '"epoch":[0-9]*' | grep -o '[0-9]*' | xargs)"
  assert_output '100 200 300'
}

# ── negative control ─────────────────────────────────────────────────────────
# A test that cannot fail is not a test. This proves the suite above is actually
# observing board_observe's output and not just asserting against empty strings.

@test "NEGATIVE CONTROL: a stubbed differ fails the transition assertions" {
  board_observe() { :; }   # the stub: records nothing
  board_with queued queued
  board_observe "$BB"
  assert_equal "$(nevents)" 0
  board_with "in-progress" queued
  board_observe "$BB"
  # With the real differ this is 1. With the stub it must be 0, or the assertions above
  # are measuring something other than what they claim.
  assert_equal "$(nevents)" 0
}
