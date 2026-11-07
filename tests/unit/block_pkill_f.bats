#!/usr/bin/env bats
# block-pkill-f.sh: a -f kill pattern is denied, a kill by name or PID is not.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/block-pkill-f.sh"
}

# The hook prints nothing to allow, so an empty reply reads as allow.
decision() {
  local out
  out=$(jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' | bash "$HOOK")
  if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecision <<<"$out"; fi
}

@test "pkill -f is denied in any clause and flag spelling, the reason leading with the hook's name" {
  for c in 'pkill -f foo' 'sleep 1; pkill -9 -f "bats.*x"' 'sudo pkill -f x' 'x && pkill --full y' 'pkill -9f z' 'LC_ALL=C pkill -f w' \
    'bash -c "pkill -f foo"' 'if true; then pkill -f foo; fi' 'timeout 5 pkill -f foo' 'xargs -r pkill -f' \
    'pkill -u me -f foo' 'pkill -U 1000 -f foo' '/usr/bin/pkill -f x' 'echo pkill -f'; do
    run decision "$c"
    assert_output deny
  done
  run bash -c "jq -nc '{tool_input:{command:\"pkill -f x\"}}' | bash '$HOOK' | jq -r .hookSpecificOutput.permissionDecisionReason"
  assert_output --partial 'block-pkill-f: '
  assert_output --partial 'pkill -x <name>'
}

@test "a pgrep -f whose matches get killed is denied" {
  run decision 'kill $(pgrep -f foo)'
  assert_output deny
  run decision 'pgrep -f foo | xargs kill -9'
  assert_output deny
  run decision 'pgrep -f foo | xargs -r sudo kill'
  assert_output deny
}

@test "negative control: a kill by name, a read-only pgrep -f and a broken phrase all pass" {
  for c in 'pkill -x foo' 'pkill foo' 'pkill -9 foo' 'pkill -x foo-fbar' 'pgrep -af claude' 'pgrep -f foo; git checkout -b kill-switch' \
    'pgrep -f x; ls kill/' 'rg -n "pkill[ ]-f" f' 'my-pkill -f x' 'ls -f; pkill -x foo' 'ls'; do
    run decision "$c"
    assert_output allow
  done
}

@test "no tracked script or config line runs a -f kill: the hook guards only agent Bash calls" {
  # A hypr bind runs under sh -c, so a -f pattern kills that shell first and the rest of the line
  # never runs (keybindings.conf Super+Ctrl+R did; waybar/pin.sh's stop had the same form). The
  # hook is the one definition of the bad form, so each line goes through it.
  cd "$BATS_TEST_DIRNAME/../.."
  local line hits=()
  while IFS= read -r line; do
    [ "$(decision "${line#*:*:}")" = allow ] || hits+=("$line")
  done < <(git grep -nwI -e pkill -e pgrep -- . ':!tests' ':!*.md' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)')
  [ "${#hits[@]}" -eq 0 ] || { printf '%s\n' "${hits[@]}"; false; }
}
