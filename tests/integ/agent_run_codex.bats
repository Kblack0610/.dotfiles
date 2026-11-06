#!/usr/bin/env bats
# agentctl-run on HARNESS=codex: the role contract as `codex exec` flags, the chatgpt route, and
# the calls.jsonl line folded from codex's --json events. The codex binary is a stub that records
# its argv and stdin and prints a canned event stream; the routes are the shipped ones.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"
  mkdir -p "$HOME/.config/agentctl/roles" "$HOME/.config/agentctl/mcp"
  printf '{"mcpServers":{}}\n' > "$HOME/.config/agentctl/mcp/none.json"
  printf '{"mcpServers":{"docs":{"command":"docs-mcp","args":["--stdio"]}}}\n' > "$HOME/.config/agentctl/mcp/docs.json"
  role observe no yes no none
  role build yes yes yes docs
  role nobash yes no no none

  cat > "$SANDBOX/bin/codex" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "mcp list" ]; then echo '[{"name":"docs","enabled":true},{"name":"adb","enabled":true}]'; exit 0; fi
printf '%s\n' "\$@" > "$SANDBOX/codex-argv.txt"
cat > "$SANDBOX/codex-stdin.txt"
echo '{"type":"thread.started","thread_id":"th-1"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"{\"ok\":true}"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":40,"output_tokens":7}}'
EOF
  chmod +x "$SANDBOX/bin/codex"
}

# role NAME WRITE BASH TASK MCP
role() {
  cat > "$HOME/.config/agentctl/roles/$1.role" <<ROLE
ROLE_DESC="fixture $1"
ROLE_WRITE=$2
ROLE_BASH=$3
ROLE_TASK=$4
ROLE_MCP=$5
ROLE_MCP_DENY=""
ROLE_APPROVE="Read"
ROLE
}

codex_run() { run "$RUN" --harness codex --data-class public "$@"; }
argv() { cat "$SANDBOX/codex-argv.txt"; }

@test "a role that denies writes runs in codex's read-only sandbox, with no subagents and no ambient servers" {
  codex_run --role observe -p "look"
  assert_success
  run argv
  assert_line -- '--sandbox'
  assert_line 'read-only'
  assert_line 'multi_agent'
  assert_line 'mcp_servers.docs.enabled=false'
  assert_line 'mcp_servers.adb.enabled=false'
  refute_line -- '--dangerously-bypass-approvals-and-sandbox'
}

@test "a writing role drops the sandbox and pins MCP to its set: off-set servers disabled, the set's added inline" {
  codex_run --role build -p "build"
  assert_success
  run argv
  assert_line -- '--dangerously-bypass-approvals-and-sandbox'
  assert_line 'mcp_servers.adb.enabled=false'
  refute_line 'mcp_servers.docs.enabled=false'
  assert_line 'mcp_servers.docs={command="docs-mcp", args=["--stdio"], env={}}'
  refute_line 'multi_agent'
}

@test "a role that denies bash but grants writes is refused: codex cannot remove its shell (negative control)" {
  codex_run --role nobash -p "x" --explain
  assert_failure
  assert_output --partial 'cannot remove its shell'
  [ ! -e "$SANDBOX/codex-argv.txt" ] || fail "codex ran for a role it cannot enforce"
}

@test "the prompt goes in on stdin under the headless rule, never as an argument" {
  codex_run --role observe -p "the input"
  assert_success
  grep -q 'running headless' "$SANDBOX/codex-stdin.txt" || fail "no headless rule on stdin"
  grep -qx 'the input' "$SANDBOX/codex-stdin.txt" || fail "the prompt is not on stdin"
  run grep -qx 'the input' "$SANDBOX/codex-argv.txt"
  assert_failure
}

@test "a Claude model id on codex is refused before codex runs" {
  AGENTCTL_MODEL=claude-opus-5-5 codex_run --role observe -p "x"
  assert_failure
  assert_output --partial 'not a Codex model'
  [ ! -e "$SANDBOX/codex-argv.txt" ] || fail "codex ran on a Claude id"
}

@test "codex defaults to the chatgpt route, which refuses personal data until the human says otherwise" {
  run "$RUN" --harness codex --role observe -p "x" --explain
  assert_equal "$status" 78
  assert_output --partial 'REFUSED'
  codex_run --role observe -p "x" --explain
  assert_success
  assert_output --partial 'route:       chatgpt'
}

@test "a named run records one calls.jsonl line from codex's events: the thread, tokens, no dollars" {
  export AGENTCTL_NAME=codex-test AGENTCTL_CALLS="$SANDBOX/calls.jsonl" AGENTCTL_MODEL=gpt-6-luna
  codex_run --role observe -p "x"
  assert_success
  run jq -r '[.harness, .session_id, ."gen_ai.response.model", ."gen_ai.usage.input_tokens", .cache_read_tokens, (.cost_usd | tostring)] | join(" ")' "$AGENTCTL_CALLS"
  assert_output 'codex th-1 gpt-6-luna 10 40 null'
  run argv
  assert_line 'gpt-6-luna'
}
