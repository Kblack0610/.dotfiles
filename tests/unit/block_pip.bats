#!/usr/bin/env bats
# block-pip.py: bare pip install is denied, uv's own pip is not; walker-guards.py runs it, and
# forge-guard's walker reads the words, so pip in quoted or grepped text is not a command.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOKS="$BATS_TEST_DIRNAME/../../.claude/hooks"
}

cmd() { jq -nc --arg c "$1" '{tool_name:"Bash", cwd:"/tmp", tool_input:{command:$c}}' | python3 "${HOOK:-$HOOKS/block-pip.py}"; }

@test "bare pip install is denied in any clause or spelling, the reason leading with the hook's name" {
  run cmd 'pip install requests'
  assert_success
  run jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output"
  assert_output --partial 'block-pip: Use `uv add'
  for c in 'uv pip install x && pip3 install y' 'python3 -m pip install x' 'cd /tmp; pip install x' \
    'bash -c "pip install x"' 'ls | xargs pip install' '/usr/bin/pip install x' 'uv run pip install x'; do
    run cmd "$c"
    assert_output --partial '"deny"'
  done
}

@test "uv pip install, quoted or grepped text and other commands pass" {
  for c in 'uv pip install requests' 'ls' "rg 'pip install' ." 'git commit -m "docs: say pip install less"' \
    'echo "run: pip install x"' 'pip list' 'pipx install x' $'cat <<EOF\npip install x\nEOF'; do
    run cmd "$c"
    assert_success
    assert_output ''
  done
}

@test "walker-guards runs it: the same deny and the same pass through the one process" {
  HOOK="$HOOKS/walker-guards.py" run cmd 'pip install x'
  assert_output --partial 'block-pip: Use `uv add'
  HOOK="$HOOKS/walker-guards.py" run cmd "rg 'pip install' ."
  assert_output ''
}
