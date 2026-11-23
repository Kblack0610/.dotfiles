#!/usr/bin/env bats
# quarantine-expiry: each open owner row whose quarantine entries end soon gets one detail line,
# once per end date, the row a dup-closed owner was folded into included; an owner with no open
# row is listed, not noted; nothing ending is quiet;
# and a quarantine or board that cannot be read is never read as all clear.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # hub answers `quarantine soon` from $SANDBOX/soon.tsv (a missing file is a parse failure,
  # exit 2) and prints $SANDBOX/undated (ends that are not dates) to stderr with exit 1;
  # notes answers `board --json --id <id>...` with the rows of $SANDBOX/board.json those ids
  # name, logs each lookup's ids to lookups.log and each edit's arguments to notes.log
  cat > "$SANDBOX/bin/hub" <<HUB
#!/usr/bin/env bash
[ "\$*" = "quarantine soon" ] || exit 2
cat "$SANDBOX/soon.tsv" 2>/dev/null || { echo "hub quarantine soon: quarantine.json: expected value" >&2; exit 2; }
[ ! -s "$SANDBOX/undated" ] || { cat "$SANDBOX/undated" >&2; exit 1; }
HUB
  cat > "$SANDBOX/bin/notes" <<NOTES
#!/usr/bin/env bash
if [ "\$1" = board ]; then
  shift 2; ids=()
  while [ \$# -gt 0 ]; do [ "\$1" = --id ] && ids+=("\$2"); shift 2; done
  echo "\${ids[*]}" >> "$SANDBOX/lookups.log"
  jq -c '{today: "x", rows: [.rows[] | select(.id as \$i | \$ARGS.positional | index([\$i]))]}' --args "\${ids[@]}" < "$SANDBOX/board.json"
  exit
fi
printf '%s\n' "\$@" >> "$SANDBOX/notes.log"
NOTES
  chmod +x "$SANDBOX/bin/hub" "$SANDBOX/bin/notes"
  # ucp-1 is open with no note, ucp-2 open and already noted for 11-24, ucp-3 on no sheet
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
  assert_line --index 2 'ucp-3: 1 entry ends 2026-11-24 (3d) in Org/play; the row is on no sheet, so no open row owns them'
  assert_line --index -1 '6 quarantine entries over 3 owner rows end soon (next 2026-11-24, 3d): 2 noted, 1 with no open owner row'
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

@test "a dup-closed owner's entries go to the row it was folded into, noted once with all of them" {
  # ucp-30 was closed into ucp-1; ucp-31 into ucp-32, itself closed into ucp-1; ucp-40 closed
  # outright; ucp-41 into a row no sheet has; ucp-50 and ucp-51 into each other
  jq '.rows += [
    {id:"ucp-30",state:"done",dup:"ucp-1",details:[],raw:"- [x] a <!-- id:ucp-30 dup:ucp-1 -->"},
    {id:"ucp-31",state:"done",dup:"ucp-32",details:[],raw:"- [x] b <!-- id:ucp-31 dup:ucp-32 -->"},
    {id:"ucp-32",state:"done",dup:"ucp-1",details:[],raw:"- [x] c <!-- id:ucp-32 dup:ucp-1 -->"},
    {id:"ucp-40",state:"done",dup:null,details:[],raw:"- [x] d <!-- id:ucp-40 done:2026-11-20 -->"},
    {id:"ucp-41",state:"done",dup:"ucp-99",details:[],raw:"- [x] e <!-- id:ucp-41 dup:ucp-99 -->"},
    {id:"ucp-50",state:"done",dup:"ucp-51",details:[],raw:"- [x] f <!-- id:ucp-50 dup:ucp-51 -->"},
    {id:"ucp-51",state:"done",dup:"ucp-50",details:[],raw:"- [x] g <!-- id:ucp-51 dup:ucp-50 -->"}]' \
    "$SANDBOX/board.json" > "$SANDBOX/b" && mv "$SANDBOX/b" "$SANDBOX/board.json"
  soon $'Org/play\tucp-1\t3\t2026-11-24\t3' $'Org/play\tucp-30\t2\t2026-11-24\t3' $'Org/play\tucp-31\t1\t2026-11-24\t3' \
    $'Org/play\tucp-40\t1\t2026-11-24\t3' $'Org/play\tucp-41\t1\t2026-11-24\t3' $'Org/play\tucp-50\t1\t2026-11-24\t3'
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index 0 'ucp-1: 3 entries end 2026-11-24 (3d) in Org/play; noted on the row now'
  assert_line --index 1 'ucp-30: 2 entries end 2026-11-24 (3d) in Org/play; ucp-1 owns them (ucp-30 was closed as its dup); noted on the row now'
  assert_line --index 2 'ucp-31: 1 entry ends 2026-11-24 (3d) in Org/play; ucp-1 owns them (closed into it: ucp-31 -> ucp-32 -> ucp-1); noted on the row now'
  assert_line --index 3 'ucp-40: 1 entry ends 2026-11-24 (3d) in Org/play; the row is closed, so no open row owns them'
  assert_line --index 4 'ucp-41: 1 entry ends 2026-11-24 (3d) in Org/play; closed as a dup of ucp-99, which is on no sheet, so no open row owns them'
  assert_line --index 5 'ucp-50: 1 entry ends 2026-11-24 (3d) in Org/play; closed into a dup loop (ucp-50 -> ucp-51 -> ucp-50), so no open row owns them'
  assert_line --index -1 '9 quarantine entries over 6 owner rows end soon (next 2026-11-24, 3d): 3 noted, 3 with no open owner row'
  # one note on ucp-1, counting all six entries, and ucp-32 was looked up on the second hop
  run grep -c -- '^--detail$' "$SANDBOX/notes.log"
  assert_output 1
  run cat "$SANDBOX/notes.log"
  assert_line --partial 'quarantine ends 2026-11-24: 6 entries of this row and of the rows closed into it as dups (ucp-30, ucp-31) stop being quarantined'
  run cat "$SANDBOX/lookups.log"
  assert_line --index 0 'ucp-1 ucp-30 ucp-31 ucp-40 ucp-41 ucp-50'
  assert_line --index 1 'ucp-32 ucp-51 ucp-99'
}

@test "a dup row listed for two repos is named once, and a chain past DUP_HOPS says it was cut" {
  jq '.rows += [{id:"ucp-30",state:"done",dup:"ucp-1",details:[],raw:"- [x] a <!-- id:ucp-30 dup:ucp-1 -->"}]
    + [range(80; 87) | {id: "ucp-\(.)", state: "done", dup: "ucp-\(. + 1)", details: [], raw: "- [x] r"}]
    + [{id:"ucp-90",state:"done",dup:"ucp-91",details:[],raw:"- [x] s"}, {id:"ucp-91",state:"done",dup:null,details:[],raw:"- [x] t"}]' \
    "$SANDBOX/board.json" > "$SANDBOX/b" && mv "$SANDBOX/b" "$SANDBOX/board.json"
  soon $'Org/play\tucp-30\t1\t2026-11-24\t3' $'Org/other\tucp-30\t2\t2026-11-24\t3' $'Org/play\tucp-80\t1\t2026-11-24\t3' \
    $'Org/play\tucp-90\t1\t2026-11-24\t3'
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index 2 'ucp-80: 1 entry ends 2026-11-24 (3d) in Org/play; closed into a dup chain over 5 deep (ucp-80 -> ucp-81 -> ucp-82 -> ucp-83 -> ucp-84 -> ucp-85 -> ucp-86), so no open row owns them'
  assert_line --index 3 'ucp-90: 1 entry ends 2026-11-24 (3d) in Org/play; closed as a dup of ucp-91, which is closed too, so no open row owns them'
  run cat "$SANDBOX/notes.log"
  assert_line --partial '3 entries of this row and of the rows closed into it as dups (ucp-30) stop'
}

@test "an owner row aimed at a later version is noted like an open-version one" {
  jq '.rows += [{id:"ucp-60",profile:"bnb",project:"unity-core-playground",lane:"agent",state:"open",version:"v0.5.6",
    details:[],raw:"- [ ] fix(tests): later #v0.5.6 <!-- id:ucp-60 -->"}]' "$SANDBOX/board.json" > "$SANDBOX/b" \
    && mv "$SANDBOX/b" "$SANDBOX/board.json"
  soon $'Org/play\tucp-60\t1\t2026-11-24\t3'
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index 0 'ucp-60: 1 entry ends 2026-11-24 (3d) in Org/play; noted on the row now'
  run cat "$SANDBOX/notes.log"
  assert_line -- '- [ ] fix(tests): later #v0.5.6 <!-- id:ucp-60 -->'
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
  assert_line --index -1 --partial ': 0 noted'
  [ ! -e "$SANDBOX/notes.log" ]
}

@test "a note on a row that took many dups names the first few and counts the rest" {
  jq '.rows += [range(71; 78) | {id: "ucp-\(.)", state: "done", dup: "ucp-1", details: [], raw: "- [x] r <!-- id:ucp-\(.) -->"}]' \
    "$SANDBOX/board.json" > "$SANDBOX/b" && mv "$SANDBOX/b" "$SANDBOX/board.json"
  soon $'Org/play\tucp-71\t1\t2026-11-24\t3' $'Org/play\tucp-72\t1\t2026-11-24\t3' $'Org/play\tucp-73\t1\t2026-11-24\t3' \
    $'Org/play\tucp-74\t1\t2026-11-24\t3' $'Org/play\tucp-75\t1\t2026-11-24\t3' $'Org/play\tucp-76\t1\t2026-11-24\t3' \
    $'Org/play\tucp-77\t1\t2026-11-24\t3'
  run "$REPO_ROOT/.local/bin/quarantine-expiry"
  assert_failure 1
  assert_line --index -1 '7 quarantine entries over 7 owner rows end soon (next 2026-11-24, 3d): 7 noted'
  run cat "$SANDBOX/notes.log"
  assert_line --partial '7 entries of this row and of the rows closed into it as dups (ucp-71, ucp-72, ucp-73, ucp-74, ucp-75 and 2 more) stop'
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
  assert_line --index -1 '2 quarantine entries over 1 owner row end soon (next 2026-11-24, 3d): 0 noted, 1 with no open owner row'
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
