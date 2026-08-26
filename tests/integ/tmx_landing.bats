#!/usr/bin/env bats
# `tmx root <world>` -- Prefix+N / Prefix+H, "take me to the top of this world".
#
# integ tier: servers.sh runs as a subprocess against the recording tmux stub, so every
# assertion is "which tmux command did it actually issue". Nothing here needs a real
# server -- the whole decision is made from the manifest plus two display-message reads,
# both of which the stub owns. servers.sh drives several REAL servers by -L, so it is
# container-only in the ui tier (see the harness skill); this is the tier that can run
# anywhere.
#
# The contract under test: a landing session is long-lived, so `root` has to RESTORE the
# world's page rather than just attach to whatever the pane was last used for. The page
# is whatever the manifest's startup command opens, which differs per world -- a literal
# path for lab, a date-derived one for hub.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  export TMX
  export XDG_STATE_HOME="$HOME/.local/state"
  export BACK_FILE="$XDG_STATE_HOME/tmx/back"

  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"

  # The manifest is whitespace-separated (`<name> <dir> [cmd...]`), so the DIR column
  # cannot contain a space - that is a property of the format, not of this change. The
  # sandbox root has one on purpose, so root the manifest dirs one level up.
  BASE="$(dirname "$SANDBOX")/worlds"
  mkdir -p "$BASE/bin"

  # The two real shapes, because the bug was that only the first one worked:
  #   hub  -> a DATE-DERIVED page, resolved by a command substitution at press time
  #   lab  -> a LITERAL path
  # Both pages carry a SPACE in their own filename: everything after the dir column is
  # the command, so the format allows it, and it is what catches an unescaped `:e`.
  LAB_PAGE="$BASE/lab projects/index.md"
  HUB_PAGE="$BASE/journal daily/today.md"
  export LAB_PAGE HUB_PAGE BASE
  mkdir -p "$(dirname "$LAB_PAGE")" "$(dirname "$HUB_PAGE")"
  : > "$LAB_PAGE"; : > "$HUB_PAGE"

  printf 'hub %s nvim "$(fake_notes_path)"\nnotes %s\n' "$BASE" "$BASE" \
    > "$TMUX_SERVERS_DIR/hub.conf"
  printf 'lab %s nvim "%s"\nplatform %s\n' "$BASE" "$LAB_PAGE" "$BASE" \
    > "$TMUX_SERVERS_DIR/lab.conf"

  # Stands in for `notes path`, so the hub case exercises a REAL command substitution
  # rather than a literal that happens to look like one.
  cat > "$BASE/bin/fake_notes_path" <<EOF
#!/usr/bin/env bash
printf '%s' "$HUB_PAGE"
EOF
  chmod +x "$BASE/bin/fake_notes_path"
  PATH="$BASE/bin:$PATH"; export PATH

  # The landing pane. Without it `list-panes` returns nothing and _refresh_landing
  # returns early, which would make every assertion below pass vacuously.
  printf '%%1\n' > "$NOTES_FIXTURE/tmux.panes"

  # `land`, not `root`: with $TMUX set, `root` only records the crumb and detaches with
  # `-E ... land <world> root`. The far side is where _refresh_landing actually runs, so
  # that is the subject. TMUX stays UNSET for the same reason land ignores it.
  unset TMUX
}

# The page as it is typed at vim's command line: spaces backslash-escaped. The sandbox
# path contains one on purpose.
vim_path() { printf '%s' "${1// /\\ }"; }

# What the subject actually told tmux to do.
calls() { cat "$NOTES_FIXTURE/calls.log" 2>/dev/null; }

# in <world> <session> -- the client is sitting on that world's landing session, so
# `root` refreshes in place instead of hopping.
in_landing() {
  export STUB_SOCKET="/tmp/tmux-1000/$1" STUB_SESSION="$2" STUB_WINDOW_INDEX=0
}

# --- the page comes from the manifest, per world ---

@test "root lab reopens the projects index when nvim is on some other file" {
  # THE BUG. The old rule only fired on a `journal/daily` pane title and only to swap a
  # stale daily for today's, so lab -- whose page is not a daily -- fell through to
  # "leave it alone" and Prefix+H never restored the index.
  in_landing lab lab
  STUB_PANE_CMD=nvim STUB_PANE_TITLE="neo-tree filesystem - (~/.notes/lab) - Nvim" \
    run "$TMX" land lab root
  assert_success
  run bash -c "cat '$NOTES_FIXTURE/calls.log'"
  assert_output --partial ":e $(vim_path "$LAB_PAGE")"
}

@test "root hub reopens today's daily, resolved at press time" {
  # The behaviour the old rule had, kept: the page is a command substitution, so a
  # long-lived session showing last week's note still lands on today's.
  in_landing hub hub
  STUB_PANE_CMD=nvim STUB_PANE_TITLE="2026-05-01.md" run "$TMX" land hub root
  assert_success
  run bash -c "cat '$NOTES_FIXTURE/calls.log'"
  assert_output --partial ":e $(vim_path "$HUB_PAGE")"
}

@test "the page is escaped out of insert mode before it is opened" {
  # `:e` typed into insert mode inserts the literal text into the buffer.
  in_landing lab lab
  STUB_PANE_CMD=nvim run "$TMX" land lab root
  assert_success
  run bash -c "grep -n 'send-keys' '$NOTES_FIXTURE/calls.log'"
  # Escape has to be the first send-keys, before the one carrying `:e`.
  esc=$(printf '%s\n' "$output" | grep -n 'Escape' | head -1 | cut -d: -f1)
  edit=$(printf '%s\n' "$output" | grep -n ':e ' | head -1 | cut -d: -f1)
  [ -n "$esc" ] && [ -n "$edit" ] && [ "$esc" -lt "$edit" ]
}

# --- the shell case, unchanged ---

@test "a pane back at a shell re-runs the manifest's startup command" {
  in_landing lab lab
  STUB_PANE_CMD=bash run "$TMX" land lab root
  assert_success
  run bash -c "cat '$NOTES_FIXTURE/calls.log'"
  assert_output --partial "nvim \"$LAB_PAGE\""
  # The shell branch RUNS the command; it must not also try to drive an editor.
  refute_output --partial ":e "
}

# --- what it must NOT do ---

@test "a world whose landing entry opens no file is left alone" {
  # A bare dir with no startup command. Nothing to restore, so root must attach and issue
  # no send-keys rather than invent a page. It has to be the FIRST entry: that is what
  # `_landing` resolves, regardless of which session the client is sitting on.
  printf 'lab %s\nplatform %s\n' "$BASE" "$BASE" > "$TMUX_SERVERS_DIR/lab.conf"
  in_landing lab lab
  STUB_PANE_CMD=nvim run "$TMX" land lab root
  assert_success
  run bash -c "grep -c 'send-keys' '$NOTES_FIXTURE/calls.log' || true"
  assert_output "0"
}

@test "a page the manifest names but that is missing is not opened" {
  # Better to leave the editor alone than to drop it into an empty unnamed buffer that
  # silently is not the index.
  rm -f "$LAB_PAGE"
  in_landing lab lab
  STUB_PANE_CMD=nvim run "$TMX" land lab root
  assert_success
  run bash -c "grep -c ':e ' '$NOTES_FIXTURE/calls.log' || true"
  assert_output "0"
}

@test "a pane running something that is not an editor is left alone" {
  # A long-running process in the landing pane is work, not a stale page.
  in_landing lab lab
  STUB_PANE_CMD=htop run "$TMX" land lab root
  assert_success
  run bash -c "grep -c 'send-keys' '$NOTES_FIXTURE/calls.log' || true"
  assert_output "0"
}

@test "a startup command with flags is not treated as a page" {
  # `nvim -p a b` opens two files; there is no single page to restore, and sending
  # `:e -p` would be nonsense.
  printf 'lab %s nvim -p "%s" "%s"\n' "$BASE" "$LAB_PAGE" "$HUB_PAGE" \
    > "$TMUX_SERVERS_DIR/lab.conf"
  in_landing lab lab
  STUB_PANE_CMD=nvim run "$TMX" land lab root
  assert_success
  run bash -c "grep -c ':e ' '$NOTES_FIXTURE/calls.log' || true"
  assert_output "0"
}
