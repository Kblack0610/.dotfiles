#!/usr/bin/env bats
# mkt: the outbound ledger. Each item is events in ~/.agent/outbound/<project>/<YYYY-MM>.jsonl,
# its review an approval ask whose answer `mkt answer` turns into a verdict and, with a URL, a
# send. The real agent-ask runs in the sandbox; hub-core's outbound.rs folds the same lines.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MKT="$REPO_ROOT/.local/bin/mkt"
  export MKT_LEDGER_DIR="$HOME/.agent/outbound"
  mkdir -p "$HOME/.config/shared-hooks" "$SANDBOX/work"
  printf '{"paths": {}, "trackers": {"dodge": {"type": "game"}}}\n' > "$HOME/.config/shared-hooks/project-map.json"
  printf '# Devlog four: the new arena\n\nThree weeks of netcode, one new map.\n' > "$SANDBOX/work/devlog.md"
  printf 'png' > "$SANDBOX/work/shot.png"
  printf 'notes' > "$SANDBOX/work/notes.txt"
}

draft() { "$MKT" draft --project dodge --channel reddit --kind post "$@" "$SANDBOX/work/devlog.md"; }
ledger() { cat "$MKT_LEDGER_DIR"/dodge/*.jsonl; }
ask_of() { "$MKT" show "$1" | jq -r .ask; }

@test "draft opens an item, copies its files and posts an approval ask with image previews" {
  run --separate-stderr draft --attach "$SANDBOX/work/shot.png" --attach "$SANDBOX/work/notes.txt"
  assert_success
  local id="$output"
  [[ "$id" =~ ^[0-9]{6}-[0-9a-f]{6}$ ]]
  local files="$MKT_LEDGER_DIR/dodge/files/$id"
  [ -f "$files/devlog.md" ] && [ -f "$files/shot.png" ] && [ -f "$files/notes.txt" ]
  run "$MKT" show "$id"
  assert_output --partial '"state": "review"'
  assert_output --partial '"title": "Devlog four: the new arena"'
  assert_output --partial "utm_source=reddit&utm_medium=post&utm_campaign=dodge&utm_content=$id"
  run "$AGENT_ASK" show "$(ask_of "$id")"
  assert_output --partial 'kind: approval'
  assert_output --partial 'question: Send the post "Devlog four: the new arena" on reddit for dodge?'
  assert_output --partial "resume: run: mkt answer $id"
  assert_output --partial 'recommend: hand'
  # only the image is a preview, and it is the ledger's copy, not the draft's original
  assert_output --partial "previews: $files/shot.png"
  refute_output --partial 'notes.txt|'
  refute_output --regexp $'(^|\n)claude_session: [^\n]'
  run "$AGENT_ASK" list dodge --pending
  [ "$(cut -f32 <<<"$output")" = "$files/shot.png" ]
  # the answer reaches mkt through the ask's resume
  "$AGENT_ASK" answer "$(ask_of "$id")" 'https://reddit.com/r/x/1' >/dev/null
  run "$ASK_RESUME" --dry-run
  assert_output --partial "would run:  mkt answer $id $(ask_of "$id")"
}

@test "an answer with the post's URL records the verdict and the send" {
  local id; id="$(draft)"
  local ask; ask="$(ask_of "$id")"
  "$AGENT_ASK" answer "$ask" 'posted: https://reddit.com/r/dodge/comments/abc.' >/dev/null
  run "$MKT" answer "$id" "$ask"
  assert_success
  run "$MKT" show "$id"
  assert_output --partial '"state": "sent"'
  assert_output --partial '"verdict": "hand"'
  assert_output --partial '"url": "https://reddit.com/r/dodge/comments/abc"'
  run "$MKT" list --project dodge --state sent
  assert_output --partial "$id"
  # a send is logged once
  run "$MKT" log "$id" https://reddit.com/again
  assert_failure
  assert_output --partial 'already logged as sent'
}

@test "hand with no URL waits for mkt log, skip is never sent, and free words send it back" {
  local a b c
  a="$(draft)"; b="$(draft)"; c="$(draft)"
  "$AGENT_ASK" answer "$(ask_of "$a")" hand >/dev/null
  "$AGENT_ASK" answer "$(ask_of "$b")" skip >/dev/null
  "$AGENT_ASK" answer "$(ask_of "$c")" 'cut the second line' >/dev/null
  for i in "$a" "$b" "$c"; do "$MKT" answer "$i" "$(ask_of "$i")"; done
  [ "$("$MKT" show "$a" | jq -r .state)" = approved ]
  [ "$("$MKT" show "$b" | jq -r .state)" = skipped ]
  [ "$("$MKT" show "$c" | jq -r .state)" = revise ]
  [ "$("$MKT" show "$c" | jq -r .note)" = 'cut the second line' ]
  "$MKT" log "$a" https://reddit.com/r/dodge/2 --by kenneth
  [ "$("$MKT" show "$a" | jq -r '.state + " " + .by')" = 'sent kenneth' ]
}

@test "mkt answer before the human answers changes nothing" {
  local id; id="$(draft)"
  run "$MKT" answer "$id" "$(ask_of "$id")"
  assert_failure
  assert_output --partial 'has no answer yet'
  [ "$("$MKT" show "$id" | jq -r .state)" = review ]
}

@test "log records a send made outside mkt draft as a new item" {
  run "$MKT" log --project dodge --channel steam --kind listing --title 'store page refresh' \
    --by store-console --reviewed-by kenneth https://store.steampowered.com/app/1
  assert_success
  local id="$output"
  run "$MKT" show "$id"
  assert_output --partial '"state": "sent"'
  assert_output --partial '"reviewed_by": "kenneth"'
  assert_output --partial '"by": "store-console"'
  run "$MKT" log --project dodge --channel steam --kind listing --title x not-a-url
  assert_failure
}

@test "post sends only a post verdict through an adapter, and no channel has one yet" {
  local id; id="$(draft)"
  run "$MKT" post "$id"
  assert_failure
  assert_output --partial 'only an item its reviewer answered post on is sent'
  # negative control: forge a post verdict; with no adapter for reddit it still refuses
  printf '{"ts":"2026-11-15T00:00:00Z","id":"%s","event":"verdict","verdict":"post"}\n' "$id" >> "$(ls "$MKT_LEDGER_DIR"/dodge/*.jsonl)"
  run "$MKT" post "$id"
  assert_failure
  assert_output --partial "no adapter posts to reddit; post it by hand, then: mkt log $id <url>"
  ! ledger | grep -q '"event":"sent"'
}

@test "draft refuses an unknown project, kind or attachment and writes nothing" {
  run "$MKT" draft --project nope --channel reddit --kind post "$SANDBOX/work/devlog.md"
  assert_failure
  assert_output --partial "'nope' is not a project"
  run "$MKT" draft --project dodge --channel reddit --kind tweet "$SANDBOX/work/devlog.md"
  assert_failure
  assert_output --partial "kind 'tweet' is not one of"
  run draft --attach "$SANDBOX/work/missing.png"
  assert_failure
  [ ! -d "$MKT_LEDGER_DIR/dodge" ]
  [ -z "$(find "$HOME/.agent/asks" -name '*.md' 2>/dev/null)" ]
}

@test "a refused review ask leaves the item a draft and says so" {
  # agent-ask refuses a question over its cap
  AGENT_ASK_QUESTION_MAX=20 run --separate-stderr draft
  assert_failure
  [[ "$stderr" == *"the item stays a draft"* ]]
  run "$MKT" list --project dodge --state draft
  [ -n "$output" ]
}
