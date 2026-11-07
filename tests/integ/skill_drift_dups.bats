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
  mkdir -p "$HOME/.agent/lessons" "$HOME/.claude/skills/x" "$HOME/.config/agentctl"
  export CLAUDE_MD="$HOME/.claude/CLAUDE.md"
  # The live file is private (~/.config/agentctl/instruction-homes.json); this is its shape.
  cat > "$HOME/.config/agentctl/instruction-homes.json" <<'JSON'
{"kinds": [
  {"kind": "global", "rank": 6, "globs": ["*/.claude/CLAUDE.md"]},
  {"kind": "shared-docs", "rank": 5, "globs": ["*/.local/src/docs/*"]},
  {"kind": "role", "rank": 3, "globs": ["*/.config/agentctl/roles/*", "*/.config/agentctl/prompts/*"]},
  {"kind": "runbook", "rank": 4, "globs": ["*/.config/agentctl/*"]},
  {"kind": "skill", "rank": 3, "globs": ["*/SKILL.md"]},
  {"kind": "lessons", "rank": 2, "globs": ["*/.agent/lessons/*"]},
  {"kind": "anchor", "rank": 1, "globs": ["*/.agent/anchors/*"]},
  {"kind": "memory", "rank": 1, "globs": ["*/memory/*"]}
]}
JSON
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

@test "an anchor AUTO block does not count, nor does a one-line mention of the marker pair" {
  mkdir -p "$HOME/.agent/anchors"
  printf '<!-- AUTO:START -->\n%s\n<!-- AUTO:END -->\n' "$RULE" > "$HOME/.agent/anchors/p.md"
  printf 'Markers `<!-- AUTO:START -->` and `<!-- AUTO:END -->` bound the block on one line, so this prose mention must not hide what follows.\n%s\n' "$RULE" > "$HOME/ov.md"
  # a spliced overview holds only its marker line, so it adds nothing to compare
  printf '<!-- shared: Core Principles -->\n' > "$HOME/ov2.md"
  export DRIFT_DOCS="$CLAUDE_MD
$HOME/.agent/anchors/p.md
$HOME/ov2.md"
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups --json
  run jq -r '.pairs' <<< "$output"
  assert_output '0'
  # control: the same anchor and a line after a one-line marker mention is still scanned
  export DRIFT_DOCS="$CLAUDE_MD
$HOME/ov.md"
  run "$DRIFT" --dups --json
  run jq -r '.pairs' <<< "$output"
  assert_output '1'
}

@test "the winner follows the rank of each home" {
  mkdir -p "$HOME/.config/agentctl/roles" "$HOME/.local/src/docs"
  printf '%s\n' "$OTHER" > "$HOME/.config/agentctl/RUN.md"
  printf '%s\n' "$OTHER" > "$HOME/.config/agentctl/roles/r.role"
  printf '%s\n' "$OTHER" > "$HOME/.local/src/docs/s.md"
  export DRIFT_DOCS="$HOME/.config/agentctl/RUN.md
$HOME/.local/src/docs/s.md
$HOME/.agent/lessons/p.md"
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups --json
  run jq -r '.items[] | "\([.a.home, .b.home] | sort | join("+"))=\(.winner)"' <<< "$output"
  assert_output --partial 'runbook+shared-docs=shared-docs'
  assert_output --partial 'lessons+runbook=runbook'
  assert_output --partial 'role+runbook=runbook'
  assert_output --partial 'lessons+role=role'
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

@test "the rank comes from instruction-homes.json: raising lessons over global flips the winner" {
  printf '# lessons\n%s\n' "$RULE" > "$HOME/.agent/lessons/p.md"
  rm "$HOME/.claude/skills/x/SKILL.md"
  f="$HOME/.config/agentctl/instruction-homes.json"
  jq '(.kinds[] | select(.kind == "lessons") | .rank) = 9' "$f" > "$f.new" && mv "$f.new" "$f"
  run "$DRIFT" --dups
  assert_success
  assert_output --partial 'winner: lessons'
}

@test "no homes file refuses to report, since no winner can be named" {
  rm "$HOME/.config/agentctl/instruction-homes.json"
  run "$DRIFT" --dups
  assert_failure 2
  assert_output --partial 'instruction-homes.json'
}
