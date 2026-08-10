#!/bin/bash
# llm-call.sh — Calls an OpenAI-compatible LLM with the judge prompt.
#
# The backend chain comes from config.json: `.backend` first, then every other
# key under `.backends` in declaration order. It used to be HARDCODED to
# mlx -> litellm regardless of what the config actually declared, which meant
# renaming or adding a backend silently produced a chain pointing at a key that
# did not exist — the failover would "run" and fail on every hop. The config is
# the source of truth for WHICH backends exist; this file only orders them.

CONFIG_FILE="$HOME/.config/llm-judge/config.json"

call_judge_llm() {
  local system_prompt="$1"
  local user_content="$2"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    return 1
  fi

  # Chain = the declared primary, then every OTHER declared backend in key order.
  # Derived from the config so a rename cannot produce a chain of ghosts.
  local primary
  primary=$(jq -r '.backend // ""' "$CONFIG_FILE")

  local backends=()
  [[ -n "$primary" ]] && jq -e --arg b "$primary" '.backends[$b]' "$CONFIG_FILE" >/dev/null 2>&1 \
    && backends=("$primary")

  local rest
  rest=$(jq -r --arg b "$primary" '.backends | keys_unsorted[] | select(. != $b)' "$CONFIG_FILE" 2>/dev/null)
  while IFS= read -r b; do [[ -n "$b" ]] && backends+=("$b"); done <<<"$rest"

  # An empty chain must be an error, not a silent success. A gate that reports
  # OK on an empty input list is the failure mode this repo keeps hitting.
  if [[ ${#backends[@]} -eq 0 ]]; then
    echo "ERROR: no usable backends in $CONFIG_FILE (.backend='$primary')" >&2
    return 1
  fi

  for backend in "${backends[@]}"; do
    local result
    result=$(_call_backend "$backend" "$system_prompt" "$user_content" 2>/dev/null)
    if [[ $? -eq 0 ]] && [[ -n "$result" ]]; then
      printf '%s' "$result"
      return 0
    fi
    echo "WARN: Backend '$backend' failed, trying next..." >&2
  done

  echo "ERROR: All LLM backends failed" >&2
  return 1
}

_call_backend() {
  local backend="$1"
  local system_prompt="$2"
  local user_content="$3"

  local base_url model timeout api_key

  # The backend name is DATA, so it is passed with --arg and indexed as .backends[$b].
  # Interpolated into the filter as `.backends.${backend}` it is jq SYNTAX, and a name
  # containing a hyphen then parses as subtraction: `.backends.mlx-8bit` reads as
  # `.backends.mlx - 8bit` and dies with "syntax error, unexpected IDENT".
  #
  # `mlx-8bit` is the judge's only fallback, so it never worked - not once. The primary
  # (`mlx`) has no hyphen and resolved fine, which is exactly why this hid: the chain
  # looked like it had a spare wheel and had none. Every time the primary hiccuped, the
  # fallback failed to even parse its own config and the eval was lost. bnb-platform ran
  # 446 sessions at 100% EVAL PENDING from 2026-08-05, all of them reporting
  # "All LLM backends failed" against an endpoint that was up the whole time.
  #
  # The DISCOVERY half of this file (see _backend_order) already does it correctly with
  # --arg. Only the USE half interpolated, so the bug needed a hyphenated name to appear.
  base_url=$(jq -r --arg b "$backend" '.backends[$b].base_url' "$CONFIG_FILE")
  model=$(jq -r --arg b "$backend" '.backends[$b].model' "$CONFIG_FILE")
  timeout=$(jq -r --arg b "$backend" '.backends[$b].timeout_seconds // 30' "$CONFIG_FILE")

  if [[ "$base_url" == "null" ]] || [[ -z "$base_url" ]]; then
    echo "ERROR: No config for backend '$backend'" >&2
    return 1
  fi

  # Resolve API key from env var if specified
  local api_key_env
  api_key_env=$(jq -r --arg b "$backend" '.backends[$b].api_key_env // empty' "$CONFIG_FILE")
  if [[ -n "$api_key_env" ]]; then
    api_key="${!api_key_env}"
  fi

  # Build auth header
  local auth_header=""
  if [[ -n "$api_key" ]]; then
    auth_header="Authorization: Bearer $api_key"
  fi

  # Build request payload — use jq for proper JSON escaping
  local payload
  payload=$(jq -n \
    --arg model "$model" \
    --arg sys "$system_prompt" \
    --arg usr "$user_content" \
    '{
      model: $model,
      messages: [
        { role: "system", content: $sys },
        { role: "user", content: $usr }
      ],
      temperature: 0.1,
      max_tokens: 2000
    }')

  # Make the API call
  local response
  local curl_args=(
    -s -S
    --max-time "$timeout"
    -H "Content-Type: application/json"
    -d "$payload"
    "${base_url}/chat/completions"
  )

  if [[ -n "$auth_header" ]]; then
    curl_args=(-H "$auth_header" "${curl_args[@]}")
  fi

  # Keep curl's own diagnosis. `2>/dev/null` here plus a bare `return 1` below meant every
  # transport failure - refused connection, DNS, TLS, timeout, a malformed filter dying
  # before curl ran - surfaced identically as "Backend 'X' failed, trying next...". The
  # caller then truncates to 200 chars, so the eval file recorded the same sentence for
  # 446 sessions and named no cause. Four separate investigations re-derived the endpoint
  # as healthy because the one line that knew why was being thrown away.
  #
  # -S is already set, so curl writes a real reason to stderr; capture it instead.
  # `local` on its own line: `local x=$(...)` would mask curl's exit status behind
  # local's own.
  local curl_err rc
  curl_err=$(mktemp)
  response=$(curl "${curl_args[@]}" 2>"$curl_err")
  rc=$?

  if [[ $rc -ne 0 ]] || [[ -z "$response" ]]; then
    local why
    why=$(tr '\n' ' ' <"$curl_err" | head -c 300)
    rm -f "$curl_err"
    echo "ERROR: $backend transport failed (curl rc=$rc): ${why:-empty response, no curl diagnostic}" >&2
    return 1
  fi
  rm -f "$curl_err"

  # Check for API error
  local error
  error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "$error" ]]; then
    echo "ERROR: API error from $backend: $error" >&2
    return 1
  fi

  # Extract the assistant's content
  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

  if [[ -z "$content" ]]; then
    echo "ERROR: No content in response from $backend" >&2
    return 1
  fi

  printf '%s' "$content"
}
