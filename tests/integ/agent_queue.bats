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
  printf "slug: n\n${hdr}tags: night\nweight: light\n---\nn\n" > "$AGENT_QUEUE_DIR/queued/20261107-010001-n.md"
  printf "slug: p\n${hdr}mode: plan\n---\np\n" > "$AGENT_QUEUE_DIR/queued/20261107-010002-p.md"
  printf "slug: q\n${hdr}phases: one two\n---\nq\n" > "$AGENT_QUEUE_DIR/queued/20261107-010003-q.md"
  export AGENT_QUEUE_NOW=12:00
  list="$("$AQ" list --json --state all --date 2026-11-07)"
  for s in b c n p q; do
    [ "$(jq -c --arg s "$s" 'select(.slug == $s)' <<<"$list")" = "$("$AQ" show "$s" --json)" ]
  done
  c="$("$AQ" show c --json)"
  [ "$(jq -r '.hold // "none"' <<<"$c")" = none ]
  [ "$(jq -r .ready <<<"$c")" = 2026-11-07T02:00:00Z ]
  [[ "$(jq -r .hold <<<"$("$AQ" show n --json)")" == night* ]]
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
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two' > "$SANDBOX/rq.md"
  AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/rq.md" --project game --slug rq >/dev/null
  "$AQ" cancel rq-p2 >/dev/null
  "$AQ" move rq-p1 done --status ok >/dev/null
  run "$AQ" add --plan "$SANDBOX/rq.md" --project game --slug rq
  assert_success
  assert_output --partial "skipped rq-p1 already finished ok"
  assert_output --partial "tick its box in $SANDBOX/rq.md"
  [ -z "$(item queued rq-p1)" ] || fail "a landed phase was queued again"
  [ "$(field "$(item queued rq-p2)" after)" = rq-p1 ] || fail "p2 does not go after the landed p1"
  "$AQ" move rq-p2 done --status ok >/dev/null
  run "$AQ" add --plan "$SANDBOX/rq.md" --project game --slug rq
  assert_failure 4
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a landed phase was queued again"
  # negative control: --repeat queues every phase as new work
  run "$AQ" add --plan "$SANDBOX/rq.md" --project game --slug rq --repeat
  assert_success
  [ -n "$(item queued rq-p1)" ] && [ -n "$(item queued rq-p2)" ]
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

@test "list puts a red item first, then priority, then a cleanup item within its priority" {
  "$AQ" add --project game --slug a-high "a"
  "$AQ" add --project game --slug b-cleanup --tags "cleanup tier3" "b"
  "$AQ" add --project game --slug c-urgent --priority urgent "c"
  "$AQ" add --project game --slug d-red-low --priority low --tags "red cause:x" "d"
  "$AQ" add --project game --slug e-reddish --tags "reddish" "e"
  "$AQ" add --project game --slug f-cleanup-low --priority low --tags cleanup "f"
  run bash -c "'$AQ' list --json | jq -r .slug"
  # red beats urgent; cleanup beats an older item of its priority, never a higher priority; tags match whole words.
  assert_output $'d-red-low\nc-urgent\nb-cleanup\na-high\ne-reddish\nf-cleanup-low'
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

@test "a project's #prio ranks its items within a priority, under red and urgent, over cleanup" {
  "$AQ" add --project app --slug a-app "a"
  "$AQ" add --project app --slug b-app-cleanup --tags cleanup "b"
  "$AQ" add --project game --slug c-game "c"
  "$AQ" add --project app --slug d-app-urgent --priority urgent "d"
  "$AQ" add --project tools --slug e-tools "e"
  # With no #prio set the order is as before: cleanup first, then queued time.
  run bash -c "'$AQ' list --json | jq -r .slug"
  assert_output $'d-app-urgent\nb-app-cleanup\na-app\nc-game\ne-tools'
  printf 'game\tfocus\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r .slug"
  # urgent still heads; game, focused, beats the older app items and the app cleanup.
  assert_output $'d-app-urgent\nc-game\nb-app-cleanup\na-app\ne-tools'
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = d-app-urgent ]
}

@test "#prio ranks focus and only first, then high, then normal, then low" {
  "$AQ" add --project elsewhere --slug a-else "a"
  "$AQ" add --project app --slug b-app "b"
  "$AQ" add --project game --slug c-game "c"
  "$AQ" add --project cockpit --slug d-cockpit "d"
  printf 'game\thigh\nelsewhere\tlow\ncockpit\tonly\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r .slug"
  assert_output $'d-cockpit\nc-game\nb-app\na-else'
}

@test "while a project is #prio/only, other projects' items hold on focus, but red, urgent and requested ones do not" {
  "$AQ" add --project app --slug a-app "a"
  "$AQ" add --project app --slug b-app-red --tags red "b"
  "$AQ" add --project app --slug c-app-urgent --priority urgent "c"
  "$AQ" add --project app --slug d-app-req --tags requested "d"
  "$AQ" add --project game --slug e-game "e"
  # Negative control: no only, nothing holds.
  run bash -c "'$AQ' list --json | jq -r 'select(.hold) | .slug'"
  assert_output ''
  printf 'game\tonly\napp\thigh\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r '\"\\(.slug) \\(.hold // \"-\")\"'"
  assert_output $'b-app-red -\nc-app-urgent -\ne-game -\na-app focus: only game\nd-app-req -'
  # A lone check (show, start_next) gives the same answer as the listing.
  run "$AQ" show a-app --json
  [ "$(jq -r .hold <<<"$output")" = "focus: only game" ]
  # focus ranks, it never holds.
  printf 'game\tfocus\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r 'select(.hold) | .slug'"
  assert_output ''
}

@test "an after: successor off focus stays queued when its item closes; on focus it starts" {
  "$AQ" add --project app --slug first --running "a" >/dev/null
  "$AQ" add --project app --slug second --after first "b" >/dev/null
  printf 'game\tonly\n' > "$NOTES_FIXTURE/prios"
  run "$AQ" move first done --status ok
  assert_success
  assert_not_called 'start --item second'
  [ -n "$(item queued second)" ]
  "$AQ" add --project game --slug g1 --running "c" >/dev/null
  "$AQ" add --project game --slug g2 --after g1 "d" >/dev/null
  run "$AQ" move g1 done --status ok
  assert_called 'fleet-dispatch start --item g2'
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
  "$AQ" add --project game --slug second --priority urgent --after first "b"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first"
  [ "$("$AQ" next --json | jq -r .slug)" = first ]
  "$AQ" move first running
  "$AQ" move first done --status failed
  run "$AQ" next
  assert_failure
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first closed failed, dead: read who closed it and why in agent-queue show first, then set after=<slug> or cancel this with --why"
  "$AQ" add --project game --slug first --repeat "again"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first"
  "$AQ" move first done --status ok
  [ "$("$AQ" next --json | jq -r .slug)" = second ]
}

@test "an after: on an item closed cancelled says the hold is dead, through show as well as list" {
  "$AQ" add --project game --slug first "a"
  "$AQ" add --project game --slug second --after first "b"
  "$AQ" move first done --status cancelled
  run bash -c "'$AQ' show second --json | jq -r .hold"
  assert_output "after first closed cancelled, dead: read who closed it and why in agent-queue show first, then set after=<slug> or cancel this with --why"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first closed cancelled, dead: read who closed it and why in agent-queue show first, then set after=<slug> or cancel this with --why"
}

# ar-39: after: is a list of slugs.
@test "after: takes a list: a comma list and a repeated --after store one line, set too, and an unknown or own slug is refused" {
  "$AQ" add --project game --slug a "a" >/dev/null
  "$AQ" add --project game --slug b "b" >/dev/null
  "$AQ" add --project game --slug c "c" >/dev/null
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

@test "a list after: holds until every slug closed ok, names the live ones and a dead one first, and the last close starts it" {
  "$AQ" add --project game --slug a --running "a" >/dev/null
  "$AQ" add --project game --slug b --running "b" >/dev/null
  "$AQ" add --project game --slug both --after a,b "both" >/dev/null
  f="$(item queued both)"; sed -i 's/^queued: .*/queued: 2026-11-03T08:00:00Z/' "$f"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"both\") | .hold'"
  assert_output "after a b"
  run "$AQ" bump both urgent
  assert_output --partial "both is held after a b: it starts when those land"
  # tk's plan phases are already ticked: it closes as landed, but only once both its parents have.
  printf '## Phases\n\n- [x] one\n' > "$SANDBOX/tk-plan.md"
  "$AQ" add --project game --slug tk --after a,b "tk" >/dev/null
  sed -i "/^from: /i plan: $SANDBOX/tk-plan.md\nphases: 1" "$(item queued tk)"
  run "$AQ" move a done --status ok
  refute_output --partial "releases"
  # One of two closed ok: it still holds on the other, and nothing starts or closes it.
  assert_not_called 'start --item both'
  [ -n "$(item queued tk)" ]
  run bash -c "'$AQ' show both --json | jq -r '.hold, .ready // \"none\"'"
  assert_output $'after b\nnone'
  run "$AQ" move b done --status ok
  assert_line "b releases: both tk"
  assert_called 'fleet-dispatch start --item both'
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-tk.md)" status)" = ok ]
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
  "$AQ" add --project game --slug two --after c,x "two" >/dev/null
  "$AQ" move x done --status failed >/dev/null
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"two\") | .hold'"
  assert_output "after x closed failed, dead: read who closed it and why in agent-queue show x, then set after=<slug> or cancel this with --why"
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

@test "the night window is the clock hours' night part, and with none a night item holds and says why" {
  "$AQ" add --project game --slug tonight --tags night "a"
  export MACHINE_MODE_HOURS="$BATS_TEST_TMPDIR/hours"
  printf 'day|02:00-22:00|open|x\nnight|22:00-02:00|full|y\n' > "$MACHINE_MODE_HOURS"
  AGENT_QUEUE_NOW=22:30 run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = tonight ]
  AGENT_QUEUE_NOW=03:00 run "$AQ" next --json
  [ "$(jq -r '.slug // empty' <<<"$output")" != tonight ]
  printf 'day|00:00-24:00|open|x\n' > "$MACHINE_MODE_HOURS"
  AGENT_QUEUE_NOW=02:00 run "$AQ" next --json
  [ "$(jq -r '.slug // empty' <<<"$output")" != tonight ]
  [ "$(jq -r .hold <<<"$("$AQ" show tonight --json)")" = "night (the hours file has no night part)" ]
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

@test "an ask: tag holds an item until that agent-ask is answered, with that option when one is named (ar-455)" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  # add refuses a malformed tag and an id no ask file has, so the gate is never silently open or shut.
  for t in "ask:" "ask:../x" "ask:a1=" "ask:a1"; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure
  done
  ask a1 pending
  "$AQ" add --project game --slug money --tags "ask:a1=a" "go live"
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
  "$AQ" add --project game --slug any --priority urgent --tags "ask:a2" "any answer"
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
  "$AQ" add --project game --slug go --tags "ask:o1=a+b" "go"
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
  "$AQ" add --project game --slug one --tags "night ask:h1=a+b" "one"
  "$AQ" add --project game --slug two --tags "ask:h1=a ask:h2=b" "two"
  "$AQ" add --project game --slug free "no ask"
  "$AQ" add --project game --slug gone --tags "ask:h2=a" "gone"
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
  "$AQ" add --project game --slug one --tags "ask:o2=GO" "x"
  "$AQ" add --project game --slug two --tags "ask:o2=stop-burst+do-bridge+go" "x"
  "$AQ" add --project game --slug three --tags "ask:o2=steps" "x"
  # An ask with no options has nothing to check a name against.
  printf 'id: o3\nstatus: pending\n' > "$AGENT_ASK_DIR/game/o3.md"
  "$AQ" add --project game --slug four --tags "ask:o3=anything" "x"
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
  "$AQ" add --project game --slug p3 --tags "tier3 ask:live=a" "go live"
  ask yes answered 'a' human
  "$AQ" add --project game --slug p4 --tags "ask:yes=a" "the next"
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
  "$AQ" add --project game --slug forms --tags "hold:mac-desktop" "fill the store forms"
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
  printf '#!/usr/bin/env bash\necho "rbw $*" >> "%s/rbw.calls"\ncase "$1" in\n  unlocked) [ ! -e "%s/rbw.locked" ] ;;\n  list) cat "%s/rbw.list" ;;\n  *) exit 9 ;;\nesac\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/rbw-fake"
  chmod +x "$SANDBOX/rbw-fake"
  export AGENT_QUEUE_RBW="$SANDBOX/rbw-fake"
  printf 'trading\tkalshi-key\nother\tmanifold-key\n' > "$SANDBOX/rbw.list"
  for t in "rbw:" "rbw:trading" "rbw:trading/" "rbw:/manifold-key"; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure; assert_output --partial "rbw:<folder>/<name>"
  done
  "$AQ" add --project game --slug deploy-key --tags "rbw:trading/manifold-key" "deploy the manifold key"
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
  # Only the read-only verbs ran: never get, unlock or sync.
  run grep -cvE '^rbw (unlocked|list --fields folder,name)$' "$SANDBOX/rbw.calls"
  assert_output 0
}

@test "requeue --hold puts a started item back behind the resource, keeps its tags, and is not a model redo (ar-613)" {
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  printf '#!/usr/bin/env bash\necho "model-lane $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/model-lane"
  chmod +x "$SANDBOX/bin/model-lane"
  "$AQ" add --project game --running --slug forms --tags "night" "fill the store forms" >/dev/null
  "$AQ" set forms "lane_run=r-forms" >/dev/null
  run "$AQ" requeue forms --hold "../x"
  assert_failure
  run "$AQ" requeue forms
  assert_failure
  # Behind a free resource it would restart at once, so the session is told to claim it.
  run "$AQ" requeue forms --hold mac-desktop
  assert_failure; assert_output --partial "claim it"
  [ -n "$(item running forms)" ]
  "$REPO_ROOT/.local/bin/agent-hold" claim mac-desktop --by other "steam forms" >/dev/null
  run "$AQ" requeue forms --hold mac-desktop
  assert_success; assert_output --partial "forms: running -> queued"
  f="$(item queued forms)"
  [ "$(field "$f" tags)" = "night hold:mac-desktop" ]
  [ -z "$(field "$f" lane_run)" ]
  [ -z "$(field "$f" started)" ]
  # A second requeue adds the tag once.
  "$AQ" requeue forms --hold mac-desktop >/dev/null
  [ "$(field "$(item queued forms)" tags)" = "night hold:mac-desktop" ]
  run grep '^model-lane' "$NOTES_FIXTURE/calls.log"
  assert_failure
  run env AGENT_QUEUE_NOW=02:00 "$AQ" next --json
  assert_failure
  "$REPO_ROOT/.local/bin/agent-hold" release mac-desktop >/dev/null
  run env AGENT_QUEUE_NOW=02:00 "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = forms ]
  # Started, its hold tag is spent: its own session may claim the desktop, and a later requeue
  # must not hold it behind that claim.
  "$AQ" move forms running >/dev/null
  [ "$(field "$(item running forms)" tags)" = night ]
}

@test "one waiter per release: the best desk class starts, the rest wait behind it, desk:auth only while the human is here" {
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  presence() { printf '#!/usr/bin/env bash\necho "%s 5 tmux"\n' "$1" > "$SANDBOX/bin/fleet-presence"; chmod +x "$SANDBOX/bin/fleet-presence"; }
  presence here
  run "$AQ" add --project game --slug bad --tags "hold:mac-desktop desk:nope" "x"
  assert_failure; assert_output --partial "desk:<class>"
  "$REPO_ROOT/.local/bin/agent-hold" claim mac-desktop --by other "steam forms" >/dev/null
  "$AQ" add --project game --slug shots --tags "hold:mac-desktop desk:listing" "store screenshots" >/dev/null
  "$AQ" add --project game --slug plain --tags "hold:mac-desktop" "no class" >/dev/null
  "$AQ" add --project game --slug signup --tags "hold:mac-desktop desk:legal" "xbox sign-up" >/dev/null
  # Held by its own at: as well, an older item of the same class does not keep the desktop from the rest.
  "$AQ" add --project game --slug at-tonight --tags "hold:mac-desktop desk:auth at:23:59" "tonight" >/dev/null
  "$AQ" add --project game --slug code --tags "hold:mac-desktop desk:auth" "2fa step" >/dev/null
  run "$AQ" next --json
  assert_failure
  "$REPO_ROOT/.local/bin/agent-hold" release mac-desktop >/dev/null
  run env AGENT_QUEUE_NOW=12:00 "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = code ]
  run "$AQ" list --state queued
  assert_output --partial "hold:mac-desktop (behind code, auth)"
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

@test "requeue --class tags the item's desk class once, and a later --class replaces it" {
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  "$AQ" add --project game --running --slug forms "fill the store forms" >/dev/null
  "$REPO_ROOT/.local/bin/agent-hold" claim mac-desktop --by other "steam forms" >/dev/null
  run "$AQ" requeue forms --hold mac-desktop --class nope
  assert_failure; assert_output --partial "desk:<class>"
  run "$AQ" requeue forms --ask q1 --class legal
  assert_failure; assert_output --partial "usage"
  "$AQ" requeue forms --hold mac-desktop --class legal >/dev/null
  [ "$(field "$(item queued forms)" tags)" = "hold:mac-desktop desk:legal" ]
  # A requeue with no --class keeps the class the item had.
  "$AQ" move forms running >/dev/null
  [ -z "$(field "$(item queued forms 2>/dev/null)" desk_start)" ]
  "$AQ" requeue forms --hold mac-desktop >/dev/null
  [ "$(field "$(item queued forms)" tags)" = "desk:legal hold:mac-desktop" ]
  [ -z "$(field "$(item queued forms)" desk_start)" ]
  "$AQ" move forms running >/dev/null
  "$AQ" requeue forms --hold mac-desktop --class auth >/dev/null
  [ "$(field "$(item queued forms)" tags)" = "hold:mac-desktop desk:auth" ]
}

@test "requeue --ask puts a headless run that needs the human back behind its ask; the human's answer releases it" {
  export AGENT_ASK_DIR="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_DIR/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_DIR/game/$1.md"; }
  "$AQ" add --project game --running --slug codexrun "pick a palette" >/dev/null
  "$AQ" set codexrun "lane_run=r-codex" >/dev/null
  run "$AQ" requeue codexrun --ask q9
  assert_failure; assert_output --partial "no agent-ask has that id"
  run "$AQ" requeue codexrun --ask q9 --hold mac-desktop
  assert_failure; assert_output --partial "usage"
  ask q9 answered 'a' human
  run "$AQ" requeue codexrun --ask q9
  assert_failure; assert_output --partial "already answered"
  [ -n "$(item running codexrun)" ]
  ask q9 pending
  run "$AQ" requeue codexrun --ask q9
  assert_success; assert_output --partial "codexrun: running -> queued"
  f="$(item queued codexrun)"
  [ "$(field "$f" tags)" = "ask:q9" ]
  [ -z "$(field "$f" lane_run)" ]
  run "$AQ" next --json
  assert_failure
  ask q9 answered 'b, the dark one' human
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = codexrun ]
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

@test "a pr: tag on a PR closed unmerged holds and says it never releases" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  printf '#!/usr/bin/env bash\ncat "%s/pr-$3"\n' "$SANDBOX" > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
  echo CLOSED > "$SANDBOX/pr-11"
  "$AQ" add --project game --slug dead --tags "pr:Org/game#11" "a"
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
  "$AQ" add --project game --slug validate --tags "at:2026-11-08T00:00 nightly:game" "a"
  [ "$(AGENT_QUEUE_NOW=2026-11-09T08:20 "$AQ" next --json | jq -r .slug)" = validate ]
  # NEGATIVE CONTROL: with no at: date the same hold reads today (11-09) and still waits on soak.
  "$AQ" cancel validate
  "$AQ" add --project game --slug today --tags "nightly:game" "b"
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
  "$AQ" add --project game --slug next --after p "next" >/dev/null
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
}

@test "retask replaces a queued item's task from args or stdin and keeps its header; refuses an empty task or a started or done item" {
  "$AQ" add --project game --from "board:game:ar-9" --tags "at:2030-01-01T09:00" --slug r "expect 16.7"
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
  "$AQ" move r running
  run "$AQ" retask r "too late"
  assert_failure; assert_output --partial "r is running: its session already has the brief"
  "$AQ" move r done --status ok
  run "$AQ" retask r "too late"
  assert_failure; assert_output --partial "nothing active with slug r"
  run "$AQ" retask nowhere "x"
  assert_failure
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
  CLAUDE_CODE_SESSION_ID=sid-a "$AQ" add --project game --slug later "queued for another session"
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

@test "the next phase starts when its parent closes ok; not when low, not on failed, not past an open hold, not when dispatch is held" {
  "$AQ" add --project game --running --slug ph1 "phase 1" >/dev/null
  "$AQ" add --project game --slug ph2 --after ph1 "phase 2" >/dev/null
  "$AQ" add --project game --slug other "unrelated" >/dev/null
  run "$AQ" move ph1 done --status ok
  assert_success
  assert_called 'fleet-dispatch start --item ph2'
  assert_not_called 'start --item other'
  # Only urgent and high skip the queue: a low next phase waits for a dispatch pass.
  "$AQ" add --project game --running --slug l1 "parent" >/dev/null
  "$AQ" add --project game --slug l2 --after l1 --priority low "low next" >/dev/null
  "$AQ" add --project game --slug l3 --after l1 --priority high "high next" >/dev/null
  run "$AQ" move l1 done --status ok
  assert_success
  assert_output --partial 'l2 is low priority, so a dispatch pass starts it in its turn'
  assert_not_called 'start --item l2'
  [ -f "$(item queued l2)" ]
  assert_called 'fleet-dispatch start --item l3'
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
  "$REPO_ROOT/.local/bin/agent-hold" set dispatch --by human "next queue" >/dev/null
  run "$AQ" move h1 done --status ok
  assert_success
  assert_output --partial 'by human: next queue), so h2 stays queued'
  assert_not_called 'start --item h2'
  [ -f "$(item queued h2)" ]
  "$REPO_ROOT/.local/bin/agent-hold" release dispatch >/dev/null
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

@test "add --plan: (independent) waits on --after alone, (after N) on phase N's item, unmarked lines keep the chain" {
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
  "$AQ" add --project game --slug base "the work before the plan" >/dev/null
  run "$AQ" add --plan "$SANDBOX/marked.md" --project game --after base --dry-run
  assert_success
  assert_line --index 0 --regexp '^would queue marked-p2	phases 2	after base$'
  assert_line --index 2 --regexp '^would queue marked-p3	phases 3	after base$'
  assert_line --index 4 --regexp '^would queue marked-p4	phases 4 5	after marked-p2$'
  # NEGATIVE CONTROL: an unmarked line still waits on the item before it, here the independent one.
  assert_line --index 6 --regexp '^would queue marked-p6	phases 6	after marked-p4$'
  # (after 5) is phase 5's item, which is 4's; (after 1) names a landed phase, so --after alone.
  assert_line --index 8 --regexp '^would queue marked-p7	phases 7	after marked-p4$'
  assert_line --index 10 --regexp '^would queue marked-p8	phases 8	after base$'
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/marked.md" --project game
  assert_success
  f="$(item queued marked-p3)"
  [ "$(field "$f" after)" = "" ]
  [ "$(field "$f" title)" = "marked P3: Third thing: runs beside 2" ]
  [ "$(field "$(item queued marked-p4)" after)" = marked-p2 ]
  [ "$(field "$(item queued marked-p4)" title)" = "marked P4+5: Fourth thing; Fifth thing" ]
  [ "$(field "$(item queued marked-p8)" after)" = "" ]
  # A marker that cannot be honoured is refused whole, naming the line; nothing is queued.
  bad() {
    printf '## Phases\n\n- [-] 1. Deferred\n- [ ] 2. Two\n- [ ] 3. %s\n' "$1" > "$SANDBOX/bad.md"
    run "$AQ" add --plan "$SANDBOX/bad.md" --project game --slug bad --dry-run
    assert_failure
    assert_output "agent-queue: --plan $SANDBOX/bad.md: could not read its Phases checklist: phase 3: $2"
  }
  bad "Three (after 3)" "(after 3) names no earlier phase"
  bad "Three (after 1)" "(after 1) waits on a deferred phase; undefer it or drop the marker"
  bad "Three (independent) (after 2)" "(independent) and (after 2) contradict"
  bad "Three (with 2) (independent)" "a (with 2) line takes the wait of phase 2's item; mark that line"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 7 ]
}

@test "bump to urgent names an after: hold and the set that lifts it, and never lifts it" {
  "$AQ" add --project game --slug first "first"
  "$AQ" add --project game --slug second --after first "second"
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
  "$AQ" set second tags=pr:Org/game#11 >/dev/null
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

# 2026-11-12: two cleanup sessions cancelled 425 items and the items said only "cancelled".
@test "cancel from a session needs --why, and records who and why on the item and in the event" {
  "$AQ" add --project game --slug w1 "w1"
  "$AQ" add --project game --slug w2 "w2"
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
  "$AQ" add --project game --slug m1 "m1"
  "$AQ" add --project game --slug m2 "m2"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m1 done --status cancelled
  assert_failure; assert_output --partial "needs --why"
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m1 done --status cancelled --why "gone"
  assert_success
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-m1.md)"
  [ "$(field "$f" cancelled_by)" = sess-9 ]
  [ "$(field "$f" cancel_why)" = gone ]
  run "$AQ" move m2 done --status failed --why "x"
  assert_failure; assert_output --partial "--why records a cancel"
  # a failed close from a session still needs no reason
  CLAUDE_CODE_SESSION_ID=sess-9 run "$AQ" move m2 done --status failed
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

# ar-617: the Queue table shows each item's wait, so list carries the same ready stats medians.
@test "list --json carries ready: queued, else its after: item's finish when later, none while that holds it" {
  "$AQ" add --project game --slug p "p"
  "$AQ" add --project game --slug f --after p "f"
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

# A test that leaves a writer waiting on a held lock: a failed assert must not leave it behind.
teardown() {
  exec 7>&-
  [ -z "${WRITER:-}" ] || kill "$WRITER" 2>/dev/null || true
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
  wait "$WRITER"
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

@test "a close names the items it releases, and one whose plan phases are already ticked closes instead of starting" {
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
# every call lands in calls.log; `ptask ... start <id>` fails once closed.<id> exists (no open row);
# `ptask ... add` prints its row with id lv-9 and exits 0, or, with
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
  if [ "$rc" = 0 ]; then printf -- '- [ ] %s #c1105 <!-- id:lv-9 -->\n' "${@: -1}"; else cat "$NOTES_FIXTURE/story.out" >&2; fi
  exit "$rc" ;;
*' start '*) [ ! -e "$NOTES_FIXTURE/closed.${@: -1}" ] && [ ! -e "$NOTES_FIXTURE/closed.$4.${@: -1}" ] ||
  { echo "no open task matches" >&2; exit 1; } ;;
*' done '*) [ ! -e "$NOTES_FIXTURE/done.rc" ] || { echo "no open task matches" >&2; exit 1; } ;;
*' run '*) [ ! -e "$NOTES_FIXTURE/run.rc" ] || { echo "no open task matches" >&2; exit 1; } ;;
*' list '*) [ ! -e "$NOTES_FIXTURE/list.rc" ] || exit 1; cat "$NOTES_FIXTURE/list.out" 2>/dev/null ;;
esac
STUB
  chmod +x "$SANDBOX/bin/notes"
}

@test "a canary item files no story row, and --from takes only the known origins, research:<facet> among them" {
  story_notes
  run "$AQ" add --project level --from canary --tags 'night canary' --slug c1 "check(canary): greet 2026w45"
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
  assert_output --partial 'human, shepherd, canary, research:<facet>, auto:<filer> or board'
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
  assert_line --index 1 'notes --profile bnb ptask level --agent add -- feat(menu): live main menus #size/s #low #of/lv-3'
  assert_line --index 2 'notes --profile bnb ptask level --agent start lv-9'
  f="$(item queued menus)"
  [ "$(field "$f" project)" = level ]
  [ "$(field "$f" row)" = level:lv-9 ]
  [ "$(field "$f" lane)" = agent ]
  [ "$(field "$f" profile)" = bnb ]
  [ "$(jq -r .row <<<"$("$AQ" show menus --json)")" = level:lv-9 ]
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
  assert_line --index 0 --partial 'add --want voice -- feat(menu): a #size/s #high #of/lv-3'
  assert_line --index 1 'notes --profile bnb ptask level --agent add -- feat(menu): c #size/s #high #of/lv-3'
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
  assert_line --index 1 "notes --profile bnb ptask level --agent add -- fix(hooks): the overlay's work #size/s #high"
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

# --- admission (ar-697) ------------------------------------------------------------------

# started_item <state dir> <slug> <queued> <started> -- an item file as a dispatcher leaves it.
started_item() {
  mkdir -p "$AGENT_QUEUE_DIR/$1"
  printf 'slug: %s\nproject: game\nmode: oneshot\npriority: high\nfrom: human\nqueued: %s\nstarted: %s\n---\n%s\n' \
    "$2" "$3" "$4" "$2" > "$AGENT_QUEUE_DIR/$1/$2.md"
}

@test "admission holds a machine filer's add once the runnable items reach the limit, writes nothing and logs the hold" {
  export AGENT_QUEUE_ADMIT_MIN=2
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --from auto:docs-cleanup --slug machine-a "machine a"
  assert_success
  [ "$(field "$(item queued machine-a)" from)" = auto:docs-cleanup ]
  run "$AQ" add --project game --from research:costs --slug machine-b "machine b"
  assert_failure 5
  assert_output --partial "held by admission, nothing was added: 2 items can start now against a limit of 2"
  assert_output --partial "notes ptask game --agent add"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-machine-b.md 2>/dev/null)" ] || fail "a held add wrote an item"
  run jq -c '{from, slug, runnable, limit}' "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output '{"from":"research:costs","slug":"machine-b","runnable":2,"limit":2}'
  # A held item does not count: an `after:` one leaves room.
  "$AQ" cancel one >/dev/null
  "$AQ" add --project game --slug later --after machine-a "later" >/dev/null
  run "$AQ" add --project game --from research:costs --slug machine-b "machine b"
  assert_success
}

@test "admission never holds a human, #requested, red, auto:epics verify, urgent or --running add, at or over the limit" {
  export AGENT_QUEUE_ADMIT_MIN=1
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --from auto:x --slug held "held"
  assert_failure 5
  "$AQ" add --project game --slug human "human" >/dev/null
  "$AQ" add --project game --from auto:x --tags '#requested' --slug asked "asked" >/dev/null
  "$AQ" add --project game --from auto:x --tags red --slug broken "broken" >/dev/null
  "$AQ" add --project game --from auto:epics --priority high --tags verify --slug verify-e-1 "verify e" >/dev/null
  run "$AQ" add --project game --from auto:x --tags verify --slug other-verify "another filer's verify"
  assert_failure 5
  "$AQ" add --project game --from auto:x --priority urgent --slug urgent "urgent" >/dev/null
  "$AQ" add --project game --from auto:x --running --session s1 --slug mine "mine" >/dev/null
  run bash -c "'$AQ' list --state active --json | jq -r .slug | sort | paste -sd,"
  assert_output "asked,broken,human,mine,one,urgent,verify-e-1"
  [ "$(wc -l < "$AGENT_QUEUE_DIR/admission.jsonl")" -eq 2 ]
}

@test "a queue item's session adding without --from files item:<its slug>, held at the limit; its deferral, urgent and --from human are not" {
  export AGENT_QUEUE_ADMIT_MIN=1 AGENT_QUEUE_ITEM=parent
  run "$AQ" add --project game --slug first "first follow-up"
  assert_success
  [ "$(field "$(item queued first)" from)" = item:parent ]
  run "$AQ" add --project game --slug second "second follow-up"
  assert_failure 5
  assert_output --partial "an automated add (item:parent) waits"
  "$AQ" add --project game --slug after-one --after first "after first" >/dev/null
  "$AQ" add --project game --slug dated --tags at:2099-01-01T09:00 "dated" >/dev/null
  "$AQ" add --project game --slug asked --from human "the human asked" >/dev/null
  "$AQ" add --project game --slug own --running --session s1 "own work" >/dev/null
  "$AQ" add --project game --slug now --priority urgent "urgent for the human" >/dev/null
  # Only an add admission gates is from the item; the rest keep human, as the readers of from expect.
  [ "$(field "$(item queued dated)" from)" = human ]
  [ "$(field "$(item queued now)" from)" = human ]
  [ "$(field "$(item queued asked)" from)" = human ]
  [ "$(field "$(item running own)" from)" = human ]
}

@test "admission's limit is a day of measured drain, the items started out of the queue in 7 days, never under the floor" {
  local i now old
  now="$(date -u -d '1 hour ago' +%FT%TZ)"; old="$(date -u -d '10 days ago' +%FT%TZ)"
  # 21 started out of the queue in the window: 3 a day. Not counted: one started 10 days ago,
  # and one started the minute it was added (--running), which never sat in the queue.
  for i in $(seq 1 21); do started_item "done/$(date +%F)" "d$i" "$(date -u -d '2 hours ago' +%FT%TZ)" "$now"; done
  started_item running r-old "$old" "$old"
  started_item running r-now "$now" "$now"
  run env AGENT_QUEUE_ADMIT_MIN=1 "$AQ" admission --json
  assert_success
  assert_output '{"on":true,"runnable":0,"limit":3,"drain_per_day":3,"held_7d":0,"admits":true}'
  run env AGENT_QUEUE_ADMIT_MIN=1 AGENT_QUEUE_ADMIT_DAYS=2 "$AQ" admission --json
  assert_equal "$(jq .limit <<<"$output")" 6
  run "$AQ" admission --json
  assert_equal "$(jq .limit <<<"$output")" 10
  run env AGENT_QUEUE_ADMIT_DAYS=0 "$AQ" admission
  assert_output --partial "admission: off,"
}

@test "admission holds a machine filer's --plan as a whole, and admitted, queues every phase" {
  printf '# P\n\n## Phases\n\n- [ ] one\n- [ ] two\n- [ ] three\n' > "$SANDBOX/orphan.md"
  export AGENT_QUEUE_ADMIT_MIN=1 AGENT_QUEUE_START=0
  run "$AQ" add --plan "$SANDBOX/orphan.md" --project game --from auto:plans --tags night
  assert_success
  run bash -c "'$AQ' list --json | jq -r .slug | paste -sd,"
  assert_output "orphan-p1,orphan-p2,orphan-p3"
  "$AQ" add --project game --slug runnable "runnable" >/dev/null
  printf '# Q\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/other.md"
  run "$AQ" add --plan "$SANDBOX/other.md" --project game --from auto:plans --tags night
  assert_failure 5
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/*-other-p1.md 2>/dev/null)" ] || fail "a held plan queued a phase"
}

@test "admission is off at AGENT_QUEUE_ADMIT_DAYS=0, and admission --json counts the holds of the last 7 days" {
  export AGENT_QUEUE_ADMIT_MIN=1
  "$AQ" add --project game --slug one "one" >/dev/null
  AGENT_QUEUE_ADMIT_DAYS=0 run "$AQ" add --project game --from auto:x --slug free "free"
  assert_success
  run "$AQ" add --project game --from auto:x --slug held "held"
  assert_failure 5
  printf '{"at":"2000-01-01T00:00:00Z","from":"auto:x","slug":"old"}\n' >> "$AGENT_QUEUE_DIR/admission.jsonl"
  run "$AQ" admission --json
  assert_equal "$(jq -c '[.held_7d, .admits]' <<<"$output")" '[1,false]'
  # A filer retrying the same item counts once, and the next hold drops lines past the window.
  run "$AQ" add --project game --from auto:x --slug held "held"
  assert_failure 5
  run "$AQ" admission --json
  assert_equal "$(jq .held_7d <<<"$output")" 1
  run jq -r .slug "$AGENT_QUEUE_DIR/admission.jsonl"
  assert_output "$(printf 'held\nheld')"
}

@test "at the limit, a machine add of a slug already queued says so, not that admission held it" {
  export AGENT_QUEUE_ADMIT_MIN=1
  "$AQ" add --project game --slug one "one" >/dev/null
  run "$AQ" add --project game --from auto:x --slug one "one again"
  assert_failure 1
  assert_output --partial "already in the queue: one"
  [ ! -e "$AGENT_QUEUE_DIR/admission.jsonl" ]
}

@test "a partial merge cannot close ok or release after items" {
  "$AQ" add --project game --running --slug partial 'two repos' >/dev/null
  "$AQ" add --project game --slug next --after partial 'next phase' >/dev/null
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
