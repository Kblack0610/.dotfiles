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
  usage main 89 75 "$r1"
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

# ratelimit_curl <header lines...> -- curl answers with these response headers (CRLF, as the API
# sends them); each call appends its argv to $SANDBOX/curl.argv and its stdin (the -K config) to
# curl.stdin. The Prometheus spend query lands there too, and reads the headers as no data.
ratelimit_curl() {
  { printf '#!/usr/bin/env bash\necho "$*" >> "$SANDBOX/curl.argv"; cat >> "$SANDBOX/curl.stdin"\n'
    printf 'printf "%%s\\r\\n" "HTTP/2 200"'
    printf ' %q' "$@"
    printf '\n'; } > "$SANDBOX/bin/curl"
  chmod +x "$SANDBOX/bin/curl"
  export SANDBOX
}

@test "usage read: the setup token's rate-limit headers give the week and the 5h window" {
  rbw_stub
  vault_put claude-oauth-main "$TOK_MAIN"
  ratelimit_curl 'anthropic-ratelimit-unified-7d-utilization: 0.65' 'anthropic-ratelimit-unified-7d-reset: 1795208400' \
    'anthropic-ratelimit-unified-5h-utilization: 0.2' 'anthropic-ratelimit-unified-5h-reset: 1795100000' \
    'anthropic-ratelimit-unified-status: allowed'
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(jq -r '.[] | select(.name == "main") | "\(.state) \(.week_used) \(.five_hour) \(.resets) \(.five_hour_resets)"' <<< "$output")" = "ok 65 20 1795208400 1795100000" ]
  # the token goes in on stdin, never on the argument list
  grep -qF "$TOK_MAIN" "$SANDBOX/curl.stdin"
  ! grep -qF "$TOK_MAIN" "$SANDBOX/curl.argv"
  grep -qF 'v1/messages' "$SANDBOX/curl.argv"
}

@test "usage read: a week header alone is a fresh answer, with no 5h window, its fraction read to the point" {
  rbw_stub
  vault_put claude-oauth-main "$TOK_MAIN"
  ratelimit_curl 'anthropic-ratelimit-unified-7d-utilization: 0.29' 'anthropic-ratelimit-unified-7d-reset: 1795208400'
  run "$ACCT" status
  assert_success
  assert_line --regexp '^main +- +29%'
  refute_line --regexp '^main .*fetch failed'
}

@test "usage read: an answer with no week header (a refused call) is a failed fetch" {
  rbw_stub
  vault_put claude-oauth-main "$TOK_MAIN"
  ratelimit_curl 'content-type: application/json'
  run --separate-stderr "$ACCT" status
  assert_line --regexp '^main .*fetch failed'
  [[ ! -e "$XDG_CACHE_HOME/claude-acct/main.json" ]]
  # it says what answered, so a refused probe does not read as a dead network
  [[ "$stderr" == *"main usage read failed: HTTP/2 200"* ]]
}

@test "usage read: a call refused at the limit still reads its windows, and is capped" {
  rbw_stub
  vault_put claude-oauth-main "$TOK_MAIN"
  ratelimit_curl 'anthropic-ratelimit-unified-7d-utilization: 1.0' 'anthropic-ratelimit-unified-7d-reset: 1795208400' \
    'anthropic-ratelimit-unified-status: rejected'
  run --separate-stderr "$ACCT" status --json
  [ "$(jq -r '.[] | select(.name == "main") | "\(.state) \(.week_used) \(.reached) \(.room.reason)"' <<< "$output")" = "ok 100 true capped" ]
}

@test "a tie goes to the first account in the file" {
  usage main 40 40
  usage alt 40 40
  run --separate-stderr "$ACCT" pick
  assert_output ''
}

@test "an account whose usage cannot be read is never picked, and reads unread" {
  usage main 40 70
  # negative control: alt read at less use wins
  usage alt 10 10
  run --separate-stderr "$ACCT" pick
  assert_output "$ALT"
  # alt with no setup token and no cached answer is not read, so it is never the pick
  rm -f "$XDG_CACHE_HOME/claude-acct/alt.json"
  run --separate-stderr "$ACCT" pick
  assert_success
  assert_output ''
  run "$ACCT" status --json
  [[ "$(jq -r '.[] | select(.name == "alt") | .state' <<< "$output")" == unread ]]
}

@test "an account that never logged in is skipped, not picked" {
  usage main 90 90
  run --separate-stderr "$ACCT" pick
  assert_output ''
}

@test "no usage data at all falls back to the default account" {
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

@test "link points at the real file, one hop, so a settings write cannot replace the stow link" {
  # Claude Code follows one symlink before it renames a temp file over the target,
  # so a two-hop chain turns the middle (stow) link into a plain copy.
  mkdir -p "$HOME/.dotfiles/.claude"
  echo '{}' > "$HOME/.dotfiles/.claude/settings.json"
  ln -s ../.dotfiles/.claude/settings.json "$HOME/.claude/settings.json"
  ln -s "$HOME/.claude/settings.json" "$ALT/settings.json"   # the old two-hop link
  run "$ACCT" link
  assert_success
  [[ "$(readlink "$ALT/settings.json")" == "$(readlink -f "$HOME/.dotfiles/.claude/settings.json")" ]]
  # an old link is replaced in place, never parked
  [[ ! -e "$ALT/.pre-share-$(date +%F)" ]]
  run "$ACCT" link
  assert_output ''
}

@test "link parks an account's link to somewhere else, never overwrites it" {
  mkdir -p "$HOME/.claude/sessions" "$SANDBOX/elsewhere"
  echo alt > "$SANDBOX/elsewhere/200.json"
  ln -s "$SANDBOX/elsewhere" "$ALT/sessions"
  run "$ACCT" link
  assert_success
  [[ "$(readlink "$ALT/sessions")" == "$(readlink -f "$HOME/.claude/sessions")" ]]
  [[ "$(readlink "$ALT/.pre-share-$(date +%F)/sessions")" == "$SANDBOX/elsewhere" ]]
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


@test "link marks first-run done in every account and touches no other key" {
  # A worker's account dirs start empty; without the flag Claude opens on its theme picker
  # and a session nobody watches sits there (27 on razer-laptop, 2026-11-18).
  printf '{"oauthAccount":{"emailAddress":"a@b"},"projects":{"/x":{"hasTrustDialogAccepted":true}},"numStartups":3}\n' > "$HOME/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"c@d"},"hasCompletedOnboarding":false}\n' > "$ALT/.claude.json"
  local before_main before_alt
  before_main=$(jq -S . "$HOME/.claude.json")
  before_alt=$(jq -S 'del(.hasCompletedOnboarding)' "$ALT/.claude.json")
  run "$ACCT" link
  assert_success
  [[ "$(jq '.hasCompletedOnboarding' "$HOME/.claude.json")" == true ]]
  [[ "$(jq '.hasCompletedOnboarding' "$ALT/.claude.json")" == true ]]
  [[ "$(jq -S 'del(.hasCompletedOnboarding)' "$HOME/.claude.json")" == "$before_main" ]]
  [[ "$(jq -S 'del(.hasCompletedOnboarding)' "$ALT/.claude.json")" == "$before_alt" ]]
  # a rerun writes nothing
  local stamp; stamp=$(stat -c %Y.%i "$ALT/.claude.json")
  run "$ACCT" link
  assert_output ''
  [[ "$(stat -c %Y.%i "$ALT/.claude.json")" == "$stamp" ]]
}

@test "link gives an account with no config yet one that has first-run done, and leaves a broken one alone" {
  printf 'not json' > "$HOME/.claude.json"
  run "$ACCT" link
  assert_success
  [[ "$(jq -c . "$ALT/.claude.json")" == '{"hasCompletedOnboarding":true}' ]]
  [[ "$(cat "$HOME/.claude.json")" == 'not json' ]]
  assert_output --partial 'first-run left as is'
}

@test "link marks first-run done through a symlinked config and in an empty one" {
  printf '{"numStartups":1}\n' > "$SANDBOX/real.json"
  ln -s "$SANDBOX/real.json" "$HOME/.claude.json"
  : > "$ALT/.claude.json"
  run "$ACCT" link
  assert_success
  [[ -L "$HOME/.claude.json" ]]
  [[ "$(jq -c . "$SANDBOX/real.json")" == '{"numStartups":1,"hasCompletedOnboarding":true}' ]]
  [[ "$(jq -c . "$ALT/.claude.json")" == '{"hasCompletedOnboarding":true}' ]]
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

@test "status --json: a failed read says so instead of a number" {
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field main .state <<<"$output")" = unread ]
  [ "$(field main .week_used <<<"$output")" = null ]
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

@test "an idle or waiting session is live but burns nothing; busy, shell and unregistered ones work" {
  # 2026-11-11 (ar-1682): max4 carried 27 claudes, 11 of them idle, and its burn read 1.4/h against
  # a measured 1.0/h; bnb read committed only through its idle and waiting ones, and dispatch stopped.
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_PROC="$SANDBOX/proc" CLAUDE_ACCT_SESSION_RATE=0.1
  week main 50 50
  week alt 50 50   # 1 point an hour to spare
  mkdir -p "$HOME/.claude/sessions"
  local p
  for p in 1:idle 2:waiting 3:busy 4:shell 5:none 6:idle 7:idle 8:idle 9:idle 10:idle 11:idle 12:idle; do
    IFS=: read -r pid st <<<"$p"
    mkdir -p "$SANDBOX/proc/$pid"
    echo claude > "$SANDBOX/proc/$pid/comm"
    printf 'CLAUDE_CONFIG_DIR=%s\0' "$ALT" > "$SANDBOX/proc/$pid/environ"
    # the registry writes compact JSON; pid 2 is spaced, which the match allows too
    [ "$st" = none ] || printf '{"pid":%s,"kind":"interactive","status":%s"%s","updatedAt":1}\n' "$pid" "$([ "$pid" = 2 ] && echo ' ')" "$st" > "$HOME/.claude/sessions/$pid.json"
  done
  run --separate-stderr "$ACCT" status --json
  [ "$(field alt .live <<<"$output")" = 12 ]
  [ "$(field alt .working <<<"$output")" = 3 ]
  [ "$(field alt '.burn * 10 | round' <<<"$output")" = 3 ]
  [ "$(field alt .room.ok <<<"$output")" = true ]
  # counted live, 12 x 0.1 would read committed
  for p in 1 2 6 7 8 9 10 11 12; do sed -i -E 's/"status": ?"[a-z]*"/"status":"busy"/' "$HOME/.claude/sessions/$p.json"; done
  run --separate-stderr "$ACCT" status --json
  [ "$(field alt .working <<<"$output")" = 12 ]
  [ "$(field alt .room.reason <<<"$output")" = committed ]
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
  mkdir -p "$SANDBOX/tf"
  rm -f "$XDG_CACHE_HOME/claude-acct/alt.json"
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
  [[ "$stderr" == *'working sessions use the rest of its week before the reset'* ]]
  # a hand start is told, never refused
  run --separate-stderr "$ACCT" pick
  assert_success
}

@test "the session rate comes from Prometheus, is cached, falls back when unreadable, and a pick never asks" {
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *working_sessions*) echo '{"status":"success","data":{"result":[{"metric":{},"value":[0,"0.25"]}]}}' ;; *) exit 22 ;; esac
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
  run grep -cF 'avg_over_time((max by (account) (claude_account_working_sessions{account="codex"}))[6h:5m]) and on (account)' "$SANDBOX/prom.args"
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
  assert_equal "$stderr" 'claude-acct: no account has room; main is the closest, 96% of its week used, inside the last 10% kept for the human, lasts to its reset Fri 10:00'
}

@test "room: with none, an account refused while within its weekly pace is named too, not only the closest" {
  # 2026-11-10 01:24: the line named bnb, over its pace, and never max4, 15% used with 38% of its week
  # gone, refused because its 13 live sessions at the fleet's 0.072 an hour emptied it before the reset.
  export CLAUDE_ACCT_NOW=$NOW TZ=UTC CLAUDE_ACCT_SESSION_RATE=0.072
  week main 77 65    # 61% gone, 11 points past the line, no live sessions: the closest
  week alt 15 104    # 38% gone, under its line
  live "$ALT" 13
  run --separate-stderr "$ACCT" room
  assert_failure 1
  assert_equal "$stderr" 'claude-acct: no account has room; main is the closest, 11 points over its weekly pace (77% used, 61% of its week gone, 5 points of slack), lasts to its reset Mon 01:00; alt is within its weekly pace but its 13 working sessions use the rest of its week before the reset, runs out Tue 02:48 at this rate'
  # an account over its pace is not named again: the closest already says what pace refuses
  rm -rf "${CLAUDE_ACCT_PROC:?}"/*
  # its 5h window alone: named, with no week clock, which is not what refuses it
  week alt 15 104
  printf '%s' "$(jq -c '.five_hour = {utilization: 97}' "$XDG_CACHE_HOME/claude-acct/alt.json")" > "$XDG_CACHE_HOME/claude-acct/alt.json"
  run --separate-stderr "$ACCT" room
  assert_failure 1
  assert_equal "$stderr" 'claude-acct: no account has room; main is the closest, 11 points over its weekly pace (77% used, 61% of its week gone, 5 points of slack), lasts to its reset Mon 01:00; alt is within its weekly pace but its 5h window at 97%'
  week alt 80 104
  run --separate-stderr "$ACCT" room
  assert_failure 1
  assert_equal "$stderr" 'claude-acct: no account has room; main is the closest, 11 points over its weekly pace (77% used, 61% of its week gone, 5 points of slack), lasts to its reset Mon 01:00'
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
  [[ "$stderr" == *'94% of its week used, inside the last 13% kept for the human'* ]] || fail "$stderr"
}

@test "room: the reserve holds late in the week, even under pace" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 90 2
  week alt 97 2
  run --separate-stderr "$ACCT" room
  assert_failure 1
  week main 89 2
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

@test "room: a failed read with no room elsewhere is exit 2" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 70 84
  run --separate-stderr "$ACCT" room
  assert_failure 2
}

@test "room: one account unread does not stop a start on the other" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 10 84
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
  run "$ACCT" check usage
  assert_failure 1
  assert_output 'cannot read usage of alt'
  week alt 30 84
  run "$ACCT" check usage
  assert_success
  assert_output 'usage read on 2 accounts'
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

@test "status: the fleet line sums live, burn and what the pool carries, says when it runs into the reserve, and names the first back on pace" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 80 84
  week alt 80 84
  live "" 10
  live "$ALT" 10
  run "$ACCT" status
  assert_success
  assert_line --partial 'after-reset'
  # 10 points above the reserve on each, both reset in 84h: 20 over 84h is 0.24 an hour, under the
  # 90 a week each gives for good; at 2 an hour the pool is into the reserve in 10h, before the resets
  assert_line --regexp '^fleet: 20 live \(20 working\), burn 2/h vs 0\.2/h sustainable \(8\.4x, carries ~2\), into the reserve [A-Z][a-z]{2} [0-9]{2}:[0-9]{2} before the resets, back on pace: not at this burn; if idle (main|alt) '
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

@test "room --json: fleet carries the sessions the pool sustains at pace, the same figure as the status line" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 80 84
  week alt 80 84
  live "" 10
  live "$ALT" 10
  run --separate-stderr "$ACCT" room --json
  # the status line's "carries ~2": 0.24 an hour over 0.1 a session
  assert_equal "$(jq -c '[.fleet.carries, .fleet.rate]' <<<"$output")" '[2,0.1]'
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
  [[ "$(field main .room.why <<< "$output")" == '97% of its week used, inside the last 10% kept for the human' ]]
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
  [[ "$(field main .room.reserve <<< "$output")" == 10 ]]
  run grep -nE 'CLAUDE_ACCT_(PACE_SLACK|RESERVE)_PCT:-' "$ACCT"
  assert_failure
}

@test "room --json: exit codes match room, an unread account is not a room verdict, and a window at the reserve refuses" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 10 84
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
# codex_log [-a] <rollout file> [epoch] -- write (or append) stdin to a rollout stamped at that time
# ($NOW by default), since only rollouts written within the week of now are read, and drop the
# cached codex reading.
codex_log() {
  local append=; [[ "$1" == -a ]] && { append=1; shift; }
  if [[ -n "$append" ]]; then cat >> "$1"; else cat > "$1"; fi
  touch -d "@${2:-$NOW}" "$1"
  rm -f "$XDG_CACHE_HOME/claude-acct/codex.json"
}
# codex_refused <file> <epoch> -- a run refused at the usage limit at that time, in the shape of the
# real one of 2026-11-08 16:18: a windowless record, then a task_complete whose error carries
# codex_error_info usage_limit_exceeded
codex_refused() {
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","limit_name":null,"primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":null,"rate_limit_reached_type":null}}}\n{"timestamp":"%s","type":"event_msg","payload":{"type":"task_complete","last_agent_message":null,"error":{"message":"You have hit your usage limit.","codex_error_info":"usage_limit_exceeded"},"started_at":%s,"completed_at":%s,"duration_ms":1673}}\n' \
    "$(date -u -d "@$2" +%FT%T.000Z)" "$(date -u -d "@$2" +%FT%T.000Z)" "$2" "$2" | codex_log "$1" "$2"
}
# rollout <week-used%> <5h-used%> <hours-until-week-reset>
rollout() {
  local reset=$((NOW + $3 * 3600)) short=$((NOW + 3600))
  printf '{"payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n' \
    "$2" "$short" "$1" "$reset" | codex_log "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
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
  week main 80 84   # 10 above the reserve over 84h: 0.12 an hour
  rollout 1 0 84    # codex: 99 left, 1.18 an hour, which the old sum added
  run --separate-stderr "$ACCT" status
  assert_success
  assert_line --regexp '^codex '
  assert_line --regexp '^fleet: 0 live \(0 working\), burn 0/h vs 0\.1/h sustainable .*, lasts to the resets, '
}

@test "sources: the textfile publishes the fleet line's own sum, and no burn when no Claude row is read" {
  # ar-1149: hub-core burn.rs re-summed the rows with its own copy of this filter; it reads these now.
  src_setup
  export CLAUDE_ACCT_SESSION_RATE=0.1
  week main 80 84   # 10 above the reserve over 84h: 0.12 an hour
  rollout 1 0 84    # codex: 99 left, 1.18 an hour, another budget
  live "" 3
  live "$ALT" 2     # alt has no usage read: its sessions are live, its burn is not summed
  rm -f "$XDG_CACHE_HOME/claude-acct/alt.json"
  mkdir -p "$SANDBOX/prom"
  "$ACCT" textfile "$SANDBOX/prom"
  run cat "$SANDBOX/prom/claude_acct.prom"
  assert_line 'claude_account_read_ok{account="alt",kind="claude"} 0'
  assert_line 'claude_fleet_live_sessions 5'
  assert_line 'claude_fleet_working_sessions 5'
  assert_line 'claude_account_working_sessions{account="main",kind="claude"} 3'
  assert_line 'claude_fleet_session_rate_points_per_hour 0.1'
  assert_line --regexp '^claude_fleet_burn_points_per_hour 0\.3(0000|$)'
  assert_line --regexp '^claude_fleet_sustain_points_per_hour 0\.119'
  # 10 points at 0.3 an hour: 33.3h, before main's reset in 84h
  assert_line 'claude_fleet_run_out_timestamp_seconds 1800120000'
  run --separate-stderr "$ACCT" status
  assert_line --regexp '^fleet: 5 live \(5 working\), burn 0\.3/h vs 0\.1/h sustainable'
  # negative control: with no Claude account read, live stays and burn and sustain are not written
  rm -f "$XDG_CACHE_HOME/claude-acct/main.json"
  "$ACCT" textfile "$SANDBOX/prom"
  run cat "$SANDBOX/prom/claude_acct.prom"
  assert_line 'claude_account_read_ok{account="main",kind="claude"} 0'
  assert_line 'claude_fleet_live_sessions 5'
  refute_line --partial 'claude_fleet_burn'
  refute_line --partial 'claude_fleet_sustain'
  refute_line --partial 'claude_fleet_run_out'
}

@test "sources: a week whose reset has passed reads as unused" {
  src_setup
  rollout 100 0 -2
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .week_used <<<"$output")" = 0 ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
}

# The shape of a real Pro rollout (2026-11-09 12:29, plan_type prolite): the week is primary and
# there is no 5h window. pro_rollout <week-used%> <hours-until-week-reset> [window minutes]
pro_rollout() {
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":%s,"window_minutes":%s,"resets_at":%s},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"prolite","rate_limit_reached_type":null}}}\n' \
    "$1" "${3:-10080}" "$((NOW + $2 * 3600))" | codex_log "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
}

@test "sources: a Pro rollout's primary week reads as the week, with no 5h window" {
  src_setup
  pro_rollout 30 84
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .plan <<<"$output")" = prolite ]
  [ "$(field codex .week_used <<<"$output")" = 30 ]
  [ "$(field codex .five_hour <<<"$output")" = null ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
  # negative control: past its pace line, the week is paced (before, it sat under 5H, never paced)
  pro_rollout 90 84
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .room.ok <<<"$output")" = false ]
  [ "$(field codex '.room.reasons | index("pace") != null' <<<"$output")" = true ]
}

@test "sources: a codex window of a length it does not know is unread, not guessed" {
  src_setup
  pro_rollout 30 84 1440
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .state <<<"$output")" = unread ]
  [ "$(field codex .room.ok <<<"$output")" = false ]
}

@test "sources: a codex week logged as 10081 minutes is still the week" {
  src_setup
  pro_rollout 30 84 10081
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .week_used <<<"$output")" = 30 ]
}

@test "sources: a codex window with no length is unread, and the stderr names it" {
  src_setup
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":10,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":40,"resets_at":%s}}}}\n' \
    "$((NOW + 3600))" "$((NOW + 84 * 3600))" | codex_log "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .state <<<"$output")" = unread ]
  [[ "$stderr" == *"unknown length [300,null]"* ]]
}

@test "sources: a codex record with only a 5h window has no week reading" {
  src_setup
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":20,"window_minutes":300,"resets_at":%s},"secondary":null}}}\n' \
    "$((NOW + 3600))" | codex_log "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .five_hour <<<"$output")" = 20 ]
  [ "$(field codex .week_used <<<"$output")" = null ]
}

@test "sources: a windowed record of another limit_id is not the plan's usage" {
  src_setup
  rollout 40 10 84
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"premium","plan_type":"plus","primary":{"used_percent":95,"window_minutes":300,"resets_at":%s},"secondary":null,"rate_limit_reached_type":null}}}\n' \
    "$((NOW + 3600))" | codex_log -a "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .week_used <<<"$output")" = 40 ]
  [ "$(field codex .five_hour <<<"$output")" = 10 ]
}

@test "sources: codex reads the last record with a window, past a windowless premium one" {
  src_setup
  rollout 40 10 84
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"premium","plan_type":"plus","primary":null,"secondary":null,"rate_limit_reached_type":null}}}\n' \
    | codex_log -a "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
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
    | codex_log "$d/rollout-b.jsonl"
  touch -d "@$((NOW - 3600))" "$d/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .week_used <<<"$output")" = 40 ]
}

@test "sources: codex reads past a run of windowless rollouts, however long" {
  src_setup
  rollout 40 10 84
  local d="$BATS_TEST_TMPDIR/codex/2026/11" i
  touch -d "@$((NOW - 7200))" "$d/rollout-a.jsonl"
  for i in $(seq 1 25); do
    printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}\n' \
      | codex_log "$d/rollout-windowless-$i.jsonl"
  done
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .week_used <<<"$output")" = 40 ]
}

@test "sources: codex with no windowed record in any rollout is unread" {
  src_setup
  printf '{"payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}\n' \
    | codex_log "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .state <<<"$output")" = unread ]
}

@test "sources: codex reads only rollouts of the last week, and an idle one reads unused" {
  src_setup
  rollout 40 10 84
  local f="$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  touch -d "@$((NOW - 604800 - 60))" "$f"
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .week_used <<<"$output")" = 0 ]
  [ "$(field codex .plan <<<"$output")" = null ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
  # negative control: the same rollout a minute inside the week is read
  touch -d "@$((NOW - 604800 + 60))" "$f"
  rm -f "$XDG_CACHE_HOME/claude-acct/codex.json"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .week_used <<<"$output")" = 40 ]
}

@test "sources: codex with no sessions dir is unread" {
  src_setup
  rm -rf "$BATS_TEST_TMPDIR/codex"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .state <<<"$output")" = unread ]
}

@test "sources: a refusal newer than the reading fills the 5h window until its reset" {
  src_setup
  rollout 40 10 84
  local d="$BATS_TEST_TMPDIR/codex/2026/11"
  touch -d "@$((NOW - 7200))" "$d/rollout-a.jsonl"
  codex_refused "$d/rollout-b.jsonl" $((NOW - 3600))
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .five_hour <<<"$output")" = 100 ]
  [ "$(field codex .five_hour_resets <<<"$output")" = $((NOW + 3600)) ]
  [ "$(field codex .week_used <<<"$output")" = 40 ]
  [ "$(field codex .reached <<<"$output")" = true ]
  [ "$(field codex .room.reason <<<"$output")" = capped ]
  # negative control: a refusal older than the reading changes nothing
  codex_refused "$d/rollout-b.jsonl" $((NOW - 3 * 3600))
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .five_hour <<<"$output")" = 10 ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
}

@test "sources: a codex refusal holds until its window can reset, then the next run is the probe" {
  src_setup
  rollout 40 10 84                       # the 5h window resets at NOW+1h
  local d="$BATS_TEST_TMPDIR/codex/2026/11"
  touch -d "@$((NOW - 7200))" "$d/rollout-a.jsonl"
  codex_refused "$d/rollout-b.jsonl" $((NOW - 3600))
  # past that reset, the refusal is spent and the window reads unused
  CLAUDE_ACCT_NOW=$((NOW + 7200)) run --separate-stderr "$ACCT" status --json
  [ "$(field codex .five_hour <<<"$output")" = 0 ]
  [ "$(field codex .reached <<<"$output")" = false ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
  # refused again after that reset: no logged reset follows it, so it holds one 5h window
  codex_refused "$d/rollout-b.jsonl" $((NOW + 5400))
  CLAUDE_ACCT_NOW=$((NOW + 7200)) run --separate-stderr "$ACCT" status --json
  [ "$(field codex .five_hour <<<"$output")" = 100 ]
  [ "$(field codex .five_hour_resets <<<"$output")" = $((NOW + 5400 + 18000)) ]
  [ "$(field codex .room.reason <<<"$output")" = capped ]
}

@test "sources: a Pro refusal holds the week, its only window" {
  src_setup
  pro_rollout 60 84
  local d="$BATS_TEST_TMPDIR/codex/2026/11"
  touch -d "@$((NOW - 7200))" "$d/rollout-a.jsonl"
  codex_refused "$d/rollout-b.jsonl" $((NOW - 3600))
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .week_used <<<"$output")" = 100 ]
  [ "$(field codex .five_hour <<<"$output")" = null ]
  [ "$(field codex .room.reason <<<"$output")" = capped ]
}

@test "sources: codex refusals with no reading in the week read reached, not unread" {
  src_setup
  codex_refused "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl" $((NOW - 600))
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .reached <<<"$output")" = true ]
  [ "$(field codex .week_used <<<"$output")" = null ]
  [ "$(field codex .room.reason <<<"$output")" = capped ]
}

@test "sources: codex refusals with no reading lapse after the shortest window, and an undated one is unread" {
  src_setup
  codex_refused "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl" $((NOW - 5 * 3600 - 60))
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .reached <<<"$output")" = false ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
  # a refusal Codex logged with no time cannot be held to any reset, so it blocks
  printf '{"payload":{"type":"task_complete","error":{"codex_error_info":"usage_limit_exceeded"}}}\n' \
    | codex_log "$BATS_TEST_TMPDIR/codex/2026/11/rollout-b.jsonl"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .state <<<"$output")" = unread ]
  [[ "$stderr" == *"a refusal with no time"* ]]
}

@test "sources: a codex refusal in an older file still counts when it is newer than the reading" {
  # Two concurrent runs: A is refused at NOW-1h and stops; B logged its last reading at NOW-2h and
  # kept writing other events, so its file is the newer one.
  src_setup
  local d="$BATS_TEST_TMPDIR/codex/2026/11"
  codex_refused "$d/rollout-a.jsonl" $((NOW - 3600))
  printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":10,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n{"timestamp":"x","payload":{"type":"agent_message"}}\n' \
    "$(date -u -d "@$((NOW - 7200))" +%FT%T.000Z)" $((NOW + 3600)) $((NOW + 84 * 3600)) | codex_log "$d/rollout-b.jsonl" $((NOW - 600))
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .five_hour <<<"$output")" = 100 ]
  [ "$(field codex .room.reason <<<"$output")" = capped ]
}

@test "sources: a torn last line does not hide the codex reading before it" {
  src_setup
  rollout 40 10 84
  printf '{"payload":{"rate_limits":{"prim' | codex_log -a "$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .state <<<"$output")" = ok ]
  [ "$(field codex .week_used <<<"$output")" = 40 ]
}

@test "sources: a codex sessions tree that cannot be listed is unread, never idle" {
  src_setup
  local d="$BATS_TEST_TMPDIR/codex/2026/11"
  rollout 40 10 84
  chmod 000 "$d"
  run --separate-stderr "$ACCT" status --json
  chmod 755 "$d"
  [ "$(field codex .state <<<"$output")" = unread ]
}

@test "sources: the codex reading is cached for the TTL like every other kind" {
  src_setup
  rollout 40 10 84
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .week_used <<<"$output")" = 40 ]
  # a newer rollout behind the cache's back is not read until the cache is older than the TTL
  local f="$BATS_TEST_TMPDIR/codex/2026/11/rollout-a.jsonl"
  sed -i 's/"used_percent":40/"used_percent":70/' "$f"
  touch -d "@$NOW" "$f"    # sed restamps it at the real time, outside the week of $NOW
  run --separate-stderr "$ACCT" status --json
  [ "$(field codex .week_used <<<"$output")" = 40 ]
  CLAUDE_ACCT_TTL=0 run --separate-stderr "$ACCT" status --json
  [ "$(field codex .week_used <<<"$output")" = 70 ]
}

@test "sources: a codex refusal dated after the cached reading is read at once; a newer reading or an older refusal waits for the TTL" {
  src_setup
  rollout 40 10 84
  run --separate-stderr "$ACCT" room --source codex
  assert_success
  # codex_log drops the cache, so each step puts the 40% one back, dated by $NOW rather than the
  # wall clock; from here a fresh read refuses (the week reads 100%), so only the cache says room
  local cache="$XDG_CACHE_HOME/claude-acct/codex.json" d="$BATS_TEST_TMPDIR/codex/2026/11"
  cp "$cache" "$BATS_TEST_TMPDIR/codex-cache"
  keep_cache() { cp "$BATS_TEST_TMPDIR/codex-cache" "$cache"; touch -d "@$((NOW - 60))" "$cache"; }
  sed -i 's/"used_percent":40/"used_percent":100/' "$d/rollout-a.jsonl"; touch -d "@$NOW" "$d/rollout-a.jsonl"
  keep_cache
  CLAUDE_ACCT_TTL=999999999 run --separate-stderr "$ACCT" room --source codex
  assert_success
  # a file written since the cache whose refusal is older than it keeps the cache
  codex_refused "$d/rollout-c.jsonl" $((NOW - 120)); touch -d "@$NOW" "$d/rollout-c.jsonl"; keep_cache
  CLAUDE_ACCT_TTL=999999999 run --separate-stderr "$ACCT" room --source codex
  assert_success
  # a refusal after it does not: the next start reads the source again and is refused
  codex_refused "$d/rollout-d.jsonl" $((NOW + 1)); keep_cache
  CLAUDE_ACCT_TTL=999999999 run --separate-stderr "$ACCT" room --source codex
  assert_failure 1
}

@test "sources: two rows on one Codex plan split it by reserve, and room --source --json prints the row" {
  src_setup
  printf 'codex-core codex %s/codex reserve=5\n' "$SRC" >> "$SANDBOX/sources"
  sed -i '/^codex /s/reserve=5/reserve=30/' "$SANDBOX/sources"
  grep -q '^codex .*reserve=30' "$SANDBOX/sources" || fail "fixture: the codex row did not take reserve=30"
  rollout 75 10 84
  run --separate-stderr "$ACCT" room --source codex --json
  assert_failure 1
  jq -e '.name == "codex" and (.room.reasons | index("reserve"))' <<<"$output" >/dev/null || fail "codex at 75% is not held by its 30% reserve: $output"
  run --separate-stderr "$ACCT" room --source codex-core --json
  jq -e '.name == "codex-core" and (.room.reasons | index("reserve") | not)' <<<"$output" >/dev/null || fail "codex-core at 75% is held by a reserve: $output"
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

@test "check underuse: a paced source near its reset with its use far under the week gone trips; far from the reset, or near pace, it is quiet" {
  src_setup
  week main 30 84
  budget sk-lazer key 40 100
  budget team team 40 100
  budget sk-res key 5 20
  # 84h left: half the week gone, 10% used, but the reset is far off
  rollout 10 0 84
  run --separate-stderr "$ACCT" check underuse codex
  assert_success
  assert_output 'no source under-used near its reset (1 sources)'
  # 24h left, 85% of the week gone, 10% used: the rest is lost at the reset
  rollout 10 0 24
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  run --separate-stderr "$ACCT" check underuse codex
  assert_failure 1
  assert_output 'under-used near its reset: codex 10% used, 85% of its week gone, resets in 24h'
  # dollar budgets are not paced, so the default set is codex alone
  run --separate-stderr "$ACCT" check underuse
  assert_failure 1
  assert_output --partial 'codex 10% used'
  # 24h left and 70% used: within UNDERUSE_GAP_PCT of the week gone
  rollout 70 0 24
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  run --separate-stderr "$ACCT" check underuse codex
  assert_success
  # a reset already past reads as a fresh window with no reset (the codex source), so nothing is lost
  rollout 10 0 -1
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  run --separate-stderr "$ACCT" check underuse codex
  assert_success
  # a name that is no paced source is nothing read; a missing number stops the check
  run --separate-stderr "$ACCT" check underuse lazer
  assert_failure 1
  assert_output 'not a paced source: lazer'
  grep -v '^UNDERUSE_HOURS=' "$REPO_ROOT/.config/claude-acct/pace.conf" > "$SANDBOX/pace.conf"
  CLAUDE_ACCT_PACE_CONF="$SANDBOX/pace.conf" run --separate-stderr "$ACCT" check underuse codex
  assert_failure 2
  [[ "$stderr" == *'UNDERUSE_HOURS is not set to a number'* ]] || fail "$stderr"
}

@test "check pace: a source marked alert=off (a test pool) never trips it, and dispatch still keeps to its room" {
  src_setup
  week main 30 84
  rollout 1 0 84
  budget sk-lazer key 40 100
  budget team team 40 100
  # the key deep in its reserve
  budget sk-res key 19.5 20
  sed -i 's/parent=lazer max_live=2$/parent=lazer max_live=2 alert=off/' "$CLAUDE_ACCT_SOURCES"
  run --separate-stderr "$ACCT" check pace
  assert_success
  assert_output 'every source on pace (5 sources)'
  [[ -z "$stderr" ]] || fail "$stderr"
  run --separate-stderr "$ACCT" room --json
  assert_success
  [[ "$(jq -r '.sources[] | select(.name == "res") | "\(.room.reason) \(.alert)"' <<< "$output")" == "reserve false" ]] || fail "$output"
  # a key that cannot be read still trips: muting low is not muting broken
  rm "$SANDBOX/gw/sk-res.json"
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  assert_output 'unread: res'
  budget sk-res key 19.5 20
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  # a value other than on or off is named, and the source trips again
  sed -i 's/alert=off$/alert=maybe/' "$CLAUDE_ACCT_SOURCES"
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  [[ "$stderr" == *"res: unknown option 'alert=maybe'"* ]] || fail "$stderr"
}

@test "check pace: the shipped sources alert on the lazer-core team and mute the lazer-pool test pool" {
  # A capped lazer-core team 429s every key in it (the classifier, knowledge-engine), so it must trip.
  run grep -E '^core +litellm-team ' "$REPO_ROOT/.config/claude-acct/sources"
  assert_success
  [[ "$output" != *alert=off* ]] || fail "$output"
  run grep -E '^lazer +litellm-team ' "$REPO_ROOT/.config/claude-acct/sources"
  assert_success
  [[ "$output" == *alert=off* ]] || fail "$output"
}

@test "check pace: a team source with no alert=off trips inside its reserve, and trips on nothing else" {
  src_setup
  week main 30 84
  rollout 1 0 84
  budget sk-lazer key 95 100
  budget team team 95 100
  budget sk-res key 5 20
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  [[ "$output" == *"over pace: "*"lazer reserve"* ]] || fail "$output"
  budget sk-lazer key 40 100
  budget team team 40 100
  rm -f "$XDG_CACHE_HOME"/claude-acct/*.json
  week main 30 84
  run --separate-stderr "$ACCT" check pace
  assert_success
}

@test "check pace: the Claude accounts are one pool, so one past its own line trips nothing while the pool lasts to the resets" {
  # 2026-11-10 (ar-1529): main, alt and bnb past their own lines kept the watch red for days while
  # the four weeks, each refilled at its reset, carried the fleet's burn.
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 81 50   # 70% of its week gone: past its line
  week alt 93 27    # inside its reserve
  live "" 1
  live "$ALT" 1
  run --separate-stderr "$ACCT" check pace
  assert_success
  assert_output 'every source on pace (2 sources)'
  # dispatch still keeps to each account's own room
  run --separate-stderr "$ACCT" room --json
  [[ "$(field main .room.reason <<< "$output") $(field alt .room.reason <<< "$output")" == "pace reserve" ]] || fail "$output"
  # 9 points above the reserve at 1 an hour last 9h, before alt's reset in 27h: that trips
  live "" 4
  live "$ALT" 4
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  assert_output --regexp '^the Claude accounts run into the reserve [A-Z][a-z]{2} [0-9]{2}:[0-9]{2}, before the resets$'
}

@test "check pace: a cached read from before its reset counts a fresh week once, not its old left as well" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 81 50    # 9 above the reserve, resets in 50h
  week alt 40 -1     # read before its reset an hour ago: fresh now, 90 above the reserve
  live "" 13
  live "$ALT" 12     # 2.5 an hour: 99 points last 39.6h, short of main's reset in 50h
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  assert_output --regexp '^the Claude accounts run into the reserve '
  # negative control: at 1 an hour the 99 points last past main's reset, and the 189 after it past alt's
  rm -rf "$CLAUDE_ACCT_PROC"/*
  live "" 5
  live "$ALT" 5
  run --separate-stderr "$ACCT" check pace
  assert_success
}

@test "check pace: the pool keeps the machine-mode level's reserve, as each room does" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SESSION_RATE=0.1
  week main 85 20    # 5 above the mid reserve, 2 above the reserved level's 13
  week alt 90 100
  live "" 3          # 0.3 an hour: 5 points last 16.7h, 2 last 6.7h; main resets in 20h
  live "$ALT" 0
  echo MACHINE_MODE=full > "$HOME/.agent/machine-mode.env"   # high: 7 kept back, 11 points last 36.7h
  run --separate-stderr "$ACCT" check pace
  assert_success
  echo MACHINE_MODE=reserved > "$HOME/.agent/machine-mode.env"
  run --separate-stderr "$ACCT" check pace
  assert_failure 1
  assert_output --regexp '^the Claude accounts run into the reserve '
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

# Reads the shipped sources file on purpose: parallel codex starts drain a plan window, so the shipped
# codex row must carry a live cap. The number is provisional (rules.jsonl), so this reads it.
@test "sources: the shipped codex row caps live starts at its max_live" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_SOURCES="$REPO_ROOT/.config/claude-acct/sources"
  export CLAUDE_ACCT_HARNESSES="$SANDBOX/harnesses.json"
  echo '{"gateway":{"url":"http://gw.test"},"harnesses":{"codex":{"source":"codex"}}}' > "$CLAUDE_ACCT_HARNESSES"
  mkdir -p "$HOME/.codex/sessions/2026/11"
  printf '{"payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":1,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":1,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n' \
    $((NOW + 3600)) $((NOW + 84 * 3600)) | codex_log "$HOME/.codex/sessions/2026/11/rollout-a.jsonl"
  week main 30 84
  # agent-queue answers only the call source_live makes, with n running codex items
  queue_running() {
    printf '#!/usr/bin/env bash\n[[ "$*" == "list --json --state running" ]] || exit 2\nfor i in $(seq 1 %s); do echo "{\\"slug\\":\\"c$i\\",\\"agent\\":\\"codex\\"}"; done\n' "$1" > "$SANDBOX/bin/agent-queue"
    chmod +x "$SANDBOX/bin/agent-queue"
  }
  queue_running 1
  run --separate-stderr "$ACCT" status --json
  assert_success
  cap=$(field codex .max_live <<<"$output")
  [[ "$cap" =~ ^[1-9][0-9]*$ ]]
  # one under the cap: the next start has room
  queue_running $((cap - 1))
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .live <<<"$output")" = $((cap - 1)) ]
  [ "$(field codex .room.ok <<<"$output")" = true ]
  # at the cap: the next start waits, with weeks of allowance left
  queue_running "$cap"
  run --separate-stderr "$ACCT" status --json
  assert_success
  [ "$(field codex .live <<<"$output")" = "$cap" ]
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

# gw_setup -- src_setup with a viewer key, a gateway config, and a gateway that answers the team and
# key lists in the live shape: a key object carries its secret (token, key_name) beside the fields kept.
gw_setup() {
  src_setup
  echo sk-viewer > "$SRC/viewer.key"
  jq --arg r "$SRC/viewer.key" '.gateway.reader_key_file = $r' "$CLAUDE_ACCT_HARNESSES" > "$SRC/h.json" && mv "$SRC/h.json" "$CLAUDE_ACCT_HARNESSES"
  printf 'codex codex %s/codex reserve=30 priority=low\ncore litellm-team %s/lazer.key\nres litellm-key %s/res.key parent=core\n' "$SRC" "$SRC" "$SRC" > "$CLAUDE_ACCT_SOURCES"
  cat > "$SRC/litellm.yaml" <<'EOS'
router_settings:
  model_group_alias: {fast: "fast (gpt-oss-120b)"}
  fallbacks:
    - {"fast (gpt-oss-120b)": ["assist (gemini-flash)"]}
EOS
  export CLAUDE_ACCT_GATEWAY_CONFIG="$SRC/litellm.yaml"
  echo '[{"team_id":"t1","team_alias":"lazer-pool","spend":60,"max_budget":50,"blocked":false,"budget_duration":"1mo","metadata":{"priority":"low"}}]' > "$SANDBOX/gw/team-list.json"
  echo '{"keys":[{"token":"hash-abc123","key_name":"sk-...wxyz","key_alias":"comms-triage","team_id":"t1","spend":1.5,"max_budget":25,"blocked":false,"budget_duration":"30d","models":["fast"],"metadata":{"consumer":"comms tier 2","priority":"must"}}]}' > "$SANDBOX/gw/key-list.json"
  cat > "$SANDBOX/bin/curl" <<'EOS'
#!/usr/bin/env bash
cat > /dev/null
case "${*: -1}" in
  */team/list) cat "$SANDBOX/gw/team-list.json" ;;
  */key/list*) cat "$SANDBOX/gw/key-list.json" ;;
  */key/info) echo '{"info":{"key_alias":"comms-triage","token":"hash-abc123"}}' ;;
  *) exit 22 ;;
esac
EOS
  chmod +x "$SANDBOX/bin/curl"
}

@test "gateway: the snapshot joins teams, keys, sources and the config's fallbacks, with no key secret" {
  gw_setup
  run "$ACCT" gateway --out "$SRC/gw.json"
  assert_success
  run jq -c '[.keys[0].alias, .keys[0].team, .keys[0].priority, .teams[0].priority, (.sources | map([.priority, .key])), .fallbacks["fast (gpt-oss-120b)"][0], .aliases.fast]' "$SRC/gw.json"
  assert_output '["comms-triage","lazer-pool","must","low",[["low",null],[null,null],[null,"comms-triage"]],"assist (gemini-flash)","fast (gpt-oss-120b)"]'
  run grep -c 'hash-abc123\|wxyz\|sk-' "$SRC/gw.json"
  assert_output 0
}

@test "gateway: a gateway that cannot be read keeps the old snapshot and exits 1" {
  gw_setup
  echo '{"old":true}' > "$SRC/gw.json"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin/curl"
  run "$ACCT" gateway --out "$SRC/gw.json"
  assert_failure 1
  assert_output --partial 'is unchanged'
  run cat "$SRC/gw.json"
  assert_output '{"old":true}'
  run bash -c 'ls -A "$1" | grep -c "^.gateway"' _ "$SRC"
  assert_output 0
}

@test "gateway: a key list longer than one page keeps the old snapshot and exits 1" {
  gw_setup
  echo '{"old":true}' > "$SRC/gw.json"
  jq -c '. + {total_count: 101, current_page: 1, total_pages: 2}' "$SANDBOX/gw/key-list.json" > "$SRC/kl.json" && mv "$SRC/kl.json" "$SANDBOX/gw/key-list.json"
  run "$ACCT" gateway --out "$SRC/gw.json"
  assert_failure 1
  assert_output --partial 'more keys than one page'
  run cat "$SRC/gw.json"
  assert_output '{"old":true}'
}

@test "gateway: the config comes from the home-config clone's upstream tip, not its working tree" {
  gw_setup
  unset CLAUDE_ACCT_GATEWAY_CONFIG
  export HOME_CONFIG="$SRC/hc"
  git init -q --bare "$SRC/hc.git"
  git clone -q "$SRC/hc.git" "$HOME_CONFIG" 2>/dev/null
  mkdir -p "$HOME_CONFIG/apps/litellm"
  cp "$SRC/litellm.yaml" "$HOME_CONFIG/apps/litellm/config.yaml"
  git -C "$HOME_CONFIG" -c user.name=t -c user.email=t@t add -A
  git -C "$HOME_CONFIG" -c user.name=t -c user.email=t@t commit -qm tip
  git -C "$HOME_CONFIG" push -q origin HEAD 2>/dev/null
  git -C "$HOME_CONFIG" branch -q -u "origin/$(git -C "$HOME_CONFIG" branch --show-current)"
  echo 'router_settings: {}' > "$HOME_CONFIG/apps/litellm/config.yaml"
  run "$ACCT" gateway --out "$SRC/gw.json"
  assert_success
  run jq -c '[(.aliases | length > 0), (.fallbacks | length > 0)]' "$SRC/gw.json"
  assert_output '[true,true]'
}

@test "gateway: no config to read leaves aliases and fallbacks null and still writes the snapshot" {
  gw_setup
  unset CLAUDE_ACCT_GATEWAY_CONFIG
  export HOME_CONFIG="$SRC/no-such-clone"
  run "$ACCT" gateway --out "$SRC/gw.json"
  assert_success
  assert_output --partial 'aliases and fallbacks are null'
  run jq -c '[.aliases, .fallbacks, .keys[0].alias]' "$SRC/gw.json"
  assert_output '[null,null,"comms-triage"]'
}

@test "textfile: with no dir it writes into the one the machine's node_exporter reads, a k3s node's included" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  local ws="$SANDBOX/node_exporter/textfile" k3s="$SANDBOX/node-exporter-textfile"
  unset PROM_TEXTFILE_DIR
  export PROM_TEXTFILE_DIRS="$ws:$k3s"
  mkdir -p "$HOME/.local/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/fleet-lease"; chmod +x "$HOME/.local/bin/fleet-lease"
  # no collector on this machine: skipped, nothing written, status 0
  run "$ACCT" textfile
  assert_success
  [ ! -e "$ws" ] && [ ! -e "$k3s" ]
  mkdir -p "$k3s"
  run "$ACCT" textfile
  assert_success
  run cat "$k3s/claude_acct.prom"
  assert_line 'claude_account_read_ok{account="main",kind="claude"} 1'
  [ ! -e "$ws" ]
}

@test "textfile: with no dir only the fleet-lease holder publishes; another machine removes its copy, one that cannot tell keeps it" {
  # a fleet worker's copy read every source unread and, merged by account, blanked every Burn row
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  export PROM_TEXTFILE_DIR="$SANDBOX/tf"
  mkdir -p "$PROM_TEXTFILE_DIR" "$HOME/.local/bin"
  # the check runs ~/.local/bin/fleet-lease, as the units do, never a PATH lookup: a fleet
  # worker's systemd PATH has no ~/.local/bin, and its 127 kept the copy that blanked the rows
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/fleet-lease"; chmod +x "$SANDBOX/bin/fleet-lease"
  lease() { printf '#!/usr/bin/env bash\n[ "$1" = claude-acct-usage ] || exit 9\nexit %s\n' "$1" > "$HOME/.local/bin/fleet-lease"; chmod +x "$HOME/.local/bin/fleet-lease"; }
  echo 'old 1' > "$PROM_TEXTFILE_DIR/claude_acct.prom"
  lease 2
  run "$ACCT" textfile
  assert_success
  assert_output --partial 'fleet-lease cannot tell who holds the lease (exit 2)'
  run cat "$PROM_TEXTFILE_DIR/claude_acct.prom"
  assert_output 'old 1'
  lease 1
  run env PATH="$SANDBOX/bin:/usr/bin:/bin" "$ACCT" textfile
  assert_success
  [ ! -e "$PROM_TEXTFILE_DIR/claude_acct.prom" ]
  # an explicit dir is not the collector's, so it publishes on any machine
  mkdir -p "$SANDBOX/own"
  run "$ACCT" textfile "$SANDBOX/own"
  assert_success
  [ -s "$SANDBOX/own/claude_acct.prom" ]
  lease 0
  run "$ACCT" textfile
  assert_success
  run cat "$PROM_TEXTFILE_DIR/claude_acct.prom"
  assert_line 'claude_account_read_ok{account="main",kind="claude"} 1'
}

# --- sign-in state: auth, check auth|expiry, wake ---------------------------------------------

# login <dir> [access end ms] [login end ms] -> a signed-in credentials file
login() {
  printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":%s,"refreshTokenExpiresAt":%s}}\n' \
    "${2:-$(((NOW + 3600) * 1000))}" "${3:-$(((NOW + 20 * 86400) * 1000))}" > "$1/.credentials.json"
}

# session <pane> <account> <status> [stuck] -> one agent-panel row, and with "stuck" a pane on Not logged in
session() {
  jq -nc --arg p "$1" --arg a "$2" --arg s "$3" \
    '{harness: "claude", pane: $p, target: ("hub/s" + $p), account: $a, status: $s, parked: false}' >> "$NOTES_FIXTURE/agent-panel.list.json"
  if [[ "${4:-}" == stuck ]]; then
    printf 'did the work\n\nNot logged in · Please run /login\n\n> \n' > "$NOTES_FIXTURE/tmux.capture.${1#*/}"
  fi
}

sent() { grep -c '^agent-panel send' "$NOTES_FIXTURE/calls.log" || true; }

@test "check auth: every account signed in is quiet, and the line says how many" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"; login "$ALT"
  run "$ACCT" check auth
  assert_success
  assert_output '2 accounts signed in'
}

@test "check auth: a credentials file emptied to {} trips, naming the account and the login command" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  echo '{}' > "$ALT/.credentials.json"
  run "$ACCT" check auth
  assert_failure 1
  assert_output 'alt signed out (the credentials file holds no login): cl --acct alt, then /login'
  # a missing file and a file with only an access token are signed out too
  rm "$ALT/.credentials.json"
  run "$ACCT" check auth
  assert_failure 1
  assert_output 'alt signed out (no credentials file): cl --acct alt, then /login'
  printf '{"claudeAiOauth":{"accessToken":"a"}}\n' > "$ALT/.credentials.json"
  run "$ACCT" check auth
  assert_failure 1
  assert_output --partial 'alt signed out (no refresh token)'
  # negative control: signing in again clears it
  login "$ALT"
  run "$ACCT" check auth
  assert_success
}

@test "check auth: every account signed out is one line naming each, and counts the sessions stopped on it" {
  export CLAUDE_ACCT_NOW=$NOW
  echo '{}' > "$HOME/.claude/.credentials.json"; echo '{}' > "$ALT/.credentials.json"
  session hub/%1 alt idle stuck; session hub/%2 alt idle stuck
  run "$ACCT" check auth
  assert_failure 1
  assert_output --partial 'main signed out'
  assert_output --partial 'alt signed out (the credentials file holds no login), 2 sessions on Not logged in: cl --acct alt, then /login'
}

@test "check auth: an access token long past its end with sessions working is a refresh that failed; idle, it is not" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  login "$ALT" $(((NOW - 40 * 60) * 1000))
  run "$ACCT" check auth
  assert_success
  session hub/%1 alt busy
  run "$ACCT" check auth
  assert_failure 1
  assert_output 'alt not refreshing: its access token ended 40m ago with 1 sessions working: cl --acct alt, then /login'
  # inside the grace Claude is still about to refresh
  login "$ALT" $(((NOW - 10 * 60) * 1000))
  run "$ACCT" check auth
  assert_success
}

@test "check auth: an account whose sessions run on a setup token is not 'not refreshing' for its file's access token" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  login "$ALT" $(((NOW - 90 * 60) * 1000))
  session hub/%1 alt busy
  run "$ACCT" check auth
  assert_failure 1
  assert_output --partial 'alt not refreshing'
  rbw_stub
  mkdir -p "$SANDBOX/vault" "$XDG_CONFIG_HOME/claude-acct/tokens"
  touch "$SANDBOX/vault/locked"
  printf '%s' "$TOK_ALT" > "$XDG_CONFIG_HOME/claude-acct/tokens/alt"
  run "$ACCT" check auth
  assert_success
  # the login itself ending still trips
  login "$ALT" $(((NOW - 90 * 60) * 1000)) $(((NOW - 3600) * 1000))
  run "$ACCT" check auth
  assert_failure 1
  assert_output --partial 'alt signed out (its login ended'
}

@test "check expiry: a login ending within three days trips, naming the account; a month out is quiet" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  login "$ALT" $(((NOW + 3600) * 1000)) $(((NOW + 2 * 86400 + 3 * 3600) * 1000))
  run "$ACCT" check expiry
  assert_failure 1
  assert_output 'alt login ends in 2d 3h: cl --acct alt, then /login'
  login "$ALT"
  run "$ACCT" check expiry
  assert_success
  assert_output 'no login ends within 3 days'
}

@test "check expiry: a signed-out account is check auth's, not named here" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  echo '{}' > "$ALT/.credentials.json"
  run "$ACCT" check expiry
  assert_success
}

@test "textfile: publishes each account's sign-in, its token ends, its last write and the stopped sessions" {
  export CLAUDE_ACCT_NOW=$NOW
  week main 30 84
  login "$HOME/.claude" $(((NOW + 3600) * 1000)) $(((NOW + 20 * 86400) * 1000))
  echo '{}' > "$ALT/.credentials.json"
  session hub/%1 alt idle stuck; session hub/%2 alt idle stuck; session hub/%3 main busy
  mkdir -p "$SANDBOX/tf"
  run "$ACCT" textfile "$SANDBOX/tf"
  assert_success
  run cat "$SANDBOX/tf/claude_acct.prom"
  assert_line 'claude_account_logged_in{account="main",kind="claude"} 1'
  assert_line 'claude_account_logged_in{account="alt",kind="claude"} 0'
  assert_line "claude_account_access_expires_timestamp_seconds{account=\"main\",kind=\"claude\"} $((NOW + 3600))"
  assert_line "claude_account_refresh_expires_timestamp_seconds{account=\"main\",kind=\"claude\"} $((NOW + 20 * 86400))"
  assert_line --regexp '^claude_account_credentials_written_timestamp_seconds\{account="main",kind="claude"\} [0-9]+$'
  assert_line 'claude_account_not_logged_in_sessions{account="alt",kind="claude"} 2'
  assert_line 'claude_account_not_logged_in_sessions{account="main",kind="claude"} 0'
  assert_line 'claude_fleet_not_logged_in_sessions 2'
  assert_line 'claude_fleet_signed_out_accounts 1'
  # an emptied file has no token to end: no expiry line for it
  refute_line --partial 'expires_timestamp_seconds{account="alt"'
}

@test "auth: the table names each account's state, and --json is the rows" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  echo '{}' > "$ALT/.credentials.json"
  session hub/%1 main busy
  run "$ACCT" auth
  assert_success
  assert_output --regexp 'main +yes +in 1h 0m +in 20d 0h .* 1 +0'
  assert_output --partial 'alt'
  assert_output --partial 'NO:the_credentials_file_holds_no_login'
  run jq -c '[.[] | {name, logged_in, working}]' <(
    "$ACCT" auth --json)
  assert_output '[{"name":"main","logged_in":true,"working":1},{"name":"alt","logged_in":false,"working":0}]'
}

@test "stuck: only an idle session whose last lines say Not logged in counts; a quote higher up or a busy session does not" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"; login "$ALT"
  session hub/%1 main idle stuck
  session hub/%2 main idle
  printf 'Not logged in · Please run /login\nthen I carried on\nline\nline\nline\nline\nline\nline\nline\n> \n' > "$NOTES_FIXTURE/tmux.capture.%2"
  session hub/%3 main busy stuck
  run jq -c '[.[] | {name, stuck}]' <("$ACCT" auth --json)
  assert_output '[{"name":"main","stuck":1},{"name":"alt","stuck":0}]'
}

@test "wake: a session stopped on Not logged in, on an account signed in again, is typed to; a signed-out account's is not" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  echo '{}' > "$ALT/.credentials.json"
  session hub/%1 main idle stuck
  session hub/%2 alt idle stuck
  run "$ACCT" wake
  assert_success
  assert_output 'woke hub/shub/%1 (hub/%1, account main), try 1 of 3'
  assert_equal "$(sent)" 1
  grep -q -- 'agent-panel send --pane hub/%1 You were signed out and are signed in again' "$NOTES_FIXTURE/calls.log"
  ! grep -q -- 'send --pane hub/%2' "$NOTES_FIXTURE/calls.log"
}

@test "wake: at most WAKE_BATCH a run, the rest the next run; a loaded machine wakes one" {
  export CLAUDE_ACCT_NOW=$NOW CLAUDE_ACCT_LOADAVG="$SANDBOX/loadavg"
  echo '0.1 0.1 0.1 1/1 1' > "$SANDBOX/loadavg"
  login "$HOME/.claude"
  for i in 1 2 3 4 5; do session "hub/%$i" main idle stuck; done
  run "$ACCT" wake
  assert_success
  assert_equal "$(sent)" 3
  # the same minute again: the three are inside their gap, so the other two go
  run "$ACCT" wake
  assert_equal "$(sent)" 5
  # negative control: past the load line a run wakes one
  : > "$NOTES_FIXTURE/calls.log"
  rm -rf "$XDG_CACHE_HOME/claude-acct/wake"
  echo '999 999 999 1/1 1' > "$SANDBOX/loadavg"
  run "$ACCT" wake
  assert_equal "$(sent)" 1
}

@test "wake: a pane waits out its gap, is tried WAKE_TRIES times, and then check auth pages it" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"; login "$ALT"
  session hub/%1 main idle stuck
  run "$ACCT" wake; assert_output --partial 'try 1 of 3'
  run "$ACCT" wake; assert_output ''
  for t in 2 3; do
    export CLAUDE_ACCT_NOW=$((NOW + t * 600))
    run "$ACCT" wake
    assert_output --partial "try $t of 3"
  done
  export CLAUDE_ACCT_NOW=$((NOW + 4 * 600))
  run "$ACCT" wake
  assert_output ''
  assert_equal "$(sent)" 3
  run "$ACCT" check auth
  assert_failure 1
  assert_output 'main 1 sessions stay on Not logged in after the wakes: cl --acct main, then /login'
}

@test "wake: a pane that came back is forgotten, so a later sign-out starts its tries again" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  session hub/%1 main idle stuck
  run "$ACCT" wake
  [ -f "$XDG_CACHE_HOME/claude-acct/wake/hub_%1" ]
  printf 'working again\n> \n' > "$NOTES_FIXTURE/tmux.capture.%1"
  run "$ACCT" wake
  assert_output ''
  [ ! -e "$XDG_CACHE_HOME/claude-acct/wake/hub_%1" ]
}

@test "wake --dry-run names what it would wake and types nothing" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  session hub/%1 main idle stuck
  run "$ACCT" wake --dry-run
  assert_output 'would wake hub/shub/%1 (hub/%1, account main)'
  assert_equal "$(sent)" 0
}

@test "auth: agent-panel missing or failing is said on stderr, never counted as no stuck sessions in silence" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"; login "$ALT"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  run --separate-stderr "$ACCT" check auth
  assert_success
  [[ "$stderr" == *'agent-panel list failed (1)'* ]]
}

@test "check auth: a refresh token past its end is signed out even though the file still holds it" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  login "$ALT" "$(((NOW - 7200) * 1000))" "$(((NOW - 3 * 3600) * 1000))"
  run "$ACCT" check auth
  assert_failure 1
  assert_output 'alt signed out (its login ended 3h ago): cl --acct alt, then /login'
}

@test "wake: a send the pane did not take still counts as a try, so check auth reaches it" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"; login "$ALT"
  session hub/%1 main idle stuck
  touch "$NOTES_FIXTURE/agent-panel.unsent"
  for t in 0 1 2 3 4; do
    export CLAUDE_ACCT_NOW=$((NOW + t * 600))
    run "$ACCT" wake
  done
  assert_equal "$(sent)" 3
  run "$ACCT" check auth
  assert_failure 1
  assert_output --partial 'main 1 sessions stay on Not logged in'
}

@test "wake: a pane at work keeps its tries, and one a human touched a minute ago is left alone" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  session hub/%1 main idle stuck
  run "$ACCT" wake
  [ -f "$XDG_CACHE_HOME/claude-acct/wake/hub_%1" ]
  rm "$NOTES_FIXTURE/agent-panel.list.json"
  session hub/%1 main busy
  run "$ACCT" wake
  [ -f "$XDG_CACHE_HOME/claude-acct/wake/hub_%1" ]
  rm "$NOTES_FIXTURE/agent-panel.list.json" "$XDG_CACHE_HOME/claude-acct/wake/hub_%1"
  jq -nc --argjson h "$((NOW - 60))" '{harness: "claude", pane: "hub/%1", target: "hub/s%1", account: "main", status: "idle", parked: false, human_at: $h}' \
    > "$NOTES_FIXTURE/agent-panel.list.json"
  run "$ACCT" wake
  assert_output ''
  assert_equal "$(sent)" 1
}

@test "wake: when agent-panel cannot list, nothing is woken and the ledger stays" {
  export CLAUDE_ACCT_NOW=$NOW
  login "$HOME/.claude"
  session hub/%1 main idle stuck
  run "$ACCT" wake
  [ -f "$XDG_CACHE_HOME/claude-acct/wake/hub_%1" ]
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  run "$ACCT" wake
  assert_failure 1
  [ -f "$XDG_CACHE_HOME/claude-acct/wake/hub_%1" ]
}

# --- long-lived tokens (setup-token) ---------------------------------------------------
# rbw is a stub over $SANDBOX/vault: one file per entry, the password on line 1, the notes after a
# blank line. `rbw add|edit` runs $EDITOR on a temp file like the real one, and every call's argv
# lands in vault/argv.log, so a test can prove the token is never an argument.

TOK_MAIN=sk-ant-oat01-mainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmainmai   # setup tokens are 108 characters (TOKEN_LEN)
TOK_ALT=sk-ant-oat01-altaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltaltal

rbw_stub() {
  export SANDBOX
  mkdir -p "$SANDBOX/vault"
  cat > "$SANDBOX/bin/rbw" <<'STUB'
#!/usr/bin/env bash
V="$SANDBOX/vault"
echo "$*" >> "$V/argv.log"
case "$1" in
  unlocked) [[ ! -e "$V/locked" ]] ;;
  get)
    if [[ "$2" == --raw ]]; then
      [[ -f "$V/$3" ]] || exit 1
      jq -n --arg n "$(sed '1,2d' "$V/$3")" '{notes: $n}'
    else
      [[ -f "$V/$2" ]] || exit 1
      head -1 "$V/$2"
    fi ;;
  add|edit)
    t=$(mktemp); "${VISUAL:-$EDITOR}" "$t"; cp "$t" "$V/$2"; rm -f "$t" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/rbw"
}

# vault_put <entry> <token> [notes]
vault_put() {
  mkdir -p "$SANDBOX/vault"
  printf '%s\n\n%s\n' "$2" "${3:-}" > "$SANDBOX/vault/$1"
}

@test "token: prints the account's token, by name or by dir, and main for an empty arg" {
  rbw_stub
  vault_put claude-oauth-main "$TOK_MAIN"
  vault_put claude-oauth-alt "$TOK_ALT"
  run "$ACCT" token alt
  assert_output "$TOK_ALT"
  run "$ACCT" token "$ALT"
  assert_output "$TOK_ALT"
  run "$ACCT" token ''
  assert_output "$TOK_MAIN"
}

@test "token: an account with no entry gets nothing and exit 1, silently" {
  rbw_stub
  vault_put claude-oauth-main "$TOK_MAIN"
  run --separate-stderr "$ACCT" token alt
  assert_failure 1
  assert_output ''
  [[ -z "$stderr" ]]
}

@test "token: a locked vault says so on stderr and prints no token" {
  rbw_stub
  vault_put claude-oauth-alt "$TOK_ALT"
  touch "$SANDBOX/vault/locked"
  run --separate-stderr "$ACCT" token alt
  assert_failure 1
  assert_output ''
  [[ "$stderr" == *'rbw is locked'* ]]
}

@test "token: a machine whose rbw is locked or absent reads the pushed copy" {
  rbw_stub
  mkdir -p "$SANDBOX/vault" "$XDG_CONFIG_HOME/claude-acct/tokens"
  touch "$SANDBOX/vault/locked"
  printf '%s' "$TOK_ALT" > "$XDG_CONFIG_HOME/claude-acct/tokens/alt"
  run --separate-stderr "$ACCT" token alt
  assert_success
  assert_output "$TOK_ALT"
  run --separate-stderr "$ACCT" token main
  assert_failure 1
  [[ "$stderr" == *"rbw is locked"* ]]   # no copy for main: it says why, as before
}

@test "token push: each token goes to the host on ssh stdin, never in an argument, and is read back" {
  rbw_stub
  vault_put claude-oauth-main "$TOK_MAIN"
  vault_put claude-oauth-alt "$TOK_ALT"
  # the stub runs the remote command locally, with HOME as the host's home
  mkdir -p "$SANDBOX/far/.local/bin" "$SANDBOX/farbin"
  printf "#!/bin/sh\nexit 1\n" > "$SANDBOX/farbin/rbw"; chmod +x "$SANDBOX/farbin/rbw"   # the host has no unlocked rbw
  ln -s "$ACCT" "$SANDBOX/far/.local/bin/claude-acct"
  cat > "$SANDBOX/bin/ssh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/ssh.argv"
while [[ "\$1" == -* ]]; do [[ "\$1" == -o ]] && shift; shift; done
shift
HOME="$SANDBOX/far" XDG_CONFIG_HOME= CLAUDE_ACCT_CONFIG="$CLAUDE_ACCT_CONFIG" PATH="$SANDBOX/farbin:/usr/bin:/bin" bash -c "\$*" 2>>"$SANDBOX/ssh.err"
STUB
  chmod +x "$SANDBOX/bin/ssh"
  run "$ACCT" token push far
  assert_success
  assert_output 'far: main alt read back'
  [[ "$(cat "$SANDBOX/far/.config/claude-acct/tokens/alt")" == "$TOK_ALT" ]]
  [[ "$(stat -c %a "$SANDBOX/far/.config/claude-acct/tokens/alt")" == 600 ]]
  run grep -c -e "$TOK_MAIN" -e "$TOK_ALT" "$SANDBOX/ssh.argv"
  assert_output 0
}

@test "token push: refuses with rbw locked here, and names an account the host cannot read" {
  rbw_stub
  vault_put claude-oauth-alt "$TOK_ALT"
  touch "$SANDBOX/vault/locked"
  run "$ACCT" token push far
  assert_failure 2
  rm "$SANDBOX/vault/locked"
  printf '#!/usr/bin/env bash\ncat >/dev/null; exit 255\n' > "$SANDBOX/bin/ssh"; chmod +x "$SANDBOX/bin/ssh"
  run --separate-stderr "$ACCT" token push far
  assert_failure 1
  [[ "$stderr" == *'far: alt failed'* ]]
  [[ "$stderr" == *'main has no token in rbw'* ]]   # an account left out fails the push too
  run --separate-stderr "$ACCT" token push -oProxyCommand=x
  assert_failure 1
  [[ "$stderr" == *'is not a host'* ]]
}

@test "token-prefix: a command substitution for an account that has a token, never the token" {
  rbw_stub
  vault_put claude-oauth-alt "$TOK_ALT"
  run "$ACCT" token-prefix "$ALT"
  assert_success
  assert_output --partial 'CLAUDE_CODE_OAUTH_TOKEN="$(claude-acct token '
  refute_output --partial "$TOK_ALT"
  run "$ACCT" token-prefix ''
  assert_output ''
}

@test "run: the chosen account's token is exported, and a token inherited from a parent is dropped" {
  rbw_stub
  vault_put claude-oauth-alt "$TOK_ALT"
  usage main 90 90
  usage alt 10 10
  printf '#!/usr/bin/env bash\necho "tok=${CLAUDE_CODE_OAUTH_TOKEN:-none} dir=${CLAUDE_CONFIG_DIR:-main}"\n' > "$SANDBOX/bin/claude"
  CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-parent run "$ACCT" run
  assert_output --partial "tok=$TOK_ALT dir=$ALT"
  # main has no token: the parent's must not carry over
  CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-parent run "$ACCT" run --acct main
  assert_output --partial 'tok=none dir=main'
}

@test "check tokens: good, inside the warn window, expired, and unread when rbw is locked" {
  rbw_stub
  export CLAUDE_ACCT_NOW=$(date -d 2026-11-17 +%s)
  vault_put claude-oauth-main "$TOK_MAIN" 'expires: 2027-11-17'
  vault_put claude-oauth-alt "$TOK_ALT" 'expires: 2027-11-17'
  run "$ACCT" check tokens
  assert_success
  assert_output '2 tokens good'
  rm "$SANDBOX/vault/claude-oauth-alt"
  run "$ACCT" check tokens
  assert_success
  assert_output 'no token yet: alt'
  vault_put claude-oauth-alt "$TOK_ALT" 'expires: 2026-12-01'
  run "$ACCT" check tokens
  assert_failure 1
  assert_output --partial 'alt expires 2026-12-01, in 14d'
  vault_put claude-oauth-alt "$TOK_ALT" 'expires: 2026-11-01'
  run "$ACCT" check tokens
  assert_failure 1
  assert_output --partial 'alt expired 2026-11-01'
  touch "$SANDBOX/vault/locked"
  run "$ACCT" check tokens
  assert_failure 2
}

# A claude stub for setup-token: `setup-token` prints a token, `-p` answers ok. TOKEN_OUT empty
# prints none, so the paste path runs.
setup_stubs() {
  rbw_stub
  cat > "$SANDBOX/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  setup-token) [[ -n "${TOKEN_OUT:-}" ]] && printf 'Your token:\n\033[1m%s\033[0m\nStore it safely\n' "$TOKEN_OUT" ;;
  -p) echo "ok"; echo "$CLAUDE_CODE_OAUTH_TOKEN" > "$SANDBOX/probe.token" ;;
  *) echo "2.1.0 (Claude Code)" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/claude"
  printf '#!/usr/bin/env bash\nprintf 403\n' > "$SANDBOX/bin/curl"; chmod +x "$SANDBOX/bin/curl"
  printf '{"oauthAccount":{"emailAddress":"alt@example.com"}}\n' > "$ALT/.claude.json"
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
}

@test "setup-token: names the email, verifies the token, stores it with its expiry, argv never carries it" {
  command -v script >/dev/null || skip "no script(1)"
  setup_stubs
  TOKEN_OUT=$TOK_ALT run "$ACCT" setup-token alt < /dev/null
  assert_success
  assert_output --partial 'sign in as alt@example.com'
  assert_output --partial 'verified'
  assert_output --partial 'usage endpoint: rejected (HTTP 403)'
  assert_output --partial 'stored: rbw claude-oauth-alt'
  [[ "$(head -1 "$SANDBOX/vault/claude-oauth-alt")" == "$TOK_ALT" ]]
  grep -q '^email: alt@example.com' "$SANDBOX/vault/claude-oauth-alt"
  grep -q "^expires: $(date -d '+365 days' +%F)" "$SANDBOX/vault/claude-oauth-alt"
  [[ "$(cat "$SANDBOX/probe.token")" == "$TOK_ALT" ]]
  ! grep -q "$TOK_ALT" "$SANDBOX/vault/argv.log"
  # nothing of the token is left in the scratch dir
  ! grep -rq "$TOK_ALT" "$TMPDIR" 2>/dev/null
}

@test "setup-token: a screen with no token falls back to a hidden paste" {
  setup_stubs
  run "$ACCT" setup-token alt <<< "$TOK_ALT"
  assert_success
  assert_output --partial 'stored: rbw claude-oauth-alt'
  [[ "$(head -1 "$SANDBOX/vault/claude-oauth-alt")" == "$TOK_ALT" ]]
}

@test "setup-token: an account that has a token is skipped, --renew replaces it" {
  setup_stubs
  vault_put claude-oauth-alt "$TOK_ALT" 'expires: 2027-01-01'
  run "$ACCT" setup-token alt < /dev/null
  assert_success
  assert_output --partial 'already has a token'
  run "$ACCT" setup-token --renew alt <<< "sk-ant-oat01-newnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewne"
  assert_success
  [[ "$(head -1 "$SANDBOX/vault/claude-oauth-alt")" == sk-ant-oat01-newnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewnewne ]]
}

@test "setup-token: an API key in the environment stops it before any call" {
  setup_stubs
  ANTHROPIC_API_KEY=sk-ant-api03-x run "$ACCT" setup-token alt <<< "$TOK_ALT"
  assert_failure
  assert_output --partial 'would not bill the subscription'
  [[ ! -e "$SANDBOX/vault/claude-oauth-alt" ]]
  [[ ! -e "$SANDBOX/probe.token" ]]
}

@test "setup-token: a token that runs no call is not stored" {
  setup_stubs
  printf '#!/usr/bin/env bash\ncase "$1" in -p) exit 1 ;; *) exit 0 ;; esac\n' > "$SANDBOX/bin/claude"
  run "$ACCT" setup-token alt <<< "$TOK_ALT"
  assert_failure
  assert_output --partial 'nothing stored'
  [[ ! -e "$SANDBOX/vault/claude-oauth-alt" ]]
}

@test "setup-token: a locked vault stops it up front" {
  setup_stubs
  touch "$SANDBOX/vault/locked"
  run "$ACCT" setup-token
  assert_failure
  assert_output --partial 'rbw is locked'
}

@test "resume_cmd: the token prefix follows launch_env, so its env -u does not drop the token" {
  src
  rbw_stub
  vault_put claude-oauth-alt "$TOK_ALT"
  launch_env() { printf "env -u CLAUDE_CODE_OAUTH_TOKEN "; }
  run resume_cmd 1 /w "$ALT" 'claude --resume s1' hi fix-menu
  # the assignment comes after the launch env's `env -u ... -u CLAUDE_CODE_OAUTH_TOKEN`, never before it
  [[ "$output" =~ -u\ CLAUDE_CODE_OAUTH_TOKEN.*\ CLAUDE_CODE_OAUTH_TOKEN=\"\$\(claude-acct\ token ]] || fail "order: $output"
  [[ "$output" != *"$TOK_ALT"* ]]
}

@test "usage read: no token (none in a locked vault, no pushed copy) reads unread with no call made" {
  rbw_stub
  vault_put claude-oauth-main "$TOK_MAIN"
  touch "$SANDBOX/vault/locked"
  ratelimit_curl 'anthropic-ratelimit-unified-7d-utilization: 0.65'
  run --separate-stderr "$ACCT" status --json
  assert_success
  [[ "$(jq -r '.[] | select(.name == "main") | .state' <<< "$output")" == unread ]]
  ! grep -qF 'v1/messages' "$SANDBOX/curl.argv"
}

@test "setup-token: a call that exits 0 without answering is not a verified token" {
  setup_stubs
  printf '#!/usr/bin/env bash\ncase "$1" in -p) echo "login required" ;; esac\n' > "$SANDBOX/bin/claude"
  run "$ACCT" setup-token alt <<< "$TOK_ALT"
  assert_failure
  assert_output --partial 'nothing stored'
  [[ ! -e "$SANDBOX/vault/claude-oauth-alt" ]]
}
