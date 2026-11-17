#!/usr/bin/env bats
# Tier 3: Prefix+k (notes-find.sh) through real fzf on a real tmux server, in the side layout it
# opens with. Container only, like every ui test. The ranking is the CLI's (stubbed here); this
# checks what the picker draws: one row per hit, and a preview opened on the hit's line even when
# the paragraphs above it wrap.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_shim

  VAULT="$SANDBOX/vault"
  NOTE="$VAULT/self/life/gifts.md"
  mkdir -p "${NOTE%/*}"
  local para i
  para="$(printf 'a long paragraph that wraps across the preview %.0s' 1 2 3 4 5)"
  {
    echo 'TOP-OF-NOTE'
    for i in $(seq 2 59); do echo "$i $para"; done
    echo 'HIT-LINE the kt gift list'
    for i in $(seq 61 90); do echo "$i $para"; done
  } >"$NOTE"
  printf '#!/bin/sh\nprintf "%%s\\t60\\t9.0\\tKt gifts\\tHIT-LINE the kt gift list\\n" "%s"\n' "$NOTE" \
    >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
}

teardown() { ui_teardown; }

@test "a hit is one row of title and folder, and the preview opens on its line past wrapped prose" {
  TM_WIDTH=144 TM_HEIGHT=31 tmux_start env NOTES_FIND_VAULT="$VAULT/" \
    "$REPO_ROOT/.local/src/tmux/notes-find.sh"
  wait_until 'screen_has "find >"'
  tmux_type 'kt gift'
  wait_until 'screen_has "HIT-LINE"'
  screen_matches 'Kt gifts +self/life$|Kt gifts +self/life +│'
  # The hit's text shows once, in the preview: the row carries no snippet.
  [ "$(screen | grep -c 'HIT-LINE')" -eq 1 ]
  screen_lacks 'TOP-OF-NOTE'
}
