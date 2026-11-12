#!/usr/bin/env bash
# blind.sh - the mechanical steps of the blind-review skill.
#   blind.sh snapshot <repo> <rev>       history-free copy of <repo> at <rev>; prints its path
#   blind.sh audit <agent-id> [live...]  exit 1 if the agent's transcript touched a forbidden path
#   blind.sh clean                       delete this session's snapshots
set -euo pipefail

root="$HOME/.cache/blind-review/${CLAUDE_CODE_SESSION_ID:?CLAUDE_CODE_SESSION_ID is not set}"

die() { echo "blind.sh: $*" >&2; exit 2; }

snapshot() {
  local repo=${1:?repo} rev=${2:?rev} sha dir
  sha=$(git -C "$repo" rev-parse --verify --quiet "$rev^{commit}") || die "no such commit: $rev"
  # A neutral name: a worktree basename can name the very plan the agent must not see.
  dir="$root/src-${sha:0:9}"
  [[ -d $dir ]] && { echo "$dir"; return; }
  mkdir -p "$dir"
  if ! git -C "$repo" archive "$sha" | tar -x -C "$dir"; then
    rm -rf "$dir"; die "archive failed for $sha"
  fi
  echo "$dir"
}

audit() {
  local id=${1:?agent-id} f pat hits live tilde
  shift
  f=$(compgen -G "$HOME/.claude*/projects/*/*/subagents/agent-$id.jsonl" | head -1) || true
  [[ -n $f ]] || die "no transcript for agent $id"
  # Plans, agent state, notes, and anything that reads git history.
  pat='\.claude[^/" ]*/plans|(~|'"$HOME"')/\.agent/|(~|'"$HOME"')/\.notes/|git (log|show|blame|reflog|diff)'
  for live in "$@"; do
    live=$(realpath -m "${live/#\~/$HOME}")
    tilde="~${live#"$HOME"}"
    pat+="|${live//./\\.}|${tilde//./\\.}"
  done
  hits=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | "\(.name) \(.input|tostring)"' "$f" | grep -E "$pat" || true)
  if [[ -n $hits ]]; then
    echo "LEAK in $f: $(wc -l <<<"$hits") calls, first 10:"; head -10 <<<"$hits" | cut -c1-200; return 1
  fi
  echo "clean: $f"
}

case ${1:-} in
  snapshot) shift; snapshot "$@" ;;
  audit) shift; audit "$@" ;;
  clean) rm -rf "$root"; echo "removed $root" ;;
  *) sed -n 2,5p "$0"; exit 2 ;;
esac
