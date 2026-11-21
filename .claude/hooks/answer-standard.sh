#!/usr/bin/env bash
# answer-standard.sh - UserPromptSubmit: put the first two sentences of each comms-standard "Answers in
# chat" rule, and a pointer to the full text, in front of the session, once per session and again
# after each compaction (the summary drops them).
#
# The rules live in the comms-standard skill and nowhere else; this only delivers them. A skill
# loads only when a session opens it, and nothing opens comms-standard before a chat answer.
# Fails open: a missing skill or transcript injects nothing. Dispatched sessions get it too: the
# human talks to them in their tmux windows.

SKILL="$HOME/.claude/skills/comms-standard/SKILL.md"
MARK="How to answer the human in chat, from comms-standard"
# shellcheck source=lib/injected.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/injected.sh" || exit 0

INPUT=$(cat)
[ "$(jq -r '.hook_event_name // empty' <<<"$INPUT" 2>/dev/null)" = UserPromptSubmit ] || exit 0
[ -r "$SKILL" ] || exit 0

# No transcript means no way to tell, so nothing is sent rather than the block on every prompt.
tp=$(jq -r '.transcript_path // empty' <<<"$INPUT")
[ -n "$tp" ] && [ -r "$tp" ] || exit 0
injected_since_compact "$tp" "$MARK" && exit 0

# The first two sentences of each bullet under "**Answers in chat**" (the rule and how to apply
# it), up to the next bold paragraph or heading. The rest of each bullet and the Why bullet stay
# behind the pointer. A sentence ends at ". " before a capital or a quote, so "e.g. a" does not
# cut it.
rules=$(awk '/^\*\*Answers in chat\*\*/ {on = 1; next}
  on && (/^\*\*/ || /^#/) {exit}
  on && /^- / && !/^- Why:/ {
    s = $0; out = ""
    for (n = 0; n < 2; n++) {
      if (!match(s, /[.] ["A-Z]/)) { out = out s; break }
      out = out substr(s, 1, RSTART + 1); s = substr(s, RSTART + 2)
    }
    sub(/ $/, "", out); print out
  }' "$SKILL")
[ -n "$rules" ] || exit 0
jq -nc --arg c "## $MARK
$rules
Full text, with how to apply each: $SKILL" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
