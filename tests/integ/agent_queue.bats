#!/usr/bin/env bats
# agent-queue - the store and verb contract: add, order, holds, cancel, bump, set, move, stats.
# Everything lives in the sandbox HOME; tmux is the recording stub.
# One of two files, split so CI shards can spread them (the other is agent_queue_part2.bats): as one file it was
# a shard by itself (ar-5740). The setup and fixtures both use are in agent_queue/common.bash.

load 'agent_queue/common'

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

@test "a work machine queues nothing: plain and --plan adds are refused, --running and a plan --check pass" {
  jq '. + {clients: {acme: {profile: "acmework"}}}' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m" && mv "$SANDBOX/m" "$AGENT_QUEUE_PROJECT_MAP"
  printf '# P\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/plan.md"
  export PROJECT_MACHINE_PROFILE=acmework
  run "$AQ" add --project game --slug work-plain "plain"
  assert_failure
  assert_output --partial "this is a work machine (acmework)"
  run "$AQ" add --project game --plan "$SANDBOX/plan.md"
  assert_failure
  assert_output --partial "this is a work machine"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ]
  run "$AQ" add --project game --plan "$SANDBOX/plan.md" --check
  assert_success
  refute_output --partial "this is a work machine"
  run "$AQ" add --running --project game --session hub:game-agent-1 --slug work-own "own work"
  assert_success
  # Negative control: the personal profile, same map, queues as before.
  PROJECT_MACHINE_PROFILE=personal run "$AQ" add --project game --slug home-plain "plain"
  assert_success
  assert_output --partial "queued home-plain"
}

@test "a client's work project is refused on any other machine: plain and --plan adds, by name or from its checkout (ar-6083)" {
  jq '. + {clients: {acme: {profile: "acmework"}}} | .trackers.game = ((.trackers.game // {}) + {client: "acme"})' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m" && mv "$SANDBOX/m" "$AGENT_QUEUE_PROJECT_MAP"
  printf '# P\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/plan.md"
  export PROJECT_MACHINE_PROFILE=personal
  run "$AQ" add --project game --slug client-plain "plain"
  assert_failure
  assert_output --partial "game is a client's work project, hidden on this machine (personal)"
  run "$AQ" add --project game --plan "$SANDBOX/plan.md"
  assert_failure
  assert_output --partial "client's work project"
  run bash -c 'cd "$1" && "$2" add --slug client-cwd "from its checkout"' _ "$REPO" "$AQ"
  assert_failure
  assert_output --partial "client's work project"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ]
  run "$AQ" add --running --project game --session hub:game-agent-1 --slug client-own "own work"
  assert_success
  # set cannot move an item into the client's project either.
  PROJECT_MACHINE_PROFILE=personal "$AQ" add --project app --slug own-app "app work"
  run "$AQ" set own-app project=game
  assert_failure
  assert_output --partial "client's work project"
  # Negative control: the same project with no client queues as before.
  jq 'del(.trackers.game.client)' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m" && mv "$SANDBOX/m" "$AGENT_QUEUE_PROJECT_MAP"
  run "$AQ" add --project game --slug home-plain "plain"
  assert_success
  assert_output --partial "queued home-plain"
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

# ar-3645: live_owner is the one owner check; cause (above), row, area, plan and pr all read the queue through it.
@test "one live item per PR: a second add or set naming it is refused and names the owner; another PR and a validate item pass" {
  run "$AQ" add --project game --slug land-a --pr o/game#7 "land PR 7"
  assert_success
  assert_equal "$(field "$(item queued land-a)" pr)" o/game#7
  run "$AQ" add --project game --slug land-b --pr o/game#7 "check PR 7"
  assert_failure
  assert_output --partial "o/game#7 is already recorded by land-a"
  ! compgen -G "$AGENT_QUEUE_DIR/*/*land-b*"
  # negative control: a different PR, and the same PR in another repo, are other work
  run "$AQ" add --project game --slug land-c --pr o/game#8 "land PR 8"
  assert_success
  run "$AQ" add --project game --slug land-d --pr o/app#7 "land app PR 7"
  assert_success
  "$AQ" add --project game --slug other "other work" >/dev/null
  run "$AQ" set other pr=o/game#7
  assert_failure
  assert_output --partial "o/game#7 is already recorded by land-a"
  run "$AQ" set other open_pr=O/GAME#8
  assert_failure
  assert_output --partial "already recorded by land-c"
  run "$AQ" set other pr=o/game#9
  assert_success
  # an item's own record is not a second owner, and a validate item reviews its author's PR
  run "$AQ" set land-a pr=o/game#7
  assert_success
  run "$AQ" add --project game --slug val-a --tags validate --pr o/game#7 "review PR 7"
  assert_success
  # a closed owner frees the PR
  run "$AQ" move land-a done --status cancelled
  assert_success
  run "$AQ" set other pr=o/game#7
  assert_success
  # reopening the closed item onto a PR another live item now records is the same twin
  run "$AQ" reopen land-a
  assert_failure
  assert_output --partial "o/game#7 is already recorded by other"
}

@test "one live item per plan phase: a twin under another slug is refused by add and by set, another phase and plan pass" {
  story_notes
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two' > "$SANDBOX/own.md"
  printf '%s\n' '## Phases' '- [ ] P1 one' > "$SANDBOX/else.md"
  run env AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/own.md" --project level --slug own
  assert_success
  assert_equal "$(field "$(item queued own-p1)" phases)" 1
  run "$AQ" add --project level --slug twin "P1 of $SANDBOX/own.md: again"
  assert_failure
  assert_output --partial "phase 1 of $SANDBOX/own.md is already held by own-p1"
  ! compgen -G "$AGENT_QUEUE_DIR/*/*-twin.md"
  run "$AQ" add --project level --slug twin2 "Plan: $SANDBOX/own.md phase 1 under a new name"
  assert_failure
  assert_output --partial "already held by own-p1"
  "$AQ" add --project level --slug claimer "a session taking on plan work" >/dev/null
  run "$AQ" set claimer plan="$SANDBOX/own.md" phases=1
  assert_failure
  assert_output --partial "phase 1 of $SANDBOX/own.md is already held by own-p1"
  # negative control: another phase of the plan, and the same phase of another plan, are other work
  run "$AQ" set claimer plan="$SANDBOX/else.md" phases=1
  assert_success
  run "$AQ" add --project level --slug p3 "P3 of $SANDBOX/own.md: three"
  assert_success
  # the holder's own claim, and a closed holder, free nothing wrongly and nothing falsely
  run "$AQ" set own-p1 phases=1
  assert_success
  run "$AQ" move own-p1 done --status cancelled
  assert_success
  run "$AQ" add --project level --slug twin "P1 of $SANDBOX/own.md: again"
  assert_success
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

@test "add --plan skips a phase another item landed under its own slug, named in its task or its plan: field (ar-1613)" {
  story_notes
  printf '%s\n' '## Phases' '- [ ] P1 one' '- [ ] P2 two' '- [ ] P3 three' > "$SANDBOX/lp.md"
  local d="$AGENT_QUEUE_DIR/done/2026-11-06"
  mkdir -p "$d"
  # P1 was queued by hand (no --plan) and P2 by another plan add: each closed ok with its box unticked.
  printf 'slug: by-hand\nproject: level\nstatus: ok\n---\nP1 of %s. Read it first.\n' "$SANDBOX/lp.md" > "$d/20261106-000001-by-hand.md"
  printf 'slug: other-p2\nproject: level\nplan: %s\nphases: 2\nstatus: ok\n---\nx\n' "$SANDBOX/lp.md" > "$d/20261106-000002-other-p2.md"
  # NEGATIVE CONTROL: a phase whose item failed, and one that names another plan, did not land.
  printf 'slug: tried\nproject: level\nstatus: failed\n---\nPhase 3 of the plan %s\n' "$SANDBOX/lp.md" > "$d/20261106-000003-tried.md"
  printf 'slug: elsewhere\nproject: level\nstatus: ok\n---\nP3 of %s\n' "$SANDBOX/xlp.md" > "$d/20261106-000004-elsewhere.md"
  # ... and so did neither a follow-up that cites P3 nor a plan of the same name in another directory.
  printf 'slug: follow\nproject: level\nstatus: ok\n---\nfix review findings for Phase 3 of the plan %s\n' "$SANDBOX/lp.md" > "$d/20261106-000005-follow.md"
  printf 'slug: twin\nproject: level\nplan: %s\nphases: 3\nstatus: ok\n---\nx\n' "$SANDBOX/other/lp.md" > "$d/20261106-000006-twin.md"
  run env AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/lp.md" --project level --slug lp
  assert_success
  assert_output --partial "skipped phase 1 of lp.md already landed on item by-hand"
  assert_output --partial "skipped phase 2 of lp.md already landed on item other-p2"
  [ -z "$(item queued lp-p1)" ] && [ -z "$(item queued lp-p2)" ] || fail "a phase landed under another slug was queued again"
  # P3 waits on the item that landed P2, which releases it at once.
  [ "$(field "$(item queued lp-p3)" after)" = other-p2 ] || fail "p3 does not go after the item that landed p2"
  # --repeat queues every phase as new work.
  "$AQ" move lp-p3 done --status failed >/dev/null
  run env AGENT_QUEUE_START=0 "$AQ" add --plan "$SANDBOX/lp.md" --project level --slug lp --repeat
  assert_success
  [ -n "$(item queued lp-p1)" ]
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
  "$AQ" add --project game --slug f-normal --priority normal "f"
  "$AQ" add --project game --slug d-urgent --priority urgent "d"
  "$AQ" add --project game --slug e-high --priority high "e"
  run bash -c "'$AQ' list --json | jq -r .slug"
  # A bare add by hand is high, so it queues with the explicit high one, in queued order; normal sits between high and low.
  assert_output $'d-urgent\nb-bare\ne-high\nf-normal\nc-low'
  run "$AQ" next --json
  assert_success
  [ "$(jq -r .slug <<<"$output")" = d-urgent ]
}

@test "a queued item ranks one tier higher per AGENT_QUEUE_AGE_STEP it waits, never above high (ar-4554)" {
  "$AQ" add --project game --slug l-old --priority low "l-old"
  "$AQ" add --project game --slug l-mid --priority low "l-mid"
  "$AQ" add --project game --slug n-new --priority normal "n-new"
  "$AQ" add --project game --slug h-new --priority high "h-new"
  "$AQ" add --project game --slug l-held --priority low "l-held"
  printf '\n## Blocked on the key\n' >> "$(item queued l-held)"
  for s in l-old=00:00 l-held=00:01 l-mid=01:30 n-new=03:00 h-new=03:59; do
    sed -i "s/^queued: .*/queued: 2026-11-10T${s#*=}:00Z/" "$(item queued "${s%%=*}")"
  done
  export AGENT_QUEUE_NOW="$(date -d 2026-11-10T04:00:00Z +%Y-%m-%dT%H:%M)"
  # The sandbox turns aging off (sandbox.bash); this test sets agent-queue's default step back.
  export AGENT_QUEUE_AGE_STEP=120
  # At 04:00 with a 120m step: l-old waited 240m (two steps, low -> high, and no further), l-mid
  # 150m (one step, low -> normal), n-new 60m (none). Ties in a tier go by queued time. l-held has no
  # ready while its body holds it, so it has not aged: it ages from when the hold lifts.
  run bash -c "'$AQ' list --json | jq -r 'select(.state == \"queued\") | .slug'"
  assert_output $'l-old\nh-new\nl-mid\nn-new\nl-held'
  [ "$("$AQ" next --json | jq -r .slug)" = l-old ]
  # The order ranks it; its priority line is not rewritten.
  [ "$(field "$(item queued l-old)" priority)" = low ]
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"l-old\") | .priority'"
  assert_output low
  # NEGATIVE CONTROL: 0 turns aging off, and the tiers are strict again.
  run bash -c "AGENT_QUEUE_AGE_STEP=0 '$AQ' list --json | jq -r 'select(.state == \"queued\") | .slug'"
  assert_output $'h-new\nn-new\nl-old\nl-held\nl-mid'
  # A step that is not whole minutes is refused, never read as some default.
  run env AGENT_QUEUE_AGE_STEP=2h "$AQ" next --json
  assert_failure; assert_output --partial "AGENT_QUEUE_AGE_STEP must be whole minutes"
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

@test "list skips an item file with no slug header, names it on stderr and logs it once (ar-5848)" {
  "$AQ" add --project game --slug a-item "a"
  printf 'just some text, no header\n' > "$AGENT_QUEUE_DIR/queued/stray.md"
  run bash -c "'$AQ' list --json 2>'$SANDBOX/err' | jq -r '.slug'"
  assert_success
  assert_output "a-item"
  grep -q "skipping .*stray.md: no slug header" "$SANDBOX/err"
  run bash -c "'$AQ' next --json 2>/dev/null | jq -r .slug"
  assert_success
  assert_output "a-item"
  "$AQ" list --json >/dev/null 2>&1
  [ "$(grep -c 'stray.md' "$AGENT_QUEUE_DIR/headerless.log")" = 1 ]
  # NEGATIVE CONTROL: a file whose header has its slug is listed, and is not logged.
  [ "$(grep -c 'a-item' "$AGENT_QUEUE_DIR/headerless.log")" = 0 ]
}

@test "a header-less file with an unwritable log still lists every valid item, and a done one keeps listing (ar-5848)" {
  "$AQ" add --project game --slug a-item "a"
  "$AQ" add --project game --slug b-item "b"
  printf 'no header\n' > "$AGENT_QUEUE_DIR/queued/00-stray.md"
  mkdir "$AGENT_QUEUE_DIR/headerless.log"
  run bash -c "'$AQ' list --json 2>/dev/null | jq -r '.slug' | sort | tr '\n' ' '"
  assert_success
  assert_output "a-item b-item "
  rmdir "$AGENT_QUEUE_DIR/headerless.log"
  mkdir -p "$AGENT_QUEUE_DIR/done/2026-01-01"
  printf 'status: ok\n' > "$AGENT_QUEUE_DIR/done/2026-01-01/old.md"
  run bash -c "'$AQ' list --json --state done --since 2026-01-01 2>/dev/null | jq -c '.state'"
  assert_output '"done"'
  [ ! -e "$AGENT_QUEUE_DIR/headerless.log" ] || ! grep -q old.md "$AGENT_QUEUE_DIR/headerless.log"
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

@test "a project's #prio, focus or a retired ladder word, reorders no item: urgent, then queued time" {
  "$AQ" add --project app --slug a-app "a"
  "$AQ" add --project app --slug b-app-cleanup --tags cleanup "b"
  "$AQ" add --project game --slug c-game "c"
  "$AQ" add --project app --slug d-app-urgent --priority urgent "d"
  "$AQ" add --project tools --slug e-tools "e"
  # With no #prio set the order is urgent, then queued time.
  run bash -c "'$AQ' list --json | jq -r .slug"
  assert_output $'d-app-urgent\na-app\nb-app-cleanup\nc-game\ne-tools'
  printf 'game\tfocus\napp\tlow\ntools\thigh\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r .slug"
  # The same order: the queue reads no project tag (a project's share of starts is DISPATCH_PROJECT_SHARE).
  assert_output $'d-app-urgent\na-app\nb-app-cleanup\nc-game\ne-tools'
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = d-app-urgent ]
}

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

@test "classes min_live: a class matched by project and under its minimum of live items goes first in its bucket and is marked short; at the minimum, or with none set, the shares decide" {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  today="$(date +%F)"
  mkdir -p "$AGENT_QUEUE_DIR/running" "$AGENT_QUEUE_DIR/waiting"
  printf 'slug: gl1\nproject: game\npriority: high\nfrom: shepherd\nqueued: %sT00:00:00Z\nstarted: %sT00:30:00Z\n---\nrunning\n' "$today" "$today" \
    > "$AGENT_QUEUE_DIR/running/20261118-000000-gl1.md"
  for s in o1 o2; do "$AQ" add --project app --from shepherd --slug "$s" "other $s"; done
  for s in g1 g2; do "$AQ" add --project game --from shepherd --slug "$s" "game $s"; done
  n=0; for s in o1 o2 g1 g2; do n=$((n + 1)); sed -i "s/^queued: .*/queued: ${today}T00:0$n:00Z/" "$(item queued "$s")"; done
  classes() { jq -n --argjson m "$1" '{on: true, window_days: 7, classes: [
    {name: "other", share: 10, default: true},
    {name: "gamework", share: 10, projects: ["game"], min_live: $m}]}' > "$SANDBOX/classes.json"; }
  order() { run bash -c "'$AQ' list --json --state queued | jq -r '[.slug, (.short // false)] | join(\":\")' | paste -sd,"; assert_success; }
  # Negative control: no minimum, the tie goes to the first class in the file.
  classes 0; order
  assert_output 'o1:false,o2:false,g1:false,g2:false'
  # One game item is live and the minimum is 2: gamework is short once, then at its minimum.
  classes 2; order
  assert_output 'g1:true,o1:false,o2:false,g2:false'
  # At the minimum (1 live): no class is short.
  classes 1; order
  assert_output 'o1:false,o2:false,g1:false,g2:false'
  # A waiting item is live too; a review one holds no session.
  mv "$AGENT_QUEUE_DIR/running/20261118-000000-gl1.md" "$AGENT_QUEUE_DIR/waiting/"
  classes 2; order
  assert_output 'g1:true,o1:false,o2:false,g2:false'
  mkdir -p "$AGENT_QUEUE_DIR/review"; mv "$AGENT_QUEUE_DIR/waiting/20261118-000000-gl1.md" "$AGENT_QUEUE_DIR/review/"
  classes 2; order
  assert_output 'g1:true,g2:true,o1:false,o2:false'
  run "$AQ" mix --json
  [ "$(jq -c '.classes[] | select(.name == "gamework") | [.live, .min_live]' <<<"$output")" = '[0,2]' ]
  # A minimum that is not a whole number is no mix, never a failed listing.
  classes 1.5
  run bash -c "'$AQ' list --json --state queued | jq -r .slug | paste -sd,"
  assert_success
  assert_output 'o1,o2,g1,g2'
  run "$AQ" mix
  assert_failure
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
  lag() { jq --argjson l "$1" '.on = true | .lag_places = $l | del(.classes[].min_live)' "$REPO_ROOT/.config/fleet-dispatch/classes.json" > "$SANDBOX/classes.json"; }
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
  assert_output '[false,3,["bug",1,1,0,25],["requested",1,2,2,50],["cleanup",0,0,0,0],["unity",0,0,0,0],["trader",0,0,0,0],["research",1,0,0,0],["feature",1,1,1,25],["bug","research"]]'
  run "$AQ" mix
  assert_success
  assert_line 'mix (off): items started in 7d against each class share'
  assert_line 'bug            15%        1    25%         1          0         0'
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
  run jq -e '(.classes | all(.share | type == "number")) and (.classes | all(.min_live == null or (.min_live | type == "number" and . == floor))) and ([.classes[] | select(.default == true)] | length == 1) and (.on | type == "boolean")' "$c"
  assert_success
}

@test "a focus project's items take no place ahead of another project's, and nothing is held" {
  "$AQ" add --project app --slug a-app "a"
  "$AQ" add --project app --slug b-app-red --tags red "b"
  "$AQ" add --project app --slug c-app-urgent --priority urgent "c"
  "$AQ" add --project app --slug d-app-high --priority high "d"
  "$AQ" add --project app --slug e-app-req --tags requested "e"
  "$AQ" add --project game --slug f-game-low --priority low "f"
  # With no focus, the low game item goes last.
  run bash -c "'$AQ' list --json | jq -r .slug"
  assert_output $'b-app-red\nc-app-urgent\na-app\nd-app-high\ne-app-req\nf-game-low'
  printf 'game\tfocus\n' > "$NOTES_FIXTURE/prios"
  run bash -c "'$AQ' list --json | jq -r '\"\\(.slug) \\(.hold // \"-\")\"'"
  # On focus, it still goes last: focus turns sprints on and ranks nothing.
  assert_output $'b-app-red -\nc-app-urgent -\na-app -\nd-app-high -\ne-app-req -\nf-game-low -'
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
  assert_output "after first closed cancelled, dead: it never releases (queue first again, or set after= without it); who closed it and why: agent-queue show first; a cancel by hand takes --why and --ask <an ask naming it, answered cancel or drop>"
  run bash -c "'$AQ' list --json | jq -r 'select(.slug == \"second\") | .hold'"
  assert_output "after first closed cancelled, dead: it never releases (queue first again, or set after= without it); who closed it and why: agent-queue show first; a cancel by hand takes --why and --ask <an ask naming it, answered cancel or drop>"
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
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_ROOT/game/$1.md"; }
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
  # Any answer releases it, the judge's and an agent's too (agent-ask decides who may answer).
  ask a1 answered 'a' judge
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = money ]
  ask a1 answered 'A, go live' agent
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
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\noptions: a|b|c\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_ROOT/game/$1.md"; }
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

# cancel_guard holds exactly the active items from the human or a #requested row.
@test "cancel_guard holds the items the human asked for, and no other" {
  "$AQ" add --project game --slug typed --from human "chore(x): the human typed it" >/dev/null
  "$AQ" add --project game --from board:game:g2-9 --slug asked --tags "ui requested" "chore(x): a #requested row" >/dev/null
  "$AQ" add --project game --from shepherd --slug agents "chore(x): an agent's own" >/dev/null
  # An empty from: must not hand its tags (requested) to the from field.
  "$AQ" add --project game --from shepherd --slug nofrom --tags requested "chore(x): an empty from" >/dev/null
  sed -i 's/^from: .*/from: /' "$(ls "${AGENT_QUEUE_DIR:-$HOME/.agent/queue}"/queued/*-nofrom.md)"
  "$AQ" add --project game --slug closed --from human "chore(x): closed by the human" >/dev/null
  "$AQ" move closed done --status ok >/dev/null
  local s
  for s in typed asked nofrom; do
    run env CLAUDE_CODE_SESSION_ID=sid-1 "$AQ" cancel "$s" --why "a test"
    assert_failure; assert_output --partial "$s is work the human asked for"
  done
  run env CLAUDE_CODE_SESSION_ID=sid-1 "$AQ" cancel agents --why "a test"
  assert_success
}

# agent-ask reads holds on every card and answer through ask-holds, which reads the header lines
# alone: it must name exactly what list --json's tags do, and nothing from a done item.
@test "ask-holds lists each active item held on an ask, as list --json's tags have them" {
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  for i in h1 h2; do printf 'id: %s\nstatus: pending\noptions: a|b\n' "$i" > "$AGENT_ASK_ROOT/game/$i.md"; done
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
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  printf 'id: o2\nstatus: pending\noptions: go|stop-burst+do-bridge|steps done, verify it\n' > "$AGENT_ASK_ROOT/game/o2.md"
  for t in ask:o2=goo ask:o2=go+ ask:o2=go++steps ask:o2=do-bridge; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure; assert_output --partial 'that ask offers go,stop-burst+do-bridge,steps done, verify it'
  done
  # Negative controls: a real option in any case, a slug holding a +, and a multi-word option by its first word.
  legacy one "tags: ask:o2=GO" --project game "x"
  legacy two "tags: ask:o2=stop-burst+do-bridge+go" --project game "x"
  legacy three "tags: ask:o2=steps" --project game "x"
  # An ask with no options has nothing to check a name against.
  printf 'id: o3\nstatus: pending\n' > "$AGENT_ASK_ROOT/game/o3.md"
  legacy four "tags: ask:o3=anything" --project game "x"
}

@test "add and set tags= refuse an ask that can never release the item: cancelled, another option" {
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_ROOT/game/$1.md"; }
  ask dead cancelled
  ask judged answered a judge
  ask other answered 'b, stay' human
  for t in ask:dead ask:other=a; do
    run "$AQ" add --project game --slug nope --tags "$t" "x"
    assert_failure; assert_output --partial 'can never release it'
  done
  # Negative control: a pending ask, and the human's answer naming that option, are accepted.
  ask live pending
  legacy p3 "tags: tier3 ask:live=a" --project game "go live"
  ask yes answered 'a' human
  legacy p4 "tags: ask:yes=a" --project game "the next"
  # The judge's answer naming that option releases it too, so it is accepted.
  legacy p5 "tags: ask:judged=a" --project game "the judged next"
  # Re-pointing an item off a dead ask goes through set, which checks the same way.
  run "$AQ" set p3 tags="tier3 ask:dead"
  assert_failure; assert_output --partial 'can never release it (cancelled)'
  "$AQ" set p3 tags="tier3 ask:yes=a"
}

@test "a needs:cluster tag is accepted on add and on set tags=, and any other needs: word is refused (ar-5944)" {
  run "$AQ" add --project game --slug cl-a --tags "needs:cluster" "reads the cluster"
  assert_success
  run "$AQ" add --project game --slug cl-b --tags "needs:gpu" "x"
  assert_failure; assert_output --partial 'a needs tag is needs:cluster'
  # set refuses weight= (not settable), so a session keeps its own item on the workstation with the tag.
  run "$AQ" set cl-a weight=heavy
  assert_failure
  run "$AQ" set cl-a tags="size/s needs:cluster"
  assert_success
  run "$AQ" set cl-a tags="needs:cpu"
  assert_failure; assert_output --partial 'a needs tag is needs:cluster'
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
  "$REPO_ROOT/.local/bin/agent-hold" release mac-desktop --by unity-agent-6 >/dev/null
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
  for t in "rbw:" "rbw:trading" "rbw:trading/" "rbw:/"; do
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

# ar-2474: an entry in no folder is rbw:/<name> (rbw lists it with an empty folder).
@test "an rbw:/<name> tag names a folderless entry: held until rbw lists it with no folder, a foldered twin does not release it" {
  printf '#!/usr/bin/env bash\ncase "$1" in\n  unlocked) exit 0 ;;\n  list) cat "%s/rbw.list" ;;\n  *) exit 9 ;;\nesac\n' "$SANDBOX" > "$SANDBOX/rbw-fake"
  chmod +x "$SANDBOX/rbw-fake"
  export AGENT_QUEUE_RBW="$SANDBOX/rbw-fake"
  printf 'trading\tfreellmapi-key\n' > "$SANDBOX/rbw.list"
  legacy llm-key "tags: rbw:/freellmapi-key" --project game "deploy the freellmapi key"
  run "$AQ" list --state queued
  assert_output --partial "rbw:/freellmapi-key (not in rbw yet)"
  run "$AQ" next --json
  assert_failure
  printf '\tfreellmapi-key\n' >> "$SANDBOX/rbw.list"
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = llm-key ]
}

# queue-held-to-board (ar-3121): a row waits on its gate on the board, so gate is the queue's own
# hold_for read through each board form, plus the row lookup for after/.
@test "gate answers each board form clear, pending or dead in hold_for's words, one rbw list for every rbw tag" {
  gate_rbw
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\noptions: a|b\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_ROOT/game/$1.md"; }
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
  # A judge's answer releases the gate like the human's.
  [ "$(st ask/a2/a)" = "clear||ask:a2=a" ]
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

@test "gate after/<row-id> reads each row by id wherever it sits, and --all answers every open row's gates" {
  gate_rbw
  # .tags is what notes lower-cases for grouping; .tags_cased is as written. A gate reads tags_cased, so
  # the ask id keeps its case (2026-11-18: every #ask/ gate on the board read "no agent-ask has that id").
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  printf 'id: AbC12x\nstatus: pending\noptions: a|b\n' > "$AGENT_ASK_ROOT/game/AbC12x.md"
  # .elsewhere is what only --id finds: a row aimed at a later version and a dropped one (the open
  # board and its done feed list neither: 2026-11-23, queue-starved tripped on both), a dup-closed one.
  jq -n '{rows: ([{id: "ar-1", state: "open", tags: ["after/ar-2", "size/s"]}, {id: "ar-2", state: "doing", tags: ["rbw/infra/x"]},
                 {id: "ar-9", state: "open", tags: ["after/ar-4"]},
                 {id: "ar-7", state: "open", tags: ["ask/abc12x/a"], tags_cased: ["ask/AbC12x/a"]}]),
          done: [{id: "ar-3", state: "done", marker: "id:ar-3 done:2026-11-01", tags: ["rbw/infra/gone"]}],
          elsewhere: [{id: "ar-4", state: "done", marker: "id:ar-4 filed:2026-11-01 dropped: on the game sheet"},
                      {id: "ar-5", state: "open", version: "v0.9.0", marker: "id:ar-5"},
                      {id: "ar-6", state: "done", marker: "id:ar-6 dup:ar-5", dup: "ar-5"},
                      {id: "ar-12", state: "done", marker: "id:ar-12 dup:ar-13", dup: "ar-13"},
                      {id: "ar-13", state: "done", marker: "id:ar-13 dup:ar-3", dup: "ar-3"},
                      {id: "ar-14", state: "done", marker: "id:ar-14 dup:ar-15", dup: "ar-15"},
                      {id: "ar-15", state: "done", marker: "id:ar-15 dup:ar-14", dup: "ar-14"}]}' > "$NOTES_FIXTURE/board.json"
  run "$AQ" gate --json after/ar-2 after/ar-3 after/ar-4 after/ar-5 after/ar-6 after/ar-404
  assert_failure 3
  st() { jq -r --arg t "$1" 'select(.tag == $t) | "\(.state)|\(.why)"' <<<"$output"; }
  [ "$(st after/ar-2)" = "pending|after ar-2 (open)" ]
  [ "$(st after/ar-3)" = "clear|" ]
  [[ "$(st after/ar-4)" == "dead|after ar-4: that row was dropped"* ]]
  [ "$(st after/ar-5)" = "pending|after ar-5 (open)" ]
  [ "$(st after/ar-6)" = "pending|after ar-6 (folded into ar-5) (open)" ]
  [[ "$(st after/ar-404)" == "dead|after ar-404: no board row"* ]]
  # Every id in one read: ar-6's dup target was asked for already.
  [ "$(grep -c '^notes board' "$NOTES_FIXTURE/calls.log")" = 1 ]
  grep -qx 'notes board --json --id ar-2 --id ar-3 --id ar-4 --id ar-5 --id ar-6 --id ar-404' "$NOTES_FIXTURE/calls.log"
  # A dup target no tag names is read too, hop by hop, and the last row's state is the gate's.
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" gate --json after/ar-12
  assert_success
  [ "$(st after/ar-12)" = "clear|" ]
  [ "$(grep -c '^notes board --json --id' "$NOTES_FIXTURE/calls.log")" = 3 ]
  # A dup cycle ends at the hop cap, dead, never in a loop.
  run "$AQ" gate --json after/ar-14
  assert_failure 3
  [[ "$(st after/ar-14)" == "dead|after ar-14 (folded into ar-15) (folded into ar-14)"*"folded more than"* ]]
  # A feed jq cannot read is an unread board, so the gate holds pending, never dead.
  cp "$NOTES_FIXTURE/board.json" "$SANDBOX/good.json"; echo 'not json' > "$NOTES_FIXTURE/board.json"
  run "$AQ" gate after/ar-2
  assert_failure 3
  assert_output --partial "pending  after/ar-2: after ar-2 (notes board --json failed)"
  mv "$SANDBOX/good.json" "$NOTES_FIXTURE/board.json"
  # --all: the open rows' gates only, no other tag and no closed row's: the open board, then one --id read.
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" gate --json --all
  assert_failure 3
  [ "$(jq -sr 'map(.tag) | sort | join(" ")' <<<"$output")" = "after/ar-2 after/ar-4 ask/AbC12x/a rbw/infra/x" ]
  [ "$(st ask/AbC12x/a)" = "pending|ask AbC12x=a (pending)" ]
  [ "$(grep -c '^notes board --json$' "$NOTES_FIXTURE/calls.log")" = 1 ]
  [ "$(grep -c '^notes board --json --id' "$NOTES_FIXTURE/calls.log")" = 1 ]
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

@test "gate --all clears each #hold/ row whose id, epic or plan is granted, and the tag and an ungranted row stay held (ar-5237)" {
  gate_rbw
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  "$REPO_ROOT/.local/bin/agent-hold" set critical --kind resource --by coordinator "lockdown" >/dev/null
  "$REPO_ROOT/.local/bin/agent-hold" grant critical ar-1 ar-50 plan-x >/dev/null
  jq -n '{rows: [{id: "ar-1", state: "open", text: "fix(a): one", tags: ["hold/critical"]},
                 {id: "ar-2", state: "open", text: "fix(b): two", tags: ["hold/critical", "of/ar-50"]},
                 {id: "ar-3", state: "open", text: "feat(c): P1", details: ["Phase 1 of the plan /p/plan-x.md: c"], tags: ["hold/critical"]},
                 {id: "ar-4", state: "open", text: "fix(d): four", tags: ["hold/critical", "of/ar-51"]}], done: []}' > "$NOTES_FIXTURE/board.json"
  run "$AQ" gate --json --all
  assert_failure 3
  [ "$(jq -sr 'map(select(.row == null) | "\(.tag)|\(.state)") | join(" ")' <<<"$output")" = "hold/critical|pending" ]
  [ "$(jq -sr 'map(select(.row != null) | "\(.row)|\(.state)|\(.queue)") | sort | join(" ")' <<<"$output")" = \
    "ar-1|clear|hold:critical ar-2|clear|hold:critical ar-3|clear|hold:critical" ]
  [[ "$(jq -sr 'map(select(.row == "ar-2")) | .[0].why' <<<"$output")" == "granted ar-50 by the critical hold" ]]
  # Text names the row a grant clears; no grant, no row line.
  run "$AQ" gate --all
  assert_output --partial "(row ar-1)"
  "$REPO_ROOT/.local/bin/agent-hold" release critical >/dev/null
  "$REPO_ROOT/.local/bin/agent-hold" set critical --kind resource --by coordinator "lockdown" >/dev/null
  run "$AQ" gate --json --all
  [ "$(jq -sr 'map(select(.row != null)) | length' <<<"$output")" = 0 ]
}

@test "a queued hold: item starts when its row, epic or plan is granted; an ungranted one stays held (ar-5237)" {
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  legacy forms "tags: hold:critical" --project game "fill the store forms"
  legacy other "tags: hold:critical" --project game "other work"
  "$REPO_ROOT/.local/bin/agent-hold" set critical --kind resource --by coordinator "lockdown" >/dev/null
  run "$AQ" next --json
  assert_failure
  "$REPO_ROOT/.local/bin/agent-hold" grant critical forms >/dev/null
  run "$AQ" next --json
  [ "$(jq -r .slug <<<"$output")" = forms ]
  run "$AQ" list --state queued
  assert_output --partial "hold:critical (since"
}

@test "gate names the fix for a dead after/: a date or time is an at/ gate, a queue item's slug is its row (ar-4471)" {
  jq -n '{rows: [{id: "ar-1", state: "open", tags: []}], done: []}' > "$NOTES_FIXTURE/board.json"
  mkdir -p "$AGENT_QUEUE_DIR/queued"
  printf 'slug: build-it\nproject: game\nrow: game:ar-1\nqueued: 2026-11-07T01:00:00Z\n---\nbuild it\n' > "$AGENT_QUEUE_DIR/queued/20261107-010000-build-it.md"
  run "$AQ" gate --json after/2026-11-23 after/0900 after/build-it after/nothing-here
  assert_failure 3
  st() { jq -r --arg t "$1" 'select(.tag == $t) | "\(.state)|\(.why)"' <<<"$output"; }
  [ "$(st after/2026-11-23)" = "dead|after 2026-11-23: no board row has that id; a date is an at gate: #at/2026-11-23/HHMM" ]
  [ "$(st after/0900)" = "dead|after 0900: no board row has that id; a time is an at gate: #at/0900" ]
  [ "$(st after/build-it)" = "dead|after build-it: no board row has that id; build-it is a queue item, its row is #after/ar-1" ]
  [ "$(st after/nothing-here)" = "dead|after nothing-here: no board row has that id" ]
}

@test "a queued item whose body's last Blocked heading is not followed by an Unblocked one holds, and has no ready (ar-4471)" {
  mkdir -p "$AGENT_QUEUE_DIR/queued"
  hdr='project: game\npriority: high\nqueued: 2026-11-07T01:00:00Z\nweight: light\n'
  printf "slug: b\n${hdr}---\ntask\n\n## Blocked 2026-11-14 (agent-11)\nneeds a login\n" > "$AGENT_QUEUE_DIR/queued/20261107-010000-b.md"
  printf "slug: u\n${hdr}---\ntask\n\n## Blocked 2026-11-14 (agent-11)\nx\n\n## Unblocked 2026-11-20 (human)\ny\n" > "$AGENT_QUEUE_DIR/queued/20261107-010001-u.md"
  printf "slug: p\n${hdr}---\ntask, mentions ## Blocked inline only\n" > "$AGENT_QUEUE_DIR/queued/20261107-010002-p.md"
  list="$("$AQ" list --json --state queued)"
  hold() { jq -r --arg s "$1" 'select(.slug == $s) | "\(.hold // "none")|\(.ready // "none")"' <<<"$list"; }
  [ "$(hold b)" = 'blocked: "## Blocked 2026-11-14 (agent-11)" in its body; a later "## Unblocked" heading releases it|none' ]
  [ "$(hold u)" = "none|2026-11-07T01:00:00Z" ]
  [ "$(hold p)" = "none|2026-11-07T01:00:00Z" ]
  # show reads the same hold as the listing.
  [ "$(jq -r .hold <<<"$("$AQ" show b --json)")" = "$(jq -r 'select(.slug == "b") | .hold' <<<"$list")" ]
}

@test "return writes what the item still waits on onto its row as gate tags before un-starting it" {
  gate_rbw
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  printf 'id: a1\nstatus: pending\noptions: a|b\n' > "$AGENT_ASK_ROOT/game/a1.md"
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

# ar-4042: an item gated on the PR it opened waits for its own merge and never starts again.
@test "a pr: gate on the item's own PR is refused by set and stripped by return, another PR's gate stays (ar-4042)" {
  story_notes
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  gh_script 'echo OPEN'
  "$AQ" add --project game --running --from shepherd --slug own "own work" >/dev/null
  "$AQ" set own row=game:gm-3 pr=Org/game#5 >/dev/null
  run "$AQ" set own tags="pr:org/game#5"
  assert_failure
  assert_output --partial "pr:org/game#5 is the PR own opened itself"
  # NEGATIVE CONTROL: another PR is no own PR.
  run "$AQ" set own tags="pr:Org/game#6"
  assert_success
  # A PR recorded in open_pr:, one in a list, and one the same set records all count.
  "$AQ" set own open_pr=Org/game#8 >/dev/null
  run "$AQ" set own tags="pr:Org/game#8"
  assert_failure
  "$AQ" set own pr="Org/game#5 Org/game#9" >/dev/null
  run "$AQ" set own tags="pr:Org/game#9"
  assert_failure
  "$AQ" add --project game --running --from shepherd --slug fresh "fresh" >/dev/null
  run "$AQ" set fresh pr=Org/game#12 tags=pr:Org/game#12
  assert_failure
  # A gate written past the check (an older item, a hand edit) is dropped on the return, the other kept.
  sed -i 's|^tags: .*|tags: pr:Org/game#5 pr:Org/game#6|' "$(item running own)"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" return own --why "back"
  assert_success
  assert_output --partial "dropped pr:Org/game#5"
  assert_called "ptask game --agent tag --add pr/Org/game/6 gm-3"
  refute grep -q 'pr/Org/game/5' "$NOTES_FIXTURE/calls.log"
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

@test "requeue --hold of a hand-queued item with no board row files its story row, then returns it behind the resource (ar-4237)" {
  story_notes
  export AGENT_HOLD_DIR="$SANDBOX/holds"
  # The row write is refused at add (a shortlist, a failed notes), so the item starts with none.
  echo 1 > "$NOTES_FIXTURE/story.rc"; echo "notes failed" > "$NOTES_FIXTURE/story.out"
  "$AQ" add --project level --running --slug hand "feat(menu): fill the store forms" >/dev/null 2>&1
  rm "$NOTES_FIXTURE/story.rc"
  [ -z "$(field "$(item running hand)" row)" ] || fail "the item already has a row"
  "$REPO_ROOT/.local/bin/agent-hold" claim mac-desktop --by other "steam forms" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$AQ" requeue hand --hold mac-desktop
  assert_success
  # The row is filed from the item, then gated while still started, and un-started.
  assert_called "ptask level --agent add"
  assert_called "ptask level --agent tag --add hold/mac-desktop lv-9"
  assert_called "ptask level --agent unstart lv-9"
  [ -z "$(item queued hand 2>/dev/null)" ]
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-hand.md)"
  [ "$(field "$f" end_reason)" = returned ]
  [ "$(field "$f" row)" = level:lv-9 ]
  # Negative control: when no row can be filed, it is refused and the item stays running.
  echo 1 > "$NOTES_FIXTURE/story.rc"
  "$AQ" add --project level --running --slug hand2 "feat(menu): again" >/dev/null 2>&1
  run "$AQ" requeue hand2 --hold mac-desktop
  assert_failure; assert_output --partial "has no board row to wait on hold:mac-desktop, and none could be filed"
  [ -n "$(item running hand2)" ]
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
  "$REPO_ROOT/.local/bin/agent-hold" release mac-desktop --by other >/dev/null
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
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  ask() { printf 'id: %s\nstatus: %s\nanswer: %s\nanswered_by: %s\n' "$1" "$2" "${3:-}" "${4:-}" > "$AGENT_ASK_ROOT/game/$1.md"; }
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
  gh_script "echo \"gh \$*\" >> \"$SANDBOX/gh.log\"; cat \"$SANDBOX/pr-\$3\""
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
  gh_script 'exit 1'
  [ "$("$AQ" next --json | jq -r .slug)" = blocked ]
  run "$AQ" add --project game --tags "pr:1653" "x"
  assert_failure; assert_output --partial "pr:<owner>/<repo>#<N>"
}

@test "a pr: tag holds while gh cannot read the PR" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  gh_script 'exit 1'
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
  gh_script "echo \"gh \$*\" >> \"$SANDBOX/gh.log\"; exit 1"
  printf '#!/usr/bin/env bash\necho sekret\n' > "$SANDBOX/bin/rbw-fj"
  printf '#!/usr/bin/env bash\nurl=${*: -1}; echo "$url" >> "%s/fj.urls"\ncase "$url" in */pulls/5) cat "%s/fj.pr" ;; */status) echo "{\\"statuses\\": []}" ;; *) exit 22 ;; esac\n' \
    "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/curl-fj"
  chmod +x "$SANDBOX/bin/rbw-fj" "$SANDBOX/bin/curl-fj"
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
  gh_script "echo \"gh \$*\" >> \"$SANDBOX/gh.log\"; exit 1"
  legacy blocked "tags: pr:Org/game#9" --project game "a"
  for _ in 1 2 3; do "$AQ" list --json >/dev/null; done
  [ "$(wc -l < "$SANDBOX/gh.log")" -eq 1 ] || fail "gh asked $(wc -l < "$SANDBOX/gh.log") times"
  AGENT_QUEUE_PR_TTL=0 "$AQ" list --json >/dev/null
  [ "$(wc -l < "$SANDBOX/gh.log")" -eq 2 ] || fail "TTL 0 did not ask again"
}

@test "a pr: tag on a PR closed unmerged holds and says it never releases" {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  gh_script "cat \"$SANDBOX/pr-\$3\""
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
  # normal is a word again (priority.md): it takes, and ranks between high and low.
  run "$AQ" bump b normal
  assert_success
  [ "$("$AQ" next --json | jq -r .slug)" = a ]
  # NEGATIVE CONTROL: a retired word (medium) is refused; urgent|high|normal|low is the whole set, as on the sheets.
  run "$AQ" bump b medium
  assert_failure; assert_output --partial "urgent, high, normal or low"
  run "$AQ" add --project game --priority medium "x"
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

@test "a move reports the outcome of the item's model-lane run with its cause: ok, failed, redo on a requeue, unrated on a cancel" {
  printf '#!/usr/bin/env bash\necho "model-lane $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/model-lane"
  chmod +x "$SANDBOX/bin/model-lane"
  for s in ok fl rq cx; do "$AQ" add --project game --running --slug "$s" "$s" >/dev/null; "$AQ" set "$s" "lane_run=r-$s" >/dev/null; done
  "$AQ" add --project game --running --slug none "none" >/dev/null
  "$AQ" move ok done --status ok >/dev/null
  "$AQ" set fl note="its PR was closed unmerged" >/dev/null   # a failed run's note is its why (ar-4263)
  "$AQ" move fl done --status failed >/dev/null
  "$AQ" move rq queued >/dev/null
  "$AQ" move cx done --status cancelled >/dev/null
  "$AQ" move none done --status ok >/dev/null
  run grep '^model-lane' "$NOTES_FIXTURE/calls.log"
  assert_output $'model-lane outcome r-ok ok --cause close\nmodel-lane outcome r-fl failed --why its PR was closed unmerged --cause close\nmodel-lane outcome r-rq redo --cause requeue\nmodel-lane outcome r-cx unrated --cause cancel'
  # The requeued item's next start logs a run of its own.
  [ -z "$(field "$(item queued rq)" lane_run)" ]
}

@test "move --end records why a run ended; a run that ended outside the model files unrated, that end its cause, on a close or a requeue; timeout and stopped still rate" {
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
  assert_output $'model-lane outcome r-lim unrated --cause limit\nmodel-lane outcome r-prov unrated --cause provider\nmodel-lane outcome r-cut unrated --cause cut\nmodel-lane outcome r-ref unrated --cause refused\nmodel-lane outcome r-req unrated --cause limit\nmodel-lane outcome r-tmo failed --why the run ended before it closed the item (end timeout) --cause close\nmodel-lane outcome r-stp failed --why the run ended before it closed the item (end stopped) --cause close'
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-lim.md)" end_reason)" = limit ]
  [ "$(field "$(item queued req)" end_reason)" = limit ]
  # A new run has not ended: the reason goes when the item runs again.
  "$AQ" move req running >/dev/null
  [ -z "$(field "$(item running req)" end_reason)" ]
}

@test "move --cause names why a started item went back: a red PR's fix-ci and a conflict rate redo, a green PR's land handoff and a lost host file unrated; refused off a requeue or outside MOVE_CAUSES (ar-4725)" {
  printf '#!/usr/bin/env bash\necho "model-lane $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/model-lane"
  chmod +x "$SANDBOX/bin/model-lane"
  for s in red cfl grn lst tk; do "$AQ" add --project game --running --slug "$s" "$s" >/dev/null; "$AQ" set "$s" "lane_run=r-$s" >/dev/null; done
  "$AQ" move red review >/dev/null; "$AQ" move cfl review >/dev/null; "$AQ" move grn review >/dev/null
  run "$AQ" move grn queued --cause green
  assert_failure
  assert_output --partial '--cause is one of fix-ci conflict land takeover lost reject'
  run "$AQ" move grn done --status ok --cause land
  assert_failure
  assert_output --partial 'use it with move <slug> queued'
  "$AQ" move red queued --cause fix-ci --if review >/dev/null
  "$AQ" move cfl queued --cause conflict --if review >/dev/null
  "$AQ" move grn queued --cause land --if review >/dev/null
  "$AQ" move lst queued --cause lost >/dev/null
  "$AQ" move tk queued --cause takeover >/dev/null
  run grep '^model-lane' "$NOTES_FIXTURE/calls.log"
  assert_output $'model-lane outcome r-red redo --cause fix-ci\nmodel-lane outcome r-cfl redo --cause conflict\nmodel-lane outcome r-grn unrated --cause land\nmodel-lane outcome r-lst unrated --cause lost\nmodel-lane outcome r-tk redo --cause takeover'
  # An unrated end outranks the mover's cause: the run says why it ended.
  "$AQ" move red running >/dev/null; "$AQ" set red lane_run=r-red2 >/dev/null
  "$AQ" move red queued --cause fix-ci --end limit >/dev/null
  run tail -n 1 "$NOTES_FIXTURE/calls.log"
  assert_output 'model-lane outcome r-red2 unrated --cause limit'
  # A trainee's no-diff run that said why (already-fixed, blocked) files unrated: no model's miss.
  for s in afx blk; do "$AQ" add --project game --running --slug "$s" "$s" >/dev/null; "$AQ" set "$s" "lane_run=r-$s" >/dev/null; done
  "$AQ" move afx queued --cause already-fixed >/dev/null
  "$AQ" move blk queued --cause blocked >/dev/null
  run grep -E '^model-lane outcome r-(afx|blk) ' "$NOTES_FIXTURE/calls.log"
  assert_output $'model-lane outcome r-afx unrated --cause already-fixed\nmodel-lane outcome r-blk unrated --cause blocked'
}

@test "handoff passes a running item to a fresh session: its pushed branch as salvage, its note, an unrated end; refused while its work is not pushed (ar-2777)" {
  printf '#!/usr/bin/env bash\necho "model-lane $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/model-lane"
  chmod +x "$SANDBOX/bin/model-lane"
  handoff_repo
  "$AQ" add --project game --running --slug h "h" >/dev/null
  "$AQ" set h lane_run=r-h >/dev/null
  run "$AQ" handoff h --note "$NOTE" --dir "$WT"
  assert_failure
  assert_output --partial "feat at $(git -C "$WT" rev-parse --short=12 HEAD) is not on origin: push it first"
  git -C "$WT" push -q origin feat 2>/dev/null
  : > "$WT/untracked"
  run "$AQ" handoff h --note "$NOTE" --dir "$WT"
  assert_failure
  assert_output --partial 'has uncommitted changes'
  rm "$WT/untracked"
  run "$AQ" handoff h --note "$SANDBOX/missing.md" --dir "$WT"
  assert_failure
  assert_output --partial 'is missing or empty'
  cp "$NOTE" "$BATS_TEST_TMPDIR/scratch.md"
  run "$AQ" handoff h --note "$BATS_TEST_TMPDIR/scratch.md" --dir "$WT"
  assert_failure
  assert_output --partial 'is outside $HOME'
  # Nothing refused moved the item.
  [ -n "$(item running h)" ]
  run "$AQ" handoff h --note "$NOTE" --dir "$WT"
  assert_success
  assert_output --partial "h: handed off (1 of 2); end this session now (/wind-down auto): the next start reads $NOTE"
  it=$("$AQ" show h --json)
  assert_equal "$(jq -r '[.state, .salvage, .handoff, .handoffs, .end_reason] | join("|")' <<<"$it")" "queued|feat@$(git -C "$WT" rev-parse HEAD)|$NOTE|1|handoff"
  # Unrated: the run did not fail, so model-lane counts it by its end and scores nothing (a plain move to queued files a redo).
  run grep '^model-lane' "$NOTES_FIXTURE/calls.log"
  assert_output 'model-lane outcome r-h unrated --cause handoff'
  run "$AQ" handoff h --note "$NOTE" --dir "$WT"
  assert_failure
  assert_output --partial 'h is queued, not running'
}

@test "handoff stops at AGENT_HANDOFF_MAX; an item with a PR, or a head the trunk holds, carries no salvage (ar-2777)" {
  handoff_repo
  git -C "$WT" push -q origin feat 2>/dev/null
  "$AQ" add --project game --running --slug p "p" >/dev/null
  "$AQ" set p pr=o/game#12 >/dev/null
  run "$AQ" handoff p --note "$NOTE" --dir "$WT"
  assert_success
  [ -z "$(field "$(item queued p)" salvage)" ]
  "$AQ" move p running >/dev/null
  AGENT_HANDOFF_MAX=1 run "$AQ" handoff p --note "$NOTE" --dir "$WT"
  assert_failure
  assert_output --partial 'p has handed off 1 times (AGENT_HANDOFF_MAX 1): finish it in this session'
  [ -n "$(item running p)" ]
  # On main, which origin holds: nothing to carry, and no branch needed.
  git -C "$WT" checkout -q main
  "$AQ" add --project game --running --slug m "m" >/dev/null
  # An older salvage (a lost run's) is not this head: the handoff clears it.
  "$AQ" set m salvage=feat@0000000 >/dev/null
  run "$AQ" handoff m --note "$NOTE" --dir "$WT"
  assert_success
  [ -z "$(field "$(item queued m)" salvage)" ]
  [ "$(field "$(item queued m)" handoffs)" = 1 ]
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

# ar-4215: fleet-bench triage reads proves_at with fromdateiso8601, so a time it cannot parse would hold nothing.
@test "set proves_at takes a UTC time and refuses any other shape" {
  "$AQ" add --project game --running --slug p "p" >/dev/null
  run "$AQ" set p proves_at=tomorrow
  assert_failure
  assert_output --partial 'proves_at is a UTC time'
  run "$AQ" set p proves_at=2026-11-31T12:00:00Z   # the right shape, no such day
  assert_failure
  run "$AQ" set p proves_at=2026-11-22T12:05:00Z
  assert_success
  [ "$(field "$(item running p)" proves_at)" = 2026-11-22T12:05:00Z ]
  [ "$("$AQ" list --json --state all | jq -r 'select(.slug == "p") | .proves_at')" = 2026-11-22T12:05:00Z ]
}

# ar-2779: the outcomes pass reads landed_by as <session>=<owner>/<repo>#<N> pairs; any other shape credits nothing.
@test "set landed_by takes <session>=<owner>/<repo>#<N> pairs and refuses any other shape" {
  "$AQ" add --project game --running --slug lb "lb" >/dev/null
  run "$AQ" set lb landed_by=sid-a
  assert_failure
  assert_output --partial 'landed_by is <session id>=<owner>/<repo>#<N> per PR'
  run "$AQ" set lb "landed_by=sid-a=o/r#4 sid-b=o/p#55"
  assert_success
  [ "$("$AQ" list --json --state all | jq -r 'select(.slug == "lb") | .landed_by')" = 'sid-a=o/r#4 sid-b=o/p#55' ]
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

@test "setting pr= on a done item keeps its merged: sha" {
  "$AQ" add --project game --running --slug d "d" >/dev/null
  "$AQ" set d pr=o/game#1 merged=aaa111 >/dev/null
  "$AQ" move d done --status ok >/dev/null
  local f
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-d.md)"
  "$AQ" set d pr= >/dev/null
  [ -z "$(field "$f" pr)" ]
  [ "$(field "$f" merged)" = aaa111 ]
  "$AQ" set d pr=o/game#2 >/dev/null
  [ "$(field "$f" pr)" = o/game#2 ]
  [ "$(field "$f" merged)" = aaa111 ]
  # Two PRs against one sha would put the lists out of step for reopen --unland: dropped.
  "$AQ" set d "pr=o/game#2 o/game#3" >/dev/null
  [ -z "$(field "$f" merged)" ]
}

# ar-1228: release-lane-reserve's five PRs, written comma-separated, read as one ref (2026-11-09).
@test "pr= written comma-separated is stored as the space list agent-land and reap split, once per PR" {
  "$AQ" add --project game --running --slug cs "cs" >/dev/null
  "$AQ" set cs "pr=o/game#1,o/web#2, o/game#1" >/dev/null
  [ "$(field "$(item running cs)" pr)" = 'o/game#1 o/web#2' ]
  # NEGATIVE CONTROL: a space list is stored as written.
  "$AQ" set cs "pr=o/web#2 o/game#1" >/dev/null
  [ "$(field "$(item running cs)" pr)" = 'o/web#2 o/game#1' ]
  # The same list in either shape is no new pr:, so a done ok item keeps its merged: list.
  "$AQ" set cs merged="aaa111 bbb222" >/dev/null
  "$AQ" move cs done --status ok >/dev/null
  "$AQ" set cs "pr=o/web#2,o/game#1" >/dev/null
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-cs.md)" merged)" = 'aaa111 bbb222' ]
}

@test "a failed done item still drops merged: on a new pr:, and a title naming merged= does not skip the drop" {
  "$AQ" add --project game --running --slug fd "fd" >/dev/null
  "$AQ" set fd pr=o/game#1 merged=aaa111 >/dev/null
  "$AQ" move fd done --status failed >/dev/null
  local f
  f="$(ls "$AGENT_QUEUE_DIR"/done/*/*-fd.md)"
  "$AQ" set fd pr=o/game#2 >/dev/null
  [ -z "$(field "$f" merged)" ]
  "$AQ" add --project game --running --slug tm "tm" >/dev/null
  "$AQ" set tm pr=o/game#1 merged=aaa111 >/dev/null
  "$AQ" set tm pr=o/game#2 "title=x merged=y" >/dev/null
  [ -z "$(field "$(item running tm)" merged)" ]
}

@test "a failing model-lane never fails the move" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/model-lane"; chmod +x "$SANDBOX/bin/model-lane"
  "$AQ" add --project game --running --slug m "m" >/dev/null; "$AQ" set m lane_run=r1 >/dev/null
  run "$AQ" move m done --status ok
  assert_success
  assert_output --partial 'model-lane outcome r1 ok --cause close failed'
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
  for o in run redispatch resume hand scratch ask sweep; do
    "$AQ" add --project game --running --slug "o-$o" "started by $o" >/dev/null
    "$AQ" set "o-$o" "origin=$o" >/dev/null
  done
  "$AQ" add --project game --slug waits "not started" >/dev/null
  run "$AQ" list --json --state active
  assert_success
  assert_equal "$(jq -sSc 'map({(.slug): .by}) | add' <<<"$output")" \
    '{"mine":null,"o-ask":"ask","o-hand":"hand","o-redispatch":"dispatch","o-resume":"resume","o-run":"dispatch","o-scratch":"hand","o-sweep":"sweep","waits":null}'
}

# 2026-11-20: about 800 of a week's 1715 from: human items were sessions' own --running records, so
# `human` did not mean the human asked (ar-4154).
@test "add --running is from session in a Claude session, item:<slug> in a queue item's, human only at a terminal or with --want; an ask: item files no story row" {
  story_notes
  CLAUDE_CODE_SESSION_ID=s1 "$AQ" add --project level --running --slug hand-own "chore(x): its own work" >/dev/null
  [ "$(field "$(item running hand-own)" from)" = session ]
  CLAUDE_CODE_SESSION_ID=s2 AGENT_QUEUE_ITEM=hand-own "$AQ" add --project level --running --slug sub "chore(x): a part of it" >/dev/null
  [ "$(field "$(item running sub)" from)" = item:hand-own ]
  CLAUDE_CODE_SESSION_ID=s3 "$AQ" add --project level --running --want human --slug asked "feat(x): the human's want" >/dev/null
  [ "$(field "$(item running asked)" from)" = human ]
  CLAUDE_CODE_SESSION_ID=s4 "$AQ" add --project level --running --from shepherd --slug named "chore(x): named" >/dev/null
  [ "$(field "$(item running named)" from)" = shepherd ]
  "$AQ" add --project level --running --slug typed "chore(x): typed at a terminal" >/dev/null
  [ "$(field "$(item running typed)" from)" = human ]
  # negative control: a queued add from a session keeps its old default; only --running changed.
  CLAUDE_CODE_SESSION_ID=s5 "$AQ" add --project level --priority low --slug later "chore(x): later" >/dev/null
  [ "$(field "$(item queued later)" from)" = human ]
  # The ask is an ask: item's record, so no story row is filed for it; a session's record files one.
  : > "$NOTES_FIXTURE/calls.log"
  "$AQ" add --project level --running --from ask:AbC1 --slug ask-resume-abc1 "/captain game go" >/dev/null
  [ "$(field "$(item running ask-resume-abc1)" from)" = ask:AbC1 ]
  run grep -c ' ptask ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  [ -n "$(field "$(item running hand-own)" row)" ]
  run "$AQ" add --project level --from ask: --slug bad "x"
  assert_failure; assert_output --partial "--from is human, session,"
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

# 2026-11-23: ar-2000-prom-zsh and ar-2000-probe-missing failed while their session was live on razer-laptop (ar-5957).
@test "--running records host: on a machine that is not the lease holder, and only with a session; the holder and an unknown holder record none" {
  printf 'dotfiles-agent-9\n' > "$NOTES_FIXTURE/tmux.session"
  export FLEET_HOST=razer-laptop TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0"
  export FLEET_HOSTS_JSON='{"name":"razer-laptop","dest":"u@razer","port":22}'
  FLEET_LEASE_STUB_RC=1 run "$AQ" add --project game --running --slug worker "on a worker"
  assert_success
  [ "$(field "$(item running worker)" session)" = lab:dotfiles-agent-9 ]
  [ "$(field "$(item running worker)" host)" = razer-laptop ]
  # negative controls: the holder, a holder not known, a session given by name, and no worktree session
  run "$AQ" add --project game --running --slug holder "on the holder"
  [ -z "$(field "$(item running holder)" host)" ]
  FLEET_LEASE_STUB_RC=2 run "$AQ" add --project game --running --slug unknown "no holder known"
  [ -z "$(field "$(item running unknown)" host)" ]
  # a non-holder the roster does not list (the workstation) records none: reap reads an unlisted host as gone
  FLEET_HOSTS_JSON='{"name":"other-laptop","dest":"u@o","port":22}' FLEET_LEASE_STUB_RC=1 run "$AQ" add --project game --running --slug unlisted "not in the roster"
  [ -z "$(field "$(item running unlisted)" host)" ]
  FLEET_LEASE_STUB_RC=1 run "$AQ" add --project game --running --session given --slug given "given"
  [ -z "$(field "$(item running given)" host)" ]
  printf 'tools\n' > "$NOTES_FIXTURE/tmux.session"
  FLEET_LEASE_STUB_RC=1 run "$AQ" add --project game --running --slug nosess "a checkout session"
  [ -z "$(field "$(item running nosess)" host)" ]
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

@test "a session's own claim records host: on a machine that is not the lease holder (ar-5957)" {
  "$AQ" add --project game --slug onworker "queued for a worker"
  printf 'dotfiles-agent-9\n' > "$NOTES_FIXTURE/tmux.session"
  export FLEET_HOSTS_JSON='{"name":"razer-laptop","dest":"u@razer","port":22}'
  FLEET_HOST=razer-laptop FLEET_LEASE_STUB_RC=1 TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0" CLAUDE_CODE_SESSION_ID=sid-w run "$AQ" claim onworker
  assert_success
  [ "$(field "$(item running onworker)" host)" = razer-laptop ]
  "$AQ" add --project game --slug onholder "queued for the holder"
  TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0" CLAUDE_CODE_SESSION_ID=sid-h run "$AQ" claim onholder
  assert_success
  [ -z "$(field "$(item running onholder)" host)" ]
  # a stale host: from an earlier run does not outlive the claim that rewrites session:
  "$AQ" add --project game --slug stale "queued with an old host"
  "$AQ" set stale host=old-worker
  TMUX="$SANDBOX/tmp/tmux-1000/lab,123,0" CLAUDE_CODE_SESSION_ID=sid-s run "$AQ" claim stale
  assert_success
  [ -z "$(field "$(item running stale)" host)" ]
}

# ar-5957 review: with host: on a worker's hand item, its own cancel must still spare its own session (ar-4902, ar-5293).
@test "cancel from a worker hand item's own session leaves that session up even though host: names this machine" {
  printf 'dotfiles-agent-4\n' > "$NOTES_FIXTURE/tmux.session"
  export FLEET_HOST=razer-laptop FLEET_HOSTS_JSON='{"name":"razer-laptop","dest":"u@razer","port":22}'
  TMUX="$SANDBOX/tmp/tmux-1000/lab,1,0" FLEET_LEASE_STUB_RC=1 AGENT_QUEUE_ITEM=mine run "$AQ" add --project game --running --slug mine "mine"
  assert_success
  "$AQ" set mine origin=hand
  [ "$(field "$(item running mine)" host)" = razer-laptop ]
  TMUX="$SANDBOX/tmp/tmux-1000/lab,1,0" AGENT_QUEUE_ITEM=mine run "$AQ" cancel mine --why "done another way"
  assert_success
  assert_output --partial "left lab:dotfiles-agent-4 open: it is the caller's own session"
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

@test "an urgent or high plan item starts its session at once, a normal or low one waits its turn; a failed start leaves it queued; AGENT_QUEUE_START=0 only queues; a dispatch hold only queues" {
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
  # A normal one waits its turn too (priority.md: normal waits its turn).
  run "$AQ" add --project game --mode plan --priority normal --slug np "plan, normal"
  assert_success
  assert_output --partial 'np is normal priority, so a dispatch pass starts it in its turn'
  assert_not_called 'start --item np'
  run "$AQ" add --project game --mode plan --priority urgent --slug up "plan, urgent"
  assert_called 'fleet-dispatch start --item up'
  # 2026-11-12: an urgent plan item started under the human's dispatch hold.
  "$REPO_ROOT/.local/bin/agent-hold" set dispatch --by human --until "+12 hours" "next queue" >/dev/null
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

@test "an add from the human's interactive session starts at add at high; a dispatched session, a headless one, a terminal add and a low one do not (ar-4452)" {
  story_notes
  unset AGENT_QUEUE_PULL
  export CLAUDE_CODE_ENTRYPOINT=cli
  run "$AQ" add --project game --priority high --slug i1 "my own task"
  assert_success
  assert_called 'fleet-dispatch start --item i1'
  # NEGATIVE CONTROLS
  run env CLAUDE_CODE_ENTRYPOINT=sdk-cli "$AQ" add --project game --priority high --slug i2 "headless"
  assert_not_called 'start --item i2'
  run env -u CLAUDE_CODE_ENTRYPOINT "$AQ" add --project game --priority high --slug i3 "terminal"
  assert_not_called 'start --item i3'
  "$AQ" set i1 origin=hand >/dev/null
  run env AGENT_QUEUE_ITEM=i1 "$AQ" add --project game --priority high --slug i4 "dispatched"
  assert_not_called 'start --item i4'
  run "$AQ" add --project game --priority low --slug i5 "low"
  assert_success
  assert_not_called 'start --item i5'
}

@test "a headless Claude run with no queue item is not the human: its add goes to the board, its urgent never starts, its --want is refused (ar-3887)" {
  story_notes
  unset AGENT_QUEUE_PULL AGENT_QUEUE_ITEM
  export CLAUDE_CODE_ENTRYPOINT=sdk-cli
  run "$AQ" add --project game --want human --slug hw "a runner claims the human's want"
  assert_failure
  assert_output --partial 'a headless Claude run (sdk-cli) has no human at hand'
  [ -z "$(item queued hw)" ]
  run "$AQ" add --project level --priority urgent --slug hu "a runner's urgent"
  assert_failure 5
  assert_output --partial 'only the board fills the queue'
  [ -z "$(item queued hu)" ]
  assert_not_called 'start --item hu'
  run "$AQ" add --project level --from human --priority high --slug hf "a runner names the human"
  assert_failure 5
  [ -z "$(item queued hf)" ]
  # A headless run's own record still goes in, from session's default, and starts nothing.
  run "$AQ" add --project game --running --slug hr "a runner's record of its own work"
  assert_success
  assert_not_called 'start --item hr'
  # NEGATIVE CONTROLS: the same want from the human's interactive session and from an SDK host's entrypoint
  run env CLAUDE_CODE_ENTRYPOINT=cli "$AQ" add --project game --want human --slug cw "the human's want"
  assert_success
  assert_called 'fleet-dispatch start --item cw'
  run env CLAUDE_CODE_ENTRYPOINT=sdk-ts "$AQ" add --project game --want human --slug tw "an SDK host's want"
  assert_failure
  [ -z "$(item queued tw)" ]
}

@test "start_at_add logs each outcome that is not a start: a low item, a dispatch hold and a failed start (ar-4452)" {
  story_notes
  export FLEET_DISPATCH_DIR="$SANDBOX/dispatch"
  run "$AQ" add --project game --want human --priority low --slug l1 "a low want"
  assert_success
  grep -qF 'start now: l1 is low priority' "$FLEET_DISPATCH_DIR/log.md" || fail "low not logged"
  FD_EXIT=1 run "$AQ" add --project game --want human --slug f1 "a start that fails"
  grep -qF 'start now: f1 could not start now' "$FLEET_DISPATCH_DIR/log.md" || fail "failure not logged"
  # NEGATIVE CONTROL: a start that works adds no line of its own (fleet-dispatch start logs it).
  : > "$FLEET_DISPATCH_DIR/log.md"
  run "$AQ" add --project game --want human --slug ok1 "a start that works"
  assert_called 'fleet-dispatch start --item ok1'
  [ ! -s "$FLEET_DISPATCH_DIR/log.md" ] || fail "a start logged a waiting line"
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

@test "an ok close pulls the rows gated on its row through fleet-dispatch pull-after; a failed close and a rowless item pull nothing; AGENT_QUEUE_START=0 still pulls, which queues and starts none" {
  story_notes
  # The rows after it are pulled through fleet-dispatch, which runs the admission and room checks.
  "$AQ" add --project level --running --slug ph1 "phase 1" >/dev/null
  run "$AQ" move ph1 done --status ok
  assert_success
  assert_called 'fleet-dispatch pull-after lv-9'
  : > "$NOTES_FIXTURE/calls.log"
  # NEGATIVE CONTROLS: a failed close and an item with no row pull nothing.
  "$AQ" add --project level --running --slug f1 "fails" >/dev/null
  "$AQ" move f1 done --status failed >/dev/null
  "$AQ" add --project game --running --slug g1 "no row" >/dev/null
  "$AQ" move g1 done --status ok >/dev/null
  assert_not_called 'pull-after'
  # The shepherd's idle close (AGENT_QUEUE_START=0) pulls too: its chain's next phase waited 10h on a pass
  # when it did not (2026-11-21, ar-4357); it passes --queue-only, so pull-after starts none.
  AGENT_QUEUE_START=0 "$AQ" add --project level --running --slug z1 "parent" >/dev/null
  AGENT_QUEUE_START=0 "$AQ" move z1 done --status ok >/dev/null
  assert_called 'fleet-dispatch pull-after --queue-only lv-9'
  : > "$NOTES_FIXTURE/calls.log"
  # A pull that fails leaves the rows to the next pass, and the close stands.
  "$AQ" add --project level --running --slug x1 "parent" >/dev/null
  FD_EXIT=1 run "$AQ" move x1 done --status ok
  assert_success
  assert_output --partial 'the rows after lv-9 were not pulled now, so the next dispatch pass promotes them'
  [ "$(field "$(ls "$AGENT_QUEUE_DIR"/done/*/*-x1.md)" status)" = ok ]
}

@test "a close leaves a queued phase alone when its plan phase is [-] and its at: tag is still ahead (ar-2413)" {
  plan_fixture
  "$AQ" add --project game --running --slug base "the work before the phase" >/dev/null
  # 2026-11-14: a close read the [-] box (phase 3, deferred to a date) as landed and closed the next item ok,
  # ahead of its at: hold. That path is gone (#2485); this pins that a close never reads plan boxes again.
  # Written by hand: a gated add queues nothing now, so only an old record can hold both an after: and an at:.
  mkdir -p "$AGENT_QUEUE_DIR/queued"
  printf '%s\n' --- 'slug: my-plan-p3' 'project: game' 'mode: oneshot' 'priority: high' 'weight: light' \
    "plan: $SANDBOX/my-plan.md" 'phases: 3' 'from: human' 'agent: claude' 'queued: 2026-11-16T18:57:46Z' \
    'after: base' 'tags: at:2099-12-15T10:00' --- 'Phase 3 of the plan: not before 2099-12-15 10:00.' \
    > "$AGENT_QUEUE_DIR/queued/20261116-105746-my-plan-p3.md"
  run "$AQ" move base done --status ok
  assert_success
  [ -e "$AGENT_QUEUE_DIR/queued/20261116-105746-my-plan-p3.md" ]
  [ -z "$(ls "$AGENT_QUEUE_DIR"/done/*/*-my-plan-p3.md 2>/dev/null)" ]
  assert_not_called 'start --item my-plan-p3'
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
  : > "$NOTES_FIXTURE/calls.log"   # the close's own pull-after is not the add's
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
  [ "$(field "$f" title)" = "Second thing: details (P2, A plan)" ]
  [ "$(field "$f" row)" = level:lv-2 ]
  grep -qF "Phase 2 of the plan $SANDBOX/my-plan.md: Second thing. Read the plan whole, then do ONLY this phase, to merged." "$f"
  assert_line 'held my-plan-p4 -> level:lv-3 (#after/lv-2)'
  assert_line 'held my-plan-p6 -> level:lv-4 (#after/lv-3)'
  # The row carries the phase's title and its whole brief, for the item dispatch promotes from it.
  grep -qF "Phases 4 and 5 of the plan $SANDBOX/my-plan.md: Fourth thing; Fifth thing. Read the plan whole, then do ONLY these phases, on one branch" "$NOTES_FIXTURE/calls.log"
  ! grep -qs "fleet-dispatch" "$NOTES_FIXTURE/calls.log"
}

@test "add --plan: an epic: new proposal holds the chain in triage, refuses it dropped or unproposed, and is written into the plan once filed" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  plan_fixture
  sed -i '1a epic: new epic(ui): a lobby' "$SANDBOX/my-plan.md"
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project level --dry-run
  assert_failure
  assert_output --partial 'never proposed'
  touch "$NOTES_FIXTURE/trace.fail"
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/my-plan.md" --project level
  [ "$status" -eq 5 ]
  assert_output --partial 'could not be read'
  rm "$NOTES_FIXTURE/trace.fail"
  echo '{"action":"added","text":"epic(ui): a lobby #plan/my-plan"}' > "$NOTES_FIXTURE/trace"
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/my-plan.md" --project level
  [ "$status" -eq 5 ]
  assert_output --partial 'waits on its epic: new proposal'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued")" ]
  ! grep -qF -- '--agent add' "$NOTES_FIXTURE/calls.log"
  echo '{"action":"dropped","text":"epic(ui): a lobby #plan/my-plan","why":"a fix, not a capability"}' >> "$NOTES_FIXTURE/trace"
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project level --dry-run
  assert_failure
  assert_output --partial 'was dropped (a fix, not a capability)'
  echo '{"action":"dup","id":"lv-50","text":"epic(ui): a lobby #plan/my-plan","why":"epic proposal: joins open epic lv-50"}' >> "$NOTES_FIXTURE/trace"
  run "$AQ" add --plan "$SANDBOX/my-plan.md" --project level --dry-run
  assert_success
  grep -q '^epic: new' "$SANDBOX/my-plan.md"
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/my-plan.md" --project level
  assert_success
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 1 ]
  grep -qx 'epic: lv-50' "$SANDBOX/my-plan.md"
}

@test "add --plan: (independent) waits on --after alone, (after N) on phase N's item, unmarked lines keep the chain" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  cat > "$SANDBOX/marked.md" <<'EOF'
## Phases

- [x] 1. Landed thing
- [ ] 2. Second thing
- [ ] 3. Third thing (independent): runs beside 2
- [ ] 4. Fourth thing (after 2; needs the parser from 2)
- [ ] 5. Fifth thing (with 4)
- [ ] 6. Sixth thing
- [ ] 7. Seventh thing (after 5; needs the item 5 joins)
- [ ] 8. Eighth thing (after 1; needs the landed first thing)
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
  [ "$(field "$f" title)" = "Third thing: runs beside 2 (P3)" ]
  [ "$(field "$(item queued marked-p8)" after)" = "" ]
  assert_line 'held marked-p4 -> level:lv-4 (#after/lv-2)'
  assert_line 'held marked-p6 -> level:lv-5 (#after/lv-4)'
  assert_line 'held marked-p7 -> level:lv-6 (#after/lv-4)'
  # A marker that cannot be honoured is refused whole, naming the line; nothing is queued.
  bad() {
    printf '## Phases\n\n- [-] 1. Deferred\n- [ ] 2. Two\n- [ ] 3. %s\n' "$1" > "$SANDBOX/bad.md"
    run "$AQ" add --plan "$SANDBOX/bad.md" --project level --slug bad --dry-run
    assert_failure
    assert_output "agent-queue: --plan $SANDBOX/bad.md: could not read its Phases checklist: phase 3: $2"
  }
  bad "Three (after 3; needs three)" "(after 3) names no earlier phase"
  bad "Three (after 1; needs one)" "(after 1) waits on a deferred phase; undefer it or drop the marker"
  bad "Three (independent) (after 2; needs two)" "(independent) and (after 2) contradict"
  bad "Three (with 2) (independent)" "a (with 2) line takes the wait of phase 2's item; mark that line"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 4 ]
}

@test "add --plan: a phase that takes a row is ranked by it, the higher of the plan's priority and the row's" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  jq -n '{rows: [{project: "level", id: "lv-1", state: "open", priority: "urgent"},
                 {project: "level", id: "lv-2", state: "open", priority: "low"},
                 {project: "level", id: "lv-3", state: "done", priority: "urgent"}]}' > "$NOTES_FIXTURE/board.json"
  cat > "$SANDBOX/takes.md" <<'EOF2'
## Phases

- [ ] P1 First (independent): takes board row lv-1
- [ ] P2 Second (independent): takes lv-2 and documents `takes <row-id>`
- [ ] P3 Third (independent), takes lv-3
- [ ] P4 Fourth (independent)
EOF2
  run "$AQ" add --plan "$SANDBOX/takes.md" --project level --priority high --dry-run
  assert_success
  assert_line --regexp '^would queue takes-p1	phases 1	after -	takes lv-1	priority urgent$'
  # NEGATIVE CONTROL: a lower row never lowers the plan's priority; a closed row is no source; no marker, no change.
  assert_line --regexp '^would queue takes-p2	phases 2	after -	takes lv-2	priority high$'
  assert_line --regexp '^would queue takes-p3	phases 3	after -	takes lv-3	priority high$'
  assert_line --regexp '^would queue takes-p4	phases 4	after -$'
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/takes.md" --project level --priority high
  assert_success
  [ "$(field "$(item queued takes-p1)" priority)" = urgent ]
  [ "$(field "$(item queued takes-p2)" priority)" = high ]
  [ "$(field "$(item queued takes-p4)" priority)" = high ]
}

@test "add --plan: a phase that takes rows files its story row tagged #takes/<id>, and a phase that takes none carries no #takes (ar-3886)" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  jq -n '{rows: [{project: "level", id: "lv-1", state: "open", priority: "low"},
                 {project: "level", id: "lv-2", state: "open", priority: "low"}]}' > "$NOTES_FIXTURE/board.json"
  printf '## Phases\n\n- [ ] P1 First (independent): takes board row lv-1\n- [ ] P2 Second (independent), takes lv-2\n- [ ] P3 Third (independent)\n' > "$SANDBOX/tk.md"
  AGENT_QUEUE_START=0 run "$AQ" add --plan "$SANDBOX/tk.md" --project level --priority high
  assert_success
  run grep '^notes --profile bnb ptask level --agent add' "$NOTES_FIXTURE/calls.log"
  assert_line --index 0 --regexp ' #high #takes/lv-1$'
  assert_line --index 1 --regexp ' #high #takes/lv-2$'
  # NEGATIVE CONTROL: the phase with no marker files its row with no #takes.
  assert_line --index 2 --regexp ' #high( #c[0-9]+)?$'
  refute_line --index 2 --partial '#takes/'
}

@test "add --plan: a phase that takes a row refuses when the board cannot be read, and queues nothing" {
  story_notes
  rm -f "$NOTES_FIXTURE/board.json"
  printf '## Phases\n\n- [ ] P1 First (independent): takes board row lv-1\n' > "$SANDBOX/takes.md"
  run "$AQ" add --plan "$SANDBOX/takes.md" --project level --priority high --dry-run
  assert_failure
  assert_output --partial "notes board --json failed"
}

@test "add --plan: an (after) must name the result it consumes; a shared file, no needs or no parse is refused" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  plan() { printf '## Phases\n\n- [x] 1. Landed\n- [ ] 2. Two\n- [ ] 3. Three\n- [ ] 4. %s\n' "$1" > "$SANDBOX/m.md"; }
  # POSITIVE CONTROL: after 1, needs, passes; a comma list waits on every open phase it names, a landed one drops out.
  plan "Four (after 2, 3; needs both outputs)"
  run "$AQ" add --plan "$SANDBOX/m.md" --project level --slug m --dry-run
  assert_success
  assert_line --regexp '^would queue m-p4	phases 4	after m-p2,m-p3$'
  assert_output --partial "Phase 4 of the plan $SANDBOX/m.md: Four. "
  plan "Four (after 1, 3; needs the third thing)"
  run "$AQ" add --plan "$SANDBOX/m.md" --project level --slug m --dry-run
  assert_success
  assert_line --regexp '^would queue m-p4	phases 4	after m-p3$'
  # A result named in `needs` may use a word the shared-file test reads before it (edit, conflicts); a
  # parenthesis that is not a marker (prose) is no marker; a sub-phase line is never read for one.
  plan "Four (after 2; needs the edit-session API and the conflicts report)"
  run "$AQ" add --plan "$SANDBOX/m.md" --project level --slug m --dry-run
  assert_success
  assert_line --regexp '^would queue m-p4	phases 4	after m-p2$'
  plan "Four (after outreach Phase 2)"
  run "$AQ" add --plan "$SANDBOX/m.md" --project level --slug m --dry-run
  assert_success
  assert_line --regexp '^would queue m-p4	phases 4	after m-p3$'
  printf '## Phases\n\n- [ ] 1. One\n- [ ] 1b. Tidy (after the release)\n- [ ] 2. Two\n' > "$SANDBOX/m.md"
  run "$AQ" add --plan "$SANDBOX/m.md" --project level --slug m --dry-run
  assert_success
  bad() {
    plan "$1"
    run "$AQ" add --plan "$SANDBOX/m.md" --project level --slug m --dry-run
    assert_failure
    assert_output --partial "could not read its Phases checklist: phase 4: "
    assert_output --partial "$2"
  }
  bad "Four (after 2)" "2) names no result it consumes; write (after 2; needs"
  bad "Four (after 2; needs)" "2; needs) names no result it consumes"
  bad "Four (after 2, since it edits ship.sh)" "2, since it edits ship.sh) waits on a shared file"
  bad "Four (after 2; needs the same file as 2)" "2; needs the same file as 2) waits on a shared file"
  bad "Four (after 2; needs foo() helper)" "2; needs foo() has a parenthesis inside the marker"
  bad "Four (after 2 and 3)" "2 and 3) does not parse"
  bad "Four (after 3; needs x) (after 2; needs y)" "more than one (after ...) marker"
  [ ! -e "$AGENT_QUEUE_DIR/queued" ] || [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 0 ]
  # The markers are read before the queue: a project the queue cannot resolve still shows the marker error.
  plan "Four (after 2 and 3)"
  run "$AQ" add --plan "$SANDBOX/m.md" --project nowhere --dry-run
  assert_failure
  assert_output --partial "does not parse"
}

@test "add --plan: a marker may carry a note, and P<N> labels number the phases, not their place" {
  story_notes; echo 1 > "$NOTES_FIXTURE/story.seq"
  cat > "$SANDBOX/labelled.md" <<'EOF2'
## Phases

- [x] P1 Landed thing (#9)
- [ ] P7 Check a thing first (independent; queued elsewhere, ar-1)
- [x] P9 Landed out of order (independent) (a note)
- [ ] P8 Later thing (after 7; needs the check)
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
  [ "$(field "$(item queued labelled-p7)" title)" = "Check a thing first (P7)" ]
  assert_line 'held labelled-p8 -> level:lv-3 (#after/lv-2)'
  assert_line 'held labelled-p10 -> level:lv-4 (#after/lv-3)'
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
  gh_script "cat \"$SANDBOX/pr-\$3\""
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
  assert_output --partial "--dry-run and --check go with --plan"
  [ "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" -eq 1 ]
}
