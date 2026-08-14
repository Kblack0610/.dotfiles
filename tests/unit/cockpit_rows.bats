#!/usr/bin/env bats
# The row wire format is the contract between the script and fzf: every --bind does
# `$SELF --verb` then `reload($SELF --list)`, and fzf slices rows with
# `--delimiter=$'\t' --with-nth='7..'`. Documented at notes-cockpit.sh:24 as
#   1 type(task|head|add|hint)  2 profile  3 file  4 line  5 key  6 section  7 DISPLAY
# If a field moves, the UI breaks at runtime with no error. Hence these tests.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$COCKPIT"
}

nfields() { awk -F'\t' '{print NF; exit}'; }

# ── _task_row ────────────────────────────────────────────────────────────────

@test "_task_row emits exactly 7 tab-separated fields" {
  run bash -c 'source "$COCKPIT"; _task_row personal /f.md 12 k1 personal "- [ ] a task" | awk -F"\t" "{print NF}"'
  assert_output '7'
}

@test "_task_row places each field in its documented position" {
  local row; row="$(_task_row personal /vault/f.md 12 k1 personal/cockpit '- [ ] a task')"
  assert_equal "$(printf '%s' "$row" | cut -f1)" 'task'
  assert_equal "$(printf '%s' "$row" | cut -f2)" 'personal'
  assert_equal "$(printf '%s' "$row" | cut -f3)" '/vault/f.md'
  assert_equal "$(printf '%s' "$row" | cut -f4)" '12'
  assert_equal "$(printf '%s' "$row" | cut -f5)" 'k1'
  assert_equal "$(printf '%s' "$row" | cut -f6)" 'personal/cockpit'
}

@test "_task_row strips the markdown checkbox from the display field" {
  local disp
  disp="$(_task_row personal /f.md 1 k1 personal '- [ ] fix the rail' | cut -f7 | strip_ansi)"
  assert_equal "$disp" '[ ] fix the rail'
}

@test "_task_row renders an in-progress task with the [/] glyph" {
  local disp
  disp="$(_task_row personal /f.md 1 k1 personal '- [/] half done' | cut -f7 | strip_ansi)"
  assert_equal "$disp" '[/] half done'
}

@test "_task_row treats [x] and [X] as done-style checkboxes to strip" {
  local disp
  disp="$(_task_row personal /f.md 1 k1 personal '- [x] finished' | cut -f7 | strip_ansi)"
  assert_equal "$disp" '[ ] finished'
  disp="$(_task_row personal /f.md 1 k1 personal '- [X] finished' | cut -f7 | strip_ansi)"
  assert_equal "$disp" '[ ] finished'
}

@test "_task_row strips html comment markers from the display" {
  local disp
  disp="$(_task_row personal /f.md 1 k1 personal '- [ ] a task <!-- key:abc -->' | cut -f7 | strip_ansi)"
  assert_equal "$disp" '[ ] a task'
}

@test "_task_row preserves priority tags in the display, since the filter greps them" {
  local disp
  disp="$(_task_row personal /f.md 1 k1 personal '- [ ] urgent thing #urgent' | cut -f7 | strip_ansi)"
  assert_equal "$disp" '[ ] urgent thing #urgent'
}

@test "_task_row keeps leading indentation out of the display" {
  local disp
  disp="$(_task_row personal /f.md 1 k1 personal '    - [ ] indented' | cut -f7 | strip_ansi)"
  assert_equal "$disp" '[ ] indented'
}

@test "_task_row emits a single line even for text containing no newline tricks" {
  local n
  n="$(_task_row personal /f.md 1 k1 personal '- [ ] one' | wc -l)"
  assert_equal "$n" '1'
}

# ── headers ──────────────────────────────────────────────────────────────────

@test "_header emits a head row with 7 fields and an empty key" {
  local row; row="$(_header 'personal')"
  assert_equal "$(printf '%s' "$row" | cut -f1)" 'head'
  assert_equal "$(printf '%s' "$row" | cut -f5)" ''
  assert_equal "$(printf '%s' "$row" | awk -F'\t' '{print NF}')" '7'
}

@test "_header display carries the section name" {
  run bash -c 'source "$COCKPIT"; _header personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'personal'
}

@test "_subheader includes the project name, version and collapsed status" {
  run bash -c 'source "$COCKPIT"; _subheader Cockpit "shipping the rail" v0.3 | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'Cockpit'
  assert_output --partial 'v0.3'
  assert_output --partial 'shipping the rail'
}

@test "_subheader collapses a multi-line status onto one row" {
  local n
  n="$(_subheader Cockpit "$(printf 'line one\nline two')" v0.3 | wc -l)"
  assert_equal "$n" '1'
}

@test "_subheader truncates a very long status" {
  local disp long
  long="$(printf 'x%.0s' {1..200})"
  disp="$(_subheader Cockpit "$long" v0.1 | cut -f7 | strip_ansi)"
  [ "${#disp}" -lt 120 ]
}

@test "_subheader omits the status segment when status is empty" {
  run bash -c 'source "$COCKPIT"; _subheader Notes "" v1.2 | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'Notes'
  assert_output --partial 'v1.2'
}

# ── _flat: todo lane first, then an "in progress" sub-lane ───────────────────

@test "_flat returns only rows whose section field matches" {
  local rows
  rows="$(_task_row personal /f.md 1 k1 personal '- [ ] mine'
          _task_row personal /f.md 2 k2 personal/cockpit '- [ ] theirs')"
  run bash -c 'source "$COCKPIT"; _flat "$1" personal | cut -f5' _ "$rows"
  assert_output 'k1'
}

@test "_flat puts in-progress tasks after an in-progress header" {
  local rows out
  rows="$(_task_row personal /f.md 1 k1 personal '- [ ] todo one'
          _task_row personal /f.md 2 k2 personal '- [/] doing one')"
  out="$(_flat "$rows" personal | cut -f1,5 | strip_ansi)"
  assert_equal "$(printf '%s' "$out" | sed -n 1p)" "$(printf 'task\tk1')"
  assert_equal "$(printf '%s' "$out" | sed -n 2p)" "$(printf 'head\t')"
  assert_equal "$(printf '%s' "$out" | sed -n 3p)" "$(printf 'task\tk2')"
}

@test "_flat omits the in-progress header when nothing is in progress" {
  local rows out
  rows="$(_task_row personal /f.md 1 k1 personal '- [ ] todo only')"
  out="$(_flat "$rows" personal)"
  refute [ "$(printf '%s' "$out" | grep -c 'in progress')" != 0 ]
}

# ── priority filter ──────────────────────────────────────────────────────────

@test "cycle_pfilter walks none -> urgent -> high -> low -> none" {
  assert_equal "$(read_pfilter)" ''
  cycle_pfilter; assert_equal "$(read_pfilter)" 'urgent'
  cycle_pfilter; assert_equal "$(read_pfilter)" 'high'
  cycle_pfilter; assert_equal "$(read_pfilter)" 'low'
  cycle_pfilter; assert_equal "$(read_pfilter)" ''
}

@test "_apply_pfilter passes everything through when no filter is set" {
  local rows out
  rows="$(_task_row personal /f.md 1 k1 personal '- [ ] plain'
          _task_row personal /f.md 2 k2 personal '- [ ] tagged #urgent')"
  out="$(printf '%s\n' "$rows" | _apply_pfilter | wc -l)"
  assert_equal "$out" '2'
}

@test "_apply_pfilter keeps only tasks carrying the active tag" {
  printf 'urgent' > "$PFILTER"
  local rows out
  rows="$(_task_row personal /f.md 1 k1 personal '- [ ] plain'
          _task_row personal /f.md 2 k2 personal '- [ ] tagged #urgent')"
  out="$(printf '%s\n' "$rows" | _apply_pfilter | cut -f5)"
  assert_equal "$out" 'k2'
}

@test "_apply_pfilter drops a header whose group has no matching task" {
  printf 'urgent' > "$PFILTER"
  local rows out
  rows="$(_header 'empty group'
          _task_row personal /f.md 1 k1 personal '- [ ] plain')"
  out="$(printf '%s\n' "$rows" | _apply_pfilter)"
  assert_equal "$out" ''
}

@test "_apply_pfilter keeps a header whose group has a matching task" {
  printf 'urgent' > "$PFILTER"
  local rows out
  rows="$(_header 'live group'
          _task_row personal /f.md 1 k1 personal '- [ ] tagged #urgent')"
  out="$(printf '%s\n' "$rows" | _apply_pfilter | cut -f1)"
  assert_equal "$(printf '%s' "$out" | sed -n 1p)" 'head'
  assert_equal "$(printf '%s' "$out" | sed -n 2p)" 'task'
}

# Characterization, not a bug report: the filter is a substring match (awk `index`), so a
# tag that merely starts with the active one also survives. Harmless in practice because
# the priority vocabulary is a closed set (urgent/high/low, shared with md::PRIORITIES and
# the nvim <leader>tp cycle). Pinned here so tightening it later is a deliberate change
# with a failing test, rather than a silent behaviour swap.
@test "_apply_pfilter matches priority tags by substring" {
  printf 'high' > "$PFILTER"
  local rows out
  rows="$(_task_row personal /f.md 1 k1 personal '- [ ] a #high'
          _task_row personal /f.md 2 k2 personal '- [ ] b #highlight'
          _task_row personal /f.md 3 k3 personal '- [ ] c #low')"
  out="$(printf '%s\n' "$rows" | _apply_pfilter | cut -f5 | tr '\n' ' ')"
  assert_equal "$out" 'k1 k2 '
}

# ── the #ai lane ───────────────────────────────────────────────────────────

# One list, two lanes: `#ai` marks an item a `/wave` may pick up, everything untagged is
# the human's and no agent touches it. If the marker stops rendering, the two lanes become
# indistinguishable in the cockpit and the human cannot see what they handed over.

@test "_task_row marks an #ai item with the lane badge" {
  run _task_row bnb /f.md 4 k1 bnb/pmp '- [ ] thumbnail squished #ai'
  assert_output --partial '@ai'
}

@test "_task_row leaves an untagged (human-lane) item unmarked" {
  run _task_row bnb /f.md 6 k3 bnb/pmp '- [ ] call the attorney re the BAA'
  refute_output --partial '@ai'
}

@test "_task_row does not leave the raw #ai tag in the display" {
  # The badge replaces it; showing both is noise on every agent-lane row.
  run _task_row bnb /f.md 4 k1 bnb/pmp '- [ ] thumbnail squished #ai'
  refute_output --partial '#ai '
}

@test "_task_row surfaces a stamped ticket id so the wave burns down visibly" {
  run _task_row bnb /f.md 4 k1 bnb/pmp '- [ ] thumbnail squished #ai <!-- vk:601 -->'
  assert_output --partial '#601'
}

@test "_task_row shows no ticket id when the item has not been scoped yet" {
  run _task_row bnb /f.md 5 k2 bnb/pmp '- [ ] provider cannot remove a resident #ai'
  refute_output --partial '#'
}

@test "an #ai item still renders its in-progress glyph" {
  run _task_row bnb /f.md 5 k2 bnb/pmp '- [/] provider cannot remove a resident #ai'
  assert_output --partial '[/]'
}

@test "the lane badge does not disturb the 7-field wire format" {
  run bash -c 'source "$COCKPIT"; _task_row bnb /f.md 4 k1 bnb/pmp "- [ ] x #ai <!-- vk:601 -->" | awk -F"\t" "{print NF}"'
  assert_output '7'
}

# ── toggle_ai (C-i) ─────────────────────────────────────────────────────────

# Handing a task to the agents is a LINE EDIT, not a CLI call: the notes CLI has no
# ptask tag/untag (focus has `mv --tag`, ptask never got one), and rm+add would lose the
# item's position and its `<!-- vk:ID -->` stamp. So these pin the edit itself.

setup_sheet() {
  SHEET="$BATS_TEST_TMPDIR/sheet.md"
  cat > "$SHEET" <<'SHEET'
- [ ] plain task
- [ ] tagged already #ai
- [ ] with priority #high
- [ ] a false friend #aid
SHEET
}

@test "toggle_ai hands an untagged task to the agents" {
  setup_sheet; toggle_ai "$SHEET" 1
  run sed -n '1p' "$SHEET"
  assert_output '- [ ] plain task #ai'
}

@test "toggle_ai takes a tagged task back" {
  setup_sheet; toggle_ai "$SHEET" 2
  run sed -n '2p' "$SHEET"
  assert_output '- [ ] tagged already'
}

@test "toggle_ai round-trips to the original line" {
  setup_sheet; toggle_ai "$SHEET" 1; toggle_ai "$SHEET" 1
  run sed -n '1p' "$SHEET"
  assert_output '- [ ] plain task'
}

@test "toggle_ai keeps a priority tag" {
  setup_sheet; toggle_ai "$SHEET" 3
  run sed -n '3p' "$SHEET"
  assert_output '- [ ] with priority #high #ai'
}

@test "toggle_ai does not treat #aid as the lane tag" {
  # A bare /#ai/ match would strip the tag off `#aid` and silently corrupt the line.
  setup_sheet; toggle_ai "$SHEET" 4
  run sed -n '4p' "$SHEET"
  assert_output '- [ ] a false friend #aid #ai'
}

@test "toggle_ai leaves every other line untouched" {
  setup_sheet; toggle_ai "$SHEET" 1
  run sed -n '2,4p' "$SHEET"
  assert_line --index 0 '- [ ] tagged already #ai'
  assert_line --index 2 '- [ ] a false friend #aid'
}

@test "toggle_ai is a no-op on a missing file or a non-numeric line" {
  setup_sheet
  run toggle_ai "$BATS_TEST_TMPDIR/nope.md" 1
  assert_success
  toggle_ai "$SHEET" ""
  run sed -n '1p' "$SHEET"
  assert_output '- [ ] plain task'
}

# ── _sprint_items: the blackboard parser ────────────────────────────────────

# `sync`/the bridge decide what to SHOW from this. Two bugs here rendered a live wave as
# six phantom rows and zero real ones, while it sat waiting on a human.

mk_board() {
  BOARD_DIR="$HOME/.agent/plans/probe"; mkdir -p "$BOARD_DIR"
  cat > "$BOARD_DIR/sprint-2026-07-27.md"
}

@test "_sprint_items stops at the next H2 instead of eating later tables" {
  # NEGATIVE CONTROL: `cols` used to latch on the first ticket+status header, so the wave
  # schema's `## Wave gate` table (Step|Gate|Status|Evidence) was parsed with the queue's
  # column indices and rendered as phantom work items.
  mk_board <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a real bug | queued |

## Wave gate
| Step | Gate | Status | Evidence |
|------|------|--------|----------|
| 1 | freshness | — | |
| 2 | full e2e | — | |
B
  run bash -c 'source "$COCKPIT"; _sprint_items probe | wc -l'
  assert_output '1'
}

@test "_sprint_items does not emit the wave-gate steps as work items" {
  mk_board <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a real bug | queued |

## Wave gate
| Step | Gate | Status | Evidence |
|------|------|--------|----------|
| 1 | freshness | — | |
B
  run bash -c 'source "$COCKPIT"; _sprint_items probe'
  refute_output --partial 'freshness'
}

@test "_sprint_items renders a PROPOSED row whose ticket cell is still empty" {
  # NEGATIVE CONTROL: a wave writes its stub board BEFORE the approval gate, so every row
  # has an empty Ticket cell. Skipping those hid the entire proposal while the wave waited.
  mk_board <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 |  | ALW is not searchable | queued |
| 2 |  | accepts filters are a no-op | queued |
B
  run bash -c 'source "$COCKPIT"; _sprint_items probe | wc -l'
  assert_output '2'
}

@test "a proposed row is keyed by its row number so it stays addressable" {
  mk_board <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 |  | ALW is not searchable | queued |
B
  run bash -c 'source "$COCKPIT"; _sprint_items probe'
  assert_output --partial '~1'
}

@test "_sprint_items still drops the header row itself" {
  mk_board <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a real bug | queued |
B
  run bash -c 'source "$COCKPIT"; _sprint_items probe'
  refute_output --partial 'Title'
}

@test "a VERSION-named board is found, not just a date-named one" {
  # A wave IS a patch version, so its board is `sprint-v1.10.1.md`. Every consumer finds a
  # board by globbing `sprint-*.md` and taking the newest by MTIME -- five of them
  # (_sprint_items, wave-session's blackboard_of, captain-watchdog, delivery-loop,
  # wave-start). Sorting by NAME anywhere in that set would have made the rename silently
  # pick the wrong board, and `sprint-2026-07-27.md` sorts after `sprint-v...` in some
  # collations but before it in others.
  BOARD_DIR="$HOME/.agent/plans/probe"; mkdir -p "$BOARD_DIR"
  cat > "$BOARD_DIR/sprint-v1.10.1.md" <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a versioned wave item | in-progress |
B
  run bash -c 'source "$COCKPIT"; _sprint_items probe'
  assert_output --partial 'a versioned wave item'
}

@test "the NEWEST board wins regardless of how the two are named" {
  # Mixed old/new naming during the transition: an old date board and a new version board
  # in the same dir. The one written last is the live one.
  BOARD_DIR="$HOME/.agent/plans/probe"; mkdir -p "$BOARD_DIR"
  cat > "$BOARD_DIR/sprint-2026-07-27.md" <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | the old dated wave | in-progress |
B
  sleep 1.1   # mtime granularity: ls -1t must be able to tell them apart
  cat > "$BOARD_DIR/sprint-v1.10.1.md" <<'B'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 602 | the current wave | in-progress |
B
  run bash -c 'source "$COCKPIT"; _sprint_items probe'
  assert_output --partial 'the current wave'
  refute_output --partial 'the old dated wave'
}

# ── view mode ────────────────────────────────────────────────────────────────

@test "read_mode defaults to tasks and toggle_mode cycles all three views" {
  assert_equal "$(read_mode)" 'tasks'
  toggle_mode; assert_equal "$(read_mode)" 'factory'
  toggle_mode; assert_equal "$(read_mode)" 'usage'
  toggle_mode; assert_equal "$(read_mode)" 'tasks'
}

@test "a mode file naming a retired view falls back to tasks" {
  # `agents` and `bridge` were real modes until the factory view replaced both. A mode
  # file written by an older version must not leave `a` pressing against a dead name.
  local m
  for m in agents bridge; do
    printf '%s' "$m" > "$MODEF"
    toggle_mode; assert_equal "$(read_mode)" 'tasks'
  done
}

@test "an unreadable mode file falls back to tasks rather than wedging the cycle" {
  # toggle_mode's last arm is `*)`, not `usage)`, so a garbage mode lands somewhere a
  # renderer answers to instead of leaving `a` pressing against a name nothing handles.
  printf 'nonsense' > "$MODEF"
  toggle_mode; assert_equal "$(read_mode)" 'tasks'
}

@test "read_section defaults to personal" {
  assert_equal "$(read_section)" 'personal'
}

# ── _feed_gist / _ask_gist: what a project row actually says ─────────────────
#
# The bridge row used to carry the summary's STATUS block: prose an LLM writes and nothing
# refreshes. On the live board it read `v1.8.15 live (2026-06-30)` for three weeks while
# the project shipped v1.10.0 and opened v1.10.1. These two helpers replace it with counts
# taken from the AUTO block, which lab-sync regenerates, and with the one sentence of an
# ask you actually have to answer.


mk_summary() { SUMMARY="$BATS_TEST_TMPDIR/summary.md"; cat > "$SUMMARY"; }

@test "_feed_gist counts what is shipping, open and in flight" {
  mk_summary <<'S'
<!-- AUTO:START -->
**shipped `alpha-v1.10.0`** (2026-07-18)

**Shipping next** — merged to `develop` since `alpha-v1.10.0`:
- fix: one
- fix: two

**In progress** (tracker):
- Area: a ticket
- Area: another ticket

**In flight** (open PRs)
- #1093 docs: a doc
<!-- AUTO:END -->
S
  run _feed_gist "$SUMMARY"
  assert_output 'shipped v1.10.0, 2 to ship, 2 open, 1 PR'
}

@test "the product prefix is stripped from a monorepo tag" {
  # `alpha-v1.10.0` on a row already labelled `alpha` is just noise.
  mk_summary <<'S'
<!-- AUTO:START -->
**shipped `alpha-v1.10.0`** (2026-07-18)
<!-- AUTO:END -->
S
  run _feed_gist "$SUMMARY"
  assert_output 'shipped v1.10.0'
}

@test "an elided ticket list reports the REAL total, not the visible rows" {
  # `- …(+10 more)` is itself a bullet. Counting it as a ticket AND adding its number is an
  # off-by-one in the only direction nobody would catch: the total still looks plausible.
  mk_summary <<'S'
<!-- AUTO:START -->
**In progress** (tracker):
- Area: one
- Area: two
- …(+10 more)
<!-- AUTO:END -->
S
  run _feed_gist "$SUMMARY"
  assert_output '12 open'
}

@test "_feed_gist is silent for a project with no AUTO block" {
  # It must fall back to the old STATUS line rather than blanking the row.
  mk_summary <<'S'
# a project
just prose, never lab-synced.
S
  run _feed_gist "$SUMMARY"
  assert_output ''
}

@test "_feed_gist is silent on a missing file" {
  run _feed_gist "$BATS_TEST_TMPDIR/nope.md"
  assert_success
  assert_output ''
}

@test "_feed_gist omits a section that has nothing in it" {
  mk_summary <<'S'
<!-- AUTO:START -->
**shipped `alpha-v2.0.0`** (2026-07-18)

**Shipping next** — merged since:

**In flight** (open PRs)
S
  run _feed_gist "$SUMMARY"
  assert_output 'shipped v2.0.0'
}

@test "_ask_gist keeps the QUESTION, which an agent writes LAST" {
  # The live wave posted ~900 characters of findings and closed with the one thing needing
  # an answer. Head-truncation would have cut off exactly that part.
  run _ask_gist "Wave 2026-07-27: 3 items -> 3 tickets, but NOT the ones on the sheet. (a) already shipped. (b) the real gap is search. (c) a prod ops action, recommend trimming. Create the 3 tickets and cut the branch?"
  assert_output 'Create the 3 tickets and cut the branch?'
}

@test "_ask_gist leaves a short question alone" {
  run _ask_gist "PR #1036 is green, merge it?"
  assert_output 'PR #1036 is green, merge it?'
}

@test "_ask_gist truncates when there is no trailing question" {
  run bash -c "$(declare -f _ask_gist); _ask_gist 'Wave stopped before creating anything: 1 item, 0 tickets. Two hard blocks. The tracker is missing and the pass is headless.' | wc -c"
  assert_output '88'   # 85 chars + the ellipsis, no trailing newline
}

@test "_ask_gist collapses newlines and tabs so a row cannot break the wire" {
  # Field 7 is the DISPLAY column of a tab-separated row: a stray tab shifts every column.
  run _ask_gist "$(printf 'one\ttwo\nthree?')"
  assert_output 'one two three?'
}

@test "_ask_gist ignores a trailing question that is really a whole paragraph" {
  # A long final clause is not a summary; fall back to truncation rather than emit a wall.
  run bash -c "$(declare -f _ask_gist); _ask_gist 'Some findings here. Given all of the above and the fact that nothing else was reachable, should we now go ahead and create every one of the proposed tickets and cut the branch?' | wc -c"
  assert_output '88'   # 85 chars + the ellipsis, no trailing newline
}

# ── _status_gist: the ONE thing a project header says, in every view ──────────
#
# The feed-over-prose fix landed in the bridge only, inlined there. The tasks list — the
# view you are looking at most of the time — kept passing the raw STATUS column straight
# to _subheader, so it showed the stale prose, or nothing at all for the many projects
# that have no STATUS line. These pin the precedence to one helper all three views call.

@test "_status_gist prefers the live feed over the STATUS prose" {
  mk_summary <<'S'
<!-- AUTO:START -->
**shipped `alpha-v1.10.0`** (2026-07-18)

**In flight** (open PRs)
- #1093 docs: a doc
<!-- AUTO:END -->
S
  run _status_gist "$SUMMARY" "_2026-06-30_ - v1.8.15 live"
  assert_output 'shipped v1.10.0, 1 PR'
}

@test "_status_gist falls back to STATUS when a project was never lab-synced" {
  mk_summary <<'S'
# a project
just prose.
S
  run _status_gist "$SUMMARY" "steady"
  assert_output 'steady'
}

@test "_status_gist is empty when there is neither a feed nor a status" {
  run _status_gist "$BATS_TEST_TMPDIR/nope.md" ""
  assert_success
  assert_output ''
}

@test "_feed_gist reads the sibling summary.md when handed a project SHEET" {
  # `notes projects` hands back README.md (the sheet, where the tasks live) for a
  # sheet-model project, while lab-sync writes the feed into summary.md beside it. Reading
  # only the path we were given blanked the status of every such project — the feed was
  # one file away in the same directory the whole time.
  local dir="$BATS_TEST_TMPDIR/proj"; mkdir -p "$dir"
  printf '# a project\nVersion: v0.0.2\n' > "$dir/README.md"
  cat > "$dir/summary.md" <<'S'
<!-- AUTO:START -->
**shipped `cockpit-v0.0.1`** (2026-07-18)

**In progress** (tracker):
- Area: a ticket
<!-- AUTO:END -->
S
  run _feed_gist "$dir/README.md"
  assert_output 'shipped v0.0.1, 1 open'
}

@test "a sheet with its OWN feed does not get overwritten by a sibling summary.md" {
  local dir="$BATS_TEST_TMPDIR/proj2"; mkdir -p "$dir"
  cat > "$dir/README.md" <<'S'
<!-- AUTO:START -->
**shipped `cockpit-v9.9.9`** (2026-07-18)
<!-- AUTO:END -->
S
  cat > "$dir/summary.md" <<'S'
<!-- AUTO:START -->
**shipped `cockpit-v0.0.1`** (2026-07-18)
<!-- AUTO:END -->
S
  run _feed_gist "$dir/README.md"
  assert_output 'shipped v9.9.9'
}

@test "_feed_gist reads the REPO-LESS version line, not just a git tag" {
  # A lab project with frozen versions but no git tag behind it gets a different sentence
  # from lab-sync: `**`name` · v0.0.1** — _(no git tag resolved)_`. Reading only the
  # `shipped` shape is why every personal project rendered a blank status while its own
  # feed named a version two lines up.
  mk_summary <<'S'
<!-- AUTO:START -->
**`notes-cockpit` · v0.0.1** — _(no git tag resolved)_

**In flight** (open PRs)
- #166 fix: a fix
<!-- AUTO:END -->
S
  run _feed_gist "$SUMMARY"
  assert_output 'shipped v0.0.1, 1 PR'
}

@test "a real git tag still wins over the repo-less line" {
  mk_summary <<'S'
<!-- AUTO:START -->
**shipped `alpha-v1.10.0`** (2026-07-18)
**`alpha` · v0.0.1** — _(no git tag resolved)_
<!-- AUTO:END -->
S
  run _feed_gist "$SUMMARY"
  assert_output 'shipped v1.10.0'
}

# ── attention_counts: the sidebar's "how many things want you" badge ─────────
# `t++` used to sit INSIDE the `p!=""` guard, so an ask that could not be bucketed into a
# profile was counted in no section AND missing from the `all` total. Bucketing is
# genuinely best-effort - the map is built from vault projects and an ask can name a repo
# instead - but the TOTAL is not: a question nobody can file is still a question, and the
# one number whose job is "how many things want you" was quietly short.

# stub_asks <rows...> -- each row: id<TAB>project<TAB>profile<TAB>...
stub_asks() {
  local body="" r
  for r in "$@"; do body+="$r"$'\n'; done
  printf '#!/usr/bin/env bash\n[ "$1" = list ] && printf %s "%s"\nexit 0\n' "'%s'" "$body" \
    > "$SANDBOX/bin/agent-ask"
  chmod +x "$SANDBOX/bin/agent-ask"
}

@test "an ask that maps to no profile still counts toward the all total" {
  # The regression, in the exact live shape: every ask under ~/.agent/asks/bnb-platform
  # carries an empty profile column, and bnb-platform is a REPO, not a vault project, so
  # it appears in no profile map.
  stub_asks $'A1\tbnb-platform\t\tpending\tgate\tq?\tapprove\t-'
  run attention_counts
  assert_success
  assert_output --partial 'all 1'
}

@test "an unbucketable ask is counted but not attributed to a section" {
  # Counting is unconditional; bucketing stays guarded. Asserting both directions so a
  # future fix cannot "fix" the total by inventing a bogus section for it.
  stub_asks $'A1\tbnb-platform\t\tpending\tgate\tq?\tapprove\t-'
  run attention_counts
  assert_output --partial 'all 1'
  refute_output --partial 'bnb-platform 1'
}

@test "bucketable and unbucketable asks both land in the total" {
  # Rule of three: a mix must sum, or the badge lies whenever the two kinds coexist.
  stub_asks $'A1\tbnb-platform\t\tpending\tgate\tq?\tapprove\t-' \
            $'A2\tcockpit\tpersonal\tpending\tgate\tq?\tapprove\t-' \
            $'A3\tnotes\tpersonal\tpending\tgate\tq?\tapprove\t-'
  run attention_counts
  assert_output --partial 'all 3'
  assert_output --partial 'personal 2'
}

@test "no pending asks yields no total line at all" {
  # `all 0` would render a badge for nothing.
  stub_asks
  run attention_counts
  assert_success
  refute_output --partial 'all'
}
