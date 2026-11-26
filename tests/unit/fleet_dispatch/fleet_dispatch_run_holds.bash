# shellcheck shell=bash
# The setup and fixtures tests/unit/fleet_dispatch_run_holds.bats and fleet_dispatch_run_holds_part2.bats both load, so CI shards can spread the two halves.

load 'fleet_dispatch/common'

# landing_rows <project> <depth>...: one session row of <project> waiting its landing turn per depth, each
# carrying that landing_queue, as fleet-sessions writes them; the deepest is the repo's.
landing_rows() {
  local p="$1"; shift
  fleet_state 0
  jq -c --arg p "$p" --argjson d "$(printf '%s\n' "$@" | jq -cs .)" \
    '.sessions += [$d | to_entries[] | {target: "lab/q:\(.key)", bucket: "WORKING", project: $p, open_job: "queue", landing_queue: .value}]' \
    "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
}

# share_history <capped> <other> -- items started and closed today: <capped> on game (the capped project in
# these tests, DISPATCH_PROJECT_SHARE=game:30) and <other> on app, the starts the project share counts.
share_history() {
  local i n; n=$(agent-queue list --json --state done 2>/dev/null | grep -c . || true)
  for i in $(seq 1 "$1"); do agent-queue add --project game --slug "h-game-$n-$i" "done game $i" >/dev/null; done
  for i in $(seq 1 "$2"); do agent-queue add --project app --slug "h-app-$n-$i" "done app $i" >/dev/null; done
  agent-queue list --json 2>/dev/null | jq -r 'select(.slug | startswith("h-")) | select(.state != "done") | .slug' | while read -r s; do
    agent-queue move "$s" running >/dev/null; agent-queue move "$s" done --status ok >/dev/null
  done
  export DISPATCH_PROJECT_SHARE=game:30
}

# classes.json min_live (ar-3943): a class under its minimum of live sessions has its first item ranked
# ahead inside its bucket (agent-queue marks it `short`), and when that item waits only on run units it
# keeps the free ones like an urgent one, so light work of a class over its minimum cannot starve it.
min_live_classes() {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  jq -n --argjson m "$1" '{on: true, window_days: 7, classes: [
    {name: "rest", share: 10, default: true},
    {name: "heavy-game", share: 10, tags: ["gamework"], min_live: $m}]}' > "$AGENT_QUEUE_CLASSES"
}
