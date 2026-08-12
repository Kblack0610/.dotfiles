#!/usr/bin/env bats
# skill-drift --lint: the STATIC checks, which are the ones CI can run.
#
# A CI runner has no ~/.claude/skills, no private overlay and no CLAUDE.md, so the
# environmental checks (DEADPATH, NOCMD, UNDEPLOYED, GHOST, UNLISTED, STALE, UNUSED)
# cannot even be attempted there. --lint is the subset decidable from a checkout, and
# this file is the proof that each check FAILS on a bad skill rather than waving it
# through - a lint nobody has watched fail is a lint nobody should trust.
#
# Every test here is a negative control by construction: build a deliberately broken
# skill, assert the specific finding. The two positive tests at the end guard the
# other direction (a valid corpus must pass, and an EMPTY corpus must NOT).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  REPO="$HOME/repo"
  mkdir -p "$REPO/.claude/skills"
  export DRIFT REPO
  # An empty baseline: these fixtures carry no legacy ASCII debt, so nothing is
  # grandfathered and NONASCII is a hard error like everything else.
  export SKILL_LINT_BASELINE="$HOME/empty.baseline"
  : > "$SKILL_LINT_BASELINE"
}

# mkskill <category> <name> [extra-frontmatter-lines...]
mkskill() {
  local cat="$1" name="$2"; shift 2
  local d="$REPO/.claude/skills/$cat/$name"
  mkdir -p "$d"
  {
    echo "---"
    echo "name: $name"
    echo "description: A test skill. Use when testing."
    echo "metadata:"
    echo "  category: $cat"
    echo "  tags: [testing]"
    echo '  reviewed: "2026-08-01"'
    for line in "$@"; do echo "$line"; done
    echo "---"
    echo
    echo "## When to Use"
    echo
    echo "- when testing"
  } > "$d/SKILL.md"
  printf '%s' "$d"
}

lint() { run "$DRIFT" --lint "$REPO"; }

# ── the corpus must pass when it is actually valid ───────────────────────────

@test "a well-formed corpus passes" {
  mkskill ops one >/dev/null
  mkskill memory two >/dev/null
  lint
  assert_success
  assert_output --partial "2 skill(s) valid"
}

# The single most important test in this file. Every tooling failure in this repo
# has been a silent success, and a linter that scans nothing and reports "valid" is
# the purest example. Exit 2, not 0.
@test "an EMPTY corpus is a failure, not a clean run" {
  lint
  assert_failure 2
  assert_output --partial "refusing to report success"
}

# ── each static check must actually fire ─────────────────────────────────────

@test "NOFRONTMATTER: a SKILL.md with no frontmatter" {
  d=$(mkskill ops broken)
  printf '# just a heading\n' > "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NOFRONTMATTER"
}

@test "NOFRONTMATTER: frontmatter without a description" {
  d=$(mkskill ops nodesc)
  printf -- '---\nname: nodesc\n---\n\n## When to Use\n' > "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NOFRONTMATTER"
  assert_output --partial "missing description"
}

@test "BADNAME: name is not kebab-case" {
  d=$(mkskill ops Bad_Name)
  lint
  assert_failure
  assert_output --partial "BADNAME"
  assert_output --partial "not kebab-case"
}

@test "BADNAME: frontmatter name disagrees with the directory" {
  d=$(mkskill ops realdir)
  sed -i 's/^name: realdir/name: someothername/' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADNAME"
  assert_output --partial "does not match the directory"
}

@test "DUPNAME: the same skill name in two categories" {
  mkskill ops twice >/dev/null
  mkskill memory twice >/dev/null
  lint
  assert_failure
  assert_output --partial "DUPNAME"
}

@test "BADMETA: missing category" {
  d=$(mkskill ops nocat)
  sed -i '/^  category:/d' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "missing metadata.category"
}

@test "BADMETA: a category outside the known set" {
  mkskill wizardry spells >/dev/null
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "not one of"
}

@test "BADMETA: category disagrees with the parent directory" {
  d=$(mkskill ops liar)
  sed -i 's/^  category: ops/  category: memory/' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "disagrees with the parent directory"
}

@test "BADMETA: missing reviewed date" {
  d=$(mkskill ops norev)
  sed -i '/^  reviewed:/d' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "missing metadata.reviewed"
}

@test "BADMETA: a reviewed date that is not YYYY-MM-DD" {
  d=$(mkskill ops badrev)
  sed -i 's/^  reviewed:.*/  reviewed: "last tuesday"/' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "YYYY-MM-DD"
}

@test "BADMETA: missing tags" {
  d=$(mkskill ops notags)
  sed -i '/^  tags:/d' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "missing metadata.tags"
}

@test "CATCOLLIDE: a category sharing a name with a skill" {
  # This is not hypothetical: comms/comms/ made `git mv` refuse and silently
  # swallowed two sibling skills during the category migration.
  mkskill ops memory >/dev/null      # a skill called "memory"
  mkskill memory realskill >/dev/null # and a category called "memory"
  lint
  assert_failure
  assert_output --partial "CATCOLLIDE"
}

@test "LONGDESC: a description past the 1536-char listing cap" {
  d=$(mkskill ops verbose)
  long=$(printf 'x%.0s' $(seq 1 1700))
  sed -i "s/^description: .*/description: $long/" "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "LONGDESC"
  assert_output --partial "truncated away"
}

@test "DESCNEAR is a WARNING, not a failure" {
  d=$(mkskill ops chatty)
  long=$(printf 'x%.0s' $(seq 1 1300))
  sed -i "s/^description: .*/description: $long/" "$d/SKILL.md"
  lint
  assert_success
  assert_output --partial "warn"
  assert_output --partial "DESCNEAR"
}

@test "NONASCII: an em dash trips the house plain-ASCII rule" {
  d=$(mkskill ops fancy)
  printf 'Some prose with an em dash \xe2\x80\x94 right here.\n' >> "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NONASCII"
}

@test "NONASCII: an arrow and an ellipsis too" {
  d=$(mkskill ops arrows)
  printf 'Flow: a \xe2\x86\x92 b, and so on\xe2\x80\xa6\n' >> "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NONASCII"
}

@test "NONASCII is suppressed for a skill named in the baseline" {
  d=$(mkskill ops legacy)
  printf 'Prose with an em dash \xe2\x80\x94 here.\n' >> "$d/SKILL.md"
  echo "NONASCII|legacy" > "$SKILL_LINT_BASELINE"
  lint
  assert_success
}

@test "the baseline suppresses only the skill it names" {
  d1=$(mkskill ops legacy); d2=$(mkskill ops fresh)
  printf 'em dash \xe2\x80\x94 here\n' >> "$d1/SKILL.md"
  printf 'em dash \xe2\x80\x94 here\n' >> "$d2/SKILL.md"
  echo "NONASCII|legacy" > "$SKILL_LINT_BASELINE"
  lint
  assert_failure
  assert_output --partial "fresh"
  refute_output --partial "FAIL  NONASCII      legacy"
}

# ── the flat layout still lints, so the gate works before AND after a migration ──

@test "a flat skill (no category dir) still gets its frontmatter checked" {
  d="$REPO/.claude/skills/flatty"
  mkdir -p "$d"
  printf -- '---\nname: WRONG\ndescription: x\n---\n\n## When to Use\n' > "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADNAME"
}
