#!/usr/bin/env bats
# agent-queue - the store and verb contract: add, order, holds, cancel, bump, set, move, stats.
# Everything lives in the sandbox HOME; tmux is the recording stub.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  sandbox_worlds
  AQ="$REPO_ROOT/.local/bin/agent-queue"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue"
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  REPO="$SANDBOX/repos/game"
  git init -q "$REPO"
  # Two games in the game repo (level, arena), a repo whose work counts on its owner (tools ->
  # cockpit), and a project with a row code in another checkout (elsewhere).
  jq -n --arg r "$REPO" '{paths: {($r): "game", "/x/app": "app", "/x/tools": "tools"}, aliases: {"g2": "game"},
    trackers: {"level": {repo: "game", path: "Assets/Level", code: "lv"}, "arena": {repo: "game", path: "Assets/Arena/", code: "ar"},
      "notes": {repo: null}, "app": {}, "tools": {owner: "cockpit"}, "cockpit": {repo: "tools"},
      "elsewhere": {repo: "app", code: "el"}}}' > "$AGENT_QUEUE_PROJECT_MAP"
  # A plan item starts its session through fleet-dispatch: a recording stub, never the real one.
  printf '#!/usr/bin/env bash\necho "fleet-dispatch $*" >> "$NOTES_FIXTURE/calls.log"\nexit "${FD_EXIT:-0}"\n' > "$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/fleet-dispatch"
  # The caller's Claude session stamps items and decides mine: a test sets it, never inherits it.
  unset CLAUDE_CODE_SESSION_ID
}

field() { awk -v k="$2: " '$0 == "---" { exit } index($0, k) == 1 { print substr($0, length(k) + 1) }' "$1"; }
item() { ls "$AGENT_QUEUE_DIR"/"$1"/*-"$2".md; }

@test "add writes one queued item with the defaults and the task as typed" {
  run "$AQ" add --project game "Menu: pick sides" "and add people"
  assert_success
  assert_output --partial "queued menu-pick-sides-and-add-people"
  f="$(item queued menu-pick-sides-and-add-people)"
  [ "$(field "$f" mode)" = oneshot ]
  [ "$(field "$f" priority)" = high ]
  [ "$(field "$f" from)" = human ]
  [ "$(field "$f" agent)" = claude ]
  [[ "$(field "$f" queued)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
  run awk 'f { print } $0 == "---" { f = 1 }' "$f"
  assert_output "Menu: pick sides and add people"
}

@test "add sets weight: light by default, heavy for a Unity checkout or a plan item, and --weight wins" {
  "$AQ" add --project game --slug plain "plain"
  [ "$(field "$(item queued plain)" weight)" = light ]
  "$AQ" add --project game --mode plan --slug planned "planned"
  [ "$(field "$(item queued planned)" weight)" = heavy ]
  "$AQ" add --project game --weight heavy --slug forced "forced"
  [ "$(field "$(item queued forced)" weight)" = heavy ]
  mkdir -p "$REPO/ProjectSettings" && : > "$REPO/ProjectSettings/ProjectVersion.txt"
  "$AQ" add --project game --slug unity "unity"
  [ "$(field "$(item queued unity)" weight)" = heavy ]
  "$AQ" add --project game --weight light --slug unity-light "unity light"
  [ "$(field "$(item queued unity-light)" weight)" = light ]
  run "$AQ" add --project game --weight huge "huge"
  assert_failure
  assert_output --partial "--weight is heavy or light, not huge"
}

@test "list --json gives an item with no weight line the derived weight" {
  "$AQ" add --project game --slug old "old"
  sed -i '/^weight:/d' "$(item queued old)"
  [ "$(jq -r .weight <<<"$("$AQ" show old --json)")" = light ]
  mkdir -p "$REPO/ProjectSettings" && : > "$REPO/ProjectSettings/ProjectVersion.txt"
  [ "$(jq -r .weight <<<"$("$AQ" show old --json)")" = heavy ]
}

@test "add reads a multi-line task from stdin" {
  printf 'Line one\nline two\n' | "$AQ" add --project game --slug two-lines
  run awk 'f { print } $0 == "---" { f = 1 }' "$(item queued two-lines)"
  assert_output $'Line one\nline two'
}

@test "add takes the project from the repo it runs in" {
  cd "$REPO"
  run "$AQ" add --slug here "do it"
  assert_success
  [ "$(field "$(item queued here)" project)" = game ]
}

@test "add refuses what it cannot run" {
  run "$AQ" add --project nope "x"
  assert_failure; assert_output --partial "unknown project: nope"
  run "$AQ" add --project game --priority asap "x"
  assert_failure; assert_output --partial "--priority"
  run "$AQ" add --project game --mode yolo "x"
  assert_failure; assert_output --partial "--mode"
  run "$AQ" add --project game --from robot "x"
  assert_failure; assert_output --partial "--from"
  run "$AQ" add --project game --tags "at:25:00" "x"
  assert_failure; assert_output --partial "at:HH:MM"
  run "$AQ" add --project game --after ghost "x"
  assert_failure; assert_output --partial "no item has that slug"
  run "$AQ" add --project game < /dev/null
  assert_failure; assert_output --partial "no task"
  [ ! -d "$AGENT_QUEUE_DIR/queued" ] || [ -z "$(ls "$AGENT_QUEUE_DIR/queued")" ]
}

@test "an alias is filed as its project, and a slug cannot be active twice" {
  run "$AQ" add --project g2 --slug dup "x"
  assert_success
  [ "$(field "$(item queued dup)" project)" = game ]
  run "$AQ" add --project game --slug dup "y"
  assert_failure; assert_output --partial "already in the queue: dup"
}

@test "a project inside a repo is runnable; a notes-only one is refused, as dispatch would" {
  run "$AQ" add --project level --slug in-repo "x"
  assert_success
  [ "$(field "$(item queued in-repo)" project)" = level ]
  run "$AQ" add --project app --slug own-name "y"
  assert_success
  run "$AQ" add --project notes --slug notes-only "z"
  assert_failure; assert_output --partial "unknown project: notes"
}

@test "list orders by priority, then queued time, and next is the head" {
  "$AQ" add --project game --slug b-bare "b"
  "$AQ" add --project game --slug c-low --priority low "c"
  "$AQ" add --project game --slug d-urgent --priority urgent "d"
  "$AQ" add --project game --slug e-high --priority high "e"
  run bash -c "'$AQ' list --json | jq -r .slug"
  # A bare add is high, so it queues with the explicit high one, in queued order.
  assert_output $'d-urgent\nb-bare\ne-high\nc-low'
  run "$AQ" next --json
  assert_success
  [ "$(jq -r .slug <<<"$output")" = d-urgent ]
}

@test "after holds an item until that slug is done ok" {
  "$AQ" add --project game --slug first "a"
  "$AQ" add --project game --slug second --priority urgent --after first "b"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first"
  [ "$("$AQ" next --json | jq -r .slug)" = first ]
  "$AQ" move first running
  "$AQ" move first done --status failed
  run "$AQ" next
  assert_failure
  "$AQ" add --project game --slug first "again"
  "$AQ" move first done --status ok
  [ "$("$AQ" next --json | jq -r .slug)" = second ]
}

@test "night and at: tags hold until their time, other tags are labels" {
  "$AQ" add --project game --slug tonight --priority urgent --tags night "a"
  "$AQ" add --project game --slug later --priority high --tags "at:18:00 ui" "b"
  "$AQ" add --project game --slug now --tags ui "c"
  AGENT_QUEUE_NOW=12:00 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = now ]
  AGENT_QUEUE_NOW=18:30 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = later ]
  AGENT_QUEUE_NOW=02:00 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = tonight ]
  AGENT_QUEUE_NIGHT=23:00-06:00 AGENT_QUEUE_NOW=23:30 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = tonight ]
}

@test "a dated at: tag holds across days until its moment; at:HH:MM alone does not" {
  "$AQ" add --project game --slug tomorrow --tags "at:2026-11-05T09:00" "a"
  "$AQ" add --project game --slug clock --tags "at:09:00" "b"
  # 16:00 the day before: the time-of-day tag has passed, the dated one holds.
  AGENT_QUEUE_NOW=2026-11-04T16:00 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = clock ]
  "$AQ" move clock done --status cancelled
  AGENT_QUEUE_NOW=2026-11-04T16:00 run "$AQ" next --json
  assert_failure
  AGENT_QUEUE_NOW=2026-11-05T08:59 run "$AQ" next --json
  assert_failure
  AGENT_QUEUE_NOW=2026-11-05T09:00 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = tomorrow ]
  run "$AQ" add --project game --tags "at:2026-13-01T09:00" "x"
  assert_failure; assert_output --partial "at:YYYY-MM-DDTHH:MM"
}

@test "a pr: tag holds an item until gh says the PR merged, and after still holds with it" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  # gh stub: the state for PR N is the file $SANDBOX/pr-N; every call is logged.
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/gh.log"\ncat "%s/pr-$3"\n' "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh"
  echo OPEN > "$SANDBOX/pr-7"; echo OPEN > "$SANDBOX/pr-8"
  "$AQ" add --project game --slug blocked --priority urgent --tags "pr:Org/game#7" "a"
  "$AQ" add --project game --slug base "b"
  "$AQ" add --project game --slug both --priority urgent --after base --tags "pr:Org/game#8" "c"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"blocked\") | .hold'"
  assert_output "pr:Org/game#7 not merged"
  [ "$("$AQ" next --json | jq -r .slug)" = base ]
  echo MERGED > "$SANDBOX/pr-7"; echo MERGED > "$SANDBOX/pr-8"
  AGENT_QUEUE_PR_TTL=0 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = blocked ]
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"both\") | .hold'"
  assert_output "after base"
  # A merged PR is cached for good: once more with gh failing makes no difference.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"
  [ "$("$AQ" next --json | jq -r .slug)" = blocked ]
  run "$AQ" add --project game --tags "pr:1653" "x"
  assert_failure; assert_output --partial "pr:<owner>/<repo>#<N>"
}

@test "a pr: tag holds while gh cannot read the PR" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
  "$AQ" add --project game --slug blocked --tags "pr:Org/game#9" "a"
  run bash -c "'$AQ' list --json | jq -r '.hold'"
  assert_output "pr:Org/game#9 not merged"
}

@test "a nightly: tag holds while today's scheduled runs go, and releases when they finish" {
  # The desk is in Los Angeles: Tests fires 02:00 and Multi 04:30 on 2026-11-06 (PST).
  export TZ=America/Los_Angeles SCHEDULES_STATE="$SANDBOX/schedules.json"
  # state <synced_at> <multi.yml status>: Tests finished, Multi's run in the given status.
  state() {
    jq -n --arg s "$1" --arg m "$2" '{repos: [{repo: "Org/game", synced_at: $s, workflows: [
      {path: ".github/workflows/multi.yml", crons: ["30 12 * * *"], timeout_min: 300,
       runs: [{id: 2, created_at: "2026-11-06T12:41:00Z", status: $m}]},
      {path: ".github/workflows/test.yml", crons: ["0 10 * * *"], timeout_min: 300,
       runs: [{id: 1, created_at: "2026-11-06T10:04:00Z", status: "completed"}]}]}]}' > "$SCHEDULES_STATE"
  }
  "$AQ" add --project game --slug triage --priority urgent --tags "nightly:game" "a"
  "$AQ" add --project game --slug other "b"
  # No state file yet: held, never released on a guess.
  AGENT_QUEUE_NOW=2026-11-06T05:00 run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"triage\") | .hold'"
  assert_output "nightly:game (no schedules state)"
  state 2026-11-06T12:55:00Z in_progress
  AGENT_QUEUE_NOW=2026-11-06T05:00 run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"triage\") | .hold'"
  assert_output "nightly:game (multi.yml running)"
  [ "$(AGENT_QUEUE_NOW=2026-11-06T05:00 "$AQ" next --json | jq -r .slug)" = other ]
  state 2026-11-06T14:05:00Z completed
  [ "$(AGENT_QUEUE_NOW=2026-11-06T06:10 "$AQ" next --json | jq -r .slug)" = triage ]
  # The same finished file read 40 minutes later is stale, and holds.
  AGENT_QUEUE_NOW=2026-11-06T06:50 run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"triage\") | .hold'"
  assert_output --partial "nightly:game (schedules state for game stale"
  AGENT_QUEUE_NOW=2026-11-06T06:50 run bash -c "'$AQ' stats --json | jq -c .sitting.held_by"
  assert_output '{"nightly":1}'
  run "$AQ" add --project game --tags "nightly:Org/game" "x"
  assert_failure; assert_output --partial "nightly:<repo>"
}

@test "a dated at: tag with a nightly: tag waits for the next night's runs, not today's" {
  export TZ=America/Los_Angeles SCHEDULES_STATE="$SANDBOX/schedules.json"
  jq -n '{repos: [{repo: "Org/game", synced_at: "2026-11-07T09:05:00Z", workflows: [
    {path: ".github/workflows/test.yml", crons: ["0 10 * * *"], timeout_min: 300,
     runs: [{id: 1, created_at: "2026-11-06T10:04:00Z", status: "completed"}]}]}]}' > "$SCHEDULES_STATE"
  "$AQ" add --project game --slug validate --tags "at:2026-11-07T00:00 nightly:game" "a"
  AGENT_QUEUE_NOW=2026-11-06T09:00 run bash -c "'$AQ' list --json | jq -r '.hold'"
  assert_output "at:2026-11-07T00:00"
  AGENT_QUEUE_NOW=2026-11-07T01:00 run bash -c "'$AQ' list --json | jq -r '.hold'"
  assert_output "nightly:game (test.yml due 02:00)"
}

@test "bump changes priority and with it the order" {
  "$AQ" add --project game --slug a "a"
  "$AQ" add --project game --slug b "b"
  run "$AQ" bump b urgent
  assert_success
  [ "$("$AQ" next --json | jq -r .slug)" = b ]
  run "$AQ" bump b soon
  assert_failure
  # NEGATIVE CONTROL: normal is retired; urgent|high|low is the whole set, as on the sheets.
  run "$AQ" bump b normal
  assert_failure; assert_output --partial "urgent, high or low"
  run "$AQ" add --project game --priority normal "x"
  assert_failure
}

@test "move walks the states and stamps each one" {
  "$AQ" add --project game --slug w "w"
  "$AQ" set w session=game-agent-1 account=main
  "$AQ" move w running
  f="$(item running w)"
  [ -n "$(field "$f" started)" ]
  [ "$(field "$f" session)" = lab:game-agent-1 ]
  "$AQ" move w waiting
  [ -n "$(field "$(item waiting w)" waiting)" ]
  run "$AQ" move w done
  assert_failure; assert_output --partial "--status"
  "$AQ" move w done --status ok
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-w.md)"
  [ "$(field "$f" status)" = ok ]
  [ -n "$(field "$f" finished)" ]
  [ "$(field "$f" account)" = main ]
}

@test "a move reports the outcome of the item's model-lane run: ok, failed, redo on a requeue, nothing on a cancel" {
  printf '#!/usr/bin/env bash\necho "model-lane $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/model-lane"
  chmod +x "$SANDBOX/bin/model-lane"
  for s in ok fl rq cx; do "$AQ" add --project game --running --slug "$s" "$s" >/dev/null; "$AQ" set "$s" "lane_run=r-$s" >/dev/null; done
  "$AQ" add --project game --running --slug none "none" >/dev/null
  "$AQ" move ok done --status ok >/dev/null
  "$AQ" move fl done --status failed >/dev/null
  "$AQ" move rq queued >/dev/null
  "$AQ" move cx done --status cancelled >/dev/null
  "$AQ" move none done --status ok >/dev/null
  run grep '^model-lane' "$NOTES_FIXTURE/calls.log"
  assert_output $'model-lane outcome r-ok ok\nmodel-lane outcome r-fl failed\nmodel-lane outcome r-rq redo'
  # The requeued item's next start logs a run of its own.
  [ -z "$(field "$(item queued rq)" lane_run)" ]
}

@test "a failing model-lane never fails the move" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/model-lane"; chmod +x "$SANDBOX/bin/model-lane"
  "$AQ" add --project game --running --slug m "m" >/dev/null; "$AQ" set m lane_run=r1 >/dev/null
  run "$AQ" move m done --status ok
  assert_success
  assert_output --partial 'model-lane outcome r1 ok failed'
  [ -f "$(ls "$AGENT_QUEUE_DIR"/done/*/*-m.md)" ]
}

@test "move --if moves only while the item is still in the state the caller read" {
  "$AQ" add --project game --slug cas "cas" >/dev/null
  "$AQ" move cas running >/dev/null
  run "$AQ" move cas waiting --if queued
  [ "$status" -eq 3 ]
  assert_output --partial "cas is running, not queued: left as it is"
  [ -f "$(item running cas)" ]
  run "$AQ" move cas done --status failed --if queued
  [ "$status" -eq 3 ]
  [ -f "$(item running cas)" ]
  run "$AQ" move cas waiting --if running
  assert_success
  [ -f "$(item waiting cas)" ]
}

@test "move back to queued drops where the item ran and keeps who worked it" {
  "$AQ" add --project game --running --session game-agent-1 --slug b "b"
  "$AQ" set b origin=run account=main
  "$AQ" claim b --sid s1 && "$AQ" claim b --sid s2
  "$AQ" move b waiting
  run "$AQ" move b queued
  assert_success
  f="$(item queued b)"
  for k in session window started waiting origin; do [ -z "$(field "$f" "$k")" ] || { echo "$k left"; return 1; }; done
  [ "$(field "$f" sessions)" = "s1 s2" ]
  [ "$(field "$f" account)" = main ]
  [ "$(field "$f" slug)" = b ]
  [ -n "$(sed -n '/^---$/,$p' "$f" | sed 1d)" ]
}

@test "set refuses identity fields and records the rest, on a done item too" {
  "$AQ" add --project game --slug s "s"
  run "$AQ" set s slug=other
  assert_failure; assert_output --partial "not a settable field: slug"
  run "$AQ" set s queued=now
  assert_failure
  "$AQ" move s done --status ok
  run "$AQ" set s pr=https://example/pr/9 "note=a b c" report=https://example/report cost_usd=4.5 work_min=30
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-s.md)"
  [ "$(field "$f" pr)" = https://example/pr/9 ]
  [ "$(field "$f" cost_usd)" = 4.5 ]
  [ "$(field "$f" work_min)" = 30 ]
  [ "$(field "$f" report)" = https://example/report ]
  [ "$(field "$f" note)" = "a b c" ]
}

@test "a project rename moves the item's board origin with it, so agent-land closes the right row" {
  "$AQ" add --project game --from "board:game:fix the lobby: soon" --slug r "fix the lobby"
  run "$AQ" set r project=level "from=board:level:fix the lobby: soon"
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/queued/*-r.md)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" from)" = "board:level:fix the lobby: soon" ]
}

@test "set refuses a project the registry does not know, or an alias, and writes nothing" {
  "$AQ" add --project game --slug s "fix the lobby"
  run "$AQ" set s project=nowhere
  assert_failure
  assert_output --partial 'unknown project: nowhere'
  run "$AQ" set s project=g2 note=x
  assert_failure
  f="$(ls "$AGENT_QUEUE_DIR"/queued/*-s.md)"
  [ "$(field "$f" project)" = game ]
  [ -z "$(field "$f" note)" ]
}

@test "add --title writes one title line; an item without one has no title key" {
  "$AQ" add --project game --slug t --title $'Fix the  thing\nnow' "the long task text"
  [ "$(field "$(item queued t)" title)" = "Fix the thing now" ]
  "$AQ" add --project game --slug u "no title given"
  ! grep -q '^title:' "$(item queued u)"
}

@test "plan mode and --running are recorded; --running starts in running/" {
  "$AQ" add --project game --mode plan --slug p "plan this"
  [ "$(field "$(item queued p)" mode)" = plan ]
  run "$AQ" add --project game --running --session dotfiles-70 --slug by-hand "this session"
  assert_success
  f="$(item running by-hand)"
  [ "$(field "$f" session)" = lab:dotfiles-70 ]
  [ -n "$(field "$f" started)" ]
}

@test "--running on the agent world records <server>:<session>; off it or outside tmux, none" {
  printf 'dotfiles-agent-9\n' > "$NOTES_FIXTURE/tmux.session"
  TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0" run "$AQ" add --project game --running --slug here "this session"
  assert_success
  [ "$(field "$(item running here)" session)" = lab:dotfiles-agent-9 ]
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.session"
  TMUX="$SANDBOX/tmp/tmux-1000/hub,123,0" run "$AQ" add --project game --running --slug hubbed "from a hub window"
  assert_success
  [ -z "$(field "$(item running hubbed)" session)" ]
  TMUX="$SANDBOX/tmp/tmux-1000/hub,123,0" run "$AQ" add --project game --running --session given --slug given "given"
  [ "$(field "$(item running given)" session)" = lab:given ]
  run "$AQ" add --project game --running --slug nowhere "no tmux"
  [ -z "$(field "$(item running nowhere)" session)" ]
}

@test "a bare session is refused when no world declares @agents, and cancel kills nothing on a value with no server" {
  rm "$HOME/.config/tmux-servers/lab.conf"
  run "$AQ" add --project game --running --session given --slug given "given"
  assert_failure
  assert_output --partial 'no world declares @agents'
  sandbox_worlds
  "$AQ" add --project game --running --session lab:x --slug bare "bare"
  sed -i 's/^session: .*/session: dotfiles/' "$(item running bare)"
  run "$AQ" cancel bare
  assert_success
  assert_not_called 'kill-session'
}

@test "mine: the active item this tmux session records; none exits 1, two exit 2" {
  printf 'dotfiles-agent-9\n' > "$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0"
  run "$AQ" mine
  assert_failure 1
  "$AQ" add --project game --running --slug here "this session"
  "$AQ" add --project game --running --session lab:other --slug elsewhere "another session"
  run "$AQ" mine
  assert_success
  assert_output here
  run "$AQ" mine --session lab:other
  assert_output elsewhere
  "$AQ" add --project game --running --slug second "a second task here"
  run "$AQ" mine
  assert_failure 2
  "$AQ" move here done --status ok
  "$AQ" move second done --status ok
  run "$AQ" mine
  assert_failure 1
}

@test "mine: a waiting item of the same tmux session is not this one's; only a running one is" {
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0"
  "$AQ" add --project game --running --session lab:dotfiles --slug earlier "an earlier conversation"
  "$AQ" move earlier waiting
  run "$AQ" mine
  assert_failure 1
}

@test "mine: the Claude session decides first, across tmux sessions and in waiting; none with a session id exits 1" {
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0"
  "$AQ" add --project game --running --session lab:dotfiles --slug tmux-only "an item of the same tmux session"
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --running --slug ours "this conversation's item"
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" mine
  assert_success
  assert_output ours
  "$AQ" move ours waiting
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" mine
  assert_output ours
  unset TMUX
  CLAUDE_CODE_SESSION_ID=sid-none run "$AQ" mine
  assert_failure 1
}

@test "mine --sid: that Claude session's item only, never the tmux session's; two exit 2" {
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0"
  "$AQ" add --project game --running --session lab:dotfiles --slug tmux-only "an item of the same tmux session"
  run "$AQ" mine --sid sid-none
  assert_failure 1
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --running --slug ours "this conversation's item"
  CLAUDE_CODE_SESSION_ID=sid-other run "$AQ" mine --sid sid-a
  assert_success
  assert_output ours
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --running --slug second "another"
  run "$AQ" mine --sid sid-a
  assert_failure 2
}

@test "add --running records the Claude session, a queued add does not; the row grammar's type and area; claim adds a session once" {
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --running --slug typed "fix(agent-land): mine picks a waiting item"
  f="$(item running typed)"
  [ "$(field "$f" sessions)" = sid-a ]
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --slug later "queued for another session"
  [ -z "$(field "$(item queued later)" sessions)" ]
  [ "$(field "$f" type)" = fix ]
  [ "$(field "$f" area)" = agent-land ]
  "$AQ" add --project game --slug untyped "Menu: pick sides"
  [ -z "$(field "$(item queued untyped)" sessions)" ]
  [ -z "$(field "$(item queued untyped)" type)" ]
  "$AQ" add --project game --slug titled --title "feat(queue): a ledger" "the long brief"
  [ "$(field "$(item queued titled)" area)" = queue ]
  run "$AQ" claim typed --sid sid-b
  assert_success
  CLAUDE_CODE_SESSION_ID=sid-b run "$AQ" claim typed
  assert_output --partial "already claimed"
  [ "$(field "$f" sessions)" = "sid-a sid-b" ]
  run "$AQ" claim typed --sid 'x;rm'
  assert_failure
  run "$AQ" claim typed
  assert_failure
  assert_output --partial "no Claude session"
  "$AQ" move typed done --status ok
  run "$AQ" claim typed --sid sid-c
  assert_failure
}

@test "a plan item starts its session at once; a failed start leaves it queued; AGENT_QUEUE_START=0 only queues" {
  run "$AQ" add --project game --mode plan --slug p1 "plan this"
  assert_success
  assert_called 'fleet-dispatch start --item p1'
  FD_EXIT=1 run "$AQ" add --project game --mode plan --slug p2 "plan that"
  assert_success
  assert_output --partial 'p2 could not start now, so it stays queued'
  [ -f "$(item queued p2)" ]
  AGENT_QUEUE_START=0 run "$AQ" add --project game --mode plan --slug p3 "plan later"
  assert_success
  assert_not_called 'start --item p3'
  run "$AQ" add --project game --slug o1 "one shot"
  assert_not_called 'start --item o1'
}

@test "the next phase starts when its parent closes ok; not on failed, not past an open hold, not when dispatch is held" {
  printf '#!/usr/bin/env bash\nexit "${HOLD_EXIT:-0}"\n' > "$SANDBOX/bin/agent-hold"; chmod +x "$SANDBOX/bin/agent-hold"
  "$AQ" add --project game --running --slug ph1 "phase 1" >/dev/null
  "$AQ" add --project game --slug ph2 --after ph1 "phase 2" >/dev/null
  "$AQ" add --project game --slug other "unrelated" >/dev/null
  run "$AQ" move ph1 done --status ok
  assert_success
  assert_called 'fleet-dispatch start --item ph2'
  assert_not_called 'start --item other'
  # A failed parent leaves its next phase held.
  "$AQ" add --project game --running --slug f1 "fails" >/dev/null
  "$AQ" add --project game --slug f2 --after f1 "after a failure" >/dev/null
  run "$AQ" move f1 done --status failed
  assert_not_called 'start --item f2'
  # Another hold on the next item still holds it.
  "$AQ" add --project game --running --slug t1 "tagged parent" >/dev/null
  AGENT_QUEUE_NOW=08:00 "$AQ" add --project game --slug t2 --after t1 --tags at:23:59 "later today" >/dev/null
  AGENT_QUEUE_NOW=08:00 run "$AQ" move t1 done --status ok
  assert_not_called 'start --item t2'
  # A dispatch hold keeps it queued for the pass.
  "$AQ" add --project game --running --slug h1 "held parent" >/dev/null
  "$AQ" add --project game --slug h2 --after h1 "held next" >/dev/null
  HOLD_EXIT=1 run "$AQ" move h1 done --status ok
  assert_success
  assert_output --partial 'dispatch is held, so h2 stays queued'
  assert_not_called 'start --item h2'
  [ -f "$(item queued h2)" ]
  # A start that fails leaves it queued.
  "$AQ" add --project game --running --slug x1 "parent" >/dev/null
  "$AQ" add --project game --slug x2 --after x1 "next" >/dev/null
  FD_EXIT=1 run "$AQ" move x1 done --status ok
  assert_success
  assert_output --partial 'x2 could not start now, so it stays queued'
  AGENT_QUEUE_START=0 "$AQ" add --project game --running --slug z1 "parent" >/dev/null
  "$AQ" add --project game --slug z2 --after z1 "next" >/dev/null
  AGENT_QUEUE_START=0 run "$AQ" move z1 done --status ok
  assert_not_called 'start --item z2'
}

plan_fixture() {
  cat > "$SANDBOX/my-plan.md" <<'EOF'
# A plan

## Phases

- [x] 1. Landed thing: details
- [ ] 2. Second thing: details
  - [ ] a step inside phase 2
- [-] 3. Deferred thing
- [ ] 4. Fourth thing. More words
- [ ] 5. Fifth thing (with 4): shares the branch of 4
- [ ] 6. Sixth thing

## Verification

- [ ] not a phase
EOF
}

@test "add --plan queues one oneshot item per unchecked phase, each after the one before; --dry-run writes nothing" {
  plan_fixture
  "$AQ" add --project game --slug base "the work before the plan" >/dev/null
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --after base --dry-run
  assert_success
  assert_line --index 0 --regexp '^would queue my-plan-p2	phases 2	after base$'
  assert_line --index 2 --regexp '^would queue my-plan-p4	phases 4 5	after my-plan-p2$'
  assert_line --index 4 --regexp '^would queue my-plan-p6	phases 6	after my-plan-p4$'
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 1 ]
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --after base --priority high --tags night
  assert_success
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 4 ]
  f="$(item queued my-plan-p2)"
  [ "$(field "$f" mode)" = oneshot ]
  [ "$(field "$f" after)" = base ]
  [ "$(field "$f" plan)" = "$SANDBOX/my-plan.md" ]
  [ "$(field "$f" phases)" = 2 ]
  [ "$(field "$f" priority)" = high ]
  [ "$(field "$f" tags)" = night ]
  [ "$(field "$f" title)" = "my-plan P2: Second thing: details" ]
  grep -qF "Phase 2 of the plan $SANDBOX/my-plan.md: Second thing. Read the plan whole, then do ONLY this phase, to merged." "$f"
  f="$(item queued my-plan-p4)"
  [ "$(field "$f" after)" = my-plan-p2 ]
  [ "$(field "$f" phases)" = "4 5" ]
  [ "$(field "$f" title)" = "my-plan P4+5: Fourth thing. More words; Fifth thing: shares the branch of 4" ]
  grep -qF "Phases 4 and 5 of the plan $SANDBOX/my-plan.md: Fourth thing; Fifth thing. Read the plan whole, then do ONLY these phases, on one branch" "$f"
  [ "$(field "$(item queued my-plan-p6)" after)" = my-plan-p4 ]
  ! grep -qs "fleet-dispatch" "$NOTES_FIXTURE/calls.log"
}

@test "add --plan writes nothing when a slug is taken, and refuses what it cannot expand" {
  plan_fixture
  "$AQ" add --project game --slug my-plan-p6 "already queued by hand" >/dev/null
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game
  assert_failure
  assert_output --partial "already in the queue: my-plan-p6 (nothing was added)"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 1 ]
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --slug other "a task too"
  assert_failure
  assert_output --partial "pass no task with it"
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --slug other --mode plan
  assert_failure
  printf '# no checklist\n' > "$SANDBOX/empty.md"
  run "$AQ" add --plan "$SANDBOX/empty.md" --project game
  assert_failure
  assert_output --partial "no unchecked phase"
  run "$AQ" add --plan "$SANDBOX/missing.md" --project game
  assert_failure
  run "$AQ" add --project game --dry-run "a task"
  assert_failure
  assert_output --partial "--dry-run goes with --plan"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 1 ]
}

@test "add --plan refuses a plan another active item names; the calling session's own item does not count" {
  plan_fixture
  "$AQ" add --project game --slug mine --running "phase 1 of $SANDBOX/my-plan.md" >/dev/null
  AGENT_QUEUE_ITEM=mine run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --dry-run
  assert_success
  # queued by hand from the plan's copy in another directory: the file name matches
  "$AQ" add --project game --slug by-hand "Phase 2 of /home/x/.agent/plans/game/my-plan.md" >/dev/null
  AGENT_QUEUE_ITEM=mine run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game
  assert_failure
  assert_output --partial "already queued: by-hand (nothing was added)"
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --dry-run
  assert_failure
  assert_output --regexp "already queued: (mine by-hand|by-hand mine) "
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" | grep my-plan)" ]
}

@test "cancel moves a queued item to done, and kills the session dispatch made for a running item" {
  "$AQ" add --project game --slug q "q"
  run "$AQ" cancel q
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-q.md)" status)" = cancelled ]
  run grep -c kill-session "$NOTES_FIXTURE/calls.log"
  assert_output 0
  "$AQ" add --project game --running --session game-agent-2 --slug r "r"
  "$AQ" set r origin=run
  run "$AQ" cancel r
  assert_success
  run grep -- "-L lab kill-session -t =game-agent-2" "$NOTES_FIXTURE/calls.log"
  assert_success
  run "$AQ" cancel r
  assert_failure; assert_output --partial "nothing active"
  # fleet-dispatch writes <server>:<tmux session>: the kill goes to that server.
  "$AQ" add --project game --running --session default:game-agent-3 --slug s "s"
  "$AQ" set s origin=hand
  run "$AQ" cancel s
  assert_success
  run grep -- "-L default kill-session -t =game-agent-3" "$NOTES_FIXTURE/calls.log"
  assert_success
}

# 2026-11-04: cancelling an item hand-started in a hub:dotfiles window killed hub:dotfiles and
# every window in it. A hand start now records no hub session, but items that name one exist.
@test "cancel of an item recorded on a hub:dotfiles window closes its window, never the session" {
  "$AQ" add --project game --running --session hub:dotfiles --slug by-hand "by hand"
  "$AQ" set by-hand window=@9
  run "$AQ" cancel by-hand
  assert_success
  assert_output --partial "closed window @9 of dotfiles"
  run grep -- "tmux -L hub kill-window -t @9" "$NOTES_FIXTURE/calls.log"
  assert_success
  run grep -c kill-session "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a hand start on the agent world records its window, and cancel closes only that" {
  echo game-agent-1 > "$NOTES_FIXTURE/tmux.session"
  TMUX="/tmp/tmux-1000/lab,1,0" TMUX_PANE=%31 STUB_WINDOW_ID=@9 \
    "$AQ" add --project game --running --slug by-hand "by hand"
  f="$(item running by-hand)"
  [ "$(field "$f" session)" = lab:game-agent-1 ]
  [ "$(field "$f" window)" = @9 ]
  run "$AQ" cancel by-hand
  assert_success
  run grep -- "tmux -L lab kill-window -t @9" "$NOTES_FIXTURE/calls.log"
  assert_success
  run grep -c kill-session "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "cancel of a hand-started item that recorded no window kills nothing" {
  "$AQ" add --project game --running --session hub:dotfiles --slug old "recorded before windows were"
  run "$AQ" cancel old
  assert_success
  assert_output --partial "left hub:dotfiles open"
  run grep -cE "kill-(session|window)" "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "cancel never kills a world session, even one an item says dispatch made" {
  export TMUX_SERVERS_DIR="$REPO_ROOT/.config/tmux-servers"
  "$AQ" add --project game --running --session hub:dotfiles --slug wrong "a bad record"
  "$AQ" set wrong origin=run
  run "$AQ" cancel wrong
  assert_success
  assert_output --partial "dotfiles is a world session"
  run grep -c kill-session "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "the same slug finished twice in a day keeps both records" {
  "$AQ" add --project game --slug twice "1"
  "$AQ" cancel twice
  "$AQ" add --project game --slug twice "2"
  "$AQ" cancel twice
  [ "$(ls "$AGENT_QUEUE_DIR"/done/*/ | grep -c twice)" -eq 2 ]
  run bash -c "'$AQ' show twice | tail -1"
  assert_output 2
}

@test "list --since reads done items from that day on, across days" {
  local slug day
  for slug in old edge new; do "$AQ" add --project game --slug "$slug" "t"; "$AQ" cancel "$slug"; done
  for slug in old:2026-11-01 edge:2026-11-02 new:2026-11-03; do
    day="$AGENT_QUEUE_DIR/done/${slug#*:}"; mkdir -p "$day"
    mv "$AGENT_QUEUE_DIR"/done/"$(date +%F)"/*-"${slug%:*}".md "$day/"
  done
  run bash -c "'$AQ' list --state done --since 2026-11-02 --json | jq -r .slug | sort | tr '\n' ' '"
  assert_output "edge new "
}

@test "list groups by state and says when nothing is there" {
  run "$AQ" list
  assert_output --partial "nothing"
  "$AQ" add --project game --slug q1 "q"
  "$AQ" add --project game --running --session s1 --slug r1 "r"
  "$AQ" add --project game --slug d1 "d"; "$AQ" cancel d1
  run bash -c "'$AQ' list | cut -f1,3"
  assert_output $'running\tr1\nqueued\tq1'
  run bash -c "'$AQ' list --state all --json | jq -r .state | sort | uniq -c | awk '{print \$2\":\"\$1}' | tr '\n' ' '"
  assert_output "done:1 queued:1 running:1 "
}

@test "stats counts states, outcomes, waits, time to PR and sources from the timestamps" {
  "$AQ" add --project game --slug a "a"
  "$AQ" add --project app --slug b --from shepherd --tags night "b"
  "$AQ" add --project game --slug c --from board:game:fix-x "c"
  "$AQ" move a running
  "$AQ" set a started=2026-11-03T10:30:00Z
  f="$(item running a)"; sed -i 's/^queued: .*/queued: 2026-11-03T10:00:00Z/' "$f"
  "$AQ" move a done --status ok
  "$AQ" set a finished=2026-11-03T11:30:00Z pr=812
  "$AQ" move b done --status cancelled
  "$AQ" set b finished=2026-11-02T09:00:00Z
  # d started the minute it was added (--running): it is counted apart, not as a 0 min wait.
  "$AQ" add --project game --slug d --running "d"
  # c can start and has sat two hours; e waits on c.
  f="$(item queued c)"; sed -i "s/^queued: .*/queued: $(date -u -d '2 hours ago' +%FT%TZ)/" "$f"
  "$AQ" add --project game --slug e --after c "e"
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  [ "$(jq -r '.active.queued' <<<"$output")" = 2 ]
  [ "$(jq -r '.started_at_once' <<<"$output")" = 1 ]
  [ "$(jq -r '.wait_minutes_p90' <<<"$output")" = 30 ]
  [ "$(jq -c '.sitting | [.queued, .runnable, .held, .held_by.after, .runnable_age_minutes_median]' <<<"$output")" = '[2,1,1,1,120]' ]
  [ "$(jq -c '.sitting.oldest_runnable | map([.slug, .minutes])' <<<"$output")" = '[["c",120]]' ]
  [ "$(jq -r '.added_per_day | add' <<<"$output")" = 5 ]
  [ "$(jq -r '.done.ok' <<<"$output")" = 1 ]
  [ "$(jq -r '.done.cancelled' <<<"$output")" = 1 ]
  [ "$(jq -r '.wait_minutes_median' <<<"$output")" = 30 ]
  [ "$(jq -r '.run_minutes_median' <<<"$output")" = 60 ]
  [ "$(jq -r '.to_pr_minutes_median' <<<"$output")" = 90 ]
  [ "$(jq -c '.per_day' <<<"$output")" = '{"2026-11-02":1,"2026-11-03":1}' ]
  [ "$(jq -c '.by_source.shepherd | [.done, .cancelled, .prs]' <<<"$output")" = '[1,1,0]' ]
  [ "$(jq -c '.by_project.game | [.done, .ok, .prs, .wait_minutes_median, .to_pr_minutes_median]' <<<"$output")" = '[1,1,1,30,90]' ]
  [ "$(jq -r '.done_by_tag.night' <<<"$output")" = 1 ]
  run "$AQ" stats
  assert_success
  assert_output --partial "done:"
  assert_output --partial "to PR:   median 90 min"
  assert_output --partial "wait:    median 30 min, p90 30 min from ready to started, 1 started at once and not counted"
  assert_output --partial "sitting: 1 can start, oldest 2h (c), median 2h; 1 held (after 1)"
  assert_output --partial "project: app 1 (0 PR), game 1 (1 PR)"
}

@test "stats wait for an after: item runs from its predecessor's finish, not from when it was queued" {
  "$AQ" add --project game --slug p "p"
  "$AQ" add --project game --slug f --after p "f"
  "$AQ" move p running; "$AQ" move p done --status ok
  "$AQ" set p finished=2026-11-03T12:00:00Z
  f="$(item queued f)"; sed -i 's/^queued: .*/queued: 2026-11-03T08:00:00Z/' "$f"
  "$AQ" move f running; "$AQ" set f started=2026-11-03T12:10:00Z
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  assert_equal "$(jq -c '[.wait_minutes_median, .wait_minutes_p90]' <<<"$output")" '[10,10]'
  # negative control: with its predecessor gone from the store, the wait runs from queued
  rm "$AGENT_QUEUE_DIR"/done/*/*-p.md
  run "$AQ" stats --json --since 2000-01-01
  assert_equal "$(jq -c '.wait_minutes_median' <<<"$output")" '250'
}

@test "stats flow: each stage counts on the local day it was reached, with lead, wait and run time" {
  export TZ=America/Los_Angeles
  "$AQ" add --project game --slug a "a"
  "$AQ" move a running
  "$AQ" set a started=2026-11-03T10:30:00Z
  f="$(item running a)"; sed -i 's/^queued: .*/queued: 2026-11-03T10:00:00Z/' "$f"
  "$AQ" move a done --status ok
  "$AQ" set a finished=2026-11-03T11:30:00Z
  "$AQ" add --project game --slug b "b"
  f="$(item queued b)"; sed -i 's/^queued: .*/queued: 2026-11-04T02:00:00Z/' "$f"
  "$AQ" move b done --status failed
  "$AQ" set b finished=2026-11-04T03:00:00Z
  run "$AQ" stats --json --flow --since 2026-11-03
  assert_success
  assert_equal "$(jq -c '.flow["2026-11-03"] | [.queued, .started, .done, .ok, .failed, .lead_minutes, .wait_minutes.p50, .run_minutes.p50]' <<<"$output")" '[2,1,2,1,1,{"n":2,"p50":90,"p90":90},30,60]'
  run "$AQ" stats --json --flow --since 2026-11-04
  [ "$(jq -c '.flow | has("2026-11-03")' <<<"$output")" = false ]
}

@test "stats counts the flow of the last 1, 6 and 24 hours: added by queued, started by started, done and failed by finished" {
  ago() { date -u -d "$1 ago" +%FT%TZ; }
  for spec in "a 3hours 30minutes ok" "b 10hours 5hours failed" "c 30hours 20hours ok"; do
    set -- $spec
    "$AQ" add --project game --slug "$1" "$1"
    "$AQ" move "$1" done --status "$4"
    "$AQ" set "$1" "finished=$(ago "$3")" "started=$(ago "$3")"
    f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-"$1".md)"; sed -i "s/^queued: .*/queued: $(ago "$2")/" "$f"
  done
  "$AQ" add --project game --slug d "d"
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  assert_equal "$(jq -c '.recent | [.done_1h, .done_6h, .done_24h, .added_1h, .added_6h, .added_24h]' <<<"$output")" '[1,2,3,1,2,3]'
  assert_equal "$(jq -c '.recent | [.failed_1h, .failed_6h, .failed_24h, .started_1h, .started_6h, .started_24h]' <<<"$output")" '[0,1,1,1,2,3]'
}

@test "stats done_today counts ok items since local midnight, never the UTC day or a failed item" {
  export TZ=Etc/GMT+8 # west of UTC: last night's 23:59 local is already today in UTC
  today="$(date +%F)"
  at() { date -u -d "@$(date -d "$1" +%s)" +%FT%TZ; } # -u alone would read $1 as UTC
  for spec in "a|$today 00:00:01|ok" "b|$(date -d yesterday +%F) 23:59:59|ok" "c|$today 00:00:02|failed"; do
    IFS='|' read -r slug when status <<<"$spec"
    "$AQ" add --project game --slug "$slug" "$slug"
    "$AQ" move "$slug" done --status "$status"
    "$AQ" set "$slug" "finished=$(at "$when")" "started=$(at "$when")"
  done
  run "$AQ" stats --json --since 2000-01-01
  assert_success
  assert_equal "$(jq -c .recent.done_today <<<"$output")" 1
}

@test "a slug is matched exactly, never as the tail of a longer one" {
  "$AQ" add --project game --slug x-first "x"
  "$AQ" add --project game --slug second --after first-missing "y" 2>/dev/null || true
  run "$AQ" add --project game --slug second --after first "y"
  assert_failure; assert_output --partial "no item has that slug"
  run "$AQ" cancel first
  assert_failure
  "$AQ" add --project game --slug first "f"
  run "$AQ" bump first urgent
  assert_success
  [ "$(field "$(item queued x-first)" priority)" = high ]
}

@test "a read waits for a writer, so a list never misses an item mid-move" {
  "$AQ" add --project game "one item" >/dev/null
  # Hold the writers' lock; a read must block on it, not read a half-moved store.
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  run timeout 1 "$AQ" list --json
  [ "$status" -eq 124 ]
  flock -u 9
  run "$AQ" list --json
  assert_success
  [ "$(jq -r .slug <<<"$output")" = one-item ]
  # A store that does not exist yet reads as empty and is not created by the read.
  rm -rf "$AGENT_QUEUE_DIR"
  run "$AQ" list
  assert_success
  [ ! -e "$AGENT_QUEUE_DIR" ]
}

@test "add files a repo with an owner under its owner, and set refuses the repo name" {
  run "$AQ" add --project tools --slug tool "x"
  assert_success
  [ "$(field "$(item queued tool)" project)" = cockpit ]
  run "$AQ" set tool project=tools
  assert_failure; assert_output --partial "unknown project: tools"
}

@test "add credits the sheet the item's row is on when it shares the checkout" {
  "$AQ" add --project game --from board:level:lv-3 --slug from-row "x"
  [ "$(field "$(item queued from-row)" project)" = level ]
  "$AQ" add --project tools --from board:cockpit:c-1 --slug from-owner-row "x"
  [ "$(field "$(item queued from-owner-row)" project)" = cockpit ]
  # Negative control: a row on a project in another checkout leaves the item where it was filed.
  "$AQ" add --project game --from board:app:a-1 --slug other-checkout "x"
  [ "$(field "$(item queued other-checkout)" project)" = game ]
}

@test "add --plan credits the sheet whose row code the plan's epic: line carries" {
  P="$SANDBOX/epic.md"
  printf '%s\n' '# Arena' '' 'epic: ar-12' '' '## Phases' '' '- [ ] P1 one' > "$P"
  run "$AQ" add --plan "$P" --project game --slug ep
  assert_success
  [ "$(field "$(item queued ep-p1)" project)" = arena ]
  printf '%s\n' 'epic: el-4' '## Phases' '- [ ] P1 one' > "$SANDBOX/far.md"
  "$AQ" add --plan "$SANDBOX/far.md" --project game --slug far
  [ "$(field "$(item queued far-p1)" project)" = game ]
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/none.md"
  "$AQ" add --plan "$SANDBOX/none.md" --project game --slug none
  [ "$(field "$(item queued none-p1)" project)" = game ]
}

@test "attribute credits the game that owns the most changed files and records every one touched" {
  "$AQ" add --project game --slug pr-a "x"
  run "$AQ" attribute pr-a <<<$'Assets/Arena/A.cs\nAssets/Arena/B.cs\nAssets/Level/L.cs\nAssets/Shared/S.cs'
  assert_success; assert_output "credited to arena (touches arena level)"
  f="$(item queued pr-a)"
  [ "$(field "$f" project)" = arena ]
  [ "$(field "$f" touches)" = "arena level" ]
  # A game's item stays in its repo's candidates: its own game's files can move it again.
  run "$AQ" attribute pr-a <<<'Assets/Level/L.cs'
  assert_output "credited to level (touches level)"
}

@test "attribute leaves the project on shared files, a tie, a prefix lookalike or a repo with no games" {
  "$AQ" add --project game --slug shared "x"
  run "$AQ" attribute shared <<<$'Assets/Shared/S.cs\nAssets/LevelEditor/E.cs\nProjectSettings/x.asset'
  assert_success; assert_output ''
  f="$(item queued shared)"
  [ "$(field "$f" project)" = game ]
  [ -z "$(field "$f" touches)" ]
  run "$AQ" attribute shared <<<$'Assets/Arena/A.cs\nAssets/Level/L.cs'
  assert_output "touches arena level"
  [ "$(field "$f" project)" = game ]
  "$AQ" add --project app --slug app-pr "y"
  run "$AQ" attribute app-pr <<<'Assets/Level/L.cs'
  assert_success; assert_output ''
  [ "$(field "$(item queued app-pr)" project)" = app ]
  run "$AQ" attribute nope </dev/null
  assert_failure; assert_output --partial "no item: nope"
}

@test "credit-of prints what attribute would record and writes nothing" {
  run "$AQ" credit-of game <<<$'Assets/Arena/A.cs\nAssets/Arena/B.cs\nAssets/Level/L.cs'
  assert_success; assert_output $'arena\tarena level'
  run "$AQ" credit-of game <<<$'Assets/Arena/A.cs\nAssets/Level/L.cs'
  assert_output $'\tarena level'
  run "$AQ" credit-of game <<<'Assets/Shared/S.cs'
  assert_success; assert_output ''
  [ ! -e "$AGENT_QUEUE_DIR" ]
}

@test "a close names the items it releases, and one whose plan phases are already ticked closes instead of starting" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/agent-hold"; chmod +x "$SANDBOX/bin/agent-hold"
  plan_fixture
  "$AQ" add --project game --running --slug base "the work before the plan" >/dev/null
  "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --after base >/dev/null
  # Another session landed phase 2 and ticked it; its queue item never heard.
  sed -i 's/^- \[ \] 2\. Second/- [x] 2. Second/' "$SANDBOX/my-plan.md"
  run "$AQ" move base done --status ok
  assert_success
  assert_line "base releases: my-plan-p2"
  assert_output --partial "my-plan-p2: its plan phases are already ticked, so it closes instead of starting"
  assert_line "my-plan-p2 releases: my-plan-p4"
  assert_not_called 'start --item my-plan-p2'
  assert_called 'fleet-dispatch start --item my-plan-p4'
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-my-plan-p2.md)"
  [ "$(field "$f" status)" = ok ]
  [ "$(field "$f" note)" = "its plan phases were ticked before base closed" ]
  # Phases 4 and 5 travel together: one still open, so the item is not landed.
  sed -i 's/^- \[ \] 4\. Fourth/- [x] 4. Fourth/' "$SANDBOX/my-plan.md"
  "$AQ" add --project game --running --slug base2 "another parent" >/dev/null
  "$AQ" set my-plan-p6 after=base2 >/dev/null
  run "$AQ" move base2 done --status ok
  assert_called 'fleet-dispatch start --item my-plan-p6'
}

# story_notes -- give the level and arena games a lab sheet, and a notes stub for the story write:
# every call lands in calls.log; `ptask ... add` prints its row with id lv-9 and exits 0, or, with
# story.rc set, prints story.out on stderr and exits story.rc (3 is ptask's "already open").
# `ptask ... propose` prints propose.out, else its words unchanged; propose.rc makes it refuse.
story_notes() {
  jq '.trackers.level.lab = "bnb" | .trackers.arena.lab = "bnb"' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m.json"
  mv "$SANDBOX/m.json" "$AGENT_QUEUE_PROJECT_MAP"
  cat > "$SANDBOX/bin/notes" <<'STUB'
#!/usr/bin/env bash
printf 'notes %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
case " $* " in
*' propose '*)
  if [ -e "$NOTES_FIXTURE/propose.rc" ]; then echo "error: unrecognized subcommand 'propose'" >&2; exit 2; fi
  if [ -e "$NOTES_FIXTURE/propose.out" ]; then cat "$NOTES_FIXTURE/propose.out"; else printf '%s\n' "${@: -1}"; fi
  exit 0 ;;
*' add '*)
  rc=$(cat "$NOTES_FIXTURE/story.rc" 2>/dev/null || echo 0)
  if [ "$rc" = 0 ]; then printf -- '- [ ] %s #c1105 <!-- id:lv-9 -->\n' "${@: -1}"; else cat "$NOTES_FIXTURE/story.out" >&2; fi
  exit "$rc" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/notes"
}

@test "a canary item files no story row, and --from takes only the known origins" {
  story_notes
  run "$AQ" add --project level --from canary --tags 'night canary' --slug c1 "check(canary): greet 2026w45"
  assert_success
  refute_output --partial 'story'
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  [ "$(field "$(item queued c1)" from)" = canary ]
  run "$AQ" add --project game --from robot --slug c2 "x"
  assert_failure
  assert_output --partial 'human, shepherd, canary or board'
}

@test "add files a started story row under the item's epic and links it as row:" {
  story_notes
  run "$AQ" add --project game --epic lv-3 --priority low --slug menus "feat(menu): live main menus #night"
  assert_success
  assert_line "story lv-9 on the level agent board, under lv-3"
  run grep '^notes' "$NOTES_FIXTURE/calls.log"
  assert_line --index 0 'notes --profile bnb ptask level --agent propose -- feat(menu): live main menus'
  assert_line --index 1 'notes --profile bnb ptask level --agent add -- feat(menu): live main menus #size/s #low #of/lv-3'
  assert_line --index 2 'notes --profile bnb ptask level --agent start lv-9'
  f="$(item queued menus)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" row)" = level:lv-9 ]
  [ "$(field "$f" lane)" = agent ]
  [ "$(field "$f" profile)" = bnb ]
  [ "$(jq -r .row <<<"$("$AQ" show menus --json)")" = level:lv-9 ]
}

@test "a plan item's story takes the plan's epic and a heavy item is sized m" {
  story_notes
  printf '%s\n' 'epic: lv-3' '## Phases' '- [ ] P1 one' > "$SANDBOX/lv.md"
  echo 'feat(level): lv P1: one' > "$NOTES_FIXTURE/propose.out"
  run "$AQ" add --plan "$SANDBOX/lv.md" --project game --weight heavy --slug lvp
  assert_success
  run grep -c -- '--agent propose -- lv P1: P1 one$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -c -- '--agent add -- feat(level): lv P1: one #size/m #high #of/lv-3$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  [ "$(field "$(item queued lvp-p1)" row)" = level:lv-9 ]
}

@test "an epic of another project is not linked, and a long title becomes the row's detail" {
  story_notes
  long="fix(menu): $(printf 'word%.0s ' {1..20})end"
  echo 'fix(menu): word word' > "$NOTES_FIXTURE/propose.out"
  "$AQ" add --project level --epic el-3 --slug far-epic -- "$long"
  run grep -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "--agent add --detail $long -- fix(menu): word"
  refute_output --partial '#of/'
  [ "${#long}" -gt 80 ]
}

@test "an open twin row is linked, and started only when no item has started it" {
  story_notes
  echo 3 > "$NOTES_FIXTURE/story.rc"
  echo 'already open on /x/agent/README.md: - [ ] feat(menu): twin #size/s <!-- id:lv-4 -->' > "$NOTES_FIXTURE/story.out"
  run "$AQ" add --project level --slug twin "feat(menu): twin"
  assert_success
  [ "$(field "$(item queued twin)" row)" = level:lv-4 ]
  run grep -c -- '--agent start lv-4' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  echo 'already open on /x/agent/README.md: - [/] feat(menu): taken <!-- id:lv-5 -->' > "$NOTES_FIXTURE/story.out"
  "$AQ" add --project level --slug taken "feat(menu): taken"
  [ "$(field "$(item queued taken)" row)" = level:lv-5 ]
  run grep -c -- '--agent start lv-5' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a notes that cannot type the words files no row and never stops the add" {
  story_notes
  touch "$NOTES_FIXTURE/propose.rc"
  run "$AQ" add --project level --slug no-verb "x"
  assert_success
  assert_output --partial "no story row filed on level: error: unrecognized subcommand 'propose'"
  [ -z "$(field "$(item queued no-verb)" row)" ]
  run grep -c -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a failed story write never stops the add: the item is written with no row" {
  story_notes
  echo 1 > "$NOTES_FIXTURE/story.rc"
  echo 'error: no such project' > "$NOTES_FIXTURE/story.out"
  run "$AQ" add --project level --slug no-sheet "x"
  assert_success
  assert_output --partial "no story row filed on level: error: no such project"
  [ -z "$(field "$(item queued no-sheet)" row)" ]
}

@test "a board item and a project with no lab sheet file no story; a board item's row is its origin" {
  story_notes
  "$AQ" add --project game --from board:level:lv-2 --slug promoted "x"
  "$AQ" add --project game --slug no-lab "y"
  # The item's own chain event is the one notes call.
  run grep -c '^notes ptask' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  [ "$(jq -r .row <<<"$("$AQ" show promoted --json)")" = level:lv-2 ]
  [ "$(jq -r '.row // "none"' <<<"$("$AQ" show no-lab --json)")" = none ]
  run "$AQ" add --project game --epic menus --slug bad "z"
  assert_failure; assert_output --partial "--epic is a row id"
}

@test "every item write appends one queue event naming the item, its row and its PR" {
  story_notes
  "$AQ" add --project game --from board:level:lv-2 --slug chain "x" >/dev/null
  "$AQ" set chain pr=o/r#7 >/dev/null
  "$AQ" move chain running >/dev/null
  "$AQ" move chain done --status ok >/dev/null
  "$AQ" add --project game --from board:level:lv-3 --slug gone "y" >/dev/null
  "$AQ" cancel gone >/dev/null
  run grep -o 'ingest record --stage queue --action [a-z-]* --from level --item [a-z]* --id [a-z0-9-]*' "$NOTES_FIXTURE/calls.log"
  assert_output - <<'OUT'
ingest record --stage queue --action item-added --from level --item chain --id lv-2
ingest record --stage queue --action item-set --from level --item chain --id lv-2
ingest record --stage queue --action item-moved --from level --item chain --id lv-2
ingest record --stage queue --action item-moved --from level --item chain --id lv-2
ingest record --stage queue --action item-added --from level --item gone --id lv-3
ingest record --stage queue --action item-cancelled --from level --item gone --id lv-3
OUT
  run grep -c -- '--action item-moved .*--pr o/r#7 .*--to done --why running -> done (ok)' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "an item write never fails on its event: a notes that cannot record leaves the write standing" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$AQ" add --project game --from board:level:lv-2 --slug sturdy "x"
  assert_success
  run "$AQ" move sturdy running
  assert_success
  assert_output "sturdy: queued -> running"
}
