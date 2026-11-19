#!/usr/bin/env bats
# agent-queue backfill-briefs: an open agent row with no brief gets the brief of the item that
# worked it, written by the real notes on a sandbox vault, since a stub would only echo it back.
# The CI rust job builds notes and sets NOTES_BIN; with none the cases skip.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  AQ="$REPO_ROOT/.local/bin/agent-queue"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue"
  dir="$HOME/.notes/lab/projects/current/game"
  mkdir -p "$dir/agent" "$HOME/.config/notes" "$AGENT_QUEUE_DIR/done/2026-11-10" "$AGENT_QUEUE_DIR/queued"
  : >"$dir/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  printf '%s\n' '# game' '' 'Version: v1.0.0 #beta' '' '## Inbox' '' '## Tasks' '' >"$dir/README.md"
  # gm-1: bare, worked by a done item with a real brief. gm-2: bare, its item only repeats the row.
  # gm-3: already has a brief. gm-4: bare, never worked. gm-1's body starts with its row line, which the
  # brief drops, and carries a marker and a checklist. gm-5's item is a dispatch promotion: its brief is
  # the whole title the row was cut from, and the dispatch template after it is not; its `was:` line
  # stays. gm-6 carries keep_brief's `brief: ` lines, which lose the prefix.
  printf '%s\n' '# game agent' '' '## Tasks' '' \
    '- [ ] feat(menu): the title screen #size/s <!-- id:gm-1 -->' \
    '- [ ] fix(menu): the back button #size/s <!-- id:gm-2 -->' \
    '- [ ] feat(menu): sound <!-- id:gm-3 -->' '  keep this brief' \
    '- [ ] chore(menu): tidy <!-- id:gm-4 -->' \
    '- [ ] fix(ci): cache the tests image <!-- id:gm-5 -->' '  was: cache the image' \
    '- [ ] feat(menu): credits <!-- id:gm-6 -->' '  brief: first' '  brief: - [ ] step two' >"$dir/agent/README.md"
  export PROJECT_MAP_FILE="$SANDBOX/map.json" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  export AGENT_QUEUE_PROJECT_MAP="$PROJECT_MAP_FILE"
  unset NOTES_PROFILE CLAUDE_CODE_SESSION_ID
  jq -n '{paths: {"/x/game": "game"}, trackers: {game: {code: "gm", lab: "personal"}}}' >"$PROJECT_MAP_FILE"
  item done/2026-11-10 title gm-1 'feat(menu): the title screen' 'feat(menu): the title screen #size/s <!-- id:gm-1 -->' \
    'Build the title screen.' '' 'See the plan <!-- plan:x.md -->' '- [ ] a step' '```sh' 'make menu' '```' '' '- start' '  - nested'
  item done/2026-11-10 gm-5 gm-5 'fix(ci): cache the tests image' \
    'fix(ci): cache the tests image so a GitHub release CDN outage stops redding every PR' '' \
    'Promoted by fleet-dispatch fill from the game agent board, row "gm-5".' '- Repo: /x/game.'
  item done/2026-11-10 back gm-2 'fix(menu): the back button' 'fix(menu): the back button #size/s <!-- id:gm-2 -->'
  item done/2026-11-10 sound gm-3 'feat(menu): sound' 'A much longer brief for sound that must not replace the one on the row.'
}

# item <dir> <slug> <row id|-> <title> <body lines...>: a queue item file as agent-queue writes it.
item() {
  local d="$1" s="$2" r="$3" t="$4"; shift 4
  {
    printf '%s\n' "slug: $s" 'project: game' 'mode: oneshot' 'priority: high' "title: $t" 'from: human' 'agent: claude' 'queued: 2026-11-10T00:00:00Z'
    [ "$r" = - ] || echo "row: game:$r"
    [ "${d%%/*}" = done ] && printf '%s\n' 'status: ok' 'finished: 2026-11-10T01:00:00Z'
    echo ---
    printf '%s\n' "$@"
  } >"$AGENT_QUEUE_DIR/$d/20261110-000000-$s.md"
}

# details <id>: the row's details as notes reads them back, one line each.
details() { notes board --json | jq -r --arg id "$1" '.rows[] | select(.id == $id) | .details[]'; }

@test "backfill-briefs: a bare row gets its item's brief verbatim, and a row with a brief, a repeat or no item is left alone" {
  before="$(cat "$dir/agent/README.md")"
  run "$AQ" backfill-briefs --dry-run
  assert_success
  assert_line 'game:gm-1 <- title (done, queued 2026-11-10): 11 lines'
  assert_line 'game:gm-5 <- gm-5 (done, queued 2026-11-10): 3 lines'
  assert_output --partial 'would fill 2 rows with a brief, strip brief: from 1,'
  assert_output --partial '1 linked only to items that repeat the row; 1 never worked by an item'
  [ "$(cat "$dir/agent/README.md")" = "$before" ] || fail "the dry-run wrote the board"
  # --check is the nightly doctor's line: one FAIL while a row lacks its item's brief, no row listed.
  run "$AQ" backfill-briefs --check
  assert_failure
  assert_output 'FAIL  briefs: 2 rows lack the brief their item has, 1 carry brief: lines, 0 open items have no row (agent-queue backfill-briefs writes them)'

  run "$AQ" backfill-briefs
  assert_success
  assert_output --partial 'filled 2 rows with a brief, stripped brief: from 1, filed 0 rows for items with none; 0 not written'
  run details gm-1
  assert_output "$(printf '%s\n' 'from item title (done, queued 2026-11-10)' 'Build the title screen.' '' 'See the plan' '- [ ] a step' '```sh' 'make menu' '```' '' '- start' '  - nested')"
  run details gm-5
  assert_output "$(printf '%s\n' 'was: cache the image' 'from item gm-5 (done, queued 2026-11-10)' 'fix(ci): cache the tests image so a GitHub release CDN outage stops redding every PR')"
  [ -z "$(details gm-2)" ] || fail "a body that repeats the row was written: $(details gm-2)"
  [ "$(details gm-3)" = 'keep this brief' ] || fail "a row's own brief was replaced: $(details gm-3)"
  [ -z "$(details gm-4)" ] || fail "a never-worked row got details"
  run details gm-6
  assert_output "$(printf '%s\n' first '- [ ] step two')"
  # The checklist line in gm-1's brief stays a brief line, not a seventh row.
  [ "$(notes board --json | jq '[.rows[] | select(.project == "game")] | length')" = 6 ] ||
    fail "a brief line became a row: $(cat "$dir/agent/README.md")"

  run "$AQ" backfill-briefs
  assert_output --partial 'filled 0 rows with a brief, stripped brief: from 0,'
  run "$AQ" backfill-briefs --check
  assert_success
  assert_output 'PASS  briefs: every agent row holds the brief its item has'
}

@test "backfill-briefs: an open item with no row gets a story row with its brief; a canary item does not" {
  item queued menu-art - 'feat(menu): new art' 'feat(menu): new art' 'Paint the menu.' 'Use the house palette.'
  printf '%s\n' 'slug: probe' 'project: game' 'mode: oneshot' 'priority: low' 'title: canary probe' 'from: canary' 'queued: 2026-11-10T00:00:00Z' --- 'probe body' \
    >"$AGENT_QUEUE_DIR/queued/20261110-000000-probe.md"
  run "$AQ" backfill-briefs
  assert_success
  assert_output --partial 'filed 1 rows for items with none'
  row="$(sed -n 's/^row: //p' "$AGENT_QUEUE_DIR/queued/20261110-000000-menu-art.md")"
  [ -n "$row" ] || fail "the item was not linked to a row"
  id="${row#game:}"
  grep -qF 'feat(menu): new art' "$dir/agent/README.md" || fail "no story row: $(cat "$dir/agent/README.md")"
  run details "$id"
  assert_output "$(printf '%s\n' 'Paint the menu.' 'Use the house palette.')"
  ! grep -q '^row:' "$AGENT_QUEUE_DIR/queued/20261110-000000-probe.md" || fail "a canary item got a row"
  ! grep -qF 'canary probe' "$dir/agent/README.md" || fail "a canary item got a row"
}
