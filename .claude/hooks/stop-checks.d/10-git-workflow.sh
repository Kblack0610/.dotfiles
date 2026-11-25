#!/bin/bash
# Stop check: git workflow completeness.
# Exit codes: 0=pass, 1=warn, 2=block.

set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || exit 0  # not a git repo

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0
[ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ] && exit 0

# merge_proof_branch: the one reader of a repo's default branch (fleet-states.md Owners).
# shellcheck source=../../../.local/lib/agent-merge-proof.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../.local/lib/agent-merge-proof.sh" || exit 0
# A repo with no remote default branch is measured against its local main, as before.
MAIN_BRANCH="$(merge_proof_branch "$(git rev-parse --show-toplevel)")" || MAIN_BRANCH=main
[ "$BRANCH" = "$MAIN_BRANCH" ] && exit 0

FAILED=0
WARN=0

# A turn that ends while this session's own background run (its gate, a test run) is still
# going is not the end of the work: the run's notice wakes the session and that Stop checks
# again. Claude Code points a background run's stdout at
# <tmp>/claude-<uid>/<cwd>/<session>/tasks/<id>.output, so a live run is a process holding
# that file open. 2026-10-29..11-05: 205 of the 207 unpushed-commit blocks came mid-run.
inflight() {
  [ -n "${STOP_SESSION_ID:-}" ] || return 1
  [ -n "$(find /proc/[0-9]*/fd -lname "*/${STOP_SESSION_ID}/tasks/*.output" -print -quit 2>/dev/null)" ]
}

unpushed() {
  if inflight; then
    echo "$1; a background run of this session is still going, so the next Stop checks again" >&2
    WARN=1
  else
    echo "FAILED: $1" >&2
    FAILED=1
  fi
}

# A queue item's session (fleet-dispatch sets AGENT_QUEUE_ITEM) pushes what each turn committed and
# records `branch: <branch>@<sha>` on its item, so a host lost mid-run loses at most the turn in
# progress: reap re-queues the item from that branch (fleet-dispatch settle_item). A session with no
# item is only asked to push, since a hand session may sit in a repo that is not ours.
ITEM=${AGENT_QUEUE_ITEM:-}
command -v agent-queue >/dev/null 2>&1 || ITEM=''

# lost_fence -- block a session its item names in `lost:`: reap gave its run up when its host stopped
# answering, and another node carries the item now. A peer clone that comes back holds the store from
# before, so lost_fence sync first takes the store's latest (bounded: offline it reads the clone).
lost_fence() {
  local lost
  [ -n "$ITEM" ] && [ -n "${STOP_SESSION_ID:-}" ] || return 0
  [ "${1:-}" != sync ] || timeout 30 store-sync --now >/dev/null 2>&1
  lost=$(agent-queue show "$ITEM" --json 2>/dev/null | jq -r '.lost // ""' 2>/dev/null)
  [[ " $lost " == *" $STOP_SESSION_ID "* ]] || return 0
  echo "FAILED: queue item $ITEM was re-queued to another node while ${lost%% *} did not answer, and this session's run was given up for lost: do not push, open a PR or land; wind down without auto" >&2
  exit 2
}

# push_item <remote> <remote branch> <what> -- push HEAD there for the item, and record it on the item.
# A failed push (offline, a moved remote branch) is unpushed work, blocked as before.
push_item() {
  local out sha was sv
  lost_fence sync
  if ! out=$(timeout 60 git push -q ${4:+-u} "$1" "HEAD:refs/heads/$2" 2>&1); then
    unpushed "$3, and pushing it to $1/$2 failed: $(tail -n 1 <<<"$out")"
    return
  fi
  echo "Pushed $3 to $1/$2 for queue item $ITEM" >&2
  [ "$1" = origin ] || return 0
  # Read again: a reap that gave this run up during the push gets no record from it. A run that
  # started from `salvage:` carries it forward, so the next start begins from this push, not that one.
  lost_fence
  sha=$(git rev-parse HEAD)
  IFS=$'\t' read -r was sv < <(agent-queue show "$ITEM" --json 2>/dev/null | jq -r '[.branch // "-", .salvage // ""] | @tsv' 2>/dev/null)
  [ "${was:-}" = "$2@$sha" ] ||
    agent-queue set "$ITEM" "branch=$2@$sha" ${sv:+"salvage=$2@$sha"} >/dev/null 2>&1 ||
    echo "Could not record branch $2@$sha on queue item $ITEM" >&2
}

lost_fence

# Only a branch that tracks its own name pushes to its upstream: one cut from origin/main tracks main
# (`git worktree add -b <branch> <dir> origin/main`), and an item's push goes to origin/<branch>, never there.
UPSTREAM=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null)
if [ -z "$UPSTREAM" ]; then
  AHEAD=$(git rev-list "$MAIN_BRANCH"..HEAD --count 2>/dev/null)
  what="Branch '$BRANCH' has $AHEAD unpushed commit(s) with no remote tracking branch"
else
  AHEAD=$(git rev-list "$UPSTREAM"..HEAD --count 2>/dev/null)
  what="Branch '$BRANCH' has $AHEAD unpushed commit(s)"
fi
if [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then
  if [ -z "$ITEM" ] || inflight; then
    unpushed "$what"
  elif [ -n "$UPSTREAM" ] && [ "${UPSTREAM#*/}" = "$BRANCH" ]; then
    push_item "${UPSTREAM%%/*}" "$BRANCH" "$what"
  elif git remote get-url origin >/dev/null 2>&1; then
    push_item origin "$BRANCH" "$what" -u
  else
    unpushed "$what"
  fi
fi

# gate: hook-stop-git-workflow
[ $FAILED -eq 1 ] && exit 2
[ $WARN -eq 1 ] && exit 1
exit 0
