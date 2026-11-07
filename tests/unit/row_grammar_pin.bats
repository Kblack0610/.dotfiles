#!/usr/bin/env bats
# The board row grammar, `type(area): title`, has one home: notes-cli (`notes row parse`, `notes row
# types`). No other tracked file spells that shape as a regex; a script that needs a row's type asks
# the verb. KNOWN lists what is still left, each with why, so a new copy fails here and an old one
# leaves the list when it goes. The plan: ~/.claude/plans/arch-intake-one-path.md (P3).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# The shape every dialect of the grammar shares: `[a-z]+`, then the escaped paren that opens the area
# (bash `)(\(`, awk and grep `\(`, jq `\\(`).
SHAPE='(\[a-z\]|\[a-z0-9\]|\[a-z-\]|\[\[:alpha:\]\]|\\w)\+[)]?[(]*\\+[(]'

# KNOWN: "<path>|<why it is not a copy of the row grammar, or the queue item that removes it>"
KNOWN=(
  ".local/bin/day-log|reads PR titles (conventional commits), not board rows"
  ".local/bin/fleet-dispatch|DISPATCH_NIGHT_OBSERVER matches a row's area, not its grammar"
)

# row_regexes <root> -- the tracked paths on stdin (NUL-separated, relative to <root>), minus notes-cli
# (the home), the tests, and the KNOWN ones: one "path:line: text" per line that spells the shape.
row_regexes() {
  local root="$1" p k known
  while IFS= read -r -d '' p; do
    case "$p" in tests/* | .local/src/notes-cli/* | .claude/rules/*) continue ;; esac
    known=0
    for k in "${KNOWN[@]}"; do [ "${k%%|*}" = "$p" ] && known=1; done
    [ "$known" = 0 ] || continue
    grep -InE -- "$SHAPE" "$root/$p" 2>/dev/null | sed "s|^|$p:|"
  done
}

@test "no tracked file but notes-cli spells the row grammar as a regex" {
  run bash -c "$(declare -f row_regexes); SHAPE='$SHAPE'; KNOWN=(${KNOWN[*]@Q}); git -C '$ROOT' ls-files -z | row_regexes '$ROOT'"
  assert_success
  assert_output ""
}

@test "negative control: a script that adds the regex back is caught, and a KNOWN one is not" {
  mkdir -p "$BATS_TEST_TMPDIR/.local/bin"
  printf '%s\n' '[[ "$1" =~ ^([a-z]+)(\([a-z0-9-]+\))?: ]] && echo "${BASH_REMATCH[1]}"' > "$BATS_TEST_TMPDIR/.local/bin/agent-queue"
  cp "$BATS_TEST_TMPDIR/.local/bin/agent-queue" "$BATS_TEST_TMPDIR/.local/bin/day-log"
  printf '%s\n' "grep -E '^\\w+\\(x\\): '" > "$BATS_TEST_TMPDIR/.local/bin/other"
  run bash -c "$(declare -f row_regexes); SHAPE='$SHAPE'; KNOWN=(${KNOWN[*]@Q}); printf '%s\0' .local/bin/agent-queue .local/bin/day-log .local/bin/other | row_regexes '$BATS_TEST_TMPDIR'"
  assert_output --partial ".local/bin/agent-queue:1:"
  assert_output --partial ".local/bin/other:1:"
  refute_output --partial "day-log"
}

@test "every KNOWN path still exists and still spells the shape, so a fixed one leaves the list" {
  local k p
  for k in "${KNOWN[@]}"; do
    p="${k%%|*}"
    run grep -cE -- "$SHAPE" "$ROOT/$p"
    assert_success
  done
}
