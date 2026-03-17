#!/bin/bash
# llm-call.sh — Calls an OpenAI-compatible LLM with judge prompt
# Supports MLX -> LiteLLM fallback chain.

CONFIG_FILE="$HOME/.dotfiles/.config/llm-judge/config.json"

call_judge_llm() {
  local system_prompt="$1"
  local user_content="$2"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    return 1
  fi

  # Read backend preference
  local primary
  primary=$(jq -r '.backend // "mlx"' "$CONFIG_FILE")

  # Try primary backend, then fallback
  local backends=("$primary")
  if [[ "$primary" == "mlx" ]]; then
    backends+=("litellm")
  else
    backends+=("mlx")
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

  base_url=$(jq -r ".backends.${backend}.base_url" "$CONFIG_FILE")
  model=$(jq -r ".backends.${backend}.model" "$CONFIG_FILE")
  timeout=$(jq -r ".backends.${backend}.timeout_seconds // 30" "$CONFIG_FILE")

  if [[ "$base_url" == "null" ]] || [[ -z "$base_url" ]]; then
    echo "ERROR: No config for backend '$backend'" >&2
    return 1
  fi

  # Resolve API key from env var if specified
  local api_key_env
  api_key_env=$(jq -r ".backends.${backend}.api_key_env // empty" "$CONFIG_FILE")
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

  response=$(curl "${curl_args[@]}" 2>/dev/null)

  if [[ $? -ne 0 ]] || [[ -z "$response" ]]; then
    return 1
  fi

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
