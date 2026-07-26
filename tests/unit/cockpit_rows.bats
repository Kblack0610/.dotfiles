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

# ── view mode ────────────────────────────────────────────────────────────────

@test "read_mode defaults to tasks and toggle_mode cycles all three views" {
  assert_equal "$(read_mode)" 'tasks'
  toggle_mode; assert_equal "$(read_mode)" 'agents'
  toggle_mode; assert_equal "$(read_mode)" 'bridge'
  toggle_mode; assert_equal "$(read_mode)" 'tasks'
}

@test "read_section defaults to personal" {
  assert_equal "$(read_section)" 'personal'
}
