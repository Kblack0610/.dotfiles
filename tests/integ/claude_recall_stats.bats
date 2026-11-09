#!/usr/bin/env bats
# claude-recall stats: counts typed slash commands, Skill calls, subagent spawns, repeated
# prompts and intents from a fixture transcript tree. CLAUDE_TRANSCRIPTS points the counter
# at the fixture and CLAUDE_RECALL_INTENTS at a two-row intents.tsv, so no real transcript
# or ~/.config file is read.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  RECALL="$REPO_ROOT/.local/bin/claude-recall"
  T="$SANDBOX/projects"
  P="$T/-home-u-proj"
  mkdir -p "$P/s1/subagents"
  export CLAUDE_TRANSCRIPTS="$T" CLAUDE_RECALL_INTENTS="$SANDBOX/intents.tsv" TZ=UTC
  printf 'land\tfinal-pass\tland it | merge it\nperf\t-\tfps\n' > "$CLAUDE_RECALL_INTENTS"

  local ts='"timestamp":"2026-10-20T10:00:00Z"' cli='"entrypoint":"cli"'
  local c1='"cwd":"/home/u/proj-agent-3"' c4='"cwd":"/home/u/proj"'
  # s1: an interactive session. It types /one-shot, runs the skill, spawns Explore, asks
  # "can you land it now" once, then four user records that are not typed requests: pasted
  # output, a harness continuation, a tool result and an isMeta skill body.
  cat > "$P/s1.jsonl" <<EOF
{"type":"user","turnOrigin":"human",$cli,$c1,$ts,"message":{"role":"user","content":"<command-name>/one-shot</command-name>"}}
{"type":"assistant",$cli,$c1,$ts,"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"one-shot"}}]}}
{"type":"assistant",$cli,$c1,$ts,"message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"Explore"}}]}}
{"type":"user","turnOrigin":"human",$cli,$c1,$ts,"message":{"role":"user","content":"can you land it now"}}
{"type":"user","turnOrigin":"human",$cli,$c1,$ts,"message":{"role":"user","content":"| can you land it\nmore pasted output"}}
{"type":"user","turnOrigin":"human",$cli,$c1,$ts,"message":{"role":"user","content":"This session is being continued, can you land it"}}
{"type":"user",$cli,$c1,$ts,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"can you land it"}]}}
{"type":"user","isMeta":true,$cli,$c1,$ts,"message":{"role":"user","content":"can you land it please"}}
EOF
  # s1's subagent: its Skill call counts toward s1 (so s1 is covered for the land intent),
  # and its dispatch prompt is not a typed prompt.
  cat > "$P/s1/subagents/agent-a.jsonl" <<EOF
{"type":"user",$cli,$c1,$ts,"message":{"role":"user","content":"can you land it"}}
{"type":"assistant",$cli,$c1,$ts,"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"final-pass"}}]}}
EOF
  # s2: headless (sdk-cli, no turnOrigin): its /one-shot and Skill call are auto.
  cat > "$P/s2.jsonl" <<EOF
{"type":"user","entrypoint":"sdk-cli","cwd":"/home/u/other",$ts,"message":{"role":"user","content":"<command-name>/one-shot</command-name>"}}
{"type":"assistant","entrypoint":"sdk-cli","cwd":"/home/u/other",$ts,"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"one-shot"}}]}}
EOF
  # s3: a /loop firing /fleet-lead three times is one session and three calls, all auto. One
  # record opens with the command-message tag, as some Claude Code versions write it.
  echo "{\"type\":\"user\",\"turnOrigin\":\"scheduled\",$cli,$c4,$ts,\"message\":{\"role\":\"user\",\"content\":\"<command-message>fleet-lead</command-message>\\n<command-name>/fleet-lead</command-name>\"}}" > "$P/s3.jsonl"
  for _ in 1 2; do
    echo "{\"type\":\"user\",\"turnOrigin\":\"scheduled\",$cli,$c4,$ts,\"message\":{\"role\":\"user\",\"content\":\"<command-name>/fleet-lead</command-name>\"}}" >> "$P/s3.jsonl"
  done
  # s4: the same ask with a filler and a transposition typo, a one-off ask, and no skill run.
  cat > "$P/s4.jsonl" <<EOF
{"type":"user","turnOrigin":"human",$cli,$c4,$ts,"message":{"role":"user","content":"ok can you lnad it"}}
{"type":"user","turnOrigin":"human",$cli,$c4,$ts,"message":{"role":"user","content":"why is the build so slow today"}}
{"type":"user",$cli,$c4,$ts,"message":{"role":"user","content":"This session is being continued. The fixture typed <command-name>/quoted</command-name> once."}}
EOF
}

stats() { "$RECALL" stats --since 2026-10-01 --json "$@"; }
row() { jq -c --arg k "$1" --arg key "$2" '.rows[] | select(.kind==$k and .key==$key)'; }

@test "slash: a /loop is one session; headless counts as auto; a tag quoted in a summary is not a command" {
  out="$(stats --kind slash)"
  run row slash quoted <<<"$out"
  assert_output ""
  run row slash fleet-lead <<<"$out"
  assert_output --partial '"calls":3,"sessions":1,"interactive_sessions":0,"auto_sessions":1'
  run row slash one-shot <<<"$out"
  assert_output --partial '"calls":2,"sessions":2,"interactive_sessions":1,"auto_sessions":1'
}

@test "skill and agent: a subagent's Skill call counts toward its parent session" {
  out="$(stats --kind skill,agent)"
  run row skill final-pass <<<"$out"
  assert_output --partial '"sessions":1,"interactive_sessions":1'
  run row skill one-shot <<<"$out"
  assert_output --partial '"sessions":2,"interactive_sessions":1,"auto_sessions":1'
  run row agent Explore <<<"$out"
  assert_output --partial '"calls":1,"sessions":1'
}

@test "prompt: fillers and a typo cluster together; pasted, harness, tool, meta and subagent text and one-offs do not count" {
  run jq -c '.rows' <<<"$(stats --kind prompt --min 2)"
  assert_output --partial '"key":"can land it"'
  assert_output --partial '"calls":2,"sessions":2'
  [ "$(jq 'length' <<<"$output")" -eq 1 ]
}

@test "intent: matched in both sessions, the covering skill ran in one (inside a subagent)" {
  out="$(stats --kind intent)"
  run row intent land <<<"$out"
  assert_output --partial '"calls":2,"sessions":2'
  assert_output --partial '"covered_sessions":1,"covered_by":["final-pass"]'
  run row intent perf <<<"$out"
  assert_output ''
}

@test "origin filter and project buckets: a numbered worktree counts toward its repo" {
  run jq -r '.rows[].key' <<<"$(stats --kind slash --origin interactive)"
  assert_output 'one-shot'
  run bash -c "jq -r '.rows[] | .bucket + \" \" + .key' | sort" <<<"$(stats --kind slash --by project)"
  assert_output "$(printf 'other one-shot\nproj fleet-lead\nproj one-shot')"
}

@test "--since takes what tool-output takes: a bare date is a local day, an ISO time is exact" {
  # fixture records are at 10:00:00Z on 2026-10-20; UTC-12 puts local midnight of that date at 12:00Z
  run env TZ=Etc/GMT+12 "$RECALL" stats --since 2026-10-20
  assert_output 'nothing counted since 2026-10-20T12:00:00'
  run "$RECALL" stats --since 2026-10-20T10:00:01Z
  assert_output 'nothing counted since 2026-10-20T10:00:01'
  run jq -r '.rows | length > 0' <<<"$("$RECALL" stats --since 2026-10-20T09:59:59Z --json)"
  assert_output true
}

@test "bypass: a call matching a skill's metadata.replaces counts per skill, covered when the skill ran, not when a hook denied it" {
  export CLAUDE_SKILLS="$SANDBOX/skills" XDG_CACHE_HOME="$SANDBOX/cache"
  mkdir -p "$CLAUDE_SKILLS/one-shot" "$CLAUDE_SKILLS/other"
  printf '%s\n' '---' 'name: one-shot' 'description: x' 'metadata:' '  replaces:' "    - match: 'gh\\s+run\\s+watch'" '      use: gh-run-wait' '---' > "$CLAUDE_SKILLS/one-shot/SKILL.md"
  printf '%s\n' '---' 'name: other' 'description: x' '---' > "$CLAUDE_SKILLS/other/SKILL.md"
  local ts='"timestamp":"2026-10-20T10:00:00Z"' cli='"entrypoint":"cli"' c='"cwd":"/home/u/proj"'
  # s1 ran one-shot, so its watch is covered; s5 typed the form without it; s6 only quoted it.
  echo "{\"type\":\"assistant\",$cli,$c,$ts,\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"gh run watch 1\"}}]}}" >> "$P/s1.jsonl"
  echo "{\"type\":\"assistant\",$cli,$c,$ts,\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"cd x; gh run watch 2 --exit-status\"}}]}}" > "$P/s5.jsonl"
  echo "{\"type\":\"assistant\",$cli,$c,$ts,\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git commit -m 'deny gh run watch'\"}}]}}" > "$P/s6.jsonl"
  # s7 typed it and a PreToolUse hook denied it, so it never ran: not a bypass.
  echo "{\"type\":\"assistant\",$cli,$c,$ts,\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t7\",\"name\":\"Bash\",\"input\":{\"command\":\"gh run watch 7\"}}]}}" > "$P/s7.jsonl"
  echo "{\"type\":\"user\",$cli,$c,$ts,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t7\",\"is_error\":true,\"content\":\"PreToolUse:Bash hook error: hand-methods: use gh-run-wait\"}]}}" >> "$P/s7.jsonl"
  # s8: denied too, its result stored as a list of text blocks.
  echo "{\"type\":\"assistant\",$cli,$c,$ts,\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t8\",\"name\":\"Bash\",\"input\":{\"command\":\"gh run watch 8\"}}]}}" > "$P/s8.jsonl"
  echo "{\"type\":\"user\",$cli,$c,$ts,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t8\",\"is_error\":true,\"content\":[{\"type\":\"text\",\"text\":\"PreToolUse:Bash hook error: hand-methods: no\"}]}]}}" >> "$P/s8.jsonl"
  out="$(stats --kind skill,bypass,denied)"
  run row bypass one-shot <<<"$out"
  assert_output --partial '"calls":2,"sessions":2'
  assert_output --partial '"covered_sessions":1'
  run row denied one-shot <<<"$out"
  assert_output --partial '"calls":2,"sessions":2'
  # bypass alone still sees a Skill call, so coverage holds without asking for skill rows
  run row bypass one-shot <<<"$(stats --kind bypass)"
  assert_output --partial '"covered_sessions":1'
  run row bypass other <<<"$out"
  assert_output ""
}

@test "negative control: a window after the fixture counts nothing, a bad kind is refused" {
  run "$RECALL" stats --since 2026-10-21
  assert_success
  assert_output 'nothing counted since 2026-10-21T00:00:00'
  run "$RECALL" stats --kind bogus
  assert_failure 2
  assert_output --partial 'unknown kind bogus'
}
