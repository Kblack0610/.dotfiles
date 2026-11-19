#!/usr/bin/env bash
# pr-overlap.sh - PostToolUse on Bash: once `gh pr create` has opened a GitHub PR, name every other
# open PR of that repo that changes one of the same files, so the session sees the overlap while both
# are still open instead of as a merge conflict after both are done. Worktrees keep sessions apart,
# and dispatch holds one session per area (fleet-dispatch queue_areas), but a hand session or a change
# that crosses areas can still edit the same file as a peer.
#
# WARNS, does not block: the PR is already open. The names go back to the session as additional
# context, and it decides whether one is the same work (fleet-comms: a peer's work that duplicates
# or breaks yours). Silent when the command opened no github.com PR, gh cannot read the repo, or
# nothing overlaps. A Forgejo PR opens through its API (forgejo-ops), not `gh pr create`, so it is
# not seen here.
#
# One `gh pr list` call, bounded at 15 s: the new PR is among the 100 newest open ones it reads, and
# gh returns the first 100 files of each. At most 5 PRs are named, three files each.

set -uo pipefail

payload=$(cat)
# Cheap exit for the common case: every Bash call in every session runs this.
[[ $payload == *"gh pr create"* ]] || exit 0

# The PR the command opened: `gh pr create` in the command itself, and the URL it printed last.
url=$(jq -r 'select(.tool_input.command // "" | test("(^|[;&|(])\\s*gh pr create")) | .tool_response.stdout // empty' <<<"$payload" 2>/dev/null |
  grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | tail -n 1)
[[ -n $url ]] || exit 0
repo=${url#https://github.com/}
repo=${repo%/pull/*}
n=${url##*/}

open=$(timeout 15 gh pr list -R "$repo" --state open --limit 100 --json number,title,files 2>/dev/null) || exit 0

out=$(jq -r --argjson n "$n" '
  [.[] | select(.number == $n) | .files[].path] as $mine
  | [.[] | select(.number != $n)
    | {number, title, both: ([.files[].path] | map(select(. as $p | $mine | index($p))))}
    | select(.both | length > 0)]
  | .[:5][]
  | "  #\(.number) \(.title): \(.both[:3] | join(", "))\(if (.both | length) > 3 then " and \(.both | length - 3) more" else "" end)"' \
  <<<"$open" 2>/dev/null) || exit 0
[[ -n $out ]] || exit 0

jq -cn --arg c "pr-overlap: #$n changes files that other open PRs in $repo also change. If one is the same work, tell its session (fleet-comms); if not, expect to merge origin after it lands:
$out" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
