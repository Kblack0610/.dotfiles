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
  [[ "$ctx" == *"Full text: $HOME/.claude/skills/comms-standard/SKILL.md"* ]]
  # The Why bullet and the next section stay out.
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
