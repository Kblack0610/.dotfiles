#!/usr/bin/env bats
# lifecycle.md is the one table of each step's template and check. Its value is that every
# path in it is real, so a moved template or check fails here instead of rotting in the doc.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOC="$PUB/.local/src/docs/lifecycle.md"
}

# Backticked `~/...` paths in a doc that resolve to nothing in this repo. A skill is deployed
# flat but lives under a category, so it is looked up by name.
dead_paths() {
  local p name
  grep -oE '`~/[^` ]+`' "$1" | tr -d '`' | sort -u | while IFS= read -r p; do
    p="${p#\~/}"
    case "$p" in
      .claude/skills/*)
        name="${p#.claude/skills/}"; name="${name%%/*}"
        [ -n "$(find "$PUB/.claude/skills" -type d -name "$name" -print -quit)" ] || echo "$p" ;;
      *) [ -e "$PUB/$p" ] || echo "$p" ;;
    esac
  done
}

@test "lifecycle.md: every path it names exists" {
  run dead_paths "$DOC"
  assert_success
  assert_output ''
}

@test "lifecycle.md: a dead path is reported" {
  # NEGATIVE CONTROL: the check above must be able to fail.
  printf '| x | `~/.local/bin/no-such-check` | `~/.claude/skills/no-such-skill/SKILL.md` |\n' \
    >"$BATS_TEST_TMPDIR/doc.md"
  run dead_paths "$BATS_TEST_TMPDIR/doc.md"
  assert_output --partial '.local/bin/no-such-check'
  assert_output --partial '.claude/skills/no-such-skill/SKILL.md'
}

@test "lifecycle.md: the table lists the seven steps in order" {
  run bash -c "grep -E '^\| [a-z]+ \|' '$DOC' | cut -d' ' -f2 | paste -sd' '"
  assert_output 'idea brief plan epic rows landed verified'
}
