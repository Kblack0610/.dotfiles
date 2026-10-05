#!/usr/bin/env bats
# What the eval judge is fed: transcript-extractor.sh and rules-loader.sh. Both failed
# silently - the judge saw no user turns at all, and a rules file lost everything after
# its first horizontal rule - so these pin the input the judge must receive.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  LIB="$BATS_TEST_DIRNAME/../../.claude/hooks/lib"
  . "$LIB/transcript-extractor.sh"
  . "$LIB/rules-loader.sh"
  T="$BATS_TEST_TMPDIR/t.jsonl"
}

@test "Claude Code user turns reach the judge as USER lines" {
  {
    echo '{"type":"user","message":{"role":"user","content":"please fix the bug"}}'
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
  } > "$T"
  run extract_transcript "$T"
  assert_line --index 0 "USER: please fix the bug"
  assert_line --index 1 "ASSISTANT: done"
}

@test "a user line carrying only a tool_result is not emitted as an empty turn" {
  echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}' > "$T"
  run extract_transcript "$T"
  assert_output ""
}

@test "frontmatter on line 1 is stripped" {
  printf -- '---\nname: x\n---\nbody\n' > "$T"
  run strip_frontmatter "$T"
  assert_output "body"
}

@test "a horizontal rule mid-file is kept, and so is everything after it" {
  printf -- '# Rules\nfirst\n---\nsecond\n---\nthird\n' > "$T"
  run strip_frontmatter "$T"
  assert_output "$(printf -- '# Rules\nfirst\n---\nsecond\n---\nthird')"
}
