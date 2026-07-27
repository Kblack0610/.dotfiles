#!/usr/bin/env bats
# sessionizer.sh -- Prefix+f, the one picker that reaches outside the current tmux world.
#
# integ tier: the script runs as a subprocess against the recording tmux stub, so every
# assertion is "which tmux command did it actually issue". The fzf picker itself is not
# exercised here (there is nothing to assert about a picker's rendering that is not a test of
# the fake); the row source behind it, --list, is.
#
# This is the first panel migrated onto panel-lib.sh, and it was the worst conformer: no strict
# mode, a bare `| fzf` with no flags, no dependency check, an unquoted `[[ -z $TMUX ]]`, and a
# `pgrep tmux` probe standing in for the switch-vs-attach question.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SESSIONIZER="$REPO_ROOT/.local/src/tmux/sessionizer.sh"
  export SESSIONIZER

  # A fixture tree with THREE candidate roots, so a test can tell "found the right one" from
  # "found the only one". One root deliberately does not exist, to cover the filter.
  mkdir -p "$SANDBOX/roots/alpha/proj-one" \
    "$SANDBOX/roots/alpha/node_modules/should-be-pruned" \
    "$SANDBOX/roots/beta/my.dotted.project" \
    "$SANDBOX/roots/beta/.git/hooks"
  # COLON-separated, like PATH: $SANDBOX contains a space by design, and a space-delimited
  # list cannot express such a path at all. The first draft of the script used spaces and this
  # fixture is what exposed it.
  export SESSIONIZER_ROOTS="$SANDBOX/roots/alpha:$SANDBOX/roots/beta:$SANDBOX/roots/nonexistent"
}

# ── The name fold ────────────────────────────────────────────────────────────

@test "a dot in the directory name is folded to an underscore" {
  # tmux treats `.` as the window/pane separator in a target, so `-t my.project` addresses
  # window "project" of session "my". An unsanitised name silently addresses something else.
  run "$SESSIONIZER" --name "$SANDBOX/roots/beta/my.dotted.project"
  assert_success
  assert_output 'my_dotted_project'
}

@test "an ordinary name is passed through untouched" {
  run "$SESSIONIZER" --name "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_output 'proj-one'
}

@test "--name without a directory is rejected" {
  run "$SESSIONIZER" --name
  assert_failure
  assert_output --partial 'needs a directory'
}

# ── The row source ───────────────────────────────────────────────────────────

@test "--list finds the project directories under every existing root" {
  run "$SESSIONIZER" --list
  assert_success
  assert_line --partial 'roots/alpha/proj-one'
  assert_line --partial 'roots/beta/my.dotted.project'
}

@test "--list prunes the directories it is configured to prune" {
  run "$SESSIONIZER" --list
  assert_success
  refute_output --partial 'node_modules'
  refute_output --partial '.git'
}

@test "SESSIONIZER_PRUNE is actually read" {
  # Prove the config key changes behaviour rather than merely existing. With the default prune
  # list replaced by something irrelevant, node_modules must reappear.
  SESSIONIZER_PRUNE='nothing-matches-this' run "$SESSIONIZER" --list
  assert_output --partial 'node_modules'
}

@test "SESSIONIZER_DEPTH is actually read" {
  mkdir -p "$SANDBOX/roots/alpha/a/b/c/d/deep-one"
  SESSIONIZER_DEPTH=9 run "$SESSIONIZER" --list
  assert_output --partial 'deep-one'
  SESSIONIZER_DEPTH=1 run "$SESSIONIZER" --list
  refute_output --partial 'deep-one'
}

@test "--list fails loudly when no configured root exists" {
  # "Nothing to show" and "your config is wrong" must not print the same empty picker.
  SESSIONIZER_ROOTS="$SANDBOX/nope-one:$SANDBOX/nope-two" run "$SESSIONIZER" --list
  assert_failure
  assert_output --partial 'none of the configured roots exist'
}

# ── Landing in a session ─────────────────────────────────────────────────────

@test "inside tmux it switches the client rather than attaching" {
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_called 'switch-client -t proj-one'
  assert_not_called 'attach -t'
}

@test "outside tmux it attaches instead of issuing a doomed switch-client" {
  # The pre-migration bug: with a server already running, the old code created the session
  # detached and then called switch-client with no client attached, which fails. `pgrep tmux`
  # was never the right question -- $TMUX is.
  run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_called 'attach -t proj-one'
  assert_not_called 'switch-client'
}

@test "an existing session is reused, not recreated" {
  # The tmux stub answers has-session with rc 0, so the session always "exists". Creating one
  # anyway would clobber a live session's directory.
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_called 'has-session -t =proj-one'
  assert_not_called 'new-session'
}

@test "the session is addressed with the exact-match prefix" {
  # `has-session -t proj` would match a session merely PREFIXED with proj. The `=` makes it
  # exact, which is what keys ensure-vs-create correctly.
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_called 'has-session -t =proj-one'
}

@test "a dotted directory reaches tmux already folded" {
  # The end-to-end version of the fold test: what matters is the name tmux SEES.
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/beta/my.dotted.project"
  assert_success
  assert_called 'switch-client -t my_dotted_project'
  assert_not_called 'my.dotted.project'
}

@test "a path that is not a directory is rejected before any tmux call" {
  run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one/nope"
  assert_failure
  assert_output --partial 'not a directory'
  assert_not_called 'new-session'
  assert_not_called 'switch-client'
}

# ── Conformance, exercised rather than grepped ───────────────────────────────

@test "--help prints the header block without reaching for fzf" {
  run "$SESSIONIZER" --help
  assert_success
  assert_output --partial 'Usage: sessionizer.sh'
  assert_output --partial 'SESSIONIZER_ROOTS'
  refute_output --partial '#!/usr/bin/env'
}

@test "an unknown verb is rejected instead of being treated as a directory" {
  # The dispatch has to distinguish a flag typo from a real path argument: `--lst` must error,
  # while a bare word is still a directory to visit.
  run "$SESSIONIZER" --lst
  assert_failure
  assert_output --partial 'unknown verb'
  assert_not_called 'new-session'
}

@test "output is identical when invoked by a relative path" {
  # fzf --bind and display-popup both re-invoke a panel from wherever they happen to be.
  local abs rel
  abs="$("$SESSIONIZER" --list)"
  rel="$(cd "$REPO_ROOT/.local/src/tmux" && ./sessionizer.sh --list)"
  assert_equal "$rel" "$abs"
}

@test "it survives a sandbox path containing a space" {
  # $SANDBOX contains a space by design (sandbox.bash:32). This is the whole reason: the
  # pre-migration script built find arguments and a session name without strict quoting.
  mkdir -p "$SANDBOX/roots/alpha/has space here"
  run "$SESSIONIZER" --list
  assert_output --partial 'has space here'
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/alpha/has space here"
  assert_success
  assert_called 'switch-client -t has space here'
}
