#!/usr/bin/env bats
# fleet-shepherd - the scheduled shepherd's gate. Every collaborator is a stub: the state
# document is written by the test, agentctl-run records its prompt instead of calling a
# model, and agent-notify records its page instead of reaching a phone.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SH="$REPO_ROOT/.local/bin/fleet-shepherd"
  export AGENTCTL_NAME=shepherd-test AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  export FLEET_STATE_FILE="$HOME/state.json" FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  mkdir -p "$FLEET_SHEPHERD_DIR"
  stub fleet-sessions 'echo "$*" >> "$HOME/sessions.calls"'
  stub fleet-assess 'echo "verdict: ${STUB_VERDICT:-CLEAR} load 0.5x"'
  stub agent-hold 'printf "%s" "${STUB_HOLDS:-}"'
  stub agent-notify 'echo "$*" >> "$HOME/pages"'
  # A pass that moves something logs it, as the skill says; STUB_SILENT makes one that does not.
  stub agentctl-run 'while [ $# -gt 0 ]; do [ "$1" = -p ] && printf "%s" "$2" > "$HOME/last-prompt"; shift; done
echo "holder=$FLEET_SHEPHERD_HOLDER" >> "$HOME/run.env"
[ -n "${STUB_SILENT:-}" ] || echo "## pass" >> "$FLEET_SHEPHERD_DIR/log.md"
exit "${STUB_RC:-0}"'
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# doc <sessions-json> [main-json]
doc() { jq -n --argjson s "$1" --argjson m "${2:-[]}" '{schema:1, sessions:$s, main:$m}' > "$FLEET_STATE_FILE"; }

row() { # target bucket nudged escalated [labels-json]
  jq -n --arg t "$1" --arg b "$2" --argjson n "$3" --argjson e "$4" --argjson l "${5:-[]}" \
    '{target:$t, bucket:$b, nudged:$n, escalated:$e, labels:$l, fact:"f-\($t)", reason:"r-\($t)"}'
}

outcome() { cat "$AGENTCTL_STATE_DIR/shepherd-test/last-outcome"; }

@test "due lists unnudged DONE/LANDED/STALLED, unescalated rows for the human, and red main" {
  doc "[$(row a DONE false false), $(row b LANDED true false), $(row c NEEDS false false), $(row d WORKING false false), $(row e STALLED true true)]" \
      '[{"repo":"r1","reason":"ci red","escalated":false},{"repo":"r2","escalated":true}]'
  run "$SH" due
  assert_success
  assert_line 'main red: r1 (ci red)'
  assert_line 'nudge DONE: a f-a'
  assert_line 'escalate LANDED: b r-b'
  assert_line 'escalate NEEDS: c r-c'
  refute_output --partial ' d '
  refute_output --partial ' e '
  refute_output --partial r2
}

@test "a hands-off row is never due, and an all-quiet document exits 1" {
  doc "[$(row a STALLED false false '["hands-off"]'), $(row b WORKING false false)]"
  run "$SH" due
  assert_failure
  assert_output ''
}

@test "a hold on a CLEAR machine and a HOLD machine with no hold are pace decisions" {
  doc "[]"
  STUB_HOLDS=$'unity\t2026\tme\twhy' run "$SH" due
  assert_line 'pace: hold unity while the machine reads CLEAR'
  STUB_VERDICT=HOLD run "$SH" due
  assert_line 'pace: machine reads HOLD with no hold set'
  STUB_VERDICT=HOLD STUB_HOLDS=$'unity\tx' run "$SH" due
  assert_failure
}

@test "run with nothing due calls no model, records NOOP, and refreshes the document" {
  doc "[$(row a WORKING false false)]"
  run "$SH" run
  assert_success
  assert_output --partial 'nothing to move'
  [ ! -e "$HOME/last-prompt" ]
  assert_equal "$(outcome)" NOOP
  assert_equal "$(cat "$HOME/sessions.calls")" --write
  [ ! -e "$HOME/pages" ]
}

@test "a settled fleet pages once, and work coming back re-arms the page" {
  doc "[$(row a NEEDS false true)]"
  "$SH" run
  "$SH" run
  run cat "$HOME/pages"
  assert_output '-p normal -t shepherd fleet settled: 1 need you; rundown in '"$FLEET_SHEPHERD_DIR"'/log.md'
  [ "$(wc -l < "$HOME/pages")" -eq 1 ] || { cat "$HOME/pages"; false; }
  doc "[$(row a WORKING false false)]"
  "$SH" run
  [ ! -e "$FLEET_SHEPHERD_DIR/.settled" ]
}

@test "run with something due starts the observe pass with the due lines, as the runner" {
  doc "[$(row a DONE false false)]"
  run "$SH" run
  assert_success
  run cat "$HOME/last-prompt"
  assert_line '/fleet-overseer shepherd'
  assert_line 'nudge DONE: a f-a'
  assert_equal "$(cat "$HOME/run.env")" holder=runner
  assert_equal "$(outcome)" WORKED
}

@test "a due pass that logs nothing is STALLED, and a failed one is FAILED" {
  doc "[$(row a DONE false false)]"
  STUB_SILENT=1 run "$SH" run
  assert_equal "$(outcome)" STALLED
  STUB_RC=3 run "$SH" run
  assert_failure
  assert_equal "$(outcome)" FAILED
}

@test "a live interactive lease stands the runner down; a stale one or the runner's own does not" {
  doc "[$(row a DONE false false)]"
  "$SH" lease
  run "$SH" run
  assert_output --partial 'standing down'
  [ ! -e "$HOME/last-prompt" ]
  assert_equal "$(outcome)" NOOP
  printf 'interactive %s\n' "$(( $(date +%s) - 31 * 60 ))" > "$FLEET_SHEPHERD_DIR/.lease"
  run "$SH" run
  [ -e "$HOME/last-prompt" ]
  rm "$HOME/last-prompt"
  FLEET_SHEPHERD_HOLDER=runner "$SH" lease
  run "$SH" run
  [ -e "$HOME/last-prompt" ]
}
