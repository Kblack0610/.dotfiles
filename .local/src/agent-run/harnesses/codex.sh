# shellcheck shell=bash
# harnesses/codex.sh - express the role contract as `codex exec` flags (Codex CLI, headless).
# The role-to-flag table and why each row holds is docs/contract.md "Harness mapping".
# Codex bills a ChatGPT plan, so its calls.jsonl lines carry tokens and no cost_usd: dollar
# caps do not bind it, MAX_CALLS_HOUR does.

CODEX_BIN="${CODEX_BIN:-codex}"

harness_supports() {
  if [ "$ROLE_BASH" = no ] && [ "$ROLE_WRITE" != no ]; then
    echo "role denies bash but grants writes; codex cannot remove its shell, and a writable sandbox lets the shell do anything." >&2
    return 1
  fi
  return 0
}

# _codex_mcp_flags -> one -c override per line pinning the run to ROLE_MCP's set
_codex_mcp_flags() {
  local file; file="$(role_mcp_file)"
  [ -n "$file" ] || return 0
  "$CODEX_BIN" mcp list --json 2>/dev/null | jq -r --slurpfile set "$file" '
    ($set[0].mcpServers // {}) as $s | .[] | .name as $n | select(.enabled and ($s | has($n) | not))
    | "mcp_servers.\(.name).enabled=false"' || return 1
  jq -r '.mcpServers // {} | to_entries[] | select(.value.command)
    | "mcp_servers.\(.key)={command=\(.value.command | tojson), args=\(.value.args // [] | tojson), env={\(
        .value.env // {} | to_entries | map("\(.key | tojson)=\(.value | tojson)") | join(","))}}"' "$file"
}

# _codex_result <codex exec args...> -> one JSON object folded from the --json event stream, the
# shape calls_record reads: result (last agent message), structured_output when a schema was
# asked, session_id (the thread), usage (input without its cached part, as claude counts it), model.
_codex_result() {
  "$CODEX_BIN" exec --json "$@" </dev/stdin 2>/dev/null | jq -cs --arg schema "${AGENT_SCHEMA:-}" --arg model "${CODEX_MODEL:-}" '
    ([.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | last) as $last
    | ([.[] | select(.type == "turn.completed") | .usage] | last // {}) as $u
    | {result: ($last // ""),
       session_id: ([.[] | select(.type == "thread.started") | .thread_id] | first),
       is_error: (any(.[]; .type == "turn.failed" or .type == "error")),
       model: (if $model == "" then null else $model end),
       usage: {input_tokens: (if $u.input_tokens then $u.input_tokens - ($u.cached_input_tokens // 0) else null end),
               output_tokens: $u.output_tokens, cache_read_input_tokens: $u.cached_input_tokens}}
    + (if $schema != "" then {structured_output: ($last | fromjson? // null)} else {} end)'
}

harness_exec() {
  local flags=() model="${ANTHROPIC_MODEL:-}" o
  if [ -n "$model" ] && [ "$(role_family_of "$model")" != openai ]; then
    echo "agentctl-run: model '$model' is not a Codex model; set MODEL to an OpenAI id for HARNESS=codex." >&2
    exit 2
  fi
  [ -n "$model" ] && flags+=(-m "$model")
  if [ "$ROLE_WRITE" = no ]; then flags+=(--sandbox read-only)
  else flags+=(--dangerously-bypass-approvals-and-sandbox); fi
  [ "$ROLE_TASK" = no ] && flags+=(--disable multi_agent)
  while IFS= read -r o; do [ -n "$o" ] && flags+=(-c "$o"); done < <(_codex_mcp_flags)
  [ -n "${AGENT_SCHEMA:-}" ] && flags+=(--output-schema "$AGENT_SCHEMA")
  flags+=(--skip-git-repo-check --color never)

  # Callers speak claude's dialect (-p "<prompt>"): -p only marks a print call, and the prompt,
  # with the headless rule claude.sh appends as a system prompt, goes in on stdin (an argument
  # is capped at 128 KiB).
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

  if [ -n "${AGENTCTL_EXPLAIN:-}" ]; then
    printf 'harness:     codex\nflags:      '
    printf ' %q' "${flags[@]}" "${rest[@]+"${rest[@]}"}"
    printf '\n'
    return 0
  fi

  exec 0<<<"$input"
  if [ -n "$(calls_name)" ]; then
    CODEX_MODEL="$model" calls_record codex _codex_result "${flags[@]}" "${rest[@]+"${rest[@]}"}" -
    exit $?
  fi
  exec "$CODEX_BIN" exec "${flags[@]}" "${rest[@]+"${rest[@]}"}" -
}
