#!/usr/bin/env bats
# archive-stale-plans.sh: a stale project dir moves into _archive/, one level deeper, and its
# entries are relative links into _live (85-sync-plans.sh). A link left as it was would point at
# _archive/_live and break silently, and archiving _live itself would empty the plan store.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SCRIPT="$REPO_ROOT/.config/shared-hooks/archive-stale-plans.sh"
  ROOT="$HOME/.agent/plans" LIVE="$HOME/.agent/plans/_live"
  mkdir -p "$LIVE" "$ROOT/old" "$ROOT/fresh"
  echo old > "$LIVE/old.md"; touch -d '2020-01-01' "$LIVE/old.md"
  echo fresh > "$LIVE/fresh.md"
  ln -s ../_live/old.md "$ROOT/old/old.md"
  ln -s ../_live/fresh.md "$ROOT/fresh/fresh.md"
  touch -h -d '2020-01-01' "$ROOT/fresh/fresh.md"   # an old link to a plan touched today
}

@test "a stale project moves to _archive and its links still reach the store" {
  run "$SCRIPT" --yes
  assert_success
  [[ "$(readlink "$ROOT/_archive/old/old.md")" == ../../_live/old.md ]]
  [[ "$(cat "$ROOT/_archive/old/old.md")" == old ]]
}

@test "a project's age is its plans' age, and _live itself is never archived" {
  run "$SCRIPT" --yes
  assert_success
  [[ -L "$ROOT/fresh/fresh.md" ]]
  [[ -f "$LIVE/old.md" && ! -e "$ROOT/_archive/_live" ]]
}

@test "a project whose _archive name is taken is left in place" {
  mkdir -p "$ROOT/_archive/old"
  run "$SCRIPT" --yes
  assert_success
  assert_output --partial '_archive/old exists'
  [[ "$(readlink "$ROOT/old/old.md")" == ../_live/old.md ]]
}
