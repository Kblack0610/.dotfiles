# agent-units.sh - which systemd user units are agent batch work: one list for agent-hold (unit_of,
# lower), fleet-assess CAP_PROBE and worktree.sh wt_closed_pane_scopes. A pane scope is a tmux
# pane's (tmux-spawn-*) or one `claude-acct scope` moved an agent session into (agent-*); an
# agentctl runner unit is batch work too, though no pane scope.
# shellcheck disable=SC2034  # read by the scripts that source this
AGENT_PANE_SCOPES=('tmux-spawn-*.scope' 'agent-*.scope')
AGENT_BATCH_UNITS=("${AGENT_PANE_SCOPES[@]}" 'agentctl@*.service')

# agent_batch_unit <unit> - true when <unit> matches an AGENT_BATCH_UNITS glob.
agent_batch_unit() {
  local g
  for g in "${AGENT_BATCH_UNITS[@]}"; do
    # shellcheck disable=SC2053  # the right side is a glob on purpose
    [[ $1 == $g ]] && return 0
  done
  return 1
}
