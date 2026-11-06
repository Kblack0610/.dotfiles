#!/usr/bin/env bats
# agent-usage langfuse: the reader's shape, over stub curl and rbw. The stub answers each
# query from its span name and dimension, so the test pins what the reader asks for too.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  AU="$REPO_ROOT/.local/bin/agent-usage"
  export SO_LF_URL=http://lf.test CURL_LOG="$BATS_TEST_TMPDIR/curl.log" CURL_STDIN="$BATS_TEST_TMPDIR/curl.stdin"
  export LF_RBW="$BATS_TEST_TMPDIR/rbw" LF_CURL="$BATS_TEST_TMPDIR/curl"
  printf '#!/bin/sh\necho pk:sk\n' > "$LF_RBW"
  cat > "$LF_CURL" <<'STUB'
#!/usr/bin/env bash
cat >> "$CURL_STDIN"
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *v2/observations*litellm_request*) echo '{"data":[{"metadata":{"attributes.error.type":"BudgetExceededError"}}],"meta":{}}' ;;
  *v2/observations*cursor=p2*) echo '{"data":[{"metadata":{"attributes.error_class":"ShellError"}},{"metadata":{}}],"meta":{}}' ;;
  *v2/observations*) echo '{"data":[{"metadata":{"attributes.error_class":"ShellError"}}],"meta":{"cursor":"p2"}}' ;;
  *providedModelName*) echo '{"data":[
    {"providedModelName":"glm","level":"DEFAULT","count_count":"9","sum_totalCost":0.5,"sum_totalTokens":"100","p95_latency":200},
    {"providedModelName":"glm","level":"ERROR","count_count":"1","sum_totalCost":0,"sum_totalTokens":"0","p95_latency":900}]}' ;;
  *claude_code.tool.execution*) echo '{"data":[{"level":"DEFAULT","count_count":"97"},{"level":"ERROR","count_count":"3"}]}' ;;
  *) echo '{"data":[
    {"name":"Read","count_count":"5","p50_latency":1,"p95_latency":2,"sum_latency":1000},
    {"name":"Bash","count_count":"2","p50_latency":10,"p95_latency":20,"sum_latency":9000},
    {"name":"mcp__x__y","count_count":"1","p50_latency":3,"p95_latency":3,"sum_latency":3000},
    {"name":"claude_code.llm_request","count_count":"8","p50_latency":3,"p95_latency":3,"sum_latency":99000},
    {"name":"ExitPlanMode","count_count":"1","p50_latency":3,"p95_latency":3,"sum_latency":99000},
    {"name":"Plugin.load","count_count":"8","p50_latency":3,"p95_latency":3,"sum_latency":99000}]}' ;;
esac
STUB
  chmod +x "$LF_RBW" "$LF_CURL"
}

lf() { "$AU" langfuse --since 2026-01-01T00:00:00-08:00 --until 2026-01-02T00:00:00-08:00; }

@test "tools: only tool spans from Claude's environments, slowest in total first, no human waits" {
  assert_equal "$(lf | jq -c '[.tools[].tool]')" '["Bash","mcp__x__y","Read"]'
  grep -q 'claude-agentctl' "$CURL_LOG"
  assert_equal "$(lf | jq -c '.tools[0]')" '{"tool":"Bash","calls":2,"p50_ms":10,"p95_ms":20,"total_s":9}'
}

@test "tool errors: counts from metrics, classes across every page" {
  assert_equal "$(lf | jq -c '.tool_errors')" \
    '{"executions":100,"errors":3,"share":0.03,"by_class":{"ShellError":2,"unknown":1},"truncated":false}'
}

@test "gateway: one row per model, errors by class" {
  assert_equal "$(lf | jq -c '.gateway | [.calls, .errors, .error_share, .cost_usd, .tokens, .by_model.glm.p95_ms, .by_error]')" \
    '[10,1,0.1,0.5,100,200,{"BudgetExceededError":1}]'
}

@test "the window goes out in UTC, and the key only on stdin" {
  lf >/dev/null
  run grep -c 'fromStartTime=2026-01-01T08:00:00Z' "$CURL_LOG"
  assert_equal "$output" 3
  run grep -c 'pk:sk' "$CURL_LOG"
  assert_equal "$output" 0
  run grep -c 'user = "pk:sk"' "$CURL_STDIN"
  assert [ "$output" -gt 0 ]
}

@test "a refused key is exit 1, a reason and nothing on stdout" {
  printf '#!/bin/sh\ncat >/dev/null\necho "curl: (22) 401" >&2\nexit 22\n' > "$LF_CURL"
  run --separate-stderr lf
  assert_failure 1
  assert_equal "$output" ''
  [[ "$stderr" == *'curl exit 22'* ]]
}

@test "a missing rbw is a reason, not a traceback" {
  export LF_RBW=/nonexistent/rbw
  run --separate-stderr lf
  assert_failure 1
  [[ "$stderr" == 'langfuse: /nonexistent/rbw: FileNotFoundError' ]]
}

@test "no rbw entry and no URL each name what is missing" {
  printf '#!/bin/sh\nexit 1\n' > "$LF_RBW"
  run --separate-stderr lf
  assert_failure 1
  [[ "$stderr" == *'no key (rbw langfuse-api)'* ]]
  unset SO_LF_URL
  export AGENTCTL_CONF_DIR="$BATS_TEST_TMPDIR/none"
  run --separate-stderr lf
  assert_failure 1
  [[ "$stderr" == *'no URL'* ]]
}
