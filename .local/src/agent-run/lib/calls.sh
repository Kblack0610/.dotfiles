# shellcheck shell=bash
# lib/calls.sh - one line per registered agent call in ~/.local/state/agentctl/calls.jsonl.
#
# Written only here, by agentctl-run, for a named print call: --agent, or a runner by its
# unit's AGENTCTL_NAME (calls_name). lib/budget.sh sums these lines. runs.jsonl is per runner
# pass and written by the unit's stop hook, so a call inside a script (a judge) never had a
# record of its own: no model, no latency, no cost, no prompt version. Field names follow the
# OTel GenAI conventions where one exists (gen_ai.*); full prompt and response text are in
# Langfuse under session_id, so `raw` keeps only the model's final text, capped.
#
# A caller may set AGENTCTL_CALL_ID to link its own record (an ask's judge_call) to this line.

AGENTCTL_CALLS="${AGENTCTL_CALLS:-${XDG_STATE_HOME:-$HOME/.local/state}/agentctl/calls.jsonl}"
CALLS_RAW_MAX=4096
# A call that stopped at its per-call cap (--max-budget-usd; the result's subtype
# error_max_budget_usd) exits this, so a caller can shrink its batch on the code, never on text.
CALLS_RC_CAPPED=76
# A call budget_stop refused exits this: it was not made at all.
# shellcheck disable=SC2034 # read by budget.sh and each caller of a named call
EX_BUDGET=75

# calls_name -> the name a call is recorded (and budgeted) under, empty for a hand run
calls_name() { printf '%s' "${AGENTCTL_AGENT:-${AGENTCTL_NAME:-}}"; }

calls_new_id() { od -An -tx1 -N6 /dev/urandom | tr -d ' \n'; }

# calls_record <harness> <cmd...>: run a print-mode harness command that emits one JSON result object
# (claude --output-format json, or an OpenAI chat completion from harnesses/raw.sh), print its
# reply to stdout as the plain run would, append the call line, and return the command's exit
# code. The reply is .structured_output as one JSON line when the agent has a SCHEMA, else
# .result (claude) or the first choice's content (raw). A schema run that ended without valid
# output has no such field, so its prose goes out and the caller's parse fails visibly. A capped
# call returns CALLS_RC_CAPPED.
calls_record() {
  local harness="$1" id t0 t1 out rc=0 text
  shift
  id="${AGENTCTL_CALL_ID:-$(calls_new_id)}"
  t0="$(date +%s%3N)"
  out="$("$@")" || rc=$?
  t1="$(date +%s%3N)"
  # A non-JSON reply (a crash before the result object) is still the call's output.
  if text="$(jq -cer 'if type != "object" then error
    elif has("result") or has("structured_output") then .structured_output // .result
    elif has("choices") or has("error") then .choices[0].message.content // ""
    else error end' <<<"$out" 2>/dev/null)"; then
    printf '%s\n' "$text"
  else
    text="$out"; out='{}'
    [ -n "$text" ] && printf '%s\n' "$text"
  fi
  mkdir -p "$(dirname "$AGENTCTL_CALLS")"
  jq -cn --argjson r "$out" --arg id "$id" --arg agent "$(calls_name)" \
    --arg role "${ROLE_NAME:-}" --arg model "$([ "$harness" = raw ] && printf '%s' "${LLM_MODEL:-}" || printf '%s' "${ANTHROPIC_MODEL:-}")" --arg harness "$harness" \
    --arg account "${ROUTE_ACCOUNT:-}" --arg at "$(date -Iseconds)" --argjson ms "$((t1 - t0))" --argjson exit "$rc" \
    --arg prompt "${AGENT_PROMPT:-}" --arg sha "${AGENT_PROMPT_SHA:-}" --arg text "$text" \
    --argjson max "$CALLS_RAW_MAX" '
    {id: $id, agent: $agent, role: $role, harness: $harness, account: $account, at: $at, duration_ms: $ms, exit: $exit,
     "gen_ai.request.model": $model,
     "gen_ai.response.model": ((($r.modelUsage // {}) | keys | first) // $r.model),
     prompt: $prompt, prompt_sha: $sha,
     session_id: $r.session_id, subtype: $r.subtype,
     is_error: (if $r | has("is_error") then $r.is_error elif $r | has("error") then true else null end),
     "gen_ai.usage.input_tokens": ($r.usage.input_tokens // $r.usage.prompt_tokens),
     "gen_ai.usage.output_tokens": ($r.usage.output_tokens // $r.usage.completion_tokens),
     cache_read_tokens: $r.usage.cache_read_input_tokens,
     cache_write_tokens: $r.usage.cache_creation_input_tokens,
     cost_usd: $r.total_cost_usd,
     raw: ($text | .[0:$max])}
    | with_entries(select(.value != null and .value != ""))' \
    | flock "$AGENTCTL_CALLS" tee -a "$AGENTCTL_CALLS" >/dev/null || true
  [ "$(jq -r '.subtype? // ""' <<<"$out" 2>/dev/null)" = error_max_budget_usd ] && rc=$CALLS_RC_CAPPED
  return "$rc"
}
