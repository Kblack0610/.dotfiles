#!/usr/bin/env bats
# large-read-guard.py: a whole-file Read or cat of a file over 2,000 lines is denied; a sliced one is not.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/large-read-guard.py"
  D="$BATS_TEST_TMPDIR"
  seq 1 2500 > "$D/big.txt"
  seq 1 1999 > "$D/small.txt"
  { printf 'x\0y\n'; seq 1 3000; } > "$D/blob.dat"
  seq 1 3000 > "$D/page.png"
}

# The hook prints nothing to allow, so an empty reply reads as allow.
read_decision() {
  local out
  out=$(jq -nc --argjson i "$1" '{tool_name:"Read", tool_input:$i}' | python3 "$HOOK")
  if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecision <<<"$out"; fi
}

bash_decision() {
  local out
  out=$(jq -nc --arg c "$1" --arg d "$D" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | python3 "$HOOK")
  if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecision <<<"$out"; fi
}

@test "a Read with no limit of a file over 2,000 lines is denied, the reason naming the hook and rg" {
  run read_decision "{\"file_path\":\"$D/big.txt\"}"
  assert_output deny
  run read_decision "{\"file_path\":\"$D/big.txt\",\"offset\":100}"
  assert_output deny
  run bash -c "jq -nc --arg f '$D/big.txt' '{tool_name:\"Read\", tool_input:{file_path:\$f}}' | python3 '$HOOK' | jq -r .hookSpecificOutput.permissionDecisionReason"
  assert_output --partial 'large-read-guard: '
  assert_output --partial 'rg -n -C 8'
}

@test "negative control: a Read with a limit, a short file, a binary and a missing file are allowed" {
  run read_decision "{\"file_path\":\"$D/big.txt\",\"limit\":200}"
  assert_output allow
  run read_decision "{\"file_path\":\"$D/big.txt\",\"offset\":2000,\"limit\":500}"
  assert_output allow
  run read_decision "{\"file_path\":\"$D/small.txt\"}"
  assert_output allow
  run read_decision "{\"file_path\":\"$D/blob.dat\"}"
  assert_output allow
  run read_decision "{\"file_path\":\"$D/page.png\"}"
  assert_output allow
  run read_decision "{\"file_path\":\"$D/nope.txt\"}"
  assert_output allow
}

@test "a cat whose output reaches the context is denied, in any clause" {
  for c in 'cat big.txt' "cat $D/big.txt" 'cat -n big.txt' 'ls; cat small.txt big.txt' 'true && cat big.txt' 'LC_ALL=C cat big.txt' '/bin/cat big.txt' 'cat "big.txt"'; do
    run bash_decision "$c"
    assert_output deny
  done
}

@test "negative control: a piped, redirected, captured or short cat is allowed" {
  for c in 'cat big.txt | head -n 5' 'cat big.txt | wc -l' 'cat big.txt > out.txt' 'cat big.txt >> out.txt' 'x=$(cat big.txt); echo ${#x}' 'cat small.txt' 'cat blob.dat' \
    'rg -n 5 big.txt' 'echo "cat big.txt"' "cat <<'EOF' > f.txt
cat big.txt
EOF" 'cat'; do
    run bash_decision "$c"
    assert_output allow
  done
}

@test "a background Bash, other tools and bad input fail open" {
  run bash -c "jq -nc --arg d '$D' '{tool_name:\"Bash\", cwd:\$d, tool_input:{command:\"cat big.txt\", run_in_background:true}}' | python3 '$HOOK'"
  assert_output ''
  run bash -c "jq -nc '{tool_name:\"Grep\", tool_input:{pattern:\"x\"}}' | python3 '$HOOK'"
  assert_output ''
  run bash -c "echo 'not json' | python3 '$HOOK'"
  assert_success
  assert_output ''
  run bash_decision "cat 'unbalanced"
  assert_output allow
}

@test "settings.json wires the guard on Read and Bash, and the old hint is gone" {
  local settings="$BATS_TEST_DIRNAME/../../.claude/settings.json"
  run jq -r '.hooks.PreToolUse[] | select(.hooks[].command | test("large-read-guard")) | .matcher' "$settings"
  assert_output 'Read|Bash'
  run grep -c 'large-file-warning' "$settings"
  assert_output 0
}
