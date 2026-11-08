#!/usr/bin/env bats
# .claude/rules: the repo's path-scoped rules (CLAUDE.md "Path-scoped rules"). Each file opens with
# `paths:` frontmatter, every glob still matches a file in the repo (a rename would otherwise turn a
# rule off without a word), and stow never deploys the directory as user rules.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# dead_globs DIR ROOT -> one "<rule>: <reason>" line per rule file with no paths list or a glob
# that matches no file under ROOT; exit 1 when it printed any.
dead_globs() {
  local dir="$1" root="$2" f g n bad=0
  for f in "$dir"/*.md; do
    [ "$(head -n1 "$f")" = "---" ] && [ "$(sed -n 2p "$f")" = "paths:" ] \
      || { echo "${f##*/}: no paths: frontmatter"; bad=1; continue; }
    n=0
    while IFS= read -r g; do
      n=$((n + 1))
      (cd "$root" && shopt -s globstar nullglob dotglob && set -- $g && [ $# -gt 0 ]) \
        || { echo "${f##*/}: $g matches nothing"; bad=1; }
    done < <(sed -n '3,/^---$/p' "$f" | sed -n 's/^  - "\(.*\)"$/\1/p')
    [ "$n" -gt 0 ] || { echo "${f##*/}: empty paths list"; bad=1; }
  done
  return "$bad"
}

@test "every rule has a paths list and each glob matches a file" {
  run dead_globs "$ROOT/.claude/rules" "$ROOT"
  assert_success
  assert_output ""
}

@test "negative control: a rule whose glob matches nothing, or with no paths, is caught" {
  mkdir -p "$BATS_TEST_TMPDIR/rules" "$BATS_TEST_TMPDIR/repo/src"
  touch "$BATS_TEST_TMPDIR/repo/src/a.sh"
  printf -- '---\npaths:\n  - "src/**"\n  - "gone/**"\n---\n\n# x\n' > "$BATS_TEST_TMPDIR/rules/one.md"
  printf -- '# no frontmatter\n' > "$BATS_TEST_TMPDIR/rules/two.md"
  run dead_globs "$BATS_TEST_TMPDIR/rules" "$BATS_TEST_TMPDIR/repo"
  assert_failure
  assert_output --partial "one.md: gone/** matches nothing"
  assert_output --partial "two.md: no paths: frontmatter"
  refute_output --partial "src/**"
}

@test "stow never deploys .claude/rules as user rules" {
  run grep -qxF '^/\.claude/rules$' "$ROOT/.stow-local-ignore"
  assert_success
}
