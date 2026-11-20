#!/usr/bin/env bats
# agentctl-run on HARNESS=agy: the role contract as an `agy -p` call held by srt under a cleared env,
# the antigravity route, and the calls.jsonl line folded from agy's stream-json events. agy and srt
# are stubs (srt records its argv and env, then runs what follows --); the real agy never runs.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"
  mkdir -p "$HOME/.config/agentctl/roles" "$HOME/.config/agentctl/mcp" "$HOME/.config/agentctl/sandbox"
  printf '{"mcpServers":{}}\n' > "$HOME/.config/agentctl/mcp/none.json"
  role build yes yes yes none
  role observe no yes no none
  role nosub yes yes no none
  printf '%s\n' '{"sandbox": {"network": {"allowedDomains": ["daily-cloudcode-pa.googleapis.com"]},' \
    '"filesystem": {"denyRead": ["~/", "/tmp"]}}}' > "$HOME/.config/agentctl/sandbox/agy.json"

  cat > "$SANDBOX/bin/agy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$SANDBOX/agy-argv.txt"
cp "$REPO_ROOT/tests/fixtures/harness-contract/agy-success.jsonl" /dev/stdout
EOF
  cat > "$SANDBOX/bin/srt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$SANDBOX/srt-argv.txt"
env > "$SANDBOX/srt-env.txt"
cp "\$2" "$SANDBOX/srt-settings.json"
shift 3
exec "\$@"
EOF
  for b in bwrap socat; do printf '#!/bin/sh\n' > "$SANDBOX/bin/$b"; done
  chmod +x "$SANDBOX"/bin/{agy,srt,bwrap,socat}
  mkdir -p "$HOME/work"
  cd "$HOME/work"
}

# role NAME WRITE BASH TASK MCP
role() {
  printf 'ROLE_DESC="fixture %s"\nROLE_WRITE=%s\nROLE_BASH=%s\nROLE_TASK=%s\nROLE_MCP=%s\nROLE_MCP_DENY=""\nROLE_APPROVE="Read"\n' \
    "$1" "$2" "$3" "$4" "$5" > "$HOME/.config/agentctl/roles/$1.role"
}

agy_run() { SANDBOX_PROFILE=agy run "$RUN" --harness agy --data-class public "$@"; }

@test "an agy run is srt-held under a cleared env: flags before -p, the prompt last under the headless rule, its settings removed after" {
  export LITELLM_MASTER_KEY=sk-master GEMINI_API_KEY=g-key
  AGENTCTL_MODEL=gemini-3.8-flash-medium agy_run --role build -p "the input"
  assert_success
  assert_output --partial 'DONE'
  run cat "$SANDBOX/srt-argv.txt"
  assert_line --index 0 -- '--settings'
  assert_line --index 2 -- '--'
  assert_line --index 3 'agy'
  run cat "$SANDBOX/agy-argv.txt"
  assert_line --index 0 -- '--output-format'
  assert_line --index 1 'text'
  assert_line -- '--dangerously-skip-permissions'
  assert_line 'gemini-3.8-flash-medium'
  assert_equal "$(grep -nx -- '-p' "$SANDBOX/agy-argv.txt" | cut -d: -f1)" 6
  grep -q 'running headless' "$SANDBOX/agy-argv.txt" || fail "no headless rule in the prompt"
  assert_equal "$(tail -n 1 "$SANDBOX/agy-argv.txt")" 'the input'
  run grep -E '^(LITELLM_MASTER_KEY|GEMINI_API_KEY)=' "$SANDBOX/srt-env.txt"
  assert_failure
  grep -qx "TMPDIR=$HOME/.agent/agy/runs/tmp" "$SANDBOX/srt-env.txt" || fail "the jail's TMPDIR is not the run dir's tmp"
  run jq -c '[.filesystem.denyRead, (.filesystem.allowWrite | index("~/.gemini/antigravity-cli") != null or index("'"$HOME"'/.gemini/antigravity-cli") != null), (.filesystem.allowRead | index("'"$SANDBOX"'/bin/agy") != null)]' "$SANDBOX/srt-settings.json"
  assert_output '[["~/","/tmp"],true,true]'
  run ls "$HOME/.agent/agy/runs"
  assert_output 'tmp'
}

@test "agy refuses a run with no lane sandbox, a role that denies writes, or one that denies subagents, and never starts (negative control)" {
  run "$RUN" --harness agy --data-class public --role build -p x
  assert_failure
  assert_output --partial 'agy runs only in a lane sandbox'
  agy_run --role observe -p x
  assert_failure
  assert_output --partial 'cannot remove its write or shell tools'
  agy_run --role nosub -p x
  assert_failure
  assert_output --partial 'no per-run switch for them'
  [ ! -e "$SANDBOX/agy-argv.txt" ] || fail "agy ran for a role or lane it cannot enforce"
}

@test "with a tool srt needs missing, a sandboxed agy run refuses instead of running bare" {
  SANDBOX_SRT_NEEDS="srt nosuch-srt-helper" agy_run --role build -p x
  assert_failure 78
  assert_output --partial 'srt cannot hold it: nosuch-srt-helper is not on PATH'
  [ ! -e "$SANDBOX/agy-argv.txt" ] || fail "agy ran without what srt needs"
}

@test "agy defaults to the antigravity route, which refuses personal data, and checks the agy source's room" {
  SANDBOX_PROFILE=agy run "$RUN" --harness agy --role build -p x --explain
  assert_equal "$status" 78
  assert_output --partial 'REFUSED'
  agy_run --role build -p x --explain
  assert_success
  assert_output --partial 'route:       antigravity'
  assert_output --partial 'harness:     agy'
  assert_called 'claude-acct room --source agy --json'
  printf '{"name":"agy","room":{"ok":false,"reason":"capped","reasons":["capped"],"why":"fixture"}}\n' > "$NOTES_FIXTURE/room-agy.json"
  agy_run --role build -p x
  assert_failure
  assert_output --partial 'source agy has no room (capped)'
  [ ! -e "$SANDBOX/agy-argv.txt" ] || fail "agy ran on a capped source"
}

@test "a named run records one calls.jsonl line from agy's stream: the conversation, tokens less the cached part, no dollars, and a schema reply" {
  printf '{"type":"object"}\n' > "$SANDBOX/schema.json"
  export AGENTCTL_NAME=agy-test AGENTCTL_CALLS="$SANDBOX/calls.jsonl"
  agy_run --role build --schema "$SANDBOX/schema.json" -p x
  assert_success
  run jq -r '[.harness, .session_id, ."gen_ai.response.model", ."gen_ai.usage.input_tokens", .cache_read_tokens, (.cost_usd | tostring)] | join(" ")' "$AGENTCTL_CALLS"
  assert_output 'agy 8138a473-5239-47fc-afb9-b84f14384328 gemini-3.8-flash-low 4236 13716 null'
  run cat "$SANDBOX/agy-argv.txt"
  assert_line 'stream-json'
  assert_line -- '--json-schema'
  assert_line "$SANDBOX/schema.json"
}
