#!/usr/bin/env bats
# answer-standard.sh: delivers comms-standard's "Answers in chat" rules. These run against the
# real skill, so a heading rename or a reworded section that the hook can no longer find goes red.

load '../vendor/bats-support/load'
load '../vendor/bats-assert/load'

ROOT="$BATS_TEST_DIRNAME/../.."
HOOK="$ROOT/.claude/hooks/answer-standard.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/skills/comms-standard"
  ln -s "$(cd "$ROOT" && pwd)/.claude/skills/messaging/comms-standard/SKILL.md" "$HOME/.claude/skills/comms-standard/SKILL.md"
  TP="$BATS_TEST_TMPDIR/t.jsonl"
  : > "$TP"
}

prompt() { # prompt [event]
  jq -nc --arg e "${1:-UserPromptSubmit}" --arg tp "$TP" '{hook_event_name: $e, transcript_path: $tp, prompt: "hi there you"}' | bash "$HOOK"
}

# Record what the hook printed the way Claude Code does: an attachment of type hook_additional_context.
record() {
  jq -c '{type: "attachment", attachment: {type: "hook_additional_context", hookEvent: "UserPromptSubmit",
    content: [.hookSpecificOutput.additionalContext]}}' <<<"$output" >> "$TP"
}

@test "a prompt gets the chat-answer rules from the skill" {
  run prompt
  assert_success
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ "$ctx" == *"Explain in plain words."* ]]
  [[ "$ctx" == *"End with the one lever"* ]]
  # The last rule bullet arrives, so a cut-off that drops the tail goes red.
  [[ "$ctx" == *"gets the \`catch-up\` shape"* ]]
  [[ "$ctx" == *"Full text, with how to apply each: $HOME/.claude/skills/comms-standard/SKILL.md"* ]]
  # Each bullet's first two sentences: the rule and how to apply it. The gloss rule is why this
  # hook exists (2026-11-19: answers were bare ids and labels), so it must arrive.
  [[ "$ctx" == *"gets a few-word gloss the first time it appears"* ]]
  [[ "$ctx" == *"rather than more than about 5 tool calls with no text."* ]]
  # The third sentence on, the intro, the Why bullet and the next section stay out.
  [[ "$ctx" != *"When the finding depends on how a piece works"* ]]
  [[ "$ctx" != *"The reader built the system"* ]]
  [[ "$ctx" != *"- Why:"* ]]
  [[ "$ctx" != *"## Steps"* ]]
}

@test "the rules are injected once per session" {
  run prompt; record
  run prompt
  assert_success
  assert_output ''
}

@test "after a compaction they are injected again" {
  run prompt; record
  echo '{"type":"system","subtype":"compact_boundary"}' >> "$TP"
  run prompt
  assert_success
  [[ "$output" == *"Explain in plain words."* ]]
}

@test "the heading typed in the conversation is not a delivery" {
  printf '%s\n' '{"type":"assistant","message":"## How to answer the human in chat, from comms-standard"}' >> "$TP"
  run prompt
  assert_success
  [[ "$output" == *"Explain in plain words."* ]]
}

@test "a blank line between the skill's bullets does not cut the rules short" {
  rm "$HOME/.claude/skills/comms-standard/SKILL.md"
  printf '**Answers in chat** intro.\n- first rule\n\n- last rule\n- Why: history\n\n## Steps\n' > "$HOME/.claude/skills/comms-standard/SKILL.md"
  run prompt
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ "$ctx" == *"- last rule"* ]]
  [[ "$ctx" != *"history"* ]]
  [[ "$ctx" != *"Steps"* ]]
}

@test "an abbreviation does not end a sentence, and a third sentence is cut" {
  rm "$HOME/.claude/skills/comms-standard/SKILL.md"
  printf '**Answers in chat** intro.\n- Name the lever, e.g. a flag, and why. Then stop. "Third" one.\n\n## Steps\n' > "$HOME/.claude/skills/comms-standard/SKILL.md"
  run prompt
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ "$ctx" == *"- Name the lever, e.g. a flag, and why. Then stop."$'\n'* ]]
  [[ "$ctx" != *"Third"* ]]
}

@test "no transcript sends nothing rather than the block on every prompt" {
  run bash -c "jq -nc '{hook_event_name: \"UserPromptSubmit\"}' | bash '$HOOK'"
  assert_success
  assert_output ''
}

@test "other events get nothing" {
  run prompt PreToolUse
  assert_success
  assert_output ''
}

@test "a missing skill fails open" {
  rm "$HOME/.claude/skills/comms-standard/SKILL.md"
  run prompt
  assert_success
  assert_output ''
}

@test "a skill without the section injects nothing" {
  rm "$HOME/.claude/skills/comms-standard/SKILL.md"
  printf '# x\n\nNo such section.\n' > "$HOME/.claude/skills/comms-standard/SKILL.md"
  run prompt
  assert_success
  assert_output ''
}
