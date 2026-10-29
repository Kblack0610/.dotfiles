#!/usr/bin/env bats
# claude-acct pick: `cl` starts each session on the account with the most room left.
# A wrong pick is silent - the session just runs on the fuller account and hits the
# limit sooner - so each scoring rule gets a case. No network: usage is seeded as
# fresh cache files and curl is stubbed to fail.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  ACCT="$REPO_ROOT/.local/bin/claude-acct"
  ALT="$HOME/.claude-alt"
  mkdir -p "$HOME/.claude" "$ALT" "$XDG_CACHE_HOME/claude-acct"
  export CLAUDE_ACCT_CONFIG="$SANDBOX/accounts"
  printf 'main -\nalt %s\n' "$ALT" > "$CLAUDE_ACCT_CONFIG"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin/curl"
  printf '#!/usr/bin/env bash\necho "2.1.0 (Claude Code)"\n' > "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/claude"
}

# usage <account> <5h%> <7d%> -- a fresh cached answer from the usage endpoint
usage() {
  printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s}}\n' "$2" "$3" \
    > "$XDG_CACHE_HOME/claude-acct/$1.json"
}

# creds <dir> <expiresAt-ms>
creds() {
  printf '{"claudeAiOauth":{"accessToken":"tok","expiresAt":%s}}\n' "$2" > "$1/.credentials.json"
}

@test "the account with the lower of its two windows' max wins" {
  usage main 10 80   # weekly nearly spent
  usage alt 50 50
  run "$ACCT" pick
  assert_success
  assert_line "$ALT"
  assert_output --partial 'claude-acct: alt (5h 50%, 7d 50%)'
}

@test "the default account wins and prints an empty dir" {
  usage main 20 30
  usage alt 60 10
  run --separate-stderr "$ACCT" pick
  assert_success
  assert_output ''
  [[ "$stderr" == *'claude-acct: main'* ]]
}

@test "a tie goes to the first account in the file" {
  usage main 40 40
  usage alt 40 40
  run --separate-stderr "$ACCT" pick
  assert_output ''
}

@test "an expired token scores 0 so launching it refreshes it" {
  usage main 40 70
  creds "$ALT" 1000
  run "$ACCT" pick
  assert_line "$ALT"
  assert_output --partial 'token expired'
}

@test "an account that never logged in is skipped, not picked" {
  usage main 90 90
  run --separate-stderr "$ACCT" pick
  assert_output ''
}

@test "no usage data at all falls back to the default account" {
  creds "$HOME/.claude" 99999999999999
  creds "$ALT" 99999999999999
  run --separate-stderr "$ACCT" pick
  assert_success
  assert_output ''
  [[ "$stderr" == *'no usage data'* ]]
}

@test "link shares the main setup and parks what was already there" {
  mkdir -p "$HOME/.claude/skills" "$HOME/.claude/projects" "$ALT/projects/old"
  echo '{}' > "$HOME/.claude/settings.json"
  run "$ACCT" link
  assert_success
  [[ "$(readlink "$ALT/skills")" == "$HOME/.claude/skills" ]]
  [[ "$(readlink "$ALT/settings.json")" == "$HOME/.claude/settings.json" ]]
  [[ "$(readlink "$ALT/projects")" == "$HOME/.claude/projects" ]]
  [[ -d "$ALT/.pre-share-$(date +%F)/projects/old" ]]
  # entries missing from main are not linked, and a second run is a no-op
  [[ ! -e "$ALT/agents" ]]
  run "$ACCT" link
  assert_output ''
}

@test "link merges an account's live sessions into the shared registry" {
  mkdir -p "$HOME/.claude/sessions" "$ALT/sessions"
  echo main > "$HOME/.claude/sessions/100.json"
  echo alt > "$ALT/sessions/200.json"
  echo key > "$ALT/sessions/200.abc.key"
  echo clash > "$ALT/sessions/100.json"
  run "$ACCT" link
  assert_success
  [[ "$(readlink "$ALT/sessions")" == "$HOME/.claude/sessions" ]]
  [[ "$(cat "$HOME/.claude/sessions/200.json")" == alt ]]
  [[ -f "$HOME/.claude/sessions/200.abc.key" ]]
  # a clash keeps main's file and parks the account's copy, never overwrites
  [[ "$(cat "$HOME/.claude/sessions/100.json")" == main ]]
  [[ "$(cat "$ALT/.pre-share-$(date +%F)/sessions/100.json")" == clash ]]
}

# --- move: the decisions, sourced. The flow itself is tests/integ/claude_acct_move.bats. ---

src() { CLAUDE_ACCT_PROC="$SANDBOX/proc" source "$ACCT"; }

@test "move refuses a busy session, a dialog and an unknown status" {
  src
  run refusal busy "" "$ALT" 10 alt "5h 1%"
  assert_success; assert_output --partial 'busy mid-turn'
  run refusal waiting "" "$ALT" 10 alt "5h 1%"
  assert_success; assert_output --partial 'permission or question dialog'
  run refusal compacting "" "$ALT" 10 alt "5h 1%"
  assert_success; assert_output --partial "unknown session status 'compacting'"
}

@test "move refuses when no account has room, or nothing is known about room" {
  src
  run refusal idle "" "$ALT" 100 alt "5h 2%, 7d 100%"
  assert_success; assert_output 'no account has room (the best is alt: 5h 2%, 7d 100%)'
  run refusal idle "" "$ALT" 99.5 alt "x"
  assert_failure
  run refusal shell "" "" "" "" ""
  assert_success; assert_output --partial 'no usage data'
}

@test "move refuses a session already on the account with the most room" {
  src
  run refusal shell "$ALT" "$ALT" 10 alt "5h 1%"
  assert_success; assert_output --partial 'already on alt'
  run refusal idle "" "" 10 main "5h 1%"
  assert_success; assert_output --partial 'already on main'
  run refusal shell "" "$ALT" 10 alt "5h 1%"
  assert_failure; assert_output ''
}

@test "the background-shell dialog is answered by its own option number" {
  src
  run dialog_choice $'  Background tasks are running\n  1. Exit and stop tasks\n  2. Move to background and exit\n  3. Stay'
  assert_output 2
  run dialog_choice $' > 1. Stay\n   2. Exit and stop tasks\n   3. Move to background and exit'
  assert_output 3
  run dialog_choice $'❯ /exit\n  bypass permissions on'
  assert_output ''
}

@test "a resumed claude keeps the model and permission flags and drops the brief" {
  src
  mkdir -p "$SANDBOX/proc/42"
  printf 'claude\0--model\0opus\0--permission-mode\0bypassPermissions\0/one-shot do --model it\0' > "$SANDBOX/proc/42/cmdline"
  run carry_flags 42
  assert_output '--model opus --permission-mode bypassPermissions '
  printf 'claude\0--dangerously-skip-permissions\0--model=sonnet\0' > "$SANDBOX/proc/42/cmdline"
  run carry_flags 42
  assert_output '--dangerously-skip-permissions --model sonnet '
  printf 'claude\0' > "$SANDBOX/proc/42/cmdline"
  run carry_flags 42
  assert_output ''
}

@test "a process's parent and account come from its own proc entry" {
  src
  mkdir -p "$SANDBOX/proc/7"
  echo '7 (my (odd) name) S 3 7 7 0 -1' > "$SANDBOX/proc/7/stat"
  run ppid_of 7
  assert_output 3
  printf 'A=1\0CLAUDE_CONFIG_DIR=%s/\0' "$ALT" > "$SANDBOX/proc/7/environ"
  run config_dir_of 7
  assert_output "$ALT"
  printf 'CLAUDE_CONFIG_DIR=%s\0' "$HOME/.claude" > "$SANDBOX/proc/7/environ"
  run config_dir_of 7
  assert_output ''
  printf 'A=1\0' > "$SANDBOX/proc/7/environ"
  run config_dir_of 7
  assert_output ''
}

@test "a claude counts as the pane's when it runs anywhere under the pane's process" {
  src
  for p in "5 1" "6 5" "7 6"; do set -- $p; mkdir -p "$SANDBOX/proc/$1"; echo "$1 (x) S $2 0" > "$SANDBOX/proc/$1/stat"; done
  run descends 7 5; assert_success
  run descends 5 5; assert_success
  run descends 5 7; assert_failure
  run descends 7 9; assert_failure
}
