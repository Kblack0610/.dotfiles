#!/usr/bin/env bats
# agentctl's runner status contract, exercised as a real subprocess.
#
# The contract is a FILE, not a command: every headless runner publishes key=value at
# ~/.local/state/agentctl/<name>/status, and readers (fleet.sh, the cockpit) parse that file
# directly. So these tests assert on the file the writer leaves behind, never on its stdout
# -- if `report` starts writing a different shape, the readers break silently and only this
# tier notices. The keys are state/project/item/detail/updated.
#
# Two properties matter more than the rest and are each pinned by a test below:
#   MERGE      `report item=...` must not wipe `project`, or a runner reporting progress
#              erases the very field that says which project it is on.
#   FAIL LOUD  an unknown key or state is rejected. A typo'd key that got stored would sit
#              in a file nobody reads, looking exactly like a runner that never reported.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  STATUS="$AGENTCTL_STATE_DIR/alpha/status"
}

# field <key> — the contract file's value for one key.
field() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$STATUS"; }

# ── the shape it writes ──────────────────────────────────────────────────────

@test "report writes the contract file with every documented key" {
  run "$AGENTCTL_BIN" report --name alpha state=working project=bnb-platform item='sprint resume'
  assert_success
  [ -f "$STATUS" ]
  assert_equal "$(field state)" 'working'
  assert_equal "$(field project)" 'bnb-platform'
  assert_equal "$(field item)" 'sprint resume'
  # `updated` is stamped by the writer, never by the caller -- a reader uses it for staleness.
  [[ "$(field updated)" =~ ^[0-9]+$ ]]
}

@test "the file is exactly one line per key, so a reader can parse it line-wise" {
  "$AGENTCTL_BIN" report --name alpha state=idle
  run wc -l < "$STATUS"
  assert_output '5'
}

@test "a multi-line value is flattened instead of forging extra records" {
  # A runner reporting a command's output would otherwise inject `item`-looking lines.
  "$AGENTCTL_BIN" report --name alpha "item=$(printf 'first\nsecond')"
  assert_equal "$(wc -l < "$STATUS")" '5'
  assert_equal "$(field item)" 'first second'
}

# ── merge ────────────────────────────────────────────────────────────────────

@test "a later report merges: reporting item alone keeps project" {
  "$AGENTCTL_BIN" report --name alpha state=working project=bnb-platform item='first thing'
  "$AGENTCTL_BIN" report --name alpha item='second thing'
  assert_equal "$(field project)" 'bnb-platform'
  assert_equal "$(field state)" 'working'
  assert_equal "$(field item)" 'second thing'
}

@test "an explicitly empty value clears that key without clearing the others" {
  "$AGENTCTL_BIN" report --name alpha state=blocked project=dotfiles item='waiting'
  "$AGENTCTL_BIN" report --name alpha item=
  assert_equal "$(field item)" ''
  assert_equal "$(field project)" 'dotfiles'
}

# ── fail loud ────────────────────────────────────────────────────────────────

@test "an unknown key is rejected rather than stored" {
  run "$AGENTCTL_BIN" report --name alpha statu=working
  assert_failure
  assert_output --partial 'unknown key'
  [ ! -f "$STATUS" ]
}

@test "an unknown state is rejected: the vocabulary is what drives a reader's glyph" {
  run "$AGENTCTL_BIN" report --name alpha state=busy
  assert_failure
  assert_output --partial 'unknown state'
}

@test "every documented state is accepted" {
  local s
  for s in working idle ok blocked error; do
    run "$AGENTCTL_BIN" report --name alpha "state=$s"
    assert_success
    assert_equal "$(field state)" "$s"
  done
}

@test "a bare word that is not key=value is rejected" {
  run "$AGENTCTL_BIN" report --name alpha working
  assert_failure
  assert_output --partial 'key=value'
}

@test "a report with nothing to say is an error, not an empty write" {
  run "$AGENTCTL_BIN" report --name alpha
  assert_failure
  [ ! -f "$STATUS" ]
}

# ── who am I ─────────────────────────────────────────────────────────────────

@test "the name comes from AGENTCTL_NAME when --name is absent" {
  # This is the path every runner actually uses: agentctl@.service exports AGENTCTL_NAME=%i,
  # so a runner's own script says `agentctl report item=...` and never hardcodes its name.
  AGENTCTL_NAME=alpha run "$AGENTCTL_BIN" report state=ok
  assert_success
  assert_equal "$(field state)" 'ok'
}

@test "--name wins over AGENTCTL_NAME" {
  AGENTCTL_NAME=beta run "$AGENTCTL_BIN" report --name alpha state=ok
  assert_success
  [ -f "$STATUS" ]
  [ ! -f "$AGENTCTL_STATE_DIR/beta/status" ]
}

@test "no name from either source is an error, not a file called ''" {
  run env -u AGENTCTL_NAME "$AGENTCTL_BIN" report state=ok
  assert_failure
  assert_output --partial 'no agent name'
}

# ── the engine-side lifecycle envelope ───────────────────────────────────────
# agentctl@.service wires these two in, so every runner has a baseline status without
# touching its own script. That is what makes the contract adoptable one runner at a time.

@test "--lifecycle start marks the runner working and clears the previous item" {
  "$AGENTCTL_BIN" report --name alpha state=idle project=dotfiles item='last run did a thing'
  run "$AGENTCTL_BIN" report --name alpha --lifecycle start
  assert_success
  assert_equal "$(field state)" 'working'
  assert_equal "$(field item)" ''
  # project survives a restart: it is a property of the runner, not of one fire.
  assert_equal "$(field project)" 'dotfiles'
}

@test "--lifecycle stop on a clean exit reports idle" {
  SERVICE_RESULT=success EXIT_STATUS=0 run "$AGENTCTL_BIN" report --name alpha --lifecycle stop
  assert_success
  assert_equal "$(field state)" 'idle'
}

@test "--lifecycle stop on a failure reports error and keeps the systemd cause" {
  # The whole point: a oneshot that died looks identical to an idle one in ActiveState.
  SERVICE_RESULT=exit-code EXIT_STATUS=2 run "$AGENTCTL_BIN" report --name alpha --lifecycle stop
  assert_success
  assert_equal "$(field state)" 'error'
  assert_output ''
  run cat "$STATUS"
  assert_output --partial 'exit-code'
  assert_output --partial 'exit=2'
}

@test "--lifecycle stop preserves what the runner last said it was doing" {
  "$AGENTCTL_BIN" report --name alpha project=bnb-platform item='shipped PR #12'
  SERVICE_RESULT=success run "$AGENTCTL_BIN" report --name alpha --lifecycle stop
  assert_equal "$(field item)" 'shipped PR #12'
  assert_equal "$(field project)" 'bnb-platform'
}

@test "an unknown lifecycle is rejected" {
  run "$AGENTCTL_BIN" report --name alpha --lifecycle sideways
  assert_failure
  assert_output --partial 'unknown lifecycle'
}

# ── atomicity + hygiene ──────────────────────────────────────────────────────

@test "the replace is atomic: no temp file is left beside the status file" {
  # A reader polls this file; it must never see a partial write, and never a stray sibling
  # it might mistake for state.
  "$AGENTCTL_BIN" report --name alpha state=ok
  "$AGENTCTL_BIN" report --name alpha state=idle
  run bash -c 'ls -A "$AGENTCTL_STATE_DIR/alpha"'
  assert_output 'status'
}

@test "reporting creates the runner's state dir when it has never run" {
  [ ! -d "$AGENTCTL_STATE_DIR/fresh" ]
  run "$AGENTCTL_BIN" report --name fresh state=working
  assert_success
  [ -f "$AGENTCTL_STATE_DIR/fresh/status" ]
}

@test "reporting does not disturb the runner's activity log" {
  seed_runner alpha 'an earlier activity line'
  "$AGENTCTL_BIN" report --name alpha state=ok
  run cat "$AGENTCTL_STATE_DIR/alpha/activity.log"
  assert_output --partial 'an earlier activity line'
}

# ── it shows up in `agentctl status` ─────────────────────────────────────────

@test "status surfaces the reported payload next to the systemd envelope" {
  seed_runner alpha
  "$AGENTCTL_BIN" report --name alpha state=blocked project=bnb-platform item='needs a human'
  run "$AGENTCTL_BIN" status alpha
  assert_success
  assert_output --partial 'reported: blocked'
  assert_output --partial 'bnb-platform'
  assert_output --partial 'needs a human'
}

@test "status on a runner that never reported omits the block entirely" {
  seed_runner quiet
  run "$AGENTCTL_BIN" status quiet
  assert_success
  refute_output --partial 'reported:'
}

# ── the proof-contract envelope (PENDING -> STALLED) ─────────────────────────
# The distinction this buys: "never wired" and "ran and said nothing" used to be
# the same observable (an absent last-outcome) and need different fixes.

@test "--lifecycle start seeds PENDING so silence stops reading as unwired" {
  run "$AGENTCTL_BIN" report --name probe --lifecycle start
  assert_success
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/probe/last-outcome")" 'PENDING'
}

@test "--lifecycle stop promotes an untouched PENDING to STALLED" {
  "$AGENTCTL_BIN" report --name probe --lifecycle start
  run "$AGENTCTL_BIN" report --name probe --lifecycle stop
  assert_success
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/probe/last-outcome")" 'STALLED'
}

@test "a runner's own verdict survives the stop envelope" {
  # The whole point: the engine only fills the gap. A runner that DID report must
  # not have its answer overwritten with STALLED.
  "$AGENTCTL_BIN" report --name probe --lifecycle start
  printf 'WORKED' > "$AGENTCTL_STATE_DIR/probe/last-outcome"
  "$AGENTCTL_BIN" report --name probe --lifecycle stop
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/probe/last-outcome")" 'WORKED'
}

@test "NOOP also survives, not just WORKED" {
  # Negative control for the test above: if promote matched on 'not STALLED'
  # rather than 'is PENDING', NOOP would be clobbered and that test would still pass.
  "$AGENTCTL_BIN" report --name probe --lifecycle start
  printf 'NOOP' > "$AGENTCTL_STATE_DIR/probe/last-outcome"
  "$AGENTCTL_BIN" report --name probe --lifecycle stop
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/probe/last-outcome")" 'NOOP'
}

@test "stop on a runner that never started does not invent an outcome" {
  run "$AGENTCTL_BIN" report --name never --lifecycle stop
  assert_success
  [ ! -e "$AGENTCTL_STATE_DIR/never/last-outcome" ]
}
