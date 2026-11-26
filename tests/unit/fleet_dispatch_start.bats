#!/usr/bin/env bats
# fleet-dispatch, `start` and `fill`: launching one session by hand and topping the queue up.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
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

@test "a usage-limit end leaves a hold earlier real failures set" {
  game_ready
  local i
  for i in 1 2; do
    jq -cn '{project: "game", lane: "human", key: "gm-1", verdict: "failed", reason: "queue item ended failed", at: "2026-11-10T00:00:00Z"}' \
      >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  agent-queue move gm-1 done --status failed --end limit
  run cmd_reap
  assert_output --partial 'un-started game: gm-1'
  assert_equal "$(judged_keys | awk -F'\t' '$4 == "*" { print $3 }')" 'gm-1'
}

@test "a failed row goes back to the judge; DISPATCH_FIX_TRIES failures hold it, and a cleared sends it back again" {
  game_ready
  f() { jq -cn --arg v "$1" '{project: "game", lane: "human", key: "fix crash on load", verdict: $v, reason: "t", at: "2026-11-10T00:00:00Z"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_output --partial 'ready'   # control: its dispatch verdict picks it
  f failed
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  refute_output --partial 'ready'   # the failure expired that verdict
  assert_output --partial 'unjudged  game (beta) human: fix crash on load'
  f failed
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  refute_output --partial 'ready'
  refute_output --partial 'unjudged  game (beta) human: fix crash on load'   # held at the limit
  f cleared
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_output --partial 'unjudged  game (beta) human: fix crash on load'
}

@test "ask_failed_rows: a row at DISPATCH_FIX_TRIES failures gets one ask with their reasons, is gated on it, and its hold ends" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] fix(game): crash on load $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] fix(game): one failure $T <!-- id:gm-2 -->"
  row game agent gm-3 "- [/] fix(game): started again $T <!-- id:gm-3 -->"
  f() { jq -cn --arg k "$1" --arg r "$2" '{project: "game", lane: "agent", key: $k, verdict: "failed", reason: $r, at: "2026-11-10T00:00:00Z"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  mkdir -p "$FLEET_DISPATCH_DIR"
  f gm-1 'queue item gm-1 ended failed, timeout'; f gm-1 'started 72h with no queue item'
  f gm-2 'queue item gm-2 ended failed'
  f gm-3 'x'; f gm-3 'y'
  stub agent-ask 'printf "%s\n" "agent-ask $*" >> "$NOTES_FIXTURE/calls.log"; [ "$1" = post ] && echo ask1; exit 0'
  run ask_failed_rows
  assert_success
  assert_output 'asked about game: gm-1 (failed 2 times, ask ask1)'
  # the ask carries both reasons and is a gate the judge answers, with retry and drop
  local post; post=$(grep '^agent-ask post' "$NOTES_FIXTURE/calls.log")
  [[ $post == *'--kind gate --project game'* ]] || fail "not a gate for game: $post"
  [[ $post == *'retry=judge the row again and start it, with 2 more tries|drop=drop the row from the board'* ]] || fail "options: $post"
  [[ $post == *'queue item gm-1 ended failed, timeout; started 72h with no queue item'* ]] || fail "reasons: $post"
  [[ $post == *'Start board row gm-1 again after its last 2 runs failed?'* ]] || fail "question: $post"
  [ "$(grep -c '^agent-ask post' "$NOTES_FIXTURE/calls.log")" = 1 ] || fail "asked about a row under the limit or started"
  grep -q '#ask/ask1/retry <!-- id:gm-1 -->' "$NOTES_FIXTURE/rows.game.agent" || fail "row not gated on the ask"
  assert_equal "$(tail -1 "$FLEET_DISPATCH_DIR/verdicts.jsonl" | jq -r '"\(.key) \(.verdict) \(.ask)"')" 'gm-1 cleared ask1'
  # the gate holds it now, not the failures, and a second pass asks nothing
  assert_equal "$(judged_keys | awk -F'\t' '$4 == "*" { print $3 }')" 'gm-3'
  : > "$NOTES_FIXTURE/calls.log"
  run ask_failed_rows
  assert_output ''
  run grep -c '^agent-ask post' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "ask_failed_rows: an ask that does not post leaves the hold; a gate that fails cancels the ask and the row is judged again" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] fix(game): crash on load $T <!-- id:gm-1 -->"
  mkdir -p "$FLEET_DISPATCH_DIR"
  local i
  for i in 1 2; do jq -cn '{project: "game", lane: "agent", key: "gm-1", verdict: "failed", reason: "r", at: "2026-11-10T00:00:00Z"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"; done
  stub agent-ask 'printf "%s\n" "agent-ask $*" >> "$NOTES_FIXTURE/calls.log"; exit 1'
  run ask_failed_rows
  assert_success
  assert_equal "$(judged_keys | awk -F'\t' '$4 == "*" { print $3 }')" 'gm-1'
  grep -q 'the ask for game agent row gm-1 did not post' "$FLEET_DISPATCH_DIR/log.md" || fail "no log line"
  # a board that will not take the tag: the ask is cancelled, and the row goes back to the judge
  stub agent-ask 'printf "%s\n" "agent-ask $*" >> "$NOTES_FIXTURE/calls.log"; [ "$1" = post ] && echo ask2; exit 0'
  mv "$SANDBOX/bin/notes" "$SANDBOX/bin/notes-real"
  stub notes '[[ " $* " == *" tag "* ]] && exit 1; exec notes-real "$@"'
  run ask_failed_rows
  assert_success
  grep -q '^agent-ask cancel ask2' "$NOTES_FIXTURE/calls.log" || fail "ask not cancelled"
  assert_equal "$(judged_keys | awk -F'\t' '$4 == "*" { print $3 }')" ''
}

@test "ask_failed_rows: a row whose done item's PR merged is closed on merge proof, not asked about; a failed run's open PR does not hold it (ar-4678)" {
  # NEGATIVE CONTROL: before ar-4678 the merged row got a retry ask (2026-11-21: ar-4041, ar-225).
  landed_item MERGED
  printf 'fix crash\t- [ ] fix crash\n' > "$NOTES_FIXTURE/rows.game.agent"
  row game agent gm-3 "- [ ] fix(game): failed run left a pr open $T <!-- id:gm-3 -->"
  agent-queue add --project game --slug gm-3 "failed run" >/dev/null
  agent-queue set gm-3 row=game:gm-3 lane=agent pr=o/game#13 >/dev/null
  run agent-queue move gm-3 done --status failed
  assert_success
  mkdir -p "$FLEET_DISPATCH_DIR"
  local k
  for k in 'fix crash' 'fix crash' gm-3 gm-3; do jq -cn --arg k "$k" '{project: "game", lane: "agent", key: $k, verdict: "failed", reason: "r", at: "2026-11-10T00:00:00Z"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"; done
  gh_script 'printf "gh %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; case " $* " in *" 13 "*) echo "OPEN - h1 PASS MERGEABLE" ;; *) cat "$NOTES_FIXTURE/pr.state" ;; esac'
  stub agent-ask 'printf "%s\n" "agent-ask $*" >> "$NOTES_FIXTURE/calls.log"; [ "$1" = post ] && echo ask1; exit 0'
  run ask_failed_rows
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  run grep '^agent-ask post' "$NOTES_FIXTURE/calls.log"
  assert_equal "${#lines[@]}" 1
  assert_output --partial 'failed run left a pr open'
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

# 2026-11-19: a start of an open agent row without --agent was told "row no longer open".
@test "start --brief without --agent finds an agent row on the agent board; a row on neither board is named as missing" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 '- [ ] tidy the loader <!-- id:gm-1 -->'
  printf '/one-shot tidy the loader\n' > "$SANDBOX/brief.md"
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --row gm-1 --brief "$SANDBOX/brief.md"
  assert_success
  assert_output --partial 'gm-1 is on the agent board'
  grep -qF -- '- [/] tidy the loader' "$NOTES_FIXTURE/rows.game.agent" || fail "row not claimed"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --row gm-9 --brief "$SANDBOX/brief.md"
  assert_failure
  assert_output --partial 'gm-9 is not on either board of game'
  refute_output --partial 'no longer open'
}

# 2026-11-19: the human's "start it now" on a phase gated #after/ its stalled predecessor was refused,
# and a session edited the board file by hand to drop the gate.
@test "start --now starts a row past a pending #after/ and takes the tag off; without --now, or with an ask gate, it is refused" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] feat(game): p1 $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] feat(game): p3 $T #after/gm-1 <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] feat(game): asked $T #after/gm-1 #ask/hold1/b <!-- id:gm-3 -->"
  printf '/one-shot p3\n' > "$SANDBOX/brief.md"
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent --row gm-2 --brief "$SANDBOX/brief.md"
  assert_failure
  assert_output --partial 'gm-2 waits on'
  assert_not_called 'wt new'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent --row gm-3 --brief "$SANDBOX/brief.md" --now
  assert_failure
  assert_not_called 'wt new'
  refute grep -qF 'gm-3' "$FLEET_DISPATCH_DIR/log.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent --row gm-2 --brief "$SANDBOX/brief.md" --now
  assert_success
  [ -n "$(qitem running gm-2)" ] || fail "the gated row's item is not running"
  assert_called 'tag --remove after/gm-1 gm-2'
  grep -qF 'human start past #after/gm-1: game gm-2' "$FLEET_DISPATCH_DIR/log.md" || fail "the pass past the gate was not logged"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --item gm-2 --now
  assert_failure 2
  assert_output --partial '--now starts a --row'
}

@test "start --resume opens its own session on the named server running claude --resume, untagged, and leaves the sheet alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game \
    --server default --session fix-crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "tmux -L default new-session -d -P -F #{pane_id} -s fix-crash -c $SANDBOX/repos/game ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume abc-123"
  # No item from a start: the human's own conversation (a scratch send, a restore of their session).
  assert_not_called '@dispatch'
  assert_not_called 'start fix crash'
  assert_not_called 'wt new'
  grep -qF -- '- [/] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "touched the row"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/ 2>/dev/null)" ] || fail "a restore with no item wrote one"
}

# 2026-11-12: every restored or scratch-sent hand session came back labelled dispatch, and so
# did each window the human opened in it with Prefix+c.
@test "start --resume of a hand item (no origin) does not tag the session; the item records origin resume" {
  project game beta "$SANDBOX/repos/game"
  started_item mine hub:dotfiles
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session mine \
    --cwd "$SANDBOX/repos/game" --resume abc-123 --item mine
  assert_success
  assert_not_called '@dispatch'
  f=$(qitem running mine)
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin) $(qfield "$f" sessions)" 'default:mine resume abc-123'
}

@test "start --resume --prompt gives the resumed conversation its first message; without a resume it is refused" {
  project game beta "$SANDBOX/repos/game"
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session fix-crash \
    --cwd "$SANDBOX/repos/game" --resume abc-123 --prompt "Answer to ask Ab12: b"
  assert_success
  assert_called "--resume abc-123 Answer\\ to\\ ask\\ Ab12:\\ b"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --item x --prompt hi
  assert_failure 2
  assert_output --partial 'first message of a --resume'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session fix-crash \
    --cwd "$SANDBOX/repos/game" --resume abc-123 --prompt "-x"
  assert_failure 2
  assert_output --partial 'cannot start with -'
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
  assert_not_called '-s s2 '
  assert_not_called '-s s3 '
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

@test "start hands the account's setup token to its claude as a substitution, never the token" {
  project game beta "$SANDBOX/repos/game"
  stub claude-acct '[ "$1" = token-prefix ] && { printf "CLAUDE_CODE_OAUTH_TOKEN=\"\$(claude-acct token x)\" "; exit 0; }; echo /home/u/.claude-personal'
  stub wt 'echo "game-agent-1"'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default \
    --session fix-crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called 'CLAUDE_CODE_OAUTH_TOKEN="$(claude-acct token x)" CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --permission-mode'
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
# task's #size/ tag gives next to account= and model=, in any case as row_size_set reads it; an
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

@test "a claude item's effort and never-run model reach claude as --effort and --model; an effort claude does not take refuses the start" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  agent-queue set fix-menu agent=claude model=haiku effort=maximum >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_failure 2
  assert_output --partial "effort 'maximum' is not one claude takes"
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "a refused item left the queue"
  agent-queue set fix-menu effort=max >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  assert_called 'claude --model haiku --effort max'
  # A pin is the lane's own model: no classify, no lane run logged.
  assert_not_called 'model-lane'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model) $(qfield "$f" lane_run)" 'haiku '
  # A model a start recorded (the item has sessions) is no pin, so a requeued item is picked afresh.
  assert_equal "$(claude_pin '{"model": "haiku", "sessions": "s1"}')" ''
  assert_equal "$(claude_pin '{"agent": "codex", "model": "sol"}')" ''
}

@test "start --resume of a claude item resumes on the model its start ran, at the item's effort" {
  project game beta "$SANDBOX/repos/game"
  started_item fix-crash lab:game-agent-9 run
  agent-queue set fix-crash model=haiku effort=high >/dev/null
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session fix-crash \
    --cwd "$SANDBOX/repos/game" --resume abc-123 --item fix-crash
  assert_success
  assert_called 'claude --model haiku --effort high'
  assert_called '--resume abc-123'
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

@test "start --item refuses a queued item whose hold is pending before it opens a session (ar-3260)" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug first "do first"
  legacy second "after: first" --project game "do second"
  run cmd_start --item second
  assert_failure
  assert_output --partial 'start: second waits on after first'
  assert_not_called 'wt new'
  [ -n "$(qitem queued second)" ] || fail "second left queued/"
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
  # The session filed its own item (no origin): a hand session, so no @dispatch label.
  assert_not_called '@dispatch'
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

@test "start --resume refuses a conversation still running, and takes the newest of two items that list one (ar-2676)" {
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
  touch -d '1 hour ago' "$(qitem running one)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s2 \
    --cwd "$SANDBOX/repos/game" --resume conv-two
  assert_success
  assert_called "AGENT_QUEUE_ITEM=two "

  # A queue that cannot answer (none installed) resumes with no item.
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
  assert_called "new-session -d -P -F #{pane_id} -s dotfiles -n crash -c $SANDBOX/repos/game ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume abc-123"
}

# 2026-11-21: a world restore made hub:dotfiles with an agent's window first, tagged the session, and
# Prefix+w showed every window of it [dispatch], the human's own included.
@test "start --resume --window of an agent item tags the window it opened, never the session" {
  project game beta "$SANDBOX/repos/game"
  started_item fix-crash lab:game-agent-9 run '' 'board:game:fix crash'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123 --item fix-crash
  assert_success
  assert_called 'tmux -L default set-option -w -t =dotfiles: @dispatch game: fix-crash'
  assert_not_called 'set-option -t =dotfiles: @dispatch'
  # Joined into the live session, the window still gets its own label.
  : > "$NOTES_FIXTURE/calls.log"
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  printf '%%42\n' > "$NOTES_FIXTURE/tmux.new_pane"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123 --item fix-crash
  assert_success
  # The pane new-window opened, not =dotfiles: (the session's active window, maybe the human's).
  assert_called 'tmux -L default set-option -w -t %42 @dispatch game: fix-crash'
  assert_not_called 'set-option -t =dotfiles: @dispatch'
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

@test "--harness paid runs opencode on its own overlay and asks for room on the paid source, not the eval one" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_success
  assert_called "OPENCODE_CONFIG=$(printf %q "$SANDBOX/eval-paid.json")"
  assert_called '--model litellm/reasoning\ \(glm-5.3\)'
  # with the gateway's name of the model, whose route budget the source's key budget does not show
  assert_called 'claude-acct room --source paid --model reasoning (glm-5.3)'
  assert_not_called 'room --source eval'
  # dispatch reads no budget itself: claude-acct is the one reader of a key
  assert_not_called 'curl'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model) $(qfield "$f" account)" 'paid glm paid'
}

@test "--harness paid refuses once its source has no room, and starts nothing" {
  harness_ready
  src_shut paid 'paid: its key is spent'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_failure
  assert_output --partial 'paid has no room: paid: its key is spent'
  assert_not_called 'opencode run'
}

@test "a hand --harness start of a private-project item on an allowlisted harness is refused before any room or launch" {
  harness_ready
  harness_set '.harnesses.paid.projects = ["dotfiles"]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_failure 2
  assert_output --partial "paid refuses fix-menu: it takes only dotfiles work (projects in $DISPATCH_HARNESSES), and this is game"
  assert_not_called 'claude-acct room'
  assert_not_called 'opencode run'
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "the refused item left the queue"
  # An unreadable list refuses too, never reads as "no list".
  harness_set '.harnesses.paid.projects = "dotfiles"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_failure 2
  assert_output --partial 'not a list of project names'
}

@test "an allowlisted harness starts only as opencode with a config_dir, in its item's own repo, so no private rule or repo reaches its run" {
  harness_ready
  # A projects list with no config_dir would load ~/.config/opencode (the private global rules,
  # agents and plugins): refused before any worktree is made.
  harness_set '.harnesses.paid.projects = ["dotfiles", "game"]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_failure 2
  assert_output --partial 'paid has a projects allowlist, so it must be an opencode harness with a config_dir'
  # Nor may a codex harness carry one, config_dir or not: its run would load ~/.codex.
  harness_set --arg d "$SANDBOX/oc-public" '.harnesses.codex.projects = ["game"] | .harnesses.codex.config_dir = $d'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_failure 2
  assert_output --partial 'codex has a projects allowlist, so it must be an opencode harness'
  # A hand --cwd cannot point an allowlisted harness at another repo than the item's own.
  harness_set --arg d "$SANDBOX/oc-public" '.harnesses.paid.config_dir = $d'
  mkdir -p "$SANDBOX/client-repo"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm --cwd "$SANDBOX/client-repo"
  assert_failure 2
  assert_output --partial "paid runs only in game's own repo, not $SANDBOX/client-repo"
  assert_not_called 'opencode run'
  assert_not_called 'agent-codex'
  assert_not_called 'wt new'
  # In its own repo, with no lane sandbox, its shell could still read every private path: refused.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_failure 2
  assert_output --partial 'paid has a projects allowlist, so it must name a lane sandbox (sandbox:)'
  assert_not_called 'opencode run'
  # Positive control: in its own repo, sandboxed, it starts, and no Claude Code or above-worktree rules load.
  harness_sandboxed paid
  canary_item fix-menu c-1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_success
  assert_called "OPENCODE_CONFIG_DIR=$(printf '%q' "$SANDBOX/oc-public") OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_DISABLE_PROJECT_CONFIG=1"
  [ -d "$SANDBOX/oc-public" ] || fail "the config_dir was not made"
}

@test "a sandboxed harness runs its opencode launch inside srt, under a cleared env, with the canary steps outside" {
  harness_ready
  harness_set --arg d "$SANDBOX/oc-public" '.harnesses.paid.projects = ["game"] | .harnesses.paid.config_dir = $d'
  harness_sandboxed paid
  ln -s "$SANDBOX/eval-paid.json" "$SANDBOX/paid-link.json"
  harness_set --arg c "$SANDBOX/paid-link.json" '.harnesses.paid.config = $c'
  canary_item fix-menu c-7
  git init -q "$SANDBOX/repos/game"
  export LITELLM_MASTER_KEY=sk-master
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_success
  run="$SANDBOX/oc-public/run" qr=$(printf %q "$SANDBOX/oc-public/run")
  line=$(grep -m1 'opencode run' "$NOTES_FIXTURE/calls.log")
  # The canary oracle runs before and the score after, outside the sandbox; the run's line starts from env -i.
  # A start that fails skips the run and the score (the tree is not at base); the settings go either way.
  [[ "$line" == *":: trap rm\\ -f\\ "*"/srt-ses_eval"*".json EXIT; trap 'exit 129' HUP TERM; fleet-bench canary start c-7 && { timeout 180m env -i "* ]] || fail "no canary start then env -i: $line"
  # Why the session ended is written once to the item, read once the run is over where it ran; the score reads it from the item,
  # and keeps the run's own lines of the harness's log beside its canary log (run-log, ar-4133).
  [[ "$line" == *"; fleet-dispatch record-end fix-menu paid ses_eval"*"; BENCH_CANARY_WRAP="*" AGENT_QUEUE_ITEM=fix-menu BENCH_CANARY_RUN_LOG=fleet-dispatch\\ run-log\\ paid\\ ses_eval"*" fleet-bench canary score c-7 && agent-queue move fix-menu done --status ok; tmux set-option -t \"\$TMUX_PANE\" @headless fix-menu 2>/dev/null; env -i "* ]] || fail "no canary score, then the replay, after: $line"
  [[ "$line" == *"TMPDIR=$qr/tmp CLAUDE_CODE_TMPDIR=$qr/tmp AGENT_QUEUE_ITEM=fix-menu "*"XDG_DATA_HOME=$qr/data "*" srt --settings $qr/srt-ses_eval"*".json -- opencode run --standalone"* ]] || fail "opencode is not inside srt: $line"
  # The config is named by its target, which the sandbox re-allows; a link inside a masked dir would not resolve.
  [[ "$line" == *"OPENCODE_CONFIG=$(printf %q "$SANDBOX/eval-paid.json") "* ]] || fail "config not by its target: $line"
  [[ "$line" != *LITELLM_MASTER_KEY* ]] || fail "the master key reached the line"
  # The settings: the profile's masks and hosts, strict; the worktree and config_dir writable; the
  # config, key and git common dir readable, the common dir not writable (the shared repo's refs).
  s=$(cat "$run"/srt-ses_eval*.json)
  assert_equal "$(jq -c .network <<<"$s")" '{"allowedDomains":["gw.test"],"deniedDomains":[],"strictAllowlist":true}'
  assert_equal "$(jq -c .filesystem.denyRead <<<"$s")" '["~/","/tmp"]'
  assert_equal "$(jq -c .filesystem.allowWrite <<<"$s")" "[\".\",\"$SANDBOX/oc-public\"]"
  jq -e --arg c "$SANDBOX/eval-paid.json" --arg k "$SANDBOX/paid.key" --arg g "$SANDBOX/repos/game/.git" '.filesystem.allowRead | index($c) and index($k) and index($g)' <<<"$s" >/dev/null || fail "config, key or git dir not readable: $s"
  # The checkout's .git sits in the writable cwd (here a plain clone's git dir), so it is denied.
  assert_equal "$(jq -c .filesystem.denyWrite <<<"$s")" "[\"$SANDBOX/repos/game/.git\"]"
  # The pane line as a shell runs it: a start that fails runs neither the session nor the score, and
  # the score runs its oracle (the code the model wrote) back inside srt, under the cleared env.
  pane="$SANDBOX/pane" && mkdir -p "$pane"
  printf '#!/usr/bin/env bash\necho "fleet-bench $*" >> %q; [ "$2" != start ] || [ -z "${START_FAILS:-}" ] || exit 1\n' "$pane/log" > "$pane/fleet-bench"
  printf '%s\n' '[ "$2" != score ] || bash -c "$BENCH_CANARY_WRAP \"\$@\"" oracle oracle-cmd' >> "$pane/fleet-bench"
  printf '#!/usr/bin/env bash\necho "srt ${*: -1} key=${LITELLM_MASTER_KEY:-none} tmp=$TMPDIR" >> %q\n' "$pane/log" > "$pane/srt"
  printf '#!/usr/bin/env bash\necho "%s $*" >> %q\n' timeout "$pane/log" > "$pane/timeout"
  printf '#!/usr/bin/env bash\necho "%s $*" >> %q\n' agent-queue "$pane/log" > "$pane/agent-queue"
  printf '#!/usr/bin/env bash\n[ "$1" != run-result ] || echo "no queue item"\n[ "$1" != record-end ] || echo "fleet-dispatch $*" >> %q\n' "$pane/log" > "$pane/fleet-dispatch"
  chmod +x "$pane"/*
  run env START_FAILS=1 PATH="$pane:$PATH" bash -c "${line#* :: }"
  assert_failure 1
  assert_equal "$(cat "$pane/log")" 'fleet-bench canary start c-7'
  run ls "$run"; refute_output --partial srt-ses_eval
  : > "$pane/log"; PATH="$pane:$PATH" bash -c "${line#* :: }"
  # Then the replay: srt again, on the run's session id (the last argument).
  run cut -d' ' -f1-3 "$pane/log"
  assert_equal "$(head -n 6 <<<"$output")" "$(printf '%s\n' 'fleet-bench canary start' 'timeout 180m env' 'fleet-dispatch record-end fix-menu' 'fleet-bench canary score' 'srt oracle-cmd key=none' 'agent-queue move fix-menu')"
  [[ "$(sed -n 7p <<<"$output")" == "srt ses_eval"*" key=none" ]] || fail "no replay after the score: $output"
  grep -q '^fleet-dispatch record-end fix-menu paid ses_eval' "$pane/log" || fail "the end was not recorded on the item: $(cat "$pane/log")"
  grep -qx 'fleet-bench canary score c-7' "$pane/log" || fail "the score was given more than the task: $(cat "$pane/log")"
  grep -qF "tmp=$run/tmp" "$pane/log" || fail "the oracle's srt has no TMPDIR in the run dir: $(cat "$pane/log")"
  run ls "$run"; refute_output --partial srt-ses_eval
}

# agy_ready -- an allowlisted agy harness in lane sandbox "pub" (which masks ~/), its stubbed agy on
# PATH, and fix-menu a canary of it.
agy_ready() {
  harness_ready
  harness_sandboxed paid
  harness_set '.harnesses.agy = {source: "agy", end_classifier: "agy", headless: true, timeout_min: 180, projects: ["game"], sandbox: "pub", models: {flash: "gemini-3.8-flash-medium"}}'
  export SANDBOX_AGY_STATE="$HOME/.gemini/antigravity-cli"
  mkdir -p "$SANDBOX_AGY_STATE"
  stub agy 'exit 0'   # the start runs only its /usage check; ~/.local/bin, on PATH here, may hold the real one
  cp "$REPO_ROOT/.local/bin/agent-agy" "$SANDBOX/bin/agent-agy"   # copied, never linked (helpers/sandbox.bash)
  mkdir -p "$HOME/.local/lib" && cp "$REPO_ROOT/.local/lib/agy-result.jq" "$HOME/.local/lib/agy-result.jq"   # item-end reads it at its default path
  canary_item fix-menu c-7
  git init -q "$SANDBOX/repos/game"
}

@test "an agy harness runs inside srt under a cleared env, its log kept outside it, the canary steps around it and its TUI after" {
  agy_ready
  export LITELLM_MASTER_KEY=sk-master
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness agy --model flash
  assert_success
  runs="$HOME/.agent/agy/runs" qr=$(printf %q "$HOME/.agent/agy/runs")
  line=$(grep -m1 'agy --output-format' "$NOTES_FIXTURE/calls.log")
  [[ "$line" == *"fleet-bench canary start c-7 && { timeout 180m agent-agy run --log $qr/agy_"*".jsonl -- env -i "* ]] || fail "no canary start, then agent-agy outside the jail: $line"
  [[ "$line" == *"TMPDIR=$qr/tmp CLAUDE_CODE_TMPDIR=$qr/tmp AGENT_QUEUE_ITEM=fix-menu AGENT_RUN_PAIR=agy:flash srt --settings $qr/srt-agy_"*".json -- agy --output-format stream-json --dangerously-skip-permissions --model gemini-3.8-flash-medium -p "* ]] ||
    fail "agy is not inside srt, flags ahead of -p: $line"
  [[ "$line" != *LITELLM_MASTER_KEY* ]] || fail "the master key reached the line"
  # The settings: the profile's masks and hosts; the worktree, agy's state and the run's tmp writable, agy's
  # binary readable, and the run dir itself (the logs, the settings) left masked.
  s=$(cat "$runs"/srt-agy_*.json)
  assert_equal "$(jq -c .filesystem.denyRead <<<"$s")" '["~/","/tmp"]'
  assert_equal "$(jq -c .filesystem.allowWrite <<<"$s")" "[\".\",\"$SANDBOX_AGY_STATE\",\"$runs/tmp\"]"
  jq -e --arg b "$(realpath "$(command -v agy)")" '.filesystem.allowRead | index($b)' <<<"$s" >/dev/null || fail "agy's binary not readable: $s"
  # The pane line as a shell runs it: agy prints P1's success stream; agent-agy keeps it and the exit,
  # record-end reads the end from that log, onto the item, and the replay opens agy on the run's conversation.
  pane="$SANDBOX/pane" && mkdir -p "$pane"
  printf '#!/usr/bin/env bash\necho "fleet-bench $*" >> %q\n' "$pane/log" > "$pane/fleet-bench"
  printf '#!/usr/bin/env bash\necho "srt key=${LITELLM_MASTER_KEY:-none}" >> %q\nwhile [ "$1" != -- ]; do shift; done; shift; exec "$@"\n' "$pane/log" > "$pane/srt"
  printf '#!/usr/bin/env bash\nshift; exec "$@"\n' > "$pane/timeout"
  printf '#!/usr/bin/env bash\nif [ "$1" = --output-format ]; then cat %q; else echo "agy tui $*" >> %q; fi\n' \
    "$REPO_ROOT/tests/fixtures/harness-contract/agy-success.jsonl" "$pane/log" > "$pane/agy"
  printf '#!/usr/bin/env bash\necho "%s $*" >> %q\n' agent-queue "$pane/log" > "$pane/agent-queue"
  printf '#!/usr/bin/env bash\n[ "$1" != record-end ] || exec %q "$@"\necho "no queue item"\n' "$REPO_ROOT/.local/bin/fleet-dispatch" > "$pane/fleet-dispatch"
  chmod +x "$pane"/*
  PATH="$pane:$PATH" bash -c "${line#* :: }" >/dev/null
  run cat "$pane/log"
  assert_line --index 0 'fleet-bench canary start c-7'
  assert_line --index 1 'srt key=none'
  assert_line --index 2 'agent-queue set fix-menu end_reason=stopped'
  assert_line --index 3 'fleet-bench canary score c-7'
  assert_line --index 4 'agent-queue move fix-menu done --status ok'
  assert_line --index 6 'agy tui --conversation 8138a473-5239-47fc-afb9-b84f14384328'
  log=$(ls "$runs"/agy_*.jsonl)
  assert_equal "$(jq -r .event "$log" | sed -n '1p;$p' | tr '\n' ' ')" 'start exit '
  run ls "$runs"; refute_output --partial srt-agy_
}

@test "an agy harness starts only in a lane sandbox, and with a projects list only in one that masks ~/" {
  agy_ready
  harness_set 'del(.harnesses.agy.sandbox)'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness agy --model flash
  assert_failure 2
  assert_output --partial "agy has a projects allowlist, so it must be an opencode harness with a config_dir, or an agy one whose lane sandbox masks ~/"
  harness_set 'del(.harnesses.agy.projects)'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness agy --model flash
  assert_failure 2
  assert_output --partial "agy runs agy, which runs only in a lane sandbox"
  printf '%s\n' '{"sandbox": {"filesystem": {"denyRead": ["~/.ssh"], "allowWrite": []}, "network": {"allowedDomains": ["gw.test"]}}}' > "$AGENTCTL_SANDBOX_DIR/thin.json"
  harness_set '.harnesses.agy.projects = ["game"] | .harnesses.agy.sandbox = "thin"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness agy --model flash
  assert_failure 2
  assert_output --partial "an agy one whose lane sandbox masks ~/"
  assert_not_called 'wt new'
}

@test "a sandboxed harness refuses an item that is not a canary, a non-opencode harness holds no sandbox, and a missing srt starts nothing" {
  harness_ready
  harness_set --arg d "$SANDBOX/oc-public" '.harnesses.paid.projects = ["game"] | .harnesses.paid.config_dir = $d'
  harness_sandboxed paid
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_failure 2
  assert_output --partial 'paid runs in a sandbox that sees its worktree alone, so it takes only a canary item with its task id (canary:), a class promoted for it or a trainee row, and it carries no #pts/N (fix-menu)'
  # A canary tag without its task id is refused too: the score step would have nothing to score.
  agent-queue set fix-menu tags=canary >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_failure 2
  assert_output --partial 'takes only a canary item with its task id'
  canary_item fix-menu c-1
  harness_set '.harnesses.codex.sandbox = "pub"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_failure 2
  assert_output --partial "codex names lane sandbox 'pub', which only an opencode or agy harness holds"
  export SANDBOX_SRT_NEEDS="srt no-such-tool-here"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness paid --model glm
  assert_failure
  assert_output --partial "lane sandbox 'pub' cannot hold paid: no-such-tool-here is not on PATH"
  assert_not_called 'opencode run'
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "the refused item left the queue"
}

# trainee_start_ready -- paid sandboxed and allowlisted to game, a trainee lane naming it (model-lane
# trainee), and t-one, a one-point tier-1 row.
trainee_start_ready() {
  harness_ready
  harness_set --arg d "$SANDBOX/oc-public" '.harnesses.paid.projects = ["game"] | .harnesses.paid.config_dir = $d'
  harness_sandboxed paid
  trainee_repo "$SANDBOX/repos/game"
  sonnet_lane
  export TRAINEE_LANE='{"candidates":[{"harness":"paid","model":"glm"}],"points":1,"reviewer":"opus","reviewer_model":"opus"}'
  agent-queue add --project game --slug t-one --priority high --tags tier1 "Fix the menu title #pts/1" >/dev/null
}

@test "a trainee run is the sandboxed opencode run, then its review hand-off outside the sandbox however the run ends, with no canary steps" {
  trainee_start_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item t-one --harness paid --model glm
  assert_success
  assert_equal "$(qfield "$(qitem running t-one)" trainee)" paid:glm
  qr=$(printf %q "$SANDBOX/oc-public/run")
  line=$(grep -m1 'opencode run' "$NOTES_FIXTURE/calls.log")
  [[ "$line" == *" HUP TERM; { timeout 180m env -i "*" srt --settings $qr/srt-ses_eval"*".json -- opencode run --standalone"* ]] || fail "the run is not inside srt: $line"
  [[ "$line" == *" </dev/null; fleet-dispatch trainee-review t-one; tmux set-option -t \"\$TMUX_PANE\" @headless t-one 2>/dev/null; "* ]] || fail "no review hand-off after the run: $line"
  [[ "$line" != *"fleet-bench canary"* ]] || fail "a trainee run carries canary steps: $line"
  # The brief: the task, and that the run leaves its edits uncommitted.
  [[ "$line" == *"Fix the menu title"* && "$line" == *"Do not commit, push or open a pull request"* ]] || fail "no trainee brief: $line"
  # The pane line as a shell runs it: the hand-off runs after a run that timed out too.
  pane="$SANDBOX/pane" && mkdir -p "$pane"
  printf '#!/usr/bin/env bash\necho "timeout $1" >> %q; exit 124\n' "$pane/log" > "$pane/timeout"
  printf '#!/usr/bin/env bash\necho "fleet-dispatch $*" >> %q\n' "$pane/log" > "$pane/fleet-dispatch"
  chmod +x "$pane"/*
  PATH="$pane:$PATH" bash -c "${line#* :: }"
  assert_equal "$(cat "$pane/log")" "$(printf '%s\n' 'timeout 180m' 'fleet-dispatch trainee-review t-one' 'fleet-dispatch run-result t-one')"
}

@test "a headless run's pane opens its transcript after its tail: the opencode TUI on its session, in the run's own jail and srt settings, no --auto; reap gets its record, and the settings go with the pane" {
  trainee_start_ready
  export LITELLM_MASTER_KEY=sk-master
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item t-one --harness paid --model glm
  assert_success
  run="$SANDBOX/oc-public/run" qr=$(printf %q "$SANDBOX/oc-public/run")
  line=$(grep -m1 'opencode run' "$NOTES_FIXTURE/calls.log")
  sid=$(sed -E 's/.*opencode run --standalone --auto --session (ses_eval[0-9]+) .*/\1/' <<<"$line")
  [[ "$sid" == ses_eval* ]] || fail "no session id on the run: $line"
  # The run's env and srt prefix, and the replay's: the same words, plus only what the run left.
  # So the replay holds the jail (env -i), its own config_dir and no Claude Code or project rules
  # (the public-only rule), the run's data dir (its transcript) and the same srt settings.
  ran=${line#*\{ timeout 180m }; ran=${ran%% opencode run *}
  replay=${line#*; tmux set-option -t \"\$TMUX_PANE\" @headless t-one 2>/dev/null; }; replay=${replay%% opencode --standalone --session *}
  assert_equal "${replay/ AGENT_RUN_RESULT=\"\$(fleet-dispatch run-result t-one 2>\/dev\/null)\"/}" "$ran"
  [[ "$ran" == "env -i "*" OPENCODE_CONFIG_DIR=$(printf %q "$SANDBOX/oc-public") OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_DISABLE_PROJECT_CONFIG=1 XDG_DATA_HOME=$qr/data "*" AGENT_RUN_PAIR=paid:glm srt --settings $qr/srt-$sid.json --" ]] || fail "the run is not in its jail: $ran"
  [[ "$line" == *" opencode --standalone --session $sid; }" ]] || fail "the replay does not open the run's session last: $line"
  [[ "${line#*@headless}" != *--auto* && "$line" != *LITELLM_MASTER_KEY* ]] || fail "the replay auto-approves, or the master key reached the line: $line"
  # reap's record of the session, kept apart from the item (a move to queued/ drops its session:).
  assert_equal "$(cat "$FLEET_DISPATCH_DIR/replay/t-one@game-agent-1")" "$(printf '%s\t%s\t' "$(qfield "$(qitem running t-one)" session | cut -d: -f1)" game-agent-1)"
  # The pane line as a shell runs it: run, tail, mark, replay with a cleared env that names its result.
  pane="$SANDBOX/pane" && mkdir -p "$pane"
  printf '#!/usr/bin/env bash\necho "timeout $1" >> %q\n' "$pane/log" > "$pane/timeout"
  printf '#!/usr/bin/env bash\necho "fleet-dispatch $*" >> %q; [ "$1" != run-result ] || echo "patch written, 1 file, +2 -1"\n' "$pane/log" > "$pane/fleet-dispatch"
  tmux_script "$(printf 'echo "tmux $*" >> %q' "$pane/log")"
  printf '#!/usr/bin/env bash\necho "srt ${*: -1} pair=$AGENT_RUN_PAIR result=$AGENT_RUN_RESULT key=${LITELLM_MASTER_KEY:-none} leak=${PANE_SECRET:-none}" >> %q\n' "$pane/log" > "$pane/srt"
  chmod +x "$pane"/*
  [ -e "$run/srt-$sid.json" ] || fail "no srt settings before the pane runs"
  TMUX_PANE=%7 PANE_SECRET=x PATH="$pane:$PATH" bash -c "${line#* :: }"
  assert_equal "$(cat "$pane/log")" "$(printf '%s\n' 'timeout 180m' 'fleet-dispatch trainee-review t-one' 'tmux set-option -t %7 @headless t-one' \
    'fleet-dispatch run-result t-one' "srt $sid pair=paid:glm result=patch written, 1 file, +2 -1 key=none leak=none")"
  [ ! -e "$run/srt-$sid.json" ] || fail "the srt settings outlived the pane"
  # A pane closed under the replay (reap's tmux-close hangs it up) still removes the settings.
  echo '{}' > "$run/srt-$sid.json"
  printf '#!/usr/bin/env bash\nkill -HUP $PPID\n' > "$pane/srt"
  run env PATH="$pane:$PATH" bash -c "${line#* :: }"
  assert_equal "$status" 129
  [ ! -e "$run/srt-$sid.json" ] || fail "a hung-up pane left its srt settings"
}

@test "run-result: a patch by files and lines, else the item's PR, its note, or its state" {
  trainee_start_ready
  TRAINEE_DIR_T="$HOME/.local/state/agentctl/dispatch/trainee" && mkdir -p "$TRAINEE_DIR_T"
  printf '%s\n' 'diff --git a/x.sh b/x.sh' '--- a/x.sh' '+++ b/x.sh' '@@ -1 +1,2 @@' '-a' '+b' '+c' \
    'diff --git a/y.md b/y.md' '--- a/y.md' '+++ b/y.md' '@@ -1,2 +1,2 @@' '-d' '--- sql' '+e' '+++ x' > "$TRAINEE_DIR_T/t-one.patch"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run-result t-one
  assert_success
  # A body line that reads like a header ("-- sql" removed, "++ x" added) still counts.
  assert_output 'patch written, 2 files, +4 -3'
  rm "$TRAINEE_DIR_T/t-one.patch"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run-result t-one
  assert_output 'queued'
  agent-queue set t-one note="session ended: no diff; requeued on claude" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run-result t-one
  assert_output 'session ended: no diff; requeued on claude'
  agent-queue set t-one pr=o/game#12 >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run-result t-one
  assert_output 'PR o/game#12, queued'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run-result 'no/such'
  assert_failure 2
}

@test "trainee-review: the diff is a patch beside its base that waits for a batch review, the worktree is put back; no diff, and trainee-reject, send the row back on claude" {
  trainee_start_ready
  agent-queue add --project game --slug t-empty --priority high --tags tier1 "Fix the save title #pts/1" >/dev/null
  for s in t-one t-empty; do agent-queue set "$s" agent=paid model=glm trainee=paid:glm >/dev/null; agent-queue move "$s" running >/dev/null; done
  # The run's worktree is a linked one: in the main checkout the review refuses, since its reset would discard work there.
  m="$SANDBOX/main" && git init -q "$m" && printf 'a\n' > "$m/menu.md"
  git -C "$m" add menu.md && git -C "$m" -c user.name=t -c user.email=t@t commit -qm base
  printf 'mine\n' > "$m/menu.md"
  run bash -c "cd $(printf %q "$m") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review t-one"
  assert_failure 1; assert_output --partial 'is no linked worktree'
  assert_equal "$(cat "$m/menu.md")" mine
  git -C "$m" checkout -q -- menu.md
  w="$SANDBOX/wt" && git -C "$m" worktree add -q "$w" 2>/dev/null
  base=$(git -C "$w" rev-parse HEAD)
  # No diff: a reject, the row back in the queue on claude, its trainee kept so no trainee takes it again.
  run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review t-empty"
  assert_success
  assert_output --partial 'trainee-reject: t-empty is back in the queue, on claude: paid:glm left no diff'
  f=$(qitem queued t-empty)
  [ -n "$f" ] || fail "the row with no diff did not go back to the queue"
  assert_equal "$(qfield "$f" agent)" claude
  assert_equal "$(qfield "$f" trainee)" paid:glm
  [ -z "$(agent-queue show review-t-empty --json 2>/dev/null)" ] || fail "a review item for no diff"
  run trainee_why "$(agent-queue show t-empty --json)"
  assert_failure; assert_output 'a ladder run took it once already (paid:glm)'
  # A diff touching a file the sandbox could not build is a reject too, named by the file, and the
  # worktree goes back to its base (ar-4739: the row's words no longer have to name its files).
  agent-queue add --project game --slug t-py --priority high --tags tier1 "Fix the save tool #pts/1" >/dev/null
  agent-queue set t-py agent=paid model=glm trainee=paid:glm >/dev/null; agent-queue move t-py running >/dev/null
  printf 'print(1)\n' > "$w/tool.py"
  run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review t-py"
  assert_success
  assert_output --partial 'trainee-reject: t-py is back in the queue, on claude: its diff touches tool.py, which is no markdown file'
  [ -n "$(qitem queued t-py)" ] || fail "the row whose diff touched tool.py did not go back to the queue"
  [ ! -e "$HOME/.local/state/agentctl/dispatch/trainee/t-py.patch" ] || fail "the rejected diff's patch is still there"
  assert_equal "$(git -C "$w" status --porcelain)" ''
  # A row that cannot move to review stays running, the diff in the worktree as well as the patch.
  printf 'b\n' > "$w/menu.md"; printf 'new\n' > "$w/title.md"
  mkdir -p "$SANDBOX/aqfail"
  printf '#!/usr/bin/env bash\n[ "$1 $3" != "move review" ] || exit 1\nexec %q "$@"\n' "$SANDBOX/bin/agent-queue" > "$SANDBOX/aqfail/agent-queue"
  chmod +x "$SANDBOX/aqfail/agent-queue"
  PATH="$SANDBOX/aqfail:$PATH" run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review t-one"
  assert_failure 1; assert_output --partial 'could not move t-one to review; it stays running'
  assert_equal "$(cat "$w/menu.md")" b
  assert_equal "$(jq -r .state <<<"$(agent-queue show t-one --json)")" running
  # A diff, an edit and a new file: saved as a patch beside its base, the worktree put back, and no
  # review item of its own: the row waits in review for the next batch review.
  run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review t-one"
  assert_success
  patch="$HOME/.local/state/agentctl/dispatch/trainee/t-one.patch"
  assert_output --partial "trainee-review: t-one's diff is $patch; it waits for the next batch review"
  grep -q '^+++ b/title.md' "$patch" || fail "the new file is not in the patch: $(cat "$patch")"
  assert_equal "$(cat "${patch%.patch}.base")" "$base"
  assert_equal "$(git -C "$w" status --porcelain)" ''
  assert_equal "$(git -C "$w" rev-parse HEAD)" "$base"
  git -C "$w" apply --check "$patch" || fail "the patch does not apply on its base"
  [ -z "$(agent-queue show review-t-one --json 2>/dev/null)" ] || fail "a per-diff review item was queued"
  it=$(agent-queue show t-one --json)
  assert_equal "$(jq -r .state <<<"$it")" review
  assert_equal "$(jq -r .note <<<"$it")" 'trainee paid:glm left a diff; the next trainee batch review lands it or sends the row back'
  run trainee_waiting
  assert_equal "$(jq -r .slug <<<"$output")" t-one
  # The batch brief: the patch, its base and both verbs, for each waiting row.
  run trainee_batch_task trainee-batch-x "$(trainee_waiting)"
  assert_output --partial 'This is agent-queue item trainee-batch-x.'
  assert_output --partial '## Queue item t-one'
  assert_output --partial "on base $base of"
  assert_output --partial "git apply --3way $patch"
  assert_output --partial "fleet-dispatch trainee-reject t-one --why"
  assert_output --partial "agent-land <N> --item t-one"
  assert_output --partial "agent-queue set t-one review_fix=none"
  assert_output --partial "review_fix=small"
  # The review rejects it: the row goes back on claude and the patch goes.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-reject t-one
  assert_failure 2
  # Its why goes on the trainee's model-lane run, where score prints it per pair.
  agent-queue set t-one lane_run=run-7 >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-reject t-one --why "edits the wrong menu"
  assert_success
  grep -qx 'model-lane outcome run-7 redo --why edits the wrong menu --cause reject' "$NOTES_FIXTURE/calls.log" || fail "the reject filed no why on the run: $(cat "$NOTES_FIXTURE/calls.log" 2>/dev/null)"
  grep -qx 'model-lane outcome run-7 redo --cause reject' "$NOTES_FIXTURE/calls.log" || fail "the reject's requeue filed no reject cause"
  it=$(agent-queue show t-one --json)
  assert_equal "$(jq -r .state <<<"$it")" queued
  assert_equal "$(jq -r .note <<<"$it")" 'trainee paid:glm rejected: edits the wrong menu'
  assert_equal "$(jq -r .agent <<<"$it")" claude
  [ ! -e "$patch" ] && [ ! -e "${patch%.patch}.base" ] || fail "the rejected patch or its base is still there"
  run trainee_waiting
  assert_output ''
  # A row no trainee ran is refused by both verbs.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-reject fix-menu --why x
  assert_failure 2; assert_output --partial 'trainee-reject: no trainee ran fix-menu'
  # A row that is not running (here, the rejected one, back in the queue) is no run's tail.
  run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review t-one"
  assert_failure 2; assert_output --partial 'trainee-review: t-one is queued, not running'
}

@test "trainee-review: a run with no diff says what ended its session (provider, timeout), and 'left no diff' only when the model finished its turn" {
  trainee_start_ready
  m="$SANDBOX/main" && git init -q "$m" && printf 'a\n' > "$m/menu.txt"
  git -C "$m" add menu.txt && git -C "$m" -c user.name=t -c user.email=t@t commit -qm base
  w="$SANDBOX/wt" && git -C "$m" worktree add -q "$w" 2>/dev/null
  # The item's host is dropped: the review runs where the run ran, so it reads this machine's opencode.db.
  for spec in "t-prov|error|provider.rate-limit|60|paid:glm's session ended on a provider refusal or error (end provider" \
              "t-time|tool-calls|-|10800|paid:glm's session ran out its harness timeout (end timeout" \
              't-stop|stop|-|60|paid:glm left no diff'; do
    IFS='|' read -r slug finish etype secs want <<<"$spec"
    agent-queue add --project game --slug "$slug" --priority high --tags tier1 "Fix the $slug title #pts/1" >/dev/null
    agent-queue set "$slug" agent=paid model=glm trainee=paid:glm host=elsewhere >/dev/null; agent-queue move "$slug" running >/dev/null
    agent-queue claim "$slug" --sid "ses_eval${slug#t-}" >/dev/null
    oc_session "ses_eval${slug#t-}" "$finish|$etype" "$secs"
    run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review $slug"
    assert_success
    assert_output --partial "trainee-reject: $slug is back in the queue, on claude: $want"
  done
}

@test "trainee-review: a no-diff run that declares already-fixed or blocked files its run unrated with that cause, never a reject; an unknown word, no file, or a real diff beside the file is as before" {
  trainee_start_ready
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"'
  m="$SANDBOX/main" && git init -q "$m" && printf 'a\n' > "$m/menu.md"
  git -C "$m" add menu.md && git -C "$m" -c user.name=t -c user.email=t@t commit -qm base
  w="$SANDBOX/wt" && git -C "$m" worktree add -q "$w" 2>/dev/null
  # slug|first line of .no-diff ("-" for no file)|the reject reason that results
  for spec in "t-fixed|Already-Fixed: the title is fine|paid:glm found the task already fixed in the code (already-fixed), with no diff" \
              "t-spc|already fixed, see menu.md|paid:glm found the task already fixed in the code (already-fixed), with no diff" \
              "t-pre|blockedness|paid:glm left no diff" \
              "t-block|blocked|paid:glm could not do the task without a human decision or access it lacks (blocked), with no diff" \
              "t-word|gave up|paid:glm left no diff" \
              "t-none|-|paid:glm left no diff"; do
    IFS='|' read -r slug marker want <<<"$spec"
    agent-queue add --project game --slug "$slug" --priority high --tags tier1 "Fix the $slug title #pts/1" >/dev/null
    agent-queue set "$slug" agent=paid model=glm trainee=paid:glm "lane_run=run-$slug" >/dev/null; agent-queue move "$slug" running >/dev/null
    rm -f "$w/.no-diff"; [ "$marker" = - ] || printf '%s\nmore\n' "$marker" > "$w/.no-diff"
    run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review $slug"
    assert_success
    assert_output --partial "trainee-reject: $slug is back in the queue, on claude: $want"
    [ ! -e "$w/.no-diff" ] || fail "$slug left its .no-diff in the worktree"
  done
  grep -qx 'model-lane outcome run-t-fixed unrated --why paid:glm found the task already fixed in the code (already-fixed), with no diff --cause already-fixed' "$NOTES_FIXTURE/calls.log" || fail "already-fixed filed no unrated run: $(cat "$NOTES_FIXTURE/calls.log")"
  grep -qx 'model-lane outcome run-t-fixed unrated --cause already-fixed' "$NOTES_FIXTURE/calls.log" || fail "already-fixed's requeue filed no unrated cause"
  grep -qx 'model-lane outcome run-t-block unrated --why paid:glm could not do the task without a human decision or access it lacks (blocked), with no diff --cause blocked' "$NOTES_FIXTURE/calls.log" || fail "blocked filed no unrated run"
  # The negative control: the unknown word and the missing file are still rejects of the trainee's run.
  grep -qx 'model-lane outcome run-t-word redo --why paid:glm left no diff --cause reject' "$NOTES_FIXTURE/calls.log" || fail "a no-diff run with an unknown word is no reject"
  grep -qx 'model-lane outcome run-t-none redo --why paid:glm left no diff --cause reject' "$NOTES_FIXTURE/calls.log" || fail "a no-diff run with no file is no reject"
  # A real diff beside the marker is reviewed as a diff: the marker is not in the patch.
  agent-queue add --project game --slug t-diff --priority high --tags tier1 "Fix the t-diff title #pts/1" >/dev/null
  agent-queue set t-diff agent=paid model=glm trainee=paid:glm >/dev/null; agent-queue move t-diff running >/dev/null
  printf 'b\n' > "$w/menu.md"; printf 'blocked\n' > "$w/.no-diff"
  run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") trainee-review t-diff"
  assert_success; assert_output --partial 'lanes.yaml names no trainee reviewer'
  refute_output --partial 'no diff'
}

@test "trainee_waiting fetches the patch a trainee run left on its fleet worker; a run here, or a worker with no patch, fetches nothing" {
  trainee_start_ready
  worker '2.0 16 1 50'
  # The worker's fleet-dispatch, over ssh, reads its own state dir, which is not this one's.
  stub fleet-dispatch "FLEET_DISPATCH_STATE=$(printf %q "$SANDBOX/remote") exec $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") \"\$@\""
  for s in t-one t-here; do
    [ "$s" = t-one ] || agent-queue add --project game --slug "$s" --priority high --tags tier1 "Fix the save title #pts/1" >/dev/null
    agent-queue set "$s" agent=paid model=glm trainee=paid:glm >/dev/null; agent-queue move "$s" running >/dev/null; agent-queue move "$s" review >/dev/null
  done
  agent-queue set t-one host=razer-laptop >/dev/null
  # Negative control: the worker holds no patch yet, so neither row waits.
  run trainee_waiting
  assert_output ''
  mkdir -p "$SANDBOX/remote/trainee"
  printf 'abc123\n' > "$SANDBOX/remote/trainee/t-one.base"
  printf -- '--- a/menu.txt\n+++ b/menu.txt\n@@ -1 +1 @@\n-a\n+b\n' > "$SANDBOX/remote/trainee/t-one.patch"
  run trainee_waiting
  assert_equal "$(jq -r .slug <<<"$output")" t-one
  local d="$HOME/.local/state/agentctl/dispatch/trainee"
  assert_equal "$(cat "$d/t-one.base")" abc123
  assert_equal "$(cat "$d/t-one.patch")" "$(cat "$SANDBOX/remote/trainee/t-one.patch")"
  [ ! -e "$d/t-here.patch" ] || fail "a row run here fetched a patch"
}

@test "a direct run is the sandboxed run stamped direct:, then its landing outside the sandbox; a verdict with no promotion is a trainee run" {
  trainee_start_ready
  # Negative control: the verdict lists no direct pair, so the same start is a trainee run.
  START_VERDICT='{"lane":"sonnet","class":"fix/s","direct":[]}' run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item t-one --harness paid --model glm
  assert_success
  assert_equal "$(qfield "$(qitem running t-one)" trainee)" paid:glm
  assert_called 'fleet-dispatch trainee-review t-one'
  agent-queue add --project game --slug d-one --priority high --tags tier1 "Fix the menu border #pts/3" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  START_VERDICT='{"lane":"sonnet","class":"fix/s","direct":["paid:glm"]}' run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item d-one --harness paid --model glm
  assert_success
  f=$(qitem running d-one)
  assert_equal "$(qfield "$f" direct)" paid:glm
  assert_equal "$(qfield "$f" trainee)" ''
  line=$(grep -m1 'opencode run' "$NOTES_FIXTURE/calls.log")
  [[ "$line" == *" srt --settings "*" </dev/null; fleet-dispatch direct-land d-one --rc \$?; tmux set-option -t \"\$TMUX_PANE\" @headless d-one 2>/dev/null; "* ]] || fail "no direct landing after the sandboxed run: $line"
  [[ "$line" != *"trainee-review"* ]] || fail "a direct run hands off to review: $line"
  assert_called 'model-lane log --item d-one --task Fix the menu border #pts/3 --lane trainee --by rule --picked glm --ran glm --harness paid --class fix/s'
}

@test "direct-land: the diff is committed, pushed, opened as a PR and landed by agent-land; a failed run, no diff, a hook or CI path, or a failed landing sends the row back on claude, and a merged one stays" {
  trainee_start_ready
  for s in d-one d-empty d-rc d-hook d-fail d-merged d-crit; do
    agent-queue add --project game --slug "$s" --priority high --tags tier1 "Fix the menu for $s #pts/3" >/dev/null
    agent-queue set "$s" agent=paid model=glm direct=paid:glm row=game:ar-9 >/dev/null; agent-queue move "$s" running >/dev/null
  done
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q --bare "$SANDBOX/origin.git"
  m="$SANDBOX/main" && git init -q -b main "$m" && printf 'a\n' > "$m/menu.txt"
  git -C "$m" add menu.txt && git -C "$m" commit -qm base && git -C "$m" remote add origin "$SANDBOX/origin.git" && git -C "$m" push -q origin main
  w="$SANDBOX/wt" && git -C "$m" worktree add -q -b game-d "$w" 2>/dev/null
  base=$(git -C "$w" rev-parse HEAD)
  gh_script 'printf "gh %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ "$1 $2" != "pr create" ] || echo https://github.com/o/game/pull/77; [ "$1 $2" != "pr view" ] || echo "${PR_STATE:-OPEN}"'
  stub agent-land 'echo "agent-land $*" >> "$NOTES_FIXTURE/calls.log"; exit ${LAND_RC:-0}'
  land() { run bash -c "cd $(printf %q "$w") && $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") direct-land $1"; }
  # No diff: the row goes back on claude, its direct: kept so no ladder run takes it again.
  land d-empty
  assert_success; assert_output --partial 'direct-land: d-empty is back in the queue, on claude: it left no diff'
  it=$(agent-queue show d-empty --json)
  assert_equal "$(jq -r '"\(.state) \(.agent) \(.direct)"' <<<"$it")" 'queued claude paid:glm'
  assert_not_called 'gh pr create'
  # A run that exited non-zero lands nothing, its diff dropped; nor does a diff on the repo's hooks or CI.
  printf 'half\n' > "$w/menu.txt"
  land "d-rc --rc 124"
  assert_success; assert_output --partial 'direct-land: d-rc is back in the queue, on claude: the run exited 124'
  assert_equal "$(git -C "$w" status --porcelain)" ''
  mkdir -p "$w/.githooks" && printf 'exit 0\n' > "$w/.githooks/pre-commit"
  land d-hook
  assert_success; assert_output --partial 'its diff touches hook or CI paths (.githooks/pre-commit)'
  assert_equal "$(git -C "$w" status --porcelain)" ''
  assert_not_called 'gh pr create'
  # A diff: committed on the worktree's branch, pushed, a PR with the item's lines, landed by agent-land.
  printf 'b\n' > "$w/menu.txt"; printf 'new\n' > "$w/title.txt"
  land d-one
  assert_success; assert_output --partial 'direct-land: d-one landed as #77, by paid:glm with no review'
  assert_equal "$(git -C "$SANDBOX/origin.git" log -1 --format=%s game-d)" 'Fix the menu for d-one'
  assert_equal "$(git -C "$SANDBOX/origin.git" show game-d:title.txt)" new
  assert_called 'gh pr create --head game-d --title Fix the menu for d-one --body'
  assert_called 'Direct run: paid:glm'
  assert_called 'Task: ar-9'
  assert_called 'agent-land 77 --item d-one --ran-checks'
  # A landing that fails: the PR is closed, the row goes back on claude, and the worktree is put back.
  w="$SANDBOX/wt2" && git -C "$m" worktree add -q -b game-f "$w" 2>/dev/null; printf 'c\n' > "$w/menu.txt"
  LAND_RC=1 land d-fail
  assert_success; assert_output --partial 'direct-land: d-fail is back in the queue, on claude: agent-land #77 failed'
  assert_called 'gh pr close 77 --delete-branch'
  assert_equal "$(jq -r '"\(.state) \(.agent)"' <<<"$(agent-queue show d-fail --json)")" 'queued claude'
  assert_equal "$(git -C "$w" rev-parse HEAD)" "$base"
  assert_equal "$(git -C "$w" status --porcelain)" ''
  # agent-land that failed after its merge: the work is in, so the PR stays and the row is not redone.
  w="$SANDBOX/wt3" && git -C "$m" worktree add -q -b game-m "$w" 2>/dev/null; printf 'm\n' > "$w/menu.txt"
  LAND_RC=1 PR_STATE=MERGED land d-merged
  assert_failure 1; assert_output --partial 'direct-land: #77 merged, but agent-land failed after it; d-merged stays running'
  assert_equal "$(jq -r .state <<<"$(agent-queue show d-merged --json)")" running
  # Critical work (agent-land exit 5) waits on its validate item: the PR stays open, the row in review.
  w="$SANDBOX/wt4" && git -C "$m" worktree add -q -b game-c "$w" 2>/dev/null; printf 'k\n' > "$w/menu.txt"
  : > "$NOTES_FIXTURE/calls.log"
  LAND_RC=5 land d-crit
  assert_success; assert_output --partial 'direct-land: #77 is critical, so it waits on a second agent'"'"'s review; d-crit is in review'
  assert_not_called 'gh pr close'
  assert_equal "$(jq -r .state <<<"$(agent-queue show d-crit --json)")" review
  # A row no direct run took, and one not running, are no run's tail.
  land t-one
  assert_failure 2; assert_output --partial 'direct-land: no direct run took t-one'
  land d-fail
  assert_failure 2; assert_output --partial 'direct-land: d-fail is queued, not running'
}

@test "an opencode harness with no config_dir keeps ~/.config/opencode: no isolation env on its launch" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model qwen
  assert_success
  assert_called 'opencode run'
  assert_not_called 'OPENCODE_CONFIG_DIR'
  assert_not_called 'OPENCODE_DISABLE_PROJECT_CONFIG'
}

@test "a source with no room, and a harness with no source, both refuse the start" {
  harness_ready
  src_shut eval 'eval: its pool lazer is spent or inside its reserve'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model sonnet
  assert_failure
  assert_output --partial 'opencode has no room: eval: its pool lazer is spent'
  harness_set 'del(.harnesses.opencode.source)'
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
  # The ask the item waited on is answered, so its hold is clear (start refuses a held item).
  mkdir -p "$HOME/.agent/asks/game"
  printf 'id: pl1\nstatus: answered\nanswer: approve\nanswered_by: human\n' > "$HOME/.agent/asks/game/pl1.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item decided --harness codex --model sol
  assert_success
  assert_called 'whose plan, ~/.claude/plans/decided.md, the human has decided on below: build it if they approved it'
  assert_not_called 'plan first'
  # Negative control: the same map without resume refuses it, as paid and opencode are.
  harness_set '.harnesses.codex |= del(.resume)'
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
  mkdir -p "$HOME/.agent/asks/game"
  printf 'id: abc\nstatus: answered\nanswer: a\nanswered_by: human\n' > "$HOME/.agent/asks/game/abc.md"
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
  tmux_script 'echo "tmux $*" >> "$NOTES_FIXTURE/calls.log"; case " $* " in *" has-session "*) exit 1 ;; esac; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --resume th-4 --session cx-again --cwd "$SANDBOX/repos/game"
  assert_success
  assert_called 'new-session -d -P -F #{pane_id} -s cx-again'
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
  worker '2.0 16 1 50' true '[]' '[codex]'
  run cmd_start --host razer-laptop --project game --brief "$SANDBOX/b.md"
  assert_failure 2
  assert_output --partial 'starts a queued --item'
  agent-queue add --project game --slug x "x" >/dev/null
  run cmd_start --host nope --item x
  assert_failure 2
  assert_output --partial 'nope is not in the fleet roster'
  assert_not_called 'wt new'
  # A harness the worker does not list in fleet_harnesses; claude needs no listing.
  harness_ready; HARNESSES=$DISPATCH_HARNESSES
  agent-queue set x agent=paid model=glm >/dev/null
  run cmd_start --host razer-laptop --item x --harness paid --model glm
  assert_failure 2
  assert_output --partial 'x would run on paid, which razer-laptop does not list in fleet_harnesses'
  assert_not_called 'wt new'
  # A codex item that resumes a thread this machine's ~/.codex holds, though the worker lists codex.
  agent-queue add --project game --slug cx "cx" >/dev/null
  codex_ran cx 019a-thread
  run cmd_start --host razer-laptop --item cx
  assert_failure 2
  assert_output --partial 'cx resumes its last codex thread, which is on this machine; start it here, without --host'
  assert_not_called 'wt new'
}

# ar-3020: start --host took claude as there on every worker, and refused any start under a lane sandbox.
@test "start --host runs a harness only where the worker's kit has it, and a lane sandbox only where its kit has srt" {
  sandbox_ready
  worker '2.0 16 1 50' true '[]' '[codex]' 'codex'
  stub claude-acct 'echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"'
  agent-queue add --project game --slug w-one --priority high "Fix the menu" >/dev/null
  # Negative control: a claude item on a worker with no claude is refused, and stays queued.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item w-one --host razer-laptop
  assert_failure 2
  assert_output --partial 'w-one would run on claude, and razer-laptop has no claude it can run (fleet-dispatch kit there: codex)'
  assert_not_called 'wt new'
  [ -n "$(qitem queued w-one)" ] || fail 'the refused item left the queue'
  # A lane sandbox on a worker whose kit has claude but no srt: refused.
  worker '2.0 16 1 50' true '[]' '[codex]' 'claude codex'
  export DISPATCH_SANDBOX_PROFILE=lane
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item w-one --host razer-laptop
  assert_failure 2
  assert_output --partial "razer-laptop has no srt (fleet-dispatch kit there: claude codex), so it cannot hold lane sandbox 'lane'"
  assert_not_called 'wt new'
  # With srt there the same start goes to the worker, under the profile the worker builds.
  worker '2.0 16 1 50' true '[]' '[codex]' 'claude codex srt'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item w-one --host razer-laptop
  assert_success
  assert_called "exec env 'env' 'DISPATCH_SANDBOX_PROFILE=lane' 'DISPATCH_SANDBOX_GH_TOKEN_FILE=' 'fleet-dispatch' 'lane-sandbox' '$SANDBOX/repos/game'"
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: "
  assert_called 'env -u GH_TOKEN -u GITHUB_TOKEN claude --model'
  assert_called ' --settings '
  assert_equal "$(qfield "$(qitem running w-one)" host)" razer-laptop
  # A worker that does not answer is said as that, never as one with nothing in its kit.
  agent-queue add --project game --slug w-two --priority high "Fix the map" >/dev/null
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item w-two --host razer-laptop
  assert_failure 2
  assert_output --partial 'razer-laptop did not answer (fleet-dispatch kit there); w-two stays queued'
}

@test "kit: claude with every account signed in, codex and opencode on PATH, srt when srt can hold a run" {
  local d="$SANDBOX/kitbin" t
  mkdir -p "$d"
  for t in claude codex srt bwrap socat; do printf '#!/bin/sh\nexit 0\n' > "$d/$t"; done
  printf '#!/bin/sh\nexit "${NODE_RC:-0}"\n' > "$d/fleet-node"
  chmod +x "$d"/*
  kit() { SANDBOX_SRT_NEEDS='srt bwrap socat' HERE=$d PATH=$d run cmd_kit; }
  kit
  assert_output 'claude codex srt'
  # Negative controls: an unsigned account drops claude; a missing srt tool drops srt; opencode counts when there.
  NODE_RC=1 kit
  assert_output 'codex srt'
  rm "$d/socat"
  kit
  assert_output 'claude codex'
  rm "$d/claude"; cp "$d/codex" "$d/opencode"
  kit
  assert_output 'codex opencode'
}

@test "host_runs: a worker runs a harness its kit has, past claude only one it lists ready, and under a lane sandbox only with srt" {
  HOST_KIT[w]='claude codex' HOST_HARN[w]=''
  run host_runs w claude; assert_success
  # Negative controls: codex is in the kit but not listed ready; a lane sandbox needs srt in the kit.
  run host_runs w codex; assert_failure
  HOST_HARN[w]=codex; run host_runs w codex; assert_success
  DISPATCH_SANDBOX_PROFILE=lane run host_runs w claude; assert_failure
  HOST_KIT[w]='claude codex srt'
  DISPATCH_SANDBOX_PROFILE=lane run host_runs w claude; assert_success
  HOST_KIT[w]=''; run host_runs w claude; assert_failure
}

@test "harness-ready: each named harness this machine runs as a fleet worker, else its name and why" {
  harness_ready
  harness_set --arg d "$SANDBOX/oc-public" '.harnesses.paid.config_dir = $d'
  harness_sandboxed paid
  stub agent-codex 'exit 0'
  stub codex '[ ! -e "$NOTES_FIXTURE/codex.hang" ] || exit 124   # what timeout gives a login check that hangs
[ "$*" = "login status" ] && [ -e "$NOTES_FIXTURE/codex.login" ]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready paid codex opencode nope
  assert_success
  assert_output "$(printf '%s\n' paid 'codex: codex is not logged in here (codex login, as the human)' \
    'opencode: it is neither codex, agy nor an opencode harness with a config_dir, and a worker runs only those' "nope: $DISPATCH_HARNESSES has no nope")"
  # Codex runs on the worker's own ChatGPT login.
  touch "$NOTES_FIXTURE/codex.login"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready codex
  assert_output codex
  touch "$NOTES_FIXTURE/codex.hang"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready codex
  assert_output 'codex: codex login status did not answer in 10s'
  rm "$SANDBOX/paid.key"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready paid
  assert_output "paid: its key file $SANDBOX/paid.key is not readable"
  printf 'sk-paid\n' > "$SANDBOX/paid.key"; rm "$SANDBOX/eval-paid.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready paid
  assert_output "paid: its config $SANDBOX/eval-paid.json is not readable"
  # agy: its launcher, agent-agy and a lane sandbox, then a bounded /usage on the human's login. Both are
  # stubbed: the developer's own ~/.local/bin, on PATH here, may hold the real ones.
  stub agent-agy 'exit 0'
  harness_set '.harnesses.agy = {source: "agy", end_classifier: "agy", headless: true, timeout_min: 180, models: {flash: "gemini-3.8-flash-medium"}}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready agy
  assert_output 'agy: it names no lane sandbox, and a worker runs only a sandboxed harness'
  harness_set '.harnesses.agy.sandbox = "pub"'
  stub agy '[ ! -e "$NOTES_FIXTURE/agy.hang" ] || exit 124
[ "$*" = "--output-format json -p /usage" ]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready agy
  assert_output agy
  touch "$NOTES_FIXTURE/agy.hang"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready agy
  assert_output 'agy: agy /usage did not answer in 20s: not signed in here? (agy, as the human)'
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

# ar-3852: a phase whose dependency has an open PR starts in a worktree cut from that PR's head.
stacked_pair() {
  project game beta "$SANDBOX/repos/game"
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  # gh: `pr view 7 -R Org/game --json headRefOid -q .headRefOid` and the state read answer from the fixtures.
  gh_script 'case "$*" in *headRefOid*) cat "$NOTES_FIXTURE/pr7.head" ;; *state*) echo OPEN ;; esac'
  echo 0123456789abcdef0123456789abcdef01234567 > "$NOTES_FIXTURE/pr7.head"
  agent-queue add --project game --slug base --running "first phase"
  agent-queue set base open_pr=Org/game#7
  # Only a plan phase stacks (ar-4537): second's brief names its plan.
  printf '# P\n' > "$SANDBOX/p.md"
  legacy second "after: base" --project game "Phase 2 of the plan $SANDBOX/p.md: second phase"
}

@test "start --item of a phase stacked on an open PR cuts its worktree from that PR's head; no stack, no --base (ar-3852)" {
  stacked_pair
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item second
  assert_success
  assert_called "new --base 0123456789abcdef0123456789abcdef01234567 --server lab --detach -c $SANDBOX/repos/game"
  assert_output --partial "stacked on base's open PR Org/game#7"
  # NEGATIVE CONTROL: an item with no dependency gets no --base.
  agent-queue add --project game --slug plain "plain"
  : > "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item plain
  assert_success
  run grep -c -e '--base' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "start --item of a stacked phase whose PR head cannot be read starts nothing and stays queued (ar-3852)" {
  stacked_pair
  gh_script 'case "$*" in *headRefOid*) exit 1 ;; *state*) echo OPEN ;; esac'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item second
  assert_failure
  assert_output --partial "could not read the head of Org/game#7"
  assert_not_called 'wt new'
  [ -n "$(qitem queued second)" ] || fail "second left the queue"
}

# --- rollup ---------------------------------------------------------------------------

# reject <harness> <model> <why> [days ago] -- one lane trainee run in model-lane's log that a review sent back
reject() {
  jq -nc --arg h "$1" --arg m "$2" --arg w "$3" --arg t "$(date -u -d "${4:-0} days ago" +%FT%T+00:00)" \
    '{id: ("r" + ($t | gsub("[^0-9]"; ""))), ts: $t, lane: "trainee", ran: $m, harness: $h, outcome: "redo", why: $w, item: "ar-x"}' >> "$DISPATCH_LANE_RUNS"
}

rollup_setup() {
  export DISPATCH_LANE_RUNS="$SANDBOX/runs.jsonl"
  : > "$DISPATCH_LANE_RUNS"
  export DISPATCH_LANE_EVENTS="$SANDBOX/demotions.jsonl"
  : > "$DISPATCH_LANE_EVENTS"
  : > "$NOTES_FIXTURE/rows.agent-runtime.agent"
}

@test "rollup: three 'left no diff' rejects on one pair file one row naming the pair; the next night files none" {
  rollup_setup
  for i in 1 2 3; do reject nim glm 'nim:glm left no diff'; done
  # an approved run and another lane's reject are no rejects of a trainee
  jq -nc '{ts: "2099-01-01T00:00:00+00:00", lane: "trainee", ran: "glm", harness: "nim", outcome: "ok"}' >> "$DISPATCH_LANE_RUNS"
  jq -nc '{ts: "2099-01-01T00:00:00+00:00", lane: "sonnet", ran: "sonnet", outcome: "redo", why: "x left no diff"}' >> "$DISPATCH_LANE_RUNS"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output --partial 'filed: fix(trainee): nim:glm runs keep leaving no diff (3 since'
  run grep -c '^notes ptask agent-runtime --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -F 'add --why minor-fault fix(trainee): nim:glm runs keep leaving no diff #size/s #of/ar-4724 #low --origin fleet-dispatch --detail 3 trainee rejects since' "$NOTES_FIXTURE/calls.log"
  assert_success
  assert_output --partial 'nim:glm 3. Fix it in how nim:glm runs, or drop the pair'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output 'rollup: no new cause since '"$(date -u -d '7 days ago' +%F)"
  run grep -c '^notes ptask agent-runtime --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "rollup: two rejects of a cause, or three older than the window, file nothing" {
  rollup_setup
  for i in 1 2; do reject nim minimax "nim:minimax's session ended on a provider refusal or error (end provider: a rate limit), with no diff"; done
  for i in 1 2 3; do reject agy flash 'agy:flash left no diff' 9; done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output 'under the bar (2 of 3): fix(trainee): nim:minimax runs keep ending on end provider (nim:minimax 2)'
  assert_not_called 'ptask agent-runtime --agent add'
}

@test "rollup: a diff refused for the file it touched is one cause whichever file it was (ar-5117)" {
  rollup_setup
  tail="which is no markdown file, nor a shell or bats file outside a cargo or npm tree, so the sandbox could not build it"
  reject agy flash "agy:flash's its diff touches .local/bin/fleet-bench.py, $tail"
  reject agy flash "agy:flash's its diff touches src/main.rs, $tail"
  reject agy flash "agy:flash's its diff touches package.json, $tail"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output --partial 'filed: fix(trainee): agy:flash runs touch a file the sandbox cannot build (3 since'
}

@test "rollup: a cause on two pairs names the harnesses, and an open row with its title is joined, not twinned" {
  rollup_setup
  why=" session ended on a provider refusal or error (end provider: a rate limit), with no diff"
  reject nim minimax "nim:minimax's$why"; reject nim minimax "nim:minimax's$why"; reject ocfree beam "ocfree:beam's$why"
  row agent-runtime agent ar-9 '- [ ] fix(trainee): trainee runs keep ending on end provider #low <!-- id:ar-9 -->'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output --partial 'joined ar-9: fix(trainee): trainee runs keep ending on end provider (3 since'
  assert_output --partial 'nim:minimax 2, ocfree:beam 1)'
  assert_not_called 'ptask agent-runtime --agent add'
  # with no open row it files one, and says which harnesses to look in
  : > "$NOTES_FIXTURE/rows.agent-runtime.agent"; rm -f "$FLEET_DISPATCH_DIR/rollup.tsv"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_output --partial 'filed: fix(trainee): trainee runs keep ending on end provider'
  run grep -F 'Fix it in the harness or source (nim, ocfree): more than one model hits it.' "$NOTES_FIXTURE/calls.log"
  assert_success
}

@test "rollup: a board it cannot read files nothing and fails; --dry files nothing and stamps nothing" {
  rollup_setup
  for i in 1 2 3; do reject nim glm 'nim:glm left no diff'; done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup --dry
  assert_success
  assert_output --partial 'would file: fix(trainee): nim:glm runs keep leaving no diff (3 since'
  [ ! -e "$FLEET_DISPATCH_DIR/rollup.tsv" ] || fail "--dry stamped a title"
  stub notes 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_failure
  assert_output --partial 'cannot read the agent-runtime board, so no row is filed'
}

@test "rollup: a cause that spreads keeps its pair's row; a run with no reason counts; a torn line is skipped" {
  rollup_setup
  for i in 1 2 3; do reject nim glm 'nim:glm left no diff'; done
  printf '{"ts": "2099-01-01T00:00:00+00:00", "lane": "trai\n' >> "$DISPATCH_LANE_RUNS"
  for i in 1 2 3; do
    jq -nc --arg t "$(date -u +%FT%T+00:00)" '{ts: $t, lane: "trainee", ran: "minimax", harness: "nim", outcome: "failed"}' >> "$DISPATCH_LANE_RUNS"
  done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output --partial 'filed: fix(trainee): nim:glm runs keep leaving no diff (3 since'
  assert_output --partial 'filed: fix(trainee): nim:minimax runs end with no reason recorded (3 since'
  run grep -F -- '--detail e.g. no reason recorded (outcome failed)' "$NOTES_FIXTURE/calls.log"
  assert_success
  run cut -f1 "$FLEET_DISPATCH_DIR/rollup.tsv"
  assert_output --partial 'keep leaving no diff'
  # the no-diff cause spreads to a second pair: the open row naming nim:glm is joined, not twinned by a "trainee runs" one, and a longer title that starts the same is another cause
  row agent-runtime agent ar-8 '- [ ] fix(trainee): nim:glm runs keep leaving no diff behind a lock #low <!-- id:ar-8 -->'
  row agent-runtime agent ar-7 '- [ ] fix(trainee): nim:glm runs keep leaving no diff #low <!-- id:ar-7 -->'
  for i in 1 2 3; do reject agy flash "agy:flash left no diff" -1; done   # dated tomorrow: newer than the stamp, whatever second it lands in
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output 'joined ar-7: fix(trainee): trainee runs keep leaving no diff (3 since '"$(date -u -d '7 days ago' +%F)"': agy:flash 3)'
  run grep -c '^notes ptask agent-runtime --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 2
}

@test "rollup: under agentctl each pass declares its outcome (WORKED filed, NOOP quiet, FAILED unread board); --dry declares none" {
  rollup_setup
  export AGENTCTL_NAME=rollup
  out="$AGENTCTL_STATE_DIR/rollup/last-outcome"
  for i in 1 2 3; do reject nim glm 'nim:glm left no diff'; done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup --dry
  assert_success
  [ ! -e "$out" ] || fail "--dry declared $(cat "$out")"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  [ "$(cat "$out")" = WORKED ] || fail "filing pass: $(cat "$out")"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  [ "$(cat "$out")" = NOOP ] || fail "quiet pass: $(cat "$out")"
  # a fresh log, so these rejects are not read as counted by the stamp written in the same second
  rollup_setup; rm -f "$FLEET_DISPATCH_DIR/rollup.tsv"
  for i in 1 2; do reject nim beam 'nim:beam left no diff'; done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output --partial 'under the bar (2 of 3)'
  [ "$(cat "$out")" = NOOP ] || fail "under the bar: $(cat "$out")"
  reject nim beam 'nim:beam left no diff'
  stub notes 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_failure
  [ "$(cat "$out")" = FAILED ] || fail "unread board: $(cat "$out")"
}

# lane_event <lane> <event> <class> <candidate> [days ago] -- one line of model-lane's demotions.jsonl
lane_event() {
  jq -nc --arg l "$1" --arg e "$2" --arg c "$3" --arg h "$4" --arg t "$(date -u -d "${5:-0} days ago" +%FT%T+00:00)" \
    '{lane: $l, event: $e, ts: $t, why: "run abc: 2 of 4 rated items redo or failed, past 25%"} + (if $h == "" then {} else {class: $c, candidate: $h} end)' >> "$DISPATCH_LANE_EVENTS"
}

@test "rollup: three failed items on any harness, Claude included, file one fix(runs) row under the plan epic; a landed, unrated or cancelled one is no non-landing" {
  rollup_setup
  for i in 1 2 3; do
    agent-queue add --project agent-runtime --slug nl-$i "non-landing $i" >/dev/null
    agent-queue move nl-$i done --status failed --end stopped >/dev/null
  done
  agent-queue add --project agent-runtime --slug lim-1 "limit" >/dev/null
  agent-queue move lim-1 done --status failed --end limit >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output --partial 'filed: fix(runs): claude:'
  assert_output --partial 'runs end on stopped (3 since'
  refute_output --partial 'end on limit'
  run grep -F 'fix(runs): ' "$NOTES_FIXTURE/calls.log"
  assert_output --partial '#size/s #of/ar-4724 #low'
  assert_output --partial 'Fix it in why claude:'
  run grep -c '^notes ptask agent-runtime --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_output 'rollup: no new cause since '"$(date -u -d '7 days ago' +%F)"
}

@test "rollup: a model-lane demote or retire files one row on its first night, joins the open row after, and a promote after it files none" {
  rollup_setup
  lane_event opus demoted fix/m claude:sonnet 1
  lane_event trainee retired - nim:glm 1
  lane_event opus demoted chore/s claude:sonnet 3; lane_event opus promoted chore/s claude:sonnet 2
  lane_event trainee retired - nim:old 3; lane_event trainee retrial - nim:old 2   # back on the roster
  lane_event trainee demoted feat/s nim:back 1   # a promoted class sent back to review: a page, no row
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output --partial 'filed: fix(model-lane): claude:sonnet left lane opus for fix/m (1 since'
  assert_output --partial 'filed: fix(model-lane): nim:glm left the trainee roster (1 since'
  refute_output --partial 'chore/s'
  refute_output --partial 'nim:old'
  refute_output --partial 'nim:back'
  run grep -F "Undo: model-lane promote opus --class 'fix/m' --candidate claude:sonnet" "$NOTES_FIXTURE/calls.log"
  assert_success
  run grep -F 'Undo: model-lane promote trainee --class - --candidate nim:glm' "$NOTES_FIXTURE/calls.log"
  assert_success
  run grep -c '^notes ptask agent-runtime --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 2
  # the next night, and a later event while the row is open: joined, not twinned
  row agent-runtime agent ar-5 '- [x] fix(model-lane): nim:glm left the trainee roster #low <!-- id:ar-5 -->'
  row agent-runtime agent ar-6 '- [ ] fix(model-lane): claude:sonnet left lane opus for fix/m #low <!-- id:ar-6 -->'
  lane_event trainee retired - nim:glm -1   # retired again after its row closed: a new row, not a join of the closed one
  lane_event opus demoted fix/m claude:sonnet -1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" rollup
  assert_success
  assert_output --partial 'joined ar-6: fix(model-lane): claude:sonnet left lane opus for fix/m'
  assert_output --partial 'filed: fix(model-lane): nim:glm left the trainee roster'
  run grep -c '^notes ptask agent-runtime --agent add ' "$NOTES_FIXTURE/calls.log"
  assert_output 3
}

@test "the brief of an item a run handed off names its note first, then its salvage branch; one never handed off names none (ar-2777)" {
  started_item fix-menu lab:game-agent-1
  run item_brief "$(agent-queue show fix-menu --json)"
  refute_output --partial 'handed it to this fresh session'
  f="$(qitem running fix-menu)"
  sed -i 's|^slug: .*|&\nhandoff: /home/u/.claude/plans/fix-menu.md\nhandoffs: 1\nsalvage: feat/menu@abc123|' "$f"
  run item_brief "$(agent-queue show fix-menu --json)"
  assert_output --partial 'An earlier run of this item handed it to this fresh session to keep context small (agent-queue handoff): read /home/u/.claude/plans/fix-menu.md first.'
  assert_output --partial 'left its unfinished work on branch feat/menu at abc123 on origin'
  [[ "$output" == *"read /home/u/.claude/plans/fix-menu.md first"*"left its unfinished work on branch feat/menu"* ]] || fail "the note is not named before the salvage branch"
}

@test "start never runs a validate item as its author: no author item, itself, the author's conversation or session (ar-1689)" {
  project game beta "$SANDBOX/repos/game"
  started_item fix-crash lab:game-agent-9 run
  sed -i 's/^---$/sessions: abc-123\n---/' "$(qitem running fix-crash)"
  # vq <slug> <after> -> a queued validate item
  vq() { started_item "$1" '' '' '' auto:validate queued; sed -i "s/^---\$/tags: validate\n${2:+after: $2\n}---/" "$(qitem queued "$1")"; }
  vq validate-none ''
  run cmd_start --item validate-none
  assert_failure 2
  assert_output --partial 'validate-none is a validate item whose after: names no author item but itself'
  vq validate-self validate-self
  run cmd_start --item validate-self
  assert_failure 2
  assert_output --partial 'validate-self is a validate item whose after: names no author item but itself'
  vq validate-fix-crash-01234567 fix-crash
  run cmd_start --server default --session s9 --cwd "$SANDBOX/repos/game" --resume abc-123 --item validate-fix-crash-01234567
  assert_failure 2
  assert_output --partial 'validates fix-crash, which conversation abc-123 worked: a second agent validates it, never its author'
  run cmd_start --server lab --session game-agent-9 --cwd "$SANDBOX/repos/game" --resume other-1 --item validate-fix-crash-01234567
  assert_failure 2
  assert_output --partial 'validates fix-crash, whose session is lab:game-agent-9'
  # A fresh start is a new conversation: the check passes it on (here to the after: hold).
  run cmd_start --item validate-fix-crash-01234567
  refute_output --partial 'never its author'
  assert_not_called 'claude --resume abc-123'
}
