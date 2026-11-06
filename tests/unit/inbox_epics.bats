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
