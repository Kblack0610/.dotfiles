#!/usr/bin/env bash
# WorktreeRemove hook, the pair of worktree-create.sh. `wt reap` is the only code that removes a
# worktree, so this asks it: it refuses a dirty or unlanded tree, one a session, pane or process
# is inside, and a submodule worktree git alone cannot remove, and it deletes the branch with
# `-d`. A refusal exits non-zero, the harness reports it, and the tree waits for the nightly
# `wt gc`. wt is found beside this file (the stow link resolves to the checkout), never by PATH.
set -euo pipefail

path=$(jq -r '.worktree_path' <<<"$(cat)")
[ -d "$path" ] || exit 0
wt="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.local/src/tmux/worktree.sh"
[ -x "$wt" ] || {
  echo "worktree-remove: no wt beside $0 ($wt)" >&2
  exit 1
}
"$wt" reap "$path" >&2
