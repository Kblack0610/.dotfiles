#!/usr/bin/env bash
# blind.sh - the mechanical steps of the blind-review skill.
#   blind.sh snapshot <repo> <rev>       history-free copy of <repo> at <rev>; prints its path
#   blind.sh audit <agent-id> [live...]  exit 1 if the agent's transcript touched a forbidden path
#   blind.sh clean                       delete this session's snapshots
# Exit 2 is a usage or tool error: the audit never reads an unchecked transcript as clean.
set -euo pipefail

root="$HOME/.cache/blind-review/${CLAUDE_CODE_SESSION_ID:?CLAUDE_CODE_SESSION_ID is not set}"

die() { echo "blind.sh: $*" >&2; exit 2; }

ere_escape() { sed 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$1"; }

snapshot() {
  local repo=${1:?repo} rev=${2:?rev} sha dir tmp
  sha=$(git -C "$repo" rev-parse --verify --quiet "$rev^{commit}") || die "no such commit: $rev"
  # A neutral name: a worktree basename can name the very plan the agent must not see.
  dir="$root/src-${sha:0:9}"
  [[ -d $dir ]] && { echo "$dir"; return; }
  mkdir -p "$root"
  tmp=$(mktemp -d "$root/.partial-XXXXXX")
  if ! git -C "$repo" archive "$sha" | tar -x -C "$tmp"; then
    rm -rf "$tmp"; die "archive failed for $sha"
  fi
  mv "$tmp" "$dir"
  echo "$dir"
}

audit() {
  local id=${1:?agent-id} f pat calls hits rc live tilde home end
  shift
  f=$(compgen -G "$HOME/.claude*/projects/*/*/subagents/agent-$id.jsonl" | head -1) || true
  [[ -n $f ]] || die "no transcript for agent $id"
  end='([/"'"'"' ]|$)'
  home="(~|\\\$HOME|$(ere_escape "$HOME"))"
  # Plans, agent state, notes, and any git verb that reads history, after any global options.
  pat='\.claude[^/" ]*/plans'"|$home/\\.(agent|notes)$end"
  pat+='|\bgit( +-[^ ]+( +[^- ][^ ]*)?)* +(log|show|blame|reflog|diff|rev-list|shortlog|whatchanged|cat-file)\b'
  for live in "$@"; do
    live=$(realpath -m "${live/#\~/$HOME}")
    tilde="~${live#"$HOME"}"
    pat+="|($(ere_escape "$live")|$(ere_escape "$tilde"))$end"
  done
  calls=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | "\(.name) \(.input|tostring)"' "$f") \
    || die "could not parse $f"
  rc=0; hits=$(grep -E -- "$pat" <<<"$calls") || rc=$?
  ((rc <= 1)) || die "bad audit pattern: $pat"
  if ((rc == 0)); then
    echo "LEAK in $f: $(wc -l <<<"$hits") calls, first 10:"; head -10 <<<"$hits" | cut -c1-200; return 1
  fi
  echo "clean: $f"
}

case ${1:-} in
  snapshot) shift; snapshot "$@" ;;
  audit) shift; audit "$@" ;;
  clean) rm -rf "$root"; echo "removed $root" ;;
  *) sed -n 2,6p "$0"; exit 2 ;;
esac
