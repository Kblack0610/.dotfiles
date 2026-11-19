#!/usr/bin/env bats
# session-preflight.sh: a new session sees the other sessions still open in its checkout,
# read from the fleet state file, so it is not blind to a conversation the human is
# having in another window.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh"

  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo hello > "$REPO/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "first commit"
  REPO="$(realpath "$REPO")"
  export CLAUDE_PROJECT_DIR="$REPO"

  DEPLOY="$SANDBOX/shared-hooks"
  mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/session-preflight.sh" \
     "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$DEPLOY/"

  export FLEET_STATE_FILE="$SANDBOX/state.json"
}

# state <epoch> <session json>...: write a fleet state file generated at <epoch>.
state() {
  local epoch="$1"; shift
  printf '%s\n' "$@" | jq -s --argjson e "$epoch" '{generated_epoch: $e, sessions: .}' > "$FLEET_STATE_FILE"
}

# row <sid> <bucket> <idle_min> <topic> [cwd]
row() {
  jq -nc --arg s "$1" --arg b "$2" --argjson i "$3" --arg t "$4" --arg c "${5:-$REPO}" \
    '{session_id: $s, bucket: $b, idle_min: $i, topic: $t, cwd: $c}'
}

context() {
  printf '{"source":"startup","session_id":"%s"}' "${1:-me-0000-0000}" \
    | bash "$DEPLOY/session-preflight.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

@test "open sessions in this checkout are listed, the session itself left out" {
  state "$(date +%s)" \
    "$(row aaaaaaaa-1111 WORKING 0 'CI runners held queue')" \
    "$(row me-0000-0000 WORKING 0 'this very session')"
  run context me-0000-0000
  assert_success
  assert_output --partial 'Open sessions in this checkout (1)'
  assert_output --partial 'aaaaaaaa WORKING idle 0m: CI runners held queue'
  refute_output --partial 'this very session'
}

@test "a conversation with the human ranks above busy work, and the cap says what it dropped" {
  local rows=() i
  for i in 1 2 3 4 5 6 7 8 9; do rows+=("$(row "w000000$i-x" WORKING 0 "busy $i")"); done
  state "$(date +%s)" "${rows[@]}" "$(row cccccccc-chat CHAT 84 'Pi low voltage sag question')"
  run context
  assert_success
  assert_line --index 0 --partial 'Session Preflight'
  assert_output --partial 'cccccccc CHAT idle 84m: Pi low voltage sag question'
  assert_output --partial '+2 more - `fleet-sessions` for the rest'
  # CHAT is the first row under the heading.
  run bash -c "printf '%s\n' \"\$1\" | grep -A1 '^Open sessions' | tail -1" _ "$output"
  assert_output --partial 'cccccccc CHAT'
}

@test "finished sessions and other checkouts are left out" {
  state "$(date +%s)" \
    "$(row dddddddd-done DONE 0 'already done')" \
    "$(row llllllll-land LANDED 0 'already landed')" \
    "$(row oooooooo-else WORKING 0 'elsewhere' /some/other/repo)"
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  refute_output --partial 'Open sessions'
}

@test "a stale state file shows nothing rather than closed sessions" {
  state "$(( $(date +%s) - 3600 ))" "$(row aaaaaaaa-1111 WORKING 0 'long gone')"
  run context
  assert_success
  refute_output --partial 'Open sessions'
}

@test "no state file, no block, and the preflight still renders" {
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  refute_output --partial 'Open sessions'
}
