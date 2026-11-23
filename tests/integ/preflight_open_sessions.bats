#!/usr/bin/env bats
# session-preflight.sh: a new session sees how many other sessions are still open on its
# project, sibling worktrees included, read from the fleet state file, so it is not blind to a
# conversation the human is having in another window.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  gh_script 'exit 1'

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
  printf '%s\n' "$@" | jq -s --argjson e "$epoch" '{generated_epoch: $e, vocab: {buckets: ["NEEDS","STALLED","DONE","LANDED","CHAT","WORKING","PARKED"], finished: ["DONE","LANDED"], in_progress: ["WORKING","NEEDS","STALLED"]}, sessions: .}' > "$FLEET_STATE_FILE"
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

@test "open sessions in this checkout are one count line, the session itself left out" {
  state "$(date +%s)" \
    "$(row aaaaaaaa-1111 WORKING 0 'CI runners held queue')" \
    "$(row bbbbbbbb-2222 CHAT 84 'Pi low voltage sag question')" \
    "$(row me-0000-0000 WORKING 0 'this very session')"
  run context me-0000-0000
  assert_success
  assert_output --partial '2 other session(s) open on repo (2 in this checkout) - `fleet-sessions` lists them.'
  # The count, not the topics: `fleet-sessions` has the list.
  refute_output --partial 'CI runners'
  refute_output --partial 'Pi low voltage'
  refute_output --partial 'this very session'
}

@test "finished, parked, other-host sessions and other checkouts are left out" {
  state "$(date +%s)" \
    "$(row dddddddd-done DONE 0 'already done')" \
    "$(row llllllll-land LANDED 0 'already landed')" \
    "$(row pppppppp-park PARKED 0 'claude is gone')" \
    "$(row oooooooo-else WORKING 0 'elsewhere' /some/other/repo)" \
    "$(row hhhhhhhh-host WORKING 0 'on a worker' | jq -c '.host = "fleet-worker-1"')"
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  refute_output --partial 'other session(s) open'
}

@test "a sibling worktree of the same project counts by its project, other projects do not (ar-3879)" {
  state "$(date +%s)" \
    "$(row wwwwwwww-sib WORKING 2 'sibling' /elsewhere/repo-agent-7 | jq -c '.project = "repo"')" \
    "$(row xxxxxxxx-oth WORKING 2 'other' /elsewhere/other-agent-1 | jq -c '.project = "other"')"
  run context
  assert_success
  assert_output --partial '1 other session(s) open on repo - `fleet-sessions` lists them.'
  refute_output --partial 'in this checkout'
}

@test "a checkout row with no project still counts, beside a sibling worktree (ar-3879)" {
  state "$(date +%s)" \
    "$(row hhhhhhhh-here CHAT 2 'no project here')" \
    "$(row wwwwwwww-sib WORKING 2 'sibling' /elsewhere/repo-agent-7 | jq -c '.project = "repo"')"
  run context
  assert_success
  assert_output --partial '2 other session(s) open on repo (1 in this checkout) - `fleet-sessions` lists them.'
}

@test "an unscoped session counts only its own checkout (ar-3879)" {
  mkdir -p "$SANDBOX/scratch" && cd "$SANDBOX/scratch"
  export CLAUDE_PROJECT_DIR="$SANDBOX/scratch" PROJECT_MAP_FILE="$SANDBOX/none.json"
  state "$(date +%s)" \
    "$(row uuuuuuuu-oth CHAT 2 'unrelated' /elsewhere/scratch | jq -c '.project = "_unscoped"')"
  run context
  assert_success
  assert_output --partial 'Session Preflight: _unscoped'
  refute_output --partial 'other session(s) open'
}

@test "a session in a subdirectory counts" {
  mkdir -p "$REPO/sub"
  state "$(date +%s)" "$(row ssssssss-sub CHAT 3 "$(printf 'first line\nsecond line')" "$REPO/sub")"
  run context
  assert_success
  assert_output --partial '1 other session(s) open on repo (1 in this checkout)'
}

@test "with no session id there is no block, since the session could not leave itself out" {
  state "$(date +%s)" "$(row aaaaaaaa-1111 WORKING 0 'someone')"
  run bash -c 'bash "$1" </dev/null 2>/dev/null | jq -r .hookSpecificOutput.additionalContext' _ "$DEPLOY/session-preflight.sh"
  assert_success
  assert_output --partial 'Session Preflight'
  refute_output --partial 'other session(s) open'
}

@test "a stale state file shows nothing rather than closed sessions" {
  state "$(( $(date +%s) - 3600 ))" "$(row aaaaaaaa-1111 WORKING 0 'long gone')"
  run context
  assert_success
  refute_output --partial 'other session(s) open'
}

@test "no state file, no block, and the preflight still renders" {
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  refute_output --partial 'other session(s) open'
}
