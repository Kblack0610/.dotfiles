#!/usr/bin/env bats
# quarantine-expiry: each open owner row whose quarantine entries end soon gets one detail line,
# once per end date; a row not open on the board is listed, not noted; nothing ending is quiet;
# and a quarantine or board that cannot be read is never read as all clear.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # hub answers `quarantine soon` from $SANDBOX/soon.tsv (a missing file is a parse failure,
  # exit 2) and prints $SANDBOX/undated (ends that are not dates) to stderr with exit 1;
  # notes answers `board --json` from $SANDBOX/board.json and logs each edit's arguments
  cat > "$SANDBOX/bin/hub" <<HUB
#!/usr/bin/env bash
[ "\$*" = "quarantine soon" ] || exit 2
cat "$SANDBOX/soon.tsv" 2>/dev/null || { echo "hub quarantine soon: quarantine.json: expected value" >&2; exit 2; }
[ ! -s "$SANDBOX/undated" ] || { cat "$SANDBOX/undated" >&2; exit 1; }
HUB
  cat > "$SANDBOX/bin/notes" <<NOTES
#!/usr/bin/env bash
if [ "\$1" = board ]; then cat "$SANDBOX/board.json"; exit; fi
printf '%s\n' "\$@" >> "$SANDBOX/notes.log"
NOTES
  chmod +x "$SANDBOX/bin/hub" "$SANDBOX/bin/notes"
  # ucp-1 is open with no note, ucp-2 open and already noted for 11-24, ucp-3 not on the board
  cat > "$SANDBOX/board.json" <<'JSON'
{"rows":[
 {"id":"ucp-1","profile":"bnb","project":"unity-core-playground","lane":"agent","details":["Fix it."],
  "raw":"- [ ] fix(tests): BossPlayTests fails #of/ucp-9 <!-- id:ucp-1 -->"},
 {"id":"ucp-2","profile":"bnb","project":"unity-core-playground","lane":"agent",
  "details":["quarantine ends 2026-11-24: 2 entries of this row stop"],"raw":"- [ ] fix(tests): two <!-- id:ucp-2 -->"},
 {"id":"ucp-10","profile":"bnb","project":"unity-core-playground","lane":"agent","details":[],
  "raw":"- [ ] fix(tests): child #of/ucp-1 <!-- id:ucp-10 -->"}]}
JSON
}

soon() { printf '%s\n' "$@" > "$SANDBOX/soon.tsv"; }

@test "an open row ending soon is noted once, by its exact line, and the totals come last" {
  soon $'Org/play\tucp-1\t3\t2026-11-24\t3' $'Org/play\tucp-2\t2\t2026-11-24\t3' $'Org/play\tucp-3\t1\t2026-11-24\t3'
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index 0 'ucp-1: 3 entries end 2026-11-24 (3d) in Org/play; noted on the row now'
  assert_line --index 1 'ucp-2: 2 entries end 2026-11-24 (3d) in Org/play; noted'
  assert_line --index 2 'ucp-3: 1 entry ends 2026-11-24 (3d) in Org/play; the row is not open on the board, so no open row owns them'
  assert_line --index -1 '6 quarantine entries over 3 owner rows end soon (next 2026-11-24, 3d): 2 noted, 1 not open on the board'
  run cat "$SANDBOX/notes.log"
  assert_line --index 0 --profile
  assert_line --index 1 bnb
  assert_line --index 3 unity-core-playground
  assert_line --index 4 --agent
  assert_line --partial 'quarantine ends 2026-11-24: 3 entries of this row stop being quarantined then and count as red'
  assert_line -- '- [ ] fix(tests): BossPlayTests fails #of/ucp-9 <!-- id:ucp-1 -->'
  refute_output --partial 'id:ucp-10'
  refute_output --partial 'id:ucp-2'
}

@test "a row already noted for a later end date is noted again for the new one" {
  soon $'Org/play\tucp-2\t2\t2026-12-08\t2'
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index 0 'ucp-2: 2 entries end 2026-12-08 (2d) in Org/play; noted on the row now'
  run cat "$SANDBOX/notes.log"
  assert_line --partial 'quarantine ends 2026-12-08:'
}

@test "--dry-run notes nothing" {
  soon $'Org/play\tucp-1\t3\t2026-11-24\t3'
  run "$REPO_ROOT/.local/bin/quarantine-expiry" --dry-run
  assert_failure 1
  assert_line --index 0 'ucp-1: 3 entries end 2026-11-24 (3d) in Org/play; would note'
  [ ! -e "$SANDBOX/notes.log" ]
}

@test "a note the board refuses is said on its line and counted" {
  soon $'Org/play\tucp-1\t3\t2026-11-24\t3'
  printf '#!/usr/bin/env bash\n[ "$1" = board ] && exec cat %q\necho "no open task matches" >&2; exit 1\n' "$SANDBOX/board.json" > "$SANDBOX/bin/notes"
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index 0 'ucp-1: 3 entries end 2026-11-24 (3d) in Org/play; could not note the row: no open task matches'
  assert_line --index -1 --partial '0 noted, 1 could not be noted'
}

@test "nothing ending soon is quiet and reads no board" {
  : > "$SANDBOX/soon.tsv"
  rm "$SANDBOX/board.json"
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_success
  assert_output 'No quarantine entry is about to end'
}

@test "a quarantine or board that cannot be read is unreadable, never all clear" {
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 2
  assert_output 'unreadable: hub quarantine soon: quarantine.json: expected value'
  soon $'Org/play\tucp-1\t3\t2026-11-24\t3'
  echo 'not json' > "$SANDBOX/board.json"
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 2
  assert_output --partial 'unreadable: notes board --json'
}

@test "an owner row with no id keeps its columns and is listed as owned by no row" {
  soon $'Org/play\t\t2\t2026-11-24\t3'
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index 0 'no owner row: 2 entries end 2026-11-24 (3d) in Org/play; no row owns them'
  assert_line --index -1 '2 quarantine entries over 1 owner row end soon (next 2026-11-24, 3d): 0 noted, 1 not open on the board'
}

@test "an end that is not a date is listed and trips, and the rows that parsed are still noted" {
  soon $'Org/play\tucp-1\t3\t2026-11-24\t3'
  echo 'hub quarantine soon: Org/play: row ucp-5 ends "11-24", not a date' > "$SANDBOX/undated"
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index 0 'ucp-1: 3 entries end 2026-11-24 (3d) in Org/play; noted on the row now'
  assert_line --index 1 'Org/play: row ucp-5 ends "11-24", not a date; its entries cannot be counted until the end is a date'
  assert_line --index -1 '3 quarantine entries over 1 owner row end soon (next 2026-11-24, 3d): 1 noted; 1 owner row with an end that is not a date'
  : > "$SANDBOX/soon.tsv"
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index -1 'No quarantine entry with a date ends soon; 1 owner row with an end that is not a date'
}
