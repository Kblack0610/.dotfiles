#!/usr/bin/env bats
# tmux-harpoon (harpoon.sh): session slots, Prefix+a s / M-1..M-4 / Prefix+E.
#
# integ tier: the script runs against the recording tmux and tmx stubs, so each jump
# assertion is "which command did it issue". The crossing itself is tmx's contract,
# covered by tmx_back.bats.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  H="$REPO_ROOT/.local/src/tmux/harpoon.sh"
  # sandbox_init pins XDG_STATE_HOME inside the sandbox.
  LIST="$XDG_STATE_HOME/tmx/harpoon"
  export TMUX="/tmp/fake,1,0"
}

# at <server> <session> -- where the stub says this client is sitting.
at() { export STUB_SOCKET="/tmp/tmux-1000/$1" STUB_SESSION="$2" STUB_WINDOW_INDEX=0; }

pinned() {
  mkdir -p "${LIST%/*}"
  : > "$LIST"
  while [ $# -gt 0 ]; do printf '%s\t%s\n' "$1" "$2" >> "$LIST"; shift 2; done
}

@test "toggle appends the current session, keyed by server and name" {
  at hub daily
  run "$H" toggle
  assert_success
  assert_output --partial "daily -> slot 1"
  at lab work
  run "$H" toggle
  assert_output --partial "work -> slot 2"
  assert_equal "$(cat "$LIST")" "$(printf 'hub\tdaily\nlab\twork')"
}

@test "toggle on a pinned session unpins it and closes the gap" {
  pinned hub daily lab work hub notes
  at lab work
  run "$H" toggle
  assert_success
  assert_output --partial "unpinned work"
  assert_equal "$(cat "$LIST")" "$(printf 'hub\tdaily\nhub\tnotes')"
}

@test "a session of the same name on another server is a different pin" {
  pinned hub work
  at lab work
  run "$H" toggle
  assert_output --partial "work -> slot 2"
}

@test "jump in the same server is a switch-client, not a hop" {
  pinned hub daily hub notes
  at hub daily
  run "$H" jump 2
  assert_success
  assert_called 'tmux switch-client -t =notes'
  assert_not_called 'tmx goto'
}

@test "jump to another server hands the hop to tmx goto" {
  pinned hub daily lab work
  at hub daily
  run "$H" jump 2
  assert_success
  assert_called 'tmx goto lab work'
  assert_not_called 'switch-client'
}

@test "jump to a session that is not running goes through tmx, which can wake it" {
  pinned hub daily hub notes
  printf 'daily\n' > "$NOTES_FIXTURE/tmux.sessions"
  at hub daily
  run "$H" jump 2
  assert_called 'tmx goto hub notes'
  assert_not_called 'switch-client'
}

@test "an empty slot says so and exits 0, so run-shell shows no error popup" {
  pinned hub daily
  at hub daily
  run "$H" jump 3
  assert_success
  assert_output --partial "slot 3 is empty"
  assert_not_called 'switch-client'
  assert_not_called 'tmx goto'
}

@test "jump to the session you are already in does nothing" {
  pinned hub daily
  at hub daily
  run "$H" jump 1
  assert_success
  assert_not_called 'switch-client'
  assert_not_called 'tmx goto'
}

@test "blank lines left by the menu do not shift the slots" {
  mkdir -p "${LIST%/*}"
  printf 'hub\tdaily\n\n\nlab\twork\n' > "$LIST"
  at hub daily
  run "$H" jump 2
  assert_called 'tmx goto lab work'
}

@test "menu writes back what the editor saved, minus blanks and duplicates" {
  pinned hub daily lab work
  # An "editor" that reverses the list and adds a blank line and a duplicate.
  cat > "$SANDBOX/ed" <<'EOF'
#!/usr/bin/env bash
{ printf '\n'; tac "$1"; tail -1 "$1"; } > "$1.new" && mv "$1.new" "$1"
EOF
  chmod +x "$SANDBOX/ed"
  EDITOR="$SANDBOX/ed" run "$H" menu
  assert_success
  assert_equal "$(cat "$LIST")" "$(printf 'lab\twork\nhub\tdaily')"
}

@test "menu in nvim maps Esc and q to save and close" {
  pinned hub daily
  mkdir -p "$SANDBOX/edbin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/nvim.args"\n' "$SANDBOX" > "$SANDBOX/edbin/nvim"
  chmod +x "$SANDBOX/edbin/nvim"
  EDITOR="$SANDBOX/edbin/nvim" run "$H" menu
  assert_success
  run cat "$SANDBOX/nvim.args"
  assert_output --partial 'nnoremap <buffer> <Esc> <Cmd>wq<CR>'
  assert_output --partial 'nnoremap <buffer> q <Cmd>wq<CR>'
}
