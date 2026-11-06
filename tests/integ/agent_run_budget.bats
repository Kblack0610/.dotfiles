#!/usr/bin/env bats
# agentctl-run budgets (lib/budget.sh): a named call runs on its conf's budget and stops
# itself at it, before the call, with BLOCKED in its state and exit 75.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"
  CALLS="$HOME/.local/state/agentctl/calls.jsonl"
  mkdir -p "$HOME/.config/agentctl/roles" "$HOME/.config/agentctl/mcp" "$AGENTCTL_CONF_DIR" "$(dirname "$CALLS")"
  printf 'ROLE_DESC="watcher fixture"\nROLE_WRITE=no\nROLE_TASK=no\nROLE_BASH=yes\nROLE_MCP=none\nROLE_MCP_DENY=""\nROLE_APPROVE="Read"\n' \
    > "$HOME/.config/agentctl/roles/watcher.role"
  printf '{"mcpServers":{}}\n' > "$HOME/.config/agentctl/mcp/none.json"
  printf 'You are the fixture judge.\n' > "$SANDBOX/policy.md"
  printf 'NAME=judge\nKIND=call\nROLE=watcher\nPROMPT="%s"\nBUDGET_CALL_USD=0.5\nBUDGET_DAY_USD=10\nMAX_CALLS_HOUR=3\n' \
    "$SANDBOX/policy.md" > "$AGENTCTL_CONF_DIR/judge.conf"
  {
    echo '#!/usr/bin/env bash'
    echo "printf '%s\n' \"\$@\" > '$SANDBOX/claude.argv'"
    echo "[ -t 0 ] || cat >/dev/null"
    echo "echo '{\"type\":\"result\",\"result\":\"OK\",\"session_id\":\"s\",\"total_cost_usd\":0.25}'"
  } > "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/bin/claude"
}

# spent <agent> <usd> <at>: one earlier call line
spent() {
  jq -cn --arg a "$1" --argjson c "$2" --arg at "$3" '{agent: $a, at: $at, cost_usd: $c}' >> "$CALLS"
}

@test "under budget, an agent's print call carries its conf's per-call cap and is recorded" {
  run "$RUN" --agent judge -p x
  assert_success
  assert_output OK
  run grep -A1 -x -- --max-budget-usd "$SANDBOX/claude.argv"
  assert_line --index 1 0.5
  run jq -r '.agent' "$CALLS"
  assert_output judge
}

@test "over the day budget, the call is not made: exit 75, the reason, BLOCKED" {
  spent judge 6 "$(date -Iseconds -d '-3 hours')"
  spent judge 5 "$(date -Iseconds -d '-2 hours')"
  spent other 50 "$(date -Iseconds)"
  run "$RUN" --agent judge -p x
  assert_failure 75
  assert_output --partial 'over its daily budget: $11 of $10'
  assert [ ! -e "$SANDBOX/claude.argv" ]
  assert_equal "$(cat "$HOME/.local/state/agentctl/judge/last-outcome")" BLOCKED
}

@test "yesterday's spend does not count against today" {
  spent judge 50 "$(date -Iseconds -d 'yesterday 12:00')"
  run "$RUN" --agent judge -p x
  assert_success
}

@test "at the hourly cap the call is not made; calls older than an hour do not count" {
  spent judge 0 "$(date -Iseconds -d '-2 hours')"
  spent judge 0 "$(date -Iseconds -d '-10 minutes')"
  spent judge 0 "$(date -Iseconds -d '-5 minutes')"
  run "$RUN" --agent judge -p x
  assert_success
  run "$RUN" --agent judge -p x
  assert_failure 75
  assert_output --partial 'rate: 3 calls in the last hour, cap 3'
}

@test "a runner named by its unit gets the default budget and is recorded under that name" {
  AGENTCTL_NAME=dream run "$RUN" --role watcher -p x
  assert_success
  run grep -A1 -x -- --max-budget-usd "$SANDBOX/claude.argv"
  assert_line --index 1 2
  run jq -r '.agent' "$CALLS"
  assert_output dream
}

@test "an agent's conf budget replaces the parent runner's" {
  spent judge 4 "$(date -Iseconds)"
  BUDGET_DAY_USD=3 BUDGET_CALL_USD=9 AGENTCTL_NAME=fleet-dispatch run "$RUN" --agent judge -p x
  assert_success
  run grep -A1 -x -- --max-budget-usd "$SANDBOX/claude.argv"
  assert_line --index 1 0.5
}

@test "explain prints the budget and what is spent" {
  spent judge 1.5 "$(date -Iseconds)"
  run "$RUN" --agent judge --explain -p x
  assert_success
  assert_output --partial 'budget:      judge: $0.5 a call, $1.5 of $10 today, 1 of 3 calls this hour'
}

@test "a hand run has no budget and no cap (negative control)" {
  spent '' 99 "$(date -Iseconds)"
  run "$RUN" --role watcher -p x
  assert_success
  refute grep -qx -- --max-budget-usd "$SANDBOX/claude.argv"
  run "$RUN" --role watcher --explain -p x
  assert_output --partial 'budget:      none (a hand run)'
}
