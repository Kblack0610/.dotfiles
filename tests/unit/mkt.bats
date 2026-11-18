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

@test "a URL inside a request is a revise, a second answer changes nothing, and skip closes the item" {
  local a b
  a="$(draft)"; b="$(draft)"
  "$AGENT_ASK" answer "$(ask_of "$a")" 'cut the second line, see https://example.com/style-guide' >/dev/null
  "$MKT" answer "$a" "$(ask_of "$a")"
  [ "$("$MKT" show "$a" | jq -r .state)" = revise ]
  ! ledger | grep -q '"event":"sent"'
  "$AGENT_ASK" answer "$(ask_of "$b")" 'posted: https://reddit.com/r/dodge/3' >/dev/null
  "$MKT" answer "$b" "$(ask_of "$b")"
  local sent; sent="$("$MKT" show "$b" | jq -r .sent)"
  # the resume run twice: refused, and the send keeps its first time
  run "$MKT" answer "$b" "$(ask_of "$b")"
  assert_failure
  assert_output --partial 'not in review'
  [ "$("$MKT" show "$b" | jq -r .sent)" = "$sent" ]
  [ "$(ledger | grep -c '"event":"sent"')" = 1 ]
  "$MKT" skip "$a" --by kenneth
  [ "$("$MKT" show "$a" | jq -r '.state + " " + .reviewed_by')" = 'skipped kenneth' ]
  run "$MKT" skip "$b"
  assert_failure
  assert_output --partial 'already sent'
}

@test "draft refuses two files with one name, and a long title still fits the ask's question" {
  mkdir -p "$SANDBOX/work/b"; printf 'png' > "$SANDBOX/work/b/shot.png"
  run draft --attach "$SANDBOX/work/shot.png" --attach "$SANDBOX/work/b/shot.png"
  assert_failure
  assert_output --partial 'two files are named shot.png'
  [ ! -d "$MKT_LEDGER_DIR/dodge" ]
  run --separate-stderr "$MKT" draft --project dodge --channel some-very-long-channel-name --kind screenshots \
    --title "$(printf 't%.0s' {1..80})" "$SANDBOX/work/devlog.md"
  assert_success
  [ "$("$MKT" show "$output" | jq -r .state)" = review ]
}

@test "scorecard counts sends per channel and kind, hand vs adapter, and the median review time" {
  run "$MKT" scorecard
  assert_success
  assert_output --partial 'no items in'
  local a b c d
  a="$(draft)"; b="$(draft)"; c="$(draft)"; d="$(draft)"
  local f; f="$(ls "$MKT_LEDGER_DIR"/dodge/*.jsonl)"
  # fixed review times: a 2h, b 4h, c 9h; d stays in review
  for x in "$a:2" "$b:4" "$c:9"; do
    printf '{"ts":"2026-11-10T00:00:00Z","id":"%s","event":"review","ask":"k"}\n' "${x%:*}" >> "$f"
    printf '{"ts":"2026-11-10T0%s:00:00Z","id":"%s","event":"verdict","verdict":"hand"}\n' "${x#*:}" "${x%:*}" >> "$f"
  done
  "$MKT" log "$a" https://reddit.com/r/dodge/a
  "$MKT" log "$b" https://reddit.com/r/dodge/b
  # c went out through an adapter; a skipped item is not counted at all
  printf '{"ts":"2026-11-11T00:00:00Z","id":"%s","event":"sent","url":"https://reddit.com/c","by":"mkt"}\n' "$c" >> "$f"
  "$MKT" skip "$("$MKT" draft --project dodge --channel steam --kind listing --no-ask "$SANDBOX/work/devlog.md")"
  "$MKT" log --project dodge --channel steam --kind listing --title 'page' https://store.steampowered.com/app/1 >/dev/null
  run "$MKT" scorecard --json
  assert_success
  local reddit; reddit="$(jq -c '.[] | select(.channel == "reddit")' <<<"$output")"
  [ "$(jq -c '[.sent, .hand, .adapter, .open, .review_hours]' <<<"$reddit")" = '[3,2,1,1,4]' ]
  [ "$(jq -r '.first_sent' <<<"$reddit")" = 2026-11-11T00:00:00Z ]
  [ "$(jq -c '.[] | select(.channel == "steam") | [.kind, .sent, .open, .review_hours]' <<<"$output")" = '["listing",1,0,null]' ]
  run "$MKT" scorecard --project dodge
  assert_output --regexp 'dodge +reddit +post +3 +2 +1 +1 +4 '
}

@test "costs lists rows older than the max age or not verified, and exits 1 only when one is due" {
  local f="$SANDBOX/work/costs.csv" today; today="$(date -u +%F)"
  printf 'id,item,low_usd,high_usd,unit,market,source,last_checked,notes\n' > "$f"
  printf 'fee,Steam fee,100,100,per game,global,https://x,%s,verified primary\n' "$today" >> "$f"
  run "$MKT" costs "$f"
  assert_success
  assert_output --partial '0 of 1 rows'
  # negative controls: an old row, an unverified row and a bad date each make it due
  printf 'old,Old price,1,2,each,global,https://x,2020-01-01,verified primary\n' >> "$f"
  printf 'snip,Snippet price,1,2,each,global,https://x,%s,unverified snippet\n' "$today" >> "$f"
  printf 'nodate,No date,1,2,each,global,https://x,soon,verified primary\n' >> "$f"
  run "$MKT" costs "$f"
  assert_failure 1
  assert_output --partial $'old\tOld price\tchecked 2020-01-01, over 183 days ago'
  assert_output --partial $'snip\tSnippet price\tnotes: unverified snippet'
  assert_output --partial $'nodate\tNo date\tlast_checked is not a date'
  assert_output --partial '3 of 4 rows'
  refute_output --partial $'fee\t'
  run "$MKT" costs "$f" --max-age-days 100000
  refute_output --partial $'old\t'
  run "$MKT" costs "$SANDBOX/work/missing.csv"
  assert_failure 2
  assert_output --partial 'unreadable: costs file'
  printf 'id,item,notes,last_checked\n' > "$f"
  run "$MKT" costs "$f"
  assert_failure 2
  assert_output --partial 'unreadable:'
}

@test "{utm} after a link that has a query joins it with &, after one without it starts the query" {
  printf 'Get it: https://play.google.com/store/apps/details?id=com.dodge?{utm} or https://dodge.example?{utm}\n' > "$SANDBOX/work/devlog.md"
  local id; id="$(draft)"
  local u="utm_source=reddit&utm_medium=post&utm_campaign=dodge&utm_content=$id"
  run cat "$MKT_LEDGER_DIR/dodge/files/$id/devlog.md"
  assert_output "Get it: https://play.google.com/store/apps/details?id=com.dodge&$u or https://dodge.example?$u"
}

@test "metrics records a sent item's numbers once, never over a later day, and refuses an unsent item or a malformed document" {
  local doc='{"metrics": {"wishlist_adds_7d": 3}, "window": {"from": "2026-11-01", "to": "2026-11-03", "final": false}}'
  local id; id="$(draft)"
  run "$MKT" metrics "$id" "$doc"
  assert_failure
  assert_output --partial 'only a sent item has numbers'
  run "$MKT" log "$id" https://reddit.com/r/x/9
  assert_success
  run "$MKT" metrics "$id" '{"metrics": {"wishlist_adds_7d": "3"}, "window": {"from": "2026-11-01", "to": "2026-11-03", "final": false}}'
  assert_failure
  run "$MKT" metrics "$id" '{"metrics": {"wishlist_adds_7d": 3}, "window": {"from": "2026-11-04", "to": "2026-11-03", "final": false}}'
  assert_failure
  run "$MKT" metrics "$id" "$doc"
  assert_output recorded
  run "$MKT" metrics "$id" "$doc"
  assert_output unchanged
  # a backfill for an earlier day leaves the later numbers
  run "$MKT" metrics "$id" '{"metrics": {"wishlist_adds_7d": 1}, "window": {"from": "2026-11-01", "to": "2026-11-02", "final": false}}'
  assert_output unchanged
  run "$MKT" show "$id"
  assert_equal "$(jq -c '[.metrics, .window.final]' <<<"$output")" '[{"wishlist_adds_7d":3},false]'
  [ "$(ledger | grep -c '"event":"metrics"')" -eq 1 ]
}
