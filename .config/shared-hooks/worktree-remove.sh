#!/usr/bin/env bash
# WorktreeRemove hook, the pair of worktree-create.sh. Removes a harness-made worktree without
# --force, so git refuses a dirty tree and the work survives; a failure exits non-zero and the
# harness reports it. The branch is left alone, since a subagent's commits may be all that is left.
set -euo pipefail

path=$(jq -r '.worktree_path' <<<"$(cat)")
[ -d "$path" ] || exit 0
git -C "$path" worktree remove "$path" >&2
