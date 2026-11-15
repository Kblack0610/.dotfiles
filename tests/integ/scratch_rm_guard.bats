#!/usr/bin/env bats
# scratch-rm-guard.py: an rm -r may not remove another live session's ~/.cache/<tool>/<id>/.
# The cache is a fixture under the test dir; the other session is a real process holding the
# fixture id in CLAUDE_CODE_SESSION_ID, started here and killed in teardown.

OTHER=0b7e5a00-0000-4000-8000-00000000aaaa
ME=0b7e5a00-0000-4000-8000-00000000bbbb
DEAD=0b7e5a00-0000-4000-8000-00000000dddd

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  GUARD="$BATS_TEST_DIRNAME/../../.claude/hooks/scratch-rm-guard.py"
  T="$BATS_TEST_TMPDIR"
  export XDG_CACHE_HOME="$T/cache"
  C="$XDG_CACHE_HOME"
  mkdir -p "$C/hub-spend-history/$OTHER/snap" "$C/mine/$ME" "$C/stale/$DEAD" "$C/plain/sub"
  touch "$C/hub-spend-history/top.json"
  # The fifo read returns once bash has exec'd with the id in its environ, so no wait is needed.
  mkfifo "$T/ready"
  CLAUDE_CODE_SESSION_ID=$OTHER bash -c 'echo up > "$1"; exec sleep 100000' _ "$T/ready" 3>&- &
  LIVE=$!
  read -r _ < "$T/ready"
}

teardown() { kill "$LIVE" 2>/dev/null || true; }

at() { jq -nc --arg c "$2" --arg d "$1" --arg s "$ME" '{tool_name:"Bash", session_id:$s, cwd:$d, tool_input:{command:$c}}' | python3 "$GUARD"; }

denied() { assert_success; assert_output --partial '"deny"'; assert_output --partial 'scratch-rm-guard:'; }
allowed() { assert_success; assert_output ''; }

@test "the 2026-11-10 command is denied, naming the live session and its pid" {
  run at /tmp "rm -rf $C/hub-spend-history"
  denied
  assert_output --partial "$OTHER"
  assert_output --partial "pid $LIVE"
}

@test "every way to reach the live session's dir is denied" {
  local c
  for c in "rm -rf $C/hub-spend-history/" "rm -r -f $C/hub-spend-history/$OTHER" "rm -fR $C/hub-spend-history/*" \
    "rm --recursive --force $C/hub-spend-history/$OTHER/snap" "rm -rf $C" "rm -rf $C/../cache" \
    "cd $C && rm -rf hub-spend-history" "bash -c 'rm -rf $C/hub-spend-history'" "eval rm -rf $C/hub-spend-history" \
    "true; sudo rm -rf -- $C/hub-*"; do
    run at /tmp "$c"
    denied
  done
}

@test "a path through a symlinked parent is the dir it reaches" {
  ln -s "$C/hub-spend-history" "$T/link"
  run at /tmp "rm -rf $T/link/$OTHER"
  denied
  run at /tmp "rm -rf $T/link"
  allowed
}

@test "the caller's own scratch, a dead session's dir and plain cache dirs pass" {
  local c
  for c in "rm -rf $C/mine" "rm -rf $C/mine/$ME" "rm -rf $C/stale" "rm -rf $C/stale/$DEAD" "rm -rf $C/plain" \
    "rm -rf $C/absent" "rm -rf $T/elsewhere"; do
    run at /tmp "$c"
    allowed
  done
}

@test "a non-recursive rm, quoted text and a heredoc body pass" {
  local c
  for c in "rm -f $C/hub-spend-history/top.json" "echo 'rm -rf $C/hub-spend-history'" "rmdir $C/plain/sub" \
    "$(printf 'cat <<EOF\nrm -rf %s\nEOF' "$C/hub-spend-history")"; do
    run at /tmp "$c"
    allowed
  done
}

@test "the session dies, the dir is free" {
  kill "$LIVE"
  wait "$LIVE" 2>/dev/null || true
  run at /tmp "rm -rf $C/hub-spend-history"
  allowed
}

@test "fail-open: bad input allows" {
  run bash -c "echo 'not json' | python3 '$GUARD'"
  allowed
  run bash -c "echo '{\"tool_name\":\"Read\"}' | python3 '$GUARD'"
  allowed
}
