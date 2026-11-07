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
  export CLAUDE_MD="$HOME/global.md"
  # The live file is private (~/.config/agentctl/instruction-homes.json) and CI has no private
  # checkout, so this is its shape, not its content: the private repo's tests own the content.
  cat > "$HOME/.config/agentctl/instruction-homes.json" <<'JSON'
{"kinds": [
  {"kind": "global", "rank": 6, "globs": []},
  {"kind": "shared-docs", "rank": 5, "globs": ["*/.local/src/docs/*"]},
  {"kind": "role", "rank": 3, "globs": ["*/.config/agentctl/roles/*", "*/.config/agentctl/prompts/*"]},
  {"kind": "runbook", "rank": 4, "globs": ["*/.config/agentctl/*"]},
  {"kind": "repo", "rank": 4, "globs": ["*/CLAUDE.md", "*/AGENTS.md"]},
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

@test "the global file is CLAUDE_MD, wherever it lives; another .claude/CLAUDE.md is a repo" {
  mkdir -p "$HOME/proj/.claude"
  printf '%s\n' "$RULE" > "$HOME/proj/.claude/CLAUDE.md"
  export DRIFT_DOCS="$CLAUDE_MD
$HOME/proj/.claude/CLAUDE.md"
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups
  assert_success
  assert_output --partial 'winner: global'
  assert_output --partial 'repo'
}

@test "a homes file that does not parse, or names no global kind, refuses to report" {
  f="$HOME/.config/agentctl/instruction-homes.json"
  printf '{"kinds": [}' > "$f"
  run "$DRIFT" --dups
  assert_failure 2
  printf '{"kinds": [{"kind": "skill", "rank": 3, "globs": ["*/SKILL.md"]}]}' > "$f"
  run "$DRIFT" --dups
  assert_failure 2
  printf '{"kinds": [{"kind": "global", "globs": []}]}' > "$f"
  run "$DRIFT" --dups
  assert_failure 2
}

# --- the gate: the count may not rise over dup_pairs_max in kpi-thresholds ------------------------

@test "--check passes at the baseline and fails, listing the pairs, once a copy is added; removing it passes again" {
  export KPI_THRESHOLDS="$HOME/kpi-thresholds"
  printf 'revert_rate_max=0.05\ndup_pairs_max=1\n' > "$KPI_THRESHOLDS"
  run "$DRIFT" --dups --check
  assert_success
  # NEGATIVE CONTROL: the global rule copied into a lesson is the second pair
  printf '# lessons\n%s\n%s\n' "$OTHER" "$RULE" > "$HOME/.agent/lessons/p.md"
  run "$DRIFT" --dups --check
  assert_failure 1
  assert_output --partial 'winner: global'
  assert_output --partial '1 over the baseline of 1'
  printf '# lessons\n%s\n' "$OTHER" > "$HOME/.agent/lessons/p.md"
  run "$DRIFT" --dups --check
  assert_success
}

@test "--check says when the baseline can drop, and --json carries max and over" {
  export KPI_THRESHOLDS="$HOME/kpi-thresholds"
  printf 'dup_pairs_max=4\n' > "$KPI_THRESHOLDS"
  run "$DRIFT" --dups --check
  assert_success
  assert_output --partial 'lower dup_pairs_max to 1'
  run "$DRIFT" --dups --check --json
  run jq -c '[.pairs, .max, .over]' <<< "$output"
  assert_output '[1,4,0]'
  printf 'dup_pairs_max=0\n' > "$KPI_THRESHOLDS"
  run "$DRIFT" --dups --check --json
  assert_failure 1
  run jq -c '[.pairs, .max, .over]' <<< "$output"
  assert_output '[1,0,1]'
}

@test "--check with no dup_pairs_max row refuses to report success" {
  export KPI_THRESHOLDS="$HOME/kpi-thresholds"
  printf 'revert_rate_max=0.05\n' > "$KPI_THRESHOLDS"
  run "$DRIFT" --dups --check
  assert_failure 2
  assert_output --partial 'no dup_pairs_max'
  rm "$KPI_THRESHOLDS"
  run "$DRIFT" --dups --check
  assert_failure 2
}

@test "two anchors sharing the generated template are not a pair" {
  mkdir -p "$HOME/.agent/anchors"
  printf -- '- **Tracker:** the agent board, `notes ptask alpha --agent list` (project-map `trackers`) and the rest.\n' > "$HOME/.agent/anchors/alpha.md"
  printf -- '- **Tracker:** the agent board, `notes ptask beta --agent list` (project-map `trackers`) and the rest.\n' > "$HOME/.agent/anchors/beta.md"
  export DRIFT_DOCS="$HOME/.agent/anchors/alpha.md
$HOME/.agent/anchors/beta.md"
  rm "$HOME/.claude/skills/x/SKILL.md"
  run "$DRIFT" --dups --json
  run jq -r '.pairs' <<< "$output"
  assert_output '0'
}

@test "--file keeps the pairs that touch one file and fails while it has any" {
  printf '# lessons\n%s\n%s\n' "$OTHER" "$RULE" > "$HOME/.agent/lessons/p.md"
  run "$DRIFT" --dups --file "$CLAUDE_MD"
  assert_failure 1
  assert_output --partial 'winner: global'
  assert_output --partial '1 pair(s)'
  # the skill is in the lesson's other pair only, never the global file's
  run "$DRIFT" --dups --file "$HOME/.claude/skills/x/SKILL.md"
  assert_failure 1
  assert_output --partial 'winner: skill'
  assert_output --partial '1 pair(s)'
  rm "$HOME/.claude/skills/x/SKILL.md"
  printf '# lessons\n%s\n' "$OTHER" > "$HOME/.agent/lessons/p.md"
  run "$DRIFT" --dups --file "$CLAUDE_MD"
  assert_success
  assert_output --partial '0 pair(s)'
}

@test "--check and --file do not combine; an unknown flag is refused" {
  run "$DRIFT" --dups --check --file "$CLAUDE_MD"
  assert_failure 2
  run "$DRIFT" --dups --bogus
  assert_failure 2
}
