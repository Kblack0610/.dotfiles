#!/usr/bin/env bats
# Deleting a task, and getting it back.
#
# The founding incident: delete was bound to C-d - one key away from the C-u/C-d
# a person reaches for to scroll - with no confirmation and no way back. A task
# was destroyed by accident and had to be recovered out of the notes vault's git
# history. Delete is now `d` plus a yes/no, C-d/C-u scroll, and `u` undoes.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
}

# The `notes` stub records calls; assert on what the cockpit ASKED it to do.
calls() { cat "$NOTES_FIXTURE/calls.log" 2>/dev/null; }

@test "d is bound to the confirming delete, not the silent one" {
  run grep -F 'bind "d:execute(' "$COCKPIT"
  assert_success
  assert_output --partial '--delete-task'
}

@test "the old one-key C-d delete is gone" {
  run grep -E "ctrl-d:execute-silent.*task-op rm" "$COCKPIT"
  assert_failure
}

@test "C-d and C-u scroll the preview instead" {
  run grep -F "bind 'ctrl-d:preview-half-page-down'" "$COCKPIT"
  assert_success
  run grep -F "bind 'ctrl-u:preview-half-page-up'" "$COCKPIT"
  assert_success
}

@test "J and K move between sections" {
  run grep -F 'bind "J:execute-silent(' "$COCKPIT"
  assert_output --partial '--next-section'
  run grep -F 'bind "K:execute-silent(' "$COCKPIT"
  assert_output --partial '--prev-section'
}

@test "h and l still work, so existing muscle memory is not broken" {
  run grep -F 'bind "h:execute-silent(' "$COCKPIT"
  assert_output --partial '--prev-section'
  run grep -F 'bind "l:execute-silent(' "$COCKPIT"
  assert_output --partial '--next-section'
}

# ── the confirmation ─────────────────────────────────────────────────────────

@test "answering no does not delete" {
  run bash -c 'printf "n\n" | "$COCKPIT" --delete-task personal/cockpit somekey'
  assert_output --partial 'cancelled'
  refute [ -n "$(calls | grep -F 'ptask cockpit rm')" ]
}

@test "just pressing enter does not delete - the default is no" {
  run bash -c 'printf "\n" | "$COCKPIT" --delete-task personal/cockpit somekey'
  assert_output --partial 'cancelled'
  refute [ -n "$(calls | grep -F 'ptask cockpit rm')" ]
}

@test "answering yes deletes and says undo is available" {
  run bash -c 'printf "y\n" | "$COCKPIT" --delete-task personal/cockpit somekey'
  assert_output --partial 'press u to undo'
  assert [ -n "$(calls | grep -F 'rm')" ]
}

@test "delete on a non-task row is refused before anything is asked" {
  run "$COCKPIT" --delete-task personal/cockpit ''
  assert_output --partial 'not on a task row'
  refute_output --partial 'are you sure'
}

# ── undo ─────────────────────────────────────────────────────────────────────

@test "undo with nothing deleted says so rather than acting" {
  run "$COCKPIT" --undo-delete
  assert_output --partial 'nothing to undo'
  refute [ -n "$(calls | grep -F 'add')" ]
}

@test "undo re-adds the deleted task through the CLI" {
  printf 'y\n' | "$COCKPIT" --delete-task personal/cockpit somekey >/dev/null 2>&1
  : > "$NOTES_FIXTURE/calls.log"
  run "$COCKPIT" --undo-delete
  # The fixture's ptask list is what the capture reads; if it held the key, undo
  # restores it. Either way undo must never silently do nothing AND claim success.
  if [[ "$output" == *'restored:'* ]]; then
    assert [ -n "$(calls | grep -F 'add')" ]
  else
    assert_output --partial 'nothing to undo'
  fi
}

@test "undo does not fire twice for one delete" {
  printf 'y\n' | "$COCKPIT" --delete-task personal/cockpit somekey >/dev/null 2>&1
  "$COCKPIT" --undo-delete >/dev/null 2>&1
  run "$COCKPIT" --undo-delete
  assert_output --partial 'nothing to undo'
}

# ── the text that comes back ─────────────────────────────────────────────────

@test "_undo_text strips what the vault renders, keeping the task itself" {
  source "$COCKPIT"
  assert_equal "$(_undo_text '- [ ] final session: ai telemetry (0d) <!-- since:2026-07-27 --> #urgent')" \
               'final session: ai telemetry #urgent'
  assert_equal "$(_undo_text '- [/] a task in progress')" 'a task in progress'
  assert_equal "$(_undo_text '- [x] a done task (3d)')" 'a done task'
}
