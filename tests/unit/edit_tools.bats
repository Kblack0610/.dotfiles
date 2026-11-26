#!/usr/bin/env bats
# .config/agent-panel/edit-tools.conf is the one list of the Claude tools that write a file. Its
# shell reader (.local/lib/edit-tools.sh) and the Python readers (claude-recall, agent-usage-burn.py)
# must read the same names; agent-core's cargo test reads it through include_str!.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  . "$REPO_ROOT/.local/lib/edit-tools.sh"
}

@test "the shell, claude-recall and agent-usage-burn read one edit-tool list" {
  run edit_tools_re
  assert_output 'Edit|Write|MultiEdit|NotebookEdit'
  run edit_tools_json
  assert_output '["Edit","Write","MultiEdit","NotebookEdit"]'
  run python3 -I - "$REPO_ROOT/.local/bin/claude-recall" "$REPO_ROOT/.local/lib/agent-usage-burn.py" <<'PY'
import importlib.machinery, importlib.util, sys
for name, path in (("claude_recall", sys.argv[1]), ("agent_usage_burn", sys.argv[2])):
    loader = importlib.machinery.SourceFileLoader(name, path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(mod)
    got = mod.edit_tools() if name == "claude_recall" else mod.WRITE_TOOLS
    print(name, " ".join(sorted(got)))
PY
  assert_success
  assert_line 'claude_recall Edit MultiEdit NotebookEdit Write'
  assert_line 'agent_usage_burn Edit MultiEdit NotebookEdit Write'
}

@test "edit_tools says so and fails on a list with no names" {
  printf '# only a comment\n\n' > "$SANDBOX/empty.conf"
  EDIT_TOOLS_CONF="$SANDBOX/empty.conf" run --separate-stderr edit_tools_re
  assert_failure
  assert_output ''
  [[ "$stderr" == *"no tool names in $SANDBOX/empty.conf"* ]]
}
