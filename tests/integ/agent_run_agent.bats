#!/usr/bin/env bats
# agentctl-run --agent <name>: a model call defined by its conf, recorded in calls.jsonl.
#
# Before this, a judge inside a script ran as `agentctl-run --role observe` with its prompt
# inline: no conf, no record of its own, and its cost and trace filed under whichever session
# or runner called it. The fleet-dispatch runner is ROLE=build, and its judge could inherit it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"
  CALLS="$HOME/.local/state/agentctl/calls.jsonl"

  # Inline role fixtures: the real roles live in the private overlay (see agent_run_headless).
  mkdir -p "$HOME/.config/agentctl/roles" "$HOME/.config/agentctl/mcp" "$AGENTCTL_CONF_DIR"
  for r in watcher builder; do
    printf 'ROLE_DESC="%s fixture"\nROLE_WRITE=no\nROLE_TASK=no\nROLE_BASH=yes\nROLE_MCP=none\nROLE_MCP_DENY=""\nROLE_APPROVE="Read"\n' "$r" \
      > "$HOME/.config/agentctl/roles/$r.role"
  done
  printf '{"mcpServers":{}}\n' > "$HOME/.config/agentctl/mcp/none.json"

  PROMPT_FILE="$SANDBOX/policy.md"
  printf 'You are the fixture judge.\n' > "$PROMPT_FILE"
  printf 'NAME=judge\nKIND=call\nLANE=observe\nROLE=watcher\nDESCRIPTION=x\nPROMPT="%s"\n' "$PROMPT_FILE" \
    > "$AGENTCTL_CONF_DIR/judge.conf"

  # The harness's exec target: logs argv and env, answers like `claude -p --output-format json`.
  fake_claude "$(cat <<'JSON'
{"type":"result","is_error":false,"result":"VERDICT-OK","session_id":"sess-1","total_cost_usd":0.012,"usage":{"input_tokens":120,"output_tokens":30,"cache_read_input_tokens":5,"cache_creation_input_tokens":0},"modelUsage":{"claude-sonnet-5-5":{}}}
JSON
)"
}

# fake_claude <json reply>: replies <json> to a --output-format json call, "plain" otherwise.
fake_claude() {
  printf '%s\n' "$1" > "$SANDBOX/claude.reply"
  {
    echo '#!/usr/bin/env bash'
    echo "printf '%s\n' \"\$@\" > '$SANDBOX/claude.argv'"
    echo "[ -t 0 ] || cat > '$SANDBOX/claude.stdin'"
    echo "printf 'OTEL=%s\nNAME=%s\n' \"\${OTEL_RESOURCE_ATTRIBUTES:-}\" \"\${AGENTCTL_NAME:-}\" > '$SANDBOX/claude.env'"
    echo "case \" \$* \" in *' --output-format json '*) cat '$SANDBOX/claude.reply' ;; *) echo plain ;; esac"
  } > "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/bin/claude"
}

@test "an agent call prints the plain result, puts the PROMPT file first, and writes one call line" {
  run "$RUN" --agent judge -p "the input"
  assert_success
  assert_output 'VERDICT-OK'
  # one input on stdin: the PROMPT file, a blank line, then the caller's input
  run grep -c 'You are the fixture judge.' "$SANDBOX/claude.stdin"
  assert_output 1
  run grep -A2 'You are the fixture judge.' "$SANDBOX/claude.stdin"
  assert_output "$(printf 'You are the fixture judge.\n\nthe input')"
  run jq -r '[.agent, .role, .exit, .session_id, .cost_usd, ."gen_ai.usage.input_tokens", ."gen_ai.response.model", .raw] | @tsv' "$CALLS"
  assert_output "$(printf 'judge\twatcher\t0\tsess-1\t0.012\t120\tclaude-sonnet-5-5\tVERDICT-OK')"
  assert_equal "$(jq -r .prompt_sha "$CALLS")" "$(git hash-object "$PROMPT_FILE")"
  assert_equal "$(wc -l < "$CALLS")" 1
}

@test "the conf's role wins over a parent runner's ROLE; a --role flag still wins over the conf" {
  ROLE=builder run "$RUN" --agent judge --explain
  assert_success
  assert_line 'role:        watcher'
  assert_line 'agent:       judge (call)'
  assert_line --regexp '^prompt: +.*policy\.md  sha [0-9a-f]{12}$'
  run "$RUN" --agent judge --role builder --explain
  assert_line 'role:        builder'
}

@test "the call is labelled with its own agent in telemetry, keeping the other attributes" {
  OTEL_RESOURCE_ATTRIBUTES='service.name=claude-code,agentctl.runner=fleet-dispatch,host.name=h' \
    AGENTCTL_NAME=fleet-dispatch run "$RUN" --agent judge -p x
  assert_success
  run cat "$SANDBOX/claude.env"
  assert_line 'OTEL=service.name=claude-code,host.name=h,agentctl.runner=judge'
  assert_line 'NAME=judge'
}

@test "a caller's call id links its record to the call line" {
  AGENTCTL_CALL_ID=abc123 run "$RUN" --agent judge -p x
  assert_success
  assert_equal "$(jq -r .id "$CALLS")" abc123
}

@test "a reply that is not a JSON result is passed through and still recorded with its exit" {
  printf '#!/usr/bin/env bash\necho "API Error: overloaded"; exit 3\n' > "$SANDBOX/bin/claude"
  run "$RUN" --agent judge -p x
  assert_failure 3
  assert_output 'API Error: overloaded'
  assert_equal "$(jq -r '[.exit, .raw] | @tsv' "$CALLS")" "$(printf '3\tAPI Error: overloaded')"
}

# schema_conf: the fixture judge with a SCHEMA key, and a reply that fills it.
schema_conf() {
  printf '{"type":"object","properties":{"call":{"type":"string"}}}\n' > "$SANDBOX/verdict.schema.json"
  printf 'SCHEMA="%s"\n' "$SANDBOX/verdict.schema.json" >> "$AGENTCTL_CONF_DIR/judge.conf"
  fake_claude '{"type":"result","is_error":false,"result":"","structured_output":{"call":"human","reason":"a b"},"session_id":"sess-1"}'
}

@test "an agent with a SCHEMA passes it to claude and prints the structured reply as one JSON line" {
  schema_conf
  run "$RUN" --agent judge -p x
  assert_success
  assert_output '{"call":"human","reason":"a b"}'
  run grep -Fx -A1 -- --json-schema "$SANDBOX/claude.argv"
  assert_line '{"type":"object","properties":{"call":{"type":"string"}}}'
  assert_equal "$(jq -r .raw "$CALLS")" '{"call":"human","reason":"a b"}'
}

@test "a schema run with no structured_output prints its prose, so the caller's parse fails (negative control)" {
  schema_conf
  fake_claude '{"type":"result","is_error":true,"result":"gave up","session_id":"sess-1"}'
  run "$RUN" --agent judge -p x
  assert_output 'gave up'
}

@test "an agent without a SCHEMA passes no --json-schema (negative control)" {
  run "$RUN" --agent judge -p x
  assert_success
  run grep -Fx -- --json-schema "$SANDBOX/claude.argv"
  assert_failure
}

@test "a SCHEMA that is not readable JSON is refused before the harness runs (negative control)" {
  printf 'SCHEMA="%s"\n' "$SANDBOX/missing.json" >> "$AGENTCTL_CONF_DIR/judge.conf"
  run "$RUN" --agent judge -p x
  assert_failure
  assert_output --partial 'not a readable JSON file'
  assert [ ! -e "$SANDBOX/claude.argv" ]
}

@test "an unregistered agent is refused before the harness runs (negative control)" {
  run "$RUN" --agent nobody -p x
  assert_failure 78
  assert_output --partial "no agent 'nobody'"
  assert [ ! -e "$SANDBOX/claude.argv" ]
  assert [ ! -e "$CALLS" ]
}

@test "a call without --agent is exec'd as before and writes no call line (negative control)" {
  run "$RUN" --role watcher -p x
  assert_success
  assert_output plain
  assert [ ! -e "$CALLS" ]
}
