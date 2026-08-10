#!/usr/bin/env bats
# One state dir, two env names, and the bug that lived in the gap between them.
#
# `agentctl` (the WRITER) resolved its state dir from $AGENTCTL_STATE, which
# agentctl@.service exports into every unit. Every READER -- agent-proof.sh,
# fleet.sh, cockpit.sh, the bats sandbox -- resolved it from $AGENTCTL_STATE_DIR.
# Two names for one directory.
#
# That is invisible while both are unset, because both default to the same path.
# It only bites when something sets ONE of them: the writer then publishes to one
# directory while the reader inspects another, and BOTH report success. A status
# that is written and never read is worse than one that is missing, because the
# missing one is at least legible as missing.
#
# These tests pin the invariant directly: whatever combination of the two names
# is set, the writer's file must be where the reader looks. They assert on the
# FILESYSTEM rather than on a printed path, because the contract is the location.
#
# Subprocess-level, throwaway dirs under $BATS_TEST_TMPDIR, no daemon.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # sandbox_init exports AGENTCTL_STATE_DIR and unsets AGENTCTL_STATE. This file
  # is specifically about what happens when that is NOT the arrangement, so each
  # test sets the combination it is about, from a clean slate.
  unset AGENTCTL_STATE AGENTCTL_STATE_DIR

  A="$SANDBOX/state-a"
  B="$SANDBOX/state-b"
  export A B
}

# The two halves are deliberately exercised through the REAL pre-existing entry
# points, not through any helper introduced by the fix -- otherwise these tests
# would fail against the old code merely because a new function is missing,
# which proves nothing about the bug.
#
#   writer  `agentctl report`  -> <state>/probe/status       (honoured $AGENTCTL_STATE)
#   reader  `proof_report`     -> <state>/probe/last-outcome (honoured $AGENTCTL_STATE_DIR)
#
# Both have existed all along. The invariant is that the two files land in the
# SAME directory; the bug was that they did not.
write_status() { "$AGENTCTL_BIN" report --name probe item=hello; }

write_outcome() {
  # shellcheck source=/dev/null
  ( source "$REPO_ROOT/.local/lib/agent-proof.sh" && proof_report probe WORKED "t" )
}

# Where the pair actually landed, as a set of directories. One entry = agreement.
# NUL-delimited and parenthesised: $SANDBOX contains a space on purpose, and the
# first version of this helper was split by xargs on it -- which is exactly the
# class of bug that space exists to catch.
landed_dirs() {
  find "$SANDBOX" "$HOME/.local/state" \
       \( -name status -o -name last-outcome \) -print0 2>/dev/null \
    | xargs -0 -r -n1 dirname | sort -u
}

# ------------------------------------------------------------------ the invariant

@test "AGENTCTL_STATE_DIR alone: writer and reader use the same directory" {
  export AGENTCTL_STATE_DIR="$A"
  write_status
  write_outcome
  run landed_dirs
  assert_output "$A/probe"
}

# THE REGRESSION TEST. This is the systemd shape: agentctl@.service exports
# AGENTCTL_STATE and nothing exports AGENTCTL_STATE_DIR. Before this change the
# writer honoured it and every reader ignored it, so a runner's status was
# published into $AGENTCTL_STATE while fleet.sh read $HOME/.local/state/agentctl.
@test "AGENTCTL_STATE alone (the systemd shape): reader follows the writer" {
  export AGENTCTL_STATE="$A"
  write_status
  write_outcome
  # One directory, not two. Before the fix this produced $A/probe for the status
  # and $HOME/.local/state/agentctl/probe for the outcome, and nothing complained.
  run landed_dirs
  assert_output "$A/probe"
}

@test "both set: writer and reader agree, and STATE_DIR wins" {
  export AGENTCTL_STATE="$A" AGENTCTL_STATE_DIR="$B"
  write_status
  write_outcome
  # The point is not which name wins, it is that both halves pick the SAME one.
  run landed_dirs
  assert_output "$B/probe"
}

@test "neither set: both fall back to the same default under HOME" {
  write_status
  write_outcome
  run landed_dirs
  assert_output "$HOME/.local/state/agentctl/probe"
}

# ------------------------------------------------------------------ negative control
#
# A test that cannot fail is not a test. If write_status silently did nothing --
# a broken stub, a bad path, a refusing binary -- every assertion above would
# still pass, because "the file is not in the wrong place" is also true when the
# file is nowhere. This proves the writer really writes and that the assertions
# above are discriminating between two real directories.
@test "the writer really writes, and only to the directory it was pointed at" {
  export AGENTCTL_STATE_DIR="$A"
  write_status
  assert [ -f "$A/probe/status" ]
  assert [ ! -e "$B/probe/status" ]

  # ...and pointing it elsewhere moves the file, rather than always hitting $A.
  export AGENTCTL_STATE_DIR="$B"
  write_status
  assert [ -f "$B/probe/status" ]
}

# ------------------------------------------------------------------ drift guard
#
# The four resolvers must stay byte-identical in precedence. They are in four
# files that no single change touches together, which is exactly how they came
# apart the first time. Written as a scan so a NEW reader that honours only one
# name is caught the day it lands, rather than the day someone sets a variable.
@test "every state-dir resolver honours BOTH names" {
  local offenders=()
  local f
  for f in .local/bin/agentctl .local/lib/agent-proof.sh \
           .local/src/tmux/fleet.sh .local/src/tmux/cockpit.sh; do
    # the line that establishes the state dir must mention both names
    grep -qE 'AGENTCTL_STATE_DIR:-\$\{?AGENTCTL_STATE' "$REPO_ROOT/$f" || offenders+=("$f")
  done
  # Empty input is failure, not success: if the loop scanned nothing this must
  # not read as "all four are fine".
  assert [ "${#offenders[@]}" -eq 0 ]
  run bash -c "grep -rlE 'AGENTCTL_STATE_DIR:-\\\$\\{?AGENTCTL_STATE' '$REPO_ROOT'/.local | wc -l"
  assert_output '4'
}
