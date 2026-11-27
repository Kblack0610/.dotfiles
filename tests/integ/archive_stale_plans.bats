#!/usr/bin/env bats
# archive-stale-plans.sh: a stale project dir moves into _archive/, one level deeper, and its
# entries are relative links into _live (85-sync-plans.sh). A link left as it was would point at
# _archive/_live and break silently, and archiving _live itself would empty the plan store.
# A finished plan in _live (every phase done, untouched 14 days) moves to _archive/_live, its links with it.

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

# finished_plan <name> <checklist line> [date]: a _live plan with one phase, dated (default 2020).
finished_plan() {
  printf '# %s\n\n## Phases\n\n%s\n' "$1" "$2" > "$LIVE/$1.md"
  touch -d "${3:-2020-01-01}" "$LIVE/$1.md"
}

@test "a finished _live plan moves to _archive/_live, and an open, fresh or unchecked one stays" {
  finished_plan done '- [x] P1 ship it (#1)'
  finished_plan open '- [ ] P1 ship it'
  finished_plan young '- [x] P1 ship it (#1)' "$(date -d '-3 days' +%F)"
  run "$SCRIPT" --yes
  assert_success
  [[ -f "$ROOT/_archive/_live/done.md" && ! -e "$LIVE/done.md" ]]
  [[ -f "$LIVE/open.md" && -f "$LIVE/young.md" && -f "$LIVE/old.md" ]]   # old.md has no checklist
}

@test "an archived _live plan takes its links: a project's goes, an archived project's and an alias still reach it" {
  finished_plan done '- [x] P1 ship it (#1)'
  mkdir -p "$ROOT/proj" "$ROOT/_archive/gone"
  ln -s ../_live/done.md "$ROOT/proj/done.md"
  ln -s ../_live/fresh.md "$ROOT/proj/fresh.md"
  ln -s ../../_live/done.md "$ROOT/_archive/gone/done.md"
  ln -s done.md "$LIVE/alias.md"
  run "$SCRIPT" --yes
  assert_success
  [[ ! -e "$ROOT/proj/done.md" && ! -L "$ROOT/proj/done.md" && -L "$ROOT/proj/fresh.md" ]]
  [[ "$(readlink "$ROOT/_archive/gone/done.md")" == ../_live/done.md && -f "$ROOT/_archive/gone/done.md" ]]
  [[ ! -L "$LIVE/alias.md" && "$(cat "$ROOT/_archive/_live/alias.md")" == "$(cat "$ROOT/_archive/_live/done.md")" ]]
}

@test "a finished plan whose _archive/_live name is taken is left in place" {
  finished_plan done '- [x] P1 ship it (#1)'
  mkdir -p "$ROOT/_archive/_live"; echo other > "$ROOT/_archive/_live/done.md"
  run "$SCRIPT" --yes
  assert_success
  assert_output --partial '_archive/_live/done.md exists'
  [[ -f "$LIVE/done.md" && "$(cat "$ROOT/_archive/_live/done.md")" == other ]]
}

@test "an alias whose name is taken in _archive/_live stays in _live and still reaches its plan; a glob name matches only itself" {
  finished_plan 'p[1]' '- [x] P1 ship it (#1)'
  mkdir -p "$ROOT/proj" "$ROOT/_archive/_live"
  ln -s '../_live/p[1].md' "$ROOT/proj/p[1].md"
  ln -s ../_live/fresh.md "$ROOT/proj/p1.md"   # what the pattern [1] would match
  ln -s 'p[1].md' "$LIVE/alias.md"; echo other > "$ROOT/_archive/_live/alias.md"
  run "$SCRIPT" --yes
  assert_success
  [[ ! -L "$ROOT/proj/p[1].md" && -L "$ROOT/proj/p1.md" ]]
  [[ "$(readlink "$LIVE/alias.md")" == '../_archive/_live/p[1].md' && -f "$LIVE/alias.md" ]]
}

@test "a LIVE_DAYS that is not a whole number stops the run before it moves anything" {
  LIVE_DAYS=abc run "$SCRIPT" --yes
  assert_failure
  assert_output --partial 'LIVE_DAYS must be a whole number'
  [[ -d "$ROOT/old" ]]
}

@test "an open plan untouched 14 days is listed and counted, never moved; a done, fresh, archived, superseded or unchecked one is not listed" {
  finished_plan open '- [ ] P1 ship it'
  finished_plan done '- [x] P1 ship it (#1)'
  finished_plan young '- [ ] P1 ship it' "$(date -d '-3 days' +%F)"
  mkdir -p "$ROOT/_unscoped" "$ROOT/_archive/gone"
  printf '# loose\n\n## Phases\n\n- [x] P1 a (#1)\n- [ ] P2 b\n' > "$ROOT/_unscoped/loose.md"; touch -d 2020-01-01 "$ROOT/_unscoped/loose.md"
  printf '# shelved\n\n## Phases\n\n- [ ] P1 a\n' > "$ROOT/_archive/gone/shelved.md"; touch -d 2020-01-01 "$ROOT/_archive/gone/shelved.md"
  printf '# moved\n\nSuperseded by other.md\n\n## Phases\n\n- [ ] P1 a\n' > "$ROOT/_unscoped/moved.md"; touch -d 2020-01-01 "$ROOT/_unscoped/moved.md"
  printf '# bare\n\n## Phases\n\nnothing yet\n' > "$ROOT/_unscoped/bare.md"; touch -d 2020-01-01 "$ROOT/_unscoped/bare.md"
  run "$SCRIPT" --yes
  assert_success
  assert_output --regexp '[0-9]+d  1 open  _live/open\.md'
  assert_output --regexp '[0-9]+d  1 open  _unscoped/loose\.md'
  assert_output --partial 'idle plans: 2'
  refute_output --partial 'young.md'
  refute_output --partial 'shelved.md'
  refute_output --partial 'moved.md'
  refute_output --partial 'bare.md'
  [[ -f "$LIVE/open.md" && -f "$ROOT/_unscoped/loose.md" ]]
}
