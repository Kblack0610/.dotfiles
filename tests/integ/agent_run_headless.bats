#!/usr/bin/env bats
# agentctl-run: the runner choke point publishes "no human is watching" as an env fact.
#
# Every caller of agentctl-run is a timer. Surfaces OUTSIDE the harness need to know that
# — the Focus gate (86-focus-reconcile.sh) blocks a turn that changed code without
# declaring it on the human's daily `## Focus`, and on a timer there is nobody to answer,
# so the agent complied the only way it could: `focus add` then `focus done`. One
# 10-minute captain-watchdog pass put 45 of those into 2026-08-04's note.
#
# It is asserted HERE rather than at each runner because there are seven `claude -p`
# callers; a marker set per-call-site is one unrelated edit away from being lost.

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
  # role; which capabilities it grants is irrelevant to whether the marker is exported.
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

  # Stub the harness's exec target, not agentctl-run itself: the export has to survive
  # all the way through `exec claude`, which is the only thing the Focus gate ever sees.
  SEEN="$SANDBOX/claude-env.txt"
  cat > "$SANDBOX/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'CLAUDE_HEADLESS=%s\n' "\${CLAUDE_HEADLESS:-<unset>}" > "$SEEN"
exit 0
EOF
  chmod +x "$SANDBOX/bin/claude"
}

@test "a dispatched run exports CLAUDE_HEADLESS=1 to the harness" {
  run "$RUN" --role fixture -p "anything"
  assert_success
  assert_equal "$(cat "$SEEN")" "CLAUDE_HEADLESS=1"
}

@test "the export is harness-agnostic -- it is set before the harness is chosen" {
  # Guards the placement. If the export were moved into harnesses/claude.sh, this file
  # would still pass the test above while every non-claude harness silently lost it.
  # Reading the source is the only way to assert WHERE, so assert it deliberately.
  run grep -n 'export CLAUDE_HEADLESS=1' "$RUN"
  assert_success
  run grep -c 'CLAUDE_HEADLESS' "$REPO_ROOT/.local/src/agent-run/harnesses/claude.sh"
  assert_output "0"
}

@test "the marker is not something a role can turn off" {
  # A role file sets capability, never whether a human is present. If a role could unset
  # this, a headless run would start writing to the daily note again and nothing would say
  # so -- the silent-success failure mode this suite exists to catch.
  run grep -rn "CLAUDE_HEADLESS" "$HOME/.config/agentctl/roles"
  assert_failure
}

# ---------------------------------------------------------------- interactive
#
# `agentctl run` at a terminal sets AGENTCTL_INTERACTIVE=1, because on that path
# the marker above would be a LIE: a human IS watching, and the Focus gate this
# file exists to protect SHOULD fire for a human-initiated turn.
#
# The danger in adding a second mode is that "interactive" quietly becomes
# "unenforced". These four tests exist to hold that line: the mode may change
# what the model is TOLD and whether it may PROMPT, and nothing else.

@test "interactive: the headless marker is not exported (a human IS watching)" {
  AGENTCTL_INTERACTIVE=1 run "$RUN" --role fixture -p "anything"
  assert_success
  assert_equal "$(cat "$SEEN")" "CLAUDE_HEADLESS=<unset>"
}

@test "interactive still passes --disallowedTools -- capability is NOT a mode" {
  # THE test of the pair. --dangerously-skip-permissions governs PROMPTING and
  # --disallowedTools governs CAPABILITY; that distinction was measured (see
  # harnesses/claude.sh). If interactive ever dropped the denylist it would be a
  # far worse bug than the one the mode fixes, and it would look like a feature.
  AGENTCTL_EXPLAIN=1 AGENTCTL_INTERACTIVE=1 run "$RUN" --role fixture --explain
  assert_success
  assert_output --partial '--disallowedTools'
}

@test "interactive drops ONLY the two prompting flags" {
  AGENTCTL_EXPLAIN=1 AGENTCTL_INTERACTIVE=1 run "$RUN" --role fixture --explain
  refute_output --partial '--dangerously-skip-permissions'
  refute_output --partial '--append-system-prompt'
}

@test "...and headless still carries both, so the test above is not vacuous" {
  AGENTCTL_EXPLAIN=1 run "$RUN" --role fixture --explain
  assert_success
  assert_output --partial '--dangerously-skip-permissions'
  assert_output --partial '--append-system-prompt'
  assert_output --partial '--disallowedTools'
}
