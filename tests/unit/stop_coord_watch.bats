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

# A live process running a script named $1 (default coord-watch) with arguments [$2] <fifo>, held
# open on a fifo nobody writes; its pid goes in the mark. It says it is up first, so the check never
# reads the forked shell before it becomes the script.
live_watch() {
  local name="${1:-coord-watch}" d="$SANDBOX/holder"
  mkdir -p "$d"; mkfifo "$d/f" "$d/up"
  printf '#!/bin/bash\necho up > "%s"\nexec 3<>"${@: -1}"; read -r -u 3\n' "$d/up" > "$d/$name"
  bash "$d/$name" ${2:+"$2"} "$d/f" 3>&- &
  HOLDER=$!
  read -r _ < "$d/up"
  printf '%s /plans/p.md\n' "$HOLDER" > "$COORD_WATCH_STATE/session-sid-1.pid"
}

@test "a coordinator with no watch armed is blocked with the step to arm it" {
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  [ "$(jq -r .decision <<<"$output")" = block ]
  [[ "$(jq -r .reason <<<"$output")" == "coord-watch: "*"ledger"*"step 2"*'`coord-watch --until <that plan>`'*"run_in_background, never Monitor"* ]]
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
  [[ "$(jq -r .reason <<<"$output")" == *'`coord-watch --until /plans/p.md`'* ]]
  live_watch other
  run bash "$CHECK" <<<"$(stop_payload)"
  [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "a coordinator whose plan has every ledger line ticked is told step 6, not to re-arm, with the watch's mark gone" {
  printf '# p\n## Follow-through\n- [x] ar-1 live\n' > "$SANDBOX/p.md"
  printf '%s\n' "$SANDBOX/p.md" > "$COORD_WATCH_STATE/session-sid-1.plan"
  PATH="$REPO_ROOT/.local/bin:$PATH" run bash "$CHECK" <<<"$(stop_payload)"
  [ "$(jq -r .decision <<<"$output")" = block ]
  [[ "$(jq -r .reason <<<"$output")" == *"nothing to watch"*"step 6"*"-coordinator"*"reopen-on-answer"*"do not re-arm"* ]]
}

@test "negative control: an open line, a plan with no ledger, or no coord-watch on PATH is a missing watch, not a ticked ledger" {
  printf '# p\n## Follow-through\n- [ ] ar-1 open\n' > "$SANDBOX/p.md"
  printf '%s\n' "$SANDBOX/p.md" > "$COORD_WATCH_STATE/session-sid-1.plan"
  PATH="$REPO_ROOT/.local/bin:$PATH" run bash "$CHECK" <<<"$(stop_payload)"
  [[ "$(jq -r .reason <<<"$output")" == *'Run `coord-watch --until'* ]]
  printf '# p\n' > "$SANDBOX/p.md"
  PATH="$REPO_ROOT/.local/bin:$PATH" run bash "$CHECK" <<<"$(stop_payload)"
  [[ "$(jq -r .reason <<<"$output")" == *'Run `coord-watch --until'* ]]
  printf '# p\n## Follow-through\n- [x] ar-1 live\n' > "$SANDBOX/p.md"
  PATH="/usr/bin:/bin" run bash "$CHECK" <<<"$(stop_payload)"
  [[ "$(jq -r .reason <<<"$output")" == *'Run `coord-watch --until'* ]]
}

@test "a live coord-watch --until (the background wait) counts as armed" {
  live_watch coord-watch --until
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
}

@test "a live coord-watch in a one-shot mode (ids, filter) is not a watch" {
  live_watch coord-watch filter
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
