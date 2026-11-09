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
  usage main 97 75 "$r1"
  usage alt 10 70 "$r2"
  run "$ACCT" pick
  assert_line "$ALT"
  usage main 94 75 "$r1"
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

@test "a resumed claude keeps the model, permission and dropped-tools flags and drops the brief" {
  src
  mkdir -p "$SANDBOX/proc/42"
  printf 'claude\0--model\0opus\0--disallowedTools\0Workflow,ScheduleWakeup\0--permission-mode\0bypassPermissions\0/one-shot do --model it\0' > "$SANDBOX/proc/42/cmdline"
  run carry_flags 42
  assert_output '--model opus --disallowedTools Workflow\,ScheduleWakeup --permission-mode bypassPermissions '
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
  for c in 'gh-run-wait 123 Release' '/home/u/.local/bin/gh-run-wait 123' \
           'gh run watch 123 --exit-status' 'gh pr checks 9 --watch --interval 60' \
           'until gh pr checks 9 | grep -q pass; do sleep 60; done' \
           'while ! gh run view 1 --json status | grep -q completed; do sleep 30; done'; do
    run shell_kind "$c"; assert_output remote
  done
  for c in 'scripts/test/ci-gate.sh --pr 9' 'scripts/test/suite.sh --retry' './run.sh EditMode' \
           '/opt/Unity/Editor/Unity -projectPath x' 'unity-editor -batchmode -quit' \
           'until scripts/test/ci-gate.sh; do sleep 5; done' 'gh run watch 1 && scripts/test/suite.sh'; do
    run shell_kind "$c"; assert_output local
  done
  for c in 'npm run dev' 'tail -f build.log' 'sleep 600' 'gh run list' 'gh pr checks 9' 'scripts/test/rerun.sh' 'vi gh-run-waiter'; do
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
  # A pane that is its claude gets the launch env; with no claude-telemetry.sh it says so, and still
  # carries the queue item.
  run resume_cmd 1 /w /a 'claude --resume s1' hi fix-menu
  assert_line --index 0 --partial 'no launch env from'
  assert_line --index 1 'CLAUDE_CONFIG_DIR=/a AGENT_QUEUE_ITEM=fix-menu claude --resume s1 hi'
}

# week <account> <used%> <hours-until-reset> -- a fresh answer with a weekly window, now at NOW
NOW=1800000000
week() {
  local resets
  resets=$(date -u -d "@$((NOW + $3 * 3600))" +%Y-%m-%dT%H:%M:%S.123456+00:00)
  printf '{"five_hour":null,"seven_day":{"utilization":%s,"resets_at":"%s"}}\n' "$2" "$resets" \
    > "$XDG_CACHE_HOME/claude-acct/$1.json"
}
# field <name> <jq>: from status --json's rows or room --json's accounts
field() { jq -r --arg a "$1" "if type == \"object\" then .accounts else . end | .[] | select(.name == \$a) | $2"; }

@test "status --json: run_out is when the live sessions empty the week at their burn now" {
  # 2026-11-09: a straight line from the week start said main ran out Tue 21:12; its burn then ran
  # it out Wed night to Thu morning (backtest: .59 points/h off over 6h, live x rate .32).
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 30 84
  week alt 80 84
  live "$ALT" 10   # 1 point an hour, 20 left
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field main .week_gone <<<"$output")" = 50 ]
  [ "$(field main .room.ok <<<"$output")" = true ]
  # no live sessions, no burn: it lasts to the reset
  [ "$(field main .run_out <<<"$output")" = null ]
  [ "$(field alt .room.reason <<<"$output")" = pace ]
  [ "$(field alt .run_out <<<"$output")" = "$((NOW + 20 * 3600))" ]
  # Negative control: a burn that lasts past the reset is null, not a time after it.
  live "" 1        # 0.1 an hour, 70 left: 700h, past the reset in 84h
  run --separate-stderr "$ACCT" status --json
  [ "$(field main .run_out <<<"$output")" = null ]
}

@test "status --json: the first hour of a week, and an account past its limit" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 0 167
  week alt 104 10
  live "$ALT" 1
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field main .room.ok <<<"$output")" = true ]
  [ "$(field main .run_out <<<"$output")" = null ]
  [ "$(field alt .room.ok <<<"$output")" = false ]
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
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"user_email\":\"m@x\"},\"value\":[0,\"600.4\"]}]}}'" > "$SANDBOX/bin/curl"
  export CC_PROM_URL=http://prom.test
  run "$ACCT" status
  assert_success
  assert_line --regexp '^main +- +30% +50% +.*\$600 +0 +0\.83 +now +ok +claude +m@x$'
  assert_line --regexp '^alt +- +80% +50% +.*\$0 +0 +0\.24 +[A-Z][a-z]{2} [0-9:]{5} +pace +claude +a@x$'
}

@test "status: Prometheus down leaves the percents and blanks only the dollars" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  echo '{"oauthAccount":{"emailAddress":"m@x"}}' > "$HOME/.claude.json"
  export CC_PROM_URL=http://prom.test   # the curl stub fails
  run "$ACCT" status
  assert_success
  assert_line --regexp '^main +- +30% +50% +.* - +0 +0\.83 +now +ok +claude +m@x$'
}

@test "live sessions count per account, only claude processes" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_PROC="$SANDBOX/proc"
  week main 30 84
  week alt 30 84
  local p
  # main last too: its line once came out empty and $(...) dropped it
  for p in 1:claude:"" 2:claude:"" 3:claude:"$ALT" 4:bash:"$ALT" 5:claude:"" 6:claude:""; do
    IFS=: read -r pid comm dir <<<"$p"
    mkdir -p "$SANDBOX/proc/$pid"
    echo "$comm" > "$SANDBOX/proc/$pid/comm"
    [ -z "$dir" ] && : > "$SANDBOX/proc/$pid/environ" || printf 'CLAUDE_CONFIG_DIR=%s\0' "$dir" > "$SANDBOX/proc/$pid/environ"
  done
  # a claude-lazer session (no CLAUDE_CONFIG_DIR, on the gateway) spends no account
  printf 'ANTHROPIC_BASE_URL=https://llm.example\0' > "$SANDBOX/proc/6/environ"
  run --separate-stderr "$ACCT" status --json
  [ "$(field main .live <<<"$output")" = 3 ]
  [ "$(field alt .live <<<"$output")" = 1 ]
}

@test "live_of forks no tool per process" {
  # pick runs this loop on every agentctl-run call; a fork per /proc entry cost 2.3s of 2.5s (ar-1007).
  local p
  for p in 1:claude:"" 2:bash:"" 3:claude:"$ALT" 4:claude:gw; do
    IFS=: read -r pid comm dir <<<"$p"
    mkdir -p "$SANDBOX/proc/$pid"
    echo "$comm" > "$SANDBOX/proc/$pid/comm"
    case "$dir" in
      "") printf 'HOME=/h\0' ;;
      gw) printf 'ANTHROPIC_BASE_URL=https://llm.example\0' ;;
      *) printf 'A=1\0CLAUDE_CONFIG_DIR=%s/\0CLAUDE_CONFIG_DIR=/not-first\0' "$dir" ;;
    esac > "$SANDBOX/proc/$pid/environ"
  done
  mkdir -p "$SANDBOX/proc/5"   # a process gone between the glob and the read: no comm, no environ
  echo claude > "$SANDBOX/proc/5/comm"; rm "$SANDBOX/proc/5/comm"
  mkdir -p "$SANDBOX/shim"
  for p in cat head tr sed awk grep; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/fork.log"\nexec /usr/bin/env -i PATH=/usr/bin:/bin %s "$@"\n' "$p" "$SANDBOX" "$p" > "$SANDBOX/shim/$p"
    chmod +x "$SANDBOX/shim/$p"
  done
  src
  PATH="$SANDBOX/shim:$PATH" run --separate-stderr live_of
  assert_success
  [ -z "$stderr" ]
  [ "$(sort <<<"$output" | paste -sd' ')" = "@ @$ALT" ]
  [ ! -e "$SANDBOX/fork.log" ] || { cat "$SANDBOX/fork.log"; false; }
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
  assert_line 'claude_account_read_ok{account="main",kind="claude"} 1'
  assert_line 'claude_account_week_used_percent{account="main",kind="claude"} 30'
  assert_line 'claude_account_week_gone_percent{account="main",kind="claude"} 50'
  assert_line 'claude_account_room{account="main",kind="claude"} 1'
  refute_line --partial 'over_pace'
  refute_line --partial 'five_hour'
  assert_line 'claude_account_read_ok{account="alt",kind="claude"} 0'
  refute_line --partial 'week_used_percent{account="alt",kind="claude"}'
  # negative control: an unread account publishes no burn or pace figure
  refute_line --regexp '(burn|sustain|on_pace).*account="alt"'
  assert_line --regexp '^claude_account_sustain_points_per_hour\{account="main",kind="claude"\} 0\.833'
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
  assert_line 'claude_account_five_hour_percent{account="main",kind="claude"} 26'
  assert_line 'claude_account_five_hour_resets_timestamp_seconds{account="main",kind="claude"} 1793763599'
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
case "$*" in *live_sessions*) echo '{"status":"success","data":{"result":[{"metric":{},"value":[0,"0.25"]}]}}' ;; *) exit 22 ;; esac
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

@test "the session rate collapses each account to one series, so a new metric label still has a partner 6h back" {
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SANDBOX/prom.args"
echo '{"status":"success","data":{"result":[{"metric":{},"value":[0,"0.06"]}]}}'
STUB
  export CC_PROM_URL=http://prom.test SANDBOX
  run bash -c "source '$ACCT'; session_rate; session_rate '' codex"
  assert_success
  run grep -cF 'max by (account) (claude_account_week_used_percent{kind=~"claude|"} offset 6h)' "$SANDBOX/prom.args"
  assert_output 1
  run grep -cF 'max by (account) (claude_account_week_used_percent{account="codex"} offset 6h)' "$SANDBOX/prom.args"
  assert_output 1
  run grep -cF 'avg_over_time((max by (account) (claude_account_live_sessions{account="codex"}))[6h:5m]) and on (account)' "$SANDBOX/prom.args"
  assert_output 1
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
  # main) at 96%, inside its reserve. "no account has room" alone read as every account full.
  export CLAUDE_ACCT_NOW=$NOW TZ=UTC
  week main 96 50
  week alt 15 152
  # Running out before the reset at its burn is committed too, so both carry 10 live (1 point an
  # hour) and alt, with 85 left against main's 4, stays the closest.
  export CLAUDE_ACCT_SESSION_RATE=0.1
  live "" 10
  live "$ALT" 10
  run --separate-stderr "$ACCT" room
  assert_failure 1
  assert_output ''
  assert_equal "$stderr" 'claude-acct: no account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack), runs out Mon 21:00 at this rate'
  # the same row status prints
  run "$ACCT" status
  assert_line --regexp '^alt +- +15% +9% +Mon 21:00 '
  # the reserve, when that is what refuses the closest one; it lasts to its reset
  # no live sessions from here: a row with no burn lasts to its reset
  rm -rf "${CLAUDE_ACCT_PROC:?}"/*
  week main 96 2
  week alt 97 100
  run --separate-stderr "$ACCT" room
  assert_failure 1
  assert_equal "$stderr" 'claude-acct: no account has room; main is the closest, 96% of its week used, inside the last 5% kept for the human, lasts to its reset Fri 10:00'
}

@test "room: the slack is the edge of the pace line" {
  export CLAUDE_ACCT_NOW=$NOW   # pace.conf's 5 of slack
  week main 55 84
  week alt 56 84
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output ''
  week main 56 84
  run --separate-stderr "$ACCT" room
  assert_failure 1
}

@test "room: the machine-mode level scales slack and reserve; pick, which cl uses, does not move" {
  export CLAUDE_ACCT_NOW=$NOW TZ=UTC
  week main 96 50
  week alt 15 152   # 1 point past mid's 5 of slack
  run --separate-stderr "$ACCT" pick
  local mid_pick="$output"
  run --separate-stderr "$ACCT" room
  assert_failure 1
  mkdir -p "$HOME/.agent"
  echo MACHINE_MODE=full > "$HOME/.agent/machine-mode.env"   # high: 10 of slack
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output "$ALT"
  run --separate-stderr "$ACCT" pick
  assert_output "$mid_pick"
  echo MACHINE_MODE=reserved > "$HOME/.agent/machine-mode.env"   # low: 1 of slack, 7 kept back
  run --separate-stderr "$ACCT" room
  assert_failure 1
  [[ "$stderr" == *'5 points over its weekly pace (15% used, 9% of its week gone, 1 point of slack)'* ]] || fail "$stderr"
  week main 94 2
  week alt 97 100
  run --separate-stderr "$ACCT" room
  assert_failure 1
  [[ "$stderr" == *'94% of its week used, inside the last 7% kept for the human'* ]] || fail "$stderr"
}

@test "room: the reserve holds late in the week, even under pace" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 95 2
  week alt 97 2
  run --separate-stderr "$ACCT" room
  assert_failure 1
  week main 94 2
  run --separate-stderr "$ACCT" room
  assert_success
  assert_output ''
}

@test "room: a nearly spent five hour window refuses when it is reported" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 10 84
  week alt 20 84
  printf '%s' "$(jq -c '.five_hour = {utilization: 97}' "$XDG_CACHE_HOME/claude-acct/main.json")" > "$XDG_CACHE_HOME/claude-acct/main.json"
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
  [[ "$stderr" == *'main would be refused an automatic start, 15 points over its weekly pace'* ]] || fail "$stderr"
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

@test "cost: each session's dollars over the window, by id; Prometheus unreachable is exit 2" {
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$HOME/curl.args"
echo '{"status":"success","data":{"result":[{"metric":{"session_id":"s1"},"value":[0,"12.345"]},{"metric":{},"value":[0,"9"]}]}}'
STUB
  export CC_PROM_URL=http://prom.test
  run "$ACCT" cost
  assert_success
  assert_output '{"s1":12.35}'
  grep -q 'USD_total\[7d\]' "$HOME/curl.args"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin/curl"
  run "$ACCT" cost
  assert_failure 2
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

@test "back on pace: over pace and burning past the line is never at this burn, and the idle time is the clock catching up" {
  # 2026-11-06: 39 live burned 4.5 points an hour against the 1.4 the three weeks could carry
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 30 84   # under pace: on pace now either way
  week alt 80 84    # 30 points over, half the week gone
  live "$ALT" 10    # 1.0 an hour, over the 0.595 the week refills
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field main .on_pace_idle <<<"$output")" = "$NOW" ]
  [ "$(field main .on_pace_burn <<<"$output")" = "$NOW" ]
  [ "$(field alt .on_pace_burn <<<"$output")" = null ]
  # 25 points past the 5 of slack at 100 a week is 42h
  [ "$(field alt .on_pace_idle <<<"$output")" = "$((NOW + 151200))" ]
  [ "$(field alt '.sustain * 84 | round' <<<"$output")" = 20 ]
}

@test "back on pace: a burn under the line closes the gap, and one that closes after the reset says null" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 60 84   # 10 points over, 5 past the slack
  week alt 80 84    # 25 past the slack: 84.7h at this burn, past the reset in 84h
  live "" 3
  live "$ALT" 3     # 0.3 an hour: the gap closes at 0.295 an hour
  run --separate-stderr "$ACCT" status --json
  assert_success
  # 5 / (100/168 - 0.3) = 16.935h
  [ "$(field main '.on_pace_burn - '$NOW' | . >= 60960 and . <= 60970' <<<"$output")" = true ]
  [ "$(field alt .on_pace_burn <<<"$output")" = null ]
}

@test "back on pace: is when room drops pace, so inside the slack is on pace now" {
  # 2026-11-09: on_pace compared used with gone and ignored the slack, so ON-PACE read about 16h
  # after the gate would let dispatch start on alt again.
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 55 84   # 5 points over: inside the slack
  week alt 56 84    # 6 over: one point past it
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field main .room.reasons <<<"$output" | jq -c .)" = '[]' ]
  [ "$(field main .on_pace_idle <<<"$output")" = "$NOW" ]
  [ "$(field alt .room.reason <<<"$output")" = pace ]
  # 1 point at 100 a week is 1.68h
  [ "$(field alt .on_pace_idle <<<"$output")" = "$((NOW + 6048))" ]
}

@test "status: the fleet line sums live, burn and what the weeks carry, and names the first back on pace" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 80 84
  week alt 80 84
  live "" 10
  live "$ALT" 10
  run "$ACCT" status
  assert_success
  assert_line --partial 'after-reset'
  assert_line --regexp '^fleet: 20 live, burn 2/h vs 0\.5/h sustainable \(4\.2x, carries ~4\), back on pace: not at this burn; if idle (main|alt) '
}

# --- the room verdict is one field of each usage row -------------------------------------------
# Every surface reads usage_json's `room` object; none re-derives "over pace". Each case below
# failed against the old script, where room.reason did not exist and the pick hint, the PACE column
# and the select in cmd_room each held their own rule.

@test "room object: inside the slack is ok, one point past it is no room by one point" {
  export CLAUDE_ACCT_NOW=$NOW
  week alt 18 141   # 27h of 168 gone = 16.07%, so 21.07 is the edge with 5 of slack
  week main 22 141
  run --separate-stderr "$ACCT" status --json
  assert_success
  [[ "$(field alt .room.ok <<< "$output")" == true ]]
  [[ "$(field alt .room.reason <<< "$output")" == ok ]]
  [[ "$(field main .room.ok <<< "$output")" == false ]]
  [[ "$(field main .room.reason <<< "$output")" == pace ]]
  [[ "$(field main '.room.over_points | ceil' <<< "$output")" == 1 ]]
  [[ "$(field alt '.room.headroom_points | floor' <<< "$output")" == 3 ]]
}

@test "room object: the reserve, the capped week and the live sessions each get their own reason" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 97 2
  week alt 100 2
  run --separate-stderr "$ACCT" room --json
  assert_failure 1
  [[ "$(field main .room.reason <<< "$output")" == reserve ]]
  [[ "$(field main .room.capped <<< "$output")" == false ]]
  [[ "$(field alt .room.reason <<< "$output")" == capped ]]
  [[ "$(field alt .room.capped <<< "$output")" == true ]]
  week main 50 84
  week alt 50 84
  live "" 12
  run --separate-stderr "$ACCT" room --json
  [[ "$(field main .room.reason <<< "$output")" == committed ]]
  [[ "$(field alt .room.reason <<< "$output")" == ok ]]
}

@test "room object: reasons lists every refusal, so a floor can tell pace alone from pace and more" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 22 141   # 1 point past its line and nothing else
  week alt 22 141
  printf '%s' "$(jq -c '.five_hour = {utilization: 97}' "$XDG_CACHE_HOME/claude-acct/alt.json")" > "$XDG_CACHE_HOME/claude-acct/alt.json"
  run --separate-stderr "$ACCT" room --json
  assert_failure 1
  [[ "$(field main '.room.reasons | join(",")' <<< "$output")" == pace ]]
  [[ "$(field alt '.room.reasons | join(",")' <<< "$output")" == pace,five_hour ]]
  [[ "$(field alt .room.reason <<< "$output")" == pace ]]
  # the textfile carries every reason, so the chip can say what else holds alt
  mkdir -p "$SANDBOX/prom" && "$ACCT" textfile "$SANDBOX/prom"
  grep -q '^claude_account_room_reason{account="alt",kind="claude",reason="pace"} 1$' "$SANDBOX/prom/claude_acct.prom"
  grep -q '^claude_account_room_reason{account="alt",kind="claude",reason="five_hour"} 1$' "$SANDBOX/prom/claude_acct.prom"
  [[ "$(field main .room.why <<< "$output")" == '1 point over its weekly pace (22% used, 16% of its week gone, 5 points of slack)' ]]
  # the refusal sentence is claude-acct's own, in the answer, so no reader rebuilds or parses it
  assert_equal "$(jq -r .pick <<< "$output")" null
  [[ "$(jq -r .why <<< "$output")" == 'no account has room; main is the closest, 1 point over its weekly pace (22% used, 16% of its week gone, 5 points of slack)'* ]]
  assert_equal "$stderr" ''
  # early in the week the reserve is past the line too, and both are named
  week main 97 141
  run --separate-stderr "$ACCT" room --json
  [[ "$(field main '.room.reasons | join(",")' <<< "$output")" == reserve,pace ]]
  [[ "$(field main .room.why <<< "$output")" == '97% of its week used, inside the last 5% kept for the human' ]]
  week main 10 84
  run --separate-stderr "$ACCT" room --json
  assert_success
  [[ "$(field main '.room.reasons | length' <<< "$output")" == 0 ]]
  [[ "$(field main .room.why <<< "$output")" == 'it has room' ]]
}

@test "room object: the old env overrides move nothing; pace.conf is the one source" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 22 141
  week alt 22 141
  CLAUDE_ACCT_PACE_SLACK_PCT=100 CLAUDE_ACCT_RESERVE_PCT=0 run --separate-stderr "$ACCT" room --json
  assert_failure 1
  [[ "$(field main .room.slack <<< "$output")" == 5 ]]
  [[ "$(field main .room.reserve <<< "$output")" == 5 ]]
  run grep -nE 'CLAUDE_ACCT_(PACE_SLACK|RESERVE)_PCT:-' "$ACCT"
  assert_failure
}

@test "room --json: exit codes match room, an unread account is not a room verdict, and a window at the reserve refuses" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 10 84
  creds "$ALT" 99999999999999
  run --separate-stderr "$ACCT" room --json
  assert_success
  [[ "$(field alt .room.reason <<< "$output")" == unread ]]
  [[ "$(field main .room.ok <<< "$output")" == true ]]
  assert_equal "$(jq -r '"\(.pick) \(.why)"' <<< "$output")" 'main null'
  week main 70 84
  run --separate-stderr "$ACCT" room --json
  assert_failure 2
  assert_equal "$(jq -r '"\(.pick) \(.why)"' <<< "$output")" 'null no account has room and one cannot be read'
  week main 10 84
  week alt 20 84
  printf '%s' "$(jq -c '.five_hour = {utilization: 97}' "$XDG_CACHE_HOME/claude-acct/main.json")" > "$XDG_CACHE_HOME/claude-acct/main.json"
  run --separate-stderr "$ACCT" room --json
  assert_success
  [[ "$(field main .room.reason <<< "$output")" == five_hour ]]
  [[ "$(field alt .room.ok <<< "$output")" == true ]]
}

@test "room object: the machine-mode level scales what the published verdict says, and pick's rank does not" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 22 141   # 1 point past mid's 5 of slack
  week alt 22 141
  run "$ACCT" status --json
  [[ "$(field main .room.slack <<< "$output")" == 5 ]]
  [[ "$(field main .room.ok <<< "$output")" == false ]]
  mkdir -p "$HOME/.agent"
  echo MACHINE_MODE=full > "$HOME/.agent/machine-mode.env"   # high: 10 of slack
  run "$ACCT" status --json
  [[ "$(field main .room.slack <<< "$output")" == 10 ]]
  [[ "$(field main .room.ok <<< "$output")" == true ]]
}

@test "one verdict: room, status, the textfile and pick's hint all follow the same row" {
  export CLAUDE_ACCT_NOW=$NOW TZ=UTC
  week main 22 141
  week alt 22 141
  mkdir -p "$SANDBOX/prom"
  run --separate-stderr "$ACCT" room
  assert_failure 1
  [[ "$stderr" == *'main is the closest, 1 point over its weekly pace'* ]] || fail "$stderr"
  run "$ACCT" status
  assert_line --regexp '^main .* pace +claude +[^ ]*$'
  run --separate-stderr "$ACCT" pick
  [[ "$stderr" == *'main would be refused an automatic start, 1 point over its weekly pace'* ]] || fail "$stderr"
  "$ACCT" textfile "$SANDBOX/prom"
  grep -q '^claude_account_room{account="main",kind="claude"} 0$' "$SANDBOX/prom/claude_acct.prom"
  grep -q '^claude_account_room_headroom_points{account="main",kind="claude"} -0\.9' "$SANDBOX/prom/claude_acct.prom"
  grep -q '^claude_account_room_reason{account="main",kind="claude",reason="pace"} 1$' "$SANDBOX/prom/claude_acct.prom"
  # the one number lives in pace.conf: lift the slack there and every surface moves with it
  sed 's/^PACE_SLACK_PCT=.*/PACE_SLACK_PCT=10/' "$REPO_ROOT/.config/claude-acct/pace.conf" > "$SANDBOX/pace.conf"
  export CLAUDE_ACCT_PACE_CONF="$SANDBOX/pace.conf"
  run --separate-stderr "$ACCT" room
  assert_success
  run --separate-stderr "$ACCT" pick
  [[ "$stderr" != *'no room'* ]] || fail "$stderr"
  "$ACCT" textfile "$SANDBOX/prom"
  grep -q '^claude_account_room{account="main",kind="claude"} 1$' "$SANDBOX/prom/claude_acct.prom"
  grep -q '^claude_account_room_reason{account="main",kind="claude",reason="ok"} 1$' "$SANDBOX/prom/claude_acct.prom"
  run grep -c '^claude_account_room_reason{account="main",kind="claude",' "$SANDBOX/prom/claude_acct.prom"
  assert_output 1
}

@test "pace.conf: a number missing from it stops claude-acct and names the file" {
  grep -v '^RESERVE_PCT=' "$REPO_ROOT/.config/claude-acct/pace.conf" > "$SANDBOX/pace.conf"
  CLAUDE_ACCT_PACE_CONF="$SANDBOX/pace.conf" run --separate-stderr "$ACCT" room
  assert_failure 1
  [[ "$stderr" == *"RESERVE_PCT is not set to a number in $SANDBOX/pace.conf"* ]] || fail "$stderr"
}

@test "pace.conf: a value with a trailing comment is refused, and room takes no unknown argument" {
  sed 's/^PACE_SLACK_PCT=.*/PACE_SLACK_PCT=5 # note/' "$REPO_ROOT/.config/claude-acct/pace.conf" > "$SANDBOX/pace.conf"
  CLAUDE_ACCT_PACE_CONF="$SANDBOX/pace.conf" run --separate-stderr "$ACCT" room
  assert_failure 1
  [[ "$stderr" == *'PACE_SLACK_PCT is not set to a number'* ]] || fail "$stderr"
  run --separate-stderr "$ACCT" room --jsn
  assert_failure 3
}

@test "no second copy: the pace numbers and the room rule are written once, in pace.conf and usage_json" {
  # a literal default beside the conf, or a second pace comparison in the verbs, is a second source
  run grep -nE 'SLACK_PCT:-[0-9]|RESERVE_PCT:-[0-9]|SESSION_RATE:-[0-9]' "$ACCT"
  assert_failure
  [[ "$(grep -cE '\$u > \$g \+ \$slack' "$ACCT")" == 1 ]]
  # the plain used-past-gone flag is gone: it called an account over that dispatch still starts on
  run grep -n 'over_pace' "$ACCT"
  assert_failure
  [[ "$(grep -c 'RESERVE_PCT=' "$REPO_ROOT/.config/claude-acct/pace.conf")" == 1 ]]
}

# --- sources: codex, litellm keys and teams -------------------------------------------

# src_setup -- the sources file, the gateway url, and a curl that answers from $SANDBOX/gw. The key
# arrives on stdin (`-K -`), so the stub files the reply by it and records argv to prove the key is
# never on the command line.
src_setup() {
  export CLAUDE_ACCT_NOW=$NOW
  export CLAUDE_ACCT_SOURCES="$SANDBOX/sources"
  export CLAUDE_ACCT_HARNESSES="$SANDBOX/harnesses.json"
  # the sources file is whitespace-separated, and $SANDBOX has a space in it: refs live beside it
  SRC="$BATS_TEST_TMPDIR"
  mkdir -p "$SANDBOX/gw" "$SRC/codex/2026/11"
  echo '{"gateway":{"url":"http://gw.test"},"harnesses":{}}' > "$CLAUDE_ACCT_HARNESSES"
  echo sk-lazer > "$SRC/lazer.key"
  echo sk-res > "$SRC/res.key"
  cat > "$SANDBOX/sources" <<EOS
# name kind ref [reserve=N] [max_live=N] [parent=name]
codex   codex         $SRC/codex  reserve=5
lazer   litellm-team  $SRC/lazer.key
res     litellm-key   $SRC/res.key   parent=lazer max_live=2
EOS
  cat > "$SANDBOX/bin/curl" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$SANDBOX/curl.argv"
hdr=; [[ " $* " == *" -K - "* ]] && hdr=$(cat)
echo "$hdr" >> "$SANDBOX/curl.stdin"
url=${*: -1}
key=${hdr##*Bearer }; key=${key%\"*}
case "$url" in
  */team/info*) cat "$SANDBOX/gw/team.json" ;;
  */key/info) cat "$SANDBOX/gw/$key.json" ;;
  */v1/messages/count_tokens) if [[ -f "$SANDBOX/gw/refused.$key" ]]; then cat "$SANDBOX/gw/refused.$key"; else echo '{"input_tokens":1}'; fi ;;
  *) exit 22 ;;
esac
EOS
  chmod +x "$SANDBOX/bin/curl"
  export SANDBOX
}
# rollout <week-used%> <5h-used%> <hours-until-week-reset>
rollout() {
  local reset=$((NOW + $3 * 3600)) short=$((NOW + 3600))
  printf '{"payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n' \
    "$2" "$short" "$1" "$reset" > "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
}
# budget <file> <key|team> <spend> <max>
budget() {
  local obj='{"info":{"spend":%s,"max_budget":%s,"budget_reset_at":null,"team_id":"t1","models":["m1"]}}'
  [[ "$2" == team ]] && obj='{"team_info":{"spend":%s,"max_budget":%s,"budget_reset_at":null}}'
  # shellcheck disable=SC2059
  printf "$obj\n" "$3" "$4" > "$SANDBOX/gw/$1.json"
}

@test "sources: codex shows its plan and week, and the keys their dollars, in status --json" {
  src_setup
  week main 30 84
  rollout 1 0 84
  budget sk-lazer key 40 100
  budget sk-res key 5 20
  budget team team 40 100
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .kind <<<"$output")" = codex ]
  [ "$(field codex .plan <<<"$output")" = plus ]
  [ "$(field codex .week_used <<<"$output")" = 1 ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
  [ "$(field res .usd_used <<<"$output")" = 5 ]
  [ "$(field res .usd_max <<<"$output")" = 20 ]
  [ "$(field res .paced <<<"$output")" = false ]
  [ "$(field res .parent <<<"$output")" = lazer ]
  [ "$(field res .room.ok <<<"$output")" = true ]
  [ "$(field lazer .usd_used <<<"$output")" = 40 ]
  # the Claude row is untouched by the sources beside it
  [ "$(field main .kind <<<"$output")" = claude ]
}

@test "sources: a rollout with the week spent gives no room, reason capped" {
  src_setup
  rollout 100 40 84
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .room.ok <<<"$output")" = false ]
  [ "$(field codex .room.reason <<<"$output")" = capped ]
  run --separate-stderr "$ACCT" room --source codex
  assert_failure 1
}

@test "sources: a codex week inside its own reserve is refused for reserve, not capped" {
  src_setup
  rollout 96 0 84
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .room.ok <<<"$output")" = false ]
  [ "$(field codex .room.reason <<<"$output")" = reserve ]
}

@test "sources: the fleet line sums Claude accounts only, a codex point is another budget" {
  # 2026-11-09: codex in the sum read 1.6/h vs 1.7/h, carries ~52; Claude alone was 1.3 vs 1.15.
  src_setup
  week main 80 84   # 20 left over 84h: 0.24 an hour
  rollout 1 0 84    # codex: 99 left, 1.18 an hour, which the old sum added
  run --separate-stderr "$ACCT" status
  assert_success
  assert_line --regexp '^codex '
  assert_line --regexp '^fleet: 0 live, burn 0/h vs 0\.2/h sustainable'
}

@test "sources: the textfile publishes the fleet line's own sum, and no burn when no Claude row is read" {
  # ar-1149: hub-core burn.rs re-summed the rows with its own copy of this filter; it reads these now.
  src_setup
  export CLAUDE_ACCT_SESSION_RATE=0.1
  week main 80 84   # 20 left over 84h: 0.24 an hour
  rollout 1 0 84    # codex: 99 left, 1.18 an hour, another budget
  live "" 3
  live "$ALT" 2     # alt has no usage read: its sessions are live, its burn is not summed
  rm -f "$XDG_CACHE_HOME/claude-acct/alt.json"
  mkdir -p "$SANDBOX/prom"
  "$ACCT" textfile "$SANDBOX/prom"
  run cat "$SANDBOX/prom/claude_acct.prom"
  assert_line 'claude_account_read_ok{account="alt",kind="claude"} 0'
  assert_line 'claude_fleet_live_sessions 5'
  assert_line 'claude_fleet_session_rate_points_per_hour 0.1'
  assert_line --regexp '^claude_fleet_burn_points_per_hour 0\.3(0000|$)'
  assert_line --regexp '^claude_fleet_sustain_points_per_hour 0\.238'
  run --separate-stderr "$ACCT" status
  assert_line --regexp '^fleet: 5 live, burn 0\.3/h vs 0\.2/h sustainable'
  # negative control: with no Claude account read, live stays and burn and sustain are not written
  rm -f "$XDG_CACHE_HOME/claude-acct/main.json" "$HOME/.claude/.credentials.json"
  "$ACCT" textfile "$SANDBOX/prom"
  run cat "$SANDBOX/prom/claude_acct.prom"
  assert_line 'claude_account_read_ok{account="main",kind="claude"} 0'
  assert_line 'claude_fleet_live_sessions 5'
  refute_line --partial 'claude_fleet_burn'
  refute_line --partial 'claude_fleet_sustain'
}

@test "sources: a week whose reset has passed reads as unused" {
  src_setup
  rollout 100 0 -2
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .week_used <<<"$output")" = 0 ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
}

@test "sources: codex reads the last record with a window, past a windowless premium one" {
  src_setup
  rollout 40 10 84
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"premium","plan_type":"plus","primary":null,"secondary":null,"rate_limit_reached_type":null}}}\n' \
    >> "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .week_used <<<"$output")" = 40 ]
}

@test "sources: codex skips a newer rollout with no windowed record, and a torn last line" {
  src_setup
  rollout 40 10 84
  local d="$BATS_TEST_TMPDIR/codex/2026/11"
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}\n{"payload":{"rate_limits":{"prim' \
    > "$d/rollout-b.jsonl"
  touch -d '-1 hour' "$d/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .week_used <<<"$output")" = 40 ]
}

@test "sources: codex reads past a run of refused rollouts, however long" {
  src_setup
  rollout 40 10 84
  local d="$BATS_TEST_TMPDIR/codex/2026/11" i
  touch -d '-2 hours' "$d/rollout-a.jsonl"
  for i in $(seq 1 25); do
    printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}\n' \
      > "$d/rollout-refused-$i.jsonl"
  done
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .week_used <<<"$output")" = 40 ]
}

@test "sources: codex with no windowed record in any rollout is unread" {
  src_setup
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}\n' \
    > "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .state <<<"$output")" = unread ]
}

@test "sources: a key at its cap has no room" {
  src_setup
  budget sk-lazer key 10 100
  budget team team 10 100
  budget sk-res key 20 20
  run --separate-stderr "$ACCT" status --json
  [ "$(field res .room.ok <<<"$output")" = false ]
  [ "$(field res .room.reason <<<"$output")" = capped ]
  run --separate-stderr "$ACCT" room --source res
  assert_failure 1
}

@test "sources: a key whose parent is spent has no room, reason parent after its own" {
  src_setup
  budget sk-lazer key 100 100
  budget team team 100 100
  budget sk-res key 1 20
  run --separate-stderr "$ACCT" status --json
  [ "$(field lazer .room.ok <<<"$output")" = false ]
  [ "$(field res .room.ok <<<"$output")" = false ]
  [ "$(field res .room.reason <<<"$output")" = parent ]
  [[ "$(field res .room.why <<<"$output")" == *lazer* ]]
  # its own cap still names itself first
  budget sk-res key 20 20
  rm -f "$XDG_CACHE_HOME/claude-acct/res.json"
  run --separate-stderr "$ACCT" status --json
  [ "$(field res .room.reason <<<"$output")" = capped ]
}

@test "sources: dollar budgets carry no pace verdict, and the key never reaches argv" {
  src_setup
  budget sk-lazer key 90 100
  budget team team 90 100
  budget sk-res key 1 20
  run --separate-stderr "$ACCT" status --json
  [ "$(field lazer '.room.reasons | index("pace")' <<<"$output")" = null ]
  [ "$(field lazer .week_gone <<<"$output")" = null ]
  run grep -c 'sk-' "$SANDBOX/curl.argv"
  assert_output 0
  grep -q 'Bearer sk-res' "$SANDBOX/curl.stdin" || fail "the key did not arrive on stdin"
}

@test "sources: the textfile covers every row, dollars included" {
  src_setup
  rollout 1 0 84
  budget sk-lazer key 40 100
  budget team team 40 100
  budget sk-res key 5 20
  mkdir -p "$SANDBOX/prom"
  "$ACCT" textfile "$SANDBOX/prom"
  run cat "$SANDBOX/prom/claude_acct.prom"
  assert_line 'claude_account_room{account="codex",kind="codex"} 1'
  assert_line 'claude_account_usd_used{account="res",kind="litellm-key"} 5'
  assert_line 'claude_account_usd_budget{account="res",kind="litellm-key"} 20'
  assert_line 'claude_account_usd_used{account="lazer",kind="litellm-team"} 40'
  refute_line --regexp 'claude_account_sustain_points_per_hour.*account="(lazer|res)"'
  # what the Burn rows print beside the figures: the reserve, whether it is paced, its pool
  assert_line 'claude_account_reserve_percent{account="codex",kind="codex"} 5'
  assert_line 'claude_account_paced{account="codex",kind="codex"} 1'
  assert_line 'claude_account_paced{account="res",kind="litellm-key"} 0'
  assert_line 'claude_account_parent{account="res",kind="litellm-key",parent="lazer"} 1'
  refute_line --regexp 'claude_account_parent\{account="(codex|lazer)"'
}

@test "check pace: every source on pace is quiet; one past its line or in its reserve trips, by name" {
  src_setup
  week main 30 84
  rollout 1 0 84
  budget sk-lazer key 40 100
  budget team team 40 100
  budget sk-res key 5 20
  run --separate-stderr "$ACCT" check pace
  assert_success
  assert_output 'every source on pace (5 sources)'
  # the same sources with codex well past its weekly line and the key inside its reserve
  rollout 90 0 84
  budget sk-res key 19.5 20
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  assert_output 'over pace: codex pace, res reserve'
}

@test "check pace: no source at all is nothing read, never a quiet green" {
  src_setup
  : > "$CLAUDE_ACCT_CONFIG"
  : > "$CLAUDE_ACCT_SOURCES"
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  assert_output 'no sources read'
}

@test "check pace: an unread source trips, but a Claude account's unread is check usage's" {
  src_setup
  week main 30 84
  rollout 1 0 84
  budget team team 40 100
  budget sk-res key 5 20
  # no reply for the pool's own key: the team read fails
  creds "$ALT" 99999999999999
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  assert_output "unread: lazer"
  [[ "$output" != *alt* ]] || fail "a Claude account named: $output"
}

@test "sources: room --json keeps pick and accounts Claude-only and lists every source beside them" {
  src_setup
  week main 30 84
  week alt 80 84
  rollout 96 0 84
  budget sk-lazer key 40 100
  budget sk-res key 5 20
  budget team team 40 100
  run --separate-stderr "$ACCT" room --json
  assert_success
  [ "$(jq -r '[.accounts[].name] | join(",")' <<<"$output")" = "main,alt" ]
  [ "$(jq -r .pick <<<"$output")" = main ]
  assert_equal "$(jq -c '[.sources[] | [.name, .kind, .room.ok, .room.reason, .max_live]]' <<<"$output")" \
    '[["codex","codex",false,"reserve",null],["lazer","litellm-team",true,"ok",null],["res","litellm-key",true,"ok",2]]'
  jq -e 'all(.sources[]; .rank | type == "number")' <<<"$output"
  # the sentence form stays about the accounts
  run --separate-stderr "$ACCT" room
  assert_success
  refute_output --partial codex
}

@test "sources: an unknown kind, a bad line, and a name that is also an account are named, not rowed" {
  src_setup
  printf 'bogus  nope  /x\nmain codex /y\nbad\n' >> "$SANDBOX/sources"
  week main 30 84
  run --separate-stderr "$ACCT" status --json
  assert_success
  [[ "$stderr" == *"main is also an account"* ]] || fail "$stderr"
  [[ "$stderr" == *"unknown kind 'nope'"* ]] || fail "$stderr"
  [ "$(field bogus .state <<<"$output")" = unread ]
  run --separate-stderr "$ACCT" room --source nosuch
  assert_failure 3
}

# Reads the shipped sources file on purpose: parallel codex starts drain the Plus 5h window while the
# week is near empty, so the shipped codex row must carry a live cap.
@test "sources: the shipped codex row has room for a second live start, not a third" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SOURCES="$REPO_ROOT/.config/claude-acct/sources"
  export CLAUDE_ACCT_HARNESSES="$SANDBOX/harnesses.json"
  echo '{"gateway":{"url":"http://gw.test"},"harnesses":{"codex":{"source":"codex"}}}' > "$CLAUDE_ACCT_HARNESSES"
  mkdir -p "$HOME/.codex/sessions/2026/11"
  printf '{"payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":1,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":1,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n' \
    $((NOW + 3600)) $((NOW + 84 * 3600)) > "$HOME/.codex/sessions/2026/11/rollout-a.jsonl"
  week main 30 84
  # agent-queue answers only the call source_live makes, with n running codex items
  queue_running() {
    printf '#!/usr/bin/env bash\n[[ "$*" == "list --json --state running" ]] || exit 2\nfor i in $(seq 1 %s); do echo "{\\"slug\\":\\"c$i\\",\\"agent\\":\\"codex\\"}"; done\n' "$1" > "$SANDBOX/bin/agent-queue"
    chmod +x "$SANDBOX/bin/agent-queue"
  }
  # one live codex item: the second start has room
  queue_running 1
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .max_live <<<"$output")" = 2 ]
  [ "$(field codex .live <<<"$output")" = 1 ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
  # two live: the third waits, with weeks of allowance left
  queue_running 2
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .live <<<"$output")" = 2 ]
  [ "$(field codex .room.ok <<<"$output")" = false ]
  [ "$(field codex '.room.reasons | index("max_live") != null' <<<"$output")" = true ]
}

# refused <key> <message>: what the gateway answers that key's free budget probe
refused() { printf '{"error":{"message":"%s","type":"budget_exceeded"}}\n' "$2" > "$SANDBOX/gw/refused.$1"; }

@test "sources: a team the gateway refuses reads the spend it refused at, and is capped, under a lower recorded spend" {
  src_setup
  budget sk-lazer key 0 100
  budget team team 203.7 250
  budget sk-res key 50 100
  # Negative control: admitted, the row is the recorded spend
  run --separate-stderr "$ACCT" status --json
  [ "$(field lazer .usd_used <<<"$output")" = 203.7 ]
  [ "$(field lazer .room.capped <<<"$output")" = false ]
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  refused sk-lazer 'Budget has been exceeded! Team=t1 Current cost: 380.0063406899994, Max budget: 250.0'
  run --separate-stderr "$ACCT" status --json
  [ "$(field lazer .usd_used <<<"$output")" = 380.0063406899994 ]
  [ "$(field lazer .room.capped <<<"$output")" = true ]
  [ "$(field res .usd_used <<<"$output")" = 50 ]
  # the probe bills nothing and names a model the key may call
  grep -q 'v1/messages/count_tokens' "$SANDBOX/curl.argv"
  grep -q '"model":"m1"' "$SANDBOX/curl.argv"
  run grep -c 'sk-lazer' "$SANDBOX/curl.argv"
  assert_output 0
}

@test "sources: a refusal counts only for the budget it names" {
  src_setup
  budget sk-lazer key 0 100
  budget team team 100 250
  budget sk-res key 50 100
  # the probe key's own ceiling is not the team's, and the team's is not the key's
  refused sk-lazer 'Budget has been exceeded! Current cost: 101.5, Max budget: 100.0'
  refused sk-res 'Budget has been exceeded! Team=t1 Current cost: 380, Max budget: 250.0'
  run --separate-stderr "$ACCT" status --json
  [ "$(field lazer .usd_used <<<"$output")" = 100 ]
  [ "$(field res .usd_used <<<"$output")" = 50 ]
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  refused sk-res 'Budget has been exceeded! Current cost: 104.25, Max budget: 100.0'
  run --separate-stderr "$ACCT" status --json
  [ "$(field res .usd_used <<<"$output")" = 104.25 ]
  [ "$(field res .room.capped <<<"$output")" = true ]
}

@test "sources: a probe that cannot tell warns and keeps the recorded spend" {
  src_setup
  budget sk-lazer key 0 100
  budget team team 203.7 250
  budget sk-res key 50 100
  # Negative control: an admitted probe says nothing
  run --separate-stderr "$ACCT" status --json
  [[ "$stderr" != *"budget probe"* ]] || fail "$stderr"
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  refused sk-lazer 'key not allowed to access model m1'
  run --separate-stderr "$ACCT" status --json
  [ "$(field lazer .usd_used <<<"$output")" = 203.7 ]
  [[ "$stderr" == *"the budget probe could not tell"* ]] || fail "$stderr"
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json "$SANDBOX/gw/refused.sk-lazer"
  jq '.info.models = []' "$SANDBOX/gw/sk-lazer.json" > "$SANDBOX/gw/k" && mv "$SANDBOX/gw/k" "$SANDBOX/gw/sk-lazer.json"
  run --separate-stderr "$ACCT" status --json
  [ "$(field lazer .usd_used <<<"$output")" = 203.7 ]
  [[ "$stderr" == *"no model to run the budget probe with"* ]] || fail "$stderr"
}

@test "sources: a gateway that cannot be reached leaves the key unread, not zero" {
  src_setup
  printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin/curl"
  run --separate-stderr "$ACCT" status --json
  [ "$(field res .state <<<"$output")" = unread ]
  [ "$(field res .room.reason <<<"$output")" = unread ]
  run --separate-stderr "$ACCT" room --source res
  assert_failure 2
}

@test "sources: a name listed twice is rowed once and the repeat is named" {
  src_setup
  printf 'codex litellm-key %s/res.key\n' "$SRC" >> "$SANDBOX/sources"
  week main 30 84
  rollout 1 0 84
  budget sk-lazer key 40 100
  budget sk-res key 5 20
  budget team team 40 100
  run --separate-stderr "$ACCT" status --json
  assert_success
  [[ "$stderr" == *"codex is listed twice"* ]] || fail "$stderr"
  [ "$(jq '[.[] | select(.name == "codex")] | length' <<<"$output")" = 1 ]
  [ "$(field codex .kind <<<"$output")" = codex ]
}

@test "sources: a parent that is not a source refuses the key, naming the parent" {
  src_setup
  printf 'orphan litellm-key %s/res.key parent=nosuch\n' "$SRC" >> "$SANDBOX/sources"
  week main 30 84
  budget sk-res key 5 20
  budget sk-lazer key 40 100
  budget team team 40 100
  run --separate-stderr "$ACCT" room --source orphan
  assert_failure 1
  [[ "$output" == *"parent nosuch is not a source"* ]] || fail "$output"
  # negative control: a key whose parent exists is not refused on that account
  run --separate-stderr "$ACCT" room --source res
  assert_success
}

@test "sources: room --source reads that source and its parent, not another key or a Claude account" {
  src_setup
  echo sk-other > "$SRC/other.key"
  printf 'other litellm-key %s/other.key parent=lazer\n' "$SRC" >> "$SANDBOX/sources"
  budget sk-res key 5 20
  budget sk-lazer key 40 100
  budget team team 40 100
  run --separate-stderr "$ACCT" room --source res
  assert_success
  # the key and the parent's key, each read and probed, and the team: five calls, none for sk-other or the usage endpoint
  [ "$(wc -l < "$SANDBOX/curl.argv")" = 5 ]
  grep -q 'sk-res' "$SANDBOX/curl.stdin"
  ! grep -q 'sk-other' "$SANDBOX/curl.stdin"
  ! grep -q 'anthropic' "$SANDBOX/curl.argv"
}
