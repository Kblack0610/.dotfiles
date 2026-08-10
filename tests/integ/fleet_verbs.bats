#!/usr/bin/env bats
# fleet.sh's `$SELF --verb` contract, exercised as a real subprocess.
#
# This is the tier that catches the regressions that matter. Every fzf --bind runs
# `$SELF --verb {2}` and then `reload($SELF --list)`; if a verb stops emitting rows, drops
# a field, or stops shelling out to agentctl, the UI breaks at runtime with no error and no
# stack trace -- fzf just renders the wrong thing or acts on the wrong row.
#
# The roster contract is the other thing under test here: fleet.sh derives its runner list
# from ~/.config/agentctl/agents/*.conf, replacing a hardcoded seven-name list that had
# already gone stale once. A test that seeds a conf and expects a row is the guard on that.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
}

# ── --list: the row feed fzf consumes ────────────────────────────────────────

@test "--list succeeds and produces rows even with an entirely empty fleet" {
  run "$FLEET" --list
  assert_success
  [ "${#lines[@]}" -gt 0 ]   # the section headers always render
}

@test "--list emits exactly 5 tab-separated fields on every row" {
  seed_runner alpha 'did a thing'
  seed_watch beta OK 'a watch'
  run bash -c '"$FLEET" --list | awk -F"\t" "NF != 5 { print NR\": \"NF; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "--list uses only the documented row types in field 1" {
  seed_runner alpha
  seed_watch beta OK
  run bash -c '"$FLEET" --list | cut -f1 | sort -u'
  assert_success
  local t
  while read -r t; do
    case "$t" in
      head|runner|watch|ask|agent|hint) ;;
      *) fail "undocumented row type in field 1: '$t'" ;;
    esac
  done <<< "$output"
}

@test "--list renders all four sections" {
  run bash -c '"$FLEET" --list | grep -P "^head\t" | cut -f5 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'asks'
  assert_output --partial 'runners'
  assert_output --partial 'watches'
  assert_output --partial 'agents'
}

# ── the roster contract: the conf dir IS the list ────────────────────────────

@test "a runner appears purely because its conf exists" {
  seed_runner brand-new-runner
  run fleet_field runner 2
  assert_success
  assert_output --partial 'brand-new-runner'
}

@test "a runner NOT in the conf dir is never rendered" {
  # The bug this replaced: a hardcoded roster listed units whether or not they existed,
  # and missed every one that did.
  seed_runner only-me
  run fleet_field runner 2
  assert_success
  assert_output 'only-me'
}

@test "removing a conf removes the row, with no cached roster left behind" {
  seed_runner transient
  rm "$AGENTCTL_CONF_DIR/transient.conf"
  run fleet_field runner 2
  assert_success
  refute_output --partial 'transient'
}

@test "an empty conf dir yields a hint rather than a silent empty section" {
  run bash -c '"$FLEET" --runners | cut -f1'
  assert_success
  assert_output --partial 'hint'
}

@test "every runner row carries an id, which the mutation verbs need" {
  seed_runner alpha; seed_runner beta
  run bash -c '"$FLEET" --runners | awk -F"\t" "\$1==\"runner\" && \$2==\"\" { print; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "a runner row surfaces the last line of its activity log" {
  seed_runner chatty 'the last thing it actually did'
  run bash -c '"$FLEET" --runners | cut -f5 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'the last thing it actually did'
}

@test "a runner with no activity log still renders instead of erroring" {
  seed_runner quiet
  run "$FLEET" --runners
  assert_success
  assert_output --partial 'quiet'
}

# ── the runner status contract ───────────────────────────────────────────────
# A runner publishes key=value at <state>/<name>/status (agentctl `report`). systemd can
# only say whether the unit is running; this is the half that says on WHAT, and these tests
# are the reader's end of that contract. Adoption is per-runner, so the fallback to the
# activity tail matters as much as the happy path -- it is what keeps the runners that never
# adopted it rendering exactly as before.

@test "a reported item wins over the activity log tail" {
  seed_runner busy 'stale line from the log'
  seed_status busy working bnb-platform 'draining the sprint queue'
  run bash -c '"$FLEET" --runners | cut -f5 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'draining the sprint queue'
  refute_output --partial 'stale line from the log'
}

@test "the reported project renders, which is the join a reader could not make before" {
  seed_runner busy
  seed_status busy working bnb-platform 'some item'
  run bash -c '"$FLEET" --runners | cut -f5 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'bnb-platform'
}

@test "a runner that never reported still falls back to its activity tail" {
  seed_runner legacy 'what the old renderer showed'
  run bash -c '"$FLEET" --runners | cut -f5 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial 'what the old renderer showed'
}

@test "a reported blocked state raises the attention glyph on an inactive unit" {
  # The case systemd structurally cannot show: the process exited cleanly and is waiting on
  # a human, so ActiveState=inactive and ExecMainStatus=0 -- indistinguishable from idle.
  seed_runner waiting
  seed_status waiting blocked dotfiles 'needs an answer'
  run bash -c '"$FLEET" --runners | cut -f5 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_output --partial '!'
}

@test "an idle reported runner does NOT raise the attention glyph" {
  # Negative control for the test above: without it, a renderer that marked every reporting
  # runner as needing attention would pass just as happily.
  seed_runner calm
  seed_status calm idle dotfiles 'nothing to do'
  run bash -c '"$FLEET" --runners | cut -f5 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  refute_output --partial '!'
}

@test "field 4 stays the systemd state even when the runner reports its own" {
  # Two vocabularies, one field, would make $4 mean different things on different rows.
  seed_runner busy
  seed_status busy blocked dotfiles 'waiting'
  run fleet_field runner 4
  refute_output --partial 'blocked'
}

@test "a status file never costs a row its 5-field shape" {
  seed_runner busy
  seed_status busy working bnb-platform 'an item long enough to be clipped by the renderer'
  run bash -c '"$FLEET" --runners | awk -F"\t" "NF != 5 { bad=1 } END { exit bad+0 }"'
  assert_success
}

# ── watches ──────────────────────────────────────────────────────────────────

@test "--watches reports each watch's state verbatim in field 4" {
  seed_watch ok-one OK
  seed_watch tripped TRIP
  seed_watch errored ERROR
  run bash -c '"$FLEET" --watches | awk -F"\t" "\$1==\"watch\" { print \$2\"=\"\$4 }"'
  assert_success
  assert_output --partial 'ok-one=OK'
  assert_output --partial 'tripped=TRIP'
  assert_output --partial 'errored=ERROR'
}

@test "a tripped watch is visually distinguished from a healthy one" {
  # The entire point of the surface: a TRIP must not read like an OK.
  seed_watch ok-one OK
  seed_watch tripped TRIP
  local ok trip
  ok="$("$FLEET" --watches | awk -F'\t' '$2=="ok-one"  { print $5 }')"
  trip="$("$FLEET" --watches | awk -F'\t' '$2=="tripped" { print $5 }')"
  refute [ "$ok" = "$trip" ]
}

@test "a watch with no state file renders as unknown rather than vanishing" {
  printf 'name: orphan\nprobe: http\n' > "$WATCH_DIR/orphan.yaml"
  run bash -c '"$FLEET" --watches | awk -F"\t" "\$2==\"orphan\" { print \$4 }"'
  assert_success
  assert_output 'unknown'
}

@test "watch rows carry the manifest path in field 3, which Enter opens" {
  seed_watch w OK
  run bash -c '"$FLEET" --watches | awk -F"\t" "\$1==\"watch\" { print \$3 }"'
  assert_success
  assert_output --partial "$WATCH_DIR/w.yaml"
}

@test "a folded description is flattened in the rendered row, not left as >-" {
  seed_watch_folded folded OK
  run bash -c '"$FLEET" --watches | awk -F"\t" "\$2==\"folded\" { print \$5 }" | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'first line of the folded'
  refute_output --partial '>-'
}

# ── agents: the out-of-session filter ────────────────────────────────────────

@test "--agents hides agents that live in the session you are already attached to" {
  # Prefix+g already reaches those; the cockpit section is for the ones you cannot see.
  printf 'here:1\t~\tproj\tin my session\nelsewhere:2\t✓\tproj\tsomewhere else\n' \
    > "$NOTES_FIXTURE/agent-panel.list"
  printf 'here' > "$NOTES_FIXTURE/tmux.session"
  run bash -c '"$FLEET" --agents | awk -F"\t" "\$1==\"agent\" { print \$2 }"'
  assert_success
  assert_output 'elsewhere:2'
}

@test "--agents renders a hint when every live agent is in this session" {
  printf 'here:1\t~\tproj\tonly one\n' > "$NOTES_FIXTURE/agent-panel.list"
  printf 'here' > "$NOTES_FIXTURE/tmux.session"
  run bash -c '"$FLEET" --agents | cut -f1'
  assert_success
  assert_output --partial 'hint'
}

@test "--agents degrades to a hint when agent-panel returns nothing" {
  : > "$NOTES_FIXTURE/agent-panel.list"
  run "$FLEET" --agents
  assert_success
  assert_output --partial 'no live agent panes'
}

# ── mutation verbs: assert the CLI call, never real state ────────────────────

@test "--runner-op runner start issues an agentctl start for that runner" {
  run "$FLEET" --runner-op runner start delivery-loop
  assert_success
  assert_called 'agentctl start delivery-loop'
}

@test "--runner-op runner stop and restart map to their agentctl verbs" {
  "$FLEET" --runner-op runner stop sentinel
  "$FLEET" --runner-op runner restart sentinel
  assert_called 'agentctl stop sentinel'
  assert_called 'agentctl restart sentinel'
}

@test "--runner-op refuses any verb outside start/stop/restart" {
  # enable/disable are deliberately absent: they change durable schedule state, and a
  # nightly job switched off from a TUI is not noticed for a week.
  run "$FLEET" --runner-op runner enable sentinel
  assert_success
  assert_not_called 'agentctl enable'
  run "$FLEET" --runner-op runner disable sentinel
  assert_not_called 'agentctl disable'
}

@test "--runner-op with no runner name is a no-op rather than a broad command" {
  run "$FLEET" --runner-op runner start
  assert_success
  assert_not_called 'agentctl start '
}

@test "--journal opens the unit's journal in a window rather than in the picker" {
  run "$FLEET" --journal dream
  assert_success
  assert_called 'agentctl@dream.service'
}

# ── --enter: what Enter means per row kind ───────────────────────────────────

@test "--enter on a runner row opens its journal" {
  run "$FLEET" --enter runner dream agentctl@dream.service
  assert_success
  assert_called 'agentctl@dream.service'
}

@test "--enter on a watch row opens the manifest for editing" {
  seed_watch w OK
  run "$FLEET" --enter watch w "$WATCH_DIR/w.yaml"
  assert_success
  assert_called 'nvim'
}

@test "--enter on an agent row switches to that pane" {
  run "$FLEET" --enter agent 'other:3' 'other:3'
  assert_success
  assert_called 'switch-client'
}

@test "--enter on a head row does nothing at all" {
  run "$FLEET" --enter head '' ''
  assert_success
  assert_not_called 'nvim'
  assert_not_called 'switch-client'
  assert_not_called 'agentctl'
}

# ── robustness ───────────────────────────────────────────────────────────────

@test "an unknown verb does not silently succeed as if it were the UI" {
  run "$FLEET" --definitely-not-a-verb
  refute_output --partial $'runner\t'
}

@test "--list tolerates every data root being missing" {
  rm -rf "$AGENTCTL_CONF_DIR" "$WATCH_DIR" "$AGENTCTL_STATE_DIR" "$WATCH_STATE_DIR"
  run "$FLEET" --list
  assert_success
  assert_output --partial 'hint'
}

@test "--list never emits a row whose display field is empty" {
  seed_runner alpha
  seed_watch beta OK
  run bash -c '"$FLEET" --list | awk -F"\t" "\$5==\"\" { print NR; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "a runner name containing a space does not split into two rows" {
  # The sandbox path itself contains a space for this reason; the roster comes from
  # filenames, which are equally free to contain one.
  seed_runner 'odd name'
  run bash -c '"$FLEET" --runners | grep -cP "^runner\t"'
  assert_success
  assert_output '1'
}

# The mutation verbs take the row TYPE as well as the id, and refuse anything
# that is not a roster runner.
#
# Before the `run` section existed every row's {2} was a roster name, so passing
# {2} alone was safe BY ACCIDENT. A run row's {2} is a run id, which made
# `agentctl start <runid>` reachable from the keyboard; it no-opped only because
# agentctl's output is redirected to /dev/null. "Does nothing" and "cannot be
# asked" are different guarantees, and only the second survives a refactor.
@test "--runner-op refuses a non-runner row type" {
  run "$FLEET" --runner-op run 20260809T000000-abcdef start
  assert_success
  # Assert on CONTENT, not on the log's absence: the fixture may already have
  # one, and "the file is not there" would pass for the wrong reason.
  run cat "$NOTES_FIXTURE/calls.log"
  refute_output --partial '20260809T000000-abcdef'
}

@test "...and a runner row still issues the verb, so the refusal is not vacuous" {
  run "$FLEET" --runner-op runner start sentinel
  assert_success
  run cat "$NOTES_FIXTURE/calls.log"
  assert_output --partial 'start sentinel'
}
