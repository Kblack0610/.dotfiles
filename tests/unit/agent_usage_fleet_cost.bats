#!/usr/bin/env bats
# agent-usage fleet-cost: billed sessions keep their bill, the rest are priced at rates fitted to the
# billed ones, and a model the fit cannot price is named and never $0. Prometheus is a stub.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export AU="$REPO_ROOT/.local/bin/agent-usage"
  export PROJECTS_ROOT="$HOME/.claude/projects" SESS_ROOT="$HOME/sess" OUTCOMES_ROOT="$HOME/outcomes" AGENT_QUEUE_DIR="$HOME/queue"
  export FLEET_SHEPHERD_DIR="$HOME/shepherd" AGENTCTL_STATE_DIR="$HOME/state" PROM_LIB="$HOME/prom-stub.sh" FIX="$HOME/fix"
  mkdir -p "$PROJECTS_ROOT/-p" "$SESS_ROOT" "$OUTCOMES_ROOT/p" "$AGENT_QUEUE_DIR" "$FLEET_SHEPHERD_DIR" "$AGENTCTL_STATE_DIR" "$FIX"
  NOW=$(date +%s); export NOW
  printf 'pass1\n' | sed 's/^/1\t/' > "$FLEET_SHEPHERD_DIR/passes.tsv"
  cat > "$PROM_LIB" <<'STUB'
prom_q() {
  local f
  case "$1" in
    *"by (model)"*litellm_spend_metric_total*) f=gw-models ;;
    *litellm_spend_metric_total*) f=gw ;;
    *USD_total*offset*) f=before ;;
    *agentctl_runner*USD_total*) f=window ;;
    *USD_total*) f=fit-cost ;;
    *token_usage*) f=fit-tok ;;
  esac
  printf '{"status":"success","data":{"result":%s}}' "$(cat "$FIX/$f")"
}
STUB
  # Opus billed at 4/20/0.2/8 per Mtok over mixed sessions; noisy is a model whose bills fit nothing.
  python3 - <<'PY'
import json, os, random
fix = os.environ["FIX"]
random.seed(7)
cost, tok = [], []
def add(sid, model, t, usd):
    cost.append({"metric": {"session_id": sid, "model": model}, "value": [0, str(usd)]})
    for k, v in zip(("input", "output", "cacheRead", "cacheCreation"), t):
        tok.append({"metric": {"session_id": sid, "model": model, "type": k}, "value": [0, str(v)]})
for i in range(12):
    t = [random.randint(1, 9) * 10**5, random.randint(1, 9) * 10**5, random.randint(1, 9) * 10**7, random.randint(1, 9) * 10**6]
    add(f"o{i}", "claude-opus-5-5", t, sum(r * v / 1e6 for r, v in zip((4, 20, 0.2, 8), t)))
for i in range(12):
    t = [10**6, 10**6, 10**7, 10**6]
    add(f"n{i}", "claude-noisy-1", [v * random.randint(1, 9) for v in t], random.uniform(1, 200))
for i in range(2):
    add(f"f{i}", "claude-few-1", [10**5] * 4, 1.0)
json.dump(cost, open(f"{fix}/fit-cost", "w"))
json.dump(tok, open(f"{fix}/fit-tok", "w"))
w = [{"metric": {"session_id": "billed", "model": "claude-opus-5-5", "agentctl_runner": "dream"}, "value": [0, "11"]},
     {"metric": {"session_id": "ghost", "model": "claude-opus-5-5"}, "value": [0, "2"]}]
json.dump(w, open(f"{fix}/window", "w"))
json.dump([{"metric": {"session_id": "billed", "model": "claude-opus-5-5"}, "value": [0, "1"]}], open(f"{fix}/before", "w"))
json.dump([{"metric": {}, "value": [0, "5.5"]}], open(f"{fix}/gw", "w"))
json.dump([{"metric": {"model": "gw-sonnet"}, "value": [0, "9"]}], open(f"{fix}/gw-models", "w"))
PY
}

turn() { # SID MODEL INPUT OUTPUT CACHE_WRITE CACHE_READ
  jq -cn --arg s "$1" --arg m "$2" --argjson i "$3" --argjson o "$4" --argjson w "$5" --argjson r "$6" --arg t "$(date -u -d "@$((NOW - 600))" +%FT%TZ)" \
    '{type:"assistant",timestamp:$t,sessionId:$s,cwd:"/p",entrypoint:($ENV.ENTRY // "cli"),message:{id:($s+$m),model:$m,usage:{input_tokens:$i,output_tokens:$o,cache_creation_input_tokens:$w,cache_read_input_tokens:$r}}}' \
    >> "$PROJECTS_ROOT/-p/$1.jsonl"
}
cost() { "$AU" fleet-cost --json | jq -c "$1 | walk(if type == \"number\" then . + 0 else . end)"; }

@test "a fit recovers the billed rates and scores them on sessions it did not see" {
  turn unbilled claude-opus-5-5 1000 1000 1000 1000
  run cost '.rates["claude-opus-5-5"] | [.input, .output, .cache_read, .cache_write, .sessions, (.fit_error_pct < 5)]'
  assert_success
  assert_output '[4,20,0.2,8,12,true]'
}

@test "an unbilled session is priced from its tokens; a billed one keeps its bill less what came before the window" {
  turn unbilled claude-opus-5-5 1000000 1000000 0 0
  turn billed claude-opus-5-5 1 1 1 1
  run cost '[.total.claude_measured, .by_model["claude-opus-5-5"].measured, .by_model["claude-opus-5-5"].estimated, .coverage.sessions_estimated]'
  assert_success
  assert_output '[12,12,24,1]'
}

@test "a model the fit cannot price is named with why and adds no dollars" {
  turn few claude-few-1 1000000 1000000 0 0
  turn noisy claude-noisy-1 1000000 1000000 0 0
  turn never claude-never-1 1000000 1000000 0 0
  run cost '[.total.estimated, (.unpriced | to_entries | map([.key, .value.why]) | sort), (.rates | has("claude-noisy-1"))]'
  assert_success
  assert_output '[0,[["claude-few-1","too few priced tokens"],["claude-never-1","no billed sessions"],["claude-noisy-1","the fit missed its held-out sessions"]],false]'
}

@test "the gateway's own model names are its metered dollars, not an estimate" {
  turn lazer gw-sonnet 1000000 1000000 0 0
  run cost '[.other_harness.gateway.usd, .other_harness.gateway.sessions, .total.estimated, (.unpriced | length)]'
  assert_success
  assert_output '[5.5,1,0,0]'
}

@test "shepherd and every runner are their own rows; a session with no transcript still counts by its bill" {
  turn pass1 claude-opus-5-5 1000000 0 0 0
  ENTRY=sdk-cli turn billed claude-opus-5-5 1 1 1 1
  printf '{"session_id":"billed","agent":"dream","account":"/h/.claude-bnb"}\n' > "$AGENTCTL_STATE_DIR/calls.jsonl"
  run cost '[.by_runner.shepherd.usd, .by_runner.dream.measured, .by_account["claude-bnb"].measured, .by_origin.interactive.measured]'
  assert_success
  assert_output '[4,10,10,2]'
}

@test "billed sessions costing more than their transcripts sets the helper line on the unbilled ones, with its range" {
  turn billed claude-opus-5-5 2000000 0 0 0   # priced $8, billed $10: 25% the transcript never saw
  turn unbilled claude-opus-5-5 1000000 0 0 0
  run cost '[.total.helper_usd, .total.helper_range, .total.estimated]'
  assert_success
  assert_output '[1,[0,1],5]'
}

@test "Codex is tagged by its price source and a Prometheus failure writes nothing" {
  printf '{"session_id":"x","harness":"codex","updated_epoch":%s,"cost_usd":3.5,"cost_src":"price"}\n{"session_id":"y","harness":"codex","updated_epoch":%s,"cost_usd":null}\n' "$NOW" "$NOW" > "$OUTCOMES_ROOT/p/2026-11.jsonl"
  run cost '.other_harness.codex'
  assert_output '{"usd":3.5,"sessions":2,"priced":1,"source":"price"}'
  echo 'prom_q() { return 1; }' > "$PROM_LIB"
  run "$AU" fleet-cost --json
  assert_failure
  refute_output --partial '"total"'
}
