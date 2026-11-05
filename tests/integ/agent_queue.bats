#!/usr/bin/env bats
# agent-queue - the store and verb contract: add, order, holds, cancel, bump, set, move, stats.
# Everything lives in the sandbox HOME; tmux is the recording stub.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  AQ="$REPO_ROOT/.local/bin/agent-queue"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue"
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  REPO="$SANDBOX/repos/game"
  git init -q "$REPO"
  jq -n --arg r "$REPO" '{paths: {($r): "game", "/x/app": "app"}, aliases: {"g2": "game"},
    trackers: {"level": {repo: "game", path: "Assets/Level"}, "notes": {repo: null}, "app": {}}}' > "$AGENT_QUEUE_PROJECT_MAP"
  # A plan item starts its session through fleet-dispatch: a recording stub, never the real one.
  printf '#!/usr/bin/env bash\necho "fleet-dispatch $*" >> "$NOTES_FIXTURE/calls.log"\nexit "${FD_EXIT:-0}"\n' > "$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/fleet-dispatch"
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
  [ "$(field "$f" session)" = game-agent-1 ]
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

@test "set refuses identity fields and records the rest, on a done item too" {
  "$AQ" add --project game --slug s "s"
  run "$AQ" set s slug=other
  assert_failure; assert_output --partial "not a settable field: slug"
  run "$AQ" set s queued=now
  assert_failure
  "$AQ" move s done --status ok
  run "$AQ" set s pr=https://example/pr/9 "note=a b c"
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-s.md)"
  [ "$(field "$f" pr)" = https://example/pr/9 ]
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

@test "plan mode and --running are recorded; --running starts in running/" {
  "$AQ" add --project game --mode plan --slug p "plan this"
  [ "$(field "$(item queued p)" mode)" = plan ]
  run "$AQ" add --project game --running --session dotfiles-70 --slug by-hand "this session"
  assert_success
  f="$(item running by-hand)"
  [ "$(field "$f" session)" = dotfiles-70 ]
  [ -n "$(field "$f" started)" ]
}

@test "--running inside tmux records <server>:<session> by default; outside it, none" {
  printf 'dotfiles-agent-9\n' > "$NOTES_FIXTURE/tmux.session"
  TMUX="$SANDBOX/tmp/tmux-1000/default,123,0" run "$AQ" add --project game --running --slug here "this session"
  assert_success
  [ "$(field "$(item running here)" session)" = default:dotfiles-agent-9 ]
  TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0" run "$AQ" add --project game --running --session given --slug given "given"
  [ "$(field "$(item running given)" session)" = given ]
  run "$AQ" add --project game --running --slug nowhere "no tmux"
  [ -z "$(field "$(item running nowhere)" session)" ]
}

@test "mine: the active item this tmux session records; none exits 1, two exit 2" {
  printf 'dotfiles-agent-9\n' > "$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
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
  grep -qF "Phase 2 of the plan $SANDBOX/my-plan.md: Second thing. Read the plan whole, then do ONLY this phase, to merged." "$f"
  f="$(item queued my-plan-p4)"
  [ "$(field "$f" after)" = my-plan-p2 ]
  [ "$(field "$f" phases)" = "4 5" ]
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
# every window in it. A hand start records its window, and cancel closes only that.
@test "cancel of an item hand-started in a hub:dotfiles window closes its window, never the session" {
  echo dotfiles > "$NOTES_FIXTURE/tmux.session"
  TMUX="/tmp/tmux-1000/hub,1,0" TMUX_PANE=%31 STUB_WINDOW_ID=@9 \
    "$AQ" add --project game --running --slug by-hand "by hand"
  f="$(item running by-hand)"
  [ "$(field "$f" session)" = hub:dotfiles ]
  [ "$(field "$f" window)" = @9 ]
  run "$AQ" cancel by-hand
  assert_success
  assert_output --partial "closed window @9 of dotfiles"
  run grep -- "tmux -L hub kill-window -t @9" "$NOTES_FIXTURE/calls.log"
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
  assert_output --partial "wait:    median 30 min, p90 30 min from queued to started, 1 started at once and not counted"
  assert_output --partial "sitting: 1 can start, oldest 2h (c), median 2h; 1 held (after 1)"
  assert_output --partial "project: app 1 (0 PR), game 1 (1 PR)"
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
