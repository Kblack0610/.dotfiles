#!/usr/bin/env bats
# refs.sh -- Prefix+C-r, today's dated reference directory in a tmux window.
#
# integ tier: the script runs as a subprocess against the recording tmux stub, so the
# assertions are "which tmux command did it issue" plus "what did it do on disk". No real
# server is needed; the only tmux calls are select-window and new-window.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  REFS="$REPO_ROOT/.local/src/tmux/refs.sh"
  export REFS

  # A `notes` stand-in. The real CLI resolves refs-today through the active profile; what
  # this script owes is to ASK it (honouring --profile) and to create what it gets back.
  REFS_ROOT="$(dirname "$SANDBOX")/refs-root"
  export REFS_ROOT
  cat > "$SANDBOX/bin/notes" <<EOF
#!/usr/bin/env bash
prof=personal
if [ "\$1" = "--profile" ]; then prof="\$2"; shift 2; fi
[ "\$1" = "path" ] && [ "\$2" = "refs-today" ] || exit 1
printf '%s/%s/2026-08-26' "$REFS_ROOT" "\$prof"
EOF
  chmod +x "$SANDBOX/bin/notes"
}

calls() { cat "$NOTES_FIXTURE/calls.log" 2>/dev/null; }

@test "creates today's refs dir and opens it in a new window" {
  STUB_SELECT_WINDOW_RC=1 run "$REFS"
  assert_success
  [ -d "$REFS_ROOT/personal/2026-08-26" ]
  run calls
  assert_output --partial "new-window -n refs"
  assert_output --partial "$REFS_ROOT/personal/2026-08-26"
}

@test "an explicit profile picks that org's refs, not the active one" {
  STUB_SELECT_WINDOW_RC=1 run "$REFS" bnb
  assert_success
  [ -d "$REFS_ROOT/bnb/2026-08-26" ]
  [ ! -d "$REFS_ROOT/personal/2026-08-26" ]
}

@test "an existing refs window is reused, not stacked" {
  # The stub exits 0 for select-window by default, which is the window-exists case.
  run "$REFS"
  assert_success
  run calls
  assert_output --partial "select-window -t refs"
  refute_output --partial "new-window"
}

@test "the directory is created before the editor opens it" {
  # `notes path` resolves a path, it does not create one. Opening a missing dir drops
  # nvim into an unnamed buffer that reads as an empty refs day and is not one.
  STUB_SELECT_WINDOW_RC=1 run "$REFS"
  assert_success
  d=$(printf '%s\n' "$(calls)" | grep -n 'new-window' | cut -d: -f1)
  [ -n "$d" ]
  [ -d "$REFS_ROOT/personal/2026-08-26" ]
}

@test "no notes CLI is an error, not a window onto nothing" {
  # Removing the stub is not enough: the developer's real `notes` is still on PATH.
  rm -f "$SANDBOX/bin/notes"
  PATH="$SANDBOX/bin:/usr/bin:/bin" run "$REFS"
  assert_failure
  assert_output --partial "notes CLI not on PATH"
  run calls
  refute_output --partial "new-window"
}

@test "a notes that resolves nothing is an error, not a window onto \$HOME" {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/bin/notes"
  run "$REFS"
  assert_failure
  assert_output --partial "could not resolve"
  run calls
  refute_output --partial "new-window"
}
