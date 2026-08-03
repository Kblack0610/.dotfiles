# harnesses/opencode.sh - express the role contract as an opencode agent.
#
# opencode has no per-run tool flags (`opencode run --help` offers only --agent,
# --model, --format ...). Capability lives in named agents in opencode.json:
#
#   plan:          tools: {write: false, edit: false, bash: true}
#   build:         tools: {write: true,  edit: true,  bash: true}
#   code-reviewer: mode: subagent, tools: {write: false, edit: false}
#
# So the mapping is role -> --agent <name>. That is only a real guarantee if the
# named agent's grants actually MATCH the contract, so this adapter reads
# opencode.json and compares before running. A role that says ROLE_WRITE=no
# pointed at an agent with write:true must not run: it would look enforced and
# be wide open, which is the exact failure mode this whole design exists to kill.
#
# ROLE_OPENCODE_AGENT overrides the name if the role and the opencode agent are
# not called the same thing; otherwise the role name is used directly (the role
# vocabulary was deliberately aligned with opencode's for this reason).

OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

_opencode_agent_name() { echo "${ROLE_OPENCODE_AGENT:-$ROLE_NAME}"; }

# Compare the opencode agent's grants against the contract. Prints the first
# mismatch and returns 1. Absent config or absent agent is also a refusal.
harness_supports() {
  local agent; agent="$(_opencode_agent_name)"

  if [ ! -r "$OPENCODE_CONFIG" ]; then
    echo "opencode config $OPENCODE_CONFIG is unreadable, so the agent's grants cannot be verified." >&2
    return 1
  fi

  python3 - "$OPENCODE_CONFIG" "$agent" "$ROLE_WRITE" "$ROLE_BASH" <<'PY'
import json, sys
cfg, agent, want_write, want_bash = sys.argv[1:5]
d = json.load(open(cfg))
agents = d.get("agent") or {}
if agent not in agents:
    print(f"opencode.json defines no agent '{agent}'. Define it (with grants matching "
          f"the role) before running this role on opencode.", file=sys.stderr)
    sys.exit(1)
tools = agents[agent].get("tools", {})
# Absent key means opencode's own default, which is permissive. Treat unknown as
# granted: assuming the safe value would be exactly the optimistic guess that
# makes an unenforced role look enforced.
got_write = bool(tools.get("write", True)) or bool(tools.get("edit", True))
got_bash  = bool(tools.get("bash",  True))
bad = []
if want_write == "no" and got_write:
    bad.append(f"role denies writes but opencode agent '{agent}' grants write/edit "
               f"(tools={tools})")
if want_bash == "no" and got_bash:
    bad.append(f"role denies bash but opencode agent '{agent}' grants bash (tools={tools})")
if bad:
    for b in bad: print(b, file=sys.stderr)
    print("Refusing to run: the harness cannot enforce this role. Fix opencode.json "
          "or run this role on a harness that can.", file=sys.stderr)
    sys.exit(1)
PY
}

harness_exec() {
  local agent; agent="$(_opencode_agent_name)"

  # ROLE_MCP is NOT translated here. opencode's MCP set lives in opencode.json's
  # `mcp` block, not on the command line, so this adapter cannot pin it per-run.
  # Deliberately loud rather than silently ignored: an operator who set
  # ROLE_MCP=none has a reason to expect zero servers.
  if [ "$ROLE_MCP" != "inherit" ]; then
    echo "agentctl-run: note - ROLE_MCP='$ROLE_MCP' is not enforceable per-run on opencode;" >&2
    echo "  its server set comes from the 'mcp' block in $OPENCODE_CONFIG." >&2
  fi

  local flags=(--agent "$agent")

  if [ -n "${AGENTCTL_EXPLAIN:-}" ]; then
    printf 'harness:     opencode\nflags:      '
    printf ' %q' "${flags[@]}"
    printf '\n'
    return 0
  fi

  exec opencode run "${flags[@]}" "$@"
}
