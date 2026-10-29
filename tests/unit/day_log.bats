#!/usr/bin/env bats
# day-log: one record per local day of every merged PR, what is open, what waits on the
# human and the fleet's telemetry. gh, fleet-bench, agent-usage and agent-hold are stubs.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export TZ=America/Los_Angeles
  export TABLE_FIT_LIB="$REPO_ROOT/.local/lib/table-fit.sh"
  export DAYLOG_DIR="$HOME/.agent/daylog" DAYLOG_REFS_DIR="$HOME/refs"
  export DAYLOG_STATE="$SANDBOX/state.json" DAYLOG_WATCH_LOG="$SANDBOX/watch.log"
  export DAYLOG_GROUPS="$SANDBOX/groups" DAYLOG_OUTCOMES_DIR="$HOME/.agent/outcomes"
  export DAYLOG_GH=gh-stub DAYLOG_BENCH_CMD=bench-stub DAYLOG_USAGE_CMD=usage-stub
  export DAYLOG_HOLD_CMD=hold-stub DAYLOG_UNITY_CMD="echo 2"
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"
  # gh-stub: logs every call; --merged-at serves $GHD/merged, --state=open $GHD/open,
  # and a $GHD/fail file makes every call fail.
  cat > "$SANDBOX/bin/gh-stub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GHD/calls"
[ -e "$GHD/fail" ] && exit 1
case "\$*" in *--merged-at*) cat "$GHD/merged" ;; *--state=open*) cat "$GHD/open" ;; esac
EOF
  cat > "$SANDBOX/bin/bench-stub" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  headline) echo "bench 24h: 2 sessions, 3 phases ticked" ;;
  sessions) echo '{"session_id":"a","target":"lab/game-agent-3:1","plan":"glad-otter","phase":"2/4","working_h":1.5,"waiting_h":0.2,"prs_merged":2,"ci_reds":0,"cost_usd":4.5}' ;;
esac
EOF
  printf '#!/usr/bin/env bash\nprintf "game\\t3\\t10\\t2000000\\t12.5\\t0\\n"\n' > "$SANDBOX/bin/usage-stub"
  printf '#!/usr/bin/env bash\nprintf "unity\\t2026-10-28T15:49:30-0700\\tshepherd\\thot\\n"\n' > "$SANDBOX/bin/hold-stub"
  chmod +x "$SANDBOX/bin/"*-stub
  cat > "$DAYLOG_GROUPS" <<'EOF'
# test groups
@game        Games
raiders,story   Raiders
ci           Tests and CI
EOF
  echo '[]' > "$GHD/merged"; echo '[]' > "$GHD/open"
  echo '{"sessions":[],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  : > "$DAYLOG_WATCH_LOG"
  SUBJECT="$REPO_ROOT/.local/bin/day-log"
  # 2026-10-28 16:00 PDT
  export DAYLOG_NOW=1793228400
}

# pr <repo> <number> <title> <merged-at-utc>
pr() {
  jq -cn --arg r "$1" --argjson n "$2" --arg t "$3" --arg at "$4" \
    '{number: $n, title: $t, url: "https://example.test/\($r)/\($n)", repository: {name: $r, nameWithOwner: "o/\($r)"}, closedAt: $at}'
}
merged() { jq -s . > "$GHD/merged"; }
rec() { local day="${*: -1}"; jq "${@:1:$#-1}" "$DAYLOG_DIR/$day.json"; }

@test "the day is the LOCAL day: 2026-10-28 in PDT searches 07:00Z to 06:59:59Z next day" {
  run "$SUBJECT" snapshot --date 2026-10-28
  assert_success
  run grep -o -- '--merged-at [^ ]*' "$GHD/calls"
  assert_output '--merged-at 2026-10-28T07:00:00Z..2026-10-29T06:59:59Z'
}

@test "the day the clocks go back is 25 hours long" {
  DAYLOG_NOW=1793563200 run "$SUBJECT" snapshot --date 2026-11-01
  assert_success
  run grep -o -- '--merged-at [^ ]*' "$GHD/calls"
  assert_output '--merged-at 2026-11-01T07:00:00Z..2026-11-02T07:59:59Z'
}

@test "a merged PR is grouped by its scope, a scope list shares a group, an unmapped scope is its own" {
  { pr game 1 'feat(raiders): bosses stay home' 2026-10-28T20:00:00Z
    pr game 2 'fix(story): the intro plays once' 2026-10-28T19:00:00Z
    pr game 3 'feat(hovercraft): skirts' 2026-10-28T18:00:00Z
    pr game 4 'ci: cache the library' 2026-10-28T17:00:00Z
    pr tools 5 'feat(raiders,ci)!: both' 2026-10-28T16:00:00Z
    pr tools 6 'Bump the lockfile' 2026-10-28T15:00:00Z; } | merged
  run "$SUBJECT" snapshot --date 2026-10-28
  assert_success
  run rec -r '.merged[] | [.number, .scope, .group, .area] | @tsv' 2026-10-28
  assert_output "$(printf '%s\n' '6	other	other	tools' '5	raiders	Raiders	tools' '4	ci	Tests and CI	Games' \
    '3	hovercraft	hovercraft	Games' '2	story	Raiders	Games' '1	raiders	Raiders	Games')"
}

@test "a PR is credited to the live session whose worktree is that repo, not a same-number PR elsewhere" {
  { pr game 7 'feat(raiders): x' 2026-10-28T20:00:00Z; pr tools 7 'feat: y' 2026-10-28T20:00:00Z; } | merged
  echo '{"sessions":[{"target":"lab/game-agent-3:1","pr":"7","cwd":"/w/game-agent-3"}],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  run "$SUBJECT" snapshot --date 2026-10-28
  run rec -c '[.merged[] | {repo, by}]' 2026-10-28
  assert_output '[{"repo":"game","by":"agent-3"},{"repo":"tools","by":null}]'
}

@test "a credit seen on an earlier pass is kept after the session has gone, and outcomes fill the rest" {
  { pr game 7 'feat: x' 2026-10-28T20:00:00Z; pr game 8 'feat: y' 2026-10-28T21:00:00Z; } | merged
  echo '{"sessions":[{"target":"lab/game-agent-3:1","pr":"7","cwd":"/w/game-agent-3"}],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  "$SUBJECT" snapshot --date 2026-10-28
  echo '{"sessions":[],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  mkdir -p "$DAYLOG_OUTCOMES_DIR/game"
  echo '{"session_id":"s","title":"game-agent-9","prs":[{"repo":"O/game","number":8,"state":"MERGED"}]}' > "$DAYLOG_OUTCOMES_DIR/game/2026-10.jsonl"
  run "$SUBJECT" snapshot --date 2026-10-28
  run rec -c '[.merged[].by]' 2026-10-28
  assert_output '["agent-3","game-agent-9"]'
}

@test "a blind pass keeps the last good merged list and names what it could not read" {
  pr game 1 'feat: x' 2026-10-28T20:00:00Z | merged
  "$SUBJECT" snapshot --date 2026-10-28
  touch "$GHD/fail"
  run "$SUBJECT" snapshot --date 2026-10-28
  assert_success
  run rec -c '[(.merged | length), .unreadable]' 2026-10-28
  assert_output '[1,["gh merged","gh open"]]'
}

@test "negative control: without a previous record a blind pass has nothing to keep" {
  touch "$GHD/fail"
  run "$SUBJECT" snapshot --date 2026-10-28
  run rec '.merged | length' 2026-10-28
  assert_output 0
}

@test "a past day keeps the live sections it last saw and does not ask gh what is open now" {
  echo '{"sessions":[{"target":"lab/game-agent-3:1","bucket":"NEEDS","reason":"a prompt","idle_min":5}],"main":[{"repo":"game","reason":"game red: Tests"}],"asks":[]}' > "$DAYLOG_STATE"
  DAYLOG_NOW=1793127600 "$SUBJECT" snapshot --date 2026-10-27    # noon on the 27th, live
  : > "$GHD/calls"
  run "$SUBJECT" snapshot --date 2026-10-27                       # now a past day
  assert_success
  run grep -c -- --state=open "$GHD/calls"
  assert_output 0
  run rec -c '[.live, .waiting.main[0].repo, .waiting.needs[0].who, .bench.headline, .fleet.unity_runs]' 2026-10-27
  assert_output '[false,"game","game-agent-3","bench 24h: 2 sessions, 3 phases ticked",2]'
}

@test "json reads a past day's record and refuses a day with none, or one still to come" {
  run "$SUBJECT" json --date 2026-10-20
  assert_failure
  assert_output --partial 'no record for 2026-10-20'
  run "$SUBJECT" json --date 2026-10-29
  assert_failure 2
}

@test "finalize defaults to yesterday, files the notes ref and prints the summary line" {
  pr game 1 'feat(raiders): x' 2026-10-28T03:00:00Z | merged     # 20:00 PDT on the 27th
  run "$SUBJECT" finalize
  assert_success
  assert_output '1 merged across 1 repos'
  run grep -c 'game#1' "$DAYLOG_REFS_DIR/2026-10-27/shipped.md"
  assert_output 1
}

@test "watch --once draws every section and no line passes the width" {
  { pr game 1 'feat(raiders): bosses stay in their lairs and start over when they are left alone' 2026-10-28T20:00:00Z; } | merged
  jq -n '[{number: 9, title: "feat: open thing", url: "u", repository: {name: "game"}, createdAt: "2026-10-28T20:00:00Z", updatedAt: "2026-10-28T21:00:00Z", isDraft: false}]' > "$GHD/open"
  echo '{"sessions":[],"main":[{"repo":"game","reason":"game red: Tests (no green in window)"}],"asks":[{"id":"Ab12","project":"game","kind":"decision","question":"ship it?","created":"2026-10-28T10:00:00-0700"}]}' > "$DAYLOG_STATE"
  echo '2026-10-28 15:00  lab/game-agent-3:1  plan 1/4 -> 2/4' > "$DAYLOG_WATCH_LOG"
  COLUMNS=80 run "$SUBJECT" watch --once
  assert_success
  for s in 'WAITING ON YOU (2)' 'MERGED BY GROUP' 'STILL OPEN' 'SESSIONS' 'TIMELINE' 'HOLD unity since 15:49'; do
    assert_output --partial "$s"
  done
  assert_output --partial '15:00  lab/game-agent-3:1  plan 1/4 -> 2/4'
  run awk 'length > 80' <<<"$output"
  assert_output ''
}

@test "a short pane keeps the summary: each table is cut to its share and says how many more" {
  for i in $(seq 1 30); do pr game "$i" "feat(g$i): thing $i" 2026-10-28T20:00:00Z; done | merged
  LINES=34 COLUMNS=100 run "$SUBJECT" watch --once
  assert_success
  assert_line --index 0 --partial 'day log  Wed 2026-10-28'
  assert_output --partial '+26 more (2 opens it)'
  [ "${#lines[@]}" -le 32 ]
}

@test "negative control: with no height every merged group is drawn" {
  for i in $(seq 1 30); do pr game "$i" "feat(g$i): thing $i" 2026-10-28T20:00:00Z; done | merged
  COLUMNS=100 run "$SUBJECT" watch --once
  refute_output --partial 'more (2 opens it)'
  assert_output --partial 'g30'
}

@test "an open section lists everything in full and folds every other section to its header" {
  for i in $(seq 1 30); do pr game "$i" "feat(g$i): thing $i" "2026-10-28T20:$(printf %02d "$i"):00Z"; done | merged
  COLUMNS=100 run "$SUBJECT" watch --once --open merged
  assert_success
  assert_output --partial '2 MERGED, EVERY PR (30)'
  assert_output --partial '1 WAITING ON YOU (0)'
  assert_output --partial '5 TIMELINE (0)'
  refute_output --partial 'nothing'
  refute_output --partial 'opens it'
  run grep -c 'game#' <<<"$output"
  assert_output 30
  run grep -m1 'game#' <<<"$(COLUMNS=100 "$SUBJECT" watch --once --open 2)"
  assert_output --partial 'game#30'
}

@test "an open section taller than the pane scrolls: it says which rows show, and the board still fits" {
  for i in $(seq 1 30); do pr game "$i" "feat(g$i): thing $i" 2026-10-28T20:00:00Z; done | merged
  LINES=24 COLUMNS=100 run "$SUBJECT" watch --once --open 2
  assert_success
  assert_output --regexp 'rows 1-[0-9]+ of 30'
  assert_output --partial '5 TIMELINE (0)'
  [ "${#lines[@]}" -le 22 ]
}

@test "scrolling stops at the end of the list, so the last row is on screen and no further" {
  for i in $(seq 1 30); do pr game "$i" "feat(g$i): thing $i" 2026-10-28T20:00:00Z; done | merged
  f="$("$SUBJECT" snapshot --date 2026-10-28)"
  source "$SUBJECT"
  frame "$f" 100 24 2 999 > "$SANDBOX/frame"
  [ "$FRAME_OPEN" = 2 ]
  [ "$FRAME_SCROLL" -eq $((30 - FRAME_PAGE)) ]
  run grep -c 'game#1 ' "$SANDBOX/frame"
  assert_output 1
  run grep "of 30" "$SANDBOX/frame"
  assert_output "  rows $((FRAME_SCROLL + 1))-30 of 30"
}

@test "the folded board shows the first asks and points at 1 for the rest; opened, every ask" {
  jq -n '{sessions: [], main: [], asks: [range(1; 10) | {id: "a\(.)", project: "game", kind: "decision", question: "q\(.)?", created: "2026-10-28T10:00:00-0700"}]}' > "$DAYLOG_STATE"
  COLUMNS=100 run "$SUBJECT" watch --once
  assert_output --partial '1 WAITING ON YOU (9)'
  assert_output --partial '+3 older asks (1 opens them)'
  COLUMNS=100 run "$SUBJECT" watch --once --open waiting
  refute_output --partial 'older asks'
  run grep -c 'ASK' <<<"$output"
  assert_output 9
}

@test "a section the day does not have opens nothing, and an unknown one is refused" {
  { pr game 1 'feat: x' 2026-10-28T03:00:00Z; } | merged
  "$SUBJECT" snapshot --date 2026-10-27
  rm -f "$DAYLOG_DIR/2026-10-27.json.tmp"
  jq '.open = null | .bench = null' "$DAYLOG_DIR/2026-10-27.json" > "$SANDBOX/r" && mv "$SANDBOX/r" "$DAYLOG_DIR/2026-10-27.json"
  COLUMNS=100 run "$SUBJECT" watch --once --date 2026-10-27 --open open
  assert_success
  assert_output --partial '2 MERGED BY GROUP'
  refute_output --partial 'STILL OPEN'
  run "$SUBJECT" watch --once --open bogus
  assert_failure 2
}
