#!/usr/bin/env bats
# session-preflight.sh + startup-telemetry.sh: every SessionStart appends one row with the start's
# timings, per hook and per phase, and the MCP servers' spawn offsets. `fleet-bench startup` and
# the claude-startup watch read it, so a row that goes missing is a watch that goes blind.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  [ -r /proc/self/stat ] || skip "needs /proc"

  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh"
  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  export CLAUDE_PROJECT_DIR="$REPO"

  DEPLOY="$SANDBOX/shared-hooks"
  mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/session-preflight.sh" "$REPO_ROOT/.config/shared-hooks/project-name.sh" \
     "$REPO_ROOT/.config/shared-hooks/startup-telemetry.sh" "$REPO_ROOT/.config/shared-hooks/stop-session-changes.py" "$DEPLOY/"
  export CLAUDE_STARTUP_LOG="$HOME/.agent/telemetry/claude-startup.jsonl"
  unset CLAUDE_PID CLAUDE_CODE_EXECPATH CLAUDE_CODE_ENTRYPOINT
}

teardown() { [ -z "${FAKE:-}" ] || { pkill -P "$FAKE" 2>/dev/null; kill "$FAKE" 2>/dev/null; } || true; }

start() { echo '{"source":"startup","session_id":"sid-1"}' | bash "$DEPLOY/session-preflight.sh"; }

@test "a start writes one row with the hook's total and its phases, and the preflight still answers" {
  run start
  assert_success
  assert_output --partial 'Session Preflight: repo'
  run jq -c '[.sid, .source, .project, (.hook_ms | type), .hooks[0].name, (.hooks[0].phases | keys)]' "$CLAUDE_STARTUP_LOG"
  assert_output '["sid-1","startup","repo","number","session-preflight",["board","facts","git","header","lessons","render","setup"]]'
  # No claude ancestor here, so the process times are unknown rather than made up.
  assert_equal "$(jq -c '[.process_ms, .ready_ms, .mcp]' "$CLAUDE_STARTUP_LOG")" '[null,null,[]]'
}

@test "the hook makes no network call and no queue write: no gh, no agent-queue claim, even for a queue item" {
  # gh was 430 ms of every start and the claim waited on the queue lock; reading the item stays.
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/calls.log"\nexit 1\n' "$SANDBOX" > "$SANDBOX/bin/gh"
  printf '#!/usr/bin/env bash\n[ "$1" = show ] || echo "agent-queue $*" >> "%s/calls.log"\nexit 1\n' "$SANDBOX" > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/agent-queue"
  AGENT_QUEUE_ITEM=some-item run start
  assert_success
  assert_output --partial 'Session Preflight: repo'
  [ ! -e "$SANDBOX/calls.log" ] || fail "the hook called: $(cat "$SANDBOX/calls.log")"
}

@test "under a claude process: process and ready ms, and each stdio MCP server's spawn offset or null" {
  # The fake claude spawns one child, as Claude Code spawns an MCP server. The child says when it
  # is up on one fifo and blocks on another, so nothing here waits on a timer.
  mkfifo "$SANDBOX/up" "$SANDBOX/hold"
  bash -c 'bash -c '\''echo up >"$1"; read -r _ <"$2"'\'' fake-mcp-server "$1" "$2" & wait' _ "$SANDBOX/up" "$SANDBOX/hold" &
  FAKE=$!
  read -r _ <"$SANDBOX/up"
  cat > "$REPO/.mcp.json" <<'EOF'
{"mcpServers": {"fake": {"command": "npx", "args": ["-y", "fake-mcp-server"]},
                "absent": {"command": "uvx", "args": ["not-running"]},
                "remote": {"type": "http", "url": "https://example.invalid/mcp"}}}
EOF
  CLAUDE_PID=$FAKE CLAUDE_CODE_EXECPATH=/opt/claude/versions/2.1.319 run start
  assert_success
  row=$(cat "$CLAUDE_STARTUP_LOG")
  assert_equal "$(jq -r .version <<<"$row")" 2.1.319
  # ready = process + hook, and the hook started after the fake claude did.
  assert_equal "$(jq '.ready_ms == .process_ms + .hook_ms and .process_ms >= 0' <<<"$row")" true
  assert_equal "$(jq -c '[.mcp[] | [.name, (.spawn_ms | type)]]' <<<"$row")" '[["fake","number"],["absent","null"]]'
  assert_equal "$(jq '.mcp[0].spawn_ms >= 0' <<<"$row")" true
}

@test "under Codex: the preflight answers and no row is written, even with CLAUDE_* inherited" {
  # Codex runs this hook too (codex/hooks.json); its rows had no ready time and blinded the watch.
  # A live CLAUDE_PID from the launcher must not pass a Codex start off as a Claude one.
  mkfifo "$SANDBOX/hold"
  bash -c 'read -r _ <"$1"' _ "$SANDBOX/hold" &
  FAKE=$!
  cp "$(command -v bash)" "$SANDBOX/bin/codex"
  export DEPLOY
  CLAUDE_PID=$FAKE CLAUDE_CODE_EXECPATH=/opt/claude/versions/2.1.319 \
    run "$SANDBOX/bin/codex" -c 'echo "{\"source\":\"startup\",\"session_id\":\"sid-1\"}" | bash "$DEPLOY/session-preflight.sh"'
  echo >"$SANDBOX/hold"
  assert_success
  assert_output --partial 'Session Preflight: repo'
  [ ! -e "$CLAUDE_STARTUP_LOG" ] || fail "row written under codex: $(cat "$CLAUDE_STARTUP_LOG")"
}

@test "a deploy without the telemetry lib keeps the preflight and writes no row" {
  rm "$DEPLOY/startup-telemetry.sh"
  run start
  assert_success
  assert_output --partial 'Session Preflight'
  [ ! -e "$CLAUDE_STARTUP_LOG" ]
}

@test "an unwritable log costs the row, never the preflight" {
  mkdir -p "$HOME/.agent"
  : > "$HOME/.agent/telemetry"   # a file where the directory should be
  run start
  assert_success
  assert_output --partial 'Session Preflight'
  # A log path that cannot be opened says nothing on the hook's stderr either.
  rm "$HOME/.agent/telemetry"; mkdir -p "$CLAUDE_STARTUP_LOG"
  run --separate-stderr start
  assert_success
  assert_equal "$stderr" ''
}

@test "SessionStart snapshots old dirt and preserves it across resume" {
  echo old > "$REPO/theme.conf"
  run start
  assert_success
  run python3 "$DEPLOY/stop-session-changes.py" changed "$REPO" sid-1
  assert_success
  assert_output ''
  echo new > "$REPO/theme.conf"
  echo '{"source":"resume","session_id":"sid-1"}' | bash "$DEPLOY/session-preflight.sh" >/dev/null
  run python3 "$DEPLOY/stop-session-changes.py" changed "$REPO" sid-1
  assert_success
  assert_output 'theme.conf'
}
