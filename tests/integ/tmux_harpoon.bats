#!/usr/bin/env bats
# tmux-harpoon (harpoon.sh): window slots, Prefix+a / M-1..M-4 / Prefix+e.
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

# at <server> <session> [window_id [session_created [name]]] -- where the stub says this
# client is sitting.
at() {
  export STUB_SOCKET="/tmp/tmux-1000/$1" STUB_SESSION="$2" STUB_WINDOW_INDEX=0 \
    STUB_WINDOW_ID="${3:-@7}" STUB_SESSION_CREATED="${4:-1000}" STUB_WINDOW_NAME="${5:-zsh}"
}

# pinned <server> <session> ... -- 2-field lines: plain session pins, the pre-window format.
pinned() {
  mkdir -p "${LIST%/*}"
  : > "$LIST"
  while [ $# -gt 0 ]; do printf '%s\t%s\n' "$1" "$2" >> "$LIST"; shift 2; done
}

# pinw <server> <session> <window_id> <stamp> <name> -- append one window pin.
pinw() { mkdir -p "${LIST%/*}"; printf '%s\t%s\t%s\t%s\t%s\n' "$@" >> "$LIST"; }

# windows [<server>] -- the live windows list-windows reports, rows read from stdin.
windows() { cat > "$NOTES_FIXTURE/tmux.window_stamps${1:+.$1}"; }

@test "toggle appends the current window, keyed by server, session, id and stamp" {
  at hub daily
  run "$H" toggle
  assert_success
  assert_output --partial "daily:zsh -> slot 1"
  at lab work @3 2000 nvim
  run "$H" toggle
  assert_output --partial "work:nvim -> slot 2"
  assert_equal "$(cat "$LIST")" "$(printf 'hub\tdaily\t@7\t1000\tzsh\nlab\twork\t@3\t2000\tnvim')"
}

@test "two windows of one session take two slots" {
  at hub daily @1 1000 zsh
  run "$H" toggle
  at hub daily @2 1000 vim
  run "$H" toggle
  assert_output --partial "daily:vim -> slot 2"
  assert_equal "$(wc -l < "$LIST" | tr -d ' ')" 2
}

@test "toggle on a pinned window unpins it and closes the gap" {
  pinw hub daily @1 1000 zsh
  pinw lab work @3 1000 vim
  pinw hub notes @4 1000 zsh
  at lab work @3 1000 renamed-since
  run "$H" toggle
  assert_success
  assert_output --partial "unpinned work:renamed-since"
  assert_equal "$(cut -f2 "$LIST" | tr '\n' ' ')" "daily notes "
}

@test "a session of the same name on another server is a different pin" {
  pinw hub work @7 1000 zsh
  at lab work
  run "$H" toggle
  assert_output --partial "work:zsh -> slot 2"
}

@test "jump to a live window selects it, then switches to its session" {
  pinw hub daily @1 1000 zsh
  pinw hub daily @2 1000 vim
  printf '1000\t@1\tzsh\n1000\t@2\tvim\n' | windows
  at hub daily @1
  run "$H" jump 2
  assert_success
  assert_called 'tmux select-window -t =daily:@2'
  assert_called 'tmux switch-client -t =daily'
}

@test "jump from the pinned window itself does nothing" {
  pinw hub daily @2 1000 vim
  printf '1000\t@2\tvim\n' | windows
  at hub daily @2
  run "$H" jump 1
  assert_success
  assert_not_called 'switch-client'
  assert_not_called 'select-window'
}

@test "a recreated session reuses window ids, so a stale stamp lands on the session" {
  # Ids restart after a kill-server: @2 now exists again, but it is not the pinned window.
  pinw hub daily @2 1000 vim
  printf '2000\t@2\tsomething-else\n' | windows
  at hub notes
  run "$H" jump 1
  assert_called 'tmux switch-client -t =daily'
  assert_not_called 'select-window'
}

@test "a closed window lands on its session" {
  pinw hub daily @2 1000 vim
  printf '1000\t@1\tzsh\n' | windows
  at hub notes
  run "$H" jump 1
  assert_called 'tmux switch-client -t =daily'
  assert_not_called 'select-window'
}

@test "a window on another server goes to tmx goto as session:window" {
  pinw lab work @3 1000 nvim
  printf '1000\t@3\tnvim\n' | windows lab
  at hub daily
  run "$H" jump 1
  assert_success
  assert_called 'tmx goto lab work:@3'
}

@test "ls shows the live window name, and says when a window has gone" {
  pinw hub daily @2 1000 old-name
  pinw hub daily @9 1000 closed
  printf '1000\t@2\tnew-name\n' | windows
  at hub daily @2
  run "$H" ls
  assert_success
  assert_line --index 0 --partial '* 1  hub      daily:new-name'
  assert_line --index 1 --partial 'daily:closed  (window gone)'
}

@test "a session pin (2-field line) in the same server is a switch-client, not a hop" {
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

@test "a session pin to the session you are already in does nothing" {
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

@test "prefix+a and C-a pin the window; t and C-t open the window-tags table" {
  # The C- twins catch Ctrl still held from the C-b prefix, which otherwise lands on an
  # unbound key and looks like the bind "not working half the time".
  local k conf="$REPO_ROOT/.tmux.conf"
  for k in a C-a; do
    grep -qE "^bind $k run-shell \"\\\$HOME/.local/bin/tmux-harpoon toggle\"\$" "$conf" ||
      fail "prefix+$k is not the harpoon toggle"
  done
  for k in t C-t; do
    grep -qE "^bind $k switch-client -T tags\$" "$conf" || fail "prefix+$k does not open the tags table"
  done
  run grep -nE '^bind -T tags s ' "$conf"
  assert_failure
}
