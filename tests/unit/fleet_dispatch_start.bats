#!/usr/bin/env bats
# fleet-dispatch, `start` and `fill`: launching one session by hand and topping the queue up.
# One file of six (tests/unit/fleet_dispatch*.bats), split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

@test "fill promotes picks into the queue with no gate and starts nothing; --dry-run lists them" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_success
  assert_line --index 0 'ready     game (beta) human, fleet, fix crash on load, high: fix crash on load [fleet, #high, beta]'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "fill --dry-run queued an item"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_output --partial 'queued game: gm-1'
  [ -n "$(qitem queued gm-1)" ] || fail "not queued"
  assert_not_called 'wt new'
}

@test "fill by hand with no DISPATCH_PER_PASS promotes up to DISPATCH_LOW_WATER picks, not every pick" {
  game_ready
  local a; for a in save menu audio; do
    row game human "fix crash on $a" "- [ ] fix crash on $a $T"
    verdict game human "fix crash on $a" dispatch S 1 "$a"
  done
  unset DISPATCH_PER_PASS
  DISPATCH_LOW_WATER=2 run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 2
}

@test "a queued board item holds its area against another pick" {
  game_ready
  row game human 'fix crash on save' "- [ ] fix crash on save $T"
  verdict game human 'fix crash on save' dispatch S 1 'fix crash on load'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  refute_output --partial 'ready'
}

@test "a board item that ends failed or cancelled hands its row back once, recorded failed" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  grep -qF -- '- [/] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
  agent-queue cancel gm-1
  run cmd_reap
  assert_success
  assert_output --partial 'un-started game: gm-1 (queue item gm-1 ended cancelled)'
  grep -qF -- '- [ ] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not un-started"
  assert_equal "$(tail -1 "$FLEET_DISPATCH_DIR/verdicts.jsonl" | jq -r .verdict)" failed
  run cmd_reap
  refute_output --partial 'un-started'
}

@test "a board item that ends on a usage limit hands its row back with no verdict, so the row is not held" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  grep -qF -- '- [/] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
  agent-queue move gm-1 done --status failed --end limit
  run cmd_reap
  assert_success
  assert_output --partial 'un-started game: gm-1 (queue item gm-1 ended failed, limit)'
  grep -qF -- '- [ ] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not un-started"
  assert_equal "$(jq -r .verdict "$FLEET_DISPATCH_DIR/verdicts.jsonl" | sort -u | paste -sd' ')" 'dispatch'
  assert_equal "$(judged_keys | awk -F'\t' '$4 == "*"')" ''
  # the started row now carries its id, so it goes back to the judge as a candidate
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_output --partial 'unjudged  game (beta) human: gm-1'
}

@test "a usage-limit end leaves a hold an earlier real failure set" {
  game_ready
  jq -cn '{project: "game", lane: "human", key: "gm-1", verdict: "failed", reason: "queue item ended failed", at: "2026-11-10T00:00:00Z"}' \
    >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  agent-queue move gm-1 done --status failed --end limit
  run cmd_reap
  assert_output --partial 'un-started game: gm-1'
  assert_equal "$(judged_keys | awk -F'\t' '$4 == "*" { print $3 }')" 'gm-1'
}

@test "a row whose failed hold a later cleared releases is picked again on its dispatch verdict" {
  game_ready
  f() { jq -cn --arg v "$1" '{project: "game", lane: "human", key: "fix crash on load", verdict: $v, reason: "t", at: "2026-11-10T00:00:00Z"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  f failed
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  refute_output --partial 'ready'   # negative control: a failed hold keeps it
  f cleared
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_output --partial 'ready'
}

@test "fill --dry-run keys a row by its id and shows the priority it would queue at" {
  project game beta "$SANDBOX/repos/game"
  row game human gm-5 "- [ ] fix crash on load #low $T <!-- id:gm-5 -->"
  verdict game human gm-5 dispatch S 1 load
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_success
  assert_line --index 0 'ready     game (beta) human, fleet, load, low: gm-5 [fleet, #low, beta]'
}

@test "a hand start still goes ahead when no account has room" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf 'brief\n' > "$SANDBOX/brief.md"
  stub claude-acct '[ "$1" = room ] && exit 1; echo /home/u/.claude-personal'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
}

@test "a start waits for another start of a queue item to claim its own, and leaves it queued past the wait" {
  two_items
  export DISPATCH_START_WAIT=0
  mkdir -p "$FLEET_DISPATCH_DIR"; exec 7>"$FLEET_DISPATCH_DIR/.start.lock"; flock 7
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-app
  exec 7>&-
  assert_failure
  assert_output --partial 'another start held the queue lock for 0s; fix-app stays queued'
  [ -n "$(qitem queued fix-app)" ] || fail "fix-app stays queued"
  assert_not_called 'wt new'
}

# --- start: the one launch path for every agent-started session --------------------------
# 2026-10-28: only `run` tagged @dispatch and kept a record, so restored and hand-launched
# sessions showed no [dispatch] and an agent tagged two by hand with set-option.

@test "start --brief claims the row, promotes it to an item, and starts that item on the agent world" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf '/one-shot tidy the loader\n' > "$SANDBOX/brief.md"
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; printf "%s\n" "$WT_NEW_CMD" > "$NOTES_FIXTURE/cmd"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_output --partial 'started game-agent-1: game: gm-1'
  grep -qF -- '- [/] tidy the loader' "$NOTES_FIXTURE/rows.game.agent" || fail "row not claimed"
  assert_called "new --server lab --detach -c $SANDBOX/repos/game"
  assert_called 'tmux -L lab set-option -t =game-agent-1: @dispatch game: gm-1'
  f=$(qitem running gm-1)
  [ -n "$f" ] || fail "the row's item is not running"
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin) $(qfield "$f" lane) $(qfield "$f" profile)" 'lab:game-agent-1 hand agent bnb'
  assert_equal "$(qfield "$f" from)" 'board:game:gm-1'
  # One /one-shot: the item's brief adds it, so the row brief's own is dropped.
  assert_equal "$(grep -o '/one-shot' "$NOTES_FIXTURE/cmd" | wc -l)" 1
  grep -qF 'AGENT_QUEUE_ITEM=gm-1' "$NOTES_FIXTURE/cmd" || fail "the session does not know its item"
}

@test "start --brief --mode plan queues a plan item and opens it in plan mode, once; --mode needs --brief" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf 'Plan this row\n' > "$SANDBOX/brief.md"
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; printf "%s\n" "$WT_NEW_CMD" > "$NOTES_FIXTURE/cmd"; echo "game-agent-1"'
  # Setup turns add's own start off; on here, as live, so a second start would show.
  AGENT_QUEUE_START=1 run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md" --mode plan
  assert_success
  f=$(qitem running gm-1)
  [ -n "$f" ] || fail "the row's item is not running"
  assert_equal "$(qfield "$f" mode)" plan
  grep -qF -- '--permission-mode plan' "$NOTES_FIXTURE/cmd" || fail "the session did not open in plan mode"
  refute grep -qF '/one-shot' "$NOTES_FIXTURE/cmd"
  # agent-queue add does not start the plan item itself: one wt new, one session.
  assert_equal "$(grep -c '^new ' "$NOTES_FIXTURE/calls.log")" 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item gm-1 --mode plan
  assert_failure 2
  assert_output --partial '--mode sets the item --brief makes'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row x --brief "$SANDBOX/brief.md" --mode later
  assert_failure 2
  assert_output --partial '--mode is oneshot or plan'
}

@test "start --row matches the row's id whatever its case, and queues the item under the lower-case id" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 '- [ ] tidy the loader <!-- id:gm-1 -->'
  printf '/one-shot tidy the loader\n' > "$SANDBOX/brief.md"
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; printf "%s\n" "$WT_NEW_CMD" > "$NOTES_FIXTURE/cmd"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent --row GM-1 --brief "$SANDBOX/brief.md"
  assert_success
  assert_output --partial 'started game-agent-1: game: gm-1'
  [ -n "$(qitem running gm-1)" ] || fail "the row's item is not running under gm-1"
}

@test "start --brief refuses a row that is not open, and starts nothing" {
  project game beta "$SANDBOX/repos/game"
  row game human 'taken' '- [/] taken'
  printf 'brief\n' > "$SANDBOX/brief.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row taken --brief "$SANDBOX/brief.md"
  assert_failure
  assert_output --partial 'row no longer open'
  assert_not_called 'wt new'
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/ 2>/dev/null)" ] || fail "queued an item"
}

@test "start --resume opens its own session on the named server running claude --resume, and leaves the sheet alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game \
    --server default --session fix-crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "tmux -L default new-session -d -s fix-crash -c $SANDBOX/repos/game ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume abc-123"
  assert_called 'tmux -L default set-option -t =fix-crash: @dispatch game: resumed'
  assert_not_called 'start fix crash'
  assert_not_called 'wt new'
  grep -qF -- '- [/] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "touched the row"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/ 2>/dev/null)" ] || fail "a restore with no item wrote one"
}

@test "start --resume --item re-attaches the started item to the new session; a queued item or a --row is refused" {
  project game beta "$SANDBOX/repos/game"
  started_item fix-crash lab:game-agent-9 run '' 'board:game:fix crash'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session fix-crash \
    --cwd "$SANDBOX/repos/game" --resume abc-123 --item fix-crash
  assert_success
  assert_called 'tmux -L default set-option -t =fix-crash: @dispatch game: fix-crash'
  f=$(qitem running fix-crash)
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin)" 'default:fix-crash resume'
  # --resume keeps the conversation's id, so the item claims that one: the session's own start no longer does.
  assert_equal "$(qfield "$f" sessions)" 'abc-123'

  agent-queue add --project game --slug later "later" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session s2 --cwd "$SANDBOX/repos/game" --resume x --item later
  assert_failure
  assert_output --partial 'later is queued'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row 'fix crash' --server default --session s3 \
    --cwd "$SANDBOX/repos/game" --resume x
  assert_failure
  assert_output --partial 'not --row'
  assert_not_called 'new-session -d -s s2'
  assert_not_called 'new-session -d -s s3'
}

@test "start runs claude on the account claude-acct picks, for a brief and for a resume" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf 'brief\n' > "$SANDBOX/brief.md"
  stub claude-acct 'echo /home/u/.claude-personal'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
  # The session id is chosen at launch and claimed on the item here, before the session's preflight.
  sid=$(grep -o -- '--session-id [0-9a-f-]*' "$NOTES_FIXTURE/calls.log" | head -1 | cut -d' ' -f2)
  [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "no session id in the launch: $sid"
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/running/*.md)" sessions)" "$sid"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default \
    --session fix-crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "fix-crash -c $SANDBOX/repos/game ${LAUNCH_ENV}CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --permission-mode bypassPermissions --resume abc-123"
}

@test "start --resume never lands in a session that already exists on that server" {
  project game beta "$SANDBOX/repos/game"
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default \
    --session dotfiles --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_failure
  assert_output --partial 'already exists on default'
  assert_not_called 'new-session'
  assert_not_called 'set-option'
}

@test "start takes --server only for a resume: a new session goes to the agent world" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [ ] fix crash'
  printf 'brief\n' > "$SANDBOX/brief.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row 'fix crash' --server hub --brief "$SANDBOX/brief.md"
  assert_failure 2
  assert_output --partial '--server is for --resume'
  assert_not_called 'wt new'
}

@test "start refuses to guess when no world declares @agents" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [ ] fix crash'
  printf 'brief\n' > "$SANDBOX/brief.md"
  rm "$HOME/.config/tmux-servers/lab.conf"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row 'fix crash' --brief "$SANDBOX/brief.md"
  assert_failure 1
  assert_output --partial 'no world declares @agents'
  assert_not_called 'wt new'
}

@test "start refuses a call that is not exactly one launch" {
  printf 'brief\n' > "$SANDBOX/brief.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row r
  assert_failure
  assert_output --partial 'exactly one of --brief, --item or --resume'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row r --brief "$SANDBOX/brief.md" --resume x
  assert_failure
  assert_output --partial 'exactly one of --brief, --item or --resume'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --brief "$SANDBOX/brief.md"
  assert_failure
  assert_output --partial 'needs the --row'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --resume x --cwd "$SANDBOX"
  assert_failure
  assert_output --partial 'needs --session and --cwd'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project
  assert_failure
  assert_output --partial '--project needs a value'
  assert_not_called 'wt new'
  assert_not_called 'new-session'
}

@test "fill --dry-run lists ready picks then unjudged rows, and never judges, claims or launches" {
  game_ready
  row game human 'add a new map' "- [ ] add a new map $T"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_success
  assert_line --index 0 'ready     game (beta) human, fleet, fix crash on load, high: fix crash on load [fleet, #high, beta]'
  assert_line --index 1 'unjudged  game (beta) human: add a new map'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run --json
  assert_equal "$(jq -r '"\(.state) \(.key)"' <<<"$output" | paste -sd, -)" 'ready fix crash on load,unjudged add a new map'
  assert_not_called 'judge called'
  assert_not_called 'wt new'
  assert_not_called 'start '
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/ 2>/dev/null)" ] || fail "fill --dry-run queued an item"
}

# ar-545: on 2026-11-06 dispatch was held and every start was a hand, plan or after: start, which
# defaulted to opus (35 opus items to 5 sonnet). The pick lives in cmd_start, so every start gets it.
@test "a hand start with no --model starts the model-lane pick and logs the run" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"sonnet\",\"by\":\"rule\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\"}" ;; log) echo run-8 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  assert_called 'model-lane classify Fix the menu sides --floor sonnet'
  assert_called 'claude --model sonnet'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane sonnet --by rule --picked sonnet --ran sonnet'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model) $(qfield "$f" origin) $(qfield "$f" lane_run)" 'sonnet hand run-8'
}

# ar-617: the Queue table's SIZE column reads the item, not the board, so start writes the size the
# task's #size/ tag gives next to account= and model=, in any case as row_size reads it; an
# unsized item gets no size line.
@test "start --item writes size= from the task's #size/ tag, and none for an unsized item" {
  game_ready
  agent-queue add --project game --slug sized "Fix the menu sides #size/M" >/dev/null
  agent-queue add --project game --slug plain "Fix the menu top" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item sized
  assert_success
  assert_equal "$(qfield "$(qitem running sized)" size)" m
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item plain
  assert_success
  ! grep -q '^size:' "$(qitem running plain)" || fail "wrote a size for an unsized item"
}

@test "a hand start whose model-lane fails starts opus and logs nothing" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"; exit 1'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  assert_called 'model-lane classify'
  assert_called 'claude --model opus'
  assert_not_called 'model-lane log'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model)" opus
  [ -z "$(qfield "$f" lane_run)" ] || fail "stamped a run that was never logged"
}

@test "an explicit --model wins over the lane: no classify, no log" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"sonnet\",\"by\":\"rule\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\"}" ;; log) echo run-8 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --model opus
  assert_success
  assert_called 'claude --model opus'
  assert_not_called 'model-lane'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model)" opus
  [ -z "$(qfield "$f" lane_run)" ] || fail "stamped a run for a model the human chose"
}

@test "start --item waits for the new claude's mode footer, answering a trust prompt, and says when it never shows" {
  project game beta "$SANDBOX/repos/game"
  stub claude-acct '[ "$1" = trust ] && { echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"; exit "$(cat "$NOTES_FIXTURE/trust.rc" 2>/dev/null || echo 0)"; }; exit 0'
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug p --mode plan "plan p"
  cmd_start --item a >/dev/null || fail "start a"
  echo 1 > "$NOTES_FIXTURE/trust.rc"
  run cmd_start --item p
  assert_success
  assert_output --partial 'game-agent-1: claude did not show "plan mode on"; look at its pane'
  assert_called 'claude-acct trust lab =game-agent-1: bypass permissions on'
  assert_called 'claude-acct trust lab =game-agent-1: plan mode on'
  [ -n "$(qitem running p)" ] || fail "p is running even when its footer never showed"
}

@test "start --item refuses an item that is not queued, and a failed launch leaves it queued" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug a "do a"
  stub wt 'exit 1'
  run cmd_start --item a
  assert_failure
  [ -n "$(qitem queued a)" ] || fail "a left queued/"
  run cmd_start --item nope
  assert_failure
  assert_output --partial 'no queue item: nope'
}

@test "a started session's launch line labels its spans with the project and queue item" {
  # A pane gets the tmux server's environment, so only the launch line can say this; off the LAN
  # the snippet defines nothing, and every other start test here runs that way.
  project game beta "$SANDBOX/repos/game"
  transcript abc-123 '{"permissionMode":"plan"}'
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  cp "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/"
  stub getent 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called 'OTEL_RESOURCE_ATTRIBUTES='
  assert_called 'project=game'
}

@test "a started session's launch line exports telemetry and drops a parent Claude session's identity" {
  # The pane runs no rc file and gets the tmux server's environment; a server started from inside a
  # Claude session held no endpoint and that session's id and flags (16 of 16 queue sessions, 2026-11-08).
  project game beta "$SANDBOX/repos/game"
  transcript abc-123 '{"permissionMode":"plan"}'
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  stub getent 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called 'OTEL_EXPORTER_OTLP_ENDPOINT=http://hp-victus:4318'
  assert_called 'OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative'
  assert_called '-u CLAUDE_CODE_SESSION_ID'
  assert_called '-u CLAUDE_CODE_SESSION_ATTENDED'
}

@test "a queue session's launch line labels it fleet-dispatch's, whichever runner ran the start" {
  # On 2026-11-11 16 of 24 queue sessions past 1h exported as shepherd, inbox-plan or claude-code.
  stub getent 'exit 0'
  AGENTCTL_NAME=shepherd CLAUDE_TELEMETRY_SERVICE=claude-agentctl run telemetry_env "$SANDBOX" gm-1
  assert_success
  assert_output --partial 'agentctl.runner=fleet-dispatch'
  assert_output --partial 'service.name=claude-agentctl'
  refute_output --partial 'agentctl.runner=shepherd'
  env -u AGENTCTL_NAME -u CLAUDE_TELEMETRY_SERVICE bash -c "source '$REPO_ROOT/.local/bin/fleet-dispatch'; telemetry_env '$SANDBOX' gm-1" > "$SANDBOX/hand"
  run grep -c 'service.name=claude-agentctl.*agentctl.runner=fleet-dispatch' "$SANDBOX/hand"
  assert_output 1
}

@test "a resume with no queue item keeps the caller's labels: it may be the human's own session" {
  stub getent 'exit 0'
  env -u AGENTCTL_NAME -u CLAUDE_TELEMETRY_SERVICE bash -c "source '$REPO_ROOT/.local/bin/fleet-dispatch'; telemetry_env '$SANDBOX' ''" > "$SANDBOX/human"
  run grep -c 'service.name=claude-code' "$SANDBOX/human"
  assert_output 1
  run grep -c 'agentctl.runner' "$SANDBOX/human"
  assert_output 0
}

@test "off the LAN a started session's launch line exports no telemetry, and still drops the parent's identity" {
  project game beta "$SANDBOX/repos/game"
  transcript abc-123 '{"permissionMode":"plan"}'
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  stub getent 'exit 2'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called '-u CLAUDE_CODE_SESSION_ID'
  assert_not_called 'OTEL_'
}

@test "start --resume --window opens a window of a live session, keeps a plan mode, and leaves its label alone" {
  project game beta "$SANDBOX/repos/game"
  transcript abc-123 '{"permissionMode":"plan"}'
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "new-window -d -P -F #{pane_id} -t =dotfiles: -n crash -c $SANDBOX/repos/game ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode plan --allow-dangerously-skip-permissions --resume abc-123"
  assert_not_called 'new-session'
  assert_not_called 'set-option'
}

# ar-70: on 2026-11-03 a hand resume of an unapproved plan item came back in bypass with no item.
@test "start --resume with no --item finds the item that lists the conversation, and a plan item with no mode on record stays in plan" {
  project game beta "$SANDBOX/repos/game"
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  CLAUDE_CODE_SESSION_ID=conv-plan agent-queue add --project game --running --mode plan --slug plan-work "plan work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session planned \
    --cwd "$SANDBOX/repos/game" --resume conv-plan
  assert_success
  assert_called "-c $SANDBOX/repos/game AGENT_QUEUE_ITEM=plan-work ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --disallowedTools Workflow,ScheduleWakeup,Artifact --permission-mode plan --allow-dangerously-skip-permissions --resume conv-plan"
  assert_called 'set-option -t =planned: @dispatch game: plan-work'
  f=$(qitem running plan-work)
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin)" 'default:planned resume'

  # Once the transcript shows the plan approved, the resume goes on in the mode it ran in.
  transcript conv-plan '{"permissionMode":"plan"}
{"permissionMode":"bypassPermissions"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session planned2 \
    --cwd "$SANDBOX/repos/game" --resume conv-plan
  assert_success
  assert_called "AGENT_QUEUE_ITEM=plan-work ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --disallowedTools Workflow,ScheduleWakeup,Artifact --permission-mode bypassPermissions --resume conv-plan"
}

@test "start --resume refuses a conversation still running, and one two items list without --item" {
  project game beta "$SANDBOX/repos/game"
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  mkdir -p "$HOME/.claude/sessions"
  printf '{"pid":%s,"sessionId":"conv-live"}' "$$" > "$HOME/.claude/sessions/$$.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s1 \
    --cwd "$SANDBOX/repos/game" --resume conv-live
  assert_failure
  assert_output --partial 'conv-live is still running'

  CLAUDE_CODE_SESSION_ID=conv-two agent-queue add --project game --running --slug one "one" >/dev/null
  CLAUDE_CODE_SESSION_ID=conv-two agent-queue add --project game --running --slug two "two" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s2 \
    --cwd "$SANDBOX/repos/game" --resume conv-two
  assert_failure
  assert_output --partial 'more than one item'
  assert_output --partial 'pass --item'
  assert_not_called 'new-session'

  # Only an ambiguous lookup refuses: a queue that cannot answer (none installed) resumes with no item.
  stub agent-queue 'echo "agent-queue: command not found" >&2; exit 127'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s3 \
    --cwd "$SANDBOX/repos/game" --resume conv-two
  assert_success
  assert_called "-s s3 -c $SANDBOX/repos/game ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume conv-two"
}

@test "start --resume --window makes the session when it is not there yet, named as asked" {
  project game beta "$SANDBOX/repos/game"
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "new-session -d -s dotfiles -n crash -c $SANDBOX/repos/game ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume abc-123"
}

@test "--harness opencode launches a standalone run on the overlay, claims its session and logs under eval" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model qwen
  assert_success
  assert_called 'env -u LITELLM_MASTER_KEY timeout 180m opencode run --standalone --auto --session ses_eval'
  assert_called '--title fix-menu --model litellm/code\ \(qwen-3-coder\) --agent build'
  assert_called 'OPENCODE_CONFIG='
  assert_called '</dev/null'
  assert_not_called 'claude --model'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane eval --by human --harness opencode --picked qwen --ran qwen'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model) $(qfield "$f" account) $(qfield "$f" lane_run)" 'opencode qwen eval run-9'
  grep -q 'ses_eval' <<<"$(qfield "$f" sessions)" || fail "the run's session id is not on the item"
  grep -qF "$(qfield "$f" sessions | tr -d '[] ' | cut -d, -f1)" "$NOTES_FIXTURE/calls.log" || fail "claimed id is not the launched one"
}

@test "--harness glm runs opencode on its own overlay and asks for room on the glm source, not the eval one" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness glm --model glm
  assert_success
  assert_called "OPENCODE_CONFIG='$SANDBOX/eval-glm.json'"
  assert_called '--model litellm/reasoning\ \(glm-5.3\)'
  assert_called 'claude-acct room --source glm'
  assert_not_called 'room --source eval'
  # dispatch reads no budget itself: claude-acct is the one reader of a key
  assert_not_called 'curl'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model) $(qfield "$f" account)" 'glm glm glm'
}

@test "--harness glm refuses once its source has no room, and starts nothing" {
  harness_ready
  src_shut glm 'glm: its key is spent'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness glm --model glm
  assert_failure
  assert_output --partial 'glm has no room: glm: its key is spent'
  assert_not_called 'opencode run'
}

@test "a source with no room, and a harness with no source, both refuse the start" {
  harness_ready
  src_shut eval 'eval: its pool lazer is spent or inside its reserve'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model sonnet
  assert_failure
  assert_output --partial 'opencode has no room: eval: its pool lazer is spent'
  jq 'del(.harnesses.opencode.source)' "$DISPATCH_HARNESSES" > "$SANDBOX/h.tmp" && mv "$SANDBOX/h.tmp" "$DISPATCH_HARNESSES"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model sonnet
  assert_failure 2
  assert_output --partial 'harness opencode has no source'
  assert_not_called 'wt new'
}

@test "an opencode brief reads the skill and carries its own closing rules, not the ones for a watched pane" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model sonnet
  assert_success
  assert_called 'Read ~/.claude/skills/one-shot/SKILL.md and follow it'
  assert_called 'pr=<owner/repo#N>'
  assert_called 'Run agent-land in the foreground'
  assert_not_called '/one-shot Fix'
  # blocked on the human: file the ask and requeue behind it, never "ask it here" in a pane nobody watches
  assert_called 'run agent-queue requeue fix-menu --ask <id>, and stop'
  assert_not_called 'ask it here'
}

@test "--harness claude-lazer runs the wrapper on the eval key with the queue tag, off the account" {
  harness_ready
  stub claude-acct 'echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness claude-lazer --model sonnet
  assert_success
  assert_called 'env -u CLAUDE_CONFIG_DIR -u LITELLM_MASTER_KEY CLAUDE_LAZER_KEY='
  mask_sid "$NOTES_FIXTURE/calls.log"
  assert_called 'AGENT_HARNESS=claude-lazer ANTHROPIC_CUSTOM_HEADERS=x-litellm-tags:\ queue:fix-menu claude-lazer --model sonnet --session-id SID --permission-mode bypassPermissions'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane eval --by human --harness claude-lazer --picked sonnet --ran sonnet'
  assert_not_called 'claude-acct pick'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" account)" 'claude-lazer eval'
}

@test "a queue item's resume drops the same tools; a resume of a conversation no item lists keeps every one" {
  project game beta "$SANDBOX/repos/game"
  transcript abc-123 '{"permissionMode":"plan"}'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  started_item fix-menu default:other
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s1 \
    --cwd "$SANDBOX/repos/game" --resume abc-123 --item fix-menu
  assert_success
  assert_called 'claude --disallowedTools Workflow,ScheduleWakeup,Artifact --permission-mode plan --allow-dangerously-skip-permissions --resume abc-123'
  transcript def-456 '{"permissionMode":"plan"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s2 \
    --cwd "$SANDBOX/repos/game" --resume def-456
  assert_success
  assert_called "-c $SANDBOX/repos/game ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode plan --allow-dangerously-skip-permissions --resume def-456"
}

@test "a claude --resume reopens under the same profile" {
  sandbox_ready
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  export DISPATCH_SANDBOX_PROFILE=lane
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game \
    --server default --session fix-crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called 'env -u GH_TOKEN -u GITHUB_TOKEN claude --settings '
  assert_called '--permission-mode bypassPermissions --resume abc-123'
}

@test "an item queued with --agent and a model starts on them with no flags" {
  harness_ready
  agent-queue add --project game --slug by-field --agent opencode --priority high "Fix it" >/dev/null
  agent-queue set by-field model=sonnet >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item by-field
  assert_success
  assert_called 'opencode run --standalone'
}

@test "a claude start is unchanged: no eval log, no gateway read; it claims the id it launches with" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  sid=$(grep -o -- '--session-id [0-9a-f-]*' "$NOTES_FIXTURE/calls.log" | head -1 | cut -d' ' -f2)
  [ -n "$sid" ] || fail "no session id in the launch"
  mask_sid "$NOTES_FIXTURE/calls.log"
  assert_called "claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode bypassPermissions \$'/one-shot Fix"
  assert_not_called 'curl'
  assert_not_called 'lane eval'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" account) $(qfield "$f" sessions)" "claude main $sid"
}

@test "gateway starts refuse what would mislabel or overspend, and the item stays queued" {
  harness_ready
  refuses() { local want="$1"; shift; run "$REPO_ROOT/.local/bin/fleet-dispatch" start "$@"; assert_failure; assert_output --partial "$want"; }
  refuses 'unknown harness: nope' --item fix-menu --harness nope --model sonnet
  refuses 'has no model opus' --item fix-menu --harness claude-lazer --model opus
  refuses 'needs --model' --item fix-menu --harness opencode
  refuses '--harness needs --item' --project game --harness opencode --model sonnet
  refuses 'a resume stays on what it ran' --resume abc --harness opencode --model sonnet
  agent-queue add --project game --slug planned --mode plan --priority high "Think" >/dev/null
  refuses 'cannot wait on a plan' --item planned --harness opencode --model sonnet
  rm "$DISPATCH_HARNESSES"
  refuses 'no harness map' --item fix-menu --harness opencode --model sonnet
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "a refused item left the queue"
}

# A plan-billed harness: claude-acct room --source codex says whether the ChatGPT plan has use left.
@test "--harness codex runs agent-codex on the plan login, gated by room and not the gateway, with a headless brief" {
  harness_ready
  # An item's effort (a canary lane's) reaches codex as a config override; agent-queue takes only a word.
  run agent-queue set fix-menu 'effort=high;x'
  assert_failure
  assert_output --partial 'effort is a word'
  agent-queue set fix-menu effort=high >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_success
  assert_called 'claude-acct room --source codex'
  assert_not_called 'curl'
  assert_called 'AGENT_QUEUE_ITEM=fix-menu env -u LITELLM_MASTER_KEY -u OPENAI_API_KEY -u CODEX_API_KEY timeout 120m agent-codex run -m gpt-6.1-sol --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust'
  assert_called '--skip-git-repo-check -c model_reasoning_effort=high'
  assert_called 'Read ~/.claude/skills/one-shot/SKILL.md and follow it'
  assert_called 'Run agent-land in the foreground'
  assert_not_called '/one-shot Fix'
  # the brief runs final-pass and skips only the steps a headless run has no way to do
  assert_called 'Run final-pass (~/.claude/skills/final-pass/SKILL.md) on the diff before the PR opens; skip only its /simplify call.'
  assert_not_called 'Skip wind-down (this run ends when you stop) and any step'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model) $(qfield "$f" account)" 'codex sol codex'
}

@test "a cloud-ok item starts as a cloud session with no --harness: claude-cloud-run on the claude account, a self-contained brief, no model-lane" {
  cloud_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-fix
  assert_success
  assert_called 'AGENT_QUEUE_ITEM=cloud-fix env -u CLAUDE_CONFIG_DIR CLOUD_TIMEOUT_MIN=90 claude-cloud-run cloud-fix acme/game'
  assert_called 'The PR body carries the line "Item: cloud-fix"'
  assert_not_called '/one-shot'
  assert_not_called 'model-lane'
  assert_not_called 'curl'
  f=$(qitem running cloud-fix)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model) $(qfield "$f" account)" 'claude-cloud cloud main'
}

@test "a cloud-ok item with no room on the plan stays queued, as a local one would" {
  cloud_ready
  stub claude-acct '[ "$1" = room ] && { echo "{\"pick\":null,\"why\":\"no account has room\"}"; exit 0; }; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-fix
  assert_failure
  assert_output --partial 'claude-cloud has no room'
  [ -n "$(qitem queued cloud-fix)" ] || fail "the item left the queue"
}

@test "an item without cloud-ok never routes to a cloud session" {
  cloud_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  assert_not_called 'claude-cloud-run'
  assert_called 'claude --model'
  assert_equal "$(qfield "$(qitem running fix-menu)" agent)" claude
}

@test "a cloud session refuses a plan item, a tier 3 item and a repo off GitHub, and the item stays queued" {
  cloud_ready
  agent-queue add --project game --slug cloud-plan --mode plan --tags cloud-ok "Think" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-plan --harness claude-cloud
  assert_failure
  assert_output --partial 'cannot wait on a plan'
  agent-queue add --project game --slug cloud-t3 --tags 'cloud-ok tier3' "Fix the gate" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-t3
  assert_failure
  assert_output --partial 'is tier 3'
  git -C "$SANDBOX/repos/game" remote set-url origin git@forge.example:acme/game.git
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-fix
  assert_failure
  assert_output --partial 'no GitHub repo for a cloud session'
  for k in cloud-plan cloud-t3 cloud-fix; do [ -n "$(qitem queued "$k")" ] || fail "$k left the queue"; done
  assert_not_called 'claude-cloud-run'
}

@test "a cloud-ok item that names a model, or a start with --model, stays on a local claude" {
  cloud_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-fix --model opus
  assert_success
  assert_not_called 'claude-cloud-run'
  assert_called 'claude --model opus'
}

@test "codex refuses a spent plan, and the item stays queued" {
  harness_ready
  src_shut codex 'codex: its week is spent'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_failure
  assert_output --partial 'codex has no room: codex: its week is spent'
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "a refused item left the queue"
}

# P6: a headless harness that resumes runs a plan item's plan stage: the plan goes to the human as an
# approval ask, and the answer resumes the thread. One that does not resume is still refused.
@test "codex runs a plan item's plan stage, posted as an approval ask and requeued behind it; without resume it is refused" {
  harness_ready
  agent-queue add --project game --slug planned --mode plan --priority high "Think it through" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item planned --harness codex --model sol
  assert_success
  assert_called 'agent-codex run -m gpt-6.1-sol'
  assert_called 'This is a plan item: plan first, and change nothing in any repo until the human approves the plan. Write it to ~/.claude/plans/planned.md'
  assert_called 'agent-ask post --kind approval'
  assert_called 'agent-queue requeue planned --ask <id> and stop: the answer resumes this run'
  assert_called 'Read ~/.claude/skills/one-shot/SKILL.md and follow it'
  [ -n "$(qitem running planned)" ] || fail "the plan item did not start"
  # A decided plan item that cannot resume (no rollout) builds on the decision, never plans again.
  : > "$NOTES_FIXTURE/calls.log"
  stub agent-ask '[ "$1" = decision ] && echo "Approve the plan for decided? -> approve"; exit 0'
  agent-queue add --project game --slug decided --mode plan --priority high "Think it through" >/dev/null
  sed -i '1a tags: ask:pl1' "$(qitem queued decided)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item decided --harness codex --model sol
  assert_success
  assert_called 'whose plan, ~/.claude/plans/decided.md, the human has decided on below: build it if they approved it'
  assert_not_called 'plan first'
  # Negative control: the same map without resume refuses it, as glm and opencode are.
  jq '.harnesses.codex |= del(.resume)' "$DISPATCH_HARNESSES" > "$SANDBOX/h.tmp" && mv "$SANDBOX/h.tmp" "$DISPATCH_HARNESSES"
  agent-queue add --project game --slug planned2 --mode plan --priority high "Think again" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item planned2 --harness codex --model sol
  assert_failure
  assert_output --partial 'codex runs to its end and cannot wait on a plan'
  [ -n "$(qitem queued planned2)" ] || fail "a refused plan item left the queue"
}

@test "a queued codex item whose last run hit the limit resumes its thread on its salvage branch, with a brief that says so" {
  harness_ready
  codex_ran fix-menu th-1 "salvage/fix-menu@0123456789abcdef0123456789abcdef01234567"
  agent-queue set fix-menu end_reason=limit >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_success
  assert_called 'timeout 120m agent-codex resume --salvage salvage/fix-menu@0123456789abcdef0123456789abcdef01234567 th-1 -m gpt-6.1-sol --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust --skip-git-repo-check '
  assert_not_called '--color never'
  assert_called "usage limit, and the plan has room again"
  assert_called 'holds the work your last run left, checked out at 0123456789abcdef0123456789abcdef01234567 (on salvage/fix-menu on origin)'
  assert_called 'agent-queue requeue fix-menu --ask <id>'
  assert_not_called 'Read ~/.claude/skills/one-shot/SKILL.md'
  f=$(qitem running fix-menu)
  [ -z "$(qfield "$f" end_reason)" ] || fail "a new run kept the last run's end_reason"
}

@test "an answered ask resumes the codex thread with the decision; a PR, a canary or a lost rollout starts cold" {
  harness_ready
  stub agent-ask '[ "$1" = decision ] && echo "Ship it? -> a: ship it"; exit 0'
  codex_ran fix-menu th-2
  sed -i '1a tags: ask:abc' "$(qitem queued fix-menu)"   # requeued behind ask abc, now answered
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_success
  assert_called 'agent-codex resume th-2 -m gpt-6.1-sol'
  assert_called 'The human already decided this in ask abc, so follow it: Ship it? -> a: ship it'
  assert_called 'stopped before the item closed, and this run takes it up'
  assert_called 'Your last run left no work the trunk lacks: start from the current directory'
  # Negative controls: an item with a PR goes to fix-ci, a canary is scored fresh, a lost rollout has nothing to resume.
  for k in pr canary lost; do
    : > "$NOTES_FIXTURE/calls.log"
    agent-queue add --project game --slug "c-$k" --priority high "Fix the $k" >/dev/null
    codex_ran "c-$k" "th-$k"
    case $k in
      pr) agent-queue set c-pr pr=acme/game#7 >/dev/null ;;
      canary) agent-queue set c-canary tags=canary >/dev/null ;;
      lost) rm "$HOME"/.codex/sessions/2026/11/09/*-th-lost.jsonl ;;
    esac
    run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item "c-$k" --harness codex --model sol
    assert_success
    assert_called 'agent-codex run -m gpt-6.1-sol'
    assert_not_called 'agent-codex resume'
  done
}

@test "an item another harness ran, or ran last, is never resumed on codex; a claude start of salvaged work is told where it is" {
  harness_ready
  codex_ran fix-menu th-3 "salvage/fix-menu@abc123"
  agent-queue set fix-menu agent=opencode >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_success
  assert_called 'agent-codex run -m gpt-6.1-sol'
  assert_not_called 'agent-codex resume'
  assert_called 'An earlier run of this item left its unfinished work on branch salvage/fix-menu at abc123 on origin: start from it'
}

@test "start --resume takes up a codex item's last thread in --cwd; a stale id, a live run and a harness that cannot resume are refused" {
  harness_ready
  started_item cx lab:game-agent-1
  codex_ran cx th-4
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cx --resume th-old --session cx-again --cwd "$SANDBOX/repos/game"
  assert_failure
  assert_output --partial 'th-old is not the last codex thread of cx'
  codex_run cx
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cx --resume th-4 --session cx-again --cwd "$SANDBOX/repos/game"
  assert_failure
  assert_output --partial 'the codex run of cx is still live'
  stub pgrep 'exit 1'
  stub tmux 'echo "tmux $*" >> "$NOTES_FIXTURE/calls.log"; case " $* " in *" has-session "*) exit 1 ;; esac; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --resume th-4 --session cx-again --cwd "$SANDBOX/repos/game"
  assert_success
  assert_called 'new-session -d -s cx-again'
  assert_called 'agent-codex resume th-4 -m gpt-6.1-sol'
  assert_not_called 'claude --resume'
  assert_equal "$(qfield "$(qitem running cx)" session)" lab:cx-again
}

@test "resume refuses an item that ran on a gateway harness that cannot resume" {
  harness_ready
  started_item gw-run lab:game-agent-1
  sed -i 's/^agent: claude/agent: opencode/' "$(qitem running gw-run)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item gw-run --resume abc
  assert_failure
  assert_output --partial 'ran on opencode, which cannot resume; --resume is for claude or a harness that resumes'
}

@test "start --host refuses what a worker cannot run" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1'
  run cmd_start --host razer-laptop --project game --brief "$SANDBOX/b.md"
  assert_failure 2
  assert_output --partial 'starts a queued --item'
  agent-queue add --project game --slug x "x" >/dev/null
  run cmd_start --host nope --item x
  assert_failure 2
  assert_output --partial 'nope is not in the fleet roster'
  sed -i '/fleet_state_host/d' "$FLEET_INVENTORY"; unset FLEET_HOSTS_JSON
  run cmd_start --host razer-laptop --item x
  assert_failure 2
  assert_output --partial 'has no fleet_state_host'
  assert_not_called 'wt new'
}

@test "start: a hand start takes the account room names, not the one pick would (ar-275)" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf 'brief\n' > "$SANDBOX/brief.md"
  # main is over its pace, bnb has room: pick (the stub prints nothing) would be main.
  acct main:pace bnb:ok:/acct/bnb
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/acct/bnb claude --model'
  assert_not_called 'env -u CLAUDE_CONFIG_DIR claude --model'
}

@test "start: a hand start with no account having room still goes ahead, on pick's account (ar-275)" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf 'brief\n' > "$SANDBOX/brief.md"
  acct main:pace bnb:pace:/acct/bnb
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_called 'env -u CLAUDE_CONFIG_DIR'
  assert_called 'claude --model'
  assert_not_called 'CLAUDE_CONFIG_DIR=/acct/bnb'
  assert_output --partial "no account has room ("
}

@test "start: a hand start on room's main pick runs with the config dir unset (ar-275)" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf 'brief\n' > "$SANDBOX/brief.md"
  acct main:ok bnb:pace:/acct/bnb
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_called 'env -u CLAUDE_CONFIG_DIR'
  assert_not_called 'CLAUDE_CONFIG_DIR=1'
  assert_not_called 'CLAUDE_CONFIG_DIR=/acct/bnb'
}
