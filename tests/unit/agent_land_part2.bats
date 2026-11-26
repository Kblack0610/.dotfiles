#!/usr/bin/env bats
# The second half of agent_land.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in agent_land/common.bash.
# shard-seconds: 155 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'agent_land/common'

@test "AGENT_QUEUE_ITEM is the default item; a board item closes its own row with lane and profile" {
  item fix-crash 'board:game:fix crash: on load' human bnb
  printf 'The change.\n\nItem: fix-crash\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_success
  assert_line --index 9 'board: closed "fix crash: on load" with pr:o/r#42 commit:fedcba987654'
  run board_calls
  assert_output 'notes --profile bnb ptask game done fix crash: on load --proof pr:o/r#42 commit:fedcba987654'
}

@test "an item taken from the session refuses a PR in another repo, before anything is touched" {
  repo_map
  ITEM_PROJECT=level item store 'board:level:store page' agent
  AGENT_QUEUE_ITEM=store run "$LAND" 42
  assert_failure 2
  assert_output --partial '#42 is in o/r (tools), and store, taken from $AGENT_QUEUE_ITEM, is a level item in game'
  assert_output --partial 'Pass --item store if this PR is that item'
  run grep -c 'pr edit\|pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
  run agent-queue show store --json
  assert_equal "$(jq -r '.state + " " + (.pr // "")' <<<"$output")" 'running '
}

@test "the same PR lands on that item when --item names it, and an item in the PR's repo needs no --item" {
  repo_map
  ITEM_PROJECT=level item store 'board:level:store page' agent
  AGENT_QUEUE_ITEM=other run "$LAND" 42 --item store
  assert_success
  assert_output --partial 'item: store done with pr:o/r#42'
  ITEM_PROJECT=tools item tool 'board:tools:tool fix' agent
  printf 'https://github.com/o/r/pull/43\n' >"$NOTES_FIXTURE/url"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  # #43 is another PR, with its own body: #42's carries "Item: store" now.
  printf 'The change and why.\n\nItem: tool\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=tool run "$LAND" 43
  assert_success
  assert_output --partial 'item: tool done with pr:o/r#43'
}

@test "a sibling subagent's item that agent-queue mine returns refuses this PR, which its body does not name (ar-3047)" {
  # home-config #1195, 2026-11-18: two subagents of one coordinator share its session id; one added
  # its item and started agent-land on its PR, and the other's bare agent-land took that item.
  item qualify
  agent-queue claim qualify --sid sid-coord >/dev/null
  agent-queue set qualify open_pr=o/r#41 >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-coord run "$LAND" 42
  assert_failure 2
  assert_output --partial "#42 (o/r#42) may be a side fix, not qualify's work, taken from agent-queue mine: its body has no \"Item: qualify\" line and qualify does not record it."
  untouched qualify
  # NEGATIVE CONTROL: named by --item, the same PR lands on it.
  CLAUDE_CODE_SESSION_ID=sid-coord run "$LAND" 42 --item qualify --partial
  assert_success
}

@test "an item taken from the session refuses a PR whose body names another item, and takes one that names it (ar-3047)" {
  item fix-crash
  item other-item
  printf 'The change.\n\nItem: other-item\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_failure 2
  assert_output --partial 'its body names its item, other-item. Pass --item other-item for the item #42 is the work of'
  run grep -c 'pr edit\|pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
  # NEGATIVE CONTROL: a body that names this item lands, though its open_pr names an earlier PR.
  agent-queue set fix-crash open_pr=o/r#41 >/dev/null
  printf 'The change.\n\nItem: fix-crash\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_success
  assert_output --partial 'item: fix-crash done with pr:o/r#42'
}

@test "a side fix in the item's own repo, its body naming no item, does not close the session's item (ar-3970)" {
  # unity-core-playground#2985, 2026-11-20: a coordinator's bare agent-land on an iOS side fix took
  # its overnight release watch from agent-queue mine, stamped "Item:" on the body and closed it.
  item watch-beta 'board:dotfiles:watch the beta cut'
  agent-queue claim watch-beta --sid sid-coord >/dev/null
  printf 'The iOS export fix.\n' >"$NOTES_FIXTURE/body"
  CLAUDE_CODE_SESSION_ID=sid-coord run "$LAND" 42
  assert_failure 2
  assert_output --partial "#42 (o/r#42) may be a side fix, not watch-beta's work, taken from agent-queue mine: its body has no \"Item: watch-beta\" line"
  assert_output --partial 'add that line to the body or pass --item watch-beta; else give it its own item'
  untouched watch-beta
  # A placeholder names no item either.
  printf 'The iOS export fix.\n\nItem: <slug>\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=watch-beta run "$LAND" 42
  assert_failure 2
  assert_output --partial 'taken from $AGENT_QUEUE_ITEM: its body has no "Item: watch-beta" line'
  # NEGATIVE CONTROL: the side fix's own item, named by --item, takes it and the placeholder is rewritten.
  item ios-export
  AGENT_QUEUE_ITEM=watch-beta run "$LAND" 42 --item ios-export
  assert_success
  assert_output --partial 'item: ios-export done with pr:o/r#42'
  run grep -cx 'Item: ios-export' "$NOTES_FIXTURE/body"
  assert_output 1
  run agent-queue show watch-beta --json
  assert_equal "$(jq -r '.state + " " + (.pr // "")' <<<"$output")" 'running '
}

@test "a re-run on the PR the item records as open lands with no Item: line (ar-3047)" {
  item fix-crash
  agent-queue set fix-crash open_pr=o/r#42 >/dev/null
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_success
  assert_output --partial 'item: fix-crash done with pr:o/r#42'
}

@test "an agent-lane board item closes its row with --agent" {
  item tidy 'board:dotfiles:tidy it' agent
  run "$LAND" 42 --item tidy --dry-run
  assert_success
  assert_line --index 14 'item: agent-queue set tidy pr=42 merged=<sha> partial= beside earlier PRs && gh api repos/<owner>/<repo>/pulls/42/files | agent-queue attribute tidy && agent-queue move tidy done --status ok'
  assert_line --index 15 'board: notes ptask dotfiles --agent done tidy it --proof pr:42'
  run agent-queue show tidy --json
  assert_equal "$(jq -r .state <<<"$output")" running
}

@test "an unknown or finished item is refused before the merge" {
  run "$LAND" 42 --item nope
  assert_failure 2
  assert_output --partial 'no queue item nope'
  item old
  agent-queue move old done --status ok
  run "$LAND" 42 --item old
  assert_failure 2
  assert_output --partial 'queue item old is done ok, not open'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
  run board_calls
  assert_output ''
}

@test "a re-run after a failed board step finds the item done with this PR and closes the row" {
  item fix 'board:game:fix it' human
  mv "$SANDBOX/bin/notes" "$SANDBOX/notes.ok"
  printf '#!/usr/bin/env bash\necho "board locked" >&2; exit 1\n' >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix
  assert_failure 1
  assert_output --partial 'board failed: board locked'
  mv "$SANDBOX/notes.ok" "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix
  assert_success
  assert_line --index 1 'merge: #42 already MERGED, recording it'
  assert_line --index 5 'board: closed "fix it" with pr:o/r#42 commit:fedcba987654'
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  run "$LAND" 43 --item fix
  assert_failure 2
  assert_output --partial 'queue item fix is done and already carries o/r#42, and an item carries one PR per repo'
}

@test "a task across two repos lands its second PR on its done item: one PR per repo, row closed once" {
  # NEGATIVE CONTROL: before ar-790 the second landing was refused as "done ok, not open".
  item split 'board:game:split it' human
  CLAUDE_CODE_SESSION_ID=sid-first run "$LAND" 42 --item split
  assert_success
  : >"$LOG"
  echo https://github.com/o/p/pull/552 >"$NOTES_FIXTURE/url"
  echo https://github.com/o/p.git >"$NOTES_FIXTURE/origin.url"
  printf 'abcdef0123456789abcdef0123456789abcdef01\n' >"$NOTES_FIXTURE/merge.oid"
  CLAUDE_CODE_SESSION_ID=sid-second run "$LAND" 552 --item split
  assert_success
  refute_output --partial 'could not record this session'
  assert_line 'item: split done with pr:o/p#552, beside o/r#42'
  assert_line 'board: left to its closing PR, o/r#42 (agent-land on that one closes the row if its board step failed)'
  assert_line 'landed #552'
  run board_calls
  assert_output ''
  run agent-queue show split --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-first sid-second'
  # Which session landed which PR, for the outcomes credit (ar-2779).
  assert_equal "$(jq -r .landed_by <<<"$output")" 'sid-first=o/r#42 sid-second=o/p#552'
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr) \(.merged)"' <<<"$output")" \
    'done ok o/r#42 o/p#552 fedcba9876543210fedcba9876543210fedcba98 abcdef0123456789abcdef0123456789abcdef01'
  # A re-run of either PR records nothing twice; a second PR in a repo the item carries is refused.
  run "$LAND" 552 --item split
  assert_success
  assert_line 'board: left to its closing PR, o/r#42 (agent-land on that one closes the row if its board step failed)'
  run agent-queue show split --json
  assert_equal "$(jq -r .pr <<<"$output")" 'o/r#42 o/p#552'
  echo https://github.com/o/p/pull/553 >"$NOTES_FIXTURE/url"
  run "$LAND" 553 --item split
  assert_failure 2
  assert_output --partial 'queue item split is done and already carries o/p#552, and an item carries one PR per repo'
}

@test "a done item with a bare pr: re-runs on its number and takes no PR from another repo" {
  item legacy
  agent-queue set legacy pr=42 merged=fedcba9876543210fedcba9876543210fedcba98 >/dev/null
  agent-queue move legacy done --status ok >/dev/null
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  run "$LAND" 42 --item legacy
  assert_success
  echo https://github.com/o/p/pull/552 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 552 --item legacy
  assert_failure 2
  assert_output --partial 'done and already carries a bare pr:42, which names no repo'
  run agent-queue show legacy --json
  assert_equal "$(jq -r .pr <<<"$output")" 42
}

@test "a bare number read against the wrong repo: a MERGED PR that is not the item's is refused, nothing recorded or edited" {
  # NEGATIVE CONTROL: before ar-886 this recorded an unrelated o/r#595 on the item (2026-11-07).
  item p3 'board:game:fill the names' human
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  echo https://github.com/o/r/pull/595 >"$NOTES_FIXTURE/url"
  printf 'agent-7\n' >"$NOTES_FIXTURE/head.ref"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'Item: some-other-item\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 595 --item p3
  assert_failure 1
  assert_output --partial 'match failed: #595 (o/r#595, from agent-7) is merged, and nothing ties it to p3'
  assert_output --partial 'with --repo <owner>/<repo>'
  refute_output --partial 'only its record is left'
  run grep -c '^gh pr edit\|^notes\|^dotfiles-autopull' <(not_recorded)
  assert_output 0
  run agent-queue show p3 --json
  assert_equal "$(jq -r '"\(.state) \(.pr // "-")"' <<<"$output")" 'running -'
}

@test "--supersedes: another session's merged PR lands the item whose own PR it replaced, which leaves pr: (bk-3)" {
  # 2026-11-11 unity-core-playground agent-17 closed #2271 for agent-5's merged #2276, whose body named agent-5's item.
  item other 'board:dotfiles:the other item'
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'The change.\nItem: other\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'If #42 replaced ship'"'"'s own PR and you closed that one: --supersedes <its number>'
  run "$LAND" 42 --item ship --supersedes 41
  assert_success
  assert_line 'supersedes: #41 closed, replaced by #42'
  assert_line 'landed #42'
  run agent-queue show ship --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr)"' <<<"$output")" 'done ok o/r#42'
  run grep -c 'pr edit' "$LOG"
  assert_output 0
  # an item that records its closed PR (a --pr-only run) drops it, so settle_prior does not refuse it
  item ship2 'board:dotfiles:ship it too' agent
  agent-queue set ship2 pr=o/r#41 >/dev/null
  printf '{"state":"CLOSED","headRefOid":"5eed","body":"no item line","createdAt":"2026-11-11T03:00:00Z"}\n' >"$NOTES_FIXTURE/sup.json"
  run "$LAND" 42 --item ship2 --supersedes 41
  assert_success
  run agent-queue show ship2 --json
  assert_equal "$(jq -r '"\(.state) \(.pr) \(.merged | length)"' <<<"$output")" 'done o/r#42 40'
}

@test "--supersedes refuses an open PR to land, and a superseded PR that is open, merged, not the item's or newer than the merge, touching nothing (bk-3)" {
  # NEGATIVE CONTROL: each would record #42 on ship with no tie between them.
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'Item: other\n' >"$NOTES_FIXTURE/body"
  local args
  for args in 'OPEN|Item: ship|#41 in o/r is OPEN, not closed' 'MERGED|Item: ship|#41 merged, so nothing replaced it' \
              'CLOSED|Item: other|nothing ties #41 to ship' 'CLOSED|Item: ship|#42 merged before #41 was opened|2026-11-12T00:00:00Z'; do
    IFS='|' read -r st b want at <<<"$args"
    jq -nc --arg s "$st" --arg b "$b" --arg at "${at:-2026-11-11T03:00:00Z}" '{state: $s, headRefOid: "5eed", body: $b, createdAt: $at}' >"$NOTES_FIXTURE/sup.json"
    run "$LAND" 42 --item ship --supersedes 41
    assert_failure
    assert_output --partial "$want"
  done
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  rm "$NOTES_FIXTURE/sup.json"
  run "$LAND" 42 --item ship --supersedes 41
  assert_failure
  assert_output --partial '--supersedes takes a merged PR, and #42 is OPEN'
  run grep -c 'pr merge\|pr edit\|^notes' "$LOG"
  assert_output 0
  run agent-queue show ship --json
  assert_equal "$(jq -r '"\(.state) \(.pr // "-")"' <<<"$output")" 'running -'
}

@test "a MERGED PR whose head is not in HEAD is the item's when its body names the item, CRLF or not" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'The change.\r\n\r\nItem: ship\r\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
}

@test "--repo: every gh pr and run call names the repo, and a checkout of another repo is refused before anything is touched" {
  echo https://github.com/o/p/pull/42 >"$NOTES_FIXTURE/url"
  run "$LAND" 42 --repo o/p --item ship
  assert_failure 1
  assert_output --partial 'repo failed: #42 is o/p#42 (--repo), but this checkout'"'"'s origin is o/r: run from a checkout of o/p, or pass --repo o/r for o/r#42'
  run grep -c '^gh pr edit\|^git fetch' "$LOG"
  assert_output 0
  : >"$LOG"
  echo https://github.com/O/P/ >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 42 --repo o/p --item ship
  assert_success
  assert_line 'item: ship done with pr:o/p#42'
  run grep -E '^gh (pr|run) ' "$LOG"
  refute_output --regexp '^gh (pr [a-z]+ 42|run list) (--[a-z]|$)'
  assert_output --partial 'gh pr merge 42 -R o/p --squash'
}

@test "--repo outside a checkout is refused before any gh call or merge (ar-2371)" {
  touch "$NOTES_FIXTURE/no.checkout"
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --repo o/r --item ship
  assert_failure 2
  assert_output --partial 'is not a usable git checkout (fatal: not a git repository)'
  assert_output --partial 'Run it from a checkout of o/r'
  # only the guard's own probe ran: no gh call, no other git call
  run cat "$LOG"
  assert_output 'git rev-parse --show-toplevel'
  # the repo comes from the item's own pr: when --repo is absent
  : >"$LOG"
  agent-queue set ship pr=o/p#42 >/dev/null
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'Run it from a checkout of o/p'
  # a dry run reads no checkout, so it still prints its steps
  run "$LAND" 42 --repo o/r --item ship --dry-run
  assert_success
}

@test "--repo takes <owner>/<repo> only" {
  run "$LAND" 42 --repo o --item ship
  assert_failure 2
  assert_output --partial '--repo takes <owner>/<repo>, not o'
  run cat "$LOG"
  assert_output ''
}

@test "the item's own pr:<owner>/<repo>#N names the repo for a bare number, and makes a MERGED PR its own" {
  item wait1
  agent-queue set wait1 pr=o/p#42 >/dev/null
  agent-queue move wait1 waiting >/dev/null
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/42 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  touch "$NOTES_FIXTURE/head.foreign"
  run "$LAND" 42 --item wait1
  assert_success
  assert_line 'item: wait1 done with pr:o/p#42'
  run grep -c '^gh pr view 42 -R o/p ' "$LOG"
  refute_output 0
  # From a checkout of the other repo, the item's ref still wins and the run is refused there.
  item wait2
  agent-queue set wait2 pr=o/p#43 >/dev/null
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/r.git >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 43 --item wait2
  assert_failure 1
  assert_output --partial "#43 is o/p#43 (the item's pr:), but this checkout's origin is o/r"
}

@test "an item recording the number in two repos needs --repo" {
  item two
  agent-queue set two 'pr=o/r#42 o/p#42' >/dev/null
  run "$LAND" 42 --item two
  assert_failure 2
  assert_output --partial 'queue item two records #42 in o/p o/r: pass --repo <owner>/<repo>'
}

@test "a --partial landing whose proof fails after the merge keeps the partial marker (ar-2904)" {
  touch "$NOTES_FIXTURE/not.ancestor"
  run "$LAND" 42 --item ship --partial
  assert_failure 1
  assert_output --partial 'proof failed: merge_proof: REFUSING'
  run agent-queue show ship --json
  assert_equal "$(jq -r '.partial // ""' <<<"$output")" yes
}

@test "a merge commit not on origin/<base> is refused: the item stays open and no row closes" {
  item fix 'board:game:fix it' human
  touch "$NOTES_FIXTURE/not.ancestor"
  run "$LAND" 42 --item fix
  assert_failure 1
  assert_output --partial 'proof failed: merge_proof: REFUSING'
  run grep -- '--action land-failed' "$LOG"
  assert_output --partial '--why merged, but proof: merge_proof: REFUSING'
  run grep -c '^notes' <(not_recorded)
  assert_output 0
  run agent-queue show fix --json
  assert_equal "$(jq -r '"\(.state) \(.merged // "-")"' <<<"$output")" 'running -'
}

@test "the item records the proven merge commit" {
  CLAUDE_CODE_SESSION_ID=sid-m run "$LAND" 42 --item ship
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '"\(.state) \(.merged)"' <<<"$output")" 'done fedcba9876543210fedcba9876543210fedcba98'
}

@test "no queue item: refused before any gh or git call, naming how to add one" {
  rm "$AGENT_QUEUE_DIR"/running/*-ship.md
  run "$LAND" 42
  assert_failure 2
  assert_output --partial 'no queue item for this session: agent-queue add --running'
  run cat "$LOG"
  assert_output ''
}

@test "--project and --title are gone: the item is the record" {
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 2
  assert_output --partial '--project is gone'
  run cat "$LOG"
  assert_output ''
}

@test "--sheet is gone" {
  run "$LAND" 42 --item ship --sheet
  assert_failure 2
  assert_output --partial 'unknown flag: --sheet'
}

@test "the PR's changed files credit the item to the game whose path owns the most" {
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n '{paths: {"/x/game": "game"}, trackers: {"arena": {repo: "game", path: "Assets/Arena"},
    "level": {repo: "game", path: "Assets/Level"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  item played
  sed -i 's/^project: dotfiles$/project: game/' "$AGENT_QUEUE_DIR/running/20261103-100000-played.md"
  printf '%s\n' Assets/Arena/A.cs Assets/Arena/B.cs Assets/Level/L.cs Assets/Shared/S.cs >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item played
  assert_success
  assert_line 'item: played done with pr:o/r#42, credited to arena (touches arena level)'
  run agent-queue show played --json
  assert_equal "$(jq -r '"\(.state) \(.project) \(.touches)"' <<<"$output")" 'done arena arena level'
}

@test "a hint gh writes to stderr on success reads into no PR field and no attributed file" {
  # gh 2.105 prints an "event listen" hint on every successful pr view and api call; read with the
  # PR's fields it put "hint:" where the state was and stopped the landing at head (2026-11-19).
  touch "$NOTES_FIXTURE/hint"
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n '{paths: {"/x/game": "game"}, trackers: {"arena": {repo: "game", path: "Assets/Arena"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  item hinted
  sed -i 's/^project: dotfiles$/project: game/' "$AGENT_QUEUE_DIR/running/20261103-100000-hinted.md"
  printf '%s\n' Assets/Arena/A.cs >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item hinted
  assert_success
  assert_line 'item: hinted done with pr:o/r#42, credited to arena (touches arena)'
  assert_line 'landed #42'
  refute_output --partial 'hint:'
}

@test "a diff too big for GitHub to list is read from git (playground #3231)" {
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n '{paths: {"/x/game": "game"}, trackers: {"arena": {repo: "game", path: "Assets/Arena"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  item huge
  sed -i 's/^project: dotfiles$/project: game/' "$AGENT_QUEUE_DIR/running/20261103-100000-huge.md"
  touch "$NOTES_FIXTURE/files.toobig"
  printf 'M\tAssets/Arena/Big.unity\nR087\tdocs/old.md\tdocs/new.md\n' >"$NOTES_FIXTURE/diff.status"
  run "$LAND" 42 --item huge
  assert_success
  assert_line 'item: huge done with pr:o/r#42, credited to arena (touches arena)'
  assert_line 'landed #42'
  run grep -c '^git fetch -q origin 5eedbase5eedbase 0123456789abcdef$' "$LOG"
  assert_output 2  # workflow_gate, then validate_gate after the catch-up
  run grep -c '^git diff --name-status -M 5eedbase5eedbase...0123456789abcdef$' "$LOG"
  assert_output 2
}

@test "files that cannot be read leave the item's project and never fail the landing" {
  item unread
  touch "$NOTES_FIXTURE/files.fail"
  # Already merged: on an open PR unreadable files refuse the merge (validate_gate, its own case).
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item unread
  assert_success
  assert_line 'item: unread done with pr:o/r#42, not credited (gh api: HTTP 502)'
  assert_line 'landed #42'
  run agent-queue show unread --json
  assert_equal "$(jq -r '"\(.state) \(.project)"' <<<"$output")" 'done dotfiles'
}

@test "live: after the merge proof, the stowed checkout of this repo is fast-forwarded in the background and said" {
  printf '~: the pass runs in the background; its result is logged to ~/.cache/dotfiles-autopull/autopull.log\n' >"$NOTES_FIXTURE/autopull.out"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'live: ~: the pass runs in the background; its result is logged to ~/.cache/dotfiles-autopull/autopull.log'
  printf '%s\n' '~/.dotfiles: fast-forwarded main 01234567..fedcba98' '~: rebuilt agent-web (cargo build --release)' >"$NOTES_FIXTURE/autopull.out"
  run "$LAND" 42 --item ship
  assert_line 'live: ~: rebuilt agent-web (cargo build --release)'
  run grep 'pr merge 42\|^dotfiles-autopull' "$LOG"
  assert_line --index 0 --partial 'pr merge 42'
  assert_line --index 1 'dotfiles-autopull --now . --bg'
}

@test "live: a repo that is not a stowed checkout gets no line" {
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'live:'
  assert_line 'landed #42'
}

@test "live: a failing autopull never fails the landing" {
  printf '1\n' >"$NOTES_FIXTURE/autopull.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
  DOTFILES_AUTOPULL="$SANDBOX/no-such-autopull" run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
}

@test "prs: after the merge the PR store refreshes that repo; a failed refresh is said and never fails the landing, an unlisted repo is said and filed once" {
  run "$LAND" 42 --item ship
  assert_success
  run grep '^schedules-sync' "$LOG"
  assert_output 'schedules-sync sync-prs o/r'
  printf '1\n' >"$NOTES_FIXTURE/ss.rc"; echo 'o/r: HTTP 502' >"$NOTES_FIXTURE/ss.err"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'prs: o/r not refreshed (o/r: HTTP 502); its next poll reads the merge'
  assert_line 'landed #42'
  printf '3\n' >"$NOTES_FIXTURE/ss.rc"
  : >"$LOG"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --partial 'prs: o/r is in no schedules-sync repos list'
  assert_line 'prs: filed on the agent-runtime outbox'
  assert_line 'landed #42'
  run grep -c '^notes ptask agent-runtime --agent add --why runtime-fault fix(ledger): o/r is in no schedules-sync repos list' "$LOG"
  assert_output 1
  printf '3\n' >"$NOTES_FIXTURE/ptask.agent.add.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'prs: a like row is already open on agent-runtime'
  printf '5\n' >"$NOTES_FIXTURE/ptask.agent.add.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --partial 'prs: not filed, notes wants its shortlist read first: notes ptask agent-runtime --agent add --why runtime-fault --checked <ids>'
  printf '1\n' >"$NOTES_FIXTURE/ptask.agent.add.rc"; echo 'board locked' >"$NOTES_FIXTURE/ptask.agent.added"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'prs: could not file it on agent-runtime (board locked)'
  assert_line 'landed #42'
}

# aq_add_stub: the sandbox agent-queue logs each add's argv to aq.add, one call a line, and answers as the real one
# does for a slug it already holds ("already in the queue", exit 1) or $SANDBOX/aq.add.rc says, and logs the
# AGENT_QUEUE_ITEM each add saw to aq.env; other verbs run for real.
aq_add_stub() {
  mv "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-queue.real"
  cat >"$SANDBOX/bin/agent-queue" <<EOS
#!/usr/bin/env bash
if [ "\$1" = add ]; then
  slug=\$(printf '%s\n' "\$@" | grep -A1 -x -- --slug | tail -1)
  ! grep -qxF "\$slug" "$SANDBOX/aq.slugs" 2>/dev/null || { echo "agent-queue: already in the queue: \$slug" >&2; exit 1; }
  printf '%s\n' "\${*%%\$'\n'*}" >>"$SANDBOX/aq.add"
  printf '%s\n' "\${AGENT_QUEUE_ITEM:-}" >>"$SANDBOX/aq.env"
  rc=\$(cat "$SANDBOX/aq.add.rc" 2>/dev/null || echo 0)
  [ "\$rc" -ne 0 ] || echo "\$slug" >>"$SANDBOX/aq.slugs"
  [ "\$rc" -ne 1 ] || echo "agent-queue: store locked" >&2
  exit "\$rc"
fi
exec "$SANDBOX/bin/agent-queue.real" "\$@"
EOS
  chmod +x "$SANDBOX/bin/agent-queue"
}

# ar-4887: #3249 left `notes projects --migrate unity-core-playground` in a sentence for after its deploy, and nobody ran it.
@test "deploy: each After deploy: line of the merged body is added as its own item, once; a failed add never fails the landing (ar-4887)" {
  local s1 s2
  s1=after-deploy-42-$(printf '%s' 'notes projects --migrate game' | sha1sum | cut -c1-7)-r
  s2=after-deploy-42-$(printf '%s' 'systemctl --user restart notes-web' | sha1sum | cut -c1-7)-r
  aq_add_stub
  # NEGATIVE CONTROL: a step said in a sentence (#3249's form), a fenced or quoted line, and a placeholder add nothing
  printf '%s\n' 'The change.' '' 'After the new binary is deployed, run notes projects --migrate game.' '```' 'After deploy: <command>' '```' \
    '> After deploy: quoted' 'After deploy: <command>' 'After deploy: none' '' 'Item: ship' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'deploy:'
  [ ! -e "$SANDBOX/aq.add" ]
  printf 'The change.\n\nAfter deploy: notes projects --migrate game\r\nAfter deploy:   systemctl --user restart notes-web  \n\nItem: ship\n' >"$NOTES_FIXTURE/body"
  AGENT_QUEUE_ITEM=ship run "$LAND" 42
  assert_success
  assert_line "deploy: added $s1: notes projects --migrate game"
  assert_line "deploy: added $s2: systemctl --user restart notes-web"
  assert_line 'landed #42'
  run cat "$SANDBOX/aq.add"
  assert_line --index 0 "add --project dotfiles --priority high --from item:ship --slug $s1 chore(deploy): notes projects --migrate game (left by o/r#42)"
  assert_line --index 1 "add --project dotfiles --priority high --from item:ship --slug $s2 chore(deploy): systemctl --user restart notes-web (left by o/r#42)"
  # the add does not run as the landed item, so that item's own after: never gates it
  run grep -c '^$' "$SANDBOX/aq.env"
  assert_output 2
  # a re-run of the landing adds neither again, though a step was put above them meanwhile
  printf 'The change.\n\nAfter deploy: systemctl --user restart notes-web\nAfter deploy: notes projects --migrate game\n\nItem: ship\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  assert_line "deploy: $s1 already queued: notes projects --migrate game"
  assert_line "deploy: $s2 already queued: systemctl --user restart notes-web"
  run grep -c . "$SANDBOX/aq.add"
  assert_output 2
  # a full queue files the step on the board, and that is said
  : >"$SANDBOX/aq.slugs"; echo 5 >"$SANDBOX/aq.add.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line "deploy: $s2 filed on the dotfiles board, the queue takes it from there: systemctl --user restart notes-web"
  # an add that fails is said with the add to run by hand, and the landing stands
  : >"$SANDBOX/aq.slugs"; echo 1 >"$SANDBOX/aq.add.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --partial "deploy: not added (agent-queue: store locked): agent-queue add --project dotfiles --priority high --from item:ship --slug $s1"
  assert_line 'landed #42'
}

# ar-5861: home-config merged 23 ansible role changes that reached no host until ConvergenceDrift fired on five.
@test "after-merge: a step the repo's after-merge file names for a changed path is added once; one still queued carries the next merge (ar-5861)" {
  local step='apply ansible to the drifted hosts' sha s
  sha=$(printf '%s' "$step" | sha1sum | cut -c1-7)
  s=after-merge-$sha-42-r
  printf '%s\n' '# a comment' '' "ansible/roles/,ansible/inventory.yml $step" 'docs/ never this one' 'lonely/' >"$NOTES_FIXTURE/after-merge"
  aq_add_stub
  # NEGATIVE CONTROL: a file outside every named path, or only a name's prefix, adds nothing
  printf '%s\n' ansible/README.md ansible/inventory.yml.bak apps/x.yaml >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'after-merge: added'
  [ ! -e "$SANDBOX/aq.add" ]
  printf '%s\n' apps/x.yaml ansible/roles/ci-host/tasks/main.yml ansible/inventory.yml >"$NOTES_FIXTURE/files"
  # another project's queued item for the same step text does not carry this repo's merge
  "$SANDBOX/bin/agent-queue.real" add --project other --slug "after-merge-$sha-40-other" 'chore(after-merge): theirs' >/dev/null
  run "$LAND" 42 --item ship
  assert_success
  assert_line "after-merge: added $s: $step"
  assert_line "after-merge: .agent-land/after-merge line 'lonely/' names no step, skipped"
  assert_line 'landed #42'
  run cat "$SANDBOX/aq.add"
  assert_output "add --project r --priority high --from item:ship --slug $s chore(after-merge): $step (left by o/r#42)"
  # a step whose item from an earlier merge is still queued is not added again: it applies the base it starts on
  "$SANDBOX/bin/agent-queue.real" add --project r --slug "after-merge-$sha-41-r" 'chore(after-merge): earlier' >/dev/null
  run "$LAND" 42 --item ship
  assert_success
  assert_line "after-merge: after-merge-$sha-41-r is still queued and carries #42 too: $step"
  run grep -c . "$SANDBOX/aq.add"
  assert_output 1
}

@test "partial landing holds after items and the board until the other repo lands" {
  legacy next "after: ship" --project dotfiles 'next phase'
  : >"$LOG"
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line 'board: left open until the final landing'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged] | join(" ")' <<<"$output")" 'running yes o/r#42 fedcba9876543210fedcba9876543210fedcba98'
  run agent-queue show next --json
  assert_equal "$(jq -r .hold <<<"$output")" 'after ship'
  run agent-queue next --json
  refute_output --partial '"slug":"next"'
  [ -z "$(board_calls)" ] || fail 'partial landing closed the row'
  # Repeating the first landing keeps one PR and never releases its dependents.
  run "$LAND" 42 --item ship --partial
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r .pr <<<"$output")" o/r#42
  # The final PR comes from another checkout/repo and closes the one item.
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$NOTES_FIXTURE/merge.oid"
  run "$LAND" 43 --item ship --plan "$PLAN" --phase '6. agent-land'
  assert_success
  assert_line 'plan: ticked "6. agent-land"'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged] | join("|")' <<<"$output")" 'done||o/r#42 o/p#43|fedcba9876543210fedcba9876543210fedcba98 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  run agent-queue show next --json
  assert_equal "$(jq -r '.hold // ""' <<<"$output")" ''
  run board_calls
  assert_output --partial 'done ship it --proof pr:o/p#43'
}

@test "an earlier PR recorded with no merge takes its merge commit from gh, so this PR is recorded beside it" {
  # NEGATIVE CONTROL: before ar-781 this merged #42, then failed "no merge recorded for o/p#1794"
  # and left #42 off the item (private #762, 2026-11-11).
  agent-queue set ship pr=o/p#1794 >/dev/null
  echo '{"state":"MERGED","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}}' >"$NOTES_FIXTURE/prior.json"
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line 'item: ship partial with pr:o/r#42, left open for the final landing'
  run grep -c '^gh pr view 1794 -R o/p --json state,mergeCommit -q .mergeCommit.oid // .state$' "$LOG"
  assert_output 1
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged] | join("|")' <<<"$output")" \
    'running|yes|o/p#1794 o/r#42|abcdef0123456789abcdef0123456789abcdef01 fedcba9876543210fedcba9876543210fedcba98'
}

@test "an earlier PR that is not merged refuses a final landing before the merge, leaving the PR and item untouched" {
  agent-queue set ship pr=o/p#1794 >/dev/null
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'queue item ship records o/p#1794, which is OPEN: land it first (agent-land 1794 --repo o/p --item ship --partial), then #42'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .pr, (.merged // ""), (.partial // "")] | join("|")' <<<"$output")" 'running|o/p#1794||'
}

@test "an open PR in another repo whose body names the item refuses a full landing before the merge; --partial lands" {
  # NEGATIVE CONTROL: before ar-2665 this merged #42 and closed ship while o/p#43, naming it, was still open,
  # so every item held after: ship started early (ar-2653: .dotfiles#2278 and .dotfiles-private#949, 2026-11-17).
  legacy next "after: ship" --project dotfiles 'next phase'
  printf '%s' '[{"number":43,"repository":{"nameWithOwner":"o/p"},"body":"Work.\r\nItem: ship\r\n"},{"number":42,"repository":{"nameWithOwner":"o/r"},"body":"Item: ship"}]' >"$NOTES_FIXTURE/search.json"
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'o/p#43 is open and names ship, which a full landing would close: land #42 --partial (agent-land 42 --item ship --partial), then o/p#43 with the full flags (agent-land 43 --repo o/p --item ship)'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, (.pr // ""), (.partial // "")] | join("|")' <<<"$output")" 'running||'
  # --partial is the split's first landing: it does not search, and leaves ship open, holding next.
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line 'item: ship partial with pr:o/r#42, left open for the final landing'
  run grep -c '^gh search prs' "$LOG"
  assert_output 1
  run agent-queue show next --json
  assert_equal "$(jq -r .hold <<<"$output")" 'after ship'
}

@test "the split search counts only an open PR whose first Item: line is this item, never this PR itself" {
  # A slug that only starts with ship, an Item: line after another, a body with none, and #42 itself.
  printf '%s' '[{"number":7,"repository":{"nameWithOwner":"o/p"},"body":"Item: ship-two"},{"number":8,"repository":{"nameWithOwner":"o/p"},"body":"Item: other\nItem: ship"},{"number":9,"repository":{"nameWithOwner":"o/p"},"body":null},{"number":42,"repository":{"nameWithOwner":"O/R"},"body":"Item: ship"}]' >"$NOTES_FIXTURE/search.json"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'item: ship done with pr:o/r#42'
}

@test "a failed split search refuses the full landing with nothing touched" {
  touch "$NOTES_FIXTURE/search.fail"
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'split: gh search prs for open PRs naming ship failed, nothing touched: gh: API rate limit exceeded (HTTP 403); re-run'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
}

@test "an item whose pr: lists two open PRs lands one --partial, then the other closes it with both merges" {
  # NEGATIVE CONTROL: before ar-1267 the --partial landing refused "o/p#43, which is OPEN: land it first
  # (... --partial)", and so did the other, so neither could land (ar-314, 2026-11-09).
  agent-queue set ship 'pr=o/r#42 o/p#43' >/dev/null
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line --partial 'item: ship partial with pr:o/r#42'
  assert_line --partial '; merged: waits for o/p#43, still open, left open for the final landing'
  # merged: cannot list #42 beside an open #43 and stay in step, so it waits empty for the final landing.
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, (.merged // "")] | join("|")' <<<"$output")" 'running|yes|o/r#42 o/p#43|'
  [ -z "$(board_calls)" ] || fail 'partial landing closed the row'
  # A re-run of the partial landing (now MERGED) leaves the same record.
  run "$LAND" 42 --item ship --partial
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, (.merged // "")] | join("|")' <<<"$output")" 'running|yes|o/r#42 o/p#43|'
  # The final landing reads #42's merge from gh and records both, in step.
  echo '{"state":"MERGED","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}}' >"$NOTES_FIXTURE/prior.json"
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$NOTES_FIXTURE/merge.oid"
  run "$LAND" 43 --item ship
  assert_success
  assert_line 'landed #43'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, (.partial // ""), .pr, .merged, .closing_pr] | join("|")' <<<"$output")" \
    'done||o/r#42 o/p#43|abcdef0123456789abcdef0123456789abcdef01 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|o/p#43'
  run board_calls
  assert_output --partial 'done ship it --proof pr:o/p#43'
}

@test "an earlier PR closed unmerged, or lists out of step, refuse before the merge with the way out" {
  agent-queue set ship pr=o/p#1794 >/dev/null
  echo '{"state":"CLOSED","mergeCommit":null}' >"$NOTES_FIXTURE/prior.json"
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'queue item ship records o/p#1794, closed unmerged: drop it from'
  agent-queue set ship 'pr=o/p#1794 o/q#7' merged=abcdef0123456789abcdef0123456789abcdef01 >/dev/null
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'out of step'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
}

@test "partial protects an already merged PR and refuses a finished item or plan phase" {
  echo MERGED >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item ship --partial
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '.state + " " + .partial' <<<"$output")" 'running yes'
  run "$LAND" 42 --item ship --partial --plan "$PLAN" --phase '6. agent-land'
  assert_failure 2
  run "$LAND" 42 --item ship
  assert_success
  run "$LAND" 42 --item ship --partial
  assert_failure 2
  assert_output --partial 'already done'
}

@test "partial dry run describes keeping the item and row open" {
  run "$LAND" 42 --item ship --partial --dry-run
  assert_success
  assert_output --partial 'partial=yes once #42 is merged'
  assert_output --partial 'board: left open until the final landing'
  refute_output --partial 'move ship done'
  refute_output --partial 'board: notes'
  refute_output --partial 'split:'
}

@test "the final second PR retries a failed board step after a partial first landing" {
  run "$LAND" 42 --item ship --partial
  assert_success
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  cp "$SANDBOX/bin/notes" "$SANDBOX/bin/notes-working"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$SANDBOX/bin/notes"
  run "$LAND" 43 --item ship
  assert_failure 1
  assert_output --partial 'board failed:'
  run agent-queue show ship --json
  assert_equal "$(jq -r '.state + " " + .closing_pr' <<<"$output")" 'done o/p#43'
  cp "$SANDBOX/bin/notes-working" "$SANDBOX/bin/notes"
  run "$LAND" 43 --item ship
  assert_success
  assert_output --partial 'board: closed "ship it" with pr:o/p#43'
}

@test "a brief with two PRs in one repo lands both on its one item: the first --partial, the second closes it" {
  # NEGATIVE CONTROL: before ar-2044 the second PR was refused as "an item carries one PR per repo",
  # so release-windows-only filed ucp-1987 for #2397 (2026-11-12).
  run "$LAND" 42 --item ship --partial
  assert_success
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$NOTES_FIXTURE/merge.oid"
  run "$LAND" 43 --item ship
  assert_success
  assert_line 'landed #43'
  assert_output --partial 'board: closed "ship it" with pr:o/r#43'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged, .closing_pr] | join("|")' <<<"$output")" \
    'done||o/r#42 o/r#43|fedcba9876543210fedcba9876543210fedcba98 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|o/r#43'
  # Once done, the rule holds again: a third PR in o/r is a second task.
  echo https://github.com/o/r/pull/44 >"$NOTES_FIXTURE/url"
  run "$LAND" 44 --item ship
  assert_failure 2
  assert_output --partial 'an item carries one PR per repo'
}

@test "an open item not marked partial still refuses a second PR in a repo it carries" {
  agent-queue set ship pr=o/r#42 merged=fedcba9876543210fedcba9876543210fedcba98 >/dev/null
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  run "$LAND" 43 --item ship
  assert_failure 2
  assert_output --partial 'an item carries one PR per repo'
  assert_output --partial 'queue item ship is open and already carries o/r#42'
  assert_output --partial 'agent-queue set ship partial=yes and re-run'
  run grep -e '^gh pr merge' -e '^gh pr edit' "$LOG"
  assert_failure
  # The way out the refusal names lands it beside #42 and closes the item.
  agent-queue set ship partial=yes >/dev/null
  run "$LAND" 43 --item ship
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .pr] | join("|")' <<<"$output")" 'done|o/r#42 o/r#43'
}

@test "--dry-run refuses a second PR in one repo on an open or done item like the real run" {
  agent-queue set ship pr=o/r#42 merged=fedcba9876543210fedcba9876543210fedcba98 >/dev/null
  run "$LAND" 43 --item ship --dry-run
  assert_failure 2
  assert_output --partial 'queue item ship is open and already carries o/r#42, and an item carries one PR per repo'
  assert_output --partial 'agent-queue set ship partial=yes and re-run'
  run grep -c '^gh ' "$LOG"
  assert_output 0

  # --partial, partial=yes, or another repo (--repo o/p) passes --dry-run.
  run "$LAND" 43 --item ship --partial --dry-run
  assert_success
  run "$LAND" 43 --item ship --repo o/p --dry-run
  assert_success
  agent-queue set ship partial=yes >/dev/null
  run "$LAND" 43 --item ship --dry-run
  assert_success
  agent-queue set ship partial= >/dev/null

  # A done item also refuses a second PR in the same repo on --dry-run.
  agent-queue move ship done --status ok >/dev/null
  run "$LAND" 43 --item ship --dry-run
  assert_failure 2
  assert_output --partial 'queue item ship is done and already carries o/r#42, and an item carries one PR per repo'
}

@test "a PR on a Forgejo origin (bnb-game-servers): merged through the API pinned to HEAD, recorded on the item, no gh" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'item-line: added "Item: ship" to the body'
  assert_line 'checks: green'
  assert_line 'merge: #42 MERGED at 01234567'
  assert_line 'item: ship done with pr:o/r#42'
  assert_line --index -1 'landed #42'
  run grep -c '^gh ' "$LOG"
  assert_output 0
  run grep -c '^curl POST pulls/42/merge {"Do":"squash","head_commit_id":"0123456789abcdef"}$' "$LOG"
  assert_output 1
  run grep -c '^git -C . fetch -q origin +refs/heads/main:refs/remotes/origin/main$' "$LOG"
  assert_output 1
  run grep -c '^curl GET pulls/42/files?limit=50&page=1$' "$LOG"
  assert_output 1
  run agent-queue show ship --json
  assert_output --partial '"pr":"o/r#42"'
  assert_output --partial '"merged":"fedcba9876543210fedcba9876543210fedcba98"'
  assert_output --partial '"state":"done"'
}

@test "prs: a Forgejo PR's store is named by the project map's forges.forgejo host, not the html_url host (ar-4530)" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  printf '{"forges":{"forgejo":"store.example"}}\n' >"$SANDBOX/map.json"
  SO_PROJECT_MAP="$SANDBOX/map.json" run "$LAND" 42 --item ship
  assert_success
  run grep '^schedules-sync' "$LOG"
  assert_output 'schedules-sync sync-prs store.example/o/r'
}

@test "prs: a Forgejo PR with no readable project map keeps the html_url host (ar-4530)" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  printf 'not json\n' >"$SANDBOX/map.json"
  SO_PROJECT_MAP="$SANDBOX/map.json" run "$LAND" 42 --item ship
  assert_success
  run grep '^schedules-sync' "$LOG"
  assert_output 'schedules-sync sync-prs forgejo.example/o/r'
  : >"$LOG"
  SO_PROJECT_MAP="$SANDBOX/none.json" run "$LAND" 42 --item ship
  run grep '^schedules-sync' "$LOG"
  assert_output 'schedules-sync sync-prs forgejo.example/o/r'
}

@test "a Forgejo-canonical checkout (home-config): its forgejo remote, not the GitHub origin, carries every git step" {
  forgejo
  mkdir -p "$SANDBOX/hc/.forgejo/workflows"
  : >"$SANDBOX/hc/.forgejo/workflows/mirror-to-github.yaml"
  printf '%s\n' "$SANDBOX/hc" >"$NOTES_FIXTURE/toplevel"
  printf 'forgejo\norigin\n' >"$NOTES_FIXTURE/remotes"
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/forgejo.url"
  printf '1\n0\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship --merge-commit
  assert_success
  assert_line 'fetch: merged forgejo/main (1 behind) into the head and pushed it'
  assert_line 'proof: evidence commit 0123456789abcdef is an ancestor of forgejo/main'
  run grep -c '^gh \|origin' "$LOG"
  assert_output 0
  run grep -c '^git push -q forgejo HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
  run grep -c '"Do":"merge"' "$LOG"
  assert_output 1
}

@test "a Forgejo check that failed stops at checks, naming it; nothing merged" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo '{"statuses":[{"status":"success","context":"lint"},{"status":"failure","context":"checks / test"}]}' >"$NOTES_FIXTURE/fj.status"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: checks / test'
  run grep -c 'pulls/42/merge' "$LOG"
  assert_output 0
}

@test "a Forgejo status read that loses its connection reads again and lands" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  : >"$NOTES_FIXTURE/fj.status.reset"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'checks: lost the connection to the API (1 of 5 retries), reading again'
  run grep -c 'POST pulls/42/merge' "$LOG"
  assert_output 1
}

@test "a Forgejo status read the bouncer refuses (a plain Forbidden) is sent again, and again after its tries run out, then lands" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo 6 >"$NOTES_FIXTURE/fj.status.gate"
  SO_FORGEJO_GATE_WAIT=0 AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'checks: lost the connection to the API (1 of 5 retries), reading again'
  assert_line 'checks: green'
  run grep -c 'POST pulls/42/merge' "$LOG"
  assert_output 1
}

@test "a Forgejo status read the bouncer refuses every time stops at checks naming the proxy; nothing merged" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo 999 >"$NOTES_FIXTURE/fj.status.gate"
  SO_FORGEJO_GATE_WAIT=0 AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'lost the connection to the API 6 times: forgejo.example: the proxy in front of Forgejo refused'
  run grep -c 'pulls/42/merge' "$LOG"
  assert_output 0
}

@test "a Forgejo base whose protection rule requires statuses refuses a head with none; with no rule it lands" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo '{"statuses":[]}' >"$NOTES_FIXTURE/fj.status"
  export AGENT_LAND_CHECKS_TRIES=1 AGENT_LAND_CHECKS_POLL=0
  echo '[{"rule_name":"main","enable_status_check":true,"block_on_outdated_branch":false}]' >"$NOTES_FIXTURE/fj.protections"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'origin/main requires checks, so Forgejo would refuse the merge'
  run grep -c 'pulls/42/merge' "$LOG"
  assert_output 0
  echo '[{"rule_name":"release","enable_status_check":true}]' >"$NOTES_FIXTURE/fj.protections"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: none reported'
}

@test "a Forgejo merge refusal ends with Forgejo's reason, not only curl's status line" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo '{"message":"Please try again later","url":"https://forgejo.example/api/swagger"}' >"$NOTES_FIXTURE/fj.refuse"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'Forgejo: Please try again later'
}

@test "a body edit the proxy's bouncer refuses (a plain Forbidden, not Forgejo's) is sent again and lands" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo 2 >"$NOTES_FIXTURE/fj.gate"
  SO_FORGEJO_GATE_WAIT=0 run "$LAND" 42 --item ship
  assert_success
  assert_line 'item-line: added "Item: ship" to the body'
  assert_line --index -1 'landed #42'
  run grep -c '^curl PATCH pulls/42 ' "$LOG"
  assert_output 3
}

@test "a body edit the bouncer refuses every time fails at item-line naming the proxy, not Forgejo; nothing merged" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo 9 >"$NOTES_FIXTURE/fj.gate"
  SO_FORGEJO_GATE_WAIT=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'item-line failed: Forgejo pr edit: forgejo.example: the proxy in front of Forgejo refused pulls/42 4 times with a plain-text 403 "Forbidden", not Forgejo'"'"'s'
  refute_output --partial 'curl: (22)'
  refute_output --partial 'Forgejo: Forbidden'
  run grep -c '^curl PATCH pulls/42 ' "$LOG"
  assert_output 4
  run grep -c 'pulls/42/merge' "$LOG"
  assert_output 0
}

@test "a Forgejo dry run reads no token and calls nothing" {
  forgejo
  printf '#!/usr/bin/env bash\nexit 1\n' >"$SANDBOX/bin/rbw"
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 42 --item ship --dry-run
  assert_success
  assert_line --partial 'forge: Forgejo forgejo.example/o/r on remote origin'
  run grep -c '^curl ' "$LOG"
  assert_output 0
}

@test "a Forgejo-canonical checkout with no remote on a listed host stops before anything, never falling back to gh" {
  forgejo
  export SO_FORGEJO_HOSTS=elsewhere.example
  mkdir -p "$SANDBOX/hc/.forgejo/workflows"
  : >"$SANDBOX/hc/.forgejo/workflows/mirror-to-github.yaml"
  printf '%s\n' "$SANDBOX/hc" >"$NOTES_FIXTURE/toplevel"
  run "$LAND" 42 --item ship
  assert_failure 2
  assert_output --partial 'is Forgejo-canonical, but none of its remotes is on a host SO_FORGEJO_HOSTS lists'
  run grep -c '^gh \|^curl ' "$LOG"
  assert_output 0
}

@test "a lock timeout on the item step is retried: the item still gets the PR and moves to done" {
  item tidy-loader
  lock_busy set 2
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_output --partial 'item: tidy-loader done with pr:o/r#42'
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.pr)"' <<<"$output")" 'done o/r#42'
}

@test "a lock that stays busy past every try fails the item step, naming the lock" {
  item tidy-loader
  lock_busy set 9
  AGENT_LAND_QUEUE_TRIES=3 run "$LAND" 42 --item tidy-loader
  assert_failure 1
  assert_output --partial 'item failed: agent-queue: the queue is locked by another writer'
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r .state <<<"$output")" running
}

@test "a busy lock on the move to done after the merge names the re-run, and the re-run closes the item (ar-3089)" {
  item tidy-loader
  lock_busy move 9
  AGENT_LAND_QUEUE_TRIES=3 run "$LAND" 42 --item tidy-loader
  assert_failure 1
  assert_output --partial 'item failed: agent-queue: the queue is locked by another writer; #42 is merged and only its record is left: re-run agent-land 42 --item tidy-loader to finish it'
  run grep -c -- '--why merged, but item: .*only its record is left' "$LOG"
  assert_output 1
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.closing_pr)"' <<<"$output")" 'running o/r#42'
  echo 0 >"$SANDBOX/busy.n"
  run "$LAND" 42 --item tidy-loader
  assert_success
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r .state <<<"$output")" done
}

@test "a failure before the merge names no re-run of a merged PR (negative control)" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  refute_output --partial 'only its record is left'
}

@test "a lock timeout on the pre-merge item read is retried" {
  item tidy-loader
  lock_busy show 2
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_output --partial 'item: tidy-loader done with pr:o/r#42'
}

@test "a pre-merge item read whose lock never clears says so, and nothing merges" {
  item second
  lock_busy show 9
  run "$LAND" 42 --item second
  assert_failure 2
  assert_output --partial 'the queue is locked by another writer: nothing merged'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "--plan on a pointer stub ticks the canonical plan, and the stub's own line beside it (ar-2513)" {
  printf '%s\n' '## Phases' '' '- [x] 1. first (#1)' '- [ ] 2. gate-then-land' '- [ ] 3. last' >"$SANDBOX/canon.md"
  printf '%s\n' "Phase 2 of $SANDBOX/canon.md" '' '## Phases' '' '- [ ] 2. gate-then-land' >"$SANDBOX/stub.md"
  run "$LAND" 42 --item ship --plan "$SANDBOX/stub.md" --phase "2. gate-then-land"
  assert_success
  assert_line "plan: $SANDBOX/stub.md is a pointer stub; its phases are in $SANDBOX/canon.md"
  run cat "$SANDBOX/canon.md"
  assert_output - <<'EOF2'
## Phases

- [x] 1. first (#1)
- [x] 2. gate-then-land (#42)
- [ ] 3. last
EOF2
  run grep -c '^- \[x\] 2. gate-then-land (#42)$' "$SANDBOX/stub.md"
  assert_output 1
  # negative control: a phase the canonical plan lacks is refused, whatever the stub says
  printf '%s\n' "Phase 2 of $SANDBOX/canon.md" '' '## Phases' '' '- [ ] 9. nope' >"$SANDBOX/stub.md"
  run "$LAND" 42 --item ship --plan "$SANDBOX/stub.md" --phase "9. nope"
  assert_failure
  assert_output --partial "plan: 0 unchecked lines"
}

@test "an item stacked on a dependency that has not closed ok is refused with exit 4: nothing merged, the open PR recorded on it (ar-3852)" {
  item base
  item tidy-loader
  agent-queue set tidy-loader after=base
  CLAUDE_CODE_SESSION_ID=sid-l run "$LAND" 42 --item tidy-loader
  assert_failure 4
  assert_output --partial 'is stacked on base'
  run grep -c 'pr merge\|pr checks' "$LOG"
  assert_output 0
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.open_pr)"' <<<"$output")" 'running o/r#42'
  # NEGATIVE CONTROL: once the dependency closed ok the same landing goes through and clears open_pr.
  agent-queue move base done --status ok
  CLAUDE_CODE_SESSION_ID=sid-l run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line 'landed #42'
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr) \(.open_pr // "")"' <<<"$output")" 'done ok o/r#42 '
}

@test "an item stacked on a dependency that closed unmerged is refused too, never merged" {
  item base
  item tidy-loader
  agent-queue set tidy-loader after=base
  agent-queue move base done --status failed
  run "$LAND" 42 --item tidy-loader
  assert_failure 4
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a --partial landing keeps the item's open_pr: its other PRs are still open (ar-3852)" {
  item tidy-loader
  agent-queue set tidy-loader open_pr=o/r#9
  run "$LAND" 42 --item tidy-loader --partial
  assert_success
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '.open_pr // "gone"' <<<"$output")" 'o/r#42'
}

@test "a partial landing on an item another session owns records the PR without claiming the item (ar-3368)" {
  item ship
  agent-queue claim ship --sid sid-owner >/dev/null
  run agent-queue show ship --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-owner'

  # A partial landing from a different session records the PR but does not claim the item.
  CLAUDE_CODE_SESSION_ID=sid-lander run "$LAND" 42 --item ship --partial
  assert_success
  assert_line --partial 'item: ship partial with pr:o/r#42'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .sessions] | join("|")' <<<"$output")" 'running|yes|o/r#42|sid-owner'
  # It still landed #42, so landed_by names it (ar-2779).
  assert_equal "$(jq -r .landed_by <<<"$output")" 'sid-lander=o/r#42'

  # Negative control: landing without --partial claims the item on its final landing.
  echo '{"state":"MERGED","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}}' >"$NOTES_FIXTURE/prior.json"
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  CLAUDE_CODE_SESSION_ID=sid-lander run "$LAND" 43 --item ship
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .sessions, .landed_by] | join("|")' <<<"$output")" 'done|sid-owner sid-lander|sid-lander=o/r#42 sid-lander=o/p#43'
}

@test "a partial landing on an item owned via tmux session does not claim the item (ar-3368)" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item foreign
  agent-queue set foreign session=lab:foreign-sess >/dev/null
  agent-queue claim foreign --sid sid-old >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-lander run "$LAND" 42 --item foreign --partial
  assert_success
  assert_line --partial 'item: foreign partial with pr:o/r#42'
  run agent-queue show foreign --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .sessions] | join("|")' <<<"$output")" 'running|yes|o/r#42|sid-old'
}

@test "a partial landing from the item's own tmux session under a new id claims it, as does one with no tmux to compare (ar-3368)" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item resumed
  agent-queue set resumed session=default:dotfiles-agent-9 >/dev/null
  agent-queue claim resumed --sid sid-old >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-new run "$LAND" 42 --item resumed --partial
  assert_success
  run agent-queue show resumed --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-old sid-new'

  unset TMUX
  item headless
  agent-queue set headless session=lab:somewhere >/dev/null
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  CLAUDE_CODE_SESSION_ID=sid-new run "$LAND" 43 --item headless --partial
  assert_success
  run agent-queue show headless --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-new'
}

@test "a red watch item cannot close ok while its watch's probe still trips; re-running once it clears closes it (ar-1605)" {
  cat >"$SANDBOX/bin/watch-companion-loop" <<'EOF'
#!/usr/bin/env bash
printf 'watch-companion-loop %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
rc=$(cat "$NOTES_FIXTURE/watch.rc" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] || echo "TRIP: spend still over limit"
exit "$rc"
EOF
  chmod +x "$SANDBOX/bin/watch-companion-loop"

  cat >"$AGENT_QUEUE_DIR/running/20261103-100000-red-spend.md" <<'EOF'
slug: red-spend
project: dotfiles
mode: oneshot
priority: urgent
from: fleet-bench
agent: claude
tags: red watch cause:ab12
row: dotfiles:ship red
queued: 2026-11-03T10:00:00Z
started: 2026-11-03T10:00:00Z
---
check(watch): spend tripped since 2026-11-20, expected: spend under cap
EOF

  printf '1\n' >"$NOTES_FIXTURE/watch.rc"
  run "$LAND" 42 --item red-spend
  assert_failure 1
  assert_output --partial "item failed: watch spend did not read OK on resolve (exit 1): TRIP: spend still over limit; #42 is merged and only its record is left: re-run agent-land 42 --item red-spend to finish it"
  # The PR merged and was recorded on the item, but the item and its board row stayed open.
  run agent-queue show red-spend --json
  assert_equal "$(jq -r '[.state, .pr, .merged] | join("|")' <<<"$output")" 'running|o/r#42|fedcba9876543210fedcba9876543210fedcba98'
  [ "$(grep -c '^notes.*done' "$LOG")" -eq 0 ]
  # The probe ran after autopull.
  [ "$(grep -n 'dotfiles-autopull' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'watch-companion-loop resolve spend --pr o/r#42' "$LOG" | cut -d: -f1)" ]

  # Once the probe clears, re-running agent-land finishes closing the item and its board row.
  printf '0\n' >"$NOTES_FIXTURE/watch.rc"
  run "$LAND" 42 --item red-spend
  assert_success
  assert_line 'watch: spend OK'
  assert_line --partial 'board: closed "ship red"'
  assert_line 'landed #42'
  run agent-queue show red-spend --json
  assert_equal "$(jq -r '[.state, .status] | join("|")' <<<"$output")" 'done|ok'
}

@test "a red watch item routed to its owner lands while the watch trips, and its PR still resolves the watch (ar-5414)" {
  cat >"$SANDBOX/bin/watch-companion-loop" <<'EOF'
#!/usr/bin/env bash
printf 'watch-companion-loop %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
echo "TRIP: spend still over limit"
exit 1
EOF
  cat >"$SANDBOX/bin/fleet-bench" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "triage --route" ] || exit 2
printf '%s\towned:ar-1\t-\t\n' "$3"
EOF
  chmod +x "$SANDBOX/bin/watch-companion-loop" "$SANDBOX/bin/fleet-bench"

  cat >"$AGENT_QUEUE_DIR/running/20261103-100000-red-spend.md" <<'EOF'
slug: red-spend
project: dotfiles
mode: oneshot
priority: urgent
from: fleet-bench
agent: claude
tags: red watch cause:ab12
row: dotfiles:ship red
queued: 2026-11-03T10:00:00Z
started: 2026-11-03T10:00:00Z
---
check(watch): spend tripped since 2026-11-20, expected: spend under cap
EOF

  run "$LAND" 42 --item red-spend
  assert_success
  assert_line 'watch spend routes to owned:ar-1, so its close is not probed'
  assert_line 'landed #42'
  # The merge is recorded as the fix watermark, and nothing else probes the watch.
  [ "$(grep -c '^watch-companion-loop ' "$LOG")" -eq 1 ]
  grep -q '^watch-companion-loop resolve spend --pr o/r#42$' "$LOG"
  run agent-queue show red-spend --json
  assert_equal "$(jq -r '[.state, .status] | join("|")' <<<"$output")" 'done|ok'
}

@test "a red watch item with --partial skips the probe check, and a non-red item with check(watch) in its task skips it too (ar-1605)" {
  cat >"$SANDBOX/bin/watch-companion-loop" <<'EOF'
#!/usr/bin/env bash
printf 'watch-companion-loop %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
exit 1
EOF
  chmod +x "$SANDBOX/bin/watch-companion-loop"

  cat >"$AGENT_QUEUE_DIR/running/20261103-100000-red-spend.md" <<'EOF'
slug: red-spend
project: dotfiles
mode: oneshot
priority: urgent
from: fleet-bench
agent: claude
tags: red watch cause:ab12
queued: 2026-11-03T10:00:00Z
started: 2026-11-03T10:00:00Z
---
check(watch): spend tripped since 2026-11-20
EOF

  run "$LAND" 42 --item red-spend --partial
  assert_success
  [ "$(grep -c 'watch-companion-loop' "$LOG")" -eq 0 ]

  cat >"$AGENT_QUEUE_DIR/running/20261103-100001-non-red.md" <<'EOF'
slug: non-red
project: dotfiles
mode: oneshot
priority: low
from: human
agent: claude
tags: reddish
queued: 2026-11-03T10:00:01Z
started: 2026-11-03T10:00:01Z
---
check(watch): spend tripped since 2026-11-20
EOF

  run "$LAND" 42 --item non-red
  assert_success
  [ "$(grep -c 'watch-companion-loop' "$LOG")" -eq 0 ]
}

@test "a red watch item whose watch is unknown (exit 2) closes ok, while lock busy (exit 75) or a usage error (exit 2) refuses (ar-1605)" {
  cat >"$SANDBOX/bin/watch-companion-loop" <<'EOF'
#!/usr/bin/env bash
printf 'watch-companion-loop %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat "$NOTES_FIXTURE/watch.err" >&2 2>/dev/null
exit "$(cat "$NOTES_FIXTURE/watch.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/watch-companion-loop"

  cat >"$AGENT_QUEUE_DIR/running/20261103-100000-red-lock.md" <<'EOF'
slug: red-lock
project: dotfiles
mode: oneshot
priority: urgent
from: fleet-bench
agent: claude
tags: red watch
queued: 2026-11-03T10:00:00Z
started: 2026-11-03T10:00:00Z
---
check(watch): spend tripped
EOF

  printf '75\n' >"$NOTES_FIXTURE/watch.rc"
  run "$LAND" 42 --item red-lock
  assert_failure 1
  assert_output --partial 'resolve spend could not take the lock (exit 75)'
  run agent-queue show red-lock --json
  assert_equal "$(jq -r .state <<<"$output")" 'running'

  printf '2\n' >"$NOTES_FIXTURE/watch.rc"
  printf 'usage: watch-companion-loop {run|recheck NAME...}\n' >"$NOTES_FIXTURE/watch.err"
  run "$LAND" 42 --item red-lock
  assert_failure 1
  assert_output --partial 'watch-companion-loop resolve spend: usage: watch-companion-loop {run|recheck NAME...}'
  run agent-queue show red-lock --json
  assert_equal "$(jq -r .state <<<"$output")" 'running'

  printf 'watch-companion-loop: no watch named spend\n' >"$NOTES_FIXTURE/watch.err"
  run "$LAND" 42 --item red-lock
  assert_success
  assert_line 'watch: spend not known here (exit 2), skipping probe check'
  run agent-queue show red-lock --json
  assert_equal "$(jq -r '[.state, .status] | join("|")' <<<"$output")" 'done|ok'
}

@test "a failed read of the head's queued runs is not 0 queued: a lost connection reads again, any other error stops at checks (ar-2235)" {
  printf '%s\n' 'no checks reported on the pr-42 branch' >"$NOTES_FIXTURE/checks.out"
  printf '%s\n' 'ERR gh: Server Error (HTTP 502)' >"$NOTES_FIXTURE/runs.queued"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_line 'checks: lost the connection to the API (1 of 5 retries), reading again'
  refute_output --partial 'reading the runs on the head'
  : >"$LOG"
  printf '%s\n' 'ERR gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/runs.queued"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: reading the runs on the head: gh: API rate limit exceeded (HTTP 403)'
  refute_output --partial 'checks: none reported'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a watch that dies on a 403 with no check named stops as a read error, not a red check (ar-2235)" {
  printf '%s\n' 'gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/checks.seq"
  : >"$NOTES_FIXTURE/checks.failed"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: the watch ended with no failed check to name: gh: API rate limit exceeded (HTTP 403)'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a PR whose only checks read skipping at that moment keeps waiting while a run is queued, then lands on green (ar-2485)" {
  printf '%s\n' $'Run Checks\tthe slot refused\tskipping' green >"$NOTES_FIXTURE/checks.seq"
  : >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' true >"$NOTES_FIXTURE/checks.skipping"
  printf '%s\n' 1 >"$NOTES_FIXTURE/runs.queued"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: only skipping reported; waiting'
  assert_line 'checks: green'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep '^sleep' "$LOG"
  assert_output 'sleep 60'
}

@test "a queued-runs answer that is not a count is a failed read, never 0 queued (ar-2235)" {
  printf '%s\n' 'no checks reported on the pr-42 branch' >"$NOTES_FIXTURE/checks.out"
  printf '%s\n' 'A new release of gh is available' >"$NOTES_FIXTURE/runs.queued"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: reading the runs on the head: not a count: A new release of gh is available'
  refute_output --partial 'checks: none reported'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "board step on a row already ticked still lands and ticks --plan (ar-4189)" {
  item fix 'board:game:gm-1' human
  jq -n '{rows: [], done: [{project: "game", lane: "human", id: "gm-1", state: "done"}]}' >"$NOTES_FIXTURE/board.json"
  mv "$SANDBOX/bin/notes" "$SANDBOX/notes.ok"
  printf '#!/usr/bin/env bash\ncase " $* " in *" done "*) echo "no open task matches '\''gm-1'\'' in game" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$SANDBOX/notes.ok" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix --plan "$PLAN" --phase "6. agent-land"
  mv "$SANDBOX/notes.ok" "$SANDBOX/bin/notes"
  assert_success
  assert_line 'board: "gm-1" was already closed, left as is'
  assert_line 'plan: ticked "6. agent-land"'
  assert_line --index -1 'landed #42'
}

@test "board step on a row no board lists as done on its project, or one dropped, still fails (ar-4189)" {
  item fix 'board:game:gm-1' human
  jq -n '{rows: [], done: [{project: "other", lane: "human", id: "gm-1", state: "done", marker: "id:gm-1 done:2026-11-01"},
    {project: "game", lane: "human", id: "gm-1", state: "done", marker: "id:gm-1 dropped:2026-11-02"}]}' >"$NOTES_FIXTURE/board.json"
  mv "$SANDBOX/bin/notes" "$SANDBOX/notes.ok"
  printf '#!/usr/bin/env bash\ncase " $* " in *" done "*) echo "no open task matches '\''gm-1'\'' in game" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$SANDBOX/notes.ok" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix
  mv "$SANDBOX/notes.ok" "$SANDBOX/bin/notes"
  assert_failure
  assert_output --partial "agent-land: board failed: no open task matches 'gm-1' in game"
}

@test "a watch that times out with a check left IN_PROGRESS and conclusion SUCCESS lands on its conclusion (ar-4595)" {
  printf '%s\n' '{"statusCheckRollup":[{"name":"Checks (docs)","workflowName":"Checks","status":"IN_PROGRESS","completedAt":"2026-11-22T10:00:00Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/1/job/137130856490"}]}' >"$NOTES_FIXTURE/checks.rollup"
  printf '#!/usr/bin/env bash\nprintf "timeout %%s\\n" "$1" >>"$NOTES_FIXTURE/calls.log"\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  AGENT_LAND_CHECKS_WATCH_TIMEOUT=45 run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: green'
  assert_line 'landed #42'
  run grep '^timeout ' "$LOG"
  assert_output 'timeout 45'
  run grep -c 'pr view 42 --json statusCheckRollup' "$LOG"
  assert_output 1
}

@test "a watch that times out with a check left IN_PROGRESS and conclusion FAILURE stops at checks, naming the check (ar-4595)" {
  printf '%s\n' '{"statusCheckRollup":[{"name":"Checks (docs)","workflowName":"Checks","status":"IN_PROGRESS","completedAt":"2026-11-22T10:00:00Z","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/1/job/137130856490"}]}' >"$NOTES_FIXTURE/checks.rollup"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks (docs)'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a watch that times out with checks still pending stops at the overall wait bound (ar-4595)" {
  printf '%s\n' '{"statusCheckRollup":[{"name":"Checks (docs)","workflowName":"Checks","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"https://github.com/o/r/actions/runs/1/job/137130856490"}]}' >"$NOTES_FIXTURE/checks.rollup"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  AGENT_LAND_CHECKS_WAIT_TIMEOUT=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'the watch timed out with checks still pending; continuing'
  assert_output --partial 'checks failed: timed out waiting for checks after 1s'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled check whose open run on HEAD already has a conclusion is not waited on as a newer run (ar-4595)" {
  printf '%s\n' "$CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  printf '%s\n' '[{"status":"in_progress","conclusion":"success","workflowName":"Checks"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: Checks, and no run of its workflow is left on the head to replace it'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a red read after a watch timeout waits on a newer run of its workflow on the head, then stops at checks once none is left (ar-4595)" {
  printf '%s\n' '{"statusCheckRollup":[{"name":"Checks (docs)","workflowName":"Checks","status":"COMPLETED","conclusion":"CANCELLED","detailsUrl":"https://github.com/o/r/actions/runs/1/job/2"}]}' >"$NOTES_FIXTURE/checks.rollup"
  printf '%s\n' '[{"status":"in_progress","workflowName":"Checks"}]' >"$NOTES_FIXTURE/runs.open"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks: red: Checks (docs); waiting on the newer run of its workflow on the head'
  assert_output --partial 'checks failed: Checks (docs)'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a rollup with no readable verdict after a watch timeout stops at checks, never reads as green (ar-4595)" {
  printf '%s\n' 'not json' >"$NOTES_FIXTURE/checks.rollup"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'the rollup gave no verdict'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "validate: a diff touching a Judge authority name does not merge; it queues one validate item and exits 5, and a re-run waits on it" {
  item crit
  printf '%s\n' README.md .local/lib/judge.sh >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'is critical (the diff touches .local/lib/judge.sh, a Judge authority name in'
  assert_output --partial 'queued validate-crit-01234567'
  assert_equal "$(merges)" 0
  run agent-queue show validate-crit-01234567 --json
  assert_success
  assert_equal "$(jq -r '"\(.state) \(.tags) \(.after) \(.from) \(.priority)"' <<<"$output")" 'queued validate crit auto:validate high'
  assert_equal "$(jq -r .task <<<"$output" | grep -c 'agent-land 42 --repo o/r --item crit')" 1
  run agent-queue show crit --json
  assert_equal "$(jq -r '"\(.state) \(.validate)"' <<<"$output")" 'running validate-crit-01234567'

  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'so it waits on validate-crit-01234567'
  assert_equal "$(merges)" 0
  assert_equal "$(ls "$AGENT_QUEUE_DIR"/*/*-validate-crit-* | wc -l)" 1
}

@test "validate: an item carrying out an ask the judge flagged human-only is critical whatever its diff" {
  item ext ask:a1
  mkdir -p "$AGENT_ASK_ROOT/dotfiles"
  printf 'id: a1\njudge_human_only: true\njudge_human_only_evidence: it sends mail to a customer\n' >"$AGENT_ASK_ROOT/dotfiles/a1.md"
  printf 'README.md\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item ext
  assert_failure 5
  assert_output --partial 'it carries out ask a1, which the judge flagged human-only: it sends mail to a customer'
  assert_equal "$(merges)" 0
  run agent-queue show validate-ext-01234567 --json
  assert_equal "$(jq -r .state <<<"$output")" queued
}

@test "validate: repo- and fleet-level work merges as before, with no validate item" {
  printf 'README.md\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'validate: repo work, no second agent needed'
  assert_line 'landed #42'
  item rules
  printf 'CLAUDE.md\n' >"$NOTES_FIXTURE/files"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item rules
  assert_success
  assert_line 'validate: fleet work, no second agent needed'
  run bash -c "ls '$AGENT_QUEUE_DIR'/*/*-validate-* 2>/dev/null | wc -l"
  assert_output 0
}

@test "validate: a pass verdict on this head from another agent's session merges" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit 'verdict: pass' 'verdict_head: 0123456789abcdef' 'sessions: s-validator' 'note: read the diff, tests green'
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_success
  assert_line --partial 'validate: pass from validate-crit-01234567 on 01234567 (critical: the diff touches .local/lib/judge.sh'
  assert_line 'landed #42'
  assert_equal "$(merges)" 1
}

@test "validate: a fail verdict leaves the PR open and sends the author item back to the queue with the findings" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit 'verdict: fail' 'verdict_head: 0123456789abcdef' 'sessions: s-validator' 'note: judge_conf drops an empty override'
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 1
  assert_output --partial 'validate failed: validate-crit-01234567 failed #42 on 01234567; #42 stays open and crit is back in the queue'
  assert_equal "$(merges)" 0
  run agent-queue show crit --json
  assert_equal "$(jq -r .state <<<"$output")" queued
  assert_equal "$(jq -r .note <<<"$output")" 'validation failed on #42 at 01234567 (validate-crit-01234567): judge_conf drops an empty override'
}

@test "validate: a missing verdict, one from the author's own session or one no session gave fails closed" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'waits on validate-crit-01234567'
  fm validate-crit-01234567 'verdict: pass' 'verdict_head: 0123456789abcdef' 'sessions: s-author'
  run "$LAND" 42 --item crit
  assert_failure 1
  assert_output --partial 'was worked by session s-author, which also worked crit: the verdict must come from another agent'
  sed -i '/^sessions: s-author$/d' "$AGENT_QUEUE_DIR"/running/*-validate-crit-01234567.md
  run "$LAND" 42 --item crit
  assert_failure 1
  assert_output --partial 'records a pass verdict, but no session worked it'
  assert_equal "$(merges)" 0
}

@test "validate: a pass on an older head does not count; the new head gets its own validate item" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-aaaaaaaa'
  vitem validate-crit-aaaaaaaa crit 'verdict: pass' 'verdict_head: aaaaaaaabbbbbbbb' 'sessions: s-validator'
  touch "$NOTES_FIXTURE/head.foreign"
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'queued validate-crit-01234567'
  assert_equal "$(merges)" 0
  run agent-queue show crit --json
  assert_equal "$(jq -r .validate <<<"$output")" validate-crit-01234567
}

@test "validate: files that cannot be read on an open PR refuse the merge" {
  touch "$NOTES_FIXTURE/files.fail"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "validate failed: could not read #42's changed files"
  assert_equal "$(merges)" 0
}

@test "validate: a validate item closed with no verdict (its session died) is filed again, not waited on" {
  item crit
  fm crit 'sessions: s-author' 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit
  mkdir -p "$AGENT_QUEUE_DIR/done"
  mv "$AGENT_QUEUE_DIR"/running/*-validate-crit-01234567.md "$AGENT_QUEUE_DIR/done/"
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item crit
  assert_failure 5
  assert_output --partial 'queued validate-crit-01234567'
  run agent-queue show validate-crit-01234567 --json
  assert_equal "$(jq -r .state <<<"$output")" queued
  assert_equal "$(merges)" 0
}

@test "validate: the landing session is put on the author item first, so its own pass on the validate item never counts" {
  item crit
  fm crit 'validate: validate-crit-01234567'
  vitem validate-crit-01234567 crit 'verdict: pass' 'verdict_head: 0123456789abcdef' 'sessions: s-hand'
  printf '.local/lib/judge.sh\n' >"$NOTES_FIXTURE/files"
  CLAUDE_CODE_SESSION_ID=s-hand AGENT_QUEUE_ITEM=crit run "$LAND" 42 --item crit
  assert_failure 1
  assert_output --partial 'was worked by session s-hand, which also worked crit'
  assert_equal "$(merges)" 0
}

# GitHub refuses to merge a PR that changes .github/workflows for an OAuth token with no workflow scope,
# and says so only at the merge, after the checks (platform#1672, ar-5191).
@test "a PR that changes .github/workflows fails before the checks when the token lacks the workflow scope, and lands once it has it (ar-5191)" {
  item ship
  printf '%s\n' README.md .github/workflows/ci.yml >"$NOTES_FIXTURE/files"
  printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: admin:org, gist, repo\r\n\r\n' >"$NOTES_FIXTURE/user.headers"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'agent-land: workflow failed: #42 changes .github/workflows and this gh token'"'"'s scopes (admin:org,gist,repo) have no workflow'
  run grep -c 'pr checks\|pr merge' "$LOG"
  assert_output 0
  # Negative control: the same PR with a token that has the scope lands.
  printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: gist, repo, workflow\r\n\r\n' >"$NOTES_FIXTURE/user.headers"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'landed #42'
}

@test "a token whose scopes lack workflow lands a PR that changes no workflow file (ar-5191)" {
  item ship
  printf '%s\n' README.md .github/actions/x.yml >"$NOTES_FIXTURE/files"
  printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: repo\r\n\r\n' >"$NOTES_FIXTURE/user.headers"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'landed #42'
}

@test "a workflow PR lands when the token's scopes cannot be read: the merge itself says what it lacks (ar-5191)" {
  item ship
  printf '%s\n' .github/workflows/ci.yml >"$NOTES_FIXTURE/files"
  touch "$NOTES_FIXTURE/user.fail"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'landed #42'
}
