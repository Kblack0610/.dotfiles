#!/usr/bin/env bats
# focus-lib.sh: the one parser for the daily note's `## Focus` section, shared by the
# session preflight (turn 1) and the reconcile gate (end of turn).
#
# These tests exist because the two ends drifted once already: the preflight matched only
# `- [ ]` and silently dropped every in-progress `- [/]` item -- hiding exactly the task
# you were working on. Every state the checkbox can hold is pinned here.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$REPO_ROOT/.config/shared-hooks/focus-lib.sh"
  NOTE="$HOME/note.md"
}

# write_focus <body-lines...> -- a daily note whose Focus section is the given lines,
# followed by a second H2 that must NOT be picked up.
write_focus() {
  { echo '# 2026-07-26'
    echo
    echo '## Focus'
    printf '%s\n' "$@"
    echo
    echo '## Log'
    echo '- [ ] a todo that lives under a different heading'
  } > "$NOTE"
}

items() { focus_body "$NOTE" | focus_items "$1"; }

# ── section scoping ──────────────────────────────────────────────────────────

@test "focus_body stops at the next H2" {
  write_focus '- [ ] inside focus'
  run focus_body "$NOTE"
  assert_success
  assert_output --partial 'inside focus'
  refute_output --partial 'different heading'
}

@test "focus_body on a missing file is empty, not an error" {
  run focus_body "$HOME/nope.md"
  assert_success
  assert_output ''
}

@test "focus_body on a note with no Focus section is empty" {
  printf '# 2026-07-26\n\n## Log\n- [ ] elsewhere\n' > "$NOTE"
  run focus_body "$NOTE"
  assert_output ''
}

# ── checkbox states ──────────────────────────────────────────────────────────

@test "open items are returned for state ' '" {
  write_focus '- [ ] first thing' '- [ ] second thing'
  run items ' '
  assert_line '- first thing'
  assert_line '- second thing'
}

@test "in-progress items are returned for state '/' -- the regression this lib was cut for" {
  write_focus '- [/] the thing i am on' '- [ ] something else'
  run items '/'
  assert_output '- the thing i am on'
}

@test "the two unfinished states do not bleed into each other" {
  write_focus '- [/] in progress' '- [ ] open' '- [x] done'
  run items ' '
  assert_output '- open'
  run items '/'
  assert_output '- in progress'
  run items 'x'
  assert_output '- done'
}

@test "done items are never returned as unfinished" {
  write_focus '- [x] already shipped'
  run items ' '
  assert_output ''
  run items '/'
  assert_output ''
}

# ── cleaning ─────────────────────────────────────────────────────────────────

@test "the carry marker is stripped but the staleness age survives" {
  write_focus '- [ ] carried thing (9d) <!-- since:2026-07-17 -->'
  run items ' '
  assert_output '- carried thing (9d)'
}

@test "trailing tags are stripped" {
  write_focus '- [ ] urgent thing (2d)  #urgent'
  run items ' '
  assert_output '- urgent thing (2d)'
}

@test "an empty checkbox line is not an item" {
  # A hand-edit leaves these behind; counting them inflates every total by one.
  write_focus '- [ ] ' '- [ ]' '- [ ] real item'
  run items ' '
  assert_output '- real item'
}

@test "indented sub-items are items, and keep their indent" {
  # Nesting is meaningful in the note, so the indent survives into the rendered line.
  write_focus '  - [ ] nested thing'
  run items ' '
  assert_output '  - nested thing'
}

@test "a '/' in the item text does not break the in-progress pattern" {
  # The lib uses ',' as its sed delimiter precisely so this needs no escaping.
  write_focus '- [/] fix a/b/c path handling'
  run items '/'
  assert_output '- fix a/b/c path handling'
}

# ── counting ─────────────────────────────────────────────────────────────────

@test "focus_count counts real items and ignores blank lines" {
  write_focus '- [ ] one' '- [ ] two' '- [ ] three'
  run bash -c "source '$REPO_ROOT/.config/shared-hooks/focus-lib.sh'; focus_body '$NOTE' | focus_items ' ' | focus_count"
  assert_output '3'
}

@test "focus_count of an empty stream is 0, not 1" {
  run bash -c "source '$REPO_ROOT/.config/shared-hooks/focus-lib.sh'; printf '' | focus_count"
  assert_output '0'
}

# ── note resolution ──────────────────────────────────────────────────────────

@test "focus_daily_note falls back to the conventional path when notes has no answer" {
  # The sandbox stub answers `path` with nothing, so the fallback is what we should get.
  run focus_daily_note
  assert_output "$HOME/.notes/journal/daily/$(date +%F).md"
}
