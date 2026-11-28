#!/usr/bin/env bats
# .local/lib/agent-units.sh is the one list of agent batch units that agent-hold, fleet-assess
# CAP_PROBE and worktree.sh read (ar-4869).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  . "$ROOT/.local/lib/agent-units.sh"
}

@test "a pane scope, an agent session scope and an agentctl unit are batch work" {
  agent_batch_unit tmux-spawn-1f2e.scope
  agent_batch_unit agent-dotfiles-3.scope
  agent_batch_unit agentctl@fleet-dispatch.service
}

@test "a desktop app scope, another service and a near miss are not batch work (negative control)" {
  local u
  # `! cmd` never fails a bats test (errexit ignores it), so each miss is an explicit return.
  for u in app-firefox-123.scope fleet-dispatch.service tmux-spawn-1f2e.service agentctl.service; do
    if agent_batch_unit "$u"; then echo "$u read as batch work" >&2; return 1; fi
  done
}

@test "the pane scopes are a subset of the batch units, so every reader sees the same pane globs" {
  local g
  for g in "${AGENT_PANE_SCOPES[@]}"; do
    [[ " ${AGENT_BATCH_UNITS[*]} " == *" $g "* ]] || { echo "pane scope $g is not a batch unit" >&2; return 1; }
  done
}

@test "fleet-assess CAP_PROBE lists the pane scopes from the lib" {
  run bash -c 'set -e; . "$1/.local/lib/agent-units.sh"; eval "$(grep "^CAP_PROBE=" "$1/.local/bin/fleet-assess")"; printf "%s" "$CAP_PROBE"' _ "$ROOT"
  [ "$status" -eq 0 ]
  local g
  for g in "${AGENT_PANE_SCOPES[@]}"; do
    [[ "$output" == *"\"$g\" "* ]] || { echo "CAP_PROBE does not list $g" >&2; return 1; }
  done
}
