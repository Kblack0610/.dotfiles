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

  # This machine is "here"; store-sync shares the registry with every other host.
  export FLEET_HOSTS_LIB="$REPO_ROOT/.local/lib/fleet-hosts.sh" FLEET_HOST=here

  PROJECT="$SANDBOX/alpha"
  mkdir -p "$PROJECT"
  export CLAUDE_PROJECT_DIR="$PROJECT"

  REG="$HOME/.agent/sessions/alpha/sessions.jsonl"
  mkdir -p "$(dirname "$REG")"

  # One Edit call, so the default row carries edits 1.
  TRANSCRIPT="$SANDBOX/self.jsonl"
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}' > "$TRANSCRIPT"
  LIVE="$SANDBOX/live.jsonl"
  : > "$LIVE"
}

run_hook() {
  jq -nc --arg t "$TRANSCRIPT" '{session_id:"self", transcript_path:$t}' | bash "$HOOK"
}

@test "drops this session's old line and this host's dead transcripts, keeps the rest verbatim" {
  {
    jq -nc --arg t "$LIVE" '{session_id:"keep", transcript:$t, title:"kept", host:"here"}'
    jq -nc '{session_id:"gone", transcript:"/nonexistent/x.jsonl", host:"here"}'
    jq -nc --arg t "$TRANSCRIPT" '{session_id:"self", transcript:$t, title:"stale"}'
    echo '{"session_id":"nots", "title":"no transcript field"}'
  } > "$REG"
  run_hook
  run jq -r '.session_id' "$REG"
  assert_output "$(printf 'keep\nnots\nself')"
  run grep -c '"title":"stale"' "$REG"
  assert_output 0
}

@test "another host's rows and rows with no host survive though their transcript is not here" {
  {
    jq -nc '{session_id:"razer", transcript:"/nonexistent/r.jsonl", host:"razer"}'
    jq -nc '{session_id:"legacy", transcript:"/nonexistent/l.jsonl"}'
    jq -nc '{session_id:"mine", transcript:"/nonexistent/m.jsonl", host:"here"}'
  } > "$REG"
  run_hook
  run jq -r '.session_id' "$REG"
  assert_output "$(printf 'razer\nlegacy\nself')"
}

@test "a host the roster lib cannot name prunes nothing and stamps no host" {
  jq -nc '{session_id:"mine", transcript:"/nonexistent/m.jsonl", host:"here"}' > "$REG"
  FLEET_HOSTS_LIB=/nonexistent FLEET_HOST= HOSTNAME= run_hook
  run jq -c '[.session_id, has("host")]' "$REG"
  assert_output "$(printf '["mine",true]\n["self",false]')"
}

@test "a Stop stamps this machine's host on its row" {
  run_hook
  run jq -r .host "$REG"
  assert_output here
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

@test "a filter pass that fails leaves the registry as it was, not this one row (ar-2779)" {
  # NEGATIVE CONTROL: before ar-2779 the failed pass's exit was ignored and the swap left only this row.
  jq -nc --arg t "$LIVE" '{session_id:"keep", transcript:$t}' > "$REG"
  before=$(cat "$REG")
  real=$(command -v jq)
  printf '#!/bin/sh\ncase " $* " in *" --arg dead "*) exit 5 ;; esac\nexec %s "$@"\n' "$real" > "$SANDBOX/bin/jq"
  chmod +x "$SANDBOX/bin/jq"
  run_hook
  assert_equal "$(cat "$REG")" "$before"
  assert_equal "$(find "$(dirname "$REG")" -name '.sessions.jsonl.*' | wc -l)" 0
}

@test "the rewrite is made next to the registry and renamed over it, so an unwritable TMPDIR still registers (ar-2779)" {
  # NEGATIVE CONTROL: a /tmp copy crossed filesystems, so mv copied it over the registry and a crash mid-copy emptied it.
  jq -nc --arg t "$LIVE" '{session_id:"keep", transcript:$t}' > "$REG"
  TMPDIR="$SANDBOX/no-such-dir" run_hook
  run jq -r .session_id "$REG"
  assert_output $'keep\nself'
  assert_equal "$(find "$(dirname "$REG")" -name '.sessions.jsonl.*' | wc -l)" 0
}

@test "a Stop after its worktree is reaped stays under the project an earlier Stop recorded" {
  jq -nc --arg t "$TRANSCRIPT" '{session_id:"self", transcript:$t, project:"alpha"}' > "$REG"
  CLAUDE_PROJECT_DIR="$SANDBOX/alpha-wt-reaped" run_hook
  run jq -r '.session_id' "$REG"
  assert_output self
  [ ! -e "$HOME/.agent/sessions/alpha-wt-reaped" ]
}

@test "the first Stop of a project creates the registry with one line" {
  run_hook
  run wc -l < "$REG"
  assert_output 1
}

@test "a read-only session is registered with no edits (ar-143)" {
  : > "$TRANSCRIPT"
  AGENTCTL_NAME= run_hook
  run jq -c '[.session_id, .edits]' "$REG"
  assert_output '["self",0]'
}

@test "edits counts the edit tool calls, not the schema and result lines that name them (ar-143)" {
  cat > "$TRANSCRIPT" <<'JSONL'
{"type":"api-request-shape","tools":[{"name":"Edit"},{"name":"Write"},{"name":"MultiEdit"},{"name":"NotebookEdit"}]}
{"type":"attachment","attachment":{"type":"prompt_snapshot","tools":[{"name":"Edit"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","name":"Edit"},{"type":"tool_use","name":"Write"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo '\"name\":\"Edit\"'"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"{\"type\":\"tool_use\",\"name\":\"Edit\"}"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"NotebookEdit"}]}}
not json "name":"Edit"
JSONL
  AGENTCTL_NAME= run_hook
  run jq -c '.edits' "$REG"
  assert_output 3
}

@test "a read-only agentctl runner is registered, with its runner name" {
  : > "$TRANSCRIPT"
  AGENTCTL_NAME=shepherd run_hook
  run jq -c '[.session_id, .edits, .agentctl]' "$REG"
  assert_output '["self",0,"shepherd"]'
}

@test "a runner's second Stop replaces its row and keeps the runner name" {
  AGENTCTL_NAME=shepherd run_hook
  AGENTCTL_NAME=shepherd run_hook
  run jq -sc 'map([.session_id, .agentctl])' "$REG"
  assert_output '[["self","shepherd"]]'
}

@test "a session by hand carries no runner name" {
  AGENTCTL_NAME= run_hook
  run jq -c 'has("agentctl")' "$REG"
  assert_output false
}

@test "first_prompt comes from the running account's history, not ~/.claude's" {
  mkdir -p "$HOME/.claude" "$SANDBOX/acct"
  echo '{"sessionId":"self","display":"from the default account"}' > "$HOME/.claude/history.jsonl"
  printf '%s\n' '{"sessionId":"self","display":"/one-shot"}' '{"sessionId":"self","display":"from the bnb account"}' > "$SANDBOX/acct/history.jsonl"
  CLAUDE_CONFIG_DIR="$SANDBOX/acct" run_hook
  run jq -r .first_prompt "$REG"
  assert_output "from the bnb account"
}

@test "a Stop records the harness its launcher set: AGENT_HARNESS for a claude-lazer session, claude on an account" {
  AGENT_HARNESS=lazer-reserve run_hook
  assert_equal "$(jq -r .harness "$REG")" lazer-reserve
  # negative control: no AGENT_HARNESS is an account session, and the row still says so
  env -u AGENT_HARNESS bash -c "$(declare -f run_hook); TRANSCRIPT='$TRANSCRIPT' HOOK='$HOOK' run_hook"
  assert_equal "$(jq -r .harness "$REG")" claude
  [ "$(jq -c 'has("base_url")' "$REG")" = false ]
}
