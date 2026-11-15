# shellcheck shell=bash
# raw -- no agent harness at all: run a plain command against a route's model.
#
# The other harnesses wrap an agent CLI that owns a tool loop. This one owns
# nothing. It exists because several consumers already speak OpenAI-compatible
# HTTP directly with their own curl -- comms-triage.sh and notes-version-summary --
# and each carried its own hardcoded base URL, model and key entry.
# That is six unshared copies of "which model, whose gateway, whose key", and the
# reason two of them were found silently spilling onto a paid Lazer route.
#
# Here they read the same LLM_* names they already read, and the ROUTE decides
# what those names contain.
#
# `-p [input]` is the third shape and the one a registered agent uses: one chat call
# to the route's model, the conf's PROMPT file as the system message and the input as
# the user message, MODEL (else the route's), MAX_TOKENS and TEMPERATURE from the conf. It prints the reply text
# and, for a named call, writes the calls.jsonl line (lib/calls.sh), so an HTTP model
# call gets the same record, budget and prompt_sha as a claude one.
#
# A caller with no conf (ask-local) shapes one call with environment, all optional:
#   RAW_MESSAGES         a file holding a JSON array of earlier chat messages (a system message,
#                        the conversation so far); the input is appended to it as the user turn
#   RAW_RESPONSE_FORMAT  the request's response_format, as a JSON object
#   RAW_TAGS             sent as the x-litellm-tags header
#   RAW_TIMEOUT_S        the curl --max-time (240)
#   RAW_STATUS_FILE      the HTTP status of the call is written here (000: no answer at all)
#   RAW_REPLY=json       print the whole response object instead of the reply text
#
# WHY harness_supports IS UNCONDITIONALLY TRUE, which looks wrong and is not:
# contract rule 3 says a harness that cannot ENFORCE a role's denials must refuse
# rather than degrade. `raw` grants no tools whatsoever -- no Write, no Bash, no
# Task, no MCP, not even a tool loop -- so every denial any role could express is
# already satisfied, vacuously but completely. It is the MOST enforcing harness
# here, not the least. The one thing it cannot do is grant a capability, which is
# never what a denial asks for.
harness_supports() { return 0; }

harness_exec() {
  # route_apply has already exported LLM_BASE_URL / LLM_MODEL / LLM_API_KEY from
  # the resolved route. Two shapes, because the two existing consumer patterns
  # genuinely differ:
  #
  #   --print-env   emit shell-quoted exports for `eval`, which is what
  #                 comms-run.sh:36-43 does to seed both halves of its pipeline
  #   -- <cmd>      exec the command with the route's env already in place
  #
  # A consumer that wants neither can still just read the variables.
  if [ "${1:-}" = --print-env ]; then
    printf 'export LLM_BASE_URL=%q\n' "${LLM_BASE_URL:-}"
    printf 'export LLM_MODEL=%q\n'    "${LLM_MODEL:-}"
    # Emitted even when empty, deliberately: an unauthenticated origin is the
    # NORMAL case for the personal-safe route, and a consumer that inherited a
    # stale key from its own environment must have it cleared rather than kept.
    printf 'export LLM_API_KEY=%q\n'  "${LLM_API_KEY:-}"
    return 0
  fi

  if [ -n "${AGENTCTL_EXPLAIN:-}" ]; then
    printf 'harness:     raw (no tools; the route decides the endpoint)\n'
    printf 'env set:     LLM_BASE_URL=%s LLM_MODEL=%s LLM_API_KEY=%s\n' \
      "${LLM_BASE_URL:-<unset>}" "${LLM_MODEL:-<unset>}" \
      "${LLM_API_KEY:+<redacted>}${LLM_API_KEY:-<unset>}"
    return 0
  fi

  case "${1:-}" in -p|--print) shift; raw_print "${1-}"; return ;; esac

  [ "$#" -gt 0 ] || {
    printf 'agentctl-run: raw: nothing to run. Pass a command, or --print-env.\n' >&2
    exit 64
  }
  exec "$@"
}

# raw_print <input>: the -p call. A failed call (no reply, an error object, empty content)
# exits non-zero, so a caller can fail instead of writing nothing.
raw_print() {
  RAW_INPUT="$1"
  # The conf's MODEL pins the model, as it does for claude; the route's model is the default.
  [ -n "${AGENTCTL_MODEL:-}" ] && LLM_MODEL="$AGENTCTL_MODEL"
  if [ -n "$(calls_name)" ]; then calls_record raw raw_chat; exit $?; fi
  local resp rc=0
  resp="$(raw_chat)" || rc=$?
  if [ "${RAW_REPLY:-}" = json ]; then printf '%s\n' "$resp"
  else jq -r '.choices[0].message.content // empty' <<<"$resp" 2>/dev/null; fi
  exit "$rc"
}

# raw_chat -> the response JSON on stdout. The input goes through a file, never argv: a
# version's whole changelog outgrew ARG_MAX once (notes-version-summary, #264). The key goes to
# curl as a config line on stdin, never argv, where any `ps` would show it.
raw_chat() {
  local body out err resp code msg rc=0 tags=() keyopt=()
  [ -n "${LLM_BASE_URL:-}" ] || { echo "agentctl-run: raw: route '${ROUTE_NAME:-}' set no LLM_BASE_URL" >&2; return 69; }
  # In a curl config line a quote or backslash would be parsed, and a newline would end the line.
  case "${LLM_API_KEY:-}" in *[\"\\$'\n']*) echo "agentctl-run: raw: the key has a quote, backslash or newline" >&2; return 78 ;; esac
  [ -z "${RAW_MESSAGES:-}" ] || [ -r "$RAW_MESSAGES" ] || { echo "agentctl-run: raw: cannot read RAW_MESSAGES $RAW_MESSAGES" >&2; return 78; }
  [ -z "${LLM_API_KEY:-}" ] || keyopt=(-K -)
  [ -z "${RAW_TAGS:-}" ] || tags=(-H "x-litellm-tags: $RAW_TAGS")
  body="$(mktemp)" out="$(mktemp)" err="$(mktemp)" || return 1
  printf '%s' "$RAW_INPUT" >"$out"
  jq -n --arg m "${LLM_MODEL:-}" --rawfile s "${AGENT_PROMPT:-/dev/null}" --rawfile u "$out" \
      --slurpfile h "${RAW_MESSAGES:-/dev/null}" --argjson rf "${RAW_RESPONSE_FORMAT:-null}" \
      --argjson mt "${AGENT_MAX_TOKENS:-1024}" --argjson t "${AGENT_TEMPERATURE:-0}" \
      '{model: $m, temperature: $t, max_tokens: $mt, stream: false}
       + (if $rf then {response_format: $rf} else {} end)
       + {messages: ((if $s == "" then [] else [{role: "system", content: $s}] end)
                     + ($h[0] // []) + [{role: "user", content: $u}])}' >"$body" \
    || { rm -f "$body" "$out" "$err"; echo "agentctl-run: raw: RAW_MESSAGES or RAW_RESPONSE_FORMAT is not JSON" >&2; return 78; }
  # curl prints the -w status even when the transfer fails (000), so a caller can tell which.
  code="$(printf 'header = "Authorization: Bearer %s"\n' "${LLM_API_KEY:-}" \
    | curl -sS "${keyopt[@]}" --max-time "${RAW_TIMEOUT_S:-240}" -o "$out" -w '%{http_code}' \
        -H 'Content-Type: application/json' "${tags[@]}" --data-binary @"$body" \
        "${LLM_BASE_URL%/}/chat/completions" 2>"$err")" || rc=$?
  code="${code:-000}"
  [ -z "${RAW_STATUS_FILE:-}" ] || printf '%s\n' "$code" >"$RAW_STATUS_FILE"
  resp="$(cat "$out")"
  if [ "$code" = 000 ]; then
    echo "agentctl-run: raw: no answer from ${LLM_BASE_URL%/}/chat/completions: $(tr '\n' ' ' <"$err")" >&2
    rm -f "$body" "$out" "$err"; return "$((rc > 0 ? rc : 1))"
  fi
  rm -f "$body" "$out" "$err"
  printf '%s\n' "$resp"
  if [ "$code" != 200 ] || jq -e '.error' <<<"$resp" >/dev/null 2>&1; then
    msg="$(jq -r '(.error.message // .detail // .error // empty) | tostring | .[:600]' <<<"$resp" 2>/dev/null)"
    [ -n "$msg" ] || msg="$(printf '%s' "$resp" | head -c 300)"
    case "$code" in
      401|403) printf 'agentctl-run: raw: the gateway refused the %s (%s): %s\n' \
                 "$([ -n "${LLM_API_KEY:-}" ] && echo key || echo 'call, and the route sent no key')" "$code" "$msg" >&2 ;;
      *)       printf 'agentctl-run: raw: %s failed (%s): %s\n' "${LLM_MODEL:-the model}" "$code" "$msg" >&2 ;;
    esac
    return 1
  fi
  jq -e '(.choices[0].message.content // "") != ""' <<<"$resp" >/dev/null 2>&1 || {
    printf 'agentctl-run: raw: the reply has no content (%s, finish_reason %s)\n' "${LLM_MODEL:-}" \
      "$(jq -r '.choices[0].finish_reason // "none"' <<<"$resp" 2>/dev/null)" >&2; return 1; }
}
