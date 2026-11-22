#!/usr/bin/env bats
# agentctl-run: a print call's input travels on stdin end to end, for claude and opencode alike.
# An argument is capped at 128 KiB by the kernel (E2BIG), and inbox-triage's prompt, every open row
# of a project, outgrew it on 2026-11-05.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"

  # A role fixture written INLINE, not copied. The real roles live in the private overlay
  # (`.config/agentctl/` is gitignored here), so a public test that read them would pass on
  # this machine and fail in CI — and reading the deployed ~/.config copy would assert this
  # box's provisioning state rather than the contract. The fixture only has to be a valid
  # role; which capabilities it grants is irrelevant to how the input travels.
  mkdir -p "$HOME/.config/agentctl/roles"
  cat > "$HOME/.config/agentctl/roles/fixture.role" <<'ROLE'
ROLE_DESC="test fixture; capabilities are irrelevant to this contract"
ROLE_WRITE=no
ROLE_TASK=no
ROLE_BASH=yes
ROLE_MCP=none
ROLE_MCP_DENY=""
ROLE_APPROVE="Read,Glob,Grep,Bash"
ROLE

  # ROLE_MCP=none names an MCP set, so the set has to EXIST. agentctl-run fails closed
  # (exit 78) on an unreadable one rather than inheriting the user-scope server list --
  # that refusal is the contract, so the fixture must satisfy it instead of tripping it.
  mkdir -p "$HOME/.config/agentctl/mcp"
  printf '{"mcpServers":{}}
' > "$HOME/.config/agentctl/mcp/none.json"
}

stub_claude_io() {
  cat > "$SANDBOX/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$SANDBOX/claude-argv.txt"
cat > "$SANDBOX/claude-stdin.txt"
EOF
  chmod +x "$SANDBOX/bin/claude"
}

@test "a print call's input reaches claude on stdin, not as an argument" {
  stub_claude_io
  run "$RUN" --role fixture -p "the input"
  assert_success
  assert_equal "$(cat "$SANDBOX/claude-stdin.txt")" "the input"
  run grep -qx 'the input' "$SANDBOX/claude-argv.txt"
  assert_failure
}

@test "-p with no value reads the input from stdin, past the 128 KiB argument cap" {
  stub_claude_io
  run bash -c "head -c 200000 /dev/zero | tr '\\0' x | '$RUN' --role fixture -p --max-turns 3"
  assert_success
  assert_equal "$(tr -d '\n' < "$SANDBOX/claude-stdin.txt" | wc -c)" 200000
  run grep -qx -- '--max-turns' "$SANDBOX/claude-argv.txt"
  assert_success
}

# opencode takes its message from stdin too: `opencode run` appends piped stdin to it.
stub_opencode_io() {
  cat > "$SANDBOX/bin/opencode" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$SANDBOX/opencode-argv.txt"
cat > "$SANDBOX/opencode-stdin.txt"
EOF2
  chmod +x "$SANDBOX/bin/opencode"
  # the shipped routes each name their harness, so opencode needs one of its own
  mkdir -p "$HOME/.config/agentctl/routes"
  printf 'ROUTE_DESC=fixture\nROUTE_TRANSPORT=anthropic-native\nROUTE_PAYER=subscription\nROUTE_PERSONAL_SAFE=yes\nROUTE_WORK_SAFE=yes\nROUTE_FALLBACK_SAFE=yes\n' > "$HOME/.config/agentctl/routes/ocfix.route"
  mkdir -p "$HOME/.config/opencode"
  printf '{"agent":{"fixture":{"tools":{"write":false,"edit":false,"bash":true}}}}\n' > "$HOME/.config/opencode/opencode.json"
}

@test "opencode: a print call's input reaches it on stdin, not as an argument" {
  stub_opencode_io
  run "$RUN" --harness opencode --route ocfix --role fixture -p "the input"
  assert_success
  assert_equal "$(cat "$SANDBOX/opencode-stdin.txt")" "the input"
  assert_equal "$(cat "$SANDBOX/opencode-argv.txt")" "$(printf 'run\n--agent\nfixture')"
}

@test "opencode: a 128 KiB-plus input still runs, on stdin past the argument cap" {
  stub_opencode_io
  run bash -c "head -c 200000 /dev/zero | tr '\\0' x | '$RUN' --harness opencode --route ocfix --role fixture -p --model m"
  assert_success
  assert_equal "$(tr -d '\n' < "$SANDBOX/opencode-stdin.txt" | wc -c)" 200000
  run grep -qx -- '--model' "$SANDBOX/opencode-argv.txt"
  assert_success
  run grep -qx -- '-p' "$SANDBOX/opencode-argv.txt"
  assert_failure
}
