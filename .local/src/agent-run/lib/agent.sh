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

# AGENTCTL_CONF_DIR, the roster, and the budget keys are lib/budget.sh's (budget_conf).

# agent_load <name> -> AGENT_KIND AGENT_ROLE AGENT_MODEL AGENT_PROMPTS AGENT_PROMPT AGENT_SCHEMA AGENT_PROMPT_SHA
#                      AGENT_ROUTE AGENT_DATA_CLASS AGENT_DELAY_RULES AGENT_HARNESS AGENT_SOURCE AGENT_CALL_CONTEXT, and for
#                      the raw harness AGENT_MAX_TOKENS AGENT_TEMPERATURE, or exit 78; and the
#                      conf's budget (lib/budget.sh), which replaces a parent runner's
agent_load() {
  local name="$1" conf v=() b=()
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || role_die "--agent '$name' is not an agent name"
  conf="$AGENTCTL_CONF_DIR/$name.conf"
  [ -r "$conf" ] || role_die "no agent '$name' ($conf). Every model call is a registered agent:
add a KIND=call conf for it - see ~/.config/agentctl/README.md, \"What an agent is\"."
  # A subshell, so the conf's keys never leak into this process except as read below.
  mapfile -t v < <(
    set +eu
    unset NAME KIND ROLE MODEL PROMPT SCHEMA ROUTE DATA_CLASS DELAY_RULES \
      HARNESS MAX_TOKENS TEMPERATURE SOURCE CALL_CONTEXT
    # shellcheck disable=SC1090
    . "$conf" >/dev/null 2>&1
    printf '%s\n' "${NAME:-}" "${KIND:-}" "${ROLE:-}" "${MODEL:-}" "${PROMPT:-}" \
      "${ROUTE:-}" "${DATA_CLASS:-}" "${DELAY_RULES:-}" \
      "${SCHEMA:-}" \
      "${HARNESS:-}" "${MAX_TOKENS:-}" "${TEMPERATURE:-}" "${SOURCE:-}" "${CALL_CONTEXT:-}"
  )
  [ "${v[0]:-}" = "$name" ] || role_die "agent conf $conf has NAME='${v[0]:-}', not '$name'"
  AGENT_KIND="${v[1]:-}"
  AGENT_ROLE="${v[2]:-}"
  AGENT_MODEL="${v[3]:-}"
  AGENT_PROMPT="${v[4]:-}"
  AGENT_ROUTE="${v[5]:-}"
  AGENT_DATA_CLASS="${v[6]:-}"
  AGENT_DELAY_RULES="${v[7]:-}"
  mapfile -t b < <(budget_conf "$name")
  BUDGET_CALL_USD="${b[0]:-}" BUDGET_DAY_USD="${b[1]:-}" MAX_CALLS_HOUR="${b[2]:-}"
  AGENT_SCHEMA="${v[8]:-}"
  if [ -n "$AGENT_SCHEMA" ]; then
    jq -e . "$AGENT_SCHEMA" >/dev/null 2>&1 || role_die "agent '$name' SCHEMA=$AGENT_SCHEMA is not a readable JSON file"
  fi
  AGENT_HARNESS="${v[9]:-}" AGENT_MAX_TOKENS="${v[10]:-}" AGENT_TEMPERATURE="${v[11]:-}"
  AGENT_SOURCE="${v[12]:-}"
  # CALL_CONTEXT=lean: the call carries its PROMPT and input, not the session context (harnesses/claude.sh)
  AGENT_CALL_CONTEXT="${v[13]:-}"
  case "$AGENT_CALL_CONTEXT" in ''|lean) ;; *) role_die "agent '$name' CALL_CONTEXT='$AGENT_CALL_CONTEXT' is not empty or lean ($conf)" ;; esac
  [ -n "$AGENT_ROLE" ] || role_die "agent '$name' declares no ROLE ($conf)"
  # PROMPT names one file, or several (colon-separated, as PATH) when the agent runs more than one pass:
  # inbox-priority's priority and link batches. Each pass's call says which with --rendered-prompt.
  local p
  IFS=: read -ra AGENT_PROMPTS <<<"$AGENT_PROMPT"
  for p in "${AGENT_PROMPTS[@]+"${AGENT_PROMPTS[@]}"}"; do
    prompt_expand "$p" >/dev/null || role_die "agent '$name' PROMPT=$p is not readable ($conf)"
  done
  AGENT_PROMPT_SHA="" AGENT_PROMPT_RENDERED=""
  if [ "${#AGENT_PROMPTS[@]}" = 1 ]; then
    AGENT_PROMPT="${AGENT_PROMPTS[0]}"
    # The git blob hash: the same id `git log --find-object` answers for, so a score can be
    # tied to the exact prompt text without storing it twice (lib prompt-render.sh, prompt_sha).
    AGENT_PROMPT_SHA="$(prompt_sha "$AGENT_PROMPT")"
  else
    AGENT_PROMPT=""
  fi
}

# agent_rendered <file>: this call's input is <file>, one of the conf's PROMPT files, already
# filled in by its caller (a template, lib prompt-render.sh). The call line records that file and
# its sha, so each pass of a several-prompt agent is scored against its own prompt, and nothing
# is put ahead of the input.
agent_rendered() {
  local want p
  want="$(readlink -f "$1")" || want=""
  for p in "${AGENT_PROMPTS[@]+"${AGENT_PROMPTS[@]}"}"; do
    if [ -n "$want" ] && [ "$(readlink -f "$p")" = "$want" ]; then
      AGENT_PROMPT="$p" AGENT_PROMPT_RENDERED=1
      AGENT_PROMPT_SHA="$(prompt_sha "$p")"
      return 0
    fi
  done
  role_die "--rendered-prompt $1 is not one of agent '$AGENTCTL_AGENT's PROMPT files (${AGENT_PROMPTS[*]:-none}): name it in the conf"
}

# agent_prompt_check: a prompt reaches the model only as text. Several PROMPT files need the
# call to say which, and a template (one holding {{name}}) needs its caller to fill it.
agent_prompt_check() {
  [ -z "${AGENT_PROMPT_RENDERED:-}" ] || return 0
  [ "${#AGENT_PROMPTS[@]}" -le 1 ] \
    || role_die "agent '$AGENTCTL_AGENT' names ${#AGENT_PROMPTS[@]} PROMPT files: its caller passes --rendered-prompt <file> with the one it filled in"
  [ -n "${AGENT_PROMPT:-}" ] || return 0
  if prompt_has_vars "$AGENT_PROMPT"; then
    role_die "agent '$AGENTCTL_AGENT' PROMPT=$AGENT_PROMPT is a template: its caller fills it (prompt_render) and passes --rendered-prompt"
  fi
}

# agent_prompt_args <args...> -> AGENT_ARGS, with the PROMPT file put ahead of the -p text, unless
# the input is that file rendered (--rendered-prompt)
agent_prompt_args() {
  local i n=$# a=("$@") done=0
  AGENT_ARGS=("$@")
  [ -n "${AGENT_PROMPT:-}" ] && [ -z "${AGENT_PROMPT_RENDERED:-}" ] || return 0
  for ((i = 0; i < n; i++)); do
    case "${a[i]}" in
      -p|--print)
        [ $((i + 1)) -lt "$n" ] || break
        AGENT_ARGS[i + 1]="$(prompt_expand "$AGENT_PROMPT")

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
