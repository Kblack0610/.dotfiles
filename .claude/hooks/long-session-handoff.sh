#!/usr/bin/env bash
# long-session-handoff.sh - PostToolUse (every tool): a queue item's long session hands its item to a fresh one.
#
# Lever 2 of plan lets-do-a-thoruoghou-abundant-teapot (P4, ar-2777). Every response re-reads the whole
# context, so a session past 150 responses pays for all of it on each further call, and one that compacted
# writes its cache again from the summary. Burn, 7 days to 2026-11-22: the unity-core-playground sessions at
# 150 or more main-thread responses were 32 of 392 and held 839M of its 2,719M context. A fresh session
# starts near 40k with the handoff note.
#
# Fires in the main thread (no agent_id: a subagent's call is not the session's) of a dispatched session
# ($AGENT_QUEUE_ITEM, its item running and naming this session) in a checkout of a pilot repo
# (AGENT_HANDOFF_REPOS, default unity-core-playground), once the transcript holds AGENT_HANDOFF_TURNS (150)
# main-thread responses or a compaction, while the item has handed off fewer than AGENT_HANDOFF_MAX (2)
# times. It tells the session once (a marker per session) how to hand off at its next clean point through
# `agent-queue handoff`; it never stops the session itself. A hand session has no $AGENT_QUEUE_ITEM and is
# never told: the human's own work is not cut (repo CLAUDE.md, "Hard limits on budgets").
#
# Counting the transcript costs up to half a second on a 100 MB one, so it runs every AGENT_HANDOFF_EVERY
# (10) calls, counted per session; no event says "the session passed N responses". Always exits 0: the
# message is PostToolUse's hookSpecificOutput.additionalContext on stdout.

set -uo pipefail

item="${AGENT_QUEUE_ITEM:-}"
[ -n "$item" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat 2>/dev/null) || exit 0
# A unit separator, not a tab: tab is IFS whitespace, so read would collapse the empty agent_id field.
IFS=$'\x1f' read -r sid transcript agent cwd < <(jq -r '[.session_id // "", .transcript_path // "", .agent_id // "", .cwd // ""] | map(tostring) | join("\u001f")' <<<"$payload" 2>/dev/null) || exit 0
[ -z "$agent" ] || exit 0
case "$sid" in '' | */* | . | ..) exit 0 ;; esac
[ -f "$transcript" ] || exit 0

state="${AGENT_HANDOFF_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/long-session-handoff}"
mkdir -p "$state" 2>/dev/null || exit 0
mark="$state/$sid"
# Touched on each call, so the week-old prune below never takes the marker of a session still running.
[ ! -e "$mark.told" ] || { touch "$mark.told"; exit 0; }

every="${AGENT_HANDOFF_EVERY:-10}"; [[ "$every" =~ ^[1-9][0-9]*$ ]] || every=10
n=$(cat "$mark.calls" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
n=$((n + 1))
echo "$n" >"$mark.calls"
[ $((n % every)) -eq 0 ] || exit 0

# The repo, not the project: a pilot repo's games resolve to projects of their own, and every worktree
# of it shares one common dir.
common=$(git -C "${cwd:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { : >"$mark.told"; exit 0; }
repo=$(basename "$(dirname "$common")")
case " ${AGENT_HANDOFF_REPOS:-unity-core-playground} " in *" $repo "*) ;; *) : >"$mark.told"; exit 0 ;; esac

turns_max="${AGENT_HANDOFF_TURNS:-150}"
# One response is one message id with usage (burn counts it so, agent-usage-burn.py scan); a compaction
# is a system line whose subtype names it.
read -r turns compactions < <(jq -nrR 'reduce (inputs | fromjson? | select(.isSidechain != true)) as $d ({ids: {}, c: 0};
    if $d.type == "assistant" and $d.message.usage != null and $d.message.model != "<synthetic>" and ($d.message.id // "") != ""
    then .ids[$d.message.id] = 1
    elif $d.type == "system" and (($d.subtype // "") | tostring | test("compact")) then .c += 1
    else . end) | "\(.ids | length) \(.c)"' "$transcript" 2>/dev/null) || exit 0
[[ "$turns" =~ ^[0-9]+$ && "$compactions" =~ ^[0-9]+$ ]] || exit 0
[ "$turns" -ge "$turns_max" ] || [ "$compactions" -ge 1 ] || exit 0

show=$("${AGENT_QUEUE_BIN:-agent-queue}" show "$item" --json 2>/dev/null) || exit 0
max="${AGENT_HANDOFF_MAX:-2}"; [[ "$max" =~ ^[0-9]+$ ]] || max=2
jq -e --arg s "$sid" --argjson max "$max" '.state == "running"
  and ((.sessions // "") | split(" ") | index($s) != null)
  and (((.handoffs // "0") | tonumber? // 0) < $max)' <<<"$show" >/dev/null || { : >"$mark.told"; exit 0; }
: >"$mark.told"
# Markers of sessions a week gone go with the next one written.
find "$state" -type f -mtime +7 -delete 2>/dev/null

why="$turns responses"
[ "$compactions" -eq 0 ] || why="$why and $compactions compaction$([ "$compactions" -eq 1 ] || echo s)"
msg="Long-session handoff ($repo pilot): this session has run $why. Every further response re-reads that context; a fresh session starts near 40k with your note. Hand item $item off at your next clean point unless it is a few steps from landing (then finish here): never while a background command of yours runs (a gate or agent-land wait dies with this window, so let it finish first). To hand off: (1) commit and push your branch; (2) add a ## Handoff section to your plan file: what is done with its proof, what is next, and what you learned that the code does not show; (3) agent-queue handoff $item --note <that plan file>; (4) /wind-down auto (the handed-off checkout reads nothing to land). If the handoff refuses, fix what it names, or carry on here when it says to finish."
jq -nc --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
