# lane-runs.jq -- the one fold of model-lane's run log (~/.agent/model-lane/runs.jsonl) to one row per run id.
# ~/.agent merges *.jsonl by union, so a row model-lane rewrote can sit beside its old copy in either order:
# the newest `rated` stamp wins, then a rated row over an unrated one, then the later line. A run keeps the
# place of its first line, and a row with no id is a run of its own. model-lane's read_log folds the same way.
# fleet-bench (models) and fleet-dispatch (trainee-rollup) read the log through it. A def only: callers
# prepend the file's text to their program, as kept.jq's do.
def lane_runs: to_entries | group_by(.value.id // .key)
  | map({at: (map(.key) | min), row: (max_by([.value.rated // "", .value.outcome != null, .key]) | .value)})
  | sort_by(.at) | map(.row);
