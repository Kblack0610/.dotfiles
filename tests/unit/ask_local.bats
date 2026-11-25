#!/usr/bin/env bats
# ask-local: the terminal client of the local model's gateway route. Driven through the real
# agentctl-run route resolution against a stub of /v1/chat/completions
# (tests/fixtures/openai-stub.py) over real curl, so what is pinned is what goes on the wire
# and how each failure reads, not a mocked curl's view.

setup_file() {
  STUB_DIR="$BATS_FILE_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  mkfifo "$STUB_DIR/ready"
  python3 "$BATS_TEST_DIRNAME/../fixtures/openai-stub.py" "$STUB_DIR" >"$STUB_DIR/ready" 3>&- &
  echo $! >"$STUB_DIR/pid"
  read -r port <"$STUB_DIR/ready"
  echo "$port" >"$STUB_DIR/port"
}

teardown_file() {
  kill "$(cat "$BATS_FILE_TMPDIR/stub/pid")" 2>/dev/null || true
}

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  STUB_DIR="$BATS_FILE_TMPDIR/stub"
  ASK_LOCAL="$REPO_ROOT/.local/bin/ask-local"
  export AGENTCTL_RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"
  export AGENTCTL_ROLES="$SANDBOX/roles" AGENTCTL_ROUTES="$SANDBOX/routes"
  mkdir -p "$AGENTCTL_ROLES" "$AGENTCTL_ROUTES"
  printf '%s\n' 'ROLE_DESC="test observe"' ROLE_WRITE=no ROLE_TASK=no ROLE_BASH=no ROLE_MCP=none \
    'ROLE_MCP_DENY=""' 'ROLE_APPROVE="Read"' >"$AGENTCTL_ROLES/observe.role"
  ASK_LOCAL_GATEWAY_URL="http://127.0.0.1:$(cat "$STUB_DIR/port")/v1"
  route gateway-local "$ASK_LOCAL_GATEWAY_URL" "local (qwen3.5-9b)"
  unset AGENT_QUEUE_ITEM LLM_BASE_URL LLM_MODEL LLM_API_KEY
  KEY="none.$BATS_SUITE_TEST_NUMBER"
}

# route <name> <base-url> <model> [key-file [personal-safe]]: a gateway route whose key is the
# sandbox's key file (default: the local model's).
route() {
  printf '%s\n' 'ROUTE_DESC="test"' 'ROUTE_TRANSPORT="openai-compatible"' "ROUTE_BASE_URL=\"$2\"" \
    "ROUTE_MODEL_RAW=\"$3\"" "ROUTE_KEY_SOURCE=\"file:~/.local/state/ask-local/${4:-key}\"" 'ROUTE_PAYER="nobody"' \
    "ROUTE_PERSONAL_SAFE=\"${5:-yes}\"" 'ROUTE_WORK_SAFE="no"' 'ROUTE_FALLBACK_SAFE="yes"' \
    "ROUTE_VERIFY_MODEL=\"$3\"" "ROUTE_VERIFY_API_BASE=\"$2\"" 'ROUTE_HARNESSES="raw"' \
    >"$AGENTCTL_ROUTES/$1.route"
}

# key <behaviour>: the stub answers by the part before the dot and files the request under the
# whole key, so a test reads only its own request when bats runs the file's tests in parallel.
key() {
  KEY="$1.$BATS_SUITE_TEST_NUMBER"
  mkdir -p "$HOME/.local/state/ask-local"
  printf '%s\n' "$KEY" >"$HOME/.local/state/ask-local/key"
  chmod 600 "$HOME/.local/state/ask-local/key"
}
sent() { jq -cr "$1" "$STUB_DIR/$KEY.json"; }

@test "a prompt goes to the route's endpoint, model and key and prints the answer" {
  key good
  run "$ASK_LOCAL" why is the sky blue </dev/null
  assert_success
  assert_output "echo: why is the sky blue"
  assert_equal "$(sent .path)" "/v1/chat/completions"
  assert_equal "$(sent .body.model)" "local (qwen3.5-9b)"
  assert_equal "$(sent .headers.Authorization)" "Bearer $KEY"
  assert_equal "$(sent '.headers["x-litellm-tags"]')" "ask-local"
  assert_equal "$(sent '.body | has("response_format")')" "false"
}

@test "stdin is appended to the prompt, and stdin alone is the prompt" {
  key good
  run bash -c 'printf "diff line\n" | "$0" "write a commit message"' "$ASK_LOCAL"
  assert_success
  assert_equal "$(sent '.body.messages[-1].content')" $'write a commit message\n\ndiff line'
  run bash -c 'printf "only stdin\n" | "$0"' "$ASK_LOCAL"
  assert_success
  assert_output "echo: only stdin"
}

@test "--route picks another route; --system and --max-tokens reach the body" {
  key good
  route other "$ASK_LOCAL_GATEWAY_URL" "other (m)"
  run "$ASK_LOCAL" --route other --system "be terse" --max-tokens 064 hi </dev/null
  assert_success
  assert_equal "$(sent '.body.messages[0]')" '{"role":"system","content":"be terse"}'
  assert_equal "$(sent .body.model)" "other (m)"
  assert_equal "$(sent .body.max_tokens)" "64"
}

@test "the queue item rides along as a gateway tag" {
  key good
  AGENT_QUEUE_ITEM=some-item run "$ASK_LOCAL" hi </dev/null
  assert_success
  assert_equal "$(sent '.headers["x-litellm-tags"]')" "ask-local,queue:some-item"
}

@test "--json asks for a JSON object and prints it when the answer parses" {
  key json
  run "$ASK_LOCAL" --json "give me ok" </dev/null
  assert_success
  assert_output '{"ok": true}'
  assert_equal "$(sent '.body.response_format.type')" "json_object"
}

@test "--schema sends the schema as a strict json_schema format" {
  key json
  echo '{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}' >"$SANDBOX/s.json"
  run "$ASK_LOCAL" --schema "$SANDBOX/s.json" "give me ok" </dev/null
  assert_success
  assert_equal "$(sent '.body.response_format.type')" "json_schema"
  assert_equal "$(sent '.body.response_format.json_schema.strict')" "true"
  assert_equal "$(sent '.body.response_format.json_schema.schema.required[0]')" "ok"
}

@test "--json fails when the model answers prose" {
  key prose
  run "$ASK_LOCAL" --json "give me ok" </dev/null
  assert_failure 1
  assert_output --partial "did not return valid JSON"
}

@test "--json wants an object; --schema takes any JSON value, false included" {
  key scalar
  run "$ASK_LOCAL" --json "is it?" </dev/null
  assert_failure 1
  assert_output --partial "did not return valid JSON"
  echo '{"type": "boolean"}' >"$BATS_TEST_TMPDIR/s.json"
  run "$ASK_LOCAL" --schema "$BATS_TEST_TMPDIR/s.json" "is it?" </dev/null
  assert_success
  assert_output "false"
}

@test "--raw prints the whole response" {
  key good
  run "$ASK_LOCAL" --raw hi </dev/null
  assert_success
  assert_equal "$(jq -r '.choices[0].finish_reason' <<<"$output")" "stop"
}

@test "a route with no key stops with exit 2 once the gateway turns the call away, and says no key was sent" {
  run "$ASK_LOCAL" hi </dev/null
  assert_failure 2
  assert_output --partial "the route sent no key (401)"
}

@test "a route that does not exist stops before any call, exit 2, with the resolver's reason" {
  key good
  run "$ASK_LOCAL" --route nope hi </dev/null
  assert_failure 2
  assert_output --partial "unknown route 'nope'"
  [ ! -e "$STUB_DIR/$KEY.json" ]
}

@test "a refused key says so, exit 1" {
  key wrong
  run "$ASK_LOCAL" hi </dev/null
  assert_failure 1
  assert_output --partial "refused the key (401)"
  refute_output --partial "systemctl"
}

@test "a route whose model is down fails with the gateway's error and where to look" {
  key down
  run "$ASK_LOCAL" hi </dev/null
  assert_failure 1
  assert_output --partial "local (qwen3.5-9b) failed (500): litellm.APIConnectionError"
  assert_output --partial "systemctl --user status llama-server"
}

@test "an unreachable gateway fails with exit 1 and names it" {
  key good
  route dead http://127.0.0.1:9/v1 "local (qwen3.5-9b)"
  run "$ASK_LOCAL" --route dead hi </dev/null
  assert_failure 1
  assert_output --partial "no answer from http://127.0.0.1:9/v1/chat/completions"
}

@test "a gateway that never answers is cut off by --timeout" {
  key hang
  run "$ASK_LOCAL" --timeout 1 hi </dev/null
  assert_failure 1
  assert_output --partial "no answer from"
  assert_output --partial "timed out"
}

@test "an empty answer is a failure, not a blank line" {
  key empty
  run "$ASK_LOCAL" hi </dev/null
  assert_failure 1
  assert_output --partial "no content (local (qwen3.5-9b), finish_reason length)"
  assert_output --partial "raise --max-tokens?"
}

@test "--chat keeps the conversation and /reset clears it" {
  key good
  run bash -c 'printf "first\nsecond\n/reset\nthird\n\n" | "$0" --chat' "$ASK_LOCAL"
  assert_success
  assert_output --partial "echo: first"
  assert_output --partial "echo: second"
  assert_output --partial "(history cleared)"
  # The last request carries only the turn after the reset.
  assert_equal "$(sent '.body.messages | length')" "1"
  assert_equal "$(sent '.body.messages[0].content')" "third"
}

@test "--chat sends earlier turns with the next one" {
  key good
  run bash -c 'printf "first\nsecond\n" | "$0" --chat' "$ASK_LOCAL"
  assert_success
  assert_equal "$(sent '[.body.messages[].role] | join(",")')" "user,assistant,user"
  assert_equal "$(sent '.body.messages[1].content')" "echo: first"
}

@test "usage errors exit 2 without a call" {
  key good
  run "$ASK_LOCAL" --max-tokens lots hi </dev/null
  assert_failure 2
  run "$ASK_LOCAL" --bogus </dev/null
  assert_failure 2
  run "$ASK_LOCAL" </dev/null
  assert_failure 2
  [ ! -e "$STUB_DIR/$KEY.json" ]
}

@test "a key that curl would parse as config stops before any call, exit 2" {
  key good
  printf '%s\n' 'bad"key' >"$HOME/.local/state/ask-local/key"
  run "$ASK_LOCAL" hi </dev/null
  assert_failure 2
  assert_output --partial "the key has a quote, backslash or newline"
  [ ! -e "$STUB_DIR/$KEY.json" ]
}

@test "--raw prints the response of an empty answer too" {
  key empty
  run "$ASK_LOCAL" --raw hi </dev/null
  assert_success
  assert_equal "$(jq -r '.choices[0].finish_reason' <<<"$output")" "length"
}

@test "the name, model and schema of a calling agent do not reach the call" {
  key good
  AGENTCTL_NAME=outer AGENTCTL_AGENT=outer AGENTCTL_MODEL=other MODEL=other AGENT_SCHEMA=/nope \
    run "$ASK_LOCAL" --raw hi </dev/null
  assert_success
  assert_equal "$(jq -r '.choices[0].message.content' <<<"$output")" "echo: hi"
  assert_equal "$(sent .body.model)" "local (qwen3.5-9b)"
  [ ! -s "$HOME/.local/state/agentctl/calls.jsonl" ]
}

# free_route <behaviour>: the --free fallback route, on its own key, as the real one is: not
# personal-safe, so only a call declared public may use it.
free_route() {
  FREE_KEY="$1.$BATS_SUITE_TEST_NUMBER"
  route gateway-free "$ASK_LOCAL_GATEWAY_URL" "free-qwen (qwen3.8-27b)" free-key no
  printf '%s\n' "$FREE_KEY" >"$HOME/.local/state/ask-local/free-key"
  chmod 600 "$HOME/.local/state/ask-local/free-key"
  export ASK_LOCAL_FREE_LEDGER="$SANDBOX/free-ledger"
}
free_sent() { jq -cr "$1" "$STUB_DIR/$FREE_KEY.json"; }

@test "--free: a down local model hands the one call to the free route as public input" {
  key down
  free_route good
  run "$ASK_LOCAL" --free why is the sky blue </dev/null
  assert_success
  assert_output --partial "trying gateway-free"
  assert_output --partial "echo: why is the sky blue"
  assert_equal "$(free_sent .body.model)" "free-qwen (qwen3.8-27b)"
  assert_equal "$(free_sent '.headers.Authorization')" "Bearer $FREE_KEY"
  [ "$(wc -l <"$ASK_LOCAL_FREE_LEDGER")" = 1 ]
}

@test "--free: an unreachable local gateway falls back too" {
  key good
  route gateway-local http://127.0.0.1:9/v1 "local (qwen3.5-9b)"
  free_route good
  run "$ASK_LOCAL" --free hi </dev/null
  assert_success
  assert_output --partial "echo: hi"
}

@test "without --free a down local model fails and the free route is never called" {
  key down
  free_route good
  run "$ASK_LOCAL" hi </dev/null
  assert_failure 1
  refute_output --partial "gateway-free"
  [ ! -e "$STUB_DIR/$FREE_KEY.json" ]
}

@test "--free: a local model that answers never touches the free route or the ledger" {
  key good
  free_route good
  run "$ASK_LOCAL" --free hi </dev/null
  assert_success
  assert_output "echo: hi"
  [ ! -e "$STUB_DIR/$FREE_KEY.json" ]
  [ ! -e "$ASK_LOCAL_FREE_LEDGER" ]
}

@test "--free: a refused key or an empty answer is not a down model, so no fallback" {
  key wrong
  free_route good
  run "$ASK_LOCAL" --free hi </dev/null
  assert_failure 1
  [ ! -e "$STUB_DIR/$FREE_KEY.json" ]
  key empty
  run "$ASK_LOCAL" --free hi </dev/null
  assert_failure 1
  [ ! -e "$STUB_DIR/$FREE_KEY.json" ]
}

@test "--free: a prompt that does not fit one minute's tokens stays a local failure" {
  key down
  free_route good
  run bash -c 'head -c 14000 /dev/zero | tr "\0" a | "$0" --free summarize' "$ASK_LOCAL"
  assert_failure 1
  assert_output --partial "--free skipped, the call is about"
  [ ! -e "$STUB_DIR/$FREE_KEY.json" ]
}

@test "--free: a busy local model (429) falls back too" {
  key busy
  free_route good
  run "$ASK_LOCAL" --free hi </dev/null
  assert_success
  assert_output --partial "echo: hi"
}

@test "--free: a free route that fails fails once with its own error and no llama-server hint" {
  key down
  free_route wrong
  run "$ASK_LOCAL" --free hi </dev/null
  assert_failure 1
  assert_output --partial "refused the key (401)"
  refute_output --partial "systemctl"
}

@test "--free: a --max-tokens that alone passes the minute's tokens is skipped" {
  key down
  free_route good
  run "$ASK_LOCAL" --free --max-tokens 7500 hi </dev/null
  assert_failure 1
  assert_output --partial "--free skipped, the call is about"
  [ ! -e "$STUB_DIR/$FREE_KEY.json" ]
}

@test "--free: no route gateway-free is a setup error that books nothing" {
  key down
  export ASK_LOCAL_FREE_LEDGER="$SANDBOX/free-ledger"
  run "$ASK_LOCAL" --free hi </dev/null
  assert_failure 2
  assert_output --partial "unknown route 'gateway-free'"
  [ ! -e "$ASK_LOCAL_FREE_LEDGER" ]
}

@test "--free needs the default local route" {
  key good
  route other "$ASK_LOCAL_GATEWAY_URL" "other (m)"
  run "$ASK_LOCAL" --free --route other hi </dev/null
  assert_failure 2
  assert_output --partial "--free falls back from the default local route only"
}

@test "--free: the request and token windows are kept, and a refused call books nothing" {
  key down
  free_route good
  now="$(date +%s)"
  for _ in $(seq 14); do echo "$now 10"; done >"$ASK_LOCAL_FREE_LEDGER"
  run "$ASK_LOCAL" --free hi </dev/null
  assert_failure 1
  assert_output --partial "14 calls in the last minute, the limit is 14"
  echo "$now 6500" >"$ASK_LOCAL_FREE_LEDGER"
  run "$ASK_LOCAL" --free hi </dev/null
  assert_failure 1
  assert_output --partial "6500 tokens went in the last minute"
  [ "$(wc -l <"$ASK_LOCAL_FREE_LEDGER")" = 1 ]
  [ ! -e "$STUB_DIR/$FREE_KEY.json" ]
}

@test "--free: the day's tokens are capped, and calls older than a day drop out of the ledger" {
  key down
  free_route good
  now="$(date +%s)"
  printf '%s\n' "$((now - 3600)) 99500" "$((now - 90000)) 50000" >"$ASK_LOCAL_FREE_LEDGER"
  run "$ASK_LOCAL" --free hi </dev/null
  assert_failure 1
  assert_output --partial "99500 tokens went in the last day"
  printf '%s\n' "$((now - 90000)) 50000" >"$ASK_LOCAL_FREE_LEDGER"
  run "$ASK_LOCAL" --free hi </dev/null
  assert_success
  [ "$(wc -l <"$ASK_LOCAL_FREE_LEDGER")" = 1 ]
}

@test "the free route refuses a call that is not declared public, so --route cannot reach it with personal data" {
  key good
  free_route good
  run "$ASK_LOCAL" --route gateway-free hi </dev/null
  assert_failure 2
  assert_output --partial "REFUSED: DATA_CLASS=personal on route 'gateway-free'"
  [ ! -e "$STUB_DIR/$FREE_KEY.json" ]
}

@test "--free is for one-shot calls, not --chat" {
  key good
  run "$ASK_LOCAL" --chat --free </dev/null
  assert_failure 2
  assert_output --partial "--free works on one-shot calls"
}
