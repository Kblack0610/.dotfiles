#!/usr/bin/env bats
# mkt-drafts: which product, channel and trigger gets a draft, and that each draft lands in the
# outbound ledger through `mkt draft` with its approval ask. The model call and release-state are
# stubs; mkt and agent-ask are the real ones. Today is fixed at Thu 2026-11-19.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MD="$REPO_ROOT/.local/bin/mkt-drafts"
  MKT="$REPO_ROOT/.local/bin/mkt"
  export MKT_LEDGER_DIR="$HOME/.agent/outbound" MKT_DRAFTS_TODAY=2026-11-19
  export MKT_CHANNELS="$SANDBOX/channels.yaml" MKT_CALENDAR="$SANDBOX/calendar.yaml"
  export RELEASE_STATE="$SANDBOX/release-state" MKT="$MKT"
  MODEL_BIN="$SANDBOX/bin/agentctl-run"
  export MODEL_LOG="$SANDBOX/model.log"
  mkdir -p "$HOME/.config/shared-hooks"
  printf '{"paths": {}, "trackers": {"dodge": {"type": "game"}, "quiet": {"type": "game"}}}\n' > "$HOME/.config/shared-hooks/project-map.json"

  cat > "$MKT_CHANNELS" <<'EOF'
accounts:
  bluesky: {handle: null, owner: human}
products:
  dodge:
    shape: pc-game
    pitch: "Dodgeball, but the arena fights back."
    tag_prefix: dodge-v
    channels:
      bluesky: "draft"
      reddit: "draft"
      steam: "draft"
      x: "off"
  quiet:
    shape: saas
    pitch: "A product with every channel off."
    tag_prefix: quiet-v
    channels:
      bluesky: "off"
      reddit: "off"
EOF
  cat > "$MKT_CALENDAR" <<'EOF'
events:
  - id: fest
    title: Next Fest
    start: 2026-11-25
    end: 2026-12-01
    products: [dodge, quiet]
    channels: [steam, x, bluesky]
    notes: wishlist posts only
  - id: far
    title: Spring sale
    start: 2027-03-01
    end: 2027-03-08
    products: [dodge]
    channels: [steam]
recurring:
  - id: shot-sat
    title: Screenshot Saturday
    rule: "weekly: saturday"
    products: [dodge]
    channels: [bluesky]
  - id: monthly-ish
    title: Per release
    rule: per-release
    products: [dodge]
    channels: [steam]
EOF
  # release-state: the newest tag is 4 days old (RS_TAG_AGE_DAYS), and a week of merged PRs.
  cat > "$RELEASE_STATE" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "changelog --json")
    at=$(date -u -d "2026-11-19 - ${RS_TAG_AGE_DAYS:-4} days" +%s)
    jq -nc --arg p "$3" --argjson at "$at" '{project: $p, tag: "\($p)-v1.2.0", at: $at, text: "### Added\n- a new arena"}' ;;
  "merged --days")
    printf '%b' "${RS_PRS:-#12 feat(arena): a new map\\n#13 ci: bump the runner\\n}" ;;
  *) exit 2 ;;
esac
EOF
  # the model: logs its input, answers with a draft that carries the {utm} placeholder
  cat > "$MODEL_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$4" >> "$MODEL_LOG"
[ -z "${MODEL_EXIT:-}" ] || exit "$MODEL_EXIT"
if [ -n "${MODEL_DECLINE:-}" ]; then echo '{"title": "", "draft": "", "reason": "nothing true to say"}'; exit 0; fi
jq -c '{title: "Post for \(.channel): \(.trigger)", draft: "\(.product.pitch) https://dodge.example?{utm}", reason: ""}' <<<"$4"
EOF
  chmod +x "$RELEASE_STATE" "$MODEL_BIN"
}

keys() { jq -r '.[] | "\(.project) \(.channel) \(.trigger)"' | sort; }
rows() { "$MKT" list --json | jq 'length'; }

@test "plan: a release, a week of PRs, an event and a weekly rule, and nothing for an off channel or product" {
  run --separate-stderr "$MD" plan --json
  assert_success
  run keys <<<"$output"
  assert_output "$(printf '%s\n' \
    'dodge bluesky event:fest' \
    'dodge bluesky release:dodge-v1.2.0' \
    'dodge bluesky shot-sat:2026-11-21' \
    'dodge bluesky week:2026-W47' \
    'dodge reddit release:dodge-v1.2.0' \
    'dodge steam event:fest' \
    'dodge steam release:dodge-v1.2.0')"
}

@test "plan: negative control, x in mode draft is drafted, so the off assertion has teeth" {
  sed -i 's/x: "off"/x: "draft"/' "$MKT_CHANNELS"
  run --separate-stderr "$MD" plan --json
  assert_success
  [[ "$(jq -r '.[] | "\(.channel) \(.trigger)"' <<<"$output")" == *'x release:dodge-v1.2.0'* ]]
  [[ "$(jq -r '.[] | "\(.channel) \(.trigger)"' <<<"$output")" == *'x event:fest'* ]]
}

@test "plan: a tag older than the release window drafts nothing, and a week of only internal PRs none" {
  export RS_TAG_AGE_DAYS=40
  run --separate-stderr "$MD" plan --json
  [[ "$output" != *release:* ]]
  export RS_PRS="#13 ci: bump the runner\n#14 docs: a page\n"
  run --separate-stderr "$MD" plan --json
  [[ "$output" != *week:* ]]
}

@test "run: each item is one ledger row with its trigger and one approval ask, the UTM filled in" {
  run --separate-stderr "$MD" run
  assert_success
  # six of the seven: MAX_DRAFTS
  [ "$(rows)" = 6 ]
  run "$MKT" list --json
  [ "$(jq -r 'map(select(.trigger and .by == "mkt-drafts" and .state == "review")) | length' <<<"$output")" = 6 ]
  local one; one="$(jq -c '[.[] | select(.channel == "reddit")][0]' <<<"$output")"
  [ "$(jq -r .trigger <<<"$one")" = release:dodge-v1.2.0 ]
  [ "$(jq -r .kind <<<"$one")" = post ]
  grep -q "utm_source=reddit&utm_medium=post&utm_campaign=dodge&utm_content=$(jq -r .id <<<"$one")" "$(jq -r .draft <<<"$one")"
  ! grep -q '{utm}' "$(jq -r .draft <<<"$one")"
  [ "$(jq -r '[.[] | select(.channel == "steam")][0].kind' <<<"$output")" = listing ]
  [ "$(wc -l < "$MODEL_LOG")" = 6 ]
  # the model is shown the product's pitch and the trigger, not just the channel
  grep -q 'Dodgeball, but the arena fights back' "$MODEL_LOG"
  grep -q 'a new arena' "$MODEL_LOG"
  [ "$(cat "$HOME/.local/state/agentctl/mkt-drafts/last-outcome")" = WORKED ]
}

@test "run: a second run drafts what is left once, and a third drafts nothing" {
  "$MD" run
  run "$MD" run
  assert_success
  [ "$(rows)" = 7 ]
  [ "$(wc -l < "$MODEL_LOG")" = 7 ]
  run "$MD" run
  [ "$(rows)" = 7 ]
  [ "$(wc -l < "$MODEL_LOG")" = 7 ]
  [ "$(cat "$HOME/.local/state/agentctl/mkt-drafts/last-outcome")" = NOOP ]
}

@test "run: a skipped row is not drafted again" {
  "$MD" run --max 7
  local id; id="$("$MKT" list --json | jq -r '.[0].id')"
  "$MKT" skip "$id"
  run "$MD" run
  [ "$(rows)" = 7 ]
}

@test "run: a declined draft is a skipped row with the reason, and its trigger is not asked twice" {
  MODEL_DECLINE=1 run "$MD" run --max 7
  assert_success
  [ "$(rows)" = 7 ]
  run "$MKT" list --json
  [ "$(jq -r 'map(select(.state == "skipped")) | length' <<<"$output")" = 7 ]
  grep -q 'nothing true to say' "$(jq -r '.[0].draft' <<<"$output")"
  : > "$MODEL_LOG"
  run "$MD" run
  [ ! -s "$MODEL_LOG" ]
}

@test "run: a budget stop is BLOCKED, drafts nothing and exits 0" {
  MODEL_EXIT=75 run "$MD" run
  assert_success
  [ "$(rows)" = 0 ]
  [ "$(cat "$HOME/.local/state/agentctl/mkt-drafts/last-outcome")" = BLOCKED ]
}

@test "run: an unusable reply is counted failed and writes no row" {
  printf '#!/usr/bin/env bash\necho not-json\n' > "$MODEL_BIN"
  run --separate-stderr "$MD" run
  [ "$(rows)" = 0 ]
  [ "$(cat "$HOME/.local/state/agentctl/mkt-drafts/last-outcome")" = FAILED ]
}

@test "mkt draft: --trigger is stored on the row, and no flag means no field" {
  printf '# Hello\n\nbody\n' > "$SANDBOX/d.md"
  run "$MKT" draft --project dodge --channel reddit --kind post --trigger release:x --no-ask "$SANDBOX/d.md"
  assert_success
  [ "$("$MKT" show "$output" | jq -r .trigger)" = release:x ]
  run "$MKT" draft --project dodge --channel reddit --kind post --no-ask "$SANDBOX/d.md"
  [ "$("$MKT" show "$output" | jq 'has("trigger")')" = false ]
}
