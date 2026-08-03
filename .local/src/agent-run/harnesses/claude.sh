# harnesses/claude.sh - express the role contract as Claude Code flags.
#
# Mapping (docs/contract.md has the table):
#   denials      -> --disallowedTools     the ONLY lever that removes a capability
#   ROLE_APPROVE -> --allowedTools        pre-approve only; stops a headless hang
#   ROLE_MCP     -> --mcp-config + --strict-mcp-config
#
# --allowedTools is the trap. Measured 2026-07-28: a run given
# --allowedTools "Read,Glob,Grep" (no Write, no Bash) was told to Write a file and
# DID. It pre-approves what it names and removes nothing. The same prompt under
# --disallowedTools "Write,Edit" answered CANNOT and left the file byte-identical.

# harness_supports - claude can enforce every key in the current contract.
# Returns 0 (supported) or prints why and returns 1. See contract rule 3.
harness_supports() {
  # --disallowedTools covers Write/Edit/Task/Bash and mcp__* families, and
  # --strict-mcp-config pins the server set. Nothing in the vocabulary is
  # inexpressible here, so there is no honest reason to refuse.
  #
  # The ROLE_WRITE=no + ROLE_BASH=yes hole is NOT a support failure: the role is
  # enforced exactly as specified, and the contract itself documents that shell
  # access defeats a write denial on every harness. Refusing here would just make
  # every observe-shaped role unrunnable.
  return 0
}

harness_exec() {
  local mcp_file denied
  mcp_file="$(role_mcp_file)"
  denied="$(role_denied_tools)"

  local flags=()
  [ -n "$ROLE_APPROVE" ] && flags+=(--allowedTools "$ROLE_APPROVE")
  [ -n "$denied" ]       && flags+=(--disallowedTools "$denied")

  # A role that writes needs edits auto-accepted or it stalls; one that does not
  # write has nothing to accept, so it stays on the stricter default.
  if [ "$ROLE_WRITE" = "yes" ]; then flags+=(--permission-mode acceptEdits)
  else                               flags+=(--permission-mode default)
  fi

  [ -n "$mcp_file" ] && flags+=(--mcp-config "$mcp_file" --strict-mcp-config)

  # There is no human on a timer to answer a prompt or read a plan file. Mirrors
  # the prompt agentctl-dream and agentctl-nightly-sync already use.
  flags+=(--append-system-prompt 'You are running headless on a timer with no human present. Never enter plan mode, never write a plan file, and never ask for approval - there is nobody to answer. Execute the task directly and report what you did.')

  if [ -n "${AGENTCTL_EXPLAIN:-}" ]; then
    printf 'harness:     claude\nflags:      '
    printf ' %q' "${flags[@]}"
    printf '\n'
    return 0
  fi

  exec claude "${flags[@]}" "$@"
}
