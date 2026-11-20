#!/usr/bin/env bash
# answer-standard.sh - UserPromptSubmit: put comms-standard's "Answers in chat" rules in front
# of the session, once per session and again after each compaction (the summary drops them).
#
# The rules live in the comms-standard skill and nowhere else; this only delivers them. A skill
# loads only when a session opens it, and nothing opens comms-standard before a chat answer, so
# for a day after #2721 restored the plain-words rule no session had it (2026-11-19: answers were
# bare ids and labels again). Same reason as plan-standard.sh: a rule that must be recalled at a
# trigger does not hold. Fails open: a missing skill or transcript injects nothing.

SKILL="$HOME/.claude/skills/comms-standard/SKILL.md"
MARK="How to answer the human in chat, from comms-standard"

INPUT=$(cat)
[ "$(jq -r '.hook_event_name // empty' <<<"$INPUT" 2>/dev/null)" = UserPromptSubmit ] || exit 0
[ -r "$SKILL" ] || exit 0

# Already delivered since the last compaction: the newest of the two in the transcript wins.
# Only a hook-context entry counts, so a session that types the heading (editing this file)
# still gets the rules.
tp=$(jq -r '.transcript_path // empty' <<<"$INPUT")
if [ -n "$tp" ] && [ -r "$tp" ]; then
  tac "$tp" | awk -v m="$MARK" 'index($0, "\"compact_boundary\"") {exit}
    index($0, "\"hook_additional_context\"") && index($0, m) {f = 1; exit}
    END {exit !f}' && exit 0
fi

# The "**Answers in chat**" paragraph and its bullets, up to the blank line; the Why bullet is
# for editing the rule, not for following it.
rules=$(awk '/^\*\*Answers in chat\*\*/ {on = 1} on && /^$/ {exit} on && !/^- Why:/' "$SKILL")
[ -n "$rules" ] || exit 0
jq -nc --arg c "## $MARK
$rules
Full text: $SKILL" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
