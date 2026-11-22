#!/usr/bin/env bats
# context-budget-guard.sh: warns when a write leaves an always-loaded file over its budget.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/context-budget-guard.sh"
  DIR="$BATS_TEST_TMPDIR/proj/memory"
  mkdir -p "$DIR"
  IDX="$DIR/MEMORY.md"
  export CONTEXT_BUDGET_GLOBAL_FILE="$BATS_TEST_TMPDIR/home/.claude/CLAUDE.md"
  mkdir -p "${CONTEXT_BUDGET_GLOBAL_FILE%/*}"
  # the restated-instruction check reads the live corpus unless a test serves its own
  export SKILL_DRIFT_BIN="$BATS_TEST_TMPDIR/no-skill-drift"
}

fill() { head -c "$2" /dev/zero | tr '\0' x > "$1"; }

payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","new_string":"x"}}' "$1"; }

@test "a memory index and other files have no size budget" {
  printf '%s\n' "$(printf 'x%.0s' $(seq 1 300))" > "$BATS_TEST_TMPDIR/MEMORY.md"
  run bash "$HOOK" <<< "$(payload "$BATS_TEST_TMPDIR/MEMORY.md")"
  assert_success
  run bash "$HOOK" <<< "$(payload "$BATS_TEST_TMPDIR/other.md")"
  assert_success
}

@test "the global CLAUDE.md over 20 KB warns" {
  fill "$CONTEXT_BUDGET_GLOBAL_FILE" 20481
  run bash "$HOOK" <<< "$(payload "$CONTEXT_BUDGET_GLOBAL_FILE")"
  assert_failure 2
  assert_output --partial "global CLAUDE.md"
  assert_output --partial "> 20480"
}

@test "the global CLAUDE.md under budget passes, line length is not checked there" {
  fill "$CONTEXT_BUDGET_GLOBAL_FILE" 20000
  run bash "$HOOK" <<< "$(payload "$CONTEXT_BUDGET_GLOBAL_FILE")"
  assert_success
  assert_output ""
}

@test "a repo root CLAUDE.md or AGENTS.md over 12 KB warns" {
  repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  fill "$repo/CLAUDE.md" 12289
  run bash "$HOOK" <<< "$(payload "$repo/CLAUDE.md")"
  assert_failure 2
  assert_output --partial "repo root CLAUDE.md"
  fill "$repo/AGENTS.md" 12289
  run bash "$HOOK" <<< "$(payload "$repo/AGENTS.md")"
  assert_failure 2
}

@test "a CLAUDE.md below a repo root is not a root file and passes" {
  repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  mkdir -p "$repo/sub"
  fill "$repo/sub/CLAUDE.md" 30000
  run bash "$HOOK" <<< "$(payload "$repo/sub/CLAUDE.md")"
  assert_success
}

# --- restated instructions: a line the edit wrote that another home already holds --------------------

dups_fixture() {
  RULE='Never push to a branch that another session has open, because the second push silently reverts the first and nobody sees it.'
  export SKILL_DRIFT_BIN="$BATS_TEST_DIRNAME/../../.local/bin/skill-drift"
  export HOME="$BATS_TEST_TMPDIR/home" CLAUDE_MD="$BATS_TEST_TMPDIR/home/global.md" CLAUDE_SKILLS="$BATS_TEST_TMPDIR/home/skills"
  export AGENTCTL_CONF="$BATS_TEST_TMPDIR/home/conf"
  mkdir -p "$HOME/.agent/lessons" "$AGENTCTL_CONF" "$CLAUDE_SKILLS"
  printf '{"kinds": [{"kind": "global", "rank": 6, "globs": []}, {"kind": "lessons", "rank": 2, "globs": ["*/.agent/lessons/*"]}, {"kind": "memory", "rank": 1, "globs": ["*/memory/*"]}]}\n' > "$AGENTCTL_CONF/instruction-homes.json"
  printf '# global\n%s\n' "$RULE" > "$CLAUDE_MD"
  LESSON="$HOME/.agent/lessons/p.md"
  MEM="$HOME/proj/memory/m.md"
  mkdir -p "${MEM%/*}"
  export DRIFT_DOCS="$CLAUDE_MD
$LESSON
$MEM"
}

write_payload() { jq -nc --arg p "$1" --arg c "$2" '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}'; }

@test "a lesson that restates the global rule warns with both homes and the winner" {
  dups_fixture
  printf '# lessons\n%s\n' "$RULE" > "$LESSON"
  run bash "$HOOK" <<< "$(write_payload "$LESSON" "$RULE")"
  assert_failure 2
  assert_output --partial 'restates an instruction another home already holds'
  assert_output --partial 'lessons line 2 restates global'
  assert_output --partial 'winner: global'
}

@test "negative control: with the copy gone, or when the edit did not write the line, it passes silently" {
  dups_fixture
  printf '# lessons\n%s\n' 'A different lesson about dashboards: render every tile from the cached snapshot, since the live query times out on a cold cluster.' > "$LESSON"
  run bash "$HOOK" <<< "$(write_payload "$LESSON" "$(cat "$LESSON")")"
  assert_success
  assert_output ""
  # the pair exists in the file, but this edit wrote another line: the guard stays out of it
  printf '# lessons\n%s\nSecond line.\n' "$RULE" > "$LESSON"
  run bash "$HOOK" <<< "$(jq -nc --arg p "$LESSON" '{tool_name: "Edit", tool_input: {file_path: $p, old_string: "Second line.", new_string: "Third line."}}')"
  assert_success
  assert_output ""
}

@test "a memory file and an Edit's new_string are checked too; a size warning and a dup warning ride one message" {
  dups_fixture
  printf '# m\n%s\n' "$RULE" > "$MEM"
  run bash "$HOOK" <<< "$(jq -nc --arg p "$MEM" --arg n "$RULE" '{tool_name: "Edit", tool_input: {file_path: $p, old_string: "x", new_string: $n}}')"
  assert_failure 2
  assert_output --partial 'memory line 2 restates global'
  export CONTEXT_BUDGET_GLOBAL_FILE="$CLAUDE_MD"
  head -c 20481 /dev/zero | tr '\0' x >> "$CLAUDE_MD"
  run bash "$HOOK" <<< "$(write_payload "$CLAUDE_MD" "$RULE")"
  assert_failure 2
  assert_output --partial 'is over budget'
  assert_output --partial 'restates an instruction'
}

@test "no scorer, or a scorer that cannot run, never blocks a write" {
  dups_fixture
  printf '# lessons\n%s\n' "$RULE" > "$LESSON"
  SKILL_DRIFT_BIN="$BATS_TEST_TMPDIR/missing" run bash "$HOOK" <<< "$(write_payload "$LESSON" "$RULE")"
  assert_success
  rm "$AGENTCTL_CONF/instruction-homes.json"
  run bash "$HOOK" <<< "$(write_payload "$LESSON" "$RULE")"
  assert_success
}
