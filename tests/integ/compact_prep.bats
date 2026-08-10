#!/usr/bin/env bats
# compact-prep.sh precompact: the PreCompact marker, and the copy that used to ride with it.
#
# The hook used to `cp` the whole session transcript into ~/.agent/archives/{project}/ and
# record the copy as `archived=`. It preserved nothing: compaction grows the session JSONL
# in place rather than rotating it, so every archive was a byte-exact PREFIX of a file still
# present under ~/.claude/projects/, and always a shorter one. Measured 2026-08-09: 14
# archives, 11/11 sessions still live, every live copy larger, several sessions archived
# two or three times each a prefix of the next. 58 MB, zero unique bytes.
#
# A silent duplicator produces no error, so the assertions below pin the ABSENCE of the copy
# as the headline case, and pin the marker/preflight contract end to end so that removing the
# copy cannot quietly break the reconcile pointer that consumed it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SUBJECT="$REPO_ROOT/.config/shared-hooks/compact-prep.sh"

  mkdir -p "$HOME/.config/shared-hooks"
  cp "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/"

  PROJECT_DIR="$SANDBOX/alpha"
  mkdir -p "$PROJECT_DIR"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"

  # A transcript that lives where the real ones live, so the marker points somewhere real.
  TRANSCRIPT="$HOME/.claude/projects/-sandbox-alpha/abc123.jsonl"
  mkdir -p "$(dirname "$TRANSCRIPT")"
  printf '{"type":"user"}\n' > "$TRANSCRIPT"

  MARKER="$HOME/.agent/compact/alpha.pending"
  ARCHIVES="$HOME/.agent/archives"
}

precompact() {
  printf '{"transcript_path":"%s","reason":"%s"}\n' "$TRANSCRIPT" "${1:-manual}" \
    | bash "$SUBJECT" precompact
}

@test "GUARD: precompact drops the marker at all" {
  # Without this, every absence assertion below could pass by the hook doing nothing.
  run precompact
  assert_success
  assert [ -f "$MARKER" ]
}

@test "THE REGRESSION: precompact copies the transcript NOWHERE" {
  run precompact
  assert_success
  # not just "the archives dir is empty" -- assert nothing was created anywhere under it
  run bash -c 'find "$1" -type f 2>/dev/null | wc -l' _ "$ARCHIVES"
  assert_output '0'
}

@test "the marker points at the live transcript, not a copy" {
  run precompact
  assert_success
  run cat "$MARKER"
  assert_output --partial "transcript=$TRANSCRIPT"
}

@test "the marker no longer carries an archived= field" {
  # A stale key that always reads empty is worse than no key: the preflight branched on it.
  run precompact
  assert_success
  run cat "$MARKER"
  refute_output --partial 'archived='
}

@test "paths no longer advertises ARCHIVE_DIR" {
  # The compact-prep skill reads these KEY=VALUE lines; a path that is never written
  # must not be advertised as one to inspect.
  run bash "$SUBJECT" paths
  assert_success
  refute_output --partial 'ARCHIVE_DIR'
  assert_output --partial 'MARKER='
}

@test "the preflight banner surfaces the transcript path end to end" {
  # The contract that mattered: preflight used to print `archived=`. If the writer drops
  # the field and the reader is not moved with it, the reconcile pointer silently vanishes.
  precompact auto
  DEPLOY="$SANDBOX/shared-hooks"
  mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/session-preflight.sh" \
     "$REPO_ROOT/.config/shared-hooks/project-name.sh" \
     "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" "$DEPLOY/"
  export AGENT_BOARD_LIB="$REPO_ROOT/.local/lib/agent-board.sh"

  run bash -c 'printf "{\"source\":\"compact\"}\n" | bash "$1" | jq -r ".hookSpecificOutput.additionalContext // empty"' \
    _ "$DEPLOY/session-preflight.sh"
  assert_success
  assert_output --partial 'Context was just compacted'
  assert_output --partial "$TRANSCRIPT"
}

@test "marker --clear removes it" {
  precompact
  run bash "$SUBJECT" marker --clear
  assert_success
  assert [ ! -f "$MARKER" ]
}

@test "a payload with no transcript still drops a marker and exits 0" {
  # Never block: a blocked compaction can trap a full context window.
  run bash -c 'printf "{\"reason\":\"auto\"}\n" | bash "$1" precompact' _ "$SUBJECT"
  assert_success
  assert [ -f "$MARKER" ]
}

@test "empty stdin exits 0" {
  run bash -c 'bash "$1" precompact </dev/null' _ "$SUBJECT"
  assert_success
}
