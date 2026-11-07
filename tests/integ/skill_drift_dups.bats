#!/usr/bin/env bats
# skill-drift --dups: the same instruction written in two homes. Each test builds a
# fixture corpus; the negative control is the pair that must be found and then, with
# the copy removed, must not be.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  RULE='Never push to a branch that another session has open, because the second push silently reverts the first and nobody sees it.'
  OTHER='Render every dashboard tile from the cached snapshot file, since the live query times out on a cold cluster after thirty seconds.'
  mkdir -p "$HOME/.agent/lessons" "$HOME/.claude/skills/x"
  export CLAUDE_MD="$HOME/global.md"
  printf '# global\n%s\n' "$RULE" > "$CLAUDE_MD"
  export DRIFT_DOCS="$CLAUDE_MD
$HOME/.agent/lessons/p.md"
  printf '# lessons\n%s\n' "$OTHER" > "$HOME/.agent/lessons/p.md"
  printf -- '---\nname: x\n---\n%s\n' "$OTHER" > "$HOME/.claude/skills/x/SKILL.md"
}

@test "a global rule restated in a lesson is reported with both homes and the winner" {
  printf '# lessons\n%s\n' "$RULE" > "$HOME/.agent/lessons/p.md"
  run "$DRIFT" --dups
  assert_success
  assert_output --partial 'global'
  assert_output --partial 'lessons'
  assert_output --partial 'winner: global'
  assert_output --partial '1 pair(s), 2 line(s)'
}

@test "negative control: with the copy removed the same corpus reports nothing" {
  run "$DRIFT" --dups --json
  assert_success
  run jq -r '"\(.pairs) \(.lines)"' <<< "$output"
  assert_output '1 2'
  # the only pair left is lesson vs skill, never the global rule
  run "$DRIFT" --dups --json
  run jq -r '.items[0] | "\(.a.home) \(.b.home) \(.winner)"' <<< "$output"
  assert_output 'lessons skill skill'
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups --json
  run jq -r '"\(.pairs) \(.lines)"' <<< "$output"
  assert_output '0 0'
}

@test "json names the by-home counts" {
  run "$DRIFT" --dups --json
  run jq -r '.by_home | keys[]' <<< "$output"
  assert_output 'lessons/skill'
}

@test "two files of the same rank leave the pick to the session" {
  mkdir -p "$HOME/.claude/projects/p/memory"
  printf '%s\n' "$OTHER" > "$HOME/.claude/projects/p/memory/m.md"
  export DRIFT_DOCS="$HOME/.claude/projects/p/memory/m.md
$HOME/.claude/projects/p/memory/n.md"
  printf '%s\n' "$OTHER" > "$HOME/.claude/projects/p/memory/n.md"
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups
  assert_output --partial 'winner: pick'
}

@test "an anchor AUTO block and a shared marker do not count" {
  mkdir -p "$HOME/.agent/anchors"
  printf '<!-- AUTO:START -->\n%s\n<!-- AUTO:END -->\n' "$RULE" > "$HOME/.agent/anchors/p.md"
  printf '<!-- shared: Core Principles -->\n' > "$HOME/ov.md"
  export DRIFT_DOCS="$CLAUDE_MD
$HOME/.agent/anchors/p.md
$HOME/ov.md"
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups --json
  run jq -r '.pairs' <<< "$output"
  assert_output '0'
}

@test "a file repeating itself is not a pair" {
  printf '%s\n%s\n' "$RULE" "$RULE" > "$CLAUDE_MD"
  export DRIFT_DOCS="$CLAUDE_MD"
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups --json
  run jq -r '.pairs' <<< "$output"
  assert_output '0'
}

@test "an empty corpus refuses to report success" {
  export DRIFT_DOCS="$HOME/missing.md"
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups
  assert_failure 2
}
