# shellcheck shell=bash
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

  # --dangerously-skip-permissions, deliberately, and it does NOT weaken the role.
  #
  # Measured 2026-07-28 as a paired control, same prompt and flags except the
  # denylist:
  #   skip-permissions, no denylist   -> file became CHANGED (wrote)
  #   skip-permissions, with denylist -> file stayed ORIGINAL (blocked)
  # So denials bind independently of the permission gate. The gate governs
  # PROMPTING; the denylist governs CAPABILITY.
  #
  # It is the right choice here because every caller is a timer with no human:
  # --permission-mode would stall waiting for an approval nobody will give.
  # agentctl-dream lost 17 nights of sweeps to exactly that (settings.json sets
  # defaultMode:plan, which a headless --print inherits) and nightly-sync then
  # repeated it from 07-22, writing zero mem0 entries while still exiting 0.
  flags+=(--dangerously-skip-permissions)

  [ -n "$mcp_file" ] && flags+=(--mcp-config "$mcp_file" --strict-mcp-config)

  # There is no human on a timer to answer a prompt or read a plan file. Mirrors
  # the prompt agentctl-dream and agentctl-nightly-sync already use. A run with no
  # --print is a timer's pass in a tmux window (fleet-shepherd), which a human may
  # attach to and type into, so it answers them, but still never waits on one.
  local print=0 a i input="" args=("$@")
  for a in "$@"; do case "$a" in -p|--print) print=1 ;; esac; done
  # The print call's input goes to claude on stdin, never as an argument: an argument is
  # capped at 128 KiB (E2BIG), and an agent's PROMPT file is prepended to it.
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
      -p|--print)
        if [ $((i + 1)) -lt ${#args[@]} ] && [ "${args[i + 1]:0:1}" != - ]; then
          input="${args[i + 1]}"
          args=("${args[@]:0:i+1}" "${args[@]:i+2}")
        fi
        break ;;
    esac
  done
  set -- "${args[@]+"${args[@]}"}"
  local cap; cap="$(budget_call_usd)"
  if [ "$print" = 1 ] && [ -n "$cap" ]; then flags+=(--max-budget-usd "$cap"); fi
  if [ "$print" = 1 ] && [ -n "${AGENT_SCHEMA:-}" ]; then flags+=(--json-schema "$(jq -c . "$AGENT_SCHEMA")"); fi
  if [ "$print" = 1 ]; then
    flags+=(--append-system-prompt 'You are running headless on a timer with no human present. Never enter plan mode, never write a plan file, and never ask for approval - there is nobody to answer. Execute the task directly and report what you did.')
  else
    flags+=(--append-system-prompt 'You are a scheduled run in a tmux window that a human may attach to. Nobody is waiting on you when you start: never enter plan mode, never write a plan file, and never ask for approval. Execute the task directly and report what you did. If a human types to you, answer them.')
  fi

  if [ -n "${AGENTCTL_EXPLAIN:-}" ]; then
    printf 'harness:     claude\nflags:      '
    printf ' %q' "${flags[@]}"
    printf '\n'
    return 0
  fi
  [ -z "$input" ] || exec 0<<<"$input"

  # A named print call (an --agent, or a runner by its unit's AGENTCTL_NAME) is recorded
  # (lib/calls.sh): the JSON result carries the session id, tokens and cost, which the day
  # budget sums, and the caller still gets plain text. A caller that chose its own
  # --output-format keeps it, unrecorded.
  if [ -n "$(calls_name)" ] && [ "$print" = 1 ]; then
    local own=0
    for a in "$@"; do case "$a" in --output-format|--output-format=*) own=1 ;; esac; done
    if [ "$own" = 0 ]; then
      calls_record claude claude --output-format json "${flags[@]}" "$@"
      exit $?
    fi
  fi

  exec claude "${flags[@]}" "$@"
}
