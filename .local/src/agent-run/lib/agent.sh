# shellcheck shell=bash
# lib/agent.sh - `agentctl-run --agent <name>`: one model call, defined by one conf.
#
# A registered agent is a conf in the agentctl roster (~/.config/agentctl/agents/<name>.conf).
# For a model call made inside another script (a judge, a sweep), the conf is KIND=call: no
# COMMAND and no unit, because its caller starts it. The conf is the one source for what the
# call may do (ROLE), what it runs on (MODEL, ROUTE, DATA_CLASS) and what it is told (PROMPT,
# a git-tracked file). Ambient ROLE/MODEL/ROUTE from a parent runner's conf are ignored: the
# fleet-dispatch runner is ROLE=build, and its judge must not inherit that.
#
# What an agent is: ~/.config/agentctl/README.md, "What an agent is".

AGENTCTL_CONF_DIR="${AGENTCTL_CONF_DIR:-$HOME/.config/agentctl/agents}"

# agent_load <name> -> AGENT_KIND AGENT_ROLE AGENT_MODEL AGENT_PROMPT AGENT_PROMPT_SHA
#                      AGENT_ROUTE AGENT_DATA_CLASS AGENT_LIVE_RULES AGENT_HARNESS, and for
#                      the raw harness AGENT_MAX_TOKENS AGENT_TEMPERATURE, or exit 78; and the
#                      conf's budget (lib/budget.sh), which replaces a parent runner's
agent_load() {
  local name="$1" conf v=()
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || role_die "--agent '$name' is not an agent name"
  conf="$AGENTCTL_CONF_DIR/$name.conf"
  [ -r "$conf" ] || role_die "no agent '$name' ($conf). Every model call is a registered agent:
add a KIND=call conf for it - see ~/.config/agentctl/README.md, \"What an agent is\"."
  # A subshell, so the conf's keys never leak into this process except as read below.
  mapfile -t v < <(
    set +eu
    unset NAME KIND ROLE MODEL PROMPT ROUTE DATA_CLASS LIVE_RULES BUDGET_CALL_USD BUDGET_DAY_USD MAX_CALLS_HOUR \
      HARNESS MAX_TOKENS TEMPERATURE
    # shellcheck disable=SC1090
    . "$conf" >/dev/null 2>&1
    printf '%s\n' "${NAME:-}" "${KIND:-}" "${ROLE:-}" "${MODEL:-}" "${PROMPT:-}" \
      "${ROUTE:-}" "${DATA_CLASS:-}" "${LIVE_RULES:-}" \
      "${BUDGET_CALL_USD:-}" "${BUDGET_DAY_USD:-}" "${MAX_CALLS_HOUR:-}" \
      "${HARNESS:-}" "${MAX_TOKENS:-}" "${TEMPERATURE:-}"
  )
  [ "${v[0]:-}" = "$name" ] || role_die "agent conf $conf has NAME='${v[0]:-}', not '$name'"
  AGENT_KIND="${v[1]:-}"
  AGENT_ROLE="${v[2]:-}"
  AGENT_MODEL="${v[3]:-}"
  AGENT_PROMPT="${v[4]:-}"
  AGENT_ROUTE="${v[5]:-}"
  AGENT_DATA_CLASS="${v[6]:-}"
  AGENT_LIVE_RULES="${v[7]:-}"
  BUDGET_CALL_USD="${v[8]:-}" BUDGET_DAY_USD="${v[9]:-}" MAX_CALLS_HOUR="${v[10]:-}"
  AGENT_HARNESS="${v[11]:-}" AGENT_MAX_TOKENS="${v[12]:-}" AGENT_TEMPERATURE="${v[13]:-}"
  [ -n "$AGENT_ROLE" ] || role_die "agent '$name' declares no ROLE ($conf)"
  AGENT_PROMPT_SHA=""
  if [ -n "$AGENT_PROMPT" ]; then
    [ -r "$AGENT_PROMPT" ] || role_die "agent '$name' PROMPT=$AGENT_PROMPT is not readable"
    # The git blob hash: the same id `git log --find-object` answers for, so a score can be
    # tied to the exact prompt text without storing it twice.
    AGENT_PROMPT_SHA="$(git hash-object "$(readlink -f "$AGENT_PROMPT")")"
  fi
}

# agent_prompt_args <args...> -> AGENT_ARGS, with the PROMPT file put ahead of the -p text
agent_prompt_args() {
  local i n=$# a=("$@") done=0
  AGENT_ARGS=("$@")
  [ -n "${AGENT_PROMPT:-}" ] || return 0
  for ((i = 0; i < n; i++)); do
    case "${a[i]}" in
      -p|--print)
        [ $((i + 1)) -lt "$n" ] || break
        AGENT_ARGS[i + 1]="$(cat "$AGENT_PROMPT")

${a[i + 1]}"
        done=1; break ;;
    esac
  done
  [ "$done" = 1 ] || role_die "agent PROMPT=$AGENT_PROMPT needs a print call: -p \"<input>\""
}

# agent_otel_runner <name>: the call's telemetry names the agent, not the session or runner
# that started it, so its cost, tokens and trace are its own. Same rewrite as
# claude-telemetry.sh's claude_otel_attr; nothing is added when telemetry is off.
agent_otel_runner() {
  [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ] || return 0
  OTEL_RESOURCE_ATTRIBUTES="$(printf '%s' "$OTEL_RESOURCE_ATTRIBUTES" | tr ',' '\n' \
    | awk -F= 'NF && $1 != "agentctl.runner"' | { cat; printf 'agentctl.runner=%s\n' "$1"; } | paste -sd, -)"
  export OTEL_RESOURCE_ATTRIBUTES
}
