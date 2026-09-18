#!/usr/bin/env bash
# WorktreeCreate hook: put the worktrees Claude Code makes on its own (Agent `isolation: "worktree"`,
# `--worktree`, background sessions) at ~/.worktrees/<repo>-<name>, the same flat layout `wt` uses.
#
# Without this hook the harness nests them at <repo>/.claude/worktrees/<name>, inside the project,
# where they dirty its status and never get reaped. The rule in ~/.claude/CLAUDE.md only reaches
# agents that read it; the harness does not, so the layout has to be enforced here.
#
# Branch semantics match the default: reuse `branch` if it exists, else create it at the caller's
# HEAD (a subagent is expected to see its parent's checkout, not the remote tip).
# Contract: stdout carries only the JSON with hookSpecificOutput.worktreePath; git chatter goes to
# stderr; any non-zero exit aborts the creation with stderr as the message.
set -euo pipefail

input=$(cat)
name=$(jq -r '.name' <<<"$input")
branch=$(jq -r '.branch // empty' <<<"$input")
detach=$(jq -r '.detach // false' <<<"$input")
cwd=$(jq -r '.cwd' <<<"$input")

# The common dir is the main checkout's .git even when cwd is itself a linked worktree, so a
# subagent spawned from ~/.worktrees/platform-agent-7 still resolves to "platform".
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)
repo=$(basename "$(dirname "$common")")
repo=${repo#.}
path="$HOME/.worktrees/${repo}-${name}"

emit() {
  jq -n --arg p "$path" '{hookSpecificOutput: {hookEventName: "WorktreeCreate", worktreePath: $p}}'
}

# Resuming a session re-requests the same worktree; hand back the existing one.
if git -C "$cwd" worktree list --porcelain | grep -qxF "worktree $path"; then
  emit
  exit 0
fi

mkdir -p "$HOME/.worktrees"
if [ "$detach" = "true" ] || [ -z "$branch" ]; then
  git -C "$cwd" worktree add --detach "$path" HEAD >&2
elif git -C "$cwd" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$cwd" worktree add "$path" "$branch" >&2
else
  git -C "$cwd" worktree add -b "$branch" "$path" HEAD >&2
fi

emit
