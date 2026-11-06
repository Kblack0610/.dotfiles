#!/usr/bin/env bats
# ask-sweep: unfinished plans and missed asks get one row each, and never twice.
# 2026-10-31: 15 plans sat with unticked phases and nothing watching them.
# 2026-11-05: it read one repo, once a night; now every repo with a board and no client, per board.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SWEEP="$REPO_ROOT/.local/bin/ask-sweep"
  export ASK_SWEEP_DIR="$SANDBOX/state" ASK_SWEEP_PLANS="$SANDBOX/plans"
  export ASK_SWEEP_PLAN_CACHE="$SANDBOX/cache" ASK_SWEEP_TRANSCRIPTS="$SANDBOX/projects"
  export ASK_SWEEP_QUIET_MIN=0 ASK_SWEEP_CMD=model-stub AGENTCTL_STATE_DIR="$SANDBOX/agentctl"
  mkdir -p "$ASK_SWEEP_DIR" "$ASK_SWEEP_PLANS" "$ASK_SWEEP_PLAN_CACHE/board" "$ASK_SWEEP_TRANSCRIPTS"
  # The registry: two personal repos with a board each, a client repo, and one with no board.
  R="$SANDBOX/repos"; mkdir -p "$R/board" "$R/two" "$R/work" "$R/loose"
  export PROJECT_MAP_FILE="$SANDBOX/project-map.json"
  jq -n --arg r "$R" '{paths: {"\($r)/board": "board", "\($r)/two": "two", "\($r)/work": "work", "\($r)/loose": "loose"},
    trackers: {_comment: "x", board: {lab: "personal"}, two: {lab: "bnb"}, work: {lab: "client", client: "acme"}}}' > "$PROJECT_MAP_FILE"
  stub fleet-sessions 'cat "$NOTES_FIXTURE/live.json" 2>/dev/null; exit 0'
  stub gh 'echo "$PWD" >> "$NOTES_FIXTURE/gh.log"; exit 0'
  # The model saves each prompt and answers from model.out.<board>, else model.out
  stub model-stub 'b="$(sed -n "1s/^## Messages (\(.*\))$/\1/p" <<<"$2")"; echo "$b" >> "$NOTES_FIXTURE/model.log"; printf "%s" "$2" > "$NOTES_FIXTURE/prompt.$b"
    cat "$NOTES_FIXTURE/model.out.$b" 2>/dev/null || cat "$NOTES_FIXTURE/model.out" 2>/dev/null; exit "$(cat "$NOTES_FIXTURE/model.rc.$b" 2>/dev/null || cat "$NOTES_FIXTURE/model.rc" 2>/dev/null || echo 0)"'
  touch -d '2 days ago' "$ASK_SWEEP_DIR/first-run"
  # The board: add files a row, refused as an open twin (exit 3) when that text is open already;
  # list prints the open rows.
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; rows="$NOTES_FIXTURE/rows.$2"
    case "$4" in add) grep -qxF -- "$5" "$rows" 2>/dev/null && exit 3; echo "$5" >> "$rows" ;; list) cat "$rows" 2>/dev/null ;; esac; exit 0'
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# plan <slug> <age> <body>
plan() {
  printf '# %s\n\n%b\n' "$1" "$3" > "$ASK_SWEEP_PLANS/$1.md"
  touch -d "$2" "$ASK_SWEEP_PLANS/$1.md"
  : > "$ASK_SWEEP_PLAN_CACHE/board/$1.md"
}
OPEN='## Phases\n\n- [x] one\n- [ ] two\n- [ ] three\n'

# message <text> [repo] [age]: a human message in a session run in that repo (default board), sent
# that long ago (default 3 hours); the transcript was last written an hour ago.
message() {
  local repo="${2:-board}" f
  f="$ASK_SWEEP_TRANSCRIPTS/x-$repo/s.jsonl"; mkdir -p "${f%/*}"
  jq -cn --arg t "$1" --arg c "$R/$repo" --arg ts "$(date -u -d "${3:-3 hours ago}" +%FT%T.000Z)" \
    '{type: "user", cwd: $c, timestamp: $ts, message: {content: $t}}' >> "$f"
  touch -d '1 hour ago' "$f"
}
TODAY="$(date -u -d '3 hours ago' +%m-%d)"
# answer <json line>...: what the model replies.
answer() { { echo ASK-SWEEP-START; printf '%s\n' "$@"; echo ASK-SWEEP-END; } > "$NOTES_FIXTURE/model.out"; }

@test "an unfinished plan gets one row with what is left, and a second run files nothing" {
  plan stale '1 day ago 1 hour ago' "$OPEN"
  run "$SWEEP" run
  assert_success
  assert_called 'ptask board --agent add chore(plan): finish stale: 2 phases left, next: two #requested #tier/2 #size/m'
  : > "$NOTES_FIXTURE/calls.log"
  run "$SWEEP" run
  assert_success
  assert_not_called 'finish stale'
}

@test "the board is the only memory: an open twin (exit 3) is refused on every run, and nothing is kept on the side" {
  plan twin '1 day ago 1 hour ago' "$OPEN"
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ "$4" = add ] && exit 3; exit 0'
  run "$SWEEP" run
  assert_success
  : > "$NOTES_FIXTURE/calls.log"
  run "$SWEEP" run
  assert_success
  assert_called 'ptask board --agent add chore(plan): finish twin'
  run ls "$ASK_SWEEP_DIR"
  assert_output 'first-run'
}

@test "a plan is left alone when finished, recent, live, older than the first run or already on a row" {
  plan finished '1 day ago 1 hour ago' '## Phases\n\n- [x] one\n- [-] two\n'
  plan recent '1 hour ago' "$OPEN"
  plan live '1 day ago 1 hour ago' "$OPEN"
  plan ancient '5 days ago' "$OPEN"
  plan onrow '1 day ago 1 hour ago' "$OPEN"
  jq -cn --arg f "$ASK_SWEEP_PLANS/live.md" '[{plan_file: $f}]' > "$NOTES_FIXTURE/live.json"
  printf 'p\t1\tk\t- [ ] finish onrow: filed by its wind-down\n' > "$NOTES_FIXTURE/ptask.board.list"
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ "$3" = --agent ] && [ "$4" = list ] && cat "$NOTES_FIXTURE/ptask.board.list"; exit 0'
  run "$SWEEP" run
  assert_success
  assert_not_called ' add '
}

@test "a plan with no checklist files no row and is only counted" {
  plan bare '1 day ago 1 hour ago' 'just text'
  plan landed '1 day ago 1 hour ago' '## Results\n\nshipped'
  run "$SWEEP" run
  assert_success
  assert_not_called ' add '
  assert_output --partial 'no checklist 1'
}

@test "a missed ask is filed with its quote, and a small clear one joins the downtime queue" {
  message 'add a slide to the gym' board '40 hours ago'
  message 'and something else'
  answer '{"quote":"add a slide","row":"feat(gym): add a slide","tier":2,"size":"S","done_is_stated":true,"human_only":false}' \
         '{"quote":"new town","row":"feat(town): build a town","tier":2,"size":"L","done_is_stated":false,"human_only":false}' \
         '{"quote":"retune ci","row":"ci(build): tune ci","tier":3,"size":"S","done_is_stated":true,"human_only":false}'
  run "$SWEEP" run
  assert_success
  # the quoted message's own day; a quote found in no message gets the newest one's
  assert_called "feat(gym): add a slide; asked $(date -u -d '40 hours ago' +%m-%d) \"add a slide\" #requested #tier/2 #size/s #worker/requested"
  assert_called "feat(town): build a town; asked $TODAY \"new town\" #requested #tier/2 #size/l"
  assert_not_called "build a town; asked $TODAY \"new town\" #requested #tier/2 #size/l #worker"
  assert_not_called "tune ci; asked $TODAY \"retune ci\" #requested #tier/3 #size/s #worker"
}

@test "a human-only ask goes on the human sheet, never the agent board" {
  message 'buy the clip pack'
  answer '{"quote":"buy it","row":"buy the clip pack","tier":2,"size":"S","done_is_stated":true,"human_only":true}'
  run "$SWEEP" run
  assert_called 'ptask board add buy the clip pack'
  assert_not_called 'ptask board --agent add buy'
}

@test "the same quote is not filed twice, whatever the model says on the next run" {
  message 'add a slide'
  answer '{"quote":"Add a slide","row":"gym: add a slide","tier":2,"size":"M"}'
  run "$SWEEP" run
  assert_called 'gym: add a slide'
  : > "$NOTES_FIXTURE/calls.log"
  answer '{"quote":"add a slide","row":"gym gets a slide","tier":2,"size":"M"}'
  run "$SWEEP" run
  assert_not_called 'slide'
}

@test "the run's cap holds, and the overflow is reported as a count" {
  export ASK_SWEEP_MAX=2
  plan slug-a '1 day ago 1 hour ago' "$OPEN"; plan slug-b '1 day ago 1 hour ago' "$OPEN"; plan slug-c '1 day ago 1 hour ago' "$OPEN"
  run "$SWEEP" run
  assert_success
  [ "$(grep -c ' add chore(plan): finish ' "$NOTES_FIXTURE/calls.log")" -eq 2 ]
  assert_output --partial 'over the cap 1'
}

@test "machine messages, tool results and messages older than the lookback never reach the model" {
  local f="$ASK_SWEEP_TRANSCRIPTS/x-board/s.jsonl" ts
  message '<task-notification>done</task-notification>'
  ts="$(date -u -d '3 hours ago' +%FT%TZ)"
  jq -cn --arg c "$R/board" --arg ts "$ts" '{type: "user", cwd: $c, timestamp: $ts, message: {content: [{type: "tool_result", content: "x"}]}}' >> "$f"
  jq -cn --arg c "$R/board" --arg ts "$ts" '{type: "user", cwd: $c, isSidechain: true, timestamp: $ts, message: {content: "agent words"}}' >> "$f"
  message 'old words' board '3 days ago'
  run "$SWEEP" run
  assert_success
  [ ! -f "$NOTES_FIXTURE/model.log" ]
}

@test "a failed model call says so, still files the plans, and records why" {
  plan stale '1 day ago 1 hour ago' "$OPEN"
  message 'add a slide'
  echo 1 > "$NOTES_FIXTURE/model.rc"
  run "$SWEEP" run
  assert_failure
  assert_output --partial 'board: model call failed (exit 1)'
  assert_called 'finish stale'
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/ask-sweep/last-outcome")" FAILED
  run tail -1 "$AGENTCTL_STATE_DIR/ask-sweep/activity.log"
  assert_output --partial 'why: board: model call failed (exit 1)'
}

@test "a budget stop is BLOCKED with its reason, and the board is asked again next run" {
  message 'add a slide'
  echo 75 > "$NOTES_FIXTURE/model.rc"
  run "$SWEEP" run
  assert_failure
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/ask-sweep/last-outcome")" BLOCKED
  run tail -1 "$AGENTCTL_STATE_DIR/ask-sweep/activity.log"
  assert_output --partial 'why: board: stopped at its budget'
  [ ! -s "$ASK_SWEEP_DIR/since/board" ]
  rm "$NOTES_FIXTURE/model.rc"; answer '{"quote":"add a slide","row":"gym: add a slide","tier":2,"size":"M"}'
  run "$SWEEP" run
  assert_success
  assert_called 'gym: add a slide'
}

@test "one call per board with its own rows and checkout; a client repo and a repo with no board are never read" {
  message 'board words'
  message 'two words' two
  message 'client words' work
  message 'loose words' loose
  printf 'p\t1\tk\t- [ ] a two row\n' > "$NOTES_FIXTURE/ptask.two.list"
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ "$1 $2" = "ptask two" ] && [ "$3" = --agent ] && cat "$NOTES_FIXTURE/ptask.two.list"; exit 0'
  answer
  run "$SWEEP" run
  assert_success
  assert_equal "$(sort "$NOTES_FIXTURE/model.log" | paste -sd,)" 'board,two'
  run cat "$NOTES_FIXTURE/prompt.two"
  assert_output --partial '"two words"'
  assert_output --partial 'a two row'
  refute_output --partial 'board words'
  run cat "$NOTES_FIXTURE/prompt.board" "$NOTES_FIXTURE/prompt.two"
  refute_output --partial 'client words'
  refute_output --partial 'loose words'
  assert_equal "$(sort -u "$NOTES_FIXTURE/gh.log" | paste -sd,)" "$R/board,$R/two"
}

@test "a second run with nothing new makes no call; a new message asks only its board" {
  message 'board words'
  message 'two words' two
  answer
  run "$SWEEP" run
  assert_success
  : > "$NOTES_FIXTURE/model.log"
  run "$SWEEP" run
  assert_success
  [ ! -s "$NOTES_FIXTURE/model.log" ]
  message 'more two words' two '30 minutes ago'
  run "$SWEEP" run
  assert_equal "$(cat "$NOTES_FIXTURE/model.log")" two
  run cat "$NOTES_FIXTURE/prompt.two"
  assert_output --partial 'more two words'
  refute_output --partial '"two words"'
}

@test "a failed board keeps its watermark while the others move" {
  message 'board words'
  message 'two words' two
  answer
  echo 1 > "$NOTES_FIXTURE/model.rc.two"
  run "$SWEEP" run
  assert_failure
  [ -s "$ASK_SWEEP_DIR/since/board" ]
  [ ! -e "$ASK_SWEEP_DIR/since/two" ]
}

@test "messages over the byte cap wait, oldest first, for the next run" {
  export ASK_SWEEP_MSG_BYTES=30
  message 'first words here' board '5 hours ago'
  message 'second words here' board '4 hours ago'
  answer
  run "$SWEEP" run
  assert_success
  assert_output --partial 'board: 1 messages wait for the next run'
  run cat "$NOTES_FIXTURE/prompt.board"
  assert_output --partial 'first words'
  refute_output --partial 'second words'
  run "$SWEEP" run
  run cat "$NOTES_FIXTURE/prompt.board"
  assert_output --partial 'second words'
  refute_output --partial 'first words'
}

@test "--dry-run prints what it would file and writes nothing" {
  plan stale '1 day ago 1 hour ago' "$OPEN"
  run "$SWEEP" run --dry-run
  assert_success
  assert_output --partial 'would file [board] chore(plan): finish stale'
  assert_not_called ' add '
}
