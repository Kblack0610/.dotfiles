#!/usr/bin/env bats
# claude-recall search reads files newest first and skips what cannot match: a file last written
# before --since, and, once --limit hits are kept, every file older than the oldest of them.
# The hits must equal the full scan's (--all-files), so each case compares the two.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  RECALL="$REPO_ROOT/.local/bin/claude-recall"
  CORPUS="$BATS_TEST_TMPDIR/corpus"
  export CLAUDE_TRANSCRIPTS="$CORPUS"
  mkdir -p "$CORPUS/-home-u-proj"

  # rec <id> <timestamp> <message content as JSON> [mtime]: one record; the file's mtime is the
  # timestamp unless given
  rec() {
    printf '{"type":"user","cwd":"/home/u/proj","timestamp":"%s","message":{"role":"user","content":%s}}\n' \
      "$2" "$3" >> "$CORPUS/-home-u-proj/$1.jsonl"
    touch -d "${4:-$2}" "$CORPUS/-home-u-proj/$1.jsonl"
  }
  for d in 10 15 18 20 22 23; do
    rec "s$d" "2026-11-${d}T10:00:00Z" "\"alpha marker $d\""
  done
  hits() { printf '%s\n' "$output" | sed '$d'; }   # the matches without the trailing note
}

@test "limit stops at the first file older than the oldest kept hit" {
  run "$RECALL" search alpha --limit 2 --context 20
  assert_success
  assert_output --partial "2 match(es) (older files not read"
  assert_output --partial "alpha marker 23"
  assert_output --partial "alpha marker 22"
  refute_output --partial "marker 20"
  early=$(hits)
  run "$RECALL" search alpha --limit 2 --context 20 --all-files
  assert_success
  refute_output --partial "older files not read"
  assert_equal "$early" "$(hits)"
}

@test "--since skips a file last written before it, and keeps every hit on or after" {
  run "$RECALL" search alpha --since 2026-11-20 --limit 0 --context 20
  assert_success
  assert_output --partial "3 match(es) (older files not read"
  refute_output --partial "marker 18"
  skipped=$(hits)
  run "$RECALL" search alpha --since 2026-11-20 --limit 0 --context 20 --all-files
  assert_success
  assert_equal "$skipped" "$(hits)"
}

@test "an mtime older than its records hides a hit, and --all-files finds it" {
  rec restored 2026-11-23T11:00:00Z '"alpha restored backup"' 2026-11-01T00:00:00Z
  run "$RECALL" search "restored backup" --since 2026-11-20 --context 20
  assert_output --partial "0 match(es)"
  run "$RECALL" search "restored backup" --since 2026-11-20 --context 20 --all-files
  assert_output --partial "1 match(es)"
}

@test "the default limit is 20, newest first" {
  for n in $(seq 1 25); do rec bulk "2026-11-23T11:00:$(printf '%02d' "$n")Z" "\"bulkterm $n\""; done
  run "$RECALL" search bulkterm --context 20
  assert_success
  assert_output --partial "20 match(es)"
  assert_output --partial "bulkterm 25"
  refute_output --partial "bulkterm 5"
}

@test "without rg, terms the raw-line check cannot pass through still match: framing, quotes, non-ASCII, case" {
  NORG="$BATS_TEST_TMPDIR/norg"   # a PATH with python3 and no rg, so the raw-line check is the only prefilter
  mkdir -p "$NORG"
  ln -s "$(command -v python3)" "$NORG/python3"
  printf '{"type":"assistant","cwd":"/home/u/proj","timestamp":"2026-11-23T12:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls x"}}]}}\n' > "$CORPUS/-home-u-proj/tool.jsonl"
  rec quoted 2026-11-23T12:01:00Z '"he said \"hi there\" twice"'
  rec utf 2026-11-23T12:02:00Z '"café au lait"'
  rec utf2 2026-11-23T12:03:00Z '"caf\u00e9 au lait"'
  rec mixed 2026-11-23T12:04:00Z '"Mixed CASE Word"'
  for t in "use Bash" '"hi there"' "café" "tool_use Bash"; do
    run env PATH="$NORG" "$RECALL" search "$t" --context 20
    assert_success
    refute_output --partial "0 match(es)"
    full=$(hits)
    run env PATH="$NORG" "$RECALL" search "$t" --context 20 --all-files
    assert_equal "$full" "$(hits)"
  done
  run env PATH="$NORG" "$RECALL" search "café" --context 20
  assert_output --partial "2 match(es)"
  run env PATH="$NORG" "$RECALL" search "mixed case" -i --context 20
  assert_output --partial "1 match(es)"
}
