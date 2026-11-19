#!/usr/bin/env bats
# tests/lint-head.awk: the match behind tests/lint.sh house rule 3, any command piped into head
# under pipefail (ar-1795, ar-2218, ar-2499). Each case is a script line it must flag or must
# pass, so a change to the word boundaries, the case-arm strip or the quote scanner shows here,
# not as a silently quiet gate.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  AWK="$BATS_TEST_DIRNAME/../lint-head.awk"
}

# hits TEXT -> what lint-head.awk prints for a script holding TEXT.
hits() { printf '%s\n' "$1" | awk -f "$AWK"; }

@test "each producer piped into head is flagged, at its line" {
  local p
  for p in "jq -r .a f" "grep x f" "sed -n p f" "tr a b <f" "awk 1 f" "sort f" "cut -f1 f" \
    "printf '%s\\n' \"\$v\"" "find d -name x" "compgen -G 'd/*'" "git ls-files" "rbw get k" \
    "my_func a" "git-grep x" "cmd"; do
    run hits $'x=1\n'"v=\$($p | head -1)"
    assert_output "2:v=\$($p | head -1)"
  done
  run hits 'sort -rn f|head -n 3'
  assert_output '1:sort -rn f|head -n 3'
}

@test "a pipe inside a quoted program or alternation does not hide the head after it" {
  run hits "c=\"\$(jq -r 'select(.cwd? | type == \"string\") | .cwd' f | head -1)\""
  assert_output --partial '1:'
  run hits 'grep -E "a|b|c" f | head -6'
  assert_output --partial '1:'
}

@test "a pipeline continued over lines is flagged at its first line" {
  run hits $'grep x f \\\n  | head -1'
  assert_output --partial '1:grep x f'
  run hits $'grep x f |\n  head -1'
  assert_output --partial '1:grep x f'
  run hits $'s=$(cmd | jq -r \'\n  select(.a | .b)\n  | .c\' | head -1)'
  assert_output --partial '1:s=$(cmd | jq -r'
}

@test "the fixed forms, a || and quoted text pass" {
  local ok
  for ok in "grep -m1 x f | cut -d= -f2" "sed -n '/^a: /{s///p;q;}' f" "sort f | awk 'NR<=3'" \
    "find d -name x -print -quit" "a || head -1 f" "head -n 5 f | cut -f4" "echo 'grep x | head -1'" \
    "adb shell \"dumpsys x | grep y | head -1\"" "# grep x f | head -1"; do
    run hits "$ok"
    assert_success
    assert_output ''
  done
}

@test "a heredoc body is data, and an apostrophe in it does not blind the lines after it" {
  run hits $'cat <<EOF\nit\'s grep x | head\nEOF\ngrep y f | head -1'
  assert_output '4:grep y f | head -1'
  run hits $'cat <<\'EOF\'\nsort | head\nEOF\necho "don\'t"\nsort f | head -2'
  assert_output '5:sort f | head -2'
}

@test "a case arm's pattern list is alternation, not a pipe into head" {
  run hits $'case "$1" in repo | match | head | review) return 0 ;; esac'
  assert_output ''
  run hits $'case $1 in\n  a) x ;; b | head) y ;;\n  repo | head) z ;;\nesac'
  assert_output ''
  run hits $'case $1 in a) v=$(f | head -1) ;; esac'
  assert_output --partial '1:'
  run hits '(cd d && git ls-files | head -1)'
  assert_output --partial '1:'
  run hits 'x=$(grep in f | head -1)'
  assert_output --partial '1:'
  run hits $'(\n  cd d\n  git ls-files | head -1)'
  assert_output --partial '3:'
}
