#!/usr/bin/env bats
# stop-post.d/89-coord-watch.sh: a session labelled `coordinator` cannot end a turn with no live
# coord-watch of its own. 2026-11-19 a release coordinator ran ten hours with no watch through two
# compactions, and three land-failed events on its critical PR reached nobody.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CHECK="$REPO_ROOT/.claude/hooks/stop-post.d/89-coord-watch.sh"
  export CLAUDE_CODE_SESSION_ATTENDED=1 FLEET_SHEPHERD_DIR="$SANDBOX/shep" COORD_WATCH_STATE="$SANDBOX/cw"
  mkdir -p "$FLEET_SHEPHERD_DIR/labels" "$COORD_WATCH_STATE"
  printf 'manual\ncoordinator\n' > "$FLEET_SHEPHERD_DIR/labels/sid-1"
  HOLDER=""
}

teardown() { [ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null || true; }

stop_payload() { printf '{"session_id":"%s","stop_hook_active":%s}' "${1:-sid-1}" "${2:-false}"; }

# A live process whose command line names coord-watch, held open on a fifo nobody writes.
live_watch() {
  mkdir -p "$SANDBOX/holder"; mkfifo "$SANDBOX/holder/f"
  printf '#!/bin/bash\nexec 3<>"$1"; read -r -u 3\n' > "$SANDBOX/holder/coord-watch"
  bash "$SANDBOX/holder/coord-watch" "$SANDBOX/holder/f" &
  HOLDER=$!
  printf '%s /plans/p.md\n' "$HOLDER" > "$COORD_WATCH_STATE/session-sid-1.pid"
}

@test "a coordinator with no watch armed is blocked with the step to arm it" {
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  [ "$(jq -r .decision <<<"$output")" = block ]
  [[ "$(jq -r .reason <<<"$output")" == "coord-watch: "*'`coord-watch <plan file>`'*"timeout_ms 1800000"* ]]
}

@test "a coordinator whose recorded watch is live passes" {
  live_watch
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
}

@test "a stale mark (dead pid, or a recycled pid that is not coord-watch) blocks and names the plan it recorded" {
  printf '999999999 /plans/p.md\n' > "$COORD_WATCH_STATE/session-sid-1.pid"
  run bash "$CHECK" <<<"$(stop_payload)"
  [ "$(jq -r .decision <<<"$output")" = block ]
  [[ "$(jq -r .reason <<<"$output")" == *'`coord-watch /plans/p.md`'* ]]
  printf '%s /plans/p.md\n' "$$" > "$COORD_WATCH_STATE/session-sid-1.pid"
  run bash "$CHECK" <<<"$(stop_payload)"
  [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "another session's live watch does not count for this one" {
  live_watch
  mv "$COORD_WATCH_STATE/session-sid-1.pid" "$COORD_WATCH_STATE/session-sid-2.pid"
  run bash "$CHECK" <<<"$(stop_payload)"
  [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "negative control: no coordinator label, a manual-only keep, the loop guard and headless runs all pass" {
  run bash "$CHECK" <<<"$(stop_payload sid-none)"
  assert_output ''
  printf 'manual\n' > "$FLEET_SHEPHERD_DIR/labels/sid-1"
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_output ''
  printf 'coordinator\n' > "$FLEET_SHEPHERD_DIR/labels/sid-1"
  run bash "$CHECK" <<<"$(stop_payload sid-1 true)"
  assert_output ''
  run env CLAUDE_CODE_SESSION_ATTENDED=0 bash "$CHECK" <<<"$(stop_payload)"
  assert_output ''
}
