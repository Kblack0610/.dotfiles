#!/usr/bin/env bats
# stop-post.d/90-session-spend.sh - the per-session spend alert for hand-started sessions.
#
# The contract Ken chose (ask F8z7aT, 2026-11-05): it ALERTS and never STOPS. A Stop hook that
# exits 2 or prints blocks the turn, so every test asserts exit 0 and empty output.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  HOOK="$REPO_ROOT/.claude/hooks/stop-post.d/90-session-spend.sh"
  export CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_SESSION_ALERT_USD=60 CLAUDE_SESSION_ALERT_EVERY=0
  unset AGENT_QUEUE_ITEM TMUX_PANE
  NOTIFY_LOG="$SANDBOX/notify.log" COST="$SANDBOX/cost" CURL_LOG="$SANDBOX/curl.log"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$NOTIFY_LOG" > "$SANDBOX/bin/agent-notify"
  # Prometheus stub: answers with the dollars in $COST, or fails when the file is absent.
  cat > "$SANDBOX/bin/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$CURL_LOG"
[ -f "$COST" ] || exit 7
printf '{"status":"success","data":{"result":[{"metric":{},"value":[0,"%s"]}]}}' "\$(cat "$COST")"
STUB
  chmod +x "$SANDBOX/bin/agent-notify" "$SANDBOX/bin/curl"
}

stop() { printf '{"session_id":"%s","cwd":"/w/demo"}' "${1:-s1}" | bash "$HOOK"; }
spend() { echo "$1" > "$COST"; }
pings() { [ -f "$NOTIFY_LOG" ] && grep -c . "$NOTIFY_LOG" || echo 0; }

@test "below the threshold: silent, no ping" {
  spend 41.5
  run stop; assert_success; assert_output ''
  assert_equal "$(pings)" 0
}

@test "pings once at 1x, 2x, 4x and 8x, never twice for one level, and never blocks" {
  for usd in 61 70 125 130 250 300 480 490; do
    spend "$usd"; run stop; assert_success; assert_output ''
  done
  assert_equal "$(pings)" 4
  grep -q 'spent \$61 (alert at \$60, this is 1x). Nothing was stopped' "$NOTIFY_LOG"
  grep -q 'this is 2x' "$NOTIFY_LOG"; grep -q 'this is 4x' "$NOTIFY_LOG"; grep -q 'this is 8x' "$NOTIFY_LOG"
  grep -q 'session_id="s1"' "$CURL_LOG"
}

@test "a jump past several levels pings once, at the level reached" {
  spend 260; run stop; assert_success
  assert_equal "$(pings)" 1
  grep -q 'this is 4x' "$NOTIFY_LOG"
}

@test "each session has its own levels" {
  spend 65; stop s1; stop s2
  assert_equal "$(pings)" 2
  grep -q 'Session s2 has spent' "$NOTIFY_LOG"
}

@test "a queue session and a headless run are left alone: no read, no ping" {
  spend 500
  AGENT_QUEUE_ITEM=x run stop; assert_success; assert_output ''
  CLAUDE_CODE_SESSION_ATTENDED=0 run stop; assert_success; assert_output ''
  assert_equal "$(pings)" 0
  [ ! -f "$CURL_LOG" ]
}

@test "reads Prometheus at most once per CLAUDE_SESSION_ALERT_EVERY seconds for one session" {
  spend 10
  CLAUDE_SESSION_ALERT_EVERY=300 run stop
  CLAUDE_SESSION_ALERT_EVERY=300 run stop
  assert_equal "$(grep -c . "$CURL_LOG")" 1
}

@test "Prometheus down, a bad session id, or a broken agent-notify: exit 0 and silent" {
  run stop; assert_success; assert_output ''
  spend 100
  run bash "$HOOK" <<<'{"session_id":"../x","cwd":"/w"}'; assert_success; assert_output ''
  printf '#!/usr/bin/env bash\necho boom >&2; exit 3\n' > "$SANDBOX/bin/agent-notify"
  run stop s9; assert_success; assert_output ''
}
