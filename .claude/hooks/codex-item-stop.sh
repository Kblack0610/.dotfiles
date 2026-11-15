#!/bin/bash
# Codex Stop hook: a fleet Codex run does not end its turn with its queue item still running and no
# PR on it, since reap would then file it failed ("ended before it closed the item", ar-1124). The
# first such Stop is blocked with how to close the item, which gives Codex one more turn. A Stop that
# was already blocked once (stop_hook_active) goes through, and reap settles what is left.
# It acts only on the Codex thread its item records (agent-codex claims it): a Claude session's
# AGENT_QUEUE_ITEM is in the env of any codex it runs, and that item is not this run's to close.
set -uo pipefail

item="${AGENT_QUEUE_ITEM:-}"
[ -n "$item" ] || exit 0
in=$(cat)
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null)" = false ] || exit 0
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
[ -n "$sid" ] || exit 0
show=$("${AGENT_QUEUE_BIN:-agent-queue}" show "$item" --json 2>/dev/null) || exit 0
jq -e --arg s "$sid" '.state == "running" and (.pr // "") == ""
  and ((.sessions // "") | split(" ") | index($s) != null)' <<<"$show" >/dev/null || exit 0

jq -n --arg i "$item" '{decision: "block", reason: ("Queue item \($i) is still running with no PR on it, so stopping now files it failed. Close it first, then stop:"
  + " landed: agent-land <N> --item \($i)."
  + " A PR that is not merging: agent-queue set \($i) pr=<owner>/<repo>#<N>; agent-queue move \($i) review."
  + " Blocked on the human: agent-ask post with your options and --recommend, then agent-queue requeue \($i) --ask <id> (the answer starts it again)."
  + " Done another way your brief names (proof, a doc and an ask): close it that way."
  + " Not doable: agent-queue set \($i) note=<why>; agent-queue move \($i) done --status failed.")}'
