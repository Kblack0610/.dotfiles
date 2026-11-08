#!/usr/bin/env bats
# overview.md names the shared sections of the global CLAUDE.md with markers and the sync splices
# them in, so the rule text has one home. The first half drives the splice on fixtures. The second
# reads the real files, and checks that every ## heading of the global CLAUDE.md reaches Codex and
# opencode through a marker or sits on LEFT_OUT: skipped where the private overlay is absent (public
# CI), it runs in the Stop fast tier.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SPLICE="$PUB/.config/codex/splice-shared-rules.py"
  PRIV="${RULES_PRIVATE_REPO:-$HOME/.dotfiles-private}"
  T="$BATS_TEST_TMPDIR"
  cat >"$T/CLAUDE.md" <<'MD'
Intro

## Core Principles

    Simplicity First.

---

## Writing Style (all artifacts)

- ASCII only.

### Sub

- Kept with its parent.

## Last

- Tail.
MD
}

@test "splice: a marker becomes its section, up to the next heading or rule" {
  printf '# Top\n<!-- shared: Core Principles -->\nmine\n' >"$T/o.md"
  run "$SPLICE" "$T/o.md" "$T/CLAUDE.md"
  assert_success
  run cat "$T/o.md"
  assert_output "$(printf '# Top\n## Core Principles\n\n    Simplicity First.\nmine')"
}

@test "splice: a file with no marker needs no source and stays as it is" {
  printf '# Top\nmine\n' >"$T/o.md"
  run "$SPLICE" "$T/o.md" "$T/absent.md"
  assert_success
  run cat "$T/o.md"
  assert_output "$(printf '# Top\nmine')"
}

@test "splice: a marker with no source file exits 1, naming the file" {
  printf '<!-- shared: Core Principles -->\n' >"$T/o.md"
  run "$SPLICE" "$T/o.md" "$T/absent.md"
  assert_failure 1
  assert_output --partial "$T/absent.md"
}

@test "splice: a marker matches a heading by its leading words and keeps subsections" {
  printf '<!-- shared: Writing Style -->\n' >"$T/o.md"
  run "$SPLICE" "$T/o.md" "$T/CLAUDE.md"
  assert_success
  run cat "$T/o.md"
  assert_output --partial '## Writing Style (all artifacts)'
  assert_output --partial 'Kept with its parent.'
  refute_output --partial 'Tail.'
}

@test "splice: a word that only starts a heading word is no match" {
  printf '<!-- shared: Writing Sty -->\n' >"$T/o.md"
  run "$SPLICE" "$T/o.md" "$T/CLAUDE.md"
  assert_failure 1
}

@test "splice: a marker with no section exits 1, naming it, and leaves the file alone" {
  printf '<!-- shared: Gone -->\nmine\n' >"$T/o.md"
  run "$SPLICE" "$T/o.md" "$T/CLAUDE.md"
  assert_failure 1
  assert_output --partial 'Gone'
  run cat "$T/o.md"
  assert_output "$(printf '<!-- shared: Gone -->\nmine')"
}

# Headings of the real files, by their words before any bracket.
headings() { grep -E '^##+ ' "$1" | sed -E 's/^#+ //; s/ \(.*//'; }

# Sections of CLAUDE.md that Codex and opencode are meant not to get. Empty today: a section lands here
# only by a decision, so a new one cannot miss them by omission. Names are the heading's leading words,
# matched like a marker.
LEFT_OUT=()

# Headings of $2 (CLAUDE.md) that no marker of $1 (overview.md) names and LEFT_OUT does not list.
# A marker matches a heading as the splice does: the whole heading, or its leading words.
uncovered() {
  local h m left
  local -a markers
  mapfile -t markers < <(sed -nE 's/^<!-- shared: (.+) -->$/\1/p' "$1")
  while IFS= read -r h; do
    for m in "${markers[@]}" "${LEFT_OUT[@]}"; do
      [ "$h" = "$m" ] || [[ "$h" == "$m "* ]] && continue 2
    done
    printf '%s\n' "$h"
  done < <(sed -nE 's/^## //p' "$2")
}

@test "coverage: a heading with no marker and not left out is reported" {
  printf '<!-- shared: Core Principles -->\n' >"$T/o.md"
  run uncovered "$T/o.md" "$T/CLAUDE.md"
  assert_output "$(printf 'Writing Style (all artifacts)\nLast')"
}

@test "coverage: a left-out heading is not reported" {
  printf '<!-- shared: Core Principles -->\n' >"$T/o.md"
  LEFT_OUT=("Last" "Writing Style")
  run uncovered "$T/o.md" "$T/CLAUDE.md"
  assert_output ''
}

@test "real files: every ## heading of CLAUDE.md has a marker or is on the left-out list" {
  local o="$PRIV/.config/rulesync-global/.rulesync/rules/overview.md" c="$PRIV/.claude/CLAUDE.md"
  [ -f "$o" ] || skip "no private overlay at $PRIV"
  run uncovered "$o" "$c"
  assert_output ''
}

@test "real files: every left-out name is still a heading of CLAUDE.md" {
  local c="$PRIV/.claude/CLAUDE.md" left
  [ -f "$c" ] || skip "no private overlay at $PRIV"
  for left in "${LEFT_OUT[@]}"; do
    run grep -qE "^## ${left}( |\$)" "$c"
    assert_success
  done
}

@test "real files: every marker resolves" {
  local o="$PRIV/.config/rulesync-global/.rulesync/rules/overview.md"
  [ -f "$o" ] || skip "no private overlay at $PRIV"
  grep -q '^<!-- shared: ' "$o" || skip "overview.md has no markers yet"
  cp "$o" "$T/o.md"
  run "$SPLICE" "$T/o.md" "$PRIV/.claude/CLAUDE.md"
  assert_success
  run grep -c '^<!-- shared: ' "$T/o.md"
  assert_output 0
}

@test "real files: overview.md restates no section or line of CLAUDE.md" {
  local o="$PRIV/.config/rulesync-global/.rulesync/rules/overview.md" c="$PRIV/.claude/CLAUDE.md"
  [ -f "$o" ] || skip "no private overlay at $PRIV"
  grep -q '^<!-- shared: ' "$o" || skip "overview.md has no markers yet"
  run comm -12 <(headings "$o" | sort -u) <(headings "$c" | sort -u)
  assert_output ''
  run comm -12 <(grep -E '^\s*- ' "$o" | sort -u) <(grep -E '^\s*- ' "$c" | sort -u)
  assert_output ''
}

@test "real files: the tracked opencode AGENTS.md carries the current shared sections" {
  local o="$PRIV/.config/rulesync-global/.rulesync/rules/overview.md" a="$PRIV/.config/opencode/AGENTS.md"
  [ -f "$o" ] || skip "no private overlay at $PRIV"
  grep -q '^<!-- shared: ' "$o" || skip "overview.md has no markers yet"
  cp "$o" "$T/o.md"
  "$SPLICE" "$T/o.md" "$PRIV/.claude/CLAUDE.md"
  # rulesync drops the frontmatter and keeps the body, so each spliced line must be in the output.
  awk '/^---$/ && f<2 {f++; next} f>=2 && NF' "$T/o.md" > "$T/body"
  [ -s "$T/body" ]
  run grep -vxFf "$a" "$T/body"
  assert_output ''
}
