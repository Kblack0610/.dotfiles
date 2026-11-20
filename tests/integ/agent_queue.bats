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
  # The wall clock never decides a test: holds read this hour (a test that needs another sets its own).
  export AGENT_QUEUE_NOW=12:00
  # Fixtures add as dispatch's pull; the board-only tests unset it to be an agent or a filer.
  export AGENT_QUEUE_PULL=dispatch
  REPO="$SANDBOX/repos/game"
  git init -q "$REPO"
  # Two games in the game repo (level, arena), a repo whose work counts on its owner (tools ->
  # cockpit), and a project with a row code in another checkout (elsewhere).
  jq -n --arg r "$REPO" '{paths: {($r): "game", "/x/app": "app", "/x/tools": "tools"},
    trackers: {"game": {names: ["g2"]}, "level": {repo: "game", path: "Assets/Level", code: "lv"}, "arena": {repo: "game", path: "Assets/Arena/", code: "ar"},
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

@test "list and show read a hand-edited header the way fm_get does" {
  # The listing reads headers in awk (queue_index, item_recs), the verbs in fm_get: a hold and a
  # weight take a key's first line, with or without a space after the colon.
  mkdir -p "$AGENT_QUEUE_DIR/queued" "$AGENT_QUEUE_DIR/done/2026-11-07"
  printf 'slug: a\nproject: game\npriority: high\nqueued: 2026-11-07T01:00:00Z\nafter:gone\nafter: b\n:odd\n::x\n---\ntask a\n\nmore\n\n' \
    > "$AGENT_QUEUE_DIR/queued/20261107-010000-a.md"
  printf 'slug: b\nproject: game\npriority: high\nfinished: 2026-11-07T02:00:00Z\nstatus: ok\nweight: heavy\nweight: light\n---\ntask b\n' \
    > "$AGENT_QUEUE_DIR/done/2026-11-07/20261107-000000-b.md"
  a="$("$AQ" show a --json)"
  [ "$(jq -r .hold <<<"$a")" = "after gone" ]
  [ "$(jq -r .task <<<"$a")" = $'task a\n\nmore' ]
  [ "$(jq -r .weight <<<"$a")" = light ]
  [ "$(jq -r '.[":odd"] // .[""] // "none"' <<<"$a")" = none ]
  [ "$(jq -r .weight <<<"$("$AQ" show b --json)")" = heavy ]
  run "$AQ" list --json --state all --date 2026-11-07
  assert_success
  [ "$(jq -c 'select(.slug == "a")' <<<"$output")" = "$a" ]
}

@test "show and list give an item the same hold, ready and derived weight" {
  # show reads one item (item_json), a listing the whole queue's index (items_json).
  mkdir -p "$AGENT_QUEUE_DIR/queued" "$AGENT_QUEUE_DIR/done/2026-11-07"
  hdr='project: game\npriority: high\nqueued: 2026-11-07T01:00:00Z\n'
  printf "slug: b\n${hdr}finished: 2026-11-07T02:00:00Z\nstatus: ok\nweight: light\n---\nb\n" \
    > "$AGENT_QUEUE_DIR/done/2026-11-07/20261107-000000-b.md"
  printf "slug: c\n${hdr}after: b\nweight: light\n---\nc\n" > "$AGENT_QUEUE_DIR/queued/20261107-010000-c.md"
  printf "slug: n\n${hdr}tags: at:23:59\nweight: light\n---\nn\n" > "$AGENT_QUEUE_DIR/queued/20261107-010001-n.md"
  printf "slug: p\n${hdr}mode: plan\n---\np\n" > "$AGENT_QUEUE_DIR/queued/20261107-010002-p.md"
  printf "slug: q\n${hdr}phases: one two\n---\nq\n" > "$AGENT_QUEUE_DIR/queued/20261107-010003-q.md"
  export AGENT_QUEUE_NOW=12:00
  # Fixtures add as dispatch's pull; the board-only tests unset it to be an agent or a filer.
  export AGENT_QUEUE_PULL=dispatch
  list="$("$AQ" list --json --state all --date 2026-11-07)"
  for s in b c n p q; do
    [ "$(jq -c --arg s "$s" 'select(.slug == $s)' <<<"$list")" = "$("$AQ" show "$s" --json)" ]
  done
  c="$("$AQ" show c --json)"
  [ "$(jq -r '.hold // "none"' <<<"$c")" = none ]
  [ "$(jq -r .ready <<<"$c")" = 2026-11-07T02:00:00Z ]
  [ "$(jq -r .hold <<<"$("$AQ" show n --json)")" = at:23:59 ]
  [ "$(jq -r .weight <<<"$("$AQ" show p --json)")" = heavy ]
  [ "$(jq -r .weight <<<"$("$AQ" show q --json)")" = heavy ]
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

@test "another spelling is filed as its project, and a slug cannot be active twice" {
  run "$AQ" add --project g2 --slug dup "x"
  assert_success
  [ "$(field "$(item queued dup)" project)" = game ]
  run "$AQ" add --project game --slug dup "y"
  assert_failure; assert_output --partial "already in the queue: dup"
}

@test "one live item per cause: a second add with its cause: is refused and names the owner, until the owner closes" {
  run "$AQ" add --project game --slug red-a --tags "red cause:abc12345" "x"
  assert_success
  run "$AQ" add --project game --running --slug red-b --tags "#size/s cause:abc12345" "y"
  assert_failure
  assert_output --partial "cause:abc12345 is already owned by red-a"
  ! compgen -G "$AGENT_QUEUE_DIR/*/*red-b*"
  # a cause that only starts like this one is another cause
  run "$AQ" add --project game --slug red-c --tags "red cause:abc1" "z"
  assert_success
  run "$AQ" move red-a done --status cancelled
  assert_success
  run "$AQ" add --project game --slug red-b --tags "red cause:abc12345" "y"
  assert_success
  # set and reopen check it too; an item's own tags are not a second owner
  run "$AQ" set red-c tags="red cause:abc12345"
  assert_failure
  assert_output --partial "cause:abc12345 is already owned by red-b"
  run "$AQ" set red-b tags="red #size/s cause:abc12345"
  assert_success
  run "$AQ" reopen red-a
  assert_failure
  assert_output --partial "cause:abc12345 is already owned by red-b"
  [ -z "$(item running red-a)" ]
}

@test "at the cap a red add whose cause: is owned returns nothing before it is refused" {
  "$AQ" add --project game --from shepherd --slug a "a" >/dev/null
  "$AQ" set a row=game:gm-a >/dev/null
  "$AQ" add --project game --from shepherd --tags "red cause:c0ffee12" --slug r1 "r1" >/dev/null
  export AGENT_QUEUE_CAP=2
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority high --tags "red cause:c0ffee12" --slug r2 "r2"
  assert_failure
  assert_output --partial "cause:c0ffee12 is already owned by r1"
  refute_output --partial "returned a"
  [ -n "$(item queued a)" ] || fail "a refused add returned a"
  # negative control: another cause makes room as before
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority high --tags "red cause:0ther123" --slug r3 "r3"
  assert_success
  assert_output --partial "returned a to its board row"
}

@test "the phases of one plan share its cause:, and an item outside the plan is refused" {
  story_notes
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two' > "$SANDBOX/rc.md"
  run env AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/rc.md" --project level --slug rc --tags "red cause:feed1234"
  assert_success
  assert_line --partial "held rc-p2 -> level:"
  run "$AQ" add --project level --slug other --tags "red cause:feed1234" "other"
  assert_failure
  assert_output --partial "cause:feed1234 is already owned by rc-p1"
}

@test "add refuses a slug that finished ok unless --repeat; a failed or cancelled one is a retry" {
  "$AQ" add --project game --slug landed "x" >/dev/null
  "$AQ" move landed done --status ok >/dev/null
  run "$AQ" add --project game --slug landed "x again"
  assert_failure 4
  assert_output --partial "landed already finished ok ("
  assert_output --partial "pass --repeat to queue it again as new work"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a finished slug was queued again"
  # negative control: a repeat is new work under the same slug, and a failed one re-queues as is
  run "$AQ" add --project game --slug landed --repeat "tonight's pass"
  assert_success
  "$AQ" add --project game --slug broke "y" >/dev/null
  "$AQ" move broke done --status failed >/dev/null
  run "$AQ" add --project game --slug broke "y, retried"
  assert_success
}

@test "a slug cut from the task's words is refused only for the same words: a 40-character twin is other work" {
  t="fix(queue): one long subject line that runs past forty characters"
  "$AQ" add --project game "$t" >/dev/null
  s="$(field "$(ls "$AGENT_QUEUE_DIR"/queued/*)" slug)"
  "$AQ" move "$s" done --status ok >/dev/null
  run "$AQ" add --project game "$t"
  assert_failure 4
  # negative control: same first 40 characters, so the same slug, but different work
  run "$AQ" add --project game "${t% characters} chars, and then some"
  assert_success
  [ -n "$(item queued "$s")" ] || fail "the different task was not queued under $s"
}

@test "add --plan skips a phase whose slug finished ok and queues the rest after it; all landed is refused" {
  story_notes
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two' > "$SANDBOX/rq.md"
  # P2 waits on P1, so it is P1's board row's waiter (#after/lv-9), never a queue item.
  run env AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/rq.md" --project level --slug rq
  assert_success
  assert_line "held rq-p2 -> level:lv-9 (#after/lv-9)"
  [ -z "$(item queued rq-p2)" ]
  AGENT_QUEUE_START=0 "$AQ" move rq-p1 done --status ok >/dev/null
  run "$AQ" add --plan "$SANDBOX/rq.md" --project level --slug rq
  assert_success
  assert_output --partial "skipped rq-p1 already finished ok"
  assert_output --partial "tick its box in $SANDBOX/rq.md"
  [ -z "$(item queued rq-p1)" ] || fail "a landed phase was queued again"
  [ "$(field "$(item queued rq-p2)" after)" = rq-p1 ] || fail "p2 does not go after the landed p1"
  AGENT_QUEUE_START=0 "$AQ" move rq-p2 done --status ok >/dev/null
  run "$AQ" add --plan "$SANDBOX/rq.md" --project level --slug rq
  assert_failure 4
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a landed phase was queued again"
  # negative control: --repeat queues every phase as new work, P2 again on P1's row
  run "$AQ" add --plan "$SANDBOX/rq.md" --project level --slug rq --repeat
  assert_success
  [ -n "$(item queued rq-p1)" ]
  assert_line "held rq-p2 -> level:lv-9 (#after/lv-9)"
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

@test "list puts a red item first, then priority, then queued time, with no cleanup key" {
  "$AQ" add --project game --slug a-high "a"
  "$AQ" add --project game --slug b-cleanup --tags "cleanup tier3" "b"
  "$AQ" add --project game --slug c-urgent --priority urgent "c"
  "$AQ" add --project game --slug d-red-low --priority low --tags "red cause:x" "d"
  "$AQ" add --project game --slug e-reddish --tags "reddish" "e"
  "$AQ" add --project game --slug f-cleanup-low --priority low --tags cleanup "f"
  run bash -c "'$AQ' list --json | jq -r .slug"
  # red beats urgent; a cleanup tag does not reorder (the mix's cleanup share does that); tags match whole words.
  assert_output $'d-red-low\nc-urgent\na-high\nb-cleanup\ne-reddish\nf-cleanup-low'
  run "$AQ" next --json
  assert_success
  [ "$(jq -r .slug <<<"$output")" = d-red-low ]
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

@test "list orders an item with no priority line as high, and the rest of the queue still reads" {
  "$AQ" add --project game --slug a-low --priority low "a"
  "$AQ" add --project game --slug b-high "b"
  f="$(item queued b-high)"
  sed -i '/^priority:/d' "$f"
  run bash -c "'$AQ' list --json | jq -r '[.slug, .priority] | @tsv'"
  assert_success
  assert_output $'b-high\thigh\na-low\tlow'
  run "$AQ" next --json
  assert_success
  [ "$(jq -r .slug <<<"$output")" = b-high ]
}

@test "list fails, never prints an empty queue, when the queue cannot be read" {
  "$AQ" add --project game --slug a-item "a"
  # The one read every listing goes through (items_json) fails; every other jq is the real one.
  real="$(command -v jq)"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = -Rsc ] && exit 5\nexec %q "$@"\n' "$real" > "$SANDBOX/bin/jq"
  chmod +x "$SANDBOX/bin/jq"
  run "$AQ" list --json
  assert_failure
  assert_output --partial "could not read the queue"
  run "$AQ" list
  assert_failure
  run "$AQ" next
  assert_failure
  assert_output --partial "could not read the queue"
}

@test "a project's #prio ranks its items within a priority, under red and urgent" {
  "$AQ" add --project app --slug a-app "a"
  "$AQ" add --project app --slug b-app-cleanup --tags cleanup "b"
  "$AQ" add --project game --slug c-game "c"
  "$AQ" add --project app --slug d-app-urgent --priority urgent "d"
  "$AQ" add --project tools --slug e-tools "e"
  # With no #prio set the order is urgent, then queued time.
  run bash -c "'$AQ' list --json | jq -r .slug"
  assert_output $'d-app-urgent\na-app\nb-app-cleanup\nc-game\ne-tools'
  printf 'game\tfocus\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r .slug"
  # urgent still heads; game, focused, beats the older app items.
  assert_output $'d-app-urgent\nc-game\na-app\nb-app-cleanup\ne-tools'
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = d-app-urgent ]
}

# The class mix (plan can-we-move-our-mellow-sphinx P3): fixture done items in and out of the window,
# a held item, and the switch off as the negative control.
mix_done() { # <day> <slug> <from> <task> [started]
  local started='' type=''
  mkdir -p "$AGENT_QUEUE_DIR/done/$1"
  # The row type `add` stamps from `notes row parse`; a fixture spells it from the task.
  [[ $4 != *:* ]] || type="type: ${4%%:*}"$'\n'
  [ -z "${5:-}" ] || started="started: $1T00:30:00Z"$'\n'
  printf 'slug: %s\nproject: game\npriority: high\nfrom: %s\nqueued: %sT00:00:00Z\n%s%sstatus: %s\nfinished: %sT01:00:00Z\n---\n%s\n' \
    "$2" "$3" "$1" "$type" "$started" "$([ -n "${5:-}" ] && echo ok || echo cancelled)" "$1" "$4" > "$AGENT_QUEUE_DIR/done/$1/x-$2.md"
}
mix_classes() { jq --argjson on "$1" '.on = $on' "$REPO_ROOT/.config/fleet-dispatch/classes.json" > "$SANDBOX/classes.json"; }

@test "the class mix: inside a bucket the class furthest under its share goes first; urgent stays ahead; a held item adds no count; started items in the window count, running ones too" {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  today="$(date +%F)" old="$(date -d '10 days ago' +%F)"
  # In the window: 4 requested ran, and 1 feature is still running. Out of it, 3 bugs; never started, 10 research.
  for i in 1 2 3 4; do mix_done "$today" "dr$i" human "do thing $i" 1; done
  mkdir -p "$AGENT_QUEUE_DIR/running"
  printf 'slug: df1\nproject: game\npriority: high\nfrom: shepherd\ntype: feat\nqueued: %sT00:00:00Z\nstarted: %sT00:30:00Z\n---\nfeat: running\n' \
    "$today" "$today" > "$AGENT_QUEUE_DIR/running/20261118-000000-df1.md"
  for i in 1 2 3; do mix_done "$old" "db$i" shepherd "fix: old $i" 1; done
  for i in $(seq 1 10); do mix_done "$today" "dz$i" shepherd "research: returned $i"; done
  printf '%s\t%s\tgame\t%s\t1\n' "feat(ui): a feature" feat "a feature" "fix(game): a bug" fix "a bug" \
    "fix(game): a held bug" fix "a held bug" "fix(game): another bug" fix "another bug" \
    "research(game): a question" research "a question" "chore(game): c" chore c \
    "chore(game): urgent cleanup" chore "urgent cleanup" > "$NOTES_FIXTURE/row.parse"
  "$AQ" add --project game --slug r1 "asked by the human"
  "$AQ" add --project game --from shepherd --slug f1 "feat(ui): a feature"
  "$AQ" add --project game --from shepherd --slug b1 "fix(game): a bug"
  legacy h1 "after: r1" --project game --from shepherd "fix(game): a held bug"
  "$AQ" add --project game --from shepherd --slug b2 --tags cleanup "fix(game): another bug"
  "$AQ" add --project game --from shepherd --slug c1 --tags cleanup "chore(game): c"
  "$AQ" add --project game --from shepherd --slug z1 "research(game): a question"
  "$AQ" add --project game --from shepherd --slug u1 --priority urgent --tags cleanup "chore(game): urgent cleanup"
  # One add a second can share a queued time; each gets its own minute, in add order.
  n=0; for s in r1 f1 b1 h1 b2 c1 z1 u1; do n=$((n + 1)); sed -i "s/^queued: .*/queued: ${today}T00:0$n:00Z/" "$(item queued "$s")"; done
  mix_classes false
  run bash -c "'$AQ' list --json --state queued | jq -r .slug"
  assert_success
  # Off: urgent first, then queued time.
  assert_output $'u1\nr1\nf1\nb1\nh1\nb2\nc1\nz1'
  mix_classes true
  run bash -c "'$AQ' list --json --state queued | jq -r .slug"
  assert_success
  # Urgent u1 (a chore) heads its own bucket and carries cleanup to 1/10 into the next. There bug and
  # research start at 0 (the old bugs and the unstarted research do not count): b1, then z1. Bug's held
  # h1 ties requested (4/60 = 1/15) and wins on file order; it adds no count, so b2 goes next (a fix,
  # so bug though fleet-dispatch tags it cleanup). Then r1, and cleanup and feature tie at 0.1 (feature's
  # running item): file order, c1 then f1.
  assert_output $'u1\nb1\nz1\nh1\nb2\nr1\nc1\nf1'
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = u1 ]
  # A window that is not a whole number of days is no mix, never a failed listing.
  jq '.window_days = "7 days"' "$SANDBOX/classes.json" > "$SANDBOX/c2.json" && mv "$SANDBOX/c2.json" "$SANDBOX/classes.json"
  run bash -c "'$AQ' list --json --state queued | jq -r .slug"
  assert_success
  assert_output $'u1\nr1\nf1\nb1\nh1\nb2\nc1\nz1'
}

@test "the class mix is elastic: lag_places bounds how far the window's history holds a class back, and a class with nothing queued gives its turns to the rest" {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  today="$(date +%F)"
  # Requested ran 30 this week (30/60 = 0.5); bug and feature ran none.
  for i in $(seq 1 30); do mix_done "$today" "dr$i" human "do thing $i" 1; done
  printf '%s\t%s\tgame\t%s\t1\n' "fix(game): bug 1" fix "bug 1" "fix(game): bug 2" fix "bug 2" > "$NOTES_FIXTURE/row.parse"
  "$AQ" add --project game --slug r1 "asked by the human"
  for i in 1 2 3 4 5 6; do "$AQ" add --project game --from shepherd --slug "f$i" "feature $i"; done
  for i in 1 2; do "$AQ" add --project game --from shepherd --slug "b$i" "fix(game): bug $i"; done
  n=0; for s in r1 f1 f2 f3 f4 f5 f6 b1 b2; do n=$((n + 1)); sed -i "s/^queued: .*/queued: ${today}T00:0$n:00Z/" "$(item queued "$s")"; done
  lag() { jq --argjson l "$1" '.on = true | .lag_places = $l' "$REPO_ROOT/.config/fleet-dispatch/classes.json" > "$SANDBOX/classes.json"; }
  order() { "$AQ" list --json --state queued | jq -r .slug | paste -sd' '; }
  # lag 10 over shares summing to 100: requested is cut to 0.1 above the lowest (0), so it waits only
  # for the one feature and two bugs at or under that, and goes 4th.
  lag 10
  run order
  assert_success
  assert_output 'b1 f1 b2 r1 f2 f3 f4 f5 f6'
  # NEGATIVE CONTROL: with no bound, the week's history parks r1 behind five features.
  lag null
  run order
  assert_output 'b1 f1 b2 f2 f3 f4 f5 r1 f6'
  # A lag_places that is not a number is no mix: plain queued time.
  lag '"10"'
  run order
  assert_output 'r1 f1 f2 f3 f4 f5 f6 b1 b2'
  # With no requested item queued, its share goes to the rest by theirs: bug 15 to feature 10.
  rm "$(item queued r1)"
  lag 10
  run order
  assert_output 'b1 f1 b2 f2 f3 f4 f5 f6'
}

@test "mix: each class's starts in the window against its share, runnable counts, and a class with runnable work and no start in starve_days is starved, mix on or off (plan P4)" {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  today="$(date +%F)" five="$(date -d '5 days ago' +%F)"
  # Started in the window: 2 requested today, 1 bug 5 days ago, 1 feature running since today. Never started: 1 research.
  mix_done "$today" dr1 human "do thing 1" 1
  mix_done "$today" dr2 human "do thing 2" 1
  mix_done "$five" db1 shepherd "fix: old bug" 1
  mix_done "$today" dz1 shepherd "research: returned"
  mkdir -p "$AGENT_QUEUE_DIR/running"
  printf 'slug: df1\nproject: game\npriority: high\nfrom: shepherd\ntype: feat\nqueued: %sT00:00:00Z\nstarted: %sT00:30:00Z\n---\nfeat: running\n' \
    "$today" "$today" > "$AGENT_QUEUE_DIR/running/20261118-000000-df1.md"
  printf '%s\t%s\tgame\t%s\t1\n' "feat(ui): a feature" feat "a feature" "fix(game): a bug" fix "a bug" \
    "research(game): a question" research "a question" "chore(game): held" chore held > "$NOTES_FIXTURE/row.parse"
  "$AQ" add --project game --slug r1 "asked by the human"
  "$AQ" add --project game --from shepherd --slug f1 "feat(ui): a feature"
  "$AQ" add --project game --from shepherd --slug b1 "fix(game): a bug"
  "$AQ" add --project game --from shepherd --slug z1 "research(game): a question"
  legacy c1 "after: r1" --project game --from shepherd "chore(game): held"
  mix_classes false
  off="$("$AQ" list --json --state queued | jq -r .slug)"
  run "$AQ" mix --json
  assert_success
  run jq -c '[.on, .starve_days, (.classes[] | [.name, .runnable, .started, .recent, .pct]), .starved]' <<<"$output"
  # The held chore is no runnable cleanup, so cleanup is not starved; bug's only start is 5 days old.
  assert_output '[false,3,["bug",1,1,0,25],["requested",1,2,2,50],["cleanup",0,0,0,0],["research",1,0,0,0],["feature",1,1,1,25],["bug","research"]]'
  run "$AQ" mix
  assert_success
  assert_line 'mix (off): items started in 7d against each class share'
  assert_line 'bug            15%        1    25%         1          0'
  assert_line 'starved: bug, research (runnable, none started in 3d)'
  # NEGATIVE CONTROL: a 7-day starve window counts the 5-day-old bug start, and research stays starved.
  jq '.starve_days = 7 | .on = true' "$SANDBOX/classes.json" > "$SANDBOX/c2.json" && mv "$SANDBOX/c2.json" "$SANDBOX/classes.json"
  run bash -c "'$AQ' mix --json | jq -c '[.on, .starved]'"
  assert_output '[true,["research"]]'
  # A starve window longer than the window is refused by mix, but starve_days only steers the watch:
  # the listing keeps the mix's order, which differs from the order with the mix off.
  run bash -c "'$AQ' list --json --state queued | jq -r .slug"
  on="$output"
  [ "$on" != "$off" ] || fail "the mix did not change the order, so the check below proves nothing"
  jq '.starve_days = 10' "$SANDBOX/classes.json" > "$SANDBOX/c2.json" && mv "$SANDBOX/c2.json" "$SANDBOX/classes.json"
  run "$AQ" mix
  assert_failure
  assert_output --partial 'not whole days inside the window'
  run bash -c "'$AQ' list --json --state queued | jq -r .slug"
  assert_success
  assert_output "$on"
}

@test "classes.json: every kind it names is a kinds.json kind, every class has a share, and one is the default" {
  c="$REPO_ROOT/.config/fleet-dispatch/classes.json"
  run jq -r --slurpfile k "$REPO_ROOT/.config/fleet-dispatch/kinds.json" '.classes[].kinds[]? | select(. as $n | $k[0] | has($n) | not)' "$c"
  assert_success
  assert_output ''
  run jq -e '(.classes | all(.share | type == "number")) and ([.classes[] | select(.default == true)] | length == 1) and (.on | type == "boolean")' "$c"
  assert_success
}

@test "#prio ranks focus first, then high, then normal, then low" {
  "$AQ" add --project elsewhere --slug a-else "a"
  "$AQ" add --project app --slug b-app "b"
  "$AQ" add --project game --slug c-game "c"
  "$AQ" add --project cockpit --slug d-cockpit "d"
  printf 'game\thigh\nelsewhere\tlow\ncockpit\tfocus\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r .slug"
  assert_output $'d-cockpit\nc-game\nb-app\na-else'
}

@test "a focus project's items start before every other project's, under red and urgent, over item priority, and nothing is held" {
  "$AQ" add --project app --slug a-app "a"
  "$AQ" add --project app --slug b-app-red --tags red "b"
  "$AQ" add --project app --slug c-app-urgent --priority urgent "c"
  "$AQ" add --project app --slug d-app-high --priority high "d"
  "$AQ" add --project app --slug e-app-req --tags requested "e"
  "$AQ" add --project game --slug f-game-low --priority low "f"
  # Negative control: no focus, the low game item goes last.
  run bash -c "'$AQ' list --json | jq -r .slug"
  assert_output $'b-app-red\nc-app-urgent\na-app\nd-app-high\ne-app-req\nf-game-low'
  printf 'game\tfocus\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r '\"\\(.slug) \\(.hold // \"-\")\"'"
  assert_output $'b-app-red -\nc-app-urgent -\nf-game-low -\na-app -\nd-app-high -\ne-app-req -'
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = b-app-red ]
}

@test "an after: successor waits on its board row, and an ok close pulls it, whatever the focus" {
  story_notes
  "$AQ" add --project level --slug first --running "a" >/dev/null
  run "$AQ" add --project level --slug second --after first "b"
  assert_failure 5
  assert_output --partial "held second -> level:lv-9 (#after/lv-9)"
  printf 'game\tfocus\n' > "$NOTES_FIXTURE/prios"
  run "$AQ" move first done --status ok
  assert_success
  assert_called 'fleet-dispatch pull-after lv-9'
}

@test "an after: on a re-queued slug holds while the slug is live, whatever an old done record says" {
  "$AQ" add --project game --slug first "a"
  "$AQ" move first running
  "$AQ" move first done --status ok
  "$AQ" add --project game --slug second --priority urgent --after first "b"
  # Negative control: the old done record alone releases the after.
  [ "$("$AQ" next --json | jq -r .slug)" = second ]
  # The same slug queued again is not done, so second holds on it in every live state.
  "$AQ" add --project game --slug first --repeat "again"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first"
  [ "$("$AQ" next --json | jq -r .slug)" = first ]
  "$AQ" move first running
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first"
  "$AQ" move first waiting
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first"
  # It finishes ok again: now the hold lifts.
  "$AQ" move first done --status ok
  [ "$("$AQ" next --json | jq -r .slug)" = second ]
}

@test "after holds an item until that slug is done ok" {
  "$AQ" add --project game --slug first "a"
  legacy second "after: first" --project game --from shepherd --priority urgent "b"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first"
  [ "$("$AQ" next --json | jq -r .slug)" = first ]
  "$AQ" move first running
  "$AQ" move first done --status failed
  run "$AQ" next
  assert_failure
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first closed failed, dead: it never releases (queue first again, or set after= without it); who closed it and why: agent-queue show first"
  "$AQ" add --project game --slug first --repeat "again"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first"
  "$AQ" move first done --status ok
  [ "$("$AQ" next --json | jq -r .slug)" = second ]
}

@test "move running refuses a queued item while its hold is pending, live, dead or a tag gate, and starts it once clear (ar-3260)" {
  "$AQ" add --project game --slug first "a"
  legacy second "after: first" --project game "b"
  run "$AQ" move second running
  assert_failure
  assert_output --partial "second waits on after first, so it cannot start"
  [ -n "$(item queued second)" ]
  "$AQ" move first running
  "$AQ" move first done --status failed
  run "$AQ" move second running
  assert_failure
  assert_output --partial "second cannot start: after first closed failed, dead"
  "$AQ" add --project game --slug first --repeat "again"
  "$AQ" move first done --status ok
  run "$AQ" move second running
  assert_success
  assert_output "second: queued -> running"
  # A tag gate holds a start the same way, and a resume from waiting reads no gate.
  legacy clock "tags: at:13:00" --project game "c"
  run "$AQ" move clock running
  assert_failure
  assert_output --partial "clock waits on at:13:00, so it cannot start"
  AGENT_QUEUE_NOW=13:00 run "$AQ" move clock running
  assert_success
  "$AQ" move clock waiting
  "$AQ" set clock "tags=at:23:00"
  run "$AQ" move clock running
  assert_success
  # A queued item that records a session is fleet-dispatch start's launch, judged before it: the move
  # records it whatever the hold reads now.
  legacy late "tags: at:23:00" --project game "d"
  "$AQ" set late session=game-agent-3
  run "$AQ" move late running
  assert_success
}

@test "add --running --after refuses until every named slug closed ok (ar-3260)" {
  "$AQ" add --project game --slug first "a"
  run "$AQ" add --project game --slug second --running --after first "b"
  assert_failure
  assert_output --partial "second waits on after first, so it cannot start --running"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/*-second.md 2>/dev/null)" ] || fail "a refused add wrote an item"
  run "$AQ" add --project game --slug second --running --after nosuch "b"
  assert_failure
  assert_output --partial "--after nosuch: no item has that slug"
  "$AQ" move first running
  "$AQ" move first done --status failed
  run "$AQ" add --project game --slug second --running --after first "b"
  assert_failure
  assert_output --partial "second cannot start --running: after first closed failed, dead"
  "$AQ" add --project game --slug first --repeat "again"
  "$AQ" move first done --status ok
  run "$AQ" add --project game --slug second --running --after first "b"
  assert_success
  [ -n "$(item running second)" ]
}

@test "an after: on an item closed cancelled says the hold is dead, through show as well as list" {
  "$AQ" add --project game --slug first "a"
  legacy second "after: first" --project game "b"
  "$AQ" move first done --status cancelled
  run bash -c "'$AQ' show second --json | jq -r .hold"
  assert_output "after first closed cancelled, dead: it never releases (queue first again, or set after= without it); who closed it and why: agent-queue show first; a cancel by hand takes --why and --ask <an ask the human answered>"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first closed cancelled, dead: it never releases (queue first again, or set after= without it); who closed it and why: agent-queue show first; a cancel by hand takes --why and --ask <an ask the human answered>"
}

# ar-39: after: is a list of slugs.
@test "after: takes a list: a comma list and a repeated --after store one line, set too, and an unknown or own slug is refused" {
  # Each landed, so the list is clear and d is queued (a pending one waits on its board row).
  for s in a b c; do "$AQ" add --project game --slug $s "$s" >/dev/null; "$AQ" move $s done --status ok >/dev/null; done
  "$AQ" add --project game --slug d --after a,b --after "c a" "d" >/dev/null
  [ "$(field "$(item queued d)" after)" = "a b c" ]
  "$AQ" set d after=c,b >/dev/null
  [ "$(field "$(item queued d)" after)" = "c b" ]
  run "$AQ" add --project game --slug e --after a,nope "e"
  assert_failure
  assert_output --partial "--after nope: no item has that slug"
  run "$AQ" add --project game --slug e --after a,e "e"
  assert_failure
  assert_output --partial "--after e: an item cannot wait on itself"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-e.md 2>/dev/null)" ]
  # set after= is checked the same way.
  run "$AQ" set d after=a,nope
  assert_failure
  assert_output --partial "--after nope: no item has that slug"
  run "$AQ" set d after=d
  assert_failure
  [ "$(field "$(item queued d)" after)" = "c b" ]
}

@test "a list after: holds until every slug closed ok and names the live ones and a dead one first" {
  "$AQ" add --project game --slug a --running "a" >/dev/null
  "$AQ" add --project game --slug b --running "b" >/dev/null
  legacy both "after: a b" --project game "both"
  f="$(item queued both)"; sed -i 's/^queued: .*/queued: 2026-11-03T08:00:00Z/' "$f"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"both\") | .hold'"
  assert_output "after a b"
  run "$AQ" bump both urgent
  assert_output --partial "both is held after a b: it starts when those land"
  "$AQ" move a done --status ok >/dev/null
  # One of two closed ok: it still holds on the other.
  run bash -c "'$AQ' show both --json | jq -r '.hold, .ready // \"none\"'"
  assert_output $'after b\nnone'
  "$AQ" move b done --status ok >/dev/null
  [ "$("$AQ" next --json | jq -r .slug)" = both ]
  "$AQ" set a finished=2026-11-03T12:00:00Z >/dev/null
  "$AQ" set b finished=2026-11-03T13:00:00Z >/dev/null
  # ready is the latest finish of the list, through list and show alike.
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"both\") | .ready'"
  assert_output 2026-11-03T13:00:00Z
  run bash -c "'$AQ' show both --json | jq -r '.hold // \"none\", .ready'"
  assert_output $'none\n2026-11-03T13:00:00Z'
  # A dead slug in the list is named even while another is live: it never releases.
  "$AQ" add --project game --slug c "c" >/dev/null
  "$AQ" add --project game --slug x "x" >/dev/null
  legacy two "after: c x" --project game --from shepherd "two"
  "$AQ" move x done --status failed >/dev/null
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"two\") | .hold'"
  assert_output "after x closed failed, dead: it never releases (queue x again, or set after= without it); who closed it and why: agent-queue show x"
}

@test "at: tags hold until their time, other tags are labels" {
  legacy later "tags: at:18:00 ui" --project game --priority high "b"
  "$AQ" add --project game --slug now --tags ui "c"
  AGENT_QUEUE_NOW=12:00 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = now ]
  AGENT_QUEUE_NOW=18:30 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = later ]
}

@test "a night tag is a label: it holds nothing at any hour" {
  "$AQ" add --project game --slug tonight --tags night "a"
  # An hour inside the old night window and one outside it: the tag holds at none of them.
  for hour in 02:00 03:59 12:00; do
    AGENT_QUEUE_NOW=$hour run "$AQ" next --json
    [ "$(jq -r .slug <<<"$output")" = tonight ]
    [ "$(AGENT_QUEUE_NOW=$hour "$AQ" show tonight --json | jq -r '.hold // "none"')" = none ]
  done
}

@test "a dated at: tag holds across days until its moment; at:HH:MM alone does not" {
  legacy tomorrow "tags: at:2026-11-05T09:00" --project game "a"
  legacy clock "tags: at:09:00" --project game "b"
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

@test "an ask: tag holds an item until that agent-ask is answered, with that option when one is named (ar-455)" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  # add refuses a malformed tag and an id no ask file has, so the gate is never silently open or shut.
  for t in "ask:" "ask:../x" "ask:a1=" "ask:a1"; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure
  done
  ask a1 pending
  legacy money "tags: ask:a1=a" --project game "go live"
  run "$AQ" next --json
  assert_failure
  run "$AQ" next --json
  assert_failure
  ask a1 answered 'b. stay on paper'
  run "$AQ" next --json
  assert_failure
  ask a1 cancelled
  run "$AQ" next --json
  assert_failure
  # A machine answer is not the human's decision.
  ask a1 answered 'a' judge
  run "$AQ" next --json
  assert_failure
  ask a1 answered 'A, go live' human
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = money ]
  ask a2 pending
  legacy any "tags: ask:a2" --project game --priority urgent "any answer"
  ask a2 answered 'whatever'
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = any ]
}

# 2026-11-07: can-we-get-cloud-vast-clarke-p3-live queued behind an ask the judge had answered, and
# upwork-p2..p5 behind one later cancelled; neither ask could ever release them.
# 2026-11-08: upwork-p2 sat behind a bare tag on an ask whose option c meant stop, so c would have started it.
@test "an ask: tag may list several releasing options, and must name them when the ask offers options" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\noptions: a|b|c\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  ask o1 pending
  run "$AQ" add --project game --slug bare --tags "ask:o1" "x"
  assert_failure
  assert_output --partial 'that ask offers a,b,c'
  legacy go "tags: ask:o1=a+b" --project game "go"
  # Negative control: an option the tag does not list holds, and says so for dead_holds to read.
  ask o1 answered 'c' human
  run "$AQ" next --json
  assert_failure
  run "$AQ" list --state queued
  assert_output --partial 'answered c, not a+b'
  ask o1 answered 'B, the other' human
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = go ]
  # 2026-11-12: a free-text answer, whose first word names no option, is the human's own answer and releases.
  ask o1 answered 'Neither: shape the whole bowl' human
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = go ]
  # Negative control: an empty answer still holds.
  ask o1 answered '' human
  run "$AQ" next --json
  assert_failure
}

# agent-ask reads holds on every card and answer through ask-holds, which reads the header lines
# alone: it must name exactly what list --json's tags do, and nothing from a done item.
@test "ask-holds lists each active item held on an ask, as list --json's tags have them" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  for i in h1 h2; do printf 'id: %s\nstatus: pending\noptions: a|b\n' "$i" > "$AGENT_ASK_DIR/game/$i.md"; done
  legacy one "tags: ui ask:h1=a+b" --project game "one"
  legacy two "tags: ask:h1=a ask:h2=b" --project game "two"
  "$AQ" add --project game --slug free "no ask"
  legacy gone "tags: ask:h2=a" --project game "gone"
  "$AQ" cancel gone >/dev/null
  run "$AQ" ask-holds
  assert_success
  assert_equal "$(sort <<<"$output")" "$(printf 'one\th1\ta+b\ntwo\th1\ta\ntwo\th2\tb')"
  assert_equal "$(sort <<<"$output")" "$("$AQ" list --json | jq -r '.slug as $s | (.tags // "") | split(" ")[]
    | select(startswith("ask:")) | .[4:] | [$s, split("=")[0], (split("=")[1] // "")] | @tsv' | sort)"
  run "$AQ" ask-holds h2
  assert_output "$(printf 'two\th2\tb')"
  run "$AQ" ask-holds nope
  assert_success
  assert_output ''
}

@test "an ask: tag refuses an option the ask does not offer, which could never match an answer" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  printf 'id: o2\nstatus: pending\noptions: go|stop-burst+do-bridge|steps done, verify it\n' > "$AGENT_ASK_DIR/game/o2.md"
  for t in ask:o2=goo ask:o2=go+ ask:o2=go++steps ask:o2=do-bridge; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure; assert_output --partial 'that ask offers go,stop-burst+do-bridge,steps done, verify it'
  done
  # Negative controls: a real option in any case, a slug holding a +, and a multi-word option by its first word.
  legacy one "tags: ask:o2=GO" --project game "x"
  legacy two "tags: ask:o2=stop-burst+do-bridge+go" --project game "x"
  legacy three "tags: ask:o2=steps" --project game "x"
  # An ask with no options has nothing to check a name against.
  printf 'id: o3\nstatus: pending\n' > "$AGENT_ASK_DIR/game/o3.md"
  legacy four "tags: ask:o3=anything" --project game "x"
}

@test "add and set tags= refuse an ask that can never release the item: cancelled, the judge's answer, another option" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  ask dead cancelled
  ask judged answered a judge
  ask other answered 'b, stay' human
  for t in ask:dead ask:judged=a ask:other=a; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure; assert_output --partial 'can never release it'
  done
  # Negative control: a pending ask, and the human's answer naming that option, are accepted.
  ask live pending
  legacy p3 "tags: tier3 ask:live=a" --project game "go live"
  ask yes answered 'a' human
  legacy p4 "tags: ask:yes=a" --project game "the next"
  # Re-pointing an item off a dead ask goes through set, which checks the same way.
  run "$AQ" set p3 tags="tier3 ask:dead"
  assert_failure; assert_output --partial 'can never release it (cancelled)'
  "$AQ" set p3 tags="tier3 ask:yes=a"
}

@test "a hold: tag holds an item while agent-hold holds that resource, whoever asks (ar-613)" {
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  for t in "hold:" "hold:../x" "hold:a/b" "hold:.."; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure; assert_output --partial "hold:<resource>"
  done
  legacy forms "tags: hold:mac-desktop" --project game "fill the store forms"
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = forms ]
  # A claim by another session holds it, and so does one by the asker: the item's own session is not the claimer.
  "$REPO_ROOT/.local/bin/agent-hold" claim mac-desktop --by unity-agent-6 "steam forms" >/dev/null
  run "$AQ" next --json
  assert_failure
  run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (since"
  assert_output --partial "by unity-agent-6: steam forms)"
  run env TMUX=x "$AQ" next --json
  assert_failure
  # Asked from the claimer's own directory with no tmux, agent-hold would name the caller unity-agent-6.
  mkdir -p "$SANDBOX/unity-agent-6"; cd "$SANDBOX/unity-agent-6"
  run env -u TMUX "$AQ" next --json
  assert_failure
  cd "$SANDBOX"
  # set tags= is checked like add.
  run "$AQ" set forms "tags=hold:a/b"
  assert_failure; assert_output --partial "hold:<resource>"
  "$REPO_ROOT/.local/bin/agent-hold" release mac-desktop >/dev/null
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = forms ]
}

@test "an rbw: tag holds an item until rbw lists that folder and name, and locked rbw holds it" {
  # A fake rbw: unlocked unless rbw.locked exists, and list prints rbw.list. Never the real one.
  printf '#!/usr/bin/env bash\necho "rbw $*" >> "%s/rbw.calls"\n[ ! -e /dev/fd/8 ] || echo "rbw $*" >> "%s/rbw.lockfd"\nflock -n -x "$AGENT_QUEUE_DIR/.lock" true || echo "rbw $*" >> "%s/rbw.underlock"\ncase "$1" in\n  unlocked) [ ! -e "%s/rbw.locked" ] ;;\n  list) cat "%s/rbw.list" ;;\n  *) exit 9 ;;\nesac\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/rbw-fake"
  chmod +x "$SANDBOX/rbw-fake"
  export AGENT_QUEUE_RBW="$SANDBOX/rbw-fake"
  printf 'trading\tkalshi-key\nother\tmanifold-key\n' > "$SANDBOX/rbw.list"
  for t in "rbw:" "rbw:trading" "rbw:trading/" "rbw:/manifold-key"; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure; assert_output --partial "rbw:<folder>/<name>"
  done
  legacy deploy-key "tags: rbw:trading/manifold-key" --project game "deploy the manifold key"
  # Same name in another folder, and a prefix of a listed name, do not release it.
  run "$AQ" next --json
  assert_failure
  run "$AQ" list --state queued
  assert_output --partial "rbw:trading/manifold-key (not in rbw yet)"
  printf 'trading\tmanifold-key-old\n' >> "$SANDBOX/rbw.list"
  run "$AQ" next --json
  assert_failure
  printf 'trading\tmanifold-key\n' >> "$SANDBOX/rbw.list"
  : > "$SANDBOX/rbw.locked"
  run "$AQ" list --state queued
  assert_output --partial "rbw:trading/manifold-key (rbw locked or missing)"
  run env AGENT_QUEUE_RBW="$SANDBOX/no-such-rbw" "$AQ" next --json
  assert_failure
  rm "$SANDBOX/rbw.locked"
  mv "$SANDBOX/rbw.list" "$SANDBOX/rbw.list.ok"   # list fails while unlocked
  run "$AQ" list --state queued
  assert_output --partial "rbw:trading/manifold-key (rbw list failed)"
  mv "$SANDBOX/rbw.list.ok" "$SANDBOX/rbw.list"
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = deploy-key ]
  # A read asks rbw only after it lets the lock go (ar-2427). A writer still asks it under the lock
  # (a move back to queued reads the hold it would bring), and rbw never gets its fd
  # there either: an rbw-agent it starts would hold the lock for good.
  [ ! -e "$SANDBOX/rbw.underlock" ]
  "$AQ" add --project game --running --slug first --tags "rbw:trading/manifold-key" "first" >/dev/null
  "$AQ" move first queued >/dev/null
  [ -s "$SANDBOX/rbw.underlock" ]
  [ ! -e "$SANDBOX/rbw.lockfd" ]
  # Only the read-only verbs ran: never get, unlock or sync.
  run grep -cvE '^rbw (unlocked|list --fields folder,name)$' "$SANDBOX/rbw.calls"
  assert_output 0
}

# A fake rbw for the gate tests: unlocked, list prints rbw.list, every call logged. Never the real one.
gate_rbw() {
  printf '#!/usr/bin/env bash\necho "rbw $*" >> "%s/rbw.calls"\ncase "$1" in unlocked) ;; list) cat "%s/rbw.list" ;; *) exit 9 ;; esac\n' \
    "$SANDBOX" "$SANDBOX" > "$SANDBOX/rbw-fake"
  chmod +x "$SANDBOX/rbw-fake"
  export AGENT_QUEUE_RBW="$SANDBOX/rbw-fake"
  printf 'infra\tx\n' > "$SANDBOX/rbw.list"
}

# queue-held-to-board (ar-3121): a row waits on its gate on the board, so gate is the queue's own
# hold_for read through each board form, plus the row lookup for after/.
@test "gate answers each board form clear, pending or dead in hold_for's words, one rbw list for every rbw tag" {
  gate_rbw
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\noptions: a|b\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  ask a1 pending
  ask a2 answered 'a' judge
  ask a3 answered 'b, sure' human
  mkdir -p "$HOME/.cache/agent-queue/pr" && echo MERGED > "$HOME/.cache/agent-queue/pr/o_r_7"
  run "$AQ" gate --json '#rbw/infra/x' rbw/infra/y rbw/other/z at/1100 at/1300 at/2599 at/2026-01-02/0900 \
    ask/a1/a ask/a2/a ask/a3 ask/a3/a pr/o/r/7 size/s
  assert_failure 3
  st() { jq -r --arg t "$1" 'select(.tag == $t) | "\(.state)|\(.why)|\(.queue)"' <<<"$output"; }
  [ "$(st rbw/infra/x)" = "clear||rbw:infra/x" ]
  [ "$(st rbw/infra/y)" = "pending|rbw infra/y (not in rbw yet)|rbw:infra/y" ]
  [ "$(st at/1100)" = "clear||at:11:00" ]
  [ "$(st at/1300)" = "pending|at 13:00|at:13:00" ]
  [[ "$(st at/2599)" == dead"|"*"a time tag is at:HH:MM"* ]]
  [ "$(st at/2026-01-02/0900)" = "clear||at:2026-01-02T09:00" ]
  [[ "$(st ask/a1/a)" == "pending|ask a1=a (pending)|ask:a1=a" ]]
  # A judge's answer is not the human's: it never releases the gate.
  [[ "$(st ask/a2/a)" == dead"|"*"answered by judge"* ]]
  # No option named on an ask that offers some: every option releases it.
  [ "$(st ask/a3)" = "clear||ask:a3=a+b" ]
  [[ "$(st ask/a3/a)" == dead"|"*"answered b"* ]]
  [ "$(st pr/o/r/7)" = "clear||pr:o/r#7" ]
  [ "$(st size/s)" = "none||" ]
  # Three rbw tags, one list.
  [ "$(grep -c '^rbw list' "$SANDBOX/rbw.calls")" = 1 ]
  run "$AQ" gate rbw/infra/x at/1100 size/s
  assert_success
  assert_line "clear    rbw/infra/x"
}

@test "gate after/<row-id> clears once that row closed done, and --all answers every open row's gates from the open board" {
  gate_rbw
  # .tags is what notes lower-cases for grouping; .tags_cased is as written. A gate reads tags_cased, so
  # the ask id keeps its case (2026-11-18: every #ask/ gate on the board read "no agent-ask has that id").
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  printf 'id: AbC12x\nstatus: pending\noptions: a|b\n' > "$AGENT_ASK_DIR/game/AbC12x.md"
  jq -n '{rows: ([{id: "ar-1", state: "open", tags: ["after/ar-2", "size/s"]}, {id: "ar-2", state: "doing", tags: ["rbw/infra/x"]},
                 {id: "ar-9", state: "open", tags: ["after/ar-4"]},
                 {id: "ar-7", state: "open", tags: ["ask/abc12x/a"], tags_cased: ["ask/AbC12x/a"]}]),
          done: [{id: "ar-3", state: "done", marker: "id:ar-3 done:2026-11-01", tags: ["rbw/infra/gone"]},
                 {id: "ar-4", state: "done", marker: "id:ar-4 done:2026-11-01 dropped: a duplicate"}]}' > "$NOTES_FIXTURE/board.json"
  run "$AQ" gate --json after/ar-2 after/ar-3 after/ar-4 after/ar-404
  assert_failure 3
  st() { jq -r --arg t "$1" 'select(.tag == $t) | "\(.state)|\(.why)"' <<<"$output"; }
  [ "$(st after/ar-2)" = "pending|after ar-2 (open)" ]
  [ "$(st after/ar-3)" = "clear|" ]
  [[ "$(st after/ar-4)" == "dead|after ar-4: that row was dropped"* ]]
  [[ "$(st after/ar-404)" == "dead|after ar-404: no board row"* ]]
  [ "$(grep -c '^notes board --json --done-days' "$NOTES_FIXTURE/calls.log")" = 1 ]
  # The open rows' gates only, no other tag and no closed row's, from one board read.
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" gate --json --all
  assert_failure 3
  [ "$(jq -sr 'map(.tag) | sort | join(" ")' <<<"$output")" = "after/ar-2 after/ar-4 ask/AbC12x/a rbw/infra/x" ]
  [ "$(st ask/AbC12x/a)" = "pending|ask AbC12x=a (pending)" ]
  [ "$(grep -c 'board' "$NOTES_FIXTURE/calls.log")" = 1 ]
  # Every after/ there names a row the open board lists, so no closed row is read.
  [ "$(grep -c 'board --json --done-days' "$NOTES_FIXTURE/calls.log")" = 0 ]
  # One it lacks reads the closed rows, once however many tags name such a row.
  jq '.rows += [{id: "ar-8", state: "open", tags: ["after/ar-404", "after/ar-405"]}]' "$NOTES_FIXTURE/board.json" > "$SANDBOX/b.json" && mv "$SANDBOX/b.json" "$NOTES_FIXTURE/board.json"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" gate --json --all
  assert_failure 3
  [[ "$(st after/ar-405)" == "dead|after ar-405: no board row"* ]]
  [ "$(grep -c 'board --json --done-days' "$NOTES_FIXTURE/calls.log")" = 1 ]
  [ "$(grep -c 'board' "$NOTES_FIXTURE/calls.log")" = 2 ]
  # Once ar-2 closes done, ar-1's gate clears.
  jq '.done += [.rows[1] | .state = "done" | .marker = "id:ar-2 done:2026-11-18"] | .rows |= map(select(.id != "ar-2"))' \
    "$NOTES_FIXTURE/board.json" > "$SANDBOX/b.json" && mv "$SANDBOX/b.json" "$NOTES_FIXTURE/board.json"
  run "$AQ" gate after/ar-2
  assert_success
  # A board that cannot be read fails --all, so no pass reads its rows as ungated, and holds an after/.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/notes"
  run "$AQ" gate --json --all
  assert_failure 1
  run "$AQ" gate after/ar-2
  assert_failure 3
  assert_output --partial "notes board --json failed"
}

@test "return writes what the item still waits on onto its row as gate tags before un-starting it" {
  gate_rbw
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  printf 'id: a1\nstatus: pending\noptions: a|b\n' > "$AGENT_ASK_DIR/game/a1.md"
  "$AQ" add --project game --running --from shepherd --slug up "upstream" >/dev/null
  "$AQ" set up row=game:gm-9 >/dev/null
  legacy gt "after: up\ntags: rbw:infra/y at:11:00 at:13:00 ask:a1=a" --project game --from shepherd "gated"
  "$AQ" set gt row=game:gm-7 >/dev/null
  legacy gf "after: gt" --project game --from shepherd "follower"
  "$AQ" set gf row=game:gm-8 >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" return gt --why "back to the board"
  assert_success
  # The met at:11:00 stays behind; the live after: names its row; the follower waits on the returned row.
  assert_called "ptask game --agent tag --add after/gm-9 --add rbw/infra/y --add at/1300 --add ask/a1/a gm-7"
  assert_called "ptask game --agent tag --add after/gm-7 gm-8"
  # The gates go on while the row is still started.
  [ "$(grep -n 'tag --add after/gm-9' "$NOTES_FIXTURE/calls.log" | cut -d: -f1)" -lt "$(grep -n 'unstart gm-7' "$NOTES_FIXTURE/calls.log" | cut -d: -f1)" ]
  # An after: on an item with no row has no board form: the return is refused and nothing closes.
  "$AQ" add --project game --running --from shepherd --slug norow "no row" >/dev/null
  legacy behind "after: norow" --project game --from shepherd "behind"
  "$AQ" set behind row=game:gm-6 >/dev/null
  run "$AQ" return behind --why "back"
  assert_failure
  assert_output --partial "cannot return behind: it waits on norow, which has no board row"
  [ -n "$(item queued behind)" ]
  # Returning norow takes behind with it: norow closes here, so behind's row waits on nothing.
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" return norow --why "back"
  assert_success
  assert_called "ptask game --agent unstart gm-6"
  [ -z "$(grep "tag .*gm-6" "$NOTES_FIXTURE/calls.log")" ]
  # --drop closes the rows, so it writes no gate.
  : > "$NOTES_FIXTURE/calls.log"
  legacy dg "tags: rbw:infra/y" --project game --from shepherd "dropped"
  "$AQ" set dg row=game:gm-5 >/dev/null
  run "$AQ" return dg --why "not wanted" --drop
  assert_success
  refute grep -q ' tag ' "$NOTES_FIXTURE/calls.log"
}

@test "return leaves a row started, exit 1, when it did not take its gates" {
  gate_rbw
  legacy gx "tags: rbw:infra/y" --project game --from shepherd "x"
  "$AQ" set gx row=game:gm-4 >/dev/null
  printf '#!/usr/bin/env bash\necho "notes $*" >> "$NOTES_FIXTURE/calls.log"\ncase "$*" in *" tag "*) exit 1 ;; esac\n' > "$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$AQ" return gx --why "back"
  assert_failure
  assert_output --partial "did not take its gates, so it stays started: notes ptask game --agent tag --add rbw/infra/y gm-4"
  refute grep -q 'unstart gm-4' "$NOTES_FIXTURE/calls.log"
}

@test "requeue --hold returns a started item to its row behind the resource, and is not a model redo (ar-613)" {
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  printf '#!/usr/bin/env bash\necho "model-lane $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/model-lane"
  chmod +x "$SANDBOX/bin/model-lane"
  "$AQ" add --project game --running --slug forms --tags "ui" "fill the store forms" >/dev/null
  "$AQ" set forms "lane_run=r-forms" >/dev/null
  run "$AQ" requeue forms --hold "../x"
  assert_failure
  run "$AQ" requeue forms
  assert_failure
  # Behind a free resource it would restart at once, so the session is told to claim it.
  run "$AQ" requeue forms --hold mac-desktop
  assert_failure; assert_output --partial "claim it"
  "$REPO_ROOT/.local/bin/agent-hold" claim mac-desktop --by other "steam forms" >/dev/null
  # The wait is the board row's: an item with none is refused and stays running.
  run "$AQ" requeue forms --hold mac-desktop
  assert_failure; assert_output --partial "has no board row to wait on hold:mac-desktop"
  [ -n "$(item running forms)" ]
  "$AQ" set forms row=game:gm-9 >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" requeue forms --hold mac-desktop
  assert_success
  assert_called "ptask game --agent tag --add hold/mac-desktop gm-9"
  # The item closes returned, nothing waits in queued/, and the model is not charged a redo.
  [ -z "$(item queued forms 2>/dev/null)" ]
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-forms.md)"
  [ "$(field "$f" end_reason)" = returned ]
  [ "$(field "$f" tags)" = "ui hold:mac-desktop" ]
  run grep '^model-lane' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "one waiter per release: the best desk class starts, the rest wait behind it, desk:auth only while the human is here" {
  # A pinned clock: at-tonight's at:23:59 is due on a wall clock at 23:59, and then it heads the auth class.
  export AGENT_HOLD_DIR="$SANDBOX/holds" AGENT_QUEUE_NOW=12:00
  presence() { printf '#!/usr/bin/env bash\necho "%s 5 tmux"\n' "$1" > "$SANDBOX/bin/fleet-presence"; chmod +x "$SANDBOX/bin/fleet-presence"; }
  presence here
  run "$AQ" add --project game --slug bad --tags "hold:mac-desktop desk:nope" "x"
  assert_failure; assert_output --partial "desk:<class>"
  "$REPO_ROOT/.local/bin/agent-hold" claim mac-desktop --by other "steam forms" >/dev/null
  legacy shots "tags: hold:mac-desktop desk:listing" --project game "store screenshots" >/dev/null
  legacy plain "tags: hold:mac-desktop" --project game "no class" >/dev/null
  legacy signup "tags: hold:mac-desktop desk:legal" --project game "xbox sign-up" >/dev/null
  # Held by its own at: as well, an older item of the same class does not keep the desktop from the rest.
  legacy at-tonight "tags: hold:mac-desktop desk:auth at:23:59" --project game "tonight" >/dev/null
  legacy code "tags: hold:mac-desktop desk:auth" --project game "2fa step" >/dev/null
  run "$AQ" next --json
  assert_failure
  "$REPO_ROOT/.local/bin/agent-hold" release mac-desktop >/dev/null
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = code ]
  run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (behind code, auth)"
  # Control: its at: is what keeps the older at-tonight behind code, up to the minute it is due.
  AGENT_QUEUE_NOW=23:58 run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (behind code, auth)"
  AGENT_QUEUE_NOW=23:59 run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (behind at-tonight, auth)"
  AGENT_QUEUE_NOW=23:59 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = at-tonight ]
  # Away, the 2FA item waits and the next class takes the desktop.
  presence away
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = signup ]
  run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (desk:auth waits for the human, away)"
  assert_output --partial "hold:mac-desktop (behind signup, legal)"
  # Started, the item drops its hold: and keeps its class, and the desktop stays its own until its
  # session claims it: no second waiter starts in between.
  "$AQ" move signup running >/dev/null
  [ "$(field "$(item running signup)" tags)" = desk:legal ]
  [ "$(field "$(item running signup)" desk_start)" = mac-desktop ]
  run "$AQ" next --json
  assert_failure
  run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (behind signup, starting)"
  # A session that never claims holds the line only AQ_DESK_START_MIN; then the next best (listing over no class) is head.
  sed -i "s/^started: .*/started: $(date -u -d '11 minutes ago' +%Y-%m-%dT%H:%M:%SZ)/" "$(item running signup)"
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = shots ]
}

@test "within one desk class the head is the urgent item, and one held by its after: is passed over (ar-2359)" {
  # desk_head reads slug, after, tags and priority by column from header_rows: this pins each.
  export AGENT_HOLD_DIR="$SANDBOX/holds" AGENT_QUEUE_NOW=12:00
  printf '#!/usr/bin/env bash\necho "here 5 tmux"\n' > "$SANDBOX/bin/fleet-presence"; chmod +x "$SANDBOX/bin/fleet-presence"
  "$AQ" add --project game --slug blocker "still live" >/dev/null
  legacy old "tags: hold:mac-desktop desk:listing" --project game "oldest" >/dev/null
  legacy waits "after: blocker\ntags: hold:mac-desktop desk:listing" --project game --priority urgent "held by after" >/dev/null
  legacy hot "tags: hold:mac-desktop desk:listing" --project game --priority urgent "urgent" >/dev/null
  legacy late "tags: hold:mac-desktop desk:listing" --project game --priority low "low" >/dev/null
  run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (behind hot, listing)"
  # Control: with hot gone, the oldest heads (late waits behind it), not waits, which its after: holds.
  "$AQ" cancel hot --why "test" >/dev/null
  run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (behind old, listing)"
  refute_output --partial "behind waits"
}

@test "requeue --class tags the item's desk class once, and a later --class replaces it" {
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  "$AQ" add --project game --running --slug forms "fill the store forms" >/dev/null
  "$AQ" set forms row=game:gm-9 >/dev/null
  "$REPO_ROOT/.local/bin/agent-hold" claim mac-desktop --by other "steam forms" >/dev/null
  run "$AQ" requeue forms --hold mac-desktop --class nope
  assert_failure; assert_output --partial "desk:<class>"
  run "$AQ" requeue forms --ask q1 --class legal
  assert_failure; assert_output --partial "usage"
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" requeue forms --hold mac-desktop --class legal >/dev/null
  assert_called "ptask game --agent tag --add hold/mac-desktop --add desk/legal gm-9"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-forms.md)" tags)" = "hold:mac-desktop desk:legal" ]
  # One class per item: a --class replaces the one it had.
  "$AQ" add --project game --running --slug legal --tags desk:legal "sign the terms" >/dev/null
  "$AQ" set legal row=game:gm-8 >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" requeue legal --hold mac-desktop --class auth >/dev/null
  assert_called "ptask game --agent tag --add hold/mac-desktop --add desk/auth gm-8"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-legal.md)" tags)" = "hold:mac-desktop desk:auth" ]
}

@test "requeue --ask returns a headless run that needs the human to its row behind the ask" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  "$AQ" add --project game --running --slug codexrun "pick a palette" >/dev/null
  "$AQ" set codexrun "lane_run=r-codex" row=game:gm-9 >/dev/null
  run "$AQ" requeue codexrun --ask q9
  assert_failure; assert_output --partial "no agent-ask has that id"
  run "$AQ" requeue codexrun --ask q9 --hold mac-desktop
  assert_failure; assert_output --partial "usage"
  ask q9 answered 'a' human
  run "$AQ" requeue codexrun --ask q9
  assert_failure; assert_output --partial "already answered"
  [ -n "$(item running codexrun)" ]
  ask q9 pending
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" requeue codexrun --ask q9
  assert_success
  # Its row waits on the ask (agent-ask start_held promotes it on the answer); no queued item holds.
  assert_called "ptask game --agent tag --add ask/q9 gm-9"
  [ -z "$(item queued codexrun 2>/dev/null)" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-codexrun.md)" end_reason)" = returned ]
}

# ar-900: reap failed a live item on one agent-panel read, and the shepherd had to mv its file back by hand.
@test "reopen puts a failed item back with its session and note and starts its row again; an active, ok or cancelled one is refused" {
  printf '#!/usr/bin/env bash\necho "notes $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  "$AQ" add --project game --running --slug cut "cut the beta" >/dev/null
  "$AQ" set cut "session=lab:game-agent-1" "row=game:gm-7" "profile=bnb" "lane=human" >/dev/null
  "$AQ" claim cut --sid e4347d61 >/dev/null
  run "$AQ" reopen cut
  assert_failure; assert_output --partial "still active"
  "$AQ" move cut done --status failed >/dev/null
  "$AQ" set cut "note=session lab:game-agent-1 ended before it closed the item" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" reopen cut --to sideways
  assert_failure
  run "$AQ" reopen cut --why "reap read live e4347d61 as gone"
  assert_success; assert_output --partial "cut: done -> running (reopened, was failed)"
  f="$(item running cut)"
  [ -z "$(field "$f" status)" ] || fail "status: survived the reopen"
  [ -z "$(field "$f" finished)" ] || fail "finished: survived the reopen"
  [ "$(field "$f" session)" = "lab:game-agent-1" ] || fail "session: was lost"
  [ "$(field "$f" sessions)" = e4347d61 ] || fail "sessions: was lost"
  [ "$(field "$f" note)" = "reopened from done (failed: session lab:game-agent-1 ended before it closed the item): reap read live e4347d61 as gone" ] || fail "note: $(field "$f" note)"
  # A human-lane row, so no --agent: started again on its own board, and marked running.
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game start gm-7
notes --profile bnb ptask game run gm-7"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cut.md 2>/dev/null)" ] || fail "a done copy was left behind"
  # --to waiting stamps waiting:; no lane is the agent lane, and no profile is notes' default.
  "$AQ" move cut done --status failed >/dev/null
  sed -i '/^lane: /d; /^profile: /d' "$AGENT_QUEUE_DIR"/done/*/*-cut.md
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" reopen cut --to waiting >/dev/null
  [ -n "$(field "$(item waiting cut)" waiting)" ] || fail "--to waiting did not stamp waiting:"
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output "notes ptask game --agent start gm-7
notes ptask game --agent run gm-7"
  # A row that will not start again fails the reopen, after the item is back.
  "$AQ" move cut done --status failed >/dev/null
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/notes"
  run "$AQ" reopen cut
  assert_failure; assert_output --partial "could not be started again"
  [ -n "$(item running cut)" ] || fail "a failed row restart left the item done"
  # A cancel was a decision and an ok close may have started the items after it: neither is a reopen.
  "$AQ" cancel cut >/dev/null
  run "$AQ" reopen cut
  assert_failure; assert_output --partial "closed cancelled, not failed"
  "$AQ" add --project game --running --slug cut "cut the beta again" >/dev/null
  "$AQ" move cut done --status ok >/dev/null
  run "$AQ" reopen cut
  assert_failure; assert_output --partial "closed ok, not failed"
  run "$AQ" reopen nosuch
  assert_failure; assert_output --partial "no finished item"
}

# ar-1031: agent-land closed shape-city-steam-console and its row on dotfiles-private#652, a side PR.
@test "reopen --unland takes a false ok close's PR off the item and reopens its row; a PR it does not record is refused" {
  printf '#!/usr/bin/env bash\necho "notes $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  "$AQ" add --project game --running --slug store "store page" >/dev/null
  "$AQ" set store "row=game:gm-9" "profile=bnb" "pr=o/game#5 o/tools#652" "merged=aaa bbb" "closing_pr=o/tools#652" >/dev/null
  "$AQ" move store done --status ok >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" reopen store --unland o/tools
  assert_failure; assert_output --partial "--unland takes <owner>/<repo>#<N>"
  run "$AQ" reopen store --unland o/tools#7
  assert_failure; assert_output --partial "store records pr:o/game#5 o/tools#652, not o/tools#7"
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-store.md)" ] || fail "a refused reopen moved the item"
  run "$AQ" reopen store --unland O/Tools#652 --why "a skill fix, not the store page"
  assert_success; assert_output --partial "store: done -> running (reopened, was ok)"
  f="$(item running store)"
  [ "$(field "$f" pr)" = "o/game#5" ] || fail "pr: $(field "$f" pr)"
  [ "$(field "$f" merged)" = aaa ] || fail "merged: $(field "$f" merged)"
  [ -z "$(field "$f" closing_pr)" ] || fail "closing_pr: survived"
  [ "$(field "$f" note)" = "reopened from done (ok, unlanded O/Tools#652): a skill fix, not the store page" ] || fail "note: $(field "$f" note)"
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent reopen gm-9 --why closed on O/Tools#652, not its work: a skill fix, not the store page
notes --profile bnb ptask game --agent start gm-9
notes --profile bnb ptask game --agent run gm-9"
  # A failed close takes no --unland: nothing landed to take off.
  "$AQ" move store done --status failed >/dev/null
  run "$AQ" reopen store --unland o/game#5
  assert_failure; assert_output --partial "--unland undoes an ok close, and store closed failed"
  # pr: and merged: out of step name no commit by index: refused, nothing changed.
  "$AQ" add --project game --running --slug skew "skew" >/dev/null
  "$AQ" set skew "pr=o/game#6 o/tools#653" "merged=ccc" >/dev/null
  "$AQ" move skew done --status ok >/dev/null
  run "$AQ" reopen skew --unland o/tools#653
  assert_failure; assert_output --partial "skew records 2 pr: and 1 merged: entries, not in step"
  # A bare ref is the PR by its number; a row reopen that fails (the row was never closed) still starts it.
  printf '#!/usr/bin/env bash\necho "notes $*" >> "$NOTES_FIXTURE/calls.log"\n[[ " $* " != *" reopen "* ]]\n' > "$SANDBOX/bin/notes"
  "$AQ" add --project game --running --slug bare "bare" >/dev/null
  "$AQ" set bare "row=game:gm-10" "pr=654 o/game#7" "merged=ddd eee" >/dev/null
  "$AQ" move bare done --status ok >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" reopen bare --unland o/tools#654
  assert_success; assert_output --partial "board row gm-10 on game was not reopened"
  assert_output --partial "bare: board row gm-10 started again"
  f="$(item running bare)"
  [ "$(field "$f" pr)" = "o/game#7" ] && [ "$(field "$f" merged)" = eee ] || fail "pr: $(field "$f" pr) merged: $(field "$f" merged)"
}

@test "a pr: tag holds an item until gh says the PR merged, and after still holds with it" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  # gh stub: the state for PR N is the file $SANDBOX/pr-N; every call is logged.
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/gh.log"\ncat "%s/pr-$3"\n' "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh"
  echo OPEN > "$SANDBOX/pr-7"; echo OPEN > "$SANDBOX/pr-8"
  legacy blocked "tags: pr:Org/game#7" --project game --priority urgent "a"
  "$AQ" add --project game --slug base "b"
  legacy both "after: base\ntags: pr:Org/game#8" --project game --priority urgent "c"
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
  legacy blocked "tags: pr:Org/game#9" --project game "a"
  run bash -c "'$AQ' list --json | jq -r '.hold'"
  assert_output "pr:Org/game#9 not merged"
}

# 2026-11-14: the pr: holds on home-config PRs asked gh, which sees only the GitHub mirror, on every
# pass, uncached: 5,241 failed REST calls that day, and the hold never released.
@test "a pr: tag on a Forgejo-canonical repo reads Forgejo's API, never gh, and releases on its merge" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache" AGENT_QUEUE_PR_TTL=0
  mkdir -p "$REPO/.forgejo/workflows"; : > "$REPO/.forgejo/workflows/mirror-to-github.yaml"
  git -C "$REPO" remote add forgejo https://git.example.test/o/game.git
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/gh.log"\nexit 1\n' "$SANDBOX" > "$SANDBOX/bin/gh"
  printf '#!/usr/bin/env bash\necho sekret\n' > "$SANDBOX/bin/rbw-fj"
  printf '#!/usr/bin/env bash\nurl=${*: -1}; echo "$url" >> "%s/fj.urls"\ncase "$url" in */pulls/5) cat "%s/fj.pr" ;; */status) echo "{\\"statuses\\": []}" ;; *) exit 22 ;; esac\n' \
    "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/curl-fj"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/rbw-fj" "$SANDBOX/bin/curl-fj"
  export SO_CURL=curl-fj SO_RBW=rbw-fj SO_FORGEJO_HOSTS=git.example.test
  echo '{"number": 5, "state": "open", "merged": false, "head": {"sha": "h1"}}' > "$SANDBOX/fj.pr"
  legacy blocked "tags: pr:kblack0610/game#5" --project game "a"
  run bash -c "'$AQ' list --json | jq -r '.hold'"
  assert_output "pr:kblack0610/game#5 not merged"
  # Read, not failed: a failed read would cache an empty state.
  [ "$(cat "$SANDBOX/pr-cache/kblack0610_game_5")" = OPEN ] || fail "open PR read as '$(cat "$SANDBOX/pr-cache/kblack0610_game_5")'"
  echo '{"number": 5, "state": "closed", "merged": true, "merge_commit_sha": "m1", "head": {"sha": "h1"}}' > "$SANDBOX/fj.pr"
  [ "$("$AQ" next --json | jq -r .slug)" = blocked ]
  grep -qx 'https://git.example.test/api/v1/repos/o/game/pulls/5' "$SANDBOX/fj.urls" || fail "Forgejo not asked"
  ! grep -q '/status$' "$SANDBOX/fj.urls" || fail "a state read also read the head's statuses"
  [ ! -e "$SANDBOX/gh.log" ] || fail "gh was asked: $(cat "$SANDBOX/gh.log")"
}

@test "a pr: read that fails is cached for the TTL, so a pass of lists costs one call (negative control: TTL 0 asks again)" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/gh.log"\nexit 1\n' "$SANDBOX" > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
  legacy blocked "tags: pr:Org/game#9" --project game "a"
  for _ in 1 2 3; do "$AQ" list --json >/dev/null; done
  [ "$(wc -l < "$SANDBOX/gh.log")" -eq 1 ] || fail "gh asked $(wc -l < "$SANDBOX/gh.log") times"
  AGENT_QUEUE_PR_TTL=0 "$AQ" list --json >/dev/null
  [ "$(wc -l < "$SANDBOX/gh.log")" -eq 2 ] || fail "TTL 0 did not ask again"
}

@test "a pr: tag on a PR closed unmerged holds and says it never releases" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  printf '#!/usr/bin/env bash\ncat "%s/pr-$3"\n' "$SANDBOX" > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
  echo CLOSED > "$SANDBOX/pr-11"
  legacy dead "tags: pr:Org/game#11" --project game "a"
  run bash -c "'$AQ' list --json | jq -r '.hold'"
  assert_output "pr:Org/game#11 closed unmerged, never releases: cancel the item or set its tags without it"
  [ -z "$("$AQ" next --json)" ] || fail "a closed PR released its hold"
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
  legacy triage "tags: nightly:game" --project game --priority urgent "a"
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
  legacy validate "tags: at:2026-11-07T00:00 nightly:game" --project game "a"
  AGENT_QUEUE_NOW=2026-11-06T09:00 run bash -c "'$AQ' list --json | jq -r '.hold'"
  assert_output "at:2026-11-07T00:00"
  AGENT_QUEUE_NOW=2026-11-07T01:00 run bash -c "'$AQ' list --json | jq -r '.hold'"
  assert_output "nightly:game (test.yml due 02:00)"
}

@test "a nightly: hold with a dated at: stays released after midnight once that night finished (22:00 slot)" {
  # 2026-11-08 PST: soak.yml at 06:00 UTC is 22:00 local, the day's last slot; it finished 23:48.
  # Judged by today, the next morning every slot of 11-09 held again (nightly-validate-20261108).
  export TZ=America/Los_Angeles SCHEDULES_STATE="$SANDBOX/schedules.json"
  jq -n '{repos: [{repo: "Org/game", synced_at: "2026-11-09T16:15:00Z", workflows: [
    {path: ".github/workflows/soak.yml", crons: ["0 6 * * *"], timeout_min: 300,
     runs: [{id: 3, created_at: "2026-11-09T06:21:00Z", status: "completed"}]},
    {path: ".github/workflows/test.yml", crons: ["0 10 * * *"], timeout_min: 300,
     runs: [{id: 1, created_at: "2026-11-08T10:01:00Z", status: "completed"},
            {id: 2, created_at: "2026-11-09T10:01:00Z", status: "in_progress"}]}]}]}' > "$SCHEDULES_STATE"
  legacy validate "tags: at:2026-11-08T00:00 nightly:game" --project game "a"
  [ "$(AGENT_QUEUE_NOW=2026-11-09T08:20 "$AQ" next --json | jq -r .slug)" = validate ]
  # NEGATIVE CONTROL: with no at: date the same hold reads today (11-09) and still waits on soak.
  "$AQ" cancel validate
  legacy today "tags: nightly:game" --project game "b"
  AGENT_QUEUE_NOW=2026-11-09T08:20 run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"today\") | .hold'"
  assert_output "nightly:game (soak.yml due 22:00)"
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
  "$AQ" move w review
  [ -n "$(field "$(item review w)" review)" ]
  run "$AQ" list --state active
  assert_output --partial $'review\t'
  run "$AQ" list --state waiting
  assert_output 'queue: nothing waiting'
  run "$AQ" list --state review --json
  [ "$(jq -r .slug <<<"$output")" = w ]
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

@test "move --end records why a run ended; a run that ended outside the model files no outcome, on a close or a requeue; timeout and stopped still rate" {
  printf '#!/usr/bin/env bash\necho "model-lane $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/model-lane"
  chmod +x "$SANDBOX/bin/model-lane"
  for s in lim prov cut ref req tmo stp; do "$AQ" add --project game --running --slug "$s" "$s" >/dev/null; "$AQ" set "$s" "lane_run=r-$s" >/dev/null; done
  "$AQ" move lim done --status failed --end limit >/dev/null
  "$AQ" move prov done --status failed --end provider >/dev/null
  "$AQ" move cut done --status failed --end cut >/dev/null
  "$AQ" move ref done --status failed --end refused >/dev/null
  "$AQ" move req queued --end limit >/dev/null
  "$AQ" move tmo done --status failed --end timeout >/dev/null
  "$AQ" move stp done --status failed --end stopped >/dev/null   # negative control: a stop is the model's own end
  run grep '^model-lane' "$NOTES_FIXTURE/calls.log"
  assert_output $'model-lane outcome r-tmo failed\nmodel-lane outcome r-stp failed'
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-lim.md)" end_reason)" = limit ]
  [ "$(field "$(item queued req)" end_reason)" = limit ]
  # A new run has not ended: the reason goes when the item runs again.
  "$AQ" move req running >/dev/null
  [ -z "$(field "$(item running req)" end_reason)" ]
}

@test "an item that waited with an end reason and then landed, or was cancelled, keeps none" {
  "$AQ" add --project game --running --slug w "w" >/dev/null
  "$AQ" move w waiting --end cut >/dev/null
  [ "$(field "$(item waiting w)" end_reason)" = cut ]
  "$AQ" move w done --status ok >/dev/null
  [ -z "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-w.md)" end_reason)" ]
  "$AQ" add --project game --running --slug x "x" >/dev/null
  "$AQ" move x waiting --end limit >/dev/null
  "$AQ" cancel x >/dev/null
  [ -z "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-x.md)" end_reason)" ]
}

@test "an end reason is one of the known ones, in move and in set" {
  "$AQ" add --project game --running --slug e "e" >/dev/null
  run "$AQ" move e done --status failed --end tired
  assert_failure
  assert_output --partial 'end_reason is one of'
  run "$AQ" set e end_reason=tired
  assert_failure
  run "$AQ" set e end_reason=limit
  assert_success
  [ "$(field "$(item running e)" end_reason)" = limit ]
}

@test "stats counts finished items by end reason, and leaves out the ones that name none" {
  "$AQ" add --project game --running --slug a "a" >/dev/null
  "$AQ" add --project game --running --slug b "b" >/dev/null
  "$AQ" add --project game --running --slug c "c" >/dev/null
  "$AQ" move a done --status failed --end limit >/dev/null
  "$AQ" move b done --status failed --end limit >/dev/null
  "$AQ" move c done --status failed >/dev/null
  run "$AQ" stats --json
  assert_success
  assert_equal "$(jq -c .by_end <<<"$output")" '{"limit":2}'
  run "$AQ" stats
  assert_output --partial 'ends:    limit 2'
}

@test "done ok refuses an item with pr: and no merged:, and its after: item stays queued" {
  "$AQ" add --project game --running --slug p "p" >/dev/null
  legacy next "after: p" --project game "next" >/dev/null
  "$AQ" set p pr=o/game#9999 >/dev/null
  run "$AQ" move p done --status ok
  assert_failure
  assert_output --partial 'p has pr:o/game#9999 and no merged:'
  assert_output --partial 'agent-land'
  [ -f "$(item running p)" ]
  [ -f "$(item queued next)" ]
  ! grep -q '^fleet-dispatch' "$NOTES_FIXTURE/calls.log" 2>/dev/null || fail "started next on an unmerged close"
  # The ways out: waiting until it merges, or a close that is not ok.
  "$AQ" move p waiting
  "$AQ" move p done --status failed
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-p.md)" status)" = failed ]
}

@test "done ok closes an item with pr: once merged: is set (negative control)" {
  "$AQ" add --project game --running --slug m2 "m2" >/dev/null
  "$AQ" set m2 pr=o/game#9999 merged=abc123 >/dev/null
  run "$AQ" move m2 done --status ok
  assert_success
  assert_output --partial 'm2: running -> done'
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-m2.md)" status)" = ok ]
}

@test "a new pr: drops the last PR's merged:, so done ok waits for the new merge" {
  "$AQ" add --project game --running --slug re "re" >/dev/null
  "$AQ" set re pr=o/game#1 merged=aaa111 >/dev/null
  "$AQ" set re pr=o/game#1 >/dev/null
  [ "$(field "$(item running re)" merged)" = aaa111 ]
  "$AQ" set re pr=o/game#2 >/dev/null
  [ -z "$(field "$(item running re)" merged)" ]
  run "$AQ" move re done --status ok
  assert_failure; assert_output --partial 'no merged:'
  "$AQ" set re pr=o/game#2 merged=bbb222 >/dev/null
  "$AQ" move re done --status ok
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
  # ar-2707: a title is settable, on a done item too, written on one line as add --title writes it.
  # NEGATIVE CONTROL: before ar-2707 this set failed "not a settable field: title".
  run "$AQ" set s $'title=  P2: every machine\tis a peer\nclone  '
  assert_success
  [ "$(field "$f" title)" = "P2: every machine is a peer clone" ]
  [ "$(sed -n '/^---$/,$p' "$f" | sed 1d)" = s ]
}

@test "retask replaces a queued item's task from args or stdin and keeps its header; refuses an empty task or a started or done item" {
  legacy r "tags: at:2030-01-01T09:00" --project game "expect 16.7"
  f="$(item queued r)"
  head="$(sed '/^---$/q' "$f")"
  run "$AQ" retask r "expect 85.0" "(17 of 20)"
  assert_success
  [ "$(sed -n '/^---$/,$p' "$f" | sed 1d)" = "expect 85.0 (17 of 20)" ]
  [ "$(sed '/^---$/q' "$f")" = "$head" ]
  printf 'line one\n---\nline three\n' | "$AQ" retask r
  [ "$(sed -n '/^---$/,$p' "$f" | sed 1d)" = $'line one\n---\nline three' ]
  [ "$(sed '/^---$/q' "$f")" = "$head" ]
  run "$AQ" show r
  assert_output --partial "line three"
  run "$AQ" retask r " "
  assert_failure; assert_output --partial "no task"
  AGENT_QUEUE_NOW=2030-01-01T09:00 "$AQ" move r running
  run "$AQ" retask r "too late"
  assert_failure; assert_output --partial "r is running: its session already has the brief"
  "$AQ" move r done --status ok
  run "$AQ" retask r "too late"
  assert_failure; assert_output --partial "nothing active with slug r"
  run "$AQ" retask nowhere "x"
  assert_failure
  # The row is the task's record: an item whose row is not on the board is refused, item untouched.
  "$AQ" add --project game --from "board:game:ar-9" --slug gone "old words"
  run "$AQ" retask gone "new words"
  assert_failure; assert_output --partial "its board row ar-9 is not open on game, so nothing was rewritten"
  [ "$(sed -n '/^---$/,$p' "$(item queued gone)" | sed 1d)" = "old words" ]
}

@test "a project rename moves the item's board origin with it, so agent-land closes the right row" {
  "$AQ" add --project game --from "board:game:fix the lobby: soon" --slug r "fix the lobby"
  run "$AQ" set r project=level "from=board:level:fix the lobby: soon"
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/queued/*-r.md)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" from)" = "board:level:fix the lobby: soon" ]
}

@test "set refuses a project the registry does not know, or another spelling of one, and writes nothing" {
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

# 2026-11-18: 18 live items had no origin, every one a session's own --running record, and
# fleet-dispatch counted each as one of its runs.
@test "a --running record writes no origin, so it has no by, and each other item's by is its origin through ORIGIN_BY" {
  "$AQ" add --project game --running --session dotfiles-71 --slug mine "this session"
  [ -z "$(field "$(item running mine)" origin)" ]
  local o
  for o in run redispatch resume hand scratch sweep; do
    "$AQ" add --project game --running --slug "o-$o" "started by $o" >/dev/null
    "$AQ" set "o-$o" "origin=$o" >/dev/null
  done
  "$AQ" add --project game --slug waits "not started" >/dev/null
  run "$AQ" list --json --state active
  assert_success
  assert_equal "$(jq -sSc 'map({(.slug): .by}) | add' <<<"$output")" \
    '{"mine":null,"o-hand":"hand","o-redispatch":"dispatch","o-resume":"resume","o-run":"dispatch","o-scratch":"hand","o-sweep":"sweep","waits":null}'
}

@test "--running records <server>:<session> on any world; only a worktree session (<repo>-agent-N) records; a checkout session, declared or not, or no tmux, records none" {
  printf 'dotfiles-agent-9\n' > "$NOTES_FIXTURE/tmux.session"
  TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0" run "$AQ" add --project game --running --slug here "this session"
  assert_success
  [ "$(field "$(item running here)" session)" = lab:dotfiles-agent-9 ]
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.session"
  TMUX="$SANDBOX/tmp/tmux-1000/hub,123,0" run "$AQ" add --project game --running --slug hubbed "from a hub window"
  assert_success
  [ -z "$(field "$(item running hubbed)" session)" ]
  printf 'dotfiles-agent-3\n' > "$NOTES_FIXTURE/tmux.session"
  TMUX="$SANDBOX/tmp/tmux-1000/hub,123,0" run "$AQ" add --project game --running --slug hubwt "from a hub worktree session"
  assert_success
  [ "$(field "$(item running hubwt)" session)" = hub:dotfiles-agent-3 ]
  printf 'tools\n' > "$NOTES_FIXTURE/tmux.session"
  TMUX="$SANDBOX/tmp/tmux-1000/hub,123,0" run "$AQ" add --project game --running --slug hubtools "from an undeclared checkout session"
  assert_success
  [ -z "$(field "$(item running hubtools)" session)" ]
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

@test "mine: the Claude session decides first, across tmux sessions and in waiting or review; none with a session id exits 1" {
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
  "$AQ" move ours review
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
  printf '%s\t%s\t%s\t%s\t1\n' "fix(agent-land): mine picks a waiting item" fix agent-land "mine picks a waiting item" \
    "feat(queue): a ledger" feat queue "a ledger" > "$NOTES_FIXTURE/row.parse"
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --running --slug typed "fix(agent-land): mine picks a waiting item"
  f="$(item running typed)"
  [ "$(field "$f" sessions)" = sid-a ]
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --priority high --slug later "queued for another session"
  [ -z "$(field "$(item queued later)" sessions)" ]
  [ "$(field "$f" type)" = fix ]
  [ "$(field "$f" area)" = agent-land ]
  "$AQ" add --project game --slug untyped "Menu: pick sides"
  assert_called 'notes row parse'
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
  # sessions is the history of who worked the item, so a done item takes a later session (agent-land's second-repo PR).
  run "$AQ" claim typed --sid sid-c
  assert_success
  [ "$("$AQ" show typed --json | jq -r .sessions)" = "sid-a sid-b sid-c" ]
  run "$AQ" claim nosuch --sid sid-c
  assert_failure
  assert_output --partial "no item: nosuch"
}

@test "a session's own claim of a queued item takes it: running, with its tmux session; a --sid claim leaves it queued (ar-1693)" {
  "$AQ" add --project game --slug phase "a plan phase queued for later"
  "$AQ" claim phase --sid sid-d >/dev/null
  [ -n "$(item queued phase)" ] || fail "a starter's --sid claim moved the item"
  printf 'dotfiles-agent-9\n' > "$NOTES_FIXTURE/tmux.session"
  TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0" CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" claim phase
  assert_success
  assert_output --partial 'phase: queued -> running'
  f="$(item running phase)"
  [ "$(field "$f" session)" = lab:dotfiles-agent-9 ]
  [ "$(field "$f" sessions)" = "sid-d sid-a" ]
  [ -n "$(field "$f" started)" ]
  # a claim of a running item adds the session and moves nothing
  CLAUDE_CODE_SESSION_ID=sid-b run "$AQ" claim phase
  assert_success
  refute_output --partial -- '->'
  [ "$(field "$(item running phase)" sessions)" = "sid-d sid-a sid-b" ]
  # a session already on a queued item (a --sid claim, a run before a requeue) takes it all the same
  "$AQ" add --project game --slug again "requeued after a run"
  "$AQ" claim again --sid sid-e >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-e run "$AQ" claim again
  assert_output --partial 'already claimed'
  assert_output --partial 'again: queued -> running'
  [ "$(field "$(item running again)" sessions)" = sid-e ]
}

@test "add --running warns when an active item of the project holds its area; a queued add, another project or another area does not" {
  printf '%s\t%s\t%s\t%s\t1\n' "fix(menu): the back button" fix menu "the back button" \
    "feat(Menu): a settings page" feat Menu "a settings page" "fix(save): slots" fix save "slots" > "$NOTES_FIXTURE/row.parse"
  "$AQ" add --project game --running --session lab:peer --slug first "fix(menu): the back button"
  run "$AQ" add --project game --running --slug second "feat(Menu): a settings page"
  assert_success
  assert_output --partial 'area Menu on game is already held by first (running in lab:peer)'
  [ -n "$(item running second)" ] || fail "a hand start was refused"
  run "$AQ" add --project game --running --slug other-area "fix(save): slots"
  refute_output --partial 'already held'
  run "$AQ" add --project app --running --slug other-project "fix(menu): the back button"
  refute_output --partial 'already held'
  run "$AQ" add --project game --slug later "fix(menu): the back button"
  refute_output --partial 'already held'
  # a queued item that turns running (a session's own claim, start --item) is told too, never of itself
  run env CLAUDE_CODE_SESSION_ID=sid-h "$AQ" claim later
  assert_output --partial 'area menu on game is already held by first (running in lab:peer)'
  refute_output --partial 'held by later'
  [ -n "$(item running later)" ] || fail "a claim on a held area was refused"
}

@test "a session that takes or lands an item by hand records its account; a --sid claim and a queued add do not" {
  CLAUDE_CONFIG_DIR=/h/.claude-bnb CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --running --slug hand "taken by hand"
  [ "$(field "$(item running hand)" account)" = .claude-bnb ]
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --priority high --slug later "queued for another session"
  f="$(item queued later)"
  [ -z "$(field "$f" account)" ]
  # fleet-dispatch start claims with --sid and sets the account it launched on itself
  "$AQ" claim later --sid sid-d >/dev/null
  [ -z "$(field "$f" account)" ]
  # agent-land from a hand session on the default config dir: main (its own claim takes the item: running)
  CLAUDE_CODE_SESSION_ID=sid-b "$AQ" claim later >/dev/null
  f="$(item running later)"
  [ "$(field "$f" account)" = main ]
  # the first account recorded stays
  CLAUDE_CONFIG_DIR=/h/.claude-max4 CLAUDE_CODE_SESSION_ID=sid-c "$AQ" claim later >/dev/null
  [ "$(field "$f" account)" = main ]
  [ "$(field "$f" sessions)" = "sid-d sid-b sid-c" ]
  # an item another harness worked keeps no account when a Claude session lands it
  "$AQ" add --project game --slug cx "worked by codex"
  "$AQ" set cx agent=codex >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-e "$AQ" claim cx >/dev/null
  [ -z "$(field "$(item queued cx)" account)" ]
}

@test "an urgent or high plan item starts its session at once, a low one waits its turn; a failed start leaves it queued; AGENT_QUEUE_START=0 only queues; a dispatch hold only queues" {
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
  # A low plan item waits for a dispatch pass; an urgent one still starts.
  run "$AQ" add --project game --mode plan --priority low --slug lp "plan, low"
  assert_success
  assert_output --partial 'lp is low priority, so a dispatch pass starts it in its turn'
  assert_not_called 'start --item lp'
  [ -f "$(item queued lp)" ]
  run "$AQ" add --project game --mode plan --priority urgent --slug up "plan, urgent"
  assert_called 'fleet-dispatch start --item up'
  # 2026-11-12: an urgent plan item started under the human's dispatch hold.
  "$REPO_ROOT/.local/bin/agent-hold" set dispatch --by human "next queue" >/dev/null
  run "$AQ" add --project game --mode plan --priority urgent --slug held "plan, held"
  assert_success
  assert_output --partial 'so held stays queued for the next dispatch pass'
  assert_not_called 'start --item held'
  [ -f "$(item queued held)" ]
}

@test "an urgent oneshot from the human starts at add; high, a machine filer's urgent, a dispatched session's urgent and a held urgent do not (ar-2944)" {
  story_notes
  run "$AQ" add --project game --priority urgent --slug u1 "fix it now"
  assert_success
  assert_called 'fleet-dispatch start --item u1'
  # negative controls
  run "$AQ" add --project game --priority high --slug h1 "soon"
  assert_not_called 'start --item h1'
  run "$AQ" add --project game --priority urgent --from shepherd --slug s1 "shepherd red"
  assert_not_called 'start --item s1'
  # an unattended session took the default from: a hand start would skip the load gates
  AGENT_QUEUE_ITEM=u1 run "$AQ" add --project game --priority urgent --slug d1 "a session's urgent"
  assert_success
  assert_not_called 'start --item d1'
  # Held work is its board row's, never the queue's: nothing starts.
  run "$AQ" add --project level --priority urgent --tags at:23:59 --slug n1 "tonight"
  assert_failure 5
  assert_output --partial 'held n1 -> level:lv-9 (#at/2359)'
  assert_not_called 'start --item n1'
  "$AQ" add --project level --running --slug par "parent" >/dev/null
  run "$AQ" add --project level --priority urgent --after par --slug a1 "after parent"
  assert_failure 5
  assert_output --partial 'held a1 -> level:lv-9 (#after/lv-9)'
  assert_not_called 'start --item a1'
}

@test "the human's want added at hand starts at add; the same add without --want, a dispatched session's want and a low want do not" {
  story_notes
  unset AGENT_QUEUE_PULL # each add below goes through admission itself, as a real session's does
  run "$AQ" add --project game --want human --slug w1 "the human asked for this"
  assert_success
  assert_called 'fleet-dispatch start --item w1'
  # negative controls
  run "$AQ" add --project game --priority high --slug w0 "an agent idea"
  assert_success
  assert_not_called 'start --item w0'
  # a dispatched session (its item not origin hand) is not the human: admission files it on the board
  "$AQ" set w1 origin=run >/dev/null
  run env AGENT_QUEUE_ITEM=w1 "$AQ" add --project level --want human --slug wd "a dispatched session's want"
  assert_failure 5
  assert_output --partial 'only the board fills the queue'
  [ -z "$(item queued wd)" ]
  assert_not_called 'start --item wd'
  run "$AQ" add --project game --want human --priority low --slug wl "a low want"
  assert_success
  assert_not_called 'start --item wl'
}

@test "add --plan starts each urgent or high phase whose wait is met once the chain is written; a low plan, a machine filer's, a dry run and AGENT_QUEUE_START=0 only queue (ar-2944)" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two' '- [ ] P3 three (independent)' > "$SANDBOX/ch.md"
  run "$AQ" add --plan "$SANDBOX/ch.md" --project level --slug ch
  assert_success
  assert_called 'fleet-dispatch start --item ch-p1'
  assert_called 'fleet-dispatch start --item ch-p3'
  # P2 waits on P1, so it is P1's row's waiter on the board, not a queue item.
  assert_line 'held ch-p2 -> level:lv-2 (#after/lv-1)'
  assert_not_called 'start --item ch-p2'
  [ -z "$(item queued ch-p2)" ]
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/lo.md"
  run "$AQ" add --plan "$SANDBOX/lo.md" --project game --priority low --slug lo
  assert_success
  assert_not_called 'start --item lo-p1'
  assert_line 'agent-queue: lo.md is low priority, so a dispatch pass starts it in its turn'
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two (independent)' > "$SANDBOX/rs.md"
  run "$AQ" add --plan "$SANDBOX/rs.md" --project game --from research:x --slug rs
  assert_success
  assert_not_called 'start --item rs-p'
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/dr.md"
  run "$AQ" add --plan "$SANDBOX/dr.md" --project game --slug dr --dry-run
  assert_success
  assert_not_called 'start --item dr-p1'
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/q0.md"
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/q0.md" --project game --slug q0
  assert_not_called 'start --item q0-p1'
}

@test "an ok close pulls the rows gated on its row through fleet-dispatch pull-after; a failed close, a rowless item and AGENT_QUEUE_START=0 pull nothing" {
  story_notes
  # The rows after it are pulled through fleet-dispatch, which runs the admission and room checks.
  "$AQ" add --project level --running --slug ph1 "phase 1" >/dev/null
  run "$AQ" move ph1 done --status ok
  assert_success
  assert_called 'fleet-dispatch pull-after lv-9'
  : > "$NOTES_FIXTURE/calls.log"
  # NEGATIVE CONTROLS: a failed close, an item with no row and AGENT_QUEUE_START=0 pull nothing.
  "$AQ" add --project level --running --slug f1 "fails" >/dev/null
  "$AQ" move f1 done --status failed >/dev/null
  "$AQ" add --project game --running --slug g1 "no row" >/dev/null
  "$AQ" move g1 done --status ok >/dev/null
  AGENT_QUEUE_START=0 "$AQ" add --project level --running --slug z1 "parent" >/dev/null
  AGENT_QUEUE_START=0 "$AQ" move z1 done --status ok >/dev/null
  assert_not_called 'pull-after'
  # A pull that fails leaves the rows to the next pass, and the close stands.
  "$AQ" add --project level --running --slug x1 "parent" >/dev/null
  FD_EXIT=1 run "$AQ" move x1 done --status ok
  assert_success
  assert_output --partial 'the rows after lv-9 were not pulled now, so the next dispatch pass promotes them'
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-x1.md)" status)" = ok ]
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

@test "add --plan queues the phase that can start and files each later one as a board row gated on the row before; --dry-run writes nothing" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  plan_fixture
  "$AQ" add --project level --slug base "the work before the plan" >/dev/null
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project level --after base --dry-run
  assert_success
  assert_line --index 0 --regexp '^would queue my-plan-p2	phases 2	after base$'
  assert_line --index 2 --regexp '^would queue my-plan-p4	phases 4 5	after my-plan-p2$'
  assert_line --index 4 --regexp '^would queue my-plan-p6	phases 6	after my-plan-p4$'
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 1 ]
  AGENT_QUEUE_START=0 "$AQ" move base done --status ok >/dev/null
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/my-plan.md" --project level --after base --priority high --tags ui
  assert_success
  # P2 can start, so it is the one queue item; each phase after it waits on the row before it (#after/<row>).
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 1 ]
  f="$(item queued my-plan-p2)"
  [ "$(field "$f" mode)" = oneshot ]
  [ "$(field "$f" after)" = base ]
  [ "$(field "$f" plan)" = "$SANDBOX/my-plan.md" ]
  [ "$(field "$f" phases)" = 2 ]
  [ "$(field "$f" priority)" = high ]
  [ "$(field "$f" tags)" = ui ]
  [ "$(field "$f" title)" = "my-plan P2: Second thing: details" ]
  [ "$(field "$f" row)" = level:lv-2 ]
  grep -qF "Phase 2 of the plan $SANDBOX/my-plan.md: Second thing. Read the plan whole, then do ONLY this phase, to merged." "$f"
  assert_line 'held my-plan-p4 -> level:lv-3 (#after/lv-2)'
  assert_line 'held my-plan-p6 -> level:lv-4 (#after/lv-3)'
  # The row carries the phase's title and its whole brief, for the item dispatch promotes from it.
  grep -F 'ptask level --agent add' "$NOTES_FIXTURE/calls.log" | grep -F "my-plan P4+5: Fourth thing. More words; Fifth thing: shares the branch of 4 #high" | grep -qF '#after/lv-2'
  grep -qF "Phases 4 and 5 of the plan $SANDBOX/my-plan.md: Fourth thing; Fifth thing. Read the plan whole, then do ONLY these phases, on one branch" "$NOTES_FIXTURE/calls.log"
  ! grep -qs "fleet-dispatch" "$NOTES_FIXTURE/calls.log"
}

@test "add --plan: (independent) waits on --after alone, (after N) on phase N's item, unmarked lines keep the chain" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  cat > "$SANDBOX/marked.md" <<'EOF'
## Phases

- [x] 1. Landed thing
- [ ] 2. Second thing
- [ ] 3. Third thing (independent): runs beside 2
- [ ] 4. Fourth thing (after 2)
- [ ] 5. Fifth thing (with 4)
- [ ] 6. Sixth thing
- [ ] 7. Seventh thing (after 5)
- [ ] 8. Eighth thing (after 1)
EOF
  "$AQ" add --project level --slug base "the work before the plan" >/dev/null
  run "$AQ" add --plan "$SANDBOX/marked.md" --project level --after base --dry-run
  assert_success
  assert_line --index 0 --regexp '^would queue marked-p2	phases 2	after base$'
  assert_line --index 2 --regexp '^would queue marked-p3	phases 3	after base$'
  assert_line --index 4 --regexp '^would queue marked-p4	phases 4 5	after marked-p2$'
  # NEGATIVE CONTROL: an unmarked line still waits on the item before it, here the independent one.
  assert_line --index 6 --regexp '^would queue marked-p6	phases 6	after marked-p4$'
  # (after 5) is phase 5's item, which is 4's; (after 1) names a landed phase, so --after alone.
  assert_line --index 8 --regexp '^would queue marked-p7	phases 7	after marked-p4$'
  assert_line --index 10 --regexp '^would queue marked-p8	phases 8	after base$'
  # With no --after, 2, 3 and 8 can start: queued, rows lv-2, lv-3 and lv-7. The rest wait on a row.
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/marked.md" --project level
  assert_success
  f="$(item queued marked-p3)"
  [ "$(field "$f" after)" = "" ]
  [ "$(field "$f" title)" = "marked P3: Third thing: runs beside 2" ]
  [ "$(field "$(item queued marked-p8)" after)" = "" ]
  assert_line 'held marked-p4 -> level:lv-4 (#after/lv-2)'
  assert_line 'held marked-p6 -> level:lv-5 (#after/lv-4)'
  assert_line 'held marked-p7 -> level:lv-6 (#after/lv-4)'
  grep -F 'ptask level --agent add' "$NOTES_FIXTURE/calls.log" | grep -qF 'marked P4+5: Fourth thing; Fifth thing #high #after/lv-2'
  # A marker that cannot be honoured is refused whole, naming the line; nothing is queued.
  bad() {
    printf '## Phases\n\n- [-] 1. Deferred\n- [ ] 2. Two\n- [ ] 3. %s\n' "$1" > "$SANDBOX/bad.md"
    run "$AQ" add --plan "$SANDBOX/bad.md" --project level --slug bad --dry-run
    assert_failure
    assert_output "agent-queue: --plan $SANDBOX/bad.md: could not read its Phases checklist: phase 3: $2"
  }
  bad "Three (after 3)" "(after 3) names no earlier phase"
  bad "Three (after 1)" "(after 1) waits on a deferred phase; undefer it or drop the marker"
  bad "Three (independent) (after 2)" "(independent) and (after 2) contradict"
  bad "Three (with 2) (independent)" "a (with 2) line takes the wait of phase 2's item; mark that line"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 4 ]
}

@test "add --plan: a marker may carry a note, and P<N> labels number the phases, not their place" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  cat > "$SANDBOX/labelled.md" <<'EOF2'
## Phases

- [x] P1 Landed thing (#9)
- [ ] P7 Check a thing first (independent; queued elsewhere, ar-1)
- [x] P9 Landed out of order (independent) (a note)
- [ ] P8 Later thing (after 7; waits on the check)
- [ ] P10 Last thing
EOF2
  "$AQ" add --project level --slug base "the work before the plan" >/dev/null
  run "$AQ" add --plan "$SANDBOX/labelled.md" --project level --after base --dry-run
  assert_success
  # NEGATIVE CONTROL: by position these would be p2, p4 and p5; by label they are p7, p8 and p10.
  assert_line --index 0 --regexp '^would queue labelled-p7	phases 7	after base$'
  assert_line --index 2 --regexp '^would queue labelled-p8	phases 8	after labelled-p7$'
  assert_line --index 4 --regexp '^would queue labelled-p10	phases 10	after labelled-p8$'
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/labelled.md" --project level
  assert_success
  [ "$(field "$(item queued labelled-p7)" phases)" = 7 ]
  [ "$(field "$(item queued labelled-p7)" title)" = "labelled P7: Check a thing first" ]
  assert_line 'held labelled-p8 -> level:lv-3 (#after/lv-2)'
  assert_line 'held labelled-p10 -> level:lv-4 (#after/lv-3)'
  grep -F 'ptask level --agent add' "$NOTES_FIXTURE/calls.log" | grep -qF 'labelled P8: Later thing #high #after/lv-2'
  # The ticked box and the open phase are read by the same number: p9 landed, p8 did not.
  source "$BATS_TEST_DIRNAME/../../.local/lib/plan-phases.sh"
  [ "$(plan_phase_list "$SANDBOX/labelled.md" | jq -c 'map(.n)')" = "[1,7,9,8,10]" ]
  printf '## Phases\n\n- [ ] P2 Two\n- [ ] P2 Again\n' > "$SANDBOX/dup.md"
  run "$AQ" add --plan "$SANDBOX/dup.md" --project level --slug dup --dry-run
  assert_failure
  assert_output --partial "two phases carry the same number"
  # A P0 phase is a phase like any other (it once read as an `(with 0)` on every later line), a
  # label's punctuation leaves the title, and a repeated number among landed phases is harmless.
  printf '## Phases\n\n- [x] P2 Done once (#1)\n- [x] P2 Done twice (#2)\n- [ ] P0. Preflight\n- [ ] P3 Three\n' > "$SANDBOX/zero.md"
  run "$AQ" add --plan "$SANDBOX/zero.md" --project level --slug zero --dry-run
  assert_success
  assert_line --index 0 --regexp '^would queue zero-p0	phases 0	after -$'
  assert_line --index 1 --partial ': Preflight. Read the plan whole'
  assert_line --index 2 --regexp '^would queue zero-p3	phases 3	after zero-p0$'
}

@test "add --plan: an (at <date> <HH:MM>) phase waits on that time alone, at no more than high (ar-3833)" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  cat > "$SANDBOX/timed.md" <<'EOF'
## Phases

- [ ] P1 Build the thing
- [ ] P2 Cut the build (independent) (at 2099-01-01 21:00; the release window)
- [ ] P3 Write it up (independent)
EOF
  run "$AQ" add --plan "$SANDBOX/timed.md" --project level --priority urgent --dry-run
  assert_success
  assert_line --index 2 --regexp '^would queue timed-p2	phases 2	after -	at:2099-01-01T21:00 high$'
  assert_line --index 3 --partial 'of the plan '"$SANDBOX"'/timed.md: Cut the build. Read the plan whole'
  # NEGATIVE CONTROL: an unmarked phase keeps the plan's priority and has no at: hold.
  assert_line --index 4 --regexp '^would queue timed-p3	phases 3	after -$'
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/timed.md" --project level --priority urgent
  assert_success
  assert_line --regexp '^held timed-p2 -> level:lv-[0-9]+ \(#at/2099-01-01/2100\)$'
  grep -F 'ptask level --agent add' "$NOTES_FIXTURE/calls.log" | grep -qF 'timed P2: Cut the build #high #at/2099-01-01/2100'
  ! grep -F 'timed P2' "$NOTES_FIXTURE/calls.log" | grep -qF '#urgent'
  [ "$(field "$(item queued timed-p1)" priority)" = urgent ]
  [ "$(field "$(item queued timed-p3)" priority)" = urgent ]
  [ "$(field "$(item queued timed-p3)" tags)" = "" ]
  # A (with N) line takes its item's wait, so a time on it is refused like any other marker.
  printf '## Phases\n\n- [ ] 1. One\n- [ ] 2. Two (with 1) (at 2099-01-01 21:00)\n' > "$SANDBOX/bad.md"
  run "$AQ" add --plan "$SANDBOX/bad.md" --project level --slug bad --dry-run
  assert_failure
  assert_output --partial "phase 2: a (with 1) line takes the wait of phase 1's item; mark that line"
}

@test "bump to urgent names an after: hold and the set that lifts it, and never lifts it" {
  "$AQ" add --project game --slug first "first"
  legacy second "after: first" --project game "second"
  run "$AQ" bump second urgent
  assert_success
  assert_output --partial "second -> urgent"
  assert_output --partial "second is held after first: it starts when that lands; agent-queue set second after= runs it now"
  [ "$(field "$(item queued second)" after)" = first ]
  # NEGATIVE CONTROL: no after:, or a bump below urgent, says nothing more.
  run "$AQ" bump first urgent
  assert_output "first -> urgent"
  run "$AQ" bump second high
  assert_output "second -> high"
  # An after: that released leaves a pr: hold, which bump does not name (ar-39 review).
  "$AQ" move first done --status ok >/dev/null
  sed -i '/^from: /i tags: pr:Org/game#11' "$(item queued second)"
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  printf '#!/usr/bin/env bash\ncat "%s/pr-$3"\n' "$SANDBOX" > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
  echo CLOSED > "$SANDBOX/pr-11"
  [[ "$("$AQ" show second --json | jq -r .hold)" == "pr:Org/game#11 closed unmerged"* ]]
  run "$AQ" bump second urgent
  assert_output "second -> urgent"
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
  AGENT_QUEUE_ITEM=mine run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --priority high
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

# 2026-11-12: two cleanup sessions cancelled 425 items and the items said only "cancelled".
@test "cancel from a session needs --why, and records who and why on the item and in the event" {
  "$AQ" add --project game --from shepherd --slug w1 "w1"
  "$AQ" add --project game --from shepherd --slug w2 "w2"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel w1
  assert_failure; assert_output --partial "needs --why"
  [ -n "$(item queued w1)" ]
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=sess-9 AGENT_QUEUE_ITEM=other run "$AQ" cancel w1 --why "superseded by w2"
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-w1.md)"
  [ "$(field "$f" status)" = cancelled ]
  [ "$(field "$f" cancelled_by)" = sess-9 ]
  [ "$(field "$f" cancel_why)" = "superseded by w2" ]
  assert_called "--action item-cancelled"
  assert_called "--by sess-9 --why superseded by w2"
  # a script with only the item slug is named by it
  AGENT_QUEUE_ITEM=sweeper run "$AQ" cancel w2
  assert_failure; assert_output --partial "needs --why"
  AGENT_QUEUE_ITEM=sweeper run "$AQ" cancel w2 --why "dup"
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-w2.md)" cancelled_by)" = sweeper ]
}

@test "cancel at a terminal with no session needs no --why and writes no canceller" {
  "$AQ" add --project game --slug h1 "h1"
  run "$AQ" cancel h1
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-h1.md)"
  [ "$(field "$f" status)" = cancelled ]
  [ -z "$(field "$f" cancelled_by)" ]
  [ -z "$(field "$f" cancel_why)" ]
  "$AQ" add --project game --slug h2 "h2"
  run "$AQ" cancel h2 --why "not needed"
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-h2.md)" cancel_why)" = "not needed" ]
}

@test "move --status cancelled takes the same --why, and --why on any other close is refused" {
  "$AQ" add --project game --from shepherd --slug m1 "m1"
  "$AQ" add --project game --from shepherd --slug m2 "m2"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m1 done --status cancelled
  assert_failure; assert_output --partial "needs --why"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m1 done --status cancelled --why "gone"
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-m1.md)"
  [ "$(field "$f" cancelled_by)" = sess-9 ]
  [ "$(field "$f" cancel_why)" = gone ]
  run "$AQ" move m2 done --status failed --why "x"
  assert_failure; assert_output --partial "--why and --ask record a cancel"
  # a failed close from a session still needs no reason
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m2 done --status failed
  assert_success
}

# 2026-11-12 (ar-2299): a bulk return by `cancel` left every item after: it dead, and a cleanup then
# cancelled those one by one, 40 chains lost.
@test "return sends A back with B after: A: B is returned, not left dead, and both rows are un-started" {
  "$AQ" add --project game --from shepherd --slug ra "a"
  legacy rb "after: ra" --project game --from shepherd "b"
  legacy rc "after: rb" --project game --from shepherd "c"
  "$AQ" add --project game --from shepherd --slug rz "unrelated"
  "$AQ" set ra row=game:gm-1
  "$AQ" set rb row=game:gm-2
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ra
  assert_failure; assert_output --partial "says why"
  [ -n "$(item queued ra)" ]
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ra --why "out of focus"
  assert_success
  for s in ra rb rc; do
    f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-$s.md)"
    [ "$(field "$f" status)" = cancelled ]
    [ "$(field "$f" end_reason)" = returned ]
    [ "$(field "$f" cancel_why)" = "out of focus" ]
  done
  [ -z "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-ra.md)" cancel_cause)" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-rb.md)" cancel_cause)" = "returned with ra" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-rc.md)" cancel_cause)" = "returned with ra" ]
  # nothing is left queued behind a closed item, and the unrelated item is untouched
  run bash -c "'$AQ' list --json | jq -r '.slug + \" \" + (.hold // \"\")'"
  assert_output "rz "
  assert_called "ptask game --agent unstart gm-1"
  assert_called "ptask game --agent unstart gm-2"
  assert_called "--action item-cancelled"
  assert_called "--by sess-9 --why returned: out of focus"
}

@test "return exits 1 and names the row command when a board row could not be un-started, the return stands" {
  "$AQ" add --project game --slug ua "a"
  "$AQ" set ua row=game:gm-5
  printf '#!/usr/bin/env bash\necho "notes $*" >> "$NOTES_FIXTURE/calls.log"\ncase "$*" in *unstart*) exit 1 ;; esac\n' > "$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$AQ" return ua --why "back"
  assert_failure
  assert_output --partial "ua is returned, but its board row gm-5 on game was not un-started: notes ptask game --agent unstart gm-5"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-ua.md)" end_reason)" = returned ]
}

@test "return of an item already behind a dead after: keeps that root cause" {
  "$AQ" add --project game --from shepherd --slug va "a"
  legacy vb "after: va" --project game --from shepherd "b"
  CLAUDE_CODE_SESSION_ID=sess-1 "$AQ" cancel va --why "set aside"
  "$AQ" return vb --why "back"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-vb.md)" cancel_cause)" = "after va closed cancelled by sess-1: set aside" ]
}

@test "negative control: a plain cancel of A still leaves B dead, and cancelling B records A as the cause" {
  "$AQ" add --project game --from shepherd --slug na "a"
  legacy nb "after: na" --project game --from shepherd "b"
  legacy nc "after: nb" --project game --from shepherd "c"
  CLAUDE_CODE_SESSION_ID=sess-1 "$AQ" cancel na --why "set aside"
  run bash -c "'$AQ' show nb --json | jq -r .hold"
  assert_output --partial "after na closed cancelled, dead"
  [ -n "$(item queued nb)" ]
  # the cleanup loop that cancels the dead ones leaves the root cause on each, down the chain
  CLAUDE_CODE_SESSION_ID=sess-2 "$AQ" cancel nb --why "dead chain"
  CLAUDE_CODE_SESSION_ID=sess-2 "$AQ" cancel nc --why "dead chain"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-nb.md)" cancel_cause)" = "after na closed cancelled by sess-1: set aside" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-nc.md)" cancel_cause)" = "after na closed cancelled by sess-1: set aside" ]
  # a cancel with nothing dead before it records no cause
  "$AQ" add --project game --slug nd "d"
  "$AQ" cancel nd
  [ -z "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-nd.md)" cancel_cause)" ]
}

@test "a session returns the human's work to its board row with no ask, but not an item with no row" {
  "$AQ" add --project game --from shepherd --slug ga "a"
  legacy gb "after: ga" --project game "b"
  # gb has no board row: returning it would leave the human's work nowhere, so the guard holds the chain
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "drain the queue under its cap"
  assert_failure; assert_output --partial "gb is work the human asked for"
  [ -n "$(item queued ga)" ] && [ -n "$(item queued gb)" ]
  "$AQ" set gb row=game:gm-7
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "drain the queue under its cap"
  assert_success
  [ -z "$(item queued ga)" ] && [ -z "$(item queued gb)" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-gb.md)" end_reason)" = returned ]
  assert_called "ptask game --agent unstart gm-7"
}

@test "a session drops the human's work only on an ask the human answered that names the whole chain, and closes nothing otherwise" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  "$AQ" add --project game --from shepherd --slug ga "a"
  legacy gb "after: ga" --project game "b"
  "$AQ" set gb row=game:gm-8
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "out of focus" --drop
  assert_failure; assert_output --partial "gb is work the human asked for"
  [ -n "$(item queued ga)" ] && [ -n "$(item queued gb)" ]
  ask h1 answered a human "ga only"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "out of focus" --ask h1 --drop
  assert_failure; assert_output --partial "does not name gb"
  [ -n "$(item queued ga)" ]
  ask h2 answered a human "ga gb"
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" return ga --why "out of focus" --ask h2 --drop
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-gb.md)" cancel_why)" = "out of focus (ask h2)" ]
  assert_called "ptask game --agent drop gm-8"
}

@test "return follows only the items that wait on it, and an item that waits on two returns with either" {
  "$AQ" add --project game --slug qa "a"
  "$AQ" add --project game --slug qx "x"
  legacy qb "after: qa qx" --project game "b"
  "$AQ" return qa --why "back to the board"
  [ -n "$(item queued qx)" ]
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-qb.md)" end_reason)" = returned ]
  run "$AQ" return nope --why "x"
  assert_failure; assert_output --partial "nothing active with slug nope"
}

# ar-2922: an add --plan that stopped part way (a lock it timed out on) left the first items of a chain.
chain_plan() {  # <name>: a four-phase plan, each phase after the one before
  printf '# %s\n\n## Phases\n\n- [ ] 1. one\n- [ ] 2. two\n- [ ] 3. three\n- [ ] 4. four\n' "$1" > "$SANDBOX/$1.md"
}

@test "add --plan resumes a chain an earlier add left part way, and still refuses a chain already whole" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  printf '# pp\n\n## Phases\n\n- [ ] 1. one\n- [ ] 2. two (independent)\n' > "$SANDBOX/pp.md"
  AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/pp.md" --project level --from shepherd --priority low >/dev/null
  # negative control: the whole chain is queued, so a second add refuses and writes nothing
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/pp.md" --project level --from shepherd --priority low
  assert_failure; assert_output --partial "the phases of $SANDBOX/pp.md are already queued"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 2 ]
  # The plan grew to a chain of four, and an add from before the queue held no gated work left its
  # first two items queued, pp-p2 after pp-p1 (it stopped on a lock it timed out on, ar-2922).
  chain_plan pp
  sed -i '/^from: /i after: pp-p1' "$(item queued pp-p2)"
  # a kept item queued with other phases than the plan gives it now is refused, nothing added
  "$AQ" set pp-p2 phases=3 >/dev/null
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/pp.md" --project level --from shepherd --priority low
  assert_failure; assert_output --partial "pp-p2 is queued with other phases than"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 2 ]
  "$AQ" set pp-p2 phases=2 >/dev/null
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/pp.md" --project level --from shepherd --priority low
  assert_success
  assert_output --partial "kept pp-p1, queued by an earlier add of"
  assert_output --partial "kept pp-p2, queued by an earlier add of"
  # The rest wait on the board, each on the row before it.
  assert_line 'held pp-p3 -> level:lv-3 (#after/lv-2)'
  assert_line 'held pp-p4 -> level:lv-4 (#after/lv-3)'
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 2 ]
}

# ar-2922: the add took the lock once per phase and gave up on the first busy one, so one busy queue left P1 only.
@test "add --plan waits on a held lock and queues every phase once it frees; one that never frees exits 75, not 1" {
  printf '# wl\n\n## Phases\n\n- [ ] 1. one\n- [ ] 2. two (independent)\n- [ ] 3. three (independent)\n' > "$SANDBOX/wl.md"
  mkdir -p "$AGENT_QUEUE_DIR"
  # The add's stderr is a fifo opened read-write here, so the first lock miss it reports is the event
  # the lock is freed on: no sleep, and a writer that never reports fails the read's timeout.
  mkfifo "$SANDBOX/err.fifo"
  exec 6<> "$SANDBOX/err.fifo"
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  AGENT_QUEUE_LOCK_WAIT=1 AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/wl.md" --project game --from shepherd --priority low \
    > "$SANDBOX/add.out" 2> "$SANDBOX/err.fifo" 9>&- 6>&- &
  WRITER=$!
  read -t 20 -r -u 6 line
  [[ "$line" == *"locked by another writer"* ]]
  flock -u 9
  wait "$WRITER" || { cat "$SANDBOX/add.out"; timeout 1 cat <&6; false; }
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 3 ]
  # negative control: a lock that never frees writes nothing and exits 75, not 1 (before: 1, "queued 0 of 3")
  printf "# w2\n\n## Phases\n\n- [ ] 1. one\n- [ ] 2. two (independent)\n" > "$SANDBOX/w2.md"
  flock 9
  AGENT_QUEUE_LOCK_WAIT=1 AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/w2.md" --project game --from shepherd --priority low 9>&-
  assert_failure 75
  assert_output --partial "the queue is busy; adding the plan again (1 of 6 tries)"
  assert_output --partial "run the same add again"
  flock -u 9
  exec 9>&- 6>&-
}

@test "set phases= takes plan checklist numbers, as add --plan writes them, and refuses anything else" {
  "$AQ" add --project game --slug ph "Phase 3 of the plan" >/dev/null
  "$AQ" set ph phases=3,4 >/dev/null
  [ "$(field "$(item queued ph)" phases)" = "3 4" ]
  run "$AQ" set ph phases=P3
  assert_failure; assert_output --partial "phases is plan checklist numbers"
  [ "$(field "$(item queued ph)" phases)" = "3 4" ]
}

# 2026-11-12: a cleanup cancelled 220 from: human items, one batch on an ask the judge answered in 20 s,
# the next by looping a dead chain (mkt-17 after mkt-16, then 18, 19, 20).
@test "a session cancels the human's work only on an ask the human answered; the human and other work are not held" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  "$AQ" add --project game --slug mkt-16 "mkt-16" >/dev/null
  for n in 17 18 19 20; do legacy "mkt-$n" "after: mkt-$((n - 1))" --project game "mkt-$n"; done
  "$AQ" add --project game --from board:game:g2-9 --tags requested --slug asked "row the human asked for" >/dev/null
  "$AQ" add --project game --from shepherd --slug chore "chore" >/dev/null
  # The terminal cancel (no session env) is the human's: mkt-16 goes, and its chain is dead.
  "$AQ" cancel mkt-16 >/dev/null
  run bash -c "'$AQ' show mkt-17 --json | jq -r .hold"
  assert_output --partial "a cancel by hand takes --why and --ask <an ask the human answered>"
  # The replay: the dead-chain loop refuses every from: human item and the #requested one.
  for s in mkt-17 mkt-18 mkt-19 mkt-20 asked; do
    CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel "$s" --why "dead chain"
    assert_failure; assert_output --partial "$s is work the human asked for"
    [ -n "$(item queued "$s")" ]
  done
  AGENT_QUEUE_ITEM=sweeper run "$AQ" move mkt-17 done --status cancelled --why "dead chain"
  assert_failure; assert_output --partial "work the human asked for"
  # An ask the human has not answered, or the judge answered, is not their decision.
  ask p1 pending
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask p1
  assert_failure; assert_output --partial "ask p1 is pending"
  ask j1 answered a judge
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask j1
  assert_failure; assert_output --partial "ask j1 is answered by judge, not the human"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask nope
  assert_failure; assert_output --partial "no such ask"
  [ -n "$(item queued mkt-17)" ]
  run "$AQ" cancel mkt-17 --ask "h1=a"
  assert_failure; assert_output --partial "--ask takes an ask id"
  # The human's answer about other work is not about this item.
  ask h0 answered a human
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask h0
  assert_failure; assert_output --partial "ask h0 does not name mkt-17"
  # A conditional move that no longer applies is left alone (exit 3) before the guard reads it.
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move mkt-17 done --status cancelled --why "x" --if running
  [ "$status" -eq 3 ]
  # The human's answer to an ask naming the items lets them go, and the item names the ask.
  ask h1 answered a human
  echo "question: drop mkt-17, mkt-18? both wait on mkt-16, which you cancelled" >> "$AGENT_ASK_DIR/game/h1.md"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel mkt-17 --why "dead chain" --ask h1
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-mkt-17.md)"
  [ "$(field "$f" cancel_why)" = "dead chain (ask h1)" ]
  [ "$(field "$f" cancelled_by)" = sess-9 ]
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move mkt-18 done --status cancelled --why "dead chain" --ask h1
  assert_success
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-mkt-18.md)" cancel_why)" = "dead chain (ask h1)" ]
  # Negative controls: other work cancels from a session with a reason, and --ask is cancel's alone.
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel chore --why "dup" --ask nope
  assert_failure; assert_output --partial "no such ask"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" cancel chore --why "dup"
  assert_success
  run "$AQ" move mkt-19 done --status failed --ask h1
  assert_failure; assert_output --partial "--ask record a cancel"
  # The human at a terminal is never held.
  run "$AQ" cancel asked
  assert_success
}

@test "cancel keeps a backslash in --why as typed, refuses a multi-line one before touching the item, and carries why to a record-only cancel" {
  "$AQ" add --project game --slug b1 "b1"
  run "$AQ" cancel b1 --why $'two\nlines'
  assert_failure; assert_output --partial "one line"
  [ -n "$(item queued b1)" ]
  [ -z "$(field "$(item queued b1)" status)" ]
  "$AQ" cancel b1 --why 'C:\tmp a\nb'
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-b1.md)" cancel_why)" = 'C:\tmp a\nb' ]
}

# 2026-11-10: two probe items deleted by hand sat queued in the record for days, chain_drift 2.
@test "cancel of a slug whose file is gone closes it in the record while the record holds it active" {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
echo "notes $*" >> "$NOTES_FIXTURE/calls.log"
case "$*" in
  # the record replays a written cancel unless NOTES_DROP says the write was lost
  "log --steps --json") if grep -q 'ingest record' "$NOTES_FIXTURE/calls.log" && [ -z "${NOTES_DROP:-}" ]; then
      echo '{"steps":[{"step":"queued","items":[]},{"step":"done","items":["gone","ghost"]}]}'
    else echo '{"steps":[{"step":"queued","items":["ghost"]},{"step":"done","items":["gone"]}]}'; fi ;;
  "log --days 3650 --item ghost --json") echo '{"action":"item-added","from":"game","text":"probe","item":"ghost"}'
    echo '{"action":"item-set","from":"game","text":"probe","item":"ghost"}' ;;
esac
EOF
  chmod +x "$SANDBOX/bin/notes"
  # a write the record never took is no cancel
  NOTES_DROP=1 run "$AQ" cancel ghost
  assert_failure; assert_output --partial "ghost is still active in the record"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" cancel ghost
  assert_success
  assert_output "cancelled ghost in the record: its file was already gone"
  assert_called "notes ingest record --stage queue --action item-cancelled --from game --item ghost --to done -- probe"
  # a session's reason and name reach the event of a cancel with no file, too
  : > "$NOTES_FIXTURE/calls.log"
  NOTES_DROP=1 CLAUDE_CODE_SESSION_ID=sess-7 run "$AQ" cancel ghost --why "file deleted"
  assert_called "--item ghost --to done --by sess-7 --why file deleted -- probe"
  # one the record has closed, or never held, is still nothing active
  for s in gone never; do
    run "$AQ" cancel "$s"
    assert_failure; assert_output --partial "nothing active with slug $s"
  done
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

# 2026-11-14: `stats --since 7d` read done_24h 0 against 274, since 7d sorted after every day dir.
@test "stats and list --since take 7d and 7 as days back, the same as the day, and refuse any other form" {
  "$AQ" add --project game --slug d1 "d"; "$AQ" move d1 done --status ok
  day="$(date -d '3 days ago' +%F)"
  run "$AQ" stats --json --flow --since "$day"
  assert_success
  want="$(jq -c '[.since, .recent.done_24h, .per_day, (.flow // {} | map_values(.done))]' <<<"$output")"
  assert_equal "$(jq -c '.[1]' <<<"$want")" 1
  for form in 3d 3; do
    run "$AQ" stats --json --flow --since "$form"
    assert_success
    assert_equal "$(jq -c '[.since, .recent.done_24h, .per_day, (.flow // {} | map_values(.done))]' <<<"$output")" "$want"
    run bash -c "'$AQ' list --state done --since $form --json | jq -r .slug"
    assert_output d1
  done
  # 20261114 and 99999 are digits date reads as a time of day, which would come back as today.
  for bad in 1w 3dd 2026-13-01 20261114 99999; do
    run "$AQ" stats --json --since "$bad"
    assert_failure
    assert_output --partial "--since is a day (YYYY-MM-DD) or days back (7d or 7), not '$bad'"
    run "$AQ" list --since "$bad"
    assert_failure
  done
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
  "$AQ" add --project app --slug b --from shepherd --tags ui "b"
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
  legacy e "after: c" --project game "e"
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
  [ "$(jq -r '.done_by_tag.ui' <<<"$output")" = 1 ]
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
  legacy f "after: p" --project game "f"
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

# ar-617: the Queue table shows each item's wait, so list carries the same ready stats medians.
@test "list --json carries ready: queued, else its after: item's finish when later, none while that holds it" {
  "$AQ" add --project game --slug p "p"
  legacy f "after: p" --project game "f"
  "$AQ" add --project game --slug plain "plain"
  f="$(item queued f)"; sed -i 's/^queued: .*/queued: 2026-11-03T08:00:00Z/' "$f"
  f="$(item queued plain)"; sed -i 's/^queued: .*/queued: 2026-11-03T09:00:00Z/' "$f"
  run "$AQ" list --json --state all
  assert_success
  assert_equal "$(jq -r 'select(.slug == "plain") | .ready' <<<"$output")" 2026-11-03T09:00:00Z
  # f is held after p: it is not ready yet
  assert_equal "$(jq -r 'select(.slug == "f") | .ready // "none"' <<<"$output")" none
  "$AQ" move p running; "$AQ" move p done --status ok
  "$AQ" set p finished=2026-11-03T12:00:00Z
  run "$AQ" list --json --state all
  assert_equal "$(jq -r 'select(.slug == "f") | .ready' <<<"$output")" 2026-11-03T12:00:00Z
  run "$AQ" show f --json
  assert_equal "$(jq -r .ready <<<"$output")" 2026-11-03T12:00:00Z
  # a predecessor that finished before the item was queued leaves ready at queued
  "$AQ" set p finished=2026-11-03T07:00:00Z
  run "$AQ" list --json --state queued
  assert_equal "$(jq -r 'select(.slug == "f") | .ready' <<<"$output")" 2026-11-03T08:00:00Z
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

# A test that leaves a writer or reader waiting on a held lock: a failed assert must not leave it behind.
teardown() {
  exec 7>&-
  [ -z "${WRITER:-}" ] || kill "$WRITER" 2>/dev/null || true
  [ -z "${READER:-}" ] || kill "$READER" 2>/dev/null || true
}

@test "a slow read works from a snapshot, so a writer goes in while it still derives holds (ar-2427)" {
  # The read stalls in its first rbw call, a hold it derives after reading the files: a fake rbw that
  # says it is in on one fifo and waits for the go on another. Events, not timing.
  mkfifo "$SANDBOX/rbw.in" "$SANDBOX/rbw.go"
  printf '#!/usr/bin/env bash\nif [ "$1" = unlocked ] && [ ! -e "%s/rbw.stalled" ]; then\n  : > "%s/rbw.stalled"; echo in > "%s/rbw.in"; read -r _ < "%s/rbw.go"\nfi\nexit 0\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/rbw-fake"
  chmod +x "$SANDBOX/rbw-fake"
  export AGENT_QUEUE_RBW="$SANDBOX/rbw-fake"
  legacy held "tags: rbw:trading/key" --project game "deploy the key" >/dev/null
  "$AQ" list --json > "$SANDBOX/read.out" 3>&- &
  READER=$!
  # Opened read-write, a fifo never blocks the open: the read's timeout and the go are the only waits,
  # so a reader that never stalls, or a fake already killed, fails the test instead of hanging it.
  read -t 10 -r _ <> "$SANDBOX/rbw.in"
  # The reader is mid-derive. A writer must not wait on it (timeout: the guard, under the 10s give-up).
  run timeout 5 "$AQ" add --project game --slug later "added while the read runs"
  assert_success
  echo go 1<> "$SANDBOX/rbw.go"
  wait "$READER"
  # The read answers from what it read before the write, hold included.
  [ "$(jq -sr 'map(.slug) | join(",")' "$SANDBOX/read.out")" = held ]
  [ "$(jq -r .hold "$SANDBOX/read.out")" = "rbw:trading/key (not in rbw yet)" ]
  run "$AQ" list --json
  [ "$(jq -sr 'map(.slug) | sort | join(",")' <<<"$output")" = held,later ]
}

@test "a waiting writer holds the gate, so overlapping reads cannot starve it" {
  "$AQ" add --project game "one item" >/dev/null
  # A read already in holds .lock shared; a writer arrives and waits on it.
  exec 7> "$AGENT_QUEUE_DIR/.lock"
  flock -s 7
  "$AQ" add --project game "two item" >/dev/null 2>&1 &
  WRITER=$!   # teardown frees it if an assert fails first
  # No event says another process took a flock, so sample it: one bounded loop, 50ms cadence.
  local i
  for i in $(seq 100); do flock -n "$AGENT_QUEUE_DIR/.gate" true || break; sleep 0.05; done
  run flock -n "$AGENT_QUEUE_DIR/.gate" true
  assert_failure
  # A new read queues behind the waiting writer instead of joining the shared hold.
  run timeout 1 "$AQ" list --json
  [ "$status" -eq 124 ]
  flock -u 7; exec 7>&-
  wait "$WRITER" || { cat "$SANDBOX/add.out"; timeout 1 cat <&6; false; }
  run "$AQ" list --json
  assert_success
  [ "$(jq -sr 'map(.slug) | sort | join(",")' <<<"$output")" = one-item,two-item ]
  # Once in, a taker drops the gate: nothing holds it after the writer is done.
  run flock -n "$AGENT_QUEUE_DIR/.gate" true
  assert_success
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
  # outside every tracker path, a directory named after the app is the app's
  run "$AQ" credit-of game <<<$'store/arena/listing.json\nstore/arena/art.png\nAssets/Level/L.cs\ndocs/x/arena.md'
  assert_output $'arena\tarena level'
  [ ! -e "$AGENT_QUEUE_DIR" ]
}

@test "a 1b sub-phase takes no place: items keep their phase numbers, and a 1b is read by its label" {
  plan_fixture
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game --dry-run
  assert_line --regexp '^would queue my-plan-p6	phases 6	after my-plan-p4$'
  # Someone adds a 1b under the landed phase 1 after the items were queued, and phase 5 lands. By
  # position 5 would now be "4. Fourth" and 6 would be "5. Fifth", ticked: p6 would close, never worked.
  sed -i 's/^- \[x\] 1\. Landed thing: details/&\n- [x] 1b. Follow-up of phase 1 (#7)/; s/^- \[ \] 5\. Fifth/- [x] 5. Fifth/' "$SANDBOX/my-plan.md"
  # NEGATIVE CONTROL: by position this list would be [1,2,3,4,5,6,7] and p6 would read ticked.
  source "$BATS_TEST_DIRNAME/../../.local/lib/plan-phases.sh"
  [ "$(plan_phase_list "$SANDBOX/my-plan.md" | jq -c 'map(.n)')" = '[1,"1b",2,3,4,5,6]' ]
  # An open 1b is no queue item (no integer for `phases:`): it is named on stderr and skipped, and
  # phase 2 keeps its number and its place in the chain.
  printf '## Phases\n\n- [x] 1. One (#1)\n- [ ] 1b. Follow-up\n- [ ] 2. Two\n' > "$SANDBOX/sub.md"
  run "$AQ" add --plan "$SANDBOX/sub.md" --project game --slug sub --dry-run
  assert_success
  assert_output --partial "skipped open sub-phase(s) 1b"
  assert_line --regexp '^would queue sub-p2	phases 2	after -$'
  refute_output --partial "sub-p1b"
  # A stub's phase N is the line numbered N, not the Nth line.
  printf 'Phase 2 of %s/my-plan.md\n' "$SANDBOX" > "$SANDBOX/stub.md"
  [ "$(plan_session_phases "$SANDBOX/stub.md" | jq -c 'map(.name)')" = '["2. Second thing: details"]' ]
  # Names that only look like a label are phases with a place: `P2P sync`, `3D models`, `2D. Layout`.
  printf '## Phases\n\n- [ ] P2P sync\n- [ ] 3D models\n- [ ] 2D. Layout\n' > "$SANDBOX/look.md"
  [ "$(plan_phase_list "$SANDBOX/look.md" | jq -c 'map(.n)')" = '[1,2,3]' ]
}

# story_notes -- give the level and arena games a lab sheet, and a notes stub for the story write:
# every call lands in calls.log; `ptask ... start <id>` fails once closed.<id> exists (no open row);
# `ptask ... add` prints its row with id lv-9 (lv-<n> counting up from story.seq when that file holds <n>) and exits 0, or, with
# story.rc set, prints story.out on stderr and exits story.rc (3 is ptask's "already open").
# `ptask ... propose` prints propose.out, else its words unchanged; propose.rc makes it refuse.
# `ptask ... done` fails once done.rc exists (no open row), `ptask ... run` once run.rc does; `ptask ... list` prints list.out, or fails with list.rc.
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
  id=9; if [ -s "$NOTES_FIXTURE/story.seq" ]; then id=$(cat "$NOTES_FIXTURE/story.seq"); echo $((id + 1)) > "$NOTES_FIXTURE/story.seq"; fi
  if [ "$rc" = 0 ]; then printf -- '- [ ] %s #c1105 <!-- id:lv-%s -->\n' "${@: -1}" "$id"; else cat "$NOTES_FIXTURE/story.out" >&2; fi
  exit "$rc" ;;
*' start '*) [ ! -e "$NOTES_FIXTURE/closed.${@: -1}" ] && [ ! -e "$NOTES_FIXTURE/closed.$4.${@: -1}" ] ||
  { echo "no open task matches" >&2; exit 1; } ;;
*' done '*) [ ! -e "$NOTES_FIXTURE/done.rc" ] || { echo "no open task matches" >&2; exit 1; } ;;
*' run '*) [ ! -e "$NOTES_FIXTURE/run.rc" ] || { echo "no open task matches" >&2; exit 1; } ;;
*' list '*) [ ! -e "$NOTES_FIXTURE/list.rc" ] || exit 1; cat "$NOTES_FIXTURE/list.out" 2>/dev/null ;;
*' board '*) cat "$NOTES_FIXTURE/board.json" 2>/dev/null; exit 0 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/notes"
}

# queue-held-to-board (ar-3121): no writer leaves a queued item with a pending hold; each gate goes on
# the item's board row instead. no_held fails on any queued item list --json reads a hold for.
no_held() {
  local held
  held="$("$AQ" list --state queued --json | jq -r 'select((.hold // "") != "") | "\(.slug): \(.hold)"')"
  [ -z "$held" ] || fail "queued items that hold: $held"
}

@test "no writer leaves a queued item with a pending hold: a gated add, --plan, a set of tags= or after= and a move back to queued all wait on the row" {
  story_notes; gate_rbw
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  echo 1 > "$NOTES_FIXTURE/story.seq"
  # A session's add on a missing rbw item files its row with the gate and queues nothing.
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=s-1 run "$AQ" add --project level --priority low --tags rbw:infra/missing --slug key "chore(deploy): the key"
  assert_failure 5
  assert_output --partial "held key -> level:lv-1 (#rbw/infra/missing)"
  assert_called "#rbw/infra/missing"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-key.md 2>/dev/null)" ] || fail "a gated add wrote an item"
  no_held
  "$AQ" add --project level --slug base "feat(menu): base" >/dev/null
  run "$AQ" add --project level --after base --slug next "feat(menu): next"
  assert_failure 5
  no_held
  printf '# P\n\n## Phases\n\n- [ ] one\n- [ ] two\n- [ ] three\n' > "$SANDBOX/inv.md"
  run "$AQ" add --plan "$SANDBOX/inv.md" --project level
  assert_success
  no_held
  # Its tails wait on their rows, so the same add again refuses rather than file them twice. Negative
  # control: a row naming the plan with no gate (an un-started return) holds no phase, so the add files them.
  printf '{"rows":[{"project":"level","id":"lv-9","state":"open","tags":["after/lv-8"],"details":["Phase 3 of the plan %s: three."]}],"done":[]}\n' "$SANDBOX/inv.md" > "$NOTES_FIXTURE/board.json"
  run "$AQ" add --plan "$SANDBOX/inv.md" --project level
  assert_failure; assert_output --partial "already wait on the board: rows lv-9"
  sed -i 's/"after\/lv-8"/"size\/s"/' "$NOTES_FIXTURE/board.json"
  run "$AQ" add --plan "$SANDBOX/inv.md" --project level
  assert_success; assert_output --partial "held inv-p3 -> "
  rm "$NOTES_FIXTURE/board.json"
  # A set that gives a queued item a gate returns it to its row; one with no row is refused unwritten.
  "$AQ" add --project level --slug other "feat(menu): other" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" set other "tags=rbw:infra/missing"
  assert_success
  assert_called "--add rbw/infra/missing"
  [ -z "$(item queued other 2>/dev/null)" ]
  no_held
  "$AQ" add --project level --slug last "feat(menu): last" >/dev/null
  run "$AQ" set last after=base
  assert_success
  [ -z "$(item queued last 2>/dev/null)" ]
  no_held
  "$AQ" add --project game --slug bare "bare" >/dev/null
  run "$AQ" set bare "tags=rbw:infra/missing"
  assert_failure; assert_output --partial "bare has no board row to wait on its gate"
  [ -z "$(field "$(item queued bare)" tags)" ]
  no_held
  # A move back to queued (reap's requeue of a gone session) of an item that now waits sends it to its
  # row with the gate; one with no row is refused and stays where it was.
  "$AQ" add --project level --slug mv "feat(menu): moved" >/dev/null
  "$AQ" move mv running >/dev/null
  "$AQ" set mv "tags=rbw:infra/missing" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move mv queued --if running
  assert_success
  assert_called "--add rbw/infra/missing"
  [ -z "$(item queued mv 2>/dev/null)" ] && [ -z "$(item running mv 2>/dev/null)" ]
  no_held
  "$AQ" move bare running >/dev/null
  "$AQ" set bare "tags=rbw:infra/missing" >/dev/null
  run "$AQ" move bare queued
  assert_failure; assert_output --partial "give it a board row"
  [ -n "$(item running bare)" ]
  no_held
  # Negative control: a legacy item written past the writers is what no_held catches.
  legacy old "tags: rbw:infra/missing" --project game "old"
  run no_held
  assert_failure; assert_output --partial "old: "
}

@test "a canary item files no story row, and --from takes only the known origins, research:<facet> among them" {
  story_notes
  run "$AQ" add --project level --from canary --tags canary --slug c1 "check(canary): greet 2026w45"
  assert_success
  refute_output --partial 'story'
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  [ "$(field "$(item queued c1)" from)" = canary ]
  run "$AQ" add --project game --from research:dotfiles-hooks --slug r1 "research(dotfiles-hooks): look"
  assert_success
  [ "$(field "$(item queued r1)" from)" = research:dotfiles-hooks ]
  run "$AQ" add --project game --from robot --slug c2 "x"
  assert_failure
  assert_output --partial 'human, shepherd, canary, trainee, research:<facet>, auto:<filer> or board'
  run "$AQ" add --project game --from research: --slug c3 "x"
  assert_failure
}

@test "add files a started story row under the item's epic and links it as row:" {
  story_notes
  run "$AQ" add --project game --epic lv-3 --priority low --slug menus "feat(menu): live main menus #night"
  assert_success
  assert_line "story lv-9 on the level agent board, under lv-3"
  run grep '^notes --profile' "$NOTES_FIXTURE/calls.log"
  assert_line --index 0 'notes --profile bnb ptask level --agent propose -- feat(menu): live main menus'
  assert_line --index 1 'notes --profile bnb ptask level --agent add --origin agent-queue -- feat(menu): live main menus #low #of/lv-3'
  assert_line --index 2 'notes --profile bnb ptask level --agent start lv-9'
  f="$(item queued menus)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" row)" = level:lv-9 ]
  [ "$(field "$f" lane)" = agent ]
  [ "$(field "$f" profile)" = bnb ]
  [ "$(jq -r .row <<<"$("$AQ" show menus --json)")" = level:lv-9 ]
}

@test "list joins the item's board row: its points and size band, in --json and as an m/5 column" {
  story_notes
  "$AQ" add --project game --epic lv-3 --slug menus "feat(menu): live main menus" >/dev/null
  "$AQ" add --project game --slug bare --from human "chore(x): no row of its own" >/dev/null
  # The row the item works scores 5 points, band m; the other item's row is unscored.
  echo '{"rows":[{"project":"level","id":"lv-9","points":5,"size":"m"}],"done":[]}' > "$NOTES_FIXTURE/board.json"
  run "$AQ" list --json --points
  assert_success
  [ "$(jq -r 'select(.slug == "menus") | "\(.size)/\(.points)"' <<<"$output")" = m/5 ]
  run "$AQ" list
  assert_line --regexp '^queued	.*	menus	.*	m/5$'
  # NEGATIVE CONTROLS: --json without --points never reads the board; with no board feed the list is still the queue.
  run "$AQ" list --json
  assert_success
  [ "$(jq -r 'select(.slug == "menus") | .points // "none"' <<<"$output")" = none ]
  rm "$NOTES_FIXTURE/board.json"
  run "$AQ" list --json --points
  assert_success
  [ "$(jq -r 'select(.slug == "menus") | .points // "none"' <<<"$output")" = none ]
  run "$AQ" list
  assert_line --regexp '^queued	.*	menus	.*	-$'
}

@test "add files the story row with no #size/: the nightly --backlog --size pass scores it" {
  story_notes
  run "$AQ" add --project game --epic lv-3 --slug light --weight light "feat(menu): a light one"
  assert_success
  run "$AQ" add --project game --epic lv-3 --slug heavy --weight heavy "feat(menu): a heavy one"
  assert_success
  run grep -c '#size/' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

# The row's section follows the item (Now while it runs, Next up once requeued), so every move to
# running marks the row and a move back to queued unmarks it; waiting keeps the mark, and an item
# with no row writes nothing (the negative control).
@test "a move to running marks the item's row run, back to queued starts it again, waiting leaves it" {
  story_notes
  "$AQ" add --project game --epic lv-3 --slug menus "feat(menu): live main menus" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" move menus running >/dev/null
  "$AQ" move menus waiting >/dev/null
  "$AQ" move menus queued >/dev/null
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent run lv-9
notes --profile bnb ptask level --agent start lv-9'
  # Added already running, its story row is marked as soon as it is filed.
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project game --epic lv-3 --running --slug live "feat(menu): live now" >/dev/null
  run grep -c ' ptask level --agent run lv-9$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # A row the write cannot reach warns, and the move stands.
  touch "$NOTES_FIXTURE/run.rc"
  "$AQ" move live queued >/dev/null
  run "$AQ" move live running
  assert_success
  assert_output --partial 'not marked run'
  [ -n "$(item running live)" ]
  # No row, no write.
  "$AQ" add --project game --from canary --slug norow "check(canary): x" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" move norow running >/dev/null
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

# tr-71 and tr-129: added by hand with --from board:, their rows were never marked, so the merge left
# them open (merged_open_rows).
@test "an item promoted from a board row (from: board:, no row:) marks that row run like a row: item" {
  story_notes
  "$AQ" add --project game --from board:level:lv-4 --slug promoted "fix(menu): promoted" >/dev/null
  [ -z "$(field "$(item queued promoted)" row)" ] || fail "the fixture needs an item with no row: line"
  "$AQ" set promoted profile=bnb lane=agent >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" move promoted running >/dev/null
  "$AQ" move promoted queued >/dev/null
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent run lv-4
notes --profile bnb ptask level --agent start lv-4'
}

# ar-1597: an item re-pointed with set row= left its first row started with no item, which read as
# board_orphan_started until the orphan pass.
@test "set row= or from=board: un-starts the row the item leaves and marks the one it works now" {
  story_notes
  "$AQ" add --project game --epic lv-3 --slug repoint "feat(menu): repoint" >/dev/null
  [ "$(field "$(item queued repoint)" row)" = level:lv-9 ]
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" set repoint row=level:lv-2
  assert_success; assert_output --partial "board row lv-9 on level un-started"
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent unstart lv-9
notes --profile bnb ptask level --agent start lv-2'
  # The same row again writes nothing.
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set repoint row=level:lv-2 >/dev/null
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # The left row is un-started on the profile and lane it was on, even when the set moves both.
  "$AQ" move repoint running >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set repoint row=level:lv-8 profile=work lane=human >/dev/null
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent unstart lv-2
notes --profile work ptask level run lv-8'
  # A failed un-start warns with the command; the set stands and succeeds.
  printf '#!/usr/bin/env bash\n[[ " $* " != *" unstart "* ]]\n' > "$SANDBOX/bin/notes"
  run "$AQ" set repoint row=level:lv-1
  assert_success; assert_output --partial "left board row lv-8 on level, not un-started"
  [ "$(field "$(item running repoint)" row)" = level:lv-1 ]
  story_notes
  # A board-promoted item re-pointed by from= leaves its row the same way.
  "$AQ" add --project game --from board:level:lv-4 --slug promoted "fix(menu): promoted" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set promoted from=board:level:lv-6 >/dev/null
  run grep -c 'ptask level --agent unstart lv-4$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # A row another active item works stays started.
  "$AQ" add --project game --from board:level:lv-5 --slug holder "fix(menu): holder" >/dev/null
  "$AQ" set promoted from=board:level:lv-5 >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set promoted from=board:level:lv-7 >/dev/null
  run grep -c ' unstart ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A done item's rows are its close's business.
  "$AQ" move promoted done --status failed >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" set promoted from=board:level:lv-3 >/dev/null
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "an item closed ok with no PR closes its row on the item; one with a PR leaves it to agent-land" {
  story_notes
  "$AQ" add --project game --epic lv-3 --slug menus "feat(menu): live main menus" >/dev/null
  "$AQ" move menus running >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move menus done --status ok
  assert_success
  assert_line 'menus: board row lv-9 closed'
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask level --agent done lv-9 --proof item:menus'
  # a board-promoted item, no profile: notes finds the project's own
  "$AQ" add --project game --from board:game:gm-7 --running --slug promoted "fix(x): y" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move promoted done --status ok
  assert_line 'promoted: board row gm-7 closed'
  run grep ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes ptask game --agent done gm-7 --proof item:promoted'
  # NEGATIVE CONTROL: a merged PR's row is agent-land's, closed on the merge
  "$AQ" add --project game --epic lv-3 --running --slug landed "feat(menu): b" >/dev/null
  "$AQ" set landed pr=o/r#4 merged=abc123 >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move landed done --status ok
  assert_success
  refute_output --partial 'board row'
  run grep -c ' ptask .* done ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # and failed or cancelled leaves it to fleet-dispatch settle_row
  "$AQ" add --project game --epic lv-3 --running --slug lost "feat(menu): c" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" move lost done --status failed
  run grep -c ' ptask .* done ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "a row already closed stays quiet on an ok close; one the close missed, or a board that cannot be read, is named on stderr" {
  story_notes
  touch "$NOTES_FIXTURE/done.rc"
  # lv-90 is another row: the open rows are read by id, not by substring
  printf -- '- [/] docs(menu): z <!-- id:lv-90 -->\n' > "$NOTES_FIXTURE/list.out"
  "$AQ" add --project game --epic lv-3 --running --slug doc "docs(menu): a" >/dev/null
  run "$AQ" move doc done --status ok
  assert_success
  refute_output --partial 'board row'
  "$AQ" add --project game --epic lv-3 --running --slug stuck "docs(menu): b" >/dev/null
  printf -- '- [/] docs(menu): b <!-- id:lv-9 -->\n' > "$NOTES_FIXTURE/list.out"
  run "$AQ" move stuck done --status ok
  assert_success
  assert_output --partial 'agent-queue: stuck is done, but its board row lv-9 on level may still be open (no open task matches): notes --profile bnb ptask level --agent done lv-9 --proof item:stuck'
  touch "$NOTES_FIXTURE/list.rc"
  "$AQ" add --project game --epic lv-3 --running --slug blind "docs(menu): c" >/dev/null
  run "$AQ" move blind done --status ok
  assert_success
  assert_output --partial 'agent-queue: blind is done, but its board row lv-9 on level may still be open'
}

@test "a want's channel reaches the story row's writer only when --want names it" {
  story_notes
  run "$AQ" add --project game --epic lv-3 --slug voiced --want voice "feat(menu): a"
  assert_success
  run "$AQ" add --project game --epic lv-3 --slug own --from human "feat(menu): c"
  assert_success
  run grep 'ptask level --agent add' "$NOTES_FIXTURE/calls.log"
  assert_line --index 0 --partial 'add --want voice -- feat(menu): a #high #of/lv-3'
  assert_line --index 1 'notes --profile bnb ptask level --agent add --origin agent-queue -- feat(menu): c #high #of/lv-3'
}

@test "--want is refused with --plan: plan items are agent-made and carry no channel" {
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/w.md"
  run "$AQ" add --plan "$SANDBOX/w.md" --project game --slug wp --want voice
  assert_failure
  assert_output --partial '--want names a human'
}

@test "a plan item's story takes the plan's epic and a heavy item is sized m" {
  story_notes
  printf '%s\n' 'epic: lv-3' '## Phases' '- [ ] P1 one' > "$SANDBOX/lv.md"
  echo 'feat(level): lv P1: one' > "$NOTES_FIXTURE/propose.out"
  run "$AQ" add --plan "$SANDBOX/lv.md" --project game --weight heavy --slug lvp
  assert_success
  run grep -c -- '--agent propose -- lv P1: one$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -c -- "--agent add --detail=Phase 1 of the plan $SANDBOX/lv.md: one\. .* -- feat(level): lv P1: one #high #of/lv-3$" "$NOTES_FIXTURE/calls.log"
  assert_output 1
  [ "$(field "$(item queued lvp-p1)" row)" = level:lv-9 ]
}

@test "an epic of another project is not linked, and a long title becomes the row's detail" {
  story_notes
  long="fix(menu): $(printf 'word%.0s ' {1..20})end"
  echo 'fix(menu): word word' > "$NOTES_FIXTURE/propose.out"
  "$AQ" add --project level --epic el-3 --slug far-epic -- "$long"
  run grep -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "--agent add --detail=$long --origin agent-queue -- fix(menu): word"
  refute_output --partial '#of/'
  [ "${#long}" -gt 80 ]
}

@test "the story row holds the item's whole body as its brief, less a first line that is the row's own words" {
  story_notes
  "$AQ" add --project level --slug multi -- $'feat(menu): the title screen\ngoal: one record\n  - nested'
  run cat "$NOTES_FIXTURE/calls.log"
  assert_output --partial $'--agent add --detail=goal: one record\n  - nested --origin agent-queue -- feat(menu): the title screen #high'
  # a --title that is not the body's first line keeps the body whole
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project level --slug titled --title "feat(menu): a short title" -- $'Phase 2 of the plan: do it\nthen land it'
  run cat "$NOTES_FIXTURE/calls.log"
  assert_output --partial $'--agent add --detail=Phase 2 of the plan: do it\nthen land it --origin agent-queue -- feat(menu): a short title #high'
  # NEGATIVE CONTROL: a one-line task that is the row's words writes no brief
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project level --slug one "feat(menu): one line"
  run grep -c -- '--detail' "$NOTES_FIXTURE/calls.log"
  assert_output 0
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

@test "a re-queue links its last item's open row by id, whatever its words; a closed one gets a new row" {
  story_notes
  "$AQ" add --project level --slug again "feat(menu): first words" >/dev/null
  "$AQ" move again done --status failed >/dev/null
  # The row was written before rows were typed: no text the new add proposes would match it.
  echo 'feat(menu): other words entirely' > "$NOTES_FIXTURE/propose.out"
  run "$AQ" add --project level --slug again "feat(menu): first words"
  assert_success
  assert_line "story lv-9 on the level agent board"
  [ "$(field "$(item queued again)" row)" = level:lv-9 ]
  [ "$(field "$(item queued again)" profile)" = bnb ]
  run grep -c -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -c -- '--agent start lv-9$' "$NOTES_FIXTURE/calls.log"
  assert_output 2
  # negative control: a repeat after an ok close finds its row done, so it files a new one
  "$AQ" move again done --status ok >/dev/null
  touch "$NOTES_FIXTURE/closed.lv-9"
  run "$AQ" add --project level --slug again --repeat "feat(menu): first words"
  assert_success
  run grep -c -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output 2
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
  # an item whose row: line is empty has no row to a reader, not the row "" (ar-1551)
  sed -i 's/^agent: /row: \nagent: /' "$(item queued no-sheet)"
  [ "$(grep -c '^row: $' "$(item queued no-sheet)")" = 1 ]
  run jq -sc '[.[] | select(.slug == "no-sheet") | has("row")]' <<<"$("$AQ" list --json --state all)"
  assert_output '[false]'
}

@test "--row links an open board row and starts it: no second row, and from: stays the origin" {
  story_notes
  run "$AQ" add --running --project game --row lv-2 --slug by-hand "feat(menu): the row's work"
  assert_success
  assert_line "story lv-2 on the level agent board"
  f="$(item running by-hand)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" row)" = level:lv-2 ]
  [ "$(field "$f" lane)" = agent ]
  [ "$(field "$f" profile)" = bnb ]
  [ "$(field "$f" from)" = human ]
  run grep '^notes --profile' "$NOTES_FIXTURE/calls.log"
  assert_output "$(printf '%s\n' 'notes --profile bnb ptask level --agent start lv-2' 'notes --profile bnb ptask level --agent run lv-2')"
}

@test "--row refuses an id that is not an open row, a row a live item names and a project with no board, writing nothing" {
  story_notes
  touch "$NOTES_FIXTURE/closed.lv-7"
  run "$AQ" add --project game --row lv-7 --slug shut "x"
  assert_failure; assert_output --partial "--row lv-7: not an open row on the level agent board: no open task matches"
  [ -z "$(item queued shut)" ]
  "$AQ" add --project game --row lv-2 --slug first "x"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project game --row lv-2 --slug second "y"
  assert_failure; assert_output --partial "--row lv-2: first already works that row; to take it over: agent-queue claim first"
  [ -z "$(item queued second)" ]
  run grep -c ' start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  run "$AQ" add --project elsewhere --row el-1 --slug no-board "z"
  assert_failure; assert_output --partial "--row el-1: elsewhere has no agent board"
  [ -z "$(item queued no-board)" ]
}

@test "--row links a row moved to the caller's game, which its code no longer names; open on neither is refused" {
  story_notes
  # ar-9 was moved from arena to level: it keeps its id, so the code sheet (arena) no longer has it.
  touch "$NOTES_FIXTURE/closed.arena.ar-9"
  run "$AQ" add --project level --row ar-9 --slug moved "x"
  assert_success
  assert_line "story ar-9 on the level agent board"
  f="$(item queued moved)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" row)" = level:ar-9 ]
  # Negative control: a row still on its code's sheet links there, whichever game the caller named.
  run "$AQ" add --project level --row ar-8 --slug by-code "y"
  assert_success
  [ "$(field "$(item queued by-code)" row)" = arena:ar-8 ]
  touch "$NOTES_FIXTURE/closed.arena.ar-7" "$NOTES_FIXTURE/closed.level.ar-7"
  run "$AQ" add --project level --row ar-7 --slug nowhere "z"
  assert_failure; assert_output --partial "--row ar-7: not an open row on the arena agent board"
  [ -z "$(item queued nowhere)" ]
}

@test "a title whose subject is one open row works that row; a mention, a closed row, two ids or an --epic file a story as before" {
  story_notes
  run "$AQ" add --running --project game --slug named "fix(menu): close it for good (lv-2)"
  assert_success
  assert_output --partial "named works row lv-2, which its title names"
  [ "$(field "$(item running named)" row)" = level:lv-2 ]
  run grep -c ' add ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # NEGATIVE CONTROLS: each of these files its own story (the stub mints lv-9).
  touch "$NOTES_FIXTURE/closed.lv-7"
  "$AQ" add --project level --slug said "fix(menu): redo the layout after lv-3 lands"
  [ "$(field "$(item queued said)" row)" = level:lv-9 ]
  "$AQ" add --project level --slug shut "lv-7: fix the menu again"
  [ "$(field "$(item queued shut)" row)" = level:lv-9 ]
  "$AQ" add --project level --slug two "lv-3: fix(menu) beside (lv-4)"
  [ "$(field "$(item queued two)" row)" = level:lv-9 ]
  "$AQ" add --project level --epic lv-5 --slug epic "feat(menu): under its epic (lv-3)"
  [ "$(field "$(item queued epic)" row)" = level:lv-9 ]
  run grep -c ' start lv-3' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "--row takes one row id, on one item, with no story options" {
  story_notes
  : > "$NOTES_FIXTURE/calls.log"
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/p.md"
  run "$AQ" add --plan "$SANDBOX/p.md" --project game --row lv-2
  assert_failure; assert_output --partial "--row links one item"
  run "$AQ" add --project game --row menus --slug a "x"
  assert_failure; assert_output --partial "--row is a row id"
  run "$AQ" add --project game --row lv-2 --epic lv-3 --slug b "x"
  assert_failure; assert_output --partial "--row links a row already filed"
  run "$AQ" add --project game --row lv-2 --from board:level:lv-2 --slug c "x"
  assert_failure; assert_output --partial "not --from board:level:lv-2"
  run grep -c ' start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
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

# A repo with no sheet of its own names the board it files on (dotfiles-private -> agent-runtime): the
# item stays on its own project and checkout, and its row lives on that board. NEGATIVE CONTROL: before
# the board key, app filed nothing and --row on it was refused.
@test "a project with no sheet files its story and links --row on the board its board key names" {
  story_notes
  jq '.trackers.app.board = "level"' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m.json" && mv "$SANDBOX/m.json" "$AGENT_QUEUE_PROJECT_MAP"
  run "$AQ" add --project app --slug overlay "fix(hooks): the overlay's work"
  assert_success
  assert_line "story lv-9 on the level agent board"
  f="$(item queued overlay)"
  [ "$(field "$f" project)" = app ]
  [ "$(field "$f" row)" = level:lv-9 ]
  [ "$(field "$f" profile)" = bnb ]
  run grep '^notes --profile' "$NOTES_FIXTURE/calls.log"
  assert_line --index 1 "notes --profile bnb ptask level --agent add --origin agent-queue -- fix(hooks): the overlay's work #high"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --running --project app --row lv-2 --slug linked "x"
  assert_success
  assert_line "story lv-2 on the level agent board"
  [ "$(field "$(item running linked)" row)" = level:lv-2 ]
  [ "$(field "$(item running linked)" project)" = app ]
  run "$AQ" add --project app --row lv-2 --slug twice "y"
  assert_failure; assert_output --partial "--row lv-2: linked already works that row"
  "$AQ" move linked done --status ok >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project app --slug linked --repeat "again"
  assert_success
  assert_line "story lv-2 on the level agent board"
  run grep -c ' add ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "every item write appends one queue event naming the item, its row and its PR" {
  story_notes
  "$AQ" add --project game --from board:level:lv-2 --slug chain "x" >/dev/null
  "$AQ" set chain pr=o/r#7 merged=0123abcd >/dev/null
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
  run "$AQ" add --project game --from board:level:lv-2 --slug sturdy "fix(x): y"
  assert_success
  assert_output --partial "notes row parse failed, so sturdy is untyped"
  [ -z "$(field "$(item queued sturdy)" type)" ]
  # Its row (from: board:) is marked too; that write failing warns and the move stands (mark_row).
  run "$AQ" move sturdy running
  assert_success
  assert_line --index 0 "sturdy: queued -> running"
  assert_output --partial "board row lv-2 on level not marked run"
  [ -n "$(item running sturdy)" ]
}

# --- admission: the cap on runnable items (ar-2918) ---------------------------------------

@test "the cap holds an add over it: no item, its board row left un-started with the whole brief, the hold logged" {
  story_notes
  export AGENT_QUEUE_CAP=2
  "$AQ" add --project level --slug one "feat(menu): one" >/dev/null
  "$AQ" add --project level --slug two "feat(menu): two" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --slug three "feat(menu): three
second line of the brief
- [ ] a step"
  assert_failure 5
  assert_output --partial "held by admission, nothing was queued: 2 items can start now against a cap of 2 (human)"
  assert_output --partial "its board row lv-9 on level is left un-started"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-three.md 2>/dev/null)" ] || fail "a held add wrote an item"
  # the brief is one value of several lines, less the row's own words; notes escapes the step
  assert_called "ptask level --agent add --detail=second line of the brief"
  assert_called "- [ ] a step -- feat(menu): three #high"
  run grep -c ' ptask level --agent start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  run jq -c '{from, slug, runnable, limit}' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output '{"from":"human","slug":"three","runnable":2,"limit":2}'
  # A gated add files its row and queues nothing, so it takes no room.
  "$AQ" cancel one >/dev/null
  run "$AQ" add --project level --slug later --after two "feat(menu): later"
  assert_failure 5
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-later.md 2>/dev/null)" ]
  run "$AQ" add --project level --slug three "feat(menu): three"
  assert_success
}


@test "an over-cap add that names --row files no second row, and a short task under a different --title keeps its words" {
  story_notes
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project level --slug one "feat(menu): one" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --row lv-2 --slug named "feat(menu): named"
  assert_failure 5
  assert_output --partial "row lv-2 is left un-started where it is"
  run grep -c ' ptask level --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  run "$AQ" add --project level --slug titled --title "feat(menu): the title" "the real wording of the task"
  assert_failure 5
  assert_called "--detail=the real wording of the task -- "
}

@test "an over-cap add that is #requested files its row with --want, so it ranks first on the board" {
  story_notes
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project level --slug one "feat(menu): one" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --tags '#requested' --slug asked "feat(menu): asked"
  assert_failure 5
  assert_called "ptask level --agent add --want human -- feat(menu): asked #high"
}

@test "a project with no board gets the command to file by hand, nothing written, and a machine filer is held the same" {
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --slug held "held"
  assert_failure 5
  assert_output --partial "game has no board row to file this on: notes ptask game --agent add"
  run "$AQ" add --project game --from research:costs --slug machine-b "machine b"
  assert_failure 5
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-held.md "$AGENT_QUEUE_DIR"/queued/*-machine-b.md 2>/dev/null)" ] || fail "a held add wrote an item"
}

@test "at the cap an urgent or red add returns the last-ranked item that has a row, never the human's, urgent work or a chain head; with none it is held" {
  # The human, 2026-11-18: urgent must not skip the cap; it pushes out something less critical.
  "$AQ" add --project game --from shepherd --slug a "a" >/dev/null
  "$AQ" add --project game --priority low --slug h "the human's" >/dev/null
  "$AQ" add --project game --from shepherd --priority low --tags '#requested' --slug req "asked for" >/dev/null
  "$AQ" add --project game --from shepherd --priority low --slug head "chain head" >/dev/null
  legacy tail "after: head" --project game --from shepherd --priority low "chain tail"
  "$AQ" add --project game --from shepherd --priority low --slug b "b" >/dev/null
  for s in a req head b; do "$AQ" set "$s" row="game:gm-$s" >/dev/null; done
  export AGENT_QUEUE_CAP=6
  : > "$NOTES_FIXTURE/calls.log"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u1 "urgent one"
  assert_success
  assert_output --partial "returned b to its board row to make room for urgent u1 under the cap of 6"
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-b.md)" end_reason)" = returned ]
  assert_called "ptask game --agent unstart gm-b"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority high --tags red --slug r1 "red one"
  assert_success
  assert_output --partial "returned a to its board row"
  # Negative controls: what is left is the human's, #requested, a chain head and urgent or red work.
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u2 "urgent two"
  assert_failure 5
  assert_output --partial "held by admission, nothing was queued: 6 items can start now against a cap of 6"
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "h,head,r1,req,tail,u1"
  run "$AQ" admission --json
  assert_equal "$(jq -c '[.held_7d, .returned_7d]' <<<"$output")" '[1,2]'
  run jq -r 'select(.why == "returned") | .slug' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output "b
a"
}

@test "make_room returns an item held to a clock time, moves nothing for an add the lock refuses, and never returns an item that started" {
  "$AQ" add --project game --priority low --slug h "the human's" >/dev/null
  legacy n "tags: at:23:59" --project game --from shepherd --priority low "tonight"
  "$AQ" set n row=game:gm-n >/dev/null
  export AGENT_QUEUE_CAP=2
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u1 "urgent one"
  assert_success
  assert_output --partial "returned n to its board row"
  AGENT_QUEUE_CAP=0 "$AQ" add --project game --from shepherd --priority low --slug c "c" >/dev/null
  "$AQ" set c row=game:gm-c >/dev/null
  # A retry of a queued urgent add dies on the duplicate and returns nothing first.
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" add --project game --priority urgent --slug u1 "urgent one"
  assert_failure
  assert_output --partial "already in the queue: u1"
  refute_output --partial "returned c"
  "$AQ" move c running >/dev/null
  AQ_RETURN_QUEUED=1 run "$AQ" return c --why "make room"
  assert_failure
  assert_output --partial "c is running now, not queued: not returned"
  run jq -r 'select(.why == "returned") | .slug' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output "n"
}

@test "the cap never holds a --running, hand-started board or auto:epics verify or dispatch's canary top-up add; dispatch's own board pull it holds" {
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --slug human "human"
  assert_failure 5
  # Urgent and red are held too when nothing can be returned: "one" is the human's.
  run "$AQ" add --project game --tags red --slug broken "broken"
  assert_failure 5
  run "$AQ" add --project game --priority urgent --slug urgent "urgent"
  assert_failure 5
  "$AQ" add --project game --running --session s1 --slug mine "mine" >/dev/null
  AGENT_QUEUE_PULL=hand "$AQ" add --project game --from board:game:gm-3 --slug gm-3 "feat(game): started by hand" >/dev/null
  "$AQ" add --project game --from auto:epics --tags verify --slug verify-e-1 "verify e" >/dev/null
  run "$AQ" add --project game --from board:game:gm-4 --slug gm-4 "feat(game): dispatch's fill"
  assert_failure 5
  AGENT_QUEUE_PULL=dispatch "$AQ" add --project game --from canary --tags canary --slug canary "check(canary): x" >/dev/null
  # Negative control: the same add without dispatch's pull is a filer's, and goes to the board.
  run env -u AGENT_QUEUE_PULL "$AQ" add --project game --from canary --tags canary --slug canary-b "check(canary): y"
  assert_failure
  assert_output --partial "only the board fills the queue"
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "canary,gm-3,mine,one,verify-e-1"
  [ "$(wc -l < "$AGENT_QUEUE_DIR/admission.jsonl")" -eq 5 ]
}

@test "the cap passes dispatch's pull of a plan phase filed on its board row, as it passes the --plan; another board pull it holds" {
  story_notes
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two' > "$SANDBOX/pp.md"
  # add_plan queues P1 and files P2 on its board row behind #after/, its brief the real writer's.
  run "$AQ" add --plan "$SANDBOX/pp.md" --project level --priority low --slug pp
  assert_output --partial "held pp-p2 -> level:"
  brief=$(sed -n 's/.*--agent add --detail=\(Phase 2 of the plan .*: two\. .*\) -- pp P2: two .*/\1/p' "$NOTES_FIXTURE/calls.log")
  [[ "$brief" == "Phase 2 of the plan $SANDBOX/pp.md: two. "* ]] || fail "no P2 brief in calls.log: $brief"
  export AGENT_QUEUE_CAP=1 AGENT_QUEUE_PULL=dispatch
  # Negative controls: the brief naming a plan file that is gone, a row that only mentions a plan,
  # and the same brief from no board pull are each held at the cap.
  mv "$SANDBOX/pp.md" "$SANDBOX/pp.gone"
  run "$AQ" add --project level --priority low --from board:level:lv-9 --slug lv-9 "feat(level): pp P2: two" $'\n'"$brief"
  assert_failure 5
  mv "$SANDBOX/pp.gone" "$SANDBOX/pp.md"
  run "$AQ" add --project level --priority low --from board:level:lv-7 --slug lv-7 "feat(level): the plan of the planet, phase 2"
  assert_failure 5
  run env -u AGENT_QUEUE_PULL "$AQ" add --project level --priority low --slug p-human "$brief"
  assert_failure 5
  # Dispatch's pull of that row, as fleet-dispatch pull-after promotes it, goes in past the cap.
  run "$AQ" add --project level --priority low --from board:level:lv-9 --slug lv-9 "feat(level): pp P2: two" $'\n'"$brief"
  assert_success
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "lv-9,pp-p1"
}

@test "only the board fills the queue: an agent's or a filer's add is filed as a board row, the human's and dispatch's go in" {
  story_notes
  unset AGENT_QUEUE_PULL
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --from shepherd --slug nudge "fix(menu): a filer's follow-up"
  assert_failure 5
  assert_output --partial "only the board fills the queue"
  assert_called "ptask level --agent add -- fix(menu): a filer's follow-up #high"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-nudge.md 2>/dev/null)" ] || fail "a filer's add wrote an item"
  run jq -r 'select(.slug == "nudge") | .why' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output board-only
  # The row it filed is on stdout, the one line a filer reads; stderr is prose for the log.
  rc=0; out=$("$AQ" add --project level --from shepherd --slug nudge2 "fix(menu): a second follow-up" 2>/dev/null) || rc=$?
  assert_equal "$rc" 5
  assert_equal "$out" "held nudge2 -> level:lv-9"
  # A board origin without dispatch's pull files no second row: the row it names stays put.
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --from board:level:lv-7 --slug lv-7 "feat(menu): seven"
  assert_failure 5
  assert_output --partial "its row level:lv-7 is left where it is"
  run grep -c ' ptask level --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A dispatch-run agent (its item not opened by the human) is held the same, even on --after.
  AGENT_QUEUE_PULL=dispatch "$AQ" add --project level --slug agent-item "agent item" >/dev/null
  run env AGENT_QUEUE_ITEM=agent-item "$AQ" add --project level --priority low --after agent-item --slug next "fix(menu): next phase"
  assert_failure 5
  # The human: at a terminal, in a session they started (no item, or an item they opened), or --running.
  "$AQ" add --project level --slug by-hand "feat(menu): by hand" >/dev/null
  "$AQ" set agent-item origin=hand >/dev/null
  AGENT_QUEUE_ITEM=agent-item "$AQ" add --project level --priority low --slug from-hand "feat(menu): from a hand session" >/dev/null
  AGENT_QUEUE_ITEM=agent-item "$AQ" add --project level --from shepherd --running --session s9 --slug own "own work" >/dev/null
  AGENT_QUEUE_PULL=dispatch "$AQ" add --project level --from board:level:lv-8 --slug lv-8 "feat(menu): eight" >/dev/null
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "agent-item,by-hand,from-hand,lv-8,own"
  # admission counts them as sent to the board, not as held by the cap
  run "$AQ" admission --json
  assert_equal "$(jq -c '[.held_7d, .boarded_7d]' <<<"$output")" '[0,4]'
  # A project with no board to file on: nothing was written, so the add fails rather than reads as filed.
  run "$AQ" add --project game --from shepherd --slug lost "fix(x): no board"
  assert_failure 1
  assert_output --partial "game has no board row to file this on"
}

@test "a filer's --plan goes to the board as one row that runs its open phases; nothing is queued" {
  story_notes
  unset AGENT_QUEUE_PULL
  printf '# P\n\n## Phases\n\n- [ ] one\n- [ ] two\n' > "$SANDBOX/orphan.md"
  run "$AQ" add --plan "$SANDBOX/orphan.md" --project level --from auto:plans --priority low
  assert_failure 5
  assert_output --partial "only the board fills the queue"
  assert_called "ptask level --agent add --detail=Run the open phases of the approved plan $SANDBOX/orphan.md in order"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*orphan* 2>/dev/null)" ] || fail "a filer's plan queued a phase"
  # The human's approved plan still queues its phases.
  run "$AQ" add --plan "$SANDBOX/orphan.md" --project level --priority low
  assert_success
}

# fleet-dispatch promote turns that row into the chain (ar-3262). NEGATIVE CONTROL: before it, --from
# board: on a --plan was refused as no filer, and promote queued the row as one item for every phase.
@test "dispatch's --plan --from board: queues the chain from auto:plan-row and puts the row on the plan's rows: line" {
  story_notes
  printf '# pp\n\n## Phases\n\n- [ ] P1 one\n- [ ] P2 two\n' > "$SANDBOX/pp.md"
  cp "$SANDBOX/pp.md" "$SANDBOX/pp.orig"
  # Without dispatch's pull the row stays where it is and nothing is written.
  run env -u AGENT_QUEUE_PULL "$AQ" add --plan "$SANDBOX/pp.md" --project level --priority low --from board:level:lv-5
  assert_failure 5
  assert_output --partial "its row lv-5 is left where it is"
  cmp "$SANDBOX/pp.md" "$SANDBOX/pp.orig" || fail "a held add wrote the plan"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/ 2>/dev/null)" ] || fail "a held add queued a phase"
  # A plan file that is gone is refused by name.
  run env AGENT_QUEUE_PULL=dispatch "$AQ" add --plan "$SANDBOX/gone.md" --project level --from board:level:lv-5
  assert_failure
  assert_output --partial "no such file"
  run env AGENT_QUEUE_PULL=dispatch "$AQ" add --plan "$SANDBOX/pp.md" --project level --priority low --from board:level:lv-5 --slug pp
  assert_success
  assert_output --partial "held pp-p2 -> level:lv-9 (#after/lv-9)"
  f=$(ls "$AGENT_QUEUE_DIR"/queued/*-pp-p1.md)
  assert_equal "$(sed -n 's/^from: //p' "$f")" auto:plan-row
  assert_equal "$(grep -x 'rows: lv-5' "$SANDBOX/pp.md")" 'rows: lv-5'
  assert_equal "$(sed -n 2p "$SANDBOX/pp.md")" 'rows: lv-5'
  ! grep -rq '^from: board:' "$AGENT_QUEUE_DIR"/queued/ || fail "a phase carries the plan row as its own row"
  # A plan whose every phase already landed queues nothing and leaves its rows: line alone.
  printf '# one\n\n## Phases\n\n- [ ] P1 one\n' > "$SANDBOX/one.md"
  AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/one.md" --project level --slug one >/dev/null
  AGENT_QUEUE_START=0 "$AQ" move one-p1 done --status ok >/dev/null
  cp "$SANDBOX/one.md" "$SANDBOX/one.orig"
  run env AGENT_QUEUE_PULL=dispatch "$AQ" add --plan "$SANDBOX/one.md" --project level --from board:level:lv-6 --slug one
  assert_failure 4
  assert_output --partial "every phase of $SANDBOX/one.md already landed"
  cmp "$SANDBOX/one.md" "$SANDBOX/one.orig" || fail "an all-landed plan got a rows: line"
}

# The project is resolved as every add resolves it: a repo whose work counts on its owner (tools ->
# cockpit, as dotfiles -> agent-runtime) files on the owner's board. NEGATIVE CONTROL: unresolved,
# tools had no board, the add failed, and reap retried every dotfiles plan each pass (ar-2787).
@test "a filer's --plan for a repo with an owner files its row on the owner's board" {
  story_notes
  jq '.trackers.cockpit.lab = "bnb" | .trackers.cockpit.code = "ck"' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m.json" && mv "$SANDBOX/m.json" "$AGENT_QUEUE_PROJECT_MAP"
  unset AGENT_QUEUE_PULL
  printf '# P\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/owned.md"
  run "$AQ" add --plan "$SANDBOX/owned.md" --project tools --from auto:plans --priority low
  assert_failure 5
  assert_called "ptask cockpit --agent add --detail=Run the open phases of the approved plan $SANDBOX/owned.md in order"
}

@test "every queued item counts against the cap, one held to a time of day or a date too" {
  # The queue holds only work that can start (a gated add files a board row), so every queued item
  # counts: one left from before, held to a time of day or a date, too.
  export AGENT_QUEUE_CAP=2
  legacy n1 "tags: at:20:00" --project game "evening one"
  legacy dated "tags: at:2099-01-01T09:00" --project game "dated"
  run "$AQ" add --project game --slug day "day"
  assert_failure 5
  assert_output --partial "2 items can start now against a cap of 2"
  "$AQ" cancel dated >/dev/null
  run "$AQ" add --project game --slug day "day"
  assert_success
}

@test "a queue item's session adding without --from files item:<its slug>, held at the cap like any add" {
  export AGENT_QUEUE_CAP=1 AGENT_QUEUE_ITEM=parent
  run "$AQ" add --project game --priority low --slug first "first follow-up"
  assert_success
  [ "$(field "$(item queued first)" from)" = item:parent ]
  run "$AQ" add --project game --priority low --slug second "second follow-up"
  assert_failure 5
  assert_output --partial "against a cap of 1 (item:parent)"
  "$AQ" add --project game --slug own --running --session s1 "own work" >/dev/null
  # Urgent is capped too (2026-11-18): with nothing to return it is held, from the item.
  run "$AQ" add --project game --slug now --priority urgent "urgent for the human"
  assert_failure 5
  assert_output --partial "against a cap of 1 (item:parent)"
  # Only a capped add is from the item; the rest keep human, as the readers of from expect.
  [ "$(field "$(item running own)" from)" = human ]
}

@test "AGENT_QUEUE_CAP=0 is the negative control: the same adds overflow past the cap, and admission --json counts the holds of 7 days" {
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project game --slug one "one" >/dev/null
  AGENT_QUEUE_CAP=0 run "$AQ" add --project game --from auto:x --slug free "free"
  assert_success
  run "$AQ" add --project game --from auto:x --slug held "held"
  assert_failure 5
  printf '{"at":"2000-01-01T00:00:00Z","from":"auto:x","slug":"old"}\n' >> "$AGENT_QUEUE_DIR/admission.jsonl"
  run "$AQ" admission --json
  assert_equal "$(jq -c '[.on, .runnable, .limit, .held_7d, .admits]' <<<"$output")" '[true,2,1,1,false]'
  run env AGENT_QUEUE_CAP=0 "$AQ" admission
  assert_output --partial "admission: off,"
  # A filer retrying the same item counts once, and the next hold drops lines past the window.
  run "$AQ" add --project game --from auto:x --slug held "held"
  assert_failure 5
  run "$AQ" admission --json
  assert_equal "$(jq .held_7d <<<"$output")" 1
  run jq -r .slug "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output "$(printf 'held\nheld')"
}

@test "at the cap, an add of a slug already queued says so, not that admission held it" {
  export AGENT_QUEUE_CAP=1
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --from auto:x --slug one "one again"
  assert_failure 1
  assert_output --partial "already in the queue: one"
  [ ! -e "$AGENT_QUEUE_DIR/admission.jsonl" ]
}

# The only write a return makes to a row besides the un-start is the gate tags of an item still held
# (see "return writes what the item still waits on"); these items wait on nothing.
@test "return writes no brief to its board row: the row already holds it, and an item with no hold adds no tag" {
  story_notes
  "$AQ" add --project game --slug ha "first line of the brief
second line of the brief"
  "$AQ" set ha row=game:gm-1
  "$AQ" add --project game --slug hb "short one-liner"
  "$AQ" set hb row=game:gm-2
  "$AQ" add --project game --from board:game:gm-3 --slug gm-3 "feat(game): row text
generated line"
  "$AQ" add --project game --slug hd "kept
already"
  "$AQ" set hd row=game:gm-4
  : > "$NOTES_FIXTURE/calls.log"
  for s in ha hb gm-3 hd; do "$AQ" return "$s" --why "back" >/dev/null; done
  run grep -cE ' ptask game --agent (edit|tag) ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  for r in gm-1 gm-2 gm-3 gm-4; do assert_called "ptask game --agent unstart $r"; done
}

@test "a partial merge cannot close ok or release after items" {
  "$AQ" add --project game --running --slug partial 'two repos' >/dev/null
  legacy next "after: partial" --project game 'next phase' >/dev/null
  "$AQ" set partial pr=o/game#1 merged=aaa111 partial=yes >/dev/null
  run "$AQ" move partial done --status ok
  assert_failure
  assert_output --partial 'has a partial landing'
  run "$AQ" show next --json
  assert_equal "$(jq -r .hold <<<"$output")" 'after partial'
  "$AQ" set partial partial= >/dev/null
  run "$AQ" move partial done --status ok
  assert_success
  run "$AQ" show next --json
  assert_equal "$(jq -r '.hold // ""' <<<"$output")" ''
}

@test "--row, a row move and --plan check the queue for a row or plan without deriving a hold (ar-2544)" {
  story_notes
  export AGENT_QUEUE_CAP=0 # the cap derives every hold to count runnable; this test is about the writers that do not
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/gh.log"\necho OPEN\n' "$SANDBOX" > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh"
  legacy held "tags: pr:Org/game#7" --project game "a"
  : > "$SANDBOX/gh.log"
  run "$AQ" add --project game --row lv-2 --slug by-row "feat(menu): the row's work"
  assert_success
  run "$AQ" add --project game --row lv-2 --slug twice "y"
  assert_failure; assert_output --partial "by-row already works that row"
  printf '# p\n\n## Phases\n- [ ] one\n' > "$SANDBOX/p.md"
  run "$AQ" add --project game --plan "$SANDBOX/p.md"
  assert_success
  run "$AQ" add --project game --plan "$SANDBOX/p.md"
  assert_failure; assert_output --partial "already queued"
  [ ! -s "$SANDBOX/gh.log" ] || fail "a writer asked gh: $(cat "$SANDBOX/gh.log")"
}

@test "a lock that stays busy past the wait exits 75, not 1, and writes nothing" {
  "$AQ" add --project game "one item" >/dev/null
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" add --project game "two item"
  assert_failure 75
  assert_output --partial "the queue is locked by another writer"
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" show one-item --json
  assert_failure 75
  flock -u 9
  run "$AQ" list --json
  [ "$(jq -sr 'map(.slug) | join(",")' <<<"$output")" = one-item ]
}

# ar-3025: a timeout names who held the lock. NEGATIVE CONTROL: before it, nothing was written and
# 108 dispatch starts failed with no holder on record.
@test "a lock timeout appends one lock-miss line naming the holder, the taker and its mode" {
  "$AQ" add --project game "one item" >/dev/null
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  # 9>&-: the taker is not the holder's child here, so it must not inherit the holder's fd.
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" add --project game "two item" 9>&-
  assert_failure 75
  assert_output --partial "lock-miss.jsonl"
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" show one-item --json 9>&-
  assert_failure 75
  flock -u 9
  exec 9>&-
  log="$AGENT_QUEUE_DIR/lock-miss.jsonl"
  [ "$(wc -l < "$log")" = 2 ]
  run jq -r --argjson me "$BASHPID" -s '.[] | [.mode, (.cmd | test("agent-queue (add|show)")),
    (.locks | index(".lock holds WRITE") != null), (.procs | any(.pid == $me and .file == ".lock")),
    (.procs | all(.cmd | test("agent-queue") | not))] | map(tostring) | join(" ")' "$log"
  assert_line --index 0 "exclusive true true true true"
  assert_line --index 1 "shared true true true true"
  # Past 1 MB the log moves to .1 and starts again.
  head -c 1048576 /dev/zero > "$log"
  exec 9> "$AGENT_QUEUE_DIR/.lock"
  flock 9
  AGENT_QUEUE_LOCK_WAIT=1 run "$AQ" show one-item --json 9>&-
  assert_failure 75
  [ "$(stat -c %s "$log.1")" = 1048576 ]
  [ "$(wc -l < "$log")" = 1 ]
}

# The row is the task's record (ar-2927), against the real notes and a sandbox vault: an item's body
# is its row's brief, so a return loses nothing, the next promote briefs the new item from the row,
# and a retask rewrites the row first. NEGATIVE CONTROL: before ar-2927 the re-promoted body was the
# row line alone. The CI rust job builds notes and sets NOTES_BIN.
@test "end to end: a returned item's brief comes back from its row on the next promote, and retask rewrites the row" {
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  dir="$HOME/.notes/lab/projects/current/game"
  mkdir -p "$dir" "$HOME/.config/notes"
  : >"$dir/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  printf '%s\n' '# game' '' 'Version: v1.0.0 #beta' '' '## Inbox' '' '## Tasks' '' >"$dir/README.md"
  export PROJECT_MAP_FILE="$AGENT_QUEUE_PROJECT_MAP" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  unset NOTES_PROFILE
  jq -n --arg r "$REPO" '{paths: {($r): "game"}, trackers: {game: {code: "gm", lab: "personal"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  tail=$'goal: one record per task\n\n- a list\n  - nested\n\n```sh\n    echo hi\n```\n## Phases\n- [ ] P1 one'
  run "$AQ" add --project game --slug title -- $'feat(menu): the title screen\n'"$tail"
  assert_success
  assert_line 'story gm-1 on the game agent board'
  # the checklist in the brief is no row of its own
  run notes --profile personal ptask game --agent list
  refute_output --partial 'P1 one'

  run "$AQ" return title --why "over the cap"
  assert_success
  raw="$(notes --profile personal ptask game --agent list | awk -F'\t' '$4 ~ /id:gm-1 / { print $4 }')"
  [[ "$raw" == '- [ ] feat(menu): the title screen'* ]] || fail "row not back open: $raw"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile personal --agent --raw "$raw"
  assert_success
  assert_output --partial 'queued game: gm-1'
  f="$(item queued gm-1)"
  body="$(awk 'f { print } $0 == "---" { f = 1 }' "$f")"
  [ "$(head -1 <<<"$body")" = "${raw#- \[ \] }" ] || fail "first line: $body"
  [ "$(tail -n +2 <<<"$body")" = "$tail" ] || fail "the brief did not come back whole: $body"

  run "$AQ" retask gm-1 $'feat(menu): the title screen\nnew brief'
  assert_success
  [ "$(notes board --json | jq -r '.rows[] | select(.id == "gm-1") | .details | join("\n")')" = "new brief" ] ||
    fail "row not rewritten: $(cat "$dir/agent/README.md")"
  [ "$(awk 'f { print } $0 == "---" { f = 1 }' "$f")" = $'feat(menu): the title screen\nnew brief' ]
}

@test "ar-2943: a session's add names its priority; an add by hand keeps the high default" {
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" add --project game --slug s1 "bare from a session"
  assert_failure
  assert_output --partial "a session's add passes --priority"
  AGENT_QUEUE_ITEM=u1 run "$AQ" add --project game --slug s2 "bare from a dispatched session"
  assert_failure
  plan_fixture
  AGENT_QUEUE_ITEM=u1 run "$AQ" add --plan "$SANDBOX/my-plan.md" --project game
  assert_failure
  assert_output --partial "a session's add passes --priority"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued")" ]
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" add --project game --priority low --slug s3 "named by the session"
  assert_success
  [ "$(field "$(item queued s3)" priority)" = low ]
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" add --project game --running --slug s4 "the session's own task"
  assert_success
  # a human channel names its want, not a priority, and an emptied session env counts as none
  CLAUDE_CODE_SESSION_ID=sid-a run "$AQ" add --project game --want voice --slug s6 "a want said aloud"
  assert_success
  CLAUDE_CODE_SESSION_ID= AGENT_QUEUE_ITEM= run "$AQ" add --project game --slug s7 "a script that cleared the session"
  assert_success
  [ "$(field "$(item queued s7)" priority)" = high ]
  # negative control: the same bare add by hand, with no session around it, files high
  run "$AQ" add --project game --slug s5 "bare by hand"
  assert_success
  [ "$(field "$(item queued s5)" priority)" = high ]
}

@test "the store-sync a write starts on exit does not inherit the queue lock" {
  # A sync that held .lock waited out its own sync lock (300s) with every queue writer behind it (2026-11-18).
  printf '#!/usr/bin/env bash\nif [ -e /proc/$$/fd/8 ]; then echo "store-sync fd8=open" >> "$NOTES_FIXTURE/calls.log"; else echo "store-sync fd8=closed" >> "$NOTES_FIXTURE/calls.log"; fi\n' > "$SANDBOX/bin/store-sync"
  chmod +x "$SANDBOX/bin/store-sync"
  run "$AQ" add --project game "Menu: pick sides"
  assert_success
  run cat "$NOTES_FIXTURE/calls.log"
  assert_output --partial "store-sync fd8=closed"
  refute_output --partial "store-sync fd8=open"
}

@test "lag_places: a class with only held items sets no floor for the bound, as it starts nothing" {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  today="$(date +%F)"
  # This week: requested 30 of 60 (0.5), feature 10 of 10 (1.0); research none (0), but its one item is held.
  for i in $(seq 1 30); do mix_done "$today" "dr$i" human "do thing $i" 1; done
  for i in $(seq 1 10); do mix_done "$today" "df$i" shepherd "feature done $i" 1; done
  printf '%s\t%s\tgame\t%s\t1\n' "research(game): held question" research "held question" > "$NOTES_FIXTURE/row.parse"
  "$AQ" add --project game --slug r2 "asked 2"
  "$AQ" add --project game --slug r3 "asked 3"
  "$AQ" add --project game --from shepherd --slug f1 "feature 1"
  legacy z1 "after: r2" --project game --from shepherd "research(game): held question"
  n=0; for s in r2 r3 f1 z1; do n=$((n + 1)); sed -i "s/^queued: .*/queued: ${today}T00:0$n:00Z/" "$(item queued "$s")"; done
  jq '.on = true | .lag_places = 10' "$REPO_ROOT/.config/fleet-dispatch/classes.json" > "$SANDBOX/classes.json"
  # The floor is requested's 0.5, so feature is cut to 0.6 and both requested items go before it. Had
  # held research's 0 set the floor, both would be cut to 0.1 and f1 would go second.
  run bash -c "'$AQ' list --json --state queued | jq -r .slug | paste -sd' '"
  assert_success
  assert_output 'z1 r2 r3 f1'
}

# twinkling-soaring-hinton P5: notes sends a session's agent add to the outbox and exits 4. A board-only
# add from a session (a held follow-up) then has no row, and says so; the plan's own row and the
# item's own story row name their origin, so notes writes them directly.
@test "a session's held follow-up that notes inboxes (exit 4) is reported as inboxed, with no row" {
  story_notes
  unset AGENT_QUEUE_PULL
  echo 4 > "$NOTES_FIXTURE/story.rc"
  echo "inboxed: follow-up" > "$NOTES_FIXTURE/story.out"
  : > "$NOTES_FIXTURE/calls.log"
  rc=0; out=$("$AQ" add --project level --from shepherd --slug nudge "fix(menu): a filer's follow-up" 2>"$SANDBOX/err") || rc=$?
  assert_equal "$rc" 5
  assert_equal "$out" "inboxed nudge -> inbox"
  grep -qF "in the outbox" "$SANDBOX/err"
  run grep -c ' ptask level --agent start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

# ar-3684: notes shows a hand session's add the similar open rows and exits 5. The item has no row
# then, and the shortlist reaches the session so it can join one or file with --checked.
@test "a held follow-up that notes answers with a shortlist (exit 5) has no row and prints the shortlist" {
  story_notes
  unset AGENT_QUEUE_PULL
  echo 5 > "$NOTES_FIXTURE/story.rc"
  printf 'dm-4\t62\tagent\tfix(menu): the follow-up already filed\n' > "$NOTES_FIXTURE/story.out"
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project level --from shepherd --slug nudge "fix(menu): a filer's follow-up" 2>"$SANDBOX/err" || true
  grep -qF "similar open rows" "$SANDBOX/err"
  grep -qF "dm-4" "$SANDBOX/err"
  run grep -c ' ptask level --agent start ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "the item's own story row and a plan's rows name their origin, a want names none" {
  story_notes
  unset AGENT_QUEUE_PULL
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --project level --slug own --from human "feat(menu): own row"
  assert_success
  assert_called "ptask level --agent add --origin agent-queue -- feat(menu): own row #high"
  printf '# P\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/orig.md"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" add --plan "$SANDBOX/orig.md" --project level --from auto:plans --priority low
  assert_failure 5
  run grep -- '--agent add' "$NOTES_FIXTURE/calls.log"
  assert_output --partial " --origin plan -- "
}
