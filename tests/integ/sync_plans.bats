#!/usr/bin/env bats
# 85-sync-plans.sh: which plans a session is allowed to claim for its project.
#
# ~/.claude/plans/ is flat, global and project-less. The original hook selected on
# mtime alone and copied every plan touched in the last 24h into whatever project
# the session happened to be in, so a day spent in three projects put each plan in
# all three. Measured on this machine before the fix: 456 of 514 distinct plan
# names lived in 2+ project dirs, one in 7, for 2,272 redundant copies.
#
# It produced no error and no failing check -- the tree just grew, and turn 1 quietly
# advertised other projects' plans as this project's. So the assertions below pin the
# NEGATIVE case (a plan that must NOT be copied) as hard as the positive one; a hook
# that copies everything passes any test that only checks the wanted plan arrived.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  HOOK="$REPO_ROOT/.claude/hooks/stop-post.d/85-sync-plans.sh"

  # Mirror the stow layout: the hook sources this by absolute $HOME path.
  mkdir -p "$HOME/.config/shared-hooks"
  cp "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/"

  # resolve_project_name falls back to the basename, so the project is "alpha".
  PROJECT="$SANDBOX/alpha"
  mkdir -p "$PROJECT"
  export CLAUDE_PROJECT_DIR="$PROJECT"

  SRC="$HOME/.claude/plans"
  DEST="$HOME/.agent/plans/alpha"
  mkdir -p "$SRC" "$DEST"

  TRANSCRIPT="$SANDBOX/transcript.jsonl"
  : > "$TRANSCRIPT"
}

# plan <name> [age-spec] -- a plan file in the flat global dir
plan() {
  local f="$SRC/$1.md"
  printf '# %s\n' "$1" > "$f"
  [ -n "${2:-}" ] && touch -d "$2" "$f"
  printf '%s' "$f"
}

# names <name>... -- a transcript that mentions these plans by absolute path,
# shaped like the real JSONL (the hook matches the path as a fixed string).
names() {
  local n
  for n in "$@"; do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
      "$SRC/$n.md" >> "$TRANSCRIPT"
  done
}

run_hook() {
  printf '{"session_id":"s1","transcript_path":"%s","stop_hook_active":false}\n' "$TRANSCRIPT" \
    | bash "$HOOK"
}

landed() { find "$DEST" -maxdepth 1 -name '*.md' -printf '%f\n' 2>/dev/null | sort; }
landed_count() { landed | grep -c . || true; }

@test "GUARD: a plan this session wrote does land" {
  # Without this, every "did not copy" assertion below could pass by the hook
  # being broken outright and copying nothing at all.
  plan mine >/dev/null
  names mine
  run run_hook
  assert_success
  run landed
  assert_output 'mine.md'
}

@test "THE REGRESSION: only the plan named in the transcript is claimed" {
  # Five plans touched today, one of them this session's. The old hook copied all
  # five. This is the exact shape that put one plan in seven project dirs.
  plan mine >/dev/null
  plan other1 >/dev/null
  plan other2 >/dev/null
  plan other3 >/dev/null
  plan other4 >/dev/null
  names mine

  run run_hook
  assert_success
  run landed
  assert_output 'mine.md'
  run landed_count
  assert_output '1'
}

@test "a plan already owned by another project is NOT taken" {
  # First writer wins. The session genuinely touched this plan, but bravo claimed
  # it first -- copying it here is the fan-out itself.
  plan shared >/dev/null
  names shared
  mkdir -p "$HOME/.agent/plans/bravo"
  printf '# shared\n' > "$HOME/.agent/plans/bravo/shared.md"

  run run_hook
  assert_success
  run landed_count
  assert_output '0'
  # and the original owner is untouched
  assert [ -f "$HOME/.agent/plans/bravo/shared.md" ]
}

@test "a plan owned deeper in the tree still blocks the copy" {
  # _archive/{project}/ nests one level further; a basename held there is still held.
  plan shared >/dev/null
  names shared
  mkdir -p "$HOME/.agent/plans/_archive/bravo"
  printf '# shared\n' > "$HOME/.agent/plans/_archive/bravo/shared.md"

  run run_hook
  assert_success
  run landed_count
  assert_output '0'
}

@test "re-owning its own plan is idempotent, not blocked" {
  # The ownership check must exclude this project's own dir, or the second Stop of
  # a session would refuse to refresh the plan it wrote in the first.
  plan mine >/dev/null
  names mine
  run run_hook
  assert_success
  printf '# mine, revised\n' > "$SRC/mine.md"

  run run_hook
  assert_success
  run landed_count
  assert_output '1'
  assert_output --partial '1'
  run cat "$DEST/mine.md"
  assert_output --partial 'revised'
}

@test "a plan merely READ this session is not claimed if stale" {
  # A transcript names plans the session read as well as wrote. An old plan read
  # from another project must not be adopted on the strength of being mentioned.
  plan borrowed '3 days ago' >/dev/null
  names borrowed
  run run_hook
  assert_success
  run landed_count
  assert_output '0'
}

@test "no transcript in the payload copies NOTHING" {
  # No attribution is available, so the safe action is to copy nothing and let the
  # next Stop sync it. The old hook copied everything in exactly this case.
  plan mine >/dev/null
  plan other >/dev/null
  run bash -c 'printf "{\"session_id\":\"s1\",\"stop_hook_active\":false}\n" | bash "$1"' _ "$HOOK"
  assert_success
  run landed_count
  assert_output '0'
}

@test "a stop_hook_active loop guard payload is a no-op" {
  plan mine >/dev/null
  names mine
  run bash -c 'printf "{\"session_id\":\"s1\",\"transcript_path\":\"%s\",\"stop_hook_active\":true}\n" "$2" | bash "$1"' _ "$HOOK" "$TRANSCRIPT"
  assert_success
  run landed_count
  assert_output '0'
}

@test "empty stdin exits 0 without copying" {
  plan mine >/dev/null
  names mine
  run bash -c 'bash "$1" </dev/null' _ "$HOOK"
  assert_success
  run landed_count
  assert_output '0'
}

@test "a missing plans source is survivable" {
  # Never block the Stop chain: pre-stop-checks.sh drives every sibling hook and a
  # single non-zero breaks the whole turn.
  rm -rf "$SRC"
  run run_hook
  assert_success
}
