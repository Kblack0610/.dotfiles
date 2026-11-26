#!/usr/bin/env bats
# inbox-epics.sh: a row keeps an #of/ only when it names an open epic of the row's own project.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.local/lib/inbox-epics.sh"
  BOARD='{"rows": [
    {"id": "gm-1", "project": "game", "type": "epic", "state": "open", "text": "epic(ui): menus"},
    {"id": "gm-2", "project": "game", "type": "epic", "state": "done", "text": "epic(ui): old"},
    {"id": "gm-3", "project": "game", "type": "fix", "state": "open", "text": "fix(ui): a row"},
    {"id": "ap-1", "project": "app", "type": "epic", "state": "doing", "text": "epic(api): auth"},
    {"id": null, "project": "app", "type": "epic", "state": "open", "text": "epic(api): no id"}]}'
  EPICS="$(epics_open "$BOARD")"
}

@test "only open epics with an id are listed" {
  assert_equal "$EPICS" "$(printf 'gm-1\tgame\tepic(ui): menus\nap-1\tapp\tepic(api): auth')"
  assert_equal "$(epics_of app "$EPICS")" "$(printf 'ap-1\tapp\tepic(api): auth')"
}

@test "own_parent names the line's own #of/ only when it is an open row of the project" {
  run own_parent 'feat(ui): a child #of/gm-3 #size/s' game "$BOARD"
  assert_success
  assert_output 'gm-3'
  run own_parent 'feat(ui): a child #of/gm-1' game "$BOARD"
  assert_output 'gm-1'
  for id in gm-2 gm-404 ap-1; do
    run own_parent "feat(ui): a child #of/$id" game "$BOARD"
    assert_failure
    assert_output ''
  done
  run own_parent 'feat(ui): no parent at all' game "$BOARD"
  assert_failure
}

@test "row_checked files a split's rows under the line's own parent, over the model's epic or none" {
  local line='feat(ui): the stage cells #of/gm-3 #agent'
  run row_checked 'feat(ui): show the cells #size/s #of/gm-1' game "$EPICS" "$line" "$BOARD"
  assert_output 'feat(ui): show the cells #size/s #of/gm-3'
  run row_checked 'feat(ui): show the legend #size/s' game "$EPICS" "$line" "$BOARD"
  assert_output 'feat(ui): show the legend #size/s #of/gm-3'
  # negative controls: an empty row, an epic row, and a line whose #of/ is no open row of the project
  run row_checked '' game "$EPICS" "$line" "$BOARD"
  assert_output ''
  run row_checked 'epic(ui): a new pass #of/gm-1' game "$EPICS" "$line" "$BOARD"
  assert_output 'epic(ui): a new pass #of/gm-1'
  run row_checked 'feat(ui): show the cells #of/gm-1' game "$EPICS" 'a line #of/gm-2' "$BOARD"
  assert_output 'feat(ui): show the cells #of/gm-1'
  run row_checked 'feat(ui): show the cells #of/gm-3' game "$EPICS" 'a line' "$BOARD"
  assert_output 'feat(ui): show the cells'
}

@test "row_checked keeps the line's #after/ on every row and its #pts/ on a one-row filing (ar-5551)" {
  local line='feat(ui): the stage cells #of/gm-3 #pts/5 #after/gm-9 #agent'
  run row_checked 'feat(ui): show the cells #size/m #pts/3' game "$EPICS" "$line" "$BOARD"
  assert_output 'feat(ui): show the cells #size/m #of/gm-3 #pts/5 #after/gm-9'
  run row_checked 'feat(ui): show the cells #size/m' game "$EPICS" "$line" "$BOARD" 1
  assert_output 'feat(ui): show the cells #size/m #of/gm-3 #pts/5 #after/gm-9'
  # a line split into two rows: each waits, each keeps its own size
  run row_checked 'feat(ui): show the legend #pts/2' game "$EPICS" "$line" "$BOARD" 2
  assert_output 'feat(ui): show the legend #pts/2 #of/gm-3 #after/gm-9'
  # negative controls: a gate the row already has is not doubled, and an empty row stays empty
  run row_checked 'feat(ui): show the cells #after/gm-9' game "$EPICS" "$line" "$BOARD" 2
  assert_output 'feat(ui): show the cells #after/gm-9 #of/gm-3'
  run row_checked '' game "$EPICS" "$line" "$BOARD"
  assert_output ''
}

@test "unparented: a new epic is for a row with no parent" {
  run unparented 'fix(ui): a #of/gm-3' 'fix(ui): b'
  assert_success
  run unparented 'fix(ui): a #of/gm-3' 'fix(ui): b #size/s #of/gm-1'
  assert_failure
  run unparented
  assert_failure
}

@test "a row keeps an open epic of its project, tags in place" {
  run epic_checked 'fix(ui): a bug #size/s #of/gm-1 #high' game "$EPICS"
  assert_output 'fix(ui): a bug #size/s #of/gm-1 #high'
}

@test "an invented, closed, non-epic or other project's parent comes off and the words stay" {
  for id in gm-404 gm-2 gm-3 ap-1; do
    run epic_checked "fix(ui): a bug #of/$id #size/s" game "$EPICS"
    assert_output 'fix(ui): a bug #size/s'
  done
}

@test "a row with no #of/ and a word that globs pass through, with no epics at all too" {
  run epic_checked 'fix(ui): the * menu' game ''
  assert_output 'fix(ui): the * menu'
  run epic_known gm-1 game ''
  assert_failure
  run epic_known '' game "$EPICS"
  assert_failure
}

@test "reparent_args: tag re-parents only an unparented row or one under its standing epic, onto a feature epic" {
  local epics
  epics="$(printf 'gm-1\tgame\tepic(ui): menus\ngm-5\tgame\tepic(ui): ui to standard\ngm-6\tgame\tepic(ci): ci to standard\nap-1\tapp\tepic(api): auth')"
  run reparent_args game '' gm-1 "$epics"
  assert_output $'--add\nof/gm-1'
  run reparent_args game '' gm-5 "$epics"
  assert_output $'--add\nof/gm-5'
  run reparent_args game gm-5 gm-1 "$epics"
  assert_output $'--remove\nof/gm-5\n--add\nof/gm-1'
  # negative controls: the same parent, a standing pick over a standing parent, a chosen parent
  # (a feature epic, or a split's row that is no epic), a pick that is no open epic of the project
  for args in 'gm-1 gm-1' 'gm-5 gm-6' 'gm-1 gm-5' 'gm-3 gm-1' ' gm-404' ' ap-1' 'gm-5 '; do
    run reparent_args game "${args%% *}" "${args#* }" "$epics"
    assert_failure
    assert_output ''
  done
}

@test "parent_word and no_parent read and strip the #of/ words, other tags in place" {
  assert_equal "$(parent_word 'fix(ui): a bug #of/gm-1 #size/s #of/gm-5')" gm-5
  assert_equal "$(parent_word 'fix(ui): a bug #size/s')" ''
  assert_equal "$(no_parent 'fix(ui): a bug #of/gm-1 #size/s #of/gm-5')" 'fix(ui): a bug #size/s'
}
