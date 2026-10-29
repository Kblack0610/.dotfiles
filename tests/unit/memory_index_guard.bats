#!/usr/bin/env bats
# memory-index-guard.sh: warns when a write leaves an auto-memory index over budget.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/memory-index-guard.sh"
  DIR="$BATS_TEST_TMPDIR/proj/memory"
  mkdir -p "$DIR"
  IDX="$DIR/MEMORY.md"
}

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
