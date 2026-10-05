#!/usr/bin/env bats
# 80-session-register.sh: the registry upsert.
#
# The upsert used to fork jq twice per registry line, 6.3 s per Stop on the largest
# real registry (1,407 lines). The rewrite is two jq passes over the whole file, and the risk
# in that is a parse error aborting the pass and truncating the registry on `mv`. So these
# pin what the per-line loop guaranteed: an unparseable line survives verbatim, only this
# session's old line and dead-transcript lines are dropped, and nothing else moves.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  HOOK="$REPO_ROOT/.claude/hooks/stop-post.d/80-session-register.sh"

  mkdir -p "$HOME/.config/shared-hooks"
  cp "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/"

  # No Prometheus in a test: telemetry is best-effort and absent here.
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/agent-usage"
  chmod +x "$SANDBOX/bin/agent-usage"

  PROJECT="$SANDBOX/alpha"
  mkdir -p "$PROJECT"
  export CLAUDE_PROJECT_DIR="$PROJECT"

  REG="$HOME/.agent/sessions/alpha/sessions.jsonl"
  mkdir -p "$(dirname "$REG")"

  # The meaningful-work gate needs one Edit in the transcript.
  TRANSCRIPT="$SANDBOX/self.jsonl"
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}' > "$TRANSCRIPT"
  LIVE="$SANDBOX/live.jsonl"
  : > "$LIVE"
}

run_hook() {
  jq -nc --arg t "$TRANSCRIPT" '{session_id:"self", transcript_path:$t}' | bash "$HOOK"
}

@test "drops this session's old line and dead transcripts, keeps the rest verbatim" {
  {
    jq -nc --arg t "$LIVE" '{session_id:"keep", transcript:$t, title:"kept"}'
    jq -nc '{session_id:"gone", transcript:"/nonexistent/x.jsonl"}'
    jq -nc --arg t "$TRANSCRIPT" '{session_id:"self", transcript:$t, title:"stale"}'
    echo '{"session_id":"nots", "title":"no transcript field"}'
  } > "$REG"
  run_hook
  run jq -r '.session_id' "$REG"
  assert_output "$(printf 'keep\nnots\nself')"
  run grep -c '"title":"stale"' "$REG"
  assert_output 0
}

@test "an unparseable line survives and does not truncate the registry" {
  {
    echo 'not json {'
    jq -nc --arg t "$LIVE" '{session_id:"after", transcript:$t}'
    echo '42'
  } > "$REG"
  run_hook
  run cat "$REG"
  assert_line --index 0 'not json {'
  assert_line --index 2 '42'
  assert_output --partial '"session_id":"after"'
  assert_output --partial '"session_id":"self"'
}

@test "the first Stop of a project creates the registry with one line" {
  run_hook
  run wc -l < "$REG"
  assert_output 1
}

@test "a read-only session is not registered" {
  : > "$TRANSCRIPT"
  run_hook
  [ ! -e "$REG" ]
}
