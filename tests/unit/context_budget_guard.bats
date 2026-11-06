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
}

fill() { head -c "$2" /dev/zero | tr '\0' x > "$1"; }

payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","new_string":"x"}}' "$1"; }

@test "a small index with short lines passes silently" {
  printf -- '- [A](a.md) - short hook\n- [B](b.md) - another\n' > "$IDX"
  run bash "$HOOK" <<< "$(payload "$IDX")"
  assert_success
  assert_output ""
}

@test "a line over the line budget warns with its line number" {
  printf -- '- [A](a.md) - short\n- [B](b.md) - %s\n' "$(printf 'x%.0s' $(seq 1 250))" > "$IDX"
  run bash "$HOOK" <<< "$(payload "$IDX")"
  assert_failure 2
  assert_output --partial "line 2:"
  assert_output --partial "lines over 200 chars"
}

@test "an index over the byte budget warns with its size" {
  for i in $(seq 1 160); do printf -- '- [Memory %03d](m%03d.md) - a hook of ordinary length for the index\n' "$i" "$i"; done > "$IDX"
  run bash "$HOOK" <<< "$(payload "$IDX")"
  assert_failure 2
  assert_output --partial "> 8192"
}

@test "budgets are overridable from the environment" {
  printf -- '- [A](a.md) - %s\n' "$(printf 'x%.0s' $(seq 1 250))" > "$IDX"
  MEMORY_INDEX_MAX_LINE=400 run bash "$HOOK" <<< "$(payload "$IDX")"
  assert_success
}

@test "a MEMORY.md outside a memory dir and other files are ignored" {
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

@test "a lessons file over budget warns only on an edit that grows it" {
  L="$BATS_TEST_TMPDIR/home/.agent/lessons/proj.md"
  mkdir -p "${L%/*}"
  fill "$L" 300
  grow=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"abc"}}' "$L")
  shrink=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"abc","new_string":"a"}}' "$L")
  CONTEXT_BUDGET_LESSONS=200 run bash "$HOOK" <<< "$grow"
  assert_failure 2
  assert_output --partial "lessons file"
  assert_output --partial "lessons archive --dry-run"
  CONTEXT_BUDGET_LESSONS=200 run bash "$HOOK" <<< "$shrink"
  assert_success
  run bash "$HOOK" <<< "$grow"
  assert_success
  # Archived lessons are not a lessons file.
  mkdir -p "${L%/*}/_archive"; fill "${L%/*}/_archive/proj-stale.md" 300
  CONTEXT_BUDGET_LESSONS=200 run bash "$HOOK" <<< "$(payload "${L%/*}/_archive/proj-stale.md")"
  assert_success
}
