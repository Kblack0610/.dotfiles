# shellcheck shell=bash
# harnesses/agy.sh - express the role contract as an `agy -p` call (the Antigravity CLI, headless).
# The role-to-flag table and why each row holds is docs/contract.md "Harness mapping".
# agy has no headless write boundary of its own (it wrote outside its workspace with no prompt,
# measured on 1.5.13), so it runs only inside a lane sandbox, under srt with a cleared env. agy bills
# the AI Pro plan, so its calls.jsonl lines carry tokens and no cost_usd: MAX_CALLS_HOUR binds it.

AGY_BIN="${AGY_BIN:-agy}"
# Where the srt settings and the jail's TMPDIR go, fleet-dispatch's agy run dir: outside the jail.
AGY_RUNS="${AGY_RUNS:-$HOME/.agent/agy/runs}"
# One argv string is capped at 128 KiB, and agy takes its prompt only as -p's value.
AGY_PROMPT_MAX=120000

harness_supports() {
  if [ -z "${SANDBOX_FILE:-}" ]; then
    echo "agy runs only in a lane sandbox (it has no headless write boundary); set the role's or runner's SANDBOX." >&2
    return 1
  fi
  if [ "$ROLE_WRITE" = no ] || [ "$ROLE_BASH" = no ]; then
    echo "role denies writes or bash; agy cannot remove its write or shell tools for one run." >&2
    return 1
  fi
  # --settings refuses disabledTools, the one key that would turn its subagents off.
  if [ "$ROLE_TASK" = no ]; then
    echo "role denies subagents; agy has no per-run switch for them." >&2
    return 1
  fi
  # Like opencode, agy's MCP set is its own config's, not a command-line choice.
  if [ "$ROLE_MCP" != inherit ]; then
    echo "agentctl-run: note - ROLE_MCP='$ROLE_MCP' is not enforceable per-run on agy;" >&2
    echo "  its server set comes from 'agy mcp list'." >&2
  fi
  return 0
}

# harness_sandbox - build the srt settings once, before the run: the profile's, plus agy's binary,
# its state dir (the login) and the jail's tmp. A missing srt tool or agy refuses. The settings go on exit.
harness_sandbox() {
  local why; why="$(sandbox_srt_refusal)"
  [ -z "$why" ] || { SANDBOX_WHY="srt cannot hold it: $why"; return 1; }
  mkdir -p "$AGY_RUNS/tmp" || { SANDBOX_WHY="no run dir $AGY_RUNS"; return 1; }
  AGY_SRT_SETTINGS="$(mktemp "$AGY_RUNS/srt-run.XXXXXX")" || { SANDBOX_WHY="no settings file in $AGY_RUNS"; return 1; }
  trap 'rm -f -- "$AGY_SRT_SETTINGS"' EXIT
  sandbox_agy_settings "$AGY_RUNS/tmp" >"$AGY_SRT_SETTINGS" && [ -s "$AGY_SRT_SETTINGS" ] ||
    { SANDBOX_WHY="its srt settings did not build (is $AGY_BIN on PATH?)"; return 1; }
}

# _agy_result <agy line...> -> one JSON object folded from the stream-json events, the shape
# calls_record reads: result (the final response), structured_output when a schema was asked,
# session_id (the conversation), usage (input without its cached part, as claude counts it), model.
_agy_result() {
  "$@" 2>/dev/null | jq -cnR --arg schema "${AGENT_SCHEMA:-}" '
    [inputs | fromjson? | objects] as $ev
    | ($ev | map(select(.event == "init")) | first) as $i
    | ($ev | map(select(.event == "result")) | last | .result // {}) as $r
    | ($r.usage // {}) as $u
    | {result: ($r.response // $r.error // ""),
       session_id: (($r.conversation_id // "") | if . == "" then $i.conversation_id else . end),
       is_error: ($r.status != "SUCCESS"),
       model: ($i.init.model // null),
       usage: {input_tokens: (if $u.input_tokens then $u.input_tokens - ($u.cache_read_tokens // 0) else null end),
               output_tokens: (if $u.output_tokens then $u.output_tokens + ($u.thinking_tokens // 0) else null end),
               cache_read_input_tokens: $u.cache_read_tokens}}
    + (if $schema != "" then {structured_output: ($r.response // "" | fromjson? // null)} else {} end)'
}

harness_exec() {
  local flags=(--dangerously-skip-permissions) model="${ANTHROPIC_MODEL:-}" v
  [ -n "$model" ] && flags+=(--model "$model")
  [ -n "${AGENT_SCHEMA:-}" ] && flags+=(--json-schema "$AGENT_SCHEMA")

  # Callers speak claude's dialect (-p "<prompt>"); the prompt, with the headless rule, is -p's
  # value, so it goes last.
  local a input="" rest=() i args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    a="${args[i]}"
    case "$a" in
      -p|--print)
        if [ $((i + 1)) -lt ${#args[@]} ] && [ "${args[i + 1]:0:1}" != - ]; then input="${args[i + 1]}"; i=$((i + 1)); fi ;;
      *) if [ -z "$input" ] && [ "${a:0:1}" != - ]; then input="$a"; else rest+=("$a"); fi ;;
    esac
  done
  [ -n "$input" ] || [ -t 0 ] || input="$(cat)"
  input="You are running headless with no human present. Never ask for approval or wait on anyone: execute the task directly and report what you did.

$input"
  if [ "${#input}" -gt "$AGY_PROMPT_MAX" ]; then
    echo "agentctl-run: the prompt is ${#input} bytes; agy takes it as one argument, capped near 128 KiB." >&2
    exit 2
  fi

  # The jail: srt, under env -i keeping only SANDBOX_ENV_KEEP, so no key or socket reaches agy.
  local jail=(env -i)
  for v in $SANDBOX_ENV_KEEP; do jail+=("$v=${!v-}"); done
  jail+=("TMPDIR=$AGY_RUNS/tmp" "CLAUDE_CODE_TMPDIR=$AGY_RUNS/tmp" srt --settings "$AGY_SRT_SETTINGS" -- "$AGY_BIN")

  if [ -n "${AGENTCTL_EXPLAIN:-}" ]; then
    printf 'harness:     agy\nflags:      '
    printf ' %q' "${flags[@]}" "${rest[@]+"${rest[@]}"}"
    printf '\n'
    return 0
  fi

  local rc=0
  if [ -n "$(calls_name)" ]; then
    calls_record agy _agy_result "${jail[@]}" --output-format stream-json "${flags[@]}" "${rest[@]+"${rest[@]}"}" -p "$input" </dev/null || rc=$?
  else
    "${jail[@]}" --output-format text "${flags[@]}" "${rest[@]+"${rest[@]}"}" -p "$input" </dev/null || rc=$?
  fi
  exit "$rc"
}
