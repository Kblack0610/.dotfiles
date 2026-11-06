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
  mkdir -p "$HOME/.claude" "$ALT" "$XDG_CACHE_HOME/claude-acct" "$SANDBOX/proc"
  # The host's own claude processes count as live sessions, which now move the rank.
  export CLAUDE_ACCT_PROC="$SANDBOX/proc"
  export CLAUDE_ACCT_CONFIG="$SANDBOX/accounts"
  printf 'main -\nalt %s\n' "$ALT" > "$CLAUDE_ACCT_CONFIG"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin/curl"
  printf '#!/usr/bin/env bash\necho "2.1.0 (Claude Code)"\n' > "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/claude"
}

# usage <account> <5h%> <7d%> [resets_at] -- a fresh cached answer from the usage endpoint;
# without resets_at the week counts as fully ahead
usage() {
  local resets=null
  [[ -n "${4:-}" ]] && resets="\"$4\""
  printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s,"resets_at":%s}}\n' "$2" "$3" "$resets" \
    > "$XDG_CACHE_HOME/claude-acct/$1.json"
}

# creds <dir> <expiresAt-ms>
creds() {
  printf '{"claudeAiOauth":{"accessToken":"tok","expiresAt":%s}}\n' "$2" > "$1/.credentials.json"
}

@test "the account whose fuller window is lower wins when resets are unknown" {
  usage main 10 80   # weekly nearly spent
  usage alt 50 50
  run "$ACCT" pick
  assert_success
  assert_line "$ALT"
  assert_output --partial 'claude-acct: alt (5h 50%, 7d 50%)'
}

@test "the default account wins and prints an empty dir" {
  usage main 20 10
  usage alt 60 30
  run --separate-stderr "$ACCT" pick
  assert_success
  assert_output ''
  [[ "$stderr" == *'claude-acct: main'* ]]
}

@test "every account spent: the Lazer reserve is named, the pick stays on the subscription" {
  usage main 100 40
  usage alt 20 100
  run --separate-stderr "$ACCT" pick
  assert_success
  [[ "$stderr" == *'cl --lazer runs Sonnet on the Lazer reserve'* ]]
  [[ "$output" != *lazer* ]]
}

@test "an account with room left: no Lazer hint" {
  usage main 100 40
  usage alt 20 99
  run --separate-stderr "$ACCT" pick
  assert_success
  [[ "$stderr" != *lazer* ]]
}

@test "a sooner reset beats a lower percent used" {
  export CLAUDE_ACCT_NOW=1800000000
  usage main 10 70 "$(date -u -d @$((1800000000 + 6 * 86400)) +%Y-%m-%dT%H:%M:%S+00:00)"
  usage alt 10 75 "$(date -u -d @$((1800000000 + 2 * 3600)) +%Y-%m-%dT%H:%M:%S+00:00)"
  run "$ACCT" pick
  assert_line "$ALT"
}

@test "an account with its five hour window nearly full loses to one that can run now" {
  export CLAUDE_ACCT_NOW=1800000000
  r1=$(date -u -d @$((1800000000 + 2 * 3600)) +%Y-%m-%dT%H:%M:%S+00:00)
  r2=$(date -u -d @$((1800000000 + 6 * 86400)) +%Y-%m-%dT%H:%M:%S+00:00)
  usage main 90 75 "$r1"
  usage alt 10 70 "$r2"
  run "$ACCT" pick
  assert_line "$ALT"
  usage main 84 75 "$r1"
  run --separate-stderr "$ACCT" pick
  assert_output ''
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

# --- park: which shells may be stopped, and what it refuses ---

@test "park: a wait on GitHub is remote, a gate, suite or Unity run is local, anything else is other" {
  src
  local c
  for c in 'gh run watch 123 --exit-status' 'gh pr checks 9 --watch --interval 60' \
           'until gh pr checks 9 | grep -q pass; do sleep 60; done' \
           'while ! gh run view 1 --json status | grep -q completed; do sleep 30; done'; do
    run shell_kind "$c"; assert_output remote
  done
  for c in 'scripts/test/ci-gate.sh --pr 9' 'scripts/test/suite.sh --retry' './run.sh EditMode' \
           '/opt/Unity/Editor/Unity -projectPath x' 'unity-editor -batchmode -quit' \
           'until scripts/test/ci-gate.sh; do sleep 5; done' 'gh run watch 1 && scripts/test/suite.sh'; do
    run shell_kind "$c"; assert_output local
  done
  for c in 'npm run dev' 'tail -f build.log' 'sleep 600' 'gh run list' 'gh pr checks 9' 'scripts/test/rerun.sh'; do
    run shell_kind "$c"; assert_output other
  done
}

@test "park: stopping shells is refused for a local run first, then for anything not a remote wait" {
  src
  run shells_refusal $'41  gh run watch 1\n42  until gh pr checks 9; do sleep 60; done'
  assert_failure; assert_output ''
  run shells_refusal ''
  assert_failure
  run shells_refusal $'41  tail -f x.log\n42  scripts/test/ci-gate.sh --pr 9'
  assert_success
  assert_output 'a local gate or suite is running (42: scripts/test/ci-gate.sh --pr 9); stopping it throws the run away, so park it once the run ends'
  run shells_refusal $'41  gh run watch 1\n43  npm run dev'
  assert_success
  assert_output 'a background shell is not a remote wait (43: npm run dev); park it once it ends'
}

@test "park: refuses on the session's state alone, never on which account has room" {
  src
  run hold_refusal park busy 0
  assert_success; assert_output 'busy mid-turn; park it once the turn ends'
  run hold_refusal park waiting 1
  assert_success; assert_output --partial 'permission or question dialog'
  run hold_refusal park shell 0
  assert_success; assert_output 'background shells are running; park it once they finish, or pass --stop-shells to stop them'
  run hold_refusal park shell 1
  assert_failure; assert_output ''
  run hold_refusal park idle 0
  assert_failure; assert_output ''
  run hold_refusal park compacting 0
  assert_success; assert_output --partial "unknown session status 'compacting'"
}

@test "unpark: the resume is told it was parked and to re-check its wait, on the account named" {
  src
  run resume_prompt park main alt idle
  assert_output --partial 'This session was parked to save Claude usage'
  assert_output --partial 'resumed on the alt account'
  assert_output --partial 're-check it before you carry on'
  refute_output --partial 'Parking stopped'
  run resume_prompt park main alt shell
  assert_output --partial 'Parking stopped your background waits'
  run resume_prompt move main alt idle
  assert_output --partial 'moved from the main Claude account to alt'
  run resume_cmd 0 "/w t" "" 'claude --resume s1' 'hi there'
  assert_output "cd /w\\ t && env -u CLAUDE_CONFIG_DIR claude --resume s1 hi\\ there"
  run resume_cmd 1 /w /a 'claude --resume s1' hi
  assert_output 'CLAUDE_CONFIG_DIR=/a claude --resume s1 hi'
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
  # main last too: its line once came out empty and $(...) dropped it
  for p in 1:claude:"" 2:claude:"" 3:claude:"$ALT" 4:bash:"$ALT" 5:claude:""; do
    IFS=: read -r pid comm dir <<<"$p"
    mkdir -p "$SANDBOX/proc/$pid"
    echo "$comm" > "$SANDBOX/proc/$pid/comm"
    [ -z "$dir" ] && : > "$SANDBOX/proc/$pid/environ" || printf 'CLAUDE_CONFIG_DIR=%s\0' "$dir" > "$SANDBOX/proc/$pid/environ"
  done
  run --separate-stderr "$ACCT" status --json
  [ "$(field main .live <<<"$output")" = 3 ]
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
  refute_line --partial 'five_hour'
  assert_line 'claude_account_read_ok{account="alt"} 0'
  refute_line --partial 'week_used_percent{account="alt"}'
  [ -z "$(find "$SANDBOX/tf" -name '.claude_acct*')" ]
}

@test "textfile: a reported five hour window publishes its percent and its reset" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  creds "$HOME/.claude" 99999999999999
  printf '%s' "$(jq -c '.five_hour = {utilization: 26, resets_at: "2026-11-04T03:39:59.658454+00:00"}' "$XDG_CACHE_HOME/claude-acct/main.json")" > "$XDG_CACHE_HOME/claude-acct/main.json"
  mkdir -p "$SANDBOX/tf"
  run "$ACCT" textfile "$SANDBOX/tf"
  assert_success
  run cat "$SANDBOX/tf/claude_acct.prom"
  assert_line 'claude_account_five_hour_percent{account="main"} 26'
  assert_line 'claude_account_five_hour_resets_timestamp_seconds{account="main"} 1793763599'
}

@test "room: the emptier account under pace wins; main prints empty, alt its dir" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 40 84
  week alt 20 84
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output "$ALT"
  week main 10 84
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output ''
}

@test "room: of the accounts under pace the sooner reset wins" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 10 150
  week alt 20 30
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output "$ALT"
}

# live <dir> <n> -- n claude processes running on that account (empty dir = main)
live() {
  local i pid
  for ((i = 0; i < $2; i++)); do
    pid=$((40000 + $(ls "$CLAUDE_ACCT_PROC" | wc -l)))
    mkdir -p "$CLAUDE_ACCT_PROC/$pid"
    echo claude > "$CLAUDE_ACCT_PROC/$pid/comm"
    if [ -n "$1" ]; then printf 'CLAUDE_CONFIG_DIR=%s\0' "$1"; else : ; fi > "$CLAUDE_ACCT_PROC/$pid/environ"
  done
}

@test "the live sessions an account already carries count against what it has left" {
  # 2026-11-04: alt at 95% resetting in 5h carried 12 live and still won on its reset alone,
  # while main sat idle at 89% with 27h to go and was on course to lose its 11% at the reset.
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.07
  week main 89 27   # carries 0.41 an hour
  week alt 95 5     # carries 1 an hour
  run --separate-stderr "$ACCT" pick
  assert_output "$ALT"
  live "$ALT" 12    # burns 0.84 of it: 0.16 spare against main's 0.41
  run --separate-stderr "$ACCT" pick
  assert_output ''
  run --separate-stderr "$ACCT" status --json
  [ "$(field alt '.burn * 100 | round' <<<"$output")" = 84 ]
  [ "$(field main .burn <<<"$output")" = 0 ]
}

@test "every account overcommitted: the one with less burn per point left takes the next start" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 50 50   # carries 1 an hour
  week alt 50 50
  live "" 20        # twice what it carries
  live "$ALT" 15    # 1.5 times
  run --separate-stderr "$ACCT" pick
  assert_output "$ALT"
  live "$ALT" 10
  run --separate-stderr "$ACCT" pick
  assert_output ''
}

@test "every account overcommitted: the next start goes where it keeps running longest" {
  # 2026-11-05: alt fresh at 19% with 26 live caps in 27h, bnb at 89% with 9 live caps in 10h.
  # Burn per spare point an hour sent cl to bnb, which its own sessions empty first.
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.118
  week main 89 30
  week alt 19 150
  live "" 9
  live "$ALT" 26
  run --separate-stderr "$ACCT" pick
  assert_success
  assert_output "$ALT"
}

@test "room: under pace, the account with spare room after its live sessions wins" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 10 150  # sooner reset elsewhere would win with nothing live
  week alt 20 30
  live "$ALT" 30    # 3 an hour against 2.7 it can carry
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output ''
}

@test "room: an account under pace that its live sessions already overcommit has none" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 50 50
  week alt 50 50   # both under pace, 1 point an hour to spare
  live "$ALT" 15
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output ''
  live "" 12
  run --separate-stderr "$ACCT" room
  assert_failure 1
  [[ "$stderr" == *'live sessions use the rest of its week before the reset'* ]]
  # a hand start is told, never refused
  run --separate-stderr "$ACCT" pick
  assert_success
}

@test "the session rate comes from Prometheus, is cached, falls back when unreadable, and a pick never asks" {
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *live_sessions*) echo '{"data":{"result":[{"metric":{},"value":[0,"0.25"]}]}}' ;; *) exit 22 ;; esac
STUB
  export CC_PROM_URL=http://prom.test
  # a pick (nospend) never asks Prometheus, so `cl` off the LAN does not wait
  run bash -c "source '$ACCT'; session_rate nospend"
  assert_output 0.07
  [ ! -e "$XDG_CACHE_HOME/claude-acct/session_rate" ]
  run bash -c "source '$ACCT'; session_rate"
  assert_output 0.25
  touch -d '-1 day' "$XDG_CACHE_HOME/claude-acct/session_rate"
  run bash -c "source '$ACCT'; session_rate nospend"
  assert_output 0.25
  touch "$XDG_CACHE_HOME/claude-acct/session_rate"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin/curl"
  run bash -c "source '$ACCT'; session_rate"
  assert_output 0.25
  rm "$XDG_CACHE_HOME/claude-acct/session_rate"
  run bash -c "source '$ACCT'; session_rate"
  assert_output 0.07
}

@test "room: today's numbers refuse main and take alt" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 66 102   # 39% of the week gone
  week alt 32 79     # 53% gone
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output "$ALT"
}

@test "room: over pace on both accounts is exit 1" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 70 84
  week alt 60 84
  run --separate-stderr "$ACCT" room
  assert_failure 1
  [[ "$stderr" == *'no account has room'* ]]
}

@test "room: with none, the line names the closest account, how far past its pace, and when it runs out" {
  # 2026-11-05 12:33: alt 15% used with 9% of its week gone, 1 point past the 5 of slack; bnb (here
  # main) at 88%, inside its reserve. "no account has room" alone read as every account full.
  export CLAUDE_ACCT_NOW=$NOW TZ=UTC
  week main 88 50
  week alt 15 152
  run --separate-stderr "$ACCT" room
  assert_failure 1
  assert_output ''
  assert_equal "$stderr" 'claude-acct: no account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack), runs out Tue 02:40 at this rate'
  # the same row status prints
  run "$ACCT" status
  assert_line --regexp '^alt +- +15% +9% +over +Tue 02:40 '
  # the reserve, when that is what refuses the closest one; it lasts to its reset
  week main 88 2
  week alt 90 100
  run --separate-stderr "$ACCT" room
  assert_failure 1
  assert_equal "$stderr" 'claude-acct: no account has room; main is the closest, 88% of its week used, inside the last 15% kept for the human, lasts to its reset Fri 10:00'
}

@test "room: the slack is the edge of the pace line" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_PACE_SLACK_PCT=5
  week main 55 84
  week alt 56 84
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output ''
  week main 56 84
  run --separate-stderr "$ACCT" room
  assert_failure 1
}

@test "room: the reserve holds late in the week, even under pace" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 85 2
  week alt 90 2
  run --separate-stderr "$ACCT" room
  assert_failure 1
  week main 84 2
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output ''
}

@test "room: a nearly spent five hour window refuses when it is reported" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 10 84
  week alt 20 84
  printf '%s' "$(jq -c '.five_hour = {utilization: 90}' "$XDG_CACHE_HOME/claude-acct/main.json")" > "$XDG_CACHE_HOME/claude-acct/main.json"
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output "$ALT"
}

@test "room: an expired token has room; a failed read with no room elsewhere is exit 2" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 70 84
  creds "$ALT" 1000
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output "$ALT"
  creds "$ALT" 99999999999999
  run --separate-stderr "$ACCT" room
  assert_failure 2
}

@test "room: one account unread does not stop a start on the other" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 10 84
  creds "$ALT" 99999999999999
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output ''
}

@test "pick warns when its account is over pace, and still picks it" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 70 84
  week alt 80 84
  run --separate-stderr "$ACCT" pick
  assert_success
  assert_output ''
  [[ "$stderr" == *'main is over its weekly pace'* ]]
}

@test "check usage: trips on a failed read, naming the account, clears when both read" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  creds "$ALT" 99999999999999
  run "$ACCT" check usage
  assert_failure 1
  assert_output 'cannot read usage of alt'
  week alt 30 84
  run "$ACCT" check usage
  assert_success
  assert_output 'usage read on 2 accounts'
}

@test "check usage: an expired token is not a failed read" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  creds "$ALT" 1000
  run "$ACCT" check usage
  assert_success
}

# prom <rate-points-over-2h> -- a curl stub answering the burn check's two queries
prom() {
  cat > "$SANDBOX/bin/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *topk*) echo '{"data":{"result":[{"metric":{"session_id":"bbbbbbbb-2"},"value":[0,"31.2"]},{"metric":{"session_id":"aaaaaaaa-1"},"value":[0,"88.9"]}]}}' ;;
  *offset*) echo '{"data":{"result":[{"metric":{},"value":[0,"$1"]}]}}' ;;
  *) exit 22 ;;
esac
STUB
  export CC_PROM_URL=http://prom.test
}

@test "check burn: a 2h rate over what the week can carry trips and names the spenders" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 70 20   # 30 left
  week alt 50 10    # 50 left; 80 points over 20h is 4 a hour
  prom 12           # 6 a hour over 2h
  export CLAUDE_ACCT_PROC="$SANDBOX/proc"
  mkdir -p "$CLAUDE_ACCT_PROC/7" "$CLAUDE_ACCT_PROC/8"
  for p in 7 8; do echo claude > "$CLAUDE_ACCT_PROC/$p/comm"; : > "$CLAUDE_ACCT_PROC/$p/environ"; done
  run "$ACCT" check burn
  assert_failure 1
  assert_output --partial 'burning 6.0%/h over 2h, the week can carry 4.0%/h (80% left, resets in 20h)'
  assert_output --partial '2 live sessions; top by 2h spend: aaaaaaaa $88, bbbbbbbb $31'
}

@test "check burn: a 2h rate under what the week can carry passes" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 70 20
  week alt 50 10
  prom 6            # 3 a hour
  run "$ACCT" check burn
  assert_success
  assert_output --partial 'burning 3.0%/h'
}

@test "check burn: Prometheus unreachable is exit 2, not a pass" {
  export CLAUDE_ACCT_NOW=$NOW CC_PROM_URL=http://prom.test   # the curl stub fails
  week main 70 20
  week alt 50 10
  run "$ACCT" check burn
  assert_failure 2
  assert_output --partial 'Prometheus is unreachable'
}

@test "check: an unknown name is a usage error, not a pass" {
  run "$ACCT" check nonsense
  assert_failure 2
}

@test "pick <name> prints that account's dir whatever the usage, and refuses an unknown one" {
  usage main 10 10
  usage alt 90 90
  run --separate-stderr "$ACCT" pick alt
  assert_success
  assert_output "$ALT"
  run --separate-stderr "$ACCT" pick main
  assert_success
  assert_output ''
  run --separate-stderr "$ACCT" pick nope
  assert_failure
  [[ "$stderr" == *"no account 'nope'"*"have: main alt"* ]]
}

# run: the one launcher for a human start (cl, sessions resume, the fzf picker, the hub).
seen_claude() {
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "${CLAUDE_CONFIG_DIR:-<main>}" "$*"\n' > "$SANDBOX/bin/claude"
}

@test "run execs claude on the picked account with its arguments" {
  seen_claude
  usage main 10 80
  usage alt 50 50
  CLAUDE_CONFIG_DIR="$HOME/.claude-spent" run --separate-stderr "$ACCT" run -r sid-1
  assert_success
  assert_output "$ALT|-r sid-1"
}

@test "run on main drops an inherited alt account; --acct forces one" {
  seen_claude
  usage main 20 10
  usage alt 60 30
  CLAUDE_CONFIG_DIR="$ALT" run --separate-stderr "$ACCT" run --dangerously-skip-permissions
  assert_output "<main>|--dangerously-skip-permissions"
  run --separate-stderr "$ACCT" run --acct alt -c
  assert_output "$ALT|-c"
  run --separate-stderr "$ACCT" run --acct nope
  assert_failure
}
