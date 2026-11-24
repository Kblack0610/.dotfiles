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
  gh_script 'echo "$PWD" >> "$NOTES_FIXTURE/gh.log"; exit 0'
  # The model saves each prompt and answers from model.out.<board>, else model.out
  stub model-stub 'for a; do case "$a" in *"## Messages"*) echo "the prompt came as an argument" >&2; exit 64 ;; esac; done; p="$(cat)"; b="$(sed -n "1s/^## Messages (\(.*\))$/\1/p" <<<"$p")"; echo "$b" >> "$NOTES_FIXTURE/model.log"; printf "%s" "$p" > "$NOTES_FIXTURE/prompt.$b"
    cat "$NOTES_FIXTURE/model.out.$b" 2>/dev/null || cat "$NOTES_FIXTURE/model.out" 2>/dev/null; exit "$(cat "$NOTES_FIXTURE/model.rc.$b" 2>/dev/null || cat "$NOTES_FIXTURE/model.rc" 2>/dev/null || echo 0)"'
  touch -d '2 days ago' "$ASK_SWEEP_DIR/first-run"
  # The board: add files a row, refused as an open twin (exit 3) when that text is open already;
  # list prints the open rows.
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; rows="$NOTES_FIXTURE/rows.$2"
    case "$4" in add) grep -qxF -- "${@: -1}" "$rows" 2>/dev/null && exit 3; echo "${@: -1}" >> "$rows" ;; list) cat "$rows" 2>/dev/null ;; esac; exit 0'
  stub agent-queue 'printf "agent-queue %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"
    planf="" prj=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --plan) planf="$2"; shift 2 ;;
        --project) prj="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$planf" ] && [ -n "$prj" ] && echo "plan $(basename "$planf" .md): run its open phases" >> "$NOTES_FIXTURE/rows.$prj"
    exit 5'
}

# stub <name> <body>; a notes stub answers `notes row types` too, unless NO_ROW_TYPES is set.
stub() {
  local pre=''
  [ "$1" = notes ] && [ -z "${NO_ROW_TYPES:-}" ] && pre='[ "$1 $2" = "row types" ] && { echo "feat fix chore"; exit 0; }'
  printf '#!/usr/bin/env bash\n%s\n%s\n' "$pre" "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"
}

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
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/stale.md --project board --priority low --from auto:ask-sweep"
  : > "$NOTES_FIXTURE/calls.log"
  run "$SWEEP" run
  assert_success
  assert_not_called 'stale'
}

@test "the board is the only memory: a plan row agent-queue held (exit 5) is filed again on every run, and nothing is kept on the side" {
  plan twin '1 day ago 1 hour ago' "$OPEN"
  stub agent-queue 'printf "agent-queue %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; exit 5'
  run "$SWEEP" run
  assert_success
  : > "$NOTES_FIXTURE/calls.log"
  run "$SWEEP" run
  assert_success
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/twin.md"
  run ls "$ASK_SWEEP_DIR"
  assert_output 'first-run'
}

# 2026-11-10..14 (ar-2111): a board's list outgrew the pipe, so `grep -q` in a pipe cut `notes` off, the
# 141 under pipefail read as "no row", and one plan was filed seven times. The newest row lists first,
# as a board's does, with about 2 MB behind it so the writer is still writing when grep quits; the stub execs cat so it dies of SIGPIPE as notes does.
@test "a plan's row is found when the board's list is longer than a pipe: two runs add one row" {
  plan bigplan '1 day ago 1 hour ago' "$OPEN"
  local rows="$NOTES_FIXTURE/rows.board"
  for i in $(seq 1 20000); do printf 'p\t%s\tk\t- [ ] unrelated row %s with enough words to be long, padding padding padding padding\n' "$i" "$i"; done > "$rows"
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; rows="$NOTES_FIXTURE/rows.board"
    case "$4" in add) { echo "p	0	k	- [ ] ${@: -1}"; cat "$rows"; } > "$rows.new"; mv "$rows.new" "$rows" ;; list) exec cat "$rows" ;; esac; exit 0'
  run "$SWEEP" run
  assert_success
  run "$SWEEP" run
  assert_success
  run grep -c 'bigplan' "$rows"
  assert_output 1
}

@test "a board that cannot be listed files nothing: unreadable is not 'no row'" {
  plan unread '1 day ago 1 hour ago' "$OPEN"
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ "$4" = list ] && exit 1; exit 0'
  run "$SWEEP" run
  assert_success
  assert_not_called ' add '
}

@test "a plan is left alone when finished, superseded, recent, live, older than the first run or already on a row" {
  plan finished '1 day ago 1 hour ago' '## Phases\n\n- [x] one\n- [-] two\n'
  plan superseded '1 day ago 1 hour ago' "Superseded by #9\\n\\n$OPEN"
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


@test "a plan whose every open phase takes a row still open on some board gets no row; closed rows or an unmarked phase file it" {
  plan held '1 day ago 1 hour ago' '## Phases\n\n- [x] one\n- [ ] two (takes ucp-7, takes ucp-8)\n'
  plan closed '1 day ago 1 hour ago' '## Phases\n\n- [x] one\n- [ ] two (takes ucp-9)\n'
  plan unmarked '1 day ago 1 hour ago' '## Phases\n\n- [ ] one (takes ucp-7)\n- [ ] two\n'
  # ucp-8 is started, ucp-9 is done; the feed lists both lanes of every board.
  jq -cn '{rows: [{id: "ucp-8", state: "doing"}, {id: "ucp-9", state: "done"}, {id: "ucp-7", state: "open"}]}' > "$NOTES_FIXTURE/board.json"
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ "$1 $2" = "board --json" ] && cat "$NOTES_FIXTURE/board.json"; exit 0'
  run "$SWEEP" run
  assert_success
  assert_not_called 'held.md'
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/closed.md --project board --priority low --from auto:ask-sweep"
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/unmarked.md --project board --priority low --from auto:ask-sweep"
  [ "$(grep -c 'notes board --json' "$NOTES_FIXTURE/calls.log")" -eq 1 ] || fail "the board feed was read more than once a run"
}

@test "a linked plans dir is swept, a plan named through another link counts as live, and _live is no project" {
  rm -rf "$ASK_SWEEP_PLANS"; mkdir -p "$SANDBOX/store" "$ASK_SWEEP_PLAN_CACHE/_live"
  ln -s "$SANDBOX/store" "$ASK_SWEEP_PLANS"          # ~/.claude/plans -> ~/.agent/plans/_live
  ln -s "$SANDBOX/store" "$SANDBOX/acct-plans"       # an account's plans link
  plan open '1 day ago 1 hour ago' "$OPEN"
  plan live '1 day ago 1 hour ago' "$OPEN"
  plan storeonly '1 day ago 1 hour ago' "$OPEN"
  rm "$ASK_SWEEP_PLAN_CACHE/board/storeonly.md"; : > "$ASK_SWEEP_PLAN_CACHE/_live/storeonly.md"
  jq -cn --arg f "$SANDBOX/acct-plans/live.md" '[{plan_file: $f}]' > "$NOTES_FIXTURE/live.json"
  run "$SWEEP" run
  assert_success
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/open.md --project board --priority low --from auto:ask-sweep"
  assert_not_called 'live.md'
  assert_not_called 'storeonly.md'
  assert_not_called '--project _live'
}

@test "a plan fleet-dispatch reap filed gets no row, by its own name or its pointer stub's; one reap did not file gets its row" {
  plan filed '1 day ago 1 hour ago' "$OPEN"
  mkdir -p "$SANDBOX/elsewhere"; printf '# real\n\n%b\n' "$OPEN" > "$SANDBOX/elsewhere/real.md"; : > "$ASK_SWEEP_PLAN_CACHE/board/real.md"
  plan unfiled '1 day ago 1 hour ago' "$OPEN"
  printf 'Phase 2 of %s\n' "$SANDBOX/elsewhere/real.md" > "$ASK_SWEEP_PLANS/random-name.md"
  touch -d '1 day ago 1 hour ago' "$ASK_SWEEP_PLANS/random-name.md"
  export FLEET_DISPATCH_DIR="$SANDBOX/dispatch"; mkdir -p "$FLEET_DISPATCH_DIR"
  printf '%s\n' "$SANDBOX/acct/plans/filed.md" "$SANDBOX/acct/plans/random-name.md" > "$FLEET_DISPATCH_DIR/plans-filed"
  run "$SWEEP" run
  assert_success
  assert_not_called '/filed.md'
  assert_not_called 'real.md'
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/unfiled.md --project board --priority low --from auto:ask-sweep"
}

@test "a plan with no checklist files no row and is only counted" {
  plan bare '1 day ago 1 hour ago' 'just text'
  plan landed '1 day ago 1 hour ago' '## Results\n\nshipped'
  run "$SWEEP" run
  assert_success
  assert_not_called ' add '
  assert_output --partial 'no checklist 1'
}

@test "an open plan with no cache copy files no row and is counted, not dropped unseen" {
  plan orphan '1 day ago 1 hour ago' "$OPEN"
  rm "$ASK_SWEEP_PLAN_CACHE/board/orphan.md"
  plan homed '1 day ago 1 hour ago' "$OPEN"
  run "$SWEEP" run
  assert_success
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/homed.md --project board --priority low --from auto:ask-sweep"
  assert_not_called 'orphan'
  assert_output --partial 'open plans 2'
  assert_output --partial 'no cache copy 1'
}

@test "the summary says what it read, so a clean read never looks like no read" {
  plan bare '1 day ago 1 hour ago' 'just text'
  message 'add a slide'
  message 'and a swing'
  answer
  run "$SWEEP" run
  assert_success
  assert_output --partial 'read 1 plans and 1 transcripts (0 unreadable, 2 new messages), asked 1 boards, filed 0'
  # the same run again: the transcript is read, its messages are past the watermark
  run "$SWEEP" run
  assert_success
  assert_output --partial 'read 1 plans and 1 transcripts (0 unreadable, 0 new messages), asked 0 boards'
}

@test "a missing transcripts or plans dir is FAILED with why, not a clean zero" {
  rmdir "$ASK_SWEEP_TRANSCRIPTS"
  run "$SWEEP" run
  assert_failure
  assert_output --partial 'no transcripts dir'
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/ask-sweep/last-outcome")" FAILED
  mkdir "$ASK_SWEEP_TRANSCRIPTS"; rmdir "$ASK_SWEEP_PLANS"
  run "$SWEEP" run
  assert_failure
  run tail -1 "$AGENTCTL_STATE_DIR/ask-sweep/activity.log"
  assert_output --partial 'why: no plans dir'
}

@test "a bad line hides no message after it, and a transcript with no cwd is counted unreadable" {
  local f="$ASK_SWEEP_TRANSCRIPTS/x-board/s.jsonl"
  message 'before the cut'
  printf '{"type":"user","trunc\n' >> "$f"
  message 'after the cut'
  mkdir -p "$ASK_SWEEP_TRANSCRIPTS/x-nocwd"
  echo '{"type":"summary"}' > "$ASK_SWEEP_TRANSCRIPTS/x-nocwd/s.jsonl"
  touch -d '1 hour ago' "$ASK_SWEEP_TRANSCRIPTS/x-nocwd/s.jsonl"
  answer
  run "$SWEEP" run
  assert_success
  assert_output --partial '1 transcripts (1 unreadable, 2 new messages)'
  run cat "$NOTES_FIXTURE/prompt.board"
  assert_output --partial 'after the cut'
}

@test "a cwd-less transcript beside a good one does not hide its dir, and none readable is FAILED" {
  message 'add a slide'
  echo '{"type":"summary"}' > "$ASK_SWEEP_TRANSCRIPTS/x-board/a.jsonl"
  touch -d '1 hour ago' "$ASK_SWEEP_TRANSCRIPTS/x-board/a.jsonl"
  answer
  run "$SWEEP" run
  assert_success
  assert_output --partial '2 transcripts (0 unreadable, 1 new messages)'
  rm "$ASK_SWEEP_TRANSCRIPTS/x-board/s.jsonl"
  run "$SWEEP" run
  assert_failure
  assert_output --partial '0 transcripts (1 unreadable'
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/ask-sweep/last-outcome")" FAILED
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
  assert_called "feat(gym): add a slide; asked $(date -u -d '40 hours ago' +%m-%d) \"add a slide\" #tier/2 #size/s #worker/requested"
  assert_called "feat(town): build a town; asked $TODAY \"new town\" #tier/2 #size/l"
  assert_not_called "build a town; asked $TODAY \"new town\" #tier/2 #size/l #worker"
  assert_not_called "tune ci; asked $TODAY \"retune ci\" #tier/3 #size/s #worker"
  assert_not_called '#requested'
}

@test "a human-only ask goes on the human sheet, never the agent board" {
  message 'buy the clip pack'
  answer '{"quote":"buy it","row":"buy the clip pack","tier":2,"size":"S","done_is_stated":true,"human_only":true}'
  run "$SWEEP" run
  assert_called 'ptask board add --want ask buy the clip pack'
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
  [ "$(grep -c 'agent-queue add --plan' "$NOTES_FIXTURE/calls.log")" -eq 2 ]
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
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/stale.md --project board --priority low --from auto:ask-sweep"
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/ask-sweep/last-outcome")" FAILED
  run tail -1 "$AGENTCTL_STATE_DIR/ask-sweep/activity.log"
  assert_output --partial 'why: board: model call failed (exit 1)'
}

@test "a plan agent-queue refuses takes no cap slot, and the run records which plan" {
  ASK_SWEEP_MAX=2   # room for both: a refusal that took a slot reads "filed 2"
  export ASK_SWEEP_MAX
  plan bad '1 day ago 1 hour ago' "$OPEN"; plan good '1 day ago 1 hour ago' "$OPEN"
  stub agent-queue 'printf "agent-queue %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"
    case "$*" in *bad.md*) echo "agent-queue: --plan bad.md: a phase marker names no result" >&2; exit 1 ;; esac; exit 5'
  run "$SWEEP" run
  assert_failure
  assert_output --partial "could not file the plan $ASK_SWEEP_PLANS/bad.md: agent-queue: --plan bad.md: a phase marker names no result"
  assert_called "agent-queue add --plan $ASK_SWEEP_PLANS/good.md"
  assert_output --partial 'filed 1, over the cap 0'
  run tail -1 "$AGENTCTL_STATE_DIR/ask-sweep/activity.log"
  assert_output --partial 'why: plan bad refused by agent-queue'
}

@test "a notes with no row types asks no model and records why" {
  message 'add a slide'
  NO_ROW_TYPES=1 stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ "$1" = row ] && exit 2; exit 0'
  run "$SWEEP" run
  assert_failure
  assert_output --partial 'board: notes row types failed'
  [ ! -f "$NOTES_FIXTURE/model.log" ]
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/ask-sweep/last-outcome")" FAILED
}

@test "a budget stop is BLOCKED with its reason, and the board is asked again next run" {
  message 'add a slide'
  echo 75 > "$NOTES_FIXTURE/model.rc"
  run "$SWEEP" run
  assert_failure 75
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/ask-sweep/last-outcome")" BLOCKED
  run tail -1 "$AGENTCTL_STATE_DIR/ask-sweep/activity.log"
  assert_output --regexp 'outcome=BLOCKED budget: .*why: board: stopped at its budget'
  [ ! -s "$ASK_SWEEP_DIR/since/board" ]
  rm "$NOTES_FIXTURE/model.rc"; answer '{"quote":"add a slide","row":"gym: add a slide","tier":2,"size":"M"}'
  run "$SWEEP" run
  assert_success
  assert_called 'gym: add a slide'
}

@test "a budget stop on one board and a failed call on another is FAILED, exit 1" {
  message 'add a slide'
  message 'two words' two
  printf 'p\t1\tk\t- [ ] a two row\n' > "$NOTES_FIXTURE/ptask.two.list"
  echo 75 > "$NOTES_FIXTURE/model.rc.board"
  echo 1 > "$NOTES_FIXTURE/model.rc.two"
  run "$SWEEP" run
  assert_failure 1
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/ask-sweep/last-outcome")" FAILED
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
  assert_output --partial $'## Row types\nfeat fix chore'
  assert_output --partial 'a two row'
  refute_output --partial 'board words'
  run cat "$NOTES_FIXTURE/prompt.board" "$NOTES_FIXTURE/prompt.two"
  refute_output --partial 'client words'
  refute_output --partial 'loose words'
  assert_equal "$(sort -u "$NOTES_FIXTURE/gh.log" | paste -sd,)" "$R/board,$R/two"
}

# 2026-11-23 (ar-4669): told "one short lowercase word", the model filed areas like cluster and
# gameplay, and the nightly --link pass swapped 25 of them to a system id, each a scored miss.
@test "each board's prompt names its systems, the area vocabulary; a board with none gets an empty list" {
  message 'board words'
  message 'two words' two
  stub project-stage-check '[ "$1 $2" = "two --list" ] && printf "ci\tdoc\t\tBuild\nviews\tdoc\thub,waybar\tViews\n"; exit 0'
  answer
  run "$SWEEP" run
  assert_success
  run cat "$NOTES_FIXTURE/prompt.two"
  assert_output --partial $'## Systems\ntwo: ci, views (also: hub=views, waybar=views)'
  assert_equal "$(tail -n 1 "$NOTES_FIXTURE/prompt.board")" '## Systems'
}

@test "a board whose open rows pass 128 KiB still reaches the model: the prompt goes on stdin" {
  # 2026-11-12: agent-runtime's 780 open rows made one argument too long (E2BIG, exit 126).
  message 'two words' two
  for i in $(seq 1 3000); do printf 'p\t%s\tk\t- [ ] row %s %s\n' "$i" "$i" "$(printf 'x%.0s' $(seq 1 90))"; done > "$NOTES_FIXTURE/ptask.two.list"
  stub notes 'printf "notes %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ "$1 $2" = "ptask two" ] && [ "$3" = --agent ] && cat "$NOTES_FIXTURE/ptask.two.list"; exit 0'
  answer
  run "$SWEEP" run
  assert_success
  refute_output --partial 'model call failed'
  [ "$(wc -c < "$NOTES_FIXTURE/prompt.two")" -gt 131072 ] || fail "the fixture never passed the argument cap"
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
  assert_output --partial 'would file [board] plan stale: run its open phases'
  assert_not_called ' add '
}

@test "a pointer stub files no row: the plan it names is swept as itself (ar-2513)" {
  plan canon '1 day ago 1 hour ago' "$OPEN"
  plan stub '1 day ago 1 hour ago' "Phase 3 of $ASK_SWEEP_PLANS/canon.md\n\n## Phases\n\n- [ ] three\n"
  run "$SWEEP" run
  assert_success
  [ "$(grep -c 'plan canon' "$NOTES_FIXTURE/rows.board")" = 1 ]
  run grep -q 'plan stub' "$NOTES_FIXTURE/rows.board"
  [ "$status" -ne 0 ]
  # negative control: the same stub pointing nowhere is a plan of its own and files its row
  plan stub '1 day ago 1 hour ago' "Phase 3 of $ASK_SWEEP_PLANS/nowhere.md\n\n## Phases\n\n- [ ] three\n"
  run "$SWEEP" run
  assert_success
  grep -q 'plan canon' "$NOTES_FIXTURE/rows.board"
  grep -q 'plan stub' "$NOTES_FIXTURE/rows.board"
}
