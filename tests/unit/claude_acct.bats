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

@test "a null five_hour window still scores on the weekly one" {
  printf '{"five_hour":null,"seven_day":{"utilization":65.0}}\n' > "$XDG_CACHE_HOME/claude-acct/main.json"
  printf '{"five_hour":null,"seven_day":{"utilization":32.0}}\n' > "$XDG_CACHE_HOME/claude-acct/alt.json"
  run "$ACCT" pick
  assert_success
  assert_line "$ALT"
  assert_output --partial 'claude-acct: alt (5h -, 7d 32%)'
}

@test "a fresh answer with a null five_hour is accepted, not read as a failed fetch" {
  creds "$HOME/.claude" 99999999999999
  printf '#!/usr/bin/env bash\nprintf %%s %s\n' "'{\"five_hour\":null,\"seven_day\":{\"utilization\":65.0,\"resets_at\":\"2026-11-06T03:00:00+00:00\"}}'" > "$SANDBOX/bin/curl"
  run "$ACCT" status
  assert_success
  assert_line --regexp '^main +- +65%'
  refute_line --regexp '^main .*fetch failed'
}

@test "a response with no usage window at all is still a failed fetch" {
  creds "$HOME/.claude" 99999999999999
  printf '#!/usr/bin/env bash\nprintf %%s %s\n' "'{\"five_hour\":null,\"seven_day\":null}'" > "$SANDBOX/bin/curl"
  run "$ACCT" status
  assert_line --regexp '^main .*fetch failed'
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
  run refusal idle "" "" "" "" ""
  assert_success; assert_output --partial 'no usage data'
}

@test "move refuses a session with background shells unless told to stop them" {
  src
  run refusal shell "" "$ALT" 10 alt "5h 1%" 0
  assert_success; assert_output --partial 'pass --stop-shells'
  run refusal shell "" "$ALT" 10 alt "5h 1%"
  assert_success; assert_output --partial 'background shells are running'
  run refusal shell "" "$ALT" 10 alt "5h 1%" 1
  assert_failure; assert_output ''
}

@test "move refuses a session already on the account with the most room" {
  src
  run refusal shell "$ALT" "$ALT" 10 alt "5h 1%" 1
  assert_success; assert_output --partial 'already on alt'
  run refusal idle "" "" 10 main "5h 1%"
  assert_success; assert_output --partial 'already on main'
  run refusal idle "" "$ALT" 10 alt "5h 1%"
  assert_failure; assert_output ''
}

@test "the background-shell dialog is answered by its own option number" {
  src
  # the dialog as Claude Code 2.1.312 draws it
  run dialog_choice $'  Background work is running\n  ❯ 1. Exit and stop tasks\n    2. Move to background and exit\n    3. Stay'
  assert_output 1
  run dialog_choice $' > 1. Stay\n   2. Move to background and exit\n   3. Exit and stop tasks'
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

@test "background shells are the claude's children that source a shell snapshot" {
  src
  mkdir -p "$SANDBOX/proc/"{50,51,52,53}
  echo '50 (claude) S 1 0' > "$SANDBOX/proc/50/stat"
  echo '51 (zsh) S 50 0' > "$SANDBOX/proc/51/stat"
  printf '/bin/zsh\0-c\0source /x/shell-snapshots/s.sh && eval '"'"'scripts/test/suite.sh --retry'"'"'\0' > "$SANDBOX/proc/51/cmdline"
  echo '52 (npm exec) S 50 0' > "$SANDBOX/proc/52/stat"
  printf 'npm\0exec\0@playwright/mcp\0' > "$SANDBOX/proc/52/cmdline"
  echo '53 (zsh) S 9 0' > "$SANDBOX/proc/53/stat"
  printf '/bin/zsh\0-c\0source /x/shell-snapshots/s.sh\0' > "$SANDBOX/proc/53/cmdline"
  run bg_shells 50
  assert_output "51  scripts/test/suite.sh --retry' "
}

# week <account> <used%> <hours-until-reset> -- a fresh answer with a weekly window, now at NOW
NOW=1800000000
week() {
  local resets
  resets=$(date -u -d "@$((NOW + $3 * 3600))" +%Y-%m-%dT%H:%M:%S.123456+00:00)
  printf '{"five_hour":null,"seven_day":{"utilization":%s,"resets_at":"%s"}}\n' "$2" "$resets" \
    > "$XDG_CACHE_HOME/claude-acct/$1.json"
}
field() { jq -r --arg a "$1" ".[] | select(.name == \$a) | $2"; }

@test "status --json: half the week gone, used under it, is under pace and lasts to the reset" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  week alt 80 84
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field main .week_gone <<<"$output")" = 50 ]
  [ "$(field main .over_pace <<<"$output")" = false ]
  [ "$(field main .run_out <<<"$output")" = null ]
  [ "$(field alt .over_pace <<<"$output")" = true ]
  # 84h gone for 80%, so 100% lands 21h from now
  [ "$(field alt .run_out <<<"$output")" = "$((NOW + 21 * 3600))" ]
}

@test "status --json: the first hour of a week, and an account past its limit" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 0 167
  week alt 104 10
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field main .over_pace <<<"$output")" = false ]
  [ "$(field main .run_out <<<"$output")" = null ]
  [ "$(field alt .over_pace <<<"$output")" = true ]
  [ "$(field alt '.run_out < '$NOW <<<"$output")" = true ]
}

@test "status --json: an expired token and a failed read say so instead of a number" {
  creds "$ALT" 1000
  creds "$HOME/.claude" 99999999999999
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field main .state <<<"$output")" = unread ]
  [ "$(field main .week_used <<<"$output")" = null ]
  [ "$(field alt .state <<<"$output")" = expired ]
}

@test "status: a table row per account, with email and 24h dollars from Prometheus" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  week alt 80 84
  echo '{"oauthAccount":{"emailAddress":"m@x"}}' > "$HOME/.claude.json"
  echo '{"oauthAccount":{"emailAddress":"a@x"}}' > "$ALT/.claude.json"
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"data\":{\"result\":[{\"metric\":{\"user_email\":\"m@x\"},\"value\":[0,\"600.4\"]}]}}'" > "$SANDBOX/bin/curl"
  export CC_PROM_URL=http://prom.test
  run "$ACCT" status
  assert_success
  assert_line --regexp '^main +- +30% +50% +under .*\$600 +m@x$'
  assert_line --regexp '^alt +- +80% +50% +over .*\$0 +a@x$'
}

@test "status: Prometheus down leaves the percents and blanks only the dollars" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  echo '{"oauthAccount":{"emailAddress":"m@x"}}' > "$HOME/.claude.json"
  export CC_PROM_URL=http://prom.test   # the curl stub fails
  run "$ACCT" status
  assert_success
  assert_line --regexp '^main +- +30% +50% +under .* - +m@x$'
}

@test "live sessions count per account, only claude processes" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_PROC="$SANDBOX/proc"
  week main 30 84
  week alt 30 84
  local p
  for p in 1:claude:"" 2:claude:"" 3:claude:"$ALT" 4:bash:"$ALT"; do
    IFS=: read -r pid comm dir <<<"$p"
    mkdir -p "$SANDBOX/proc/$pid"
    echo "$comm" > "$SANDBOX/proc/$pid/comm"
    [ -z "$dir" ] && : > "$SANDBOX/proc/$pid/environ" || printf 'CLAUDE_CONFIG_DIR=%s\0' "$dir" > "$SANDBOX/proc/$pid/environ"
  done
  run --separate-stderr "$ACCT" status --json
  [ "$(field main .live <<<"$output")" = 2 ]
  [ "$(field alt .live <<<"$output")" = 1 ]
}

@test "textfile: publishes each account, marks a failed read, and leaves no temp file" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  creds "$HOME/.claude" 99999999999999
  mkdir -p "$SANDBOX/tf"
  rm -f "$XDG_CACHE_HOME/claude-acct/alt.json"
  printf '{"claudeAiOauth":{"accessToken":"tok","expiresAt":99999999999999}}\n' > "$ALT/.credentials.json"
  run "$ACCT" textfile "$SANDBOX/tf"
  assert_success
  run cat "$SANDBOX/tf/claude_acct.prom"
  assert_line 'claude_account_read_ok{account="main"} 1'
  assert_line 'claude_account_week_used_percent{account="main"} 30'
  assert_line 'claude_account_week_gone_percent{account="main"} 50'
  assert_line 'claude_account_over_pace{account="main"} 0'
  assert_line 'claude_account_read_ok{account="alt"} 0'
  refute_line --partial 'week_used_percent{account="alt"}'
  [ -z "$(find "$SANDBOX/tf" -name '.claude_acct*')" ]
}
