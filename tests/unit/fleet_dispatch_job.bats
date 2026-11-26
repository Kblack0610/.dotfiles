#!/usr/bin/env bats
# fleet-dispatch, mode: job items (ar-3040): a queued item whose run: is an agentctl runner starts through agentctl with
# no model session, keeps every hold, and closes on the runner's own outcome word. agentctl, systemctl and claude are stubs.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

# job_fixture: a runner conf, the stubs that record what would run, a past hour for at: holds, and nothing holding dispatch.
job_fixture() {
  mkdir -p "$SANDBOX/agents"
  printf 'NAME=game-build\nKIND=oneshot\nEFFECT=none\n' > "$SANDBOX/agents/game-build.conf"
  export AGENTCTL_CONF_DIR="$SANDBOX/agents" AGENT_QUEUE_NOW=12:00 DISPATCH_REAP_GRACE=60
  project game beta "$SANDBOX/repos/game"
  stub agentctl 'echo "agentctl $*" >> "$NOTES_FIXTURE/calls.log"; [ ! -e "$NOTES_FIXTURE/agentctl.refuse" ] || { echo "game-build: already running" >&2; exit 1; }'
  stub claude 'echo "claude $*" >> "$NOTES_FIXTURE/calls.log"'
  stub systemctl 'cat "$NOTES_FIXTURE/unit.state" 2>/dev/null || echo inactive'
  stub agent-hold '[ ! -e "$NOTES_FIXTURE/dispatch.held" ] || [ "$2" != dispatch ] || exit 1
if [ "$1 $2" = "check unity" ]; then echo "held: unity (since 11:00 by unity-agent-1: a build)"; exit 1; fi; exit 0'
}

# job_add <slug> [tags]: the item the human queues, as agent-queue add --mode job.
job_add() {
  case "${2:-}" in
    *hold:*) agent-queue add --project game --mode job --run "game-build all beta" --slug "$1" >/dev/null || return
      legacy_hold "$1" "tags: $2" ;;   # add files an item with a hold: tag on its board row, which a fixture has none of
    *) agent-queue add --project game --mode job --run "game-build all beta" ${2:+--tags "$2"} --slug "$1" >/dev/null ;;
  esac
}

# job_run_line <outcome> <started epoch>: a finished run in the ledger agentctl writes.
job_run_line() {
  . "$HOME/.local/lib/agent-proof.sh"
  mkdir -p "$(proof_state_dir)"
  printf '{"name":"game-build","invocation":"x","started":%s,"finished":%s,"result":"success","exit":"0","outcome":"%s","out":[0,0],"err":[0,0]}\n' \
    "$2" "$(($2 + 5))" "$1" >> "$(proof_state_dir)/runs.jsonl"
}

# job_running <slug> <seconds ago>: the item as dispatch's start left it, started that long ago.
job_running() {
  agent-queue move "$1" running >/dev/null
  agent-queue set "$1" "started=$(date -u -d "-$2 seconds" +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
}

@test "a job item with a past at: starts its runner through agentctl: no session, no worktree, no claude" {
  job_fixture
  job_add nightly "at:01:00"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial "started job nightly: game-build"
  assert_called "agentctl start game-build --no-block -- all beta"
  assert_not_called 'wt new'
  assert_not_called 'claude '
  [ -n "$(qitem running nightly)" ] || fail "the job item is not running"
  [ -z "$(qitem queued nightly)" ]
}

@test "negative control: the same job item under hold:unity, at: later today or the dispatch hold stays queued across a pass" {
  job_fixture
  job_add on-hold "at:01:00 hold:unity"
  job_add later "at:23:00"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'agentctl start'
  [ -n "$(qitem queued on-hold)" ] || fail "hold:unity item left the queue"
  [ -n "$(qitem queued later)" ] || fail "at:23:00 item left the queue"
  # The dispatch hold stops a job start as it stops any start.
  job_add free "at:01:00"
  : > "$NOTES_FIXTURE/dispatch.held"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'agentctl start'
  [ -n "$(qitem queued free)" ] || fail "a held dispatch started a job"
  # And the free item does start once nothing holds it.
  rm "$NOTES_FIXTURE/dispatch.held"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_called "agentctl start game-build --no-block -- all beta"
  [ -n "$(qitem running free)" ]
  [ -n "$(qitem queued on-hold)" ]
}

@test "a runner agentctl refuses to start (already running) leaves the item queued for the next pass" {
  job_fixture
  job_add busy "at:01:00"
  : > "$NOTES_FIXTURE/agentctl.refuse"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called "agentctl start game-build"
  assert_output --partial "stays queued"
  [ -n "$(qitem queued busy)" ] || fail "a refused start did not requeue the item"
  [ -z "$(qitem running busy)" ]
}

@test "a job item whose runner conf is gone is closed failed, not left to retry" {
  job_fixture
  job_add ghost "at:01:00"
  rm "$SANDBOX/agents/game-build.conf"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'agentctl start'
  [ "$(agent-queue show ghost --json | jq -r '.state + " " + .status')" = "done failed" ]
}

@test "reap: a job item closes on its runner's outcome word: WORKED and NOOP ok, FAILED, STALLED and none failed" {
  job_fixture
  local w want
  for w in WORKED:ok NOOP:ok FAILED:failed STALLED:failed NONE:failed; do
    want=${w#*:}; w=${w%%:*}
    rm -f "$HOME/.local/state/agentctl/runs.jsonl"
    job_add "j-${w,,}"; job_running "j-${w,,}" 600
    job_run_line "$([ "$w" = NONE ] && echo '' || echo "$w")" "$(date -d '-300 seconds' +%s)"
    reap_jobs
    [ "$(agent-queue show "j-${w,,}" --json | jq -r '.state + " " + .status')" = "done $want" ] || fail "$w did not close $want"
  done
}

@test "reap: a job item names the runner's word in its note, and a run from before the item started is not its run" {
  job_fixture
  job_add old; job_running old 100
  echo active > "$NOTES_FIXTURE/unit.state"   # past the grace, so only a live unit keeps it until its run is written
  job_run_line FAILED "$(date -d '-900 seconds' +%s)"
  reap_jobs
  [ -n "$(qitem running old)" ] || fail "an earlier run closed the item"
  job_run_line WORKED "$(date -d '-50 seconds' +%s)"
  reap_jobs
  [ "$(agent-queue show old --json | jq -r '.state + " " + .status')" = "done ok" ]
  run agent-queue show old --json
  assert_output --partial "runner game-build ended WORKED"
}

@test "reap: no ledger line closes a job item failed only once the grace has passed and the unit is not live" {
  job_fixture
  job_add fresh; job_running fresh 10
  job_add lost; job_running lost 600
  reap_jobs
  [ -n "$(qitem running fresh)" ] || fail "a start inside the grace was closed"
  [ "$(agent-queue show lost --json | jq -r '.state + " " + .status')" = "done failed" ]
  # Negative control: a unit still running keeps the item, whatever its age.
  job_add live; job_running live 600
  echo active > "$NOTES_FIXTURE/unit.state"
  reap_jobs
  [ -n "$(qitem running live)" ] || fail "a live runner's item was closed"
}

@test "a reap pass never settles a job item as a lost session" {
  job_fixture
  job_add sess; job_running sess 600
  # No ledger line yet, the unit is active: it is the runner's to close, not a gone session's.
  echo active > "$NOTES_FIXTURE/unit.state"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" reap
  [ -n "$(qitem running sess)" ] || fail "reap closed a job item that has a live run"
  refute_output --partial "session ended"
}

@test "start --item on a job item starts it by hand under the same holds, and refuses a session flag" {
  job_fixture
  job_add hand "hold:unity"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item hand
  assert_failure
  assert_output --partial "waits on hold:unity"
  assert_not_called 'agentctl start'
  job_add hand2 "at:01:00"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item hand2 --model opus
  assert_failure 2
  assert_not_called 'agentctl start'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item hand2
  assert_success
  assert_called "agentctl start game-build --no-block -- all beta"
  [ -n "$(qitem running hand2)" ]
}
