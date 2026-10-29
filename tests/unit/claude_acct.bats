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
