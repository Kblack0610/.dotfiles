#!/usr/bin/env bats
# skill-drift --docs: DEADPATH and NOCMD over the global doc set, the deterministic
# baseline the nightly docs-cleanup pass starts from. Each test builds a doc with a
# real and a dead reference and asserts only the dead one is reported.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  mkdir -p "$HOME/real"
}

@test "a dead path is reported with its doc and line, a live one is not" {
  printf '# doc\nSee ~/real for it.\nAnd ~/gone/file.md too.\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs
  assert_failure 1
  assert_output --partial '~/gone/file.md'
  assert_output --partial '(line 3)'
  refute_output --partial '~/real '
  assert_output --partial '1 finding(s) across 1 doc(s)'
}

@test "a command missing from PATH inside a bash fence is NOCMD" {
  printf '```bash\nno-such-tool-xyz --flag\nls -la\n```\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  assert_failure 1
  run jq -r '.findings[] | "\(.type) \(.item)"' <<< "$output"
  assert_output 'NOCMD no-such-tool-xyz'
}

@test "a clean doc set exits 0 and json names the doc count" {
  printf 'Only ~/real here.\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  assert_success
  run jq -r '"\(.docs) \(.drift)"' <<< "$output"
  assert_output '1 0'
}

@test "an empty doc set refuses to report success" {
  DRIFT_DOCS="$HOME/missing.md" run "$DRIFT" --docs
  assert_failure 2
}

@test "a placeholder path is checked by its concrete directory only" {
  # Cut at the <, `p<N>/` read as a missing `~/real/p`; a brace list still
  # names its dead directory.
  printf 'Save to `~/real/p<N>/`, `~/real/{a,b}.md` and `~/gone/{a,b}.md`.\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '.findings[] | .item' <<< "$output"
  assert_output '~/gone'
}

@test "comments, heredoc bodies and multi-line quoted strings in a fence are not commands" {
  printf '%s\n' '```bash' \
    '# invert a binding / swap two verbs' \
    "gh api graphql -f query='" \
    '  number' \
    "'" \
    "cat <<'EOF' > ~/x" \
    'changelog -- not a tool' \
    'EOF' \
    'no-such-tool-xyz --flag' \
    '```' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '.findings[] | select(.type == "NOCMD") | .item' <<< "$output"
  # negative control: the real missing tool after them is still found
  assert_output 'no-such-tool-xyz'
}
