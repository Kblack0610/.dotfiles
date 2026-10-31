#!/usr/bin/env bats
# ask-sweep: unfinished plans and missed asks get one row each, and never twice.
# 2026-10-31: 15 plans sat with unticked phases and nothing watching them.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SWEEP="$REPO_ROOT/.local/bin/ask-sweep"
  export ASK_SWEEP_DIR="$SANDBOX/state" ASK_SWEEP_PLANS="$SANDBOX/plans"
  export ASK_SWEEP_PLAN_CACHE="$SANDBOX/cache" ASK_SWEEP_TRANSCRIPTS="$SANDBOX/projects"
  export ASK_SWEEP_REPOS=playground ASK_SWEEP_BOARD=board ASK_SWEEP_QUIET_MIN=0
  export ASK_SWEEP_CMD=model-stub
  mkdir -p "$ASK_SWEEP_DIR" "$ASK_SWEEP_PLANS" "$ASK_SWEEP_PLAN_CACHE/board" "$ASK_SWEEP_TRANSCRIPTS/x-playground"
  stub fleet-sessions 'cat "$NOTES_FIXTURE/live.json" 2>/dev/null; exit 0'
  stub gh 'exit 0'
  stub model-stub 'echo called >> "$NOTES_FIXTURE/model.log"; cat "$NOTES_FIXTURE/model.out" 2>/dev/null; exit "$(cat "$NOTES_FIXTURE/model.rc" 2>/dev/null || echo 0)"'
  touch -d '2 days ago' "$ASK_SWEEP_DIR/first-run"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# plan <slug> <age> <body>
plan() {
  printf '# %s\n\n%b\n' "$1" "$3" > "$ASK_SWEEP_PLANS/$1.md"
  touch -d "$2" "$ASK_SWEEP_PLANS/$1.md"
  : > "$ASK_SWEEP_PLAN_CACHE/board/$1.md"
}
OPEN='## Phases\n\n- [x] one\n- [ ] two\n- [ ] three\n'

# message <text>: a human message dated 2026-10-30 in a transcript.
message() {
  jq -cn --arg t "$1" '{type: "user", timestamp: "2026-10-30T12:00:00Z", message: {content: $t}}' \
    >> "$ASK_SWEEP_TRANSCRIPTS/x-playground/s.jsonl"
  touch -d '1 hour ago' "$ASK_SWEEP_TRANSCRIPTS/x-playground/s.jsonl"
}
# answer <json line>...: what the model replies.
answer() { { echo ASK-SWEEP-START; printf '%s\n' "$@"; echo ASK-SWEEP-END; } > "$NOTES_FIXTURE/model.out"; }

@test "an unfinished plan gets one row with what is left, and a second run files nothing" {
  plan stale '1 day ago 1 hour ago' "$OPEN"
  run "$SWEEP" run --date 2026-10-30
  assert_success
  assert_called 'ptask board --agent add finish stale: 2 phases left, next: two #ask #tier/2'
  : > "$NOTES_FIXTURE/calls.log"
  run "$SWEEP" run --date 2026-10-30
  assert_success
  assert_not_called 'finish stale'
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
  run "$SWEEP" run --date 2026-10-30
  assert_success
  assert_not_called ' add '
}

@test "a plan with no checklist files no row and is only counted" {
  plan bare '1 day ago 1 hour ago' 'just text'
  plan landed '1 day ago 1 hour ago' '## Results\n\nshipped'
  run "$SWEEP" run --date 2026-10-30
  assert_success
  assert_not_called ' add '
  run "$SWEEP" report
  assert_output --partial '1 with no checklist'
}

@test "a missed ask is filed with its quote, and a small clear one joins the downtime queue" {
  message 'add a slide to the gym'
  answer '{"quote":"add a slide","row":"gym: add a slide","tier":2,"size":"S","done_is_stated":true,"human_only":false}' \
         '{"quote":"new town","row":"build a town","tier":2,"size":"L","done_is_stated":false,"human_only":false}' \
         '{"quote":"retune ci","row":"tune ci","tier":3,"size":"S","done_is_stated":true,"human_only":false}'
  run "$SWEEP" run --date 2026-10-30
  assert_success
  assert_called 'gym: add a slide; asked 10-30 "add a slide" #ask #tier/2 #worker/asks'
  assert_called 'build a town; asked 10-30 "new town" #ask #tier/2'
  assert_not_called 'build a town; asked 10-30 "new town" #ask #tier/2 #worker'
  assert_not_called 'tune ci; asked 10-30 "retune ci" #ask #tier/3 #worker'
}

@test "a human-only ask goes on the human sheet, never the agent board" {
  message 'buy the clip pack'
  answer '{"quote":"buy it","row":"buy the clip pack","tier":2,"size":"S","done_is_stated":true,"human_only":true}'
  run "$SWEEP" run --date 2026-10-30
  assert_called 'ptask board add buy the clip pack'
  assert_not_called 'ptask board --agent add buy'
}

@test "the same quote is not filed twice, whatever the model says on the next run" {
  message 'add a slide'
  answer '{"quote":"Add a slide","row":"gym: add a slide","tier":2,"size":"M"}'
  run "$SWEEP" run --date 2026-10-30
  assert_called 'gym: add a slide'
  : > "$NOTES_FIXTURE/calls.log"
  answer '{"quote":"add a slide","row":"gym gets a slide","tier":2,"size":"M"}'
  run "$SWEEP" run --date 2026-10-30
  assert_not_called 'slide'
}

@test "the nightly cap holds, and the overflow is reported as a count" {
  export ASK_SWEEP_MAX=2
  plan a '1 day ago 1 hour ago' "$OPEN"; plan b '1 day ago 1 hour ago' "$OPEN"; plan c '1 day ago 1 hour ago' "$OPEN"
  run "$SWEEP" run --date 2026-10-30
  assert_success
  [ "$(grep -c ' add finish ' "$NOTES_FIXTURE/calls.log")" -eq 2 ]
  run "$SWEEP" report
  assert_output --partial '(1 more over the cap)'
}

@test "machine messages, tool results and other days never reach the model" {
  message '<task-notification>done</task-notification>'
  jq -cn '{type: "user", timestamp: "2026-10-30T12:00:00Z", message: {content: [{type: "tool_result", content: "x"}]}}' >> "$ASK_SWEEP_TRANSCRIPTS/x-playground/s.jsonl"
  jq -cn '{type: "user", timestamp: "2026-10-29T12:00:00Z", message: {content: "yesterday words"}}' >> "$ASK_SWEEP_TRANSCRIPTS/x-playground/s.jsonl"
  jq -cn '{type: "user", isSidechain: true, timestamp: "2026-10-30T12:00:00Z", message: {content: "agent words"}}' >> "$ASK_SWEEP_TRANSCRIPTS/x-playground/s.jsonl"
  touch -d '1 hour ago' "$ASK_SWEEP_TRANSCRIPTS/x-playground/s.jsonl"
  run "$SWEEP" run --date 2026-10-30
  assert_success
  [ ! -f "$NOTES_FIXTURE/model.log" ]
}

@test "a failed model call says so and still files the plans" {
  plan stale '1 day ago 1 hour ago' "$OPEN"
  message 'add a slide'
  echo 1 > "$NOTES_FIXTURE/model.rc"
  run "$SWEEP" run --date 2026-10-30
  assert_failure
  assert_output --partial 'model call failed'
  assert_called 'finish stale'
}

@test "--dry-run prints what it would file and writes nothing" {
  plan stale '1 day ago 1 hour ago' "$OPEN"
  run "$SWEEP" run --dry-run --date 2026-10-30
  assert_success
  assert_output --partial 'would file [board] finish stale'
  assert_not_called ' add '
  [ ! -f "$ASK_SWEEP_DIR/plans-filed" ]
}
