#!/usr/bin/env bats
# The harness contract (QUEUE.md "Harnesses", private overlay): every harness in harnesses.json says
# whether a later run can take up its session (`resume`) and which facts its runs report (`reports`:
# end_reason, tokens, cost, hard_errors, tests, effort). A false names its reason in `why_not`; a true
# is proved here by the reader that fact comes from, run on this harness's fixture under
# tests/fixtures/harness-contract/, giving a value that is not null, zero or empty. A launcher with no
# reader proves no true, and harnesses on one launcher state the same facts. An optional `max_tier`
# (the harness's trust ceiling, which fleet-dispatch enforces) is 1, 2 or 3.
# The real map is checked where the private overlay is (the Stop fast tier); public CI skips that one
# test, and the fixture map and negative controls below run everywhere.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  FIX="$REPO_ROOT/tests/fixtures/harness-contract"
  MAP="${HARNESS_CONTRACT_MAP:-$HOME/.dotfiles-private/.config/agentctl/harnesses.json}"
  SANDBOX="$BATS_TEST_TMPDIR"
  export SO_PROJECT_LIB="$SANDBOX/project-name.sh"
  echo 'resolve_project_name() { basename "$1"; }' > "$SO_PROJECT_LIB"
}

KEYS="end_reason tokens cost hard_errors tests effort"

# reader <launcher> <map> -> the facts that launcher's reader gives on its fixture, as one JSON object
# with a key per contract fact it proves (null when the reader gave none); {} for a launcher with no reader.
# Read once per launcher, map and fixture dir: several harnesses share a launcher (glm and opencode).
reader() {
  local w="$BATS_TEST_TMPDIR/reader/$1/$(printf '%s\n' "$2" "$FIX" | md5sum | cut -c1-12)"
  [ -f "$w.json" ] || { mkdir -p "$w"; read_facts "$1" "$2" "$w" > "$w.json"; }
  cat "$w.json"
}

read_facts() {
  local w="$3"
  case "$1" in
    codex)
      mkdir -p "$w/s"
      cp "$FIX/codex-rollout.jsonl" "$w/s/rollout-2026-11-09T12-00-00-cx-contract.jsonl"
      local row end thread
      row=$(bash -c '. "$1/.local/lib/session-outcomes.sh" && so_codex_rows "$2" "$3" "$4"' _ "$REPO_ROOT" "$w/s" "$w" "$2")
      end=$(jq -rs --argjson timeout_s 0 -f "$REPO_ROOT/.local/lib/codex-rollout.jq" "$FIX/codex-rollout.jsonl")
      # resume: agent-codex resume hands codex the thread id the rollout's reader gives.
      thread=$(jq -r .session_id <<<"$row")
      printf '#!/bin/sh\necho "$*" > "%s/codex.args"\n' "$w" > "$w/codex"; chmod +x "$w/codex"
      (unset AGENT_QUEUE_ITEM; CODEX_BIN="$w/codex" "$REPO_ROOT/.local/bin/agent-codex" resume "$thread" "go on" >/dev/null 2>&1)
      jq -c --arg end "$end" --arg args "$(cat "$w/codex.args" 2>/dev/null)" --arg t "$thread" '
        {resume: (if $t != "" and ($args | startswith("exec resume --json \($t) ")) then $t else null end),
         end_reason: (if $end == "" then null else $end end), tokens: .tokens.total, cost: .cost_usd,
         hard_errors: .metrics.hard_errors, tests: .metrics.activity.test_runs, effort}' <<<"$row" ;;
    opencode)
      sqlite3 "$w/oc.db" < "$FIX/opencode.sql"
      bash -c '. "$1/.local/lib/session-outcomes.sh" && so_opencode_rows "$2" "$3"' _ "$REPO_ROOT" "$w/oc.db" "$w" |
        jq -c '{tokens: .tokens.total, cost: .cost_usd}' ;;
    claude-lazer)
      bash -c '. "$1/.local/lib/session-outcomes.sh" && so_transcript_metrics "$2"' _ "$REPO_ROOT" "$FIX/claude-transcript.jsonl" |
        jq -c '{tokens: .activity.tokens, hard_errors, tests: .activity.test_runs}' ;;
    *) echo '{}' ;;
  esac
}

# A fact is proved by a value that shows the reader read it: the fixtures hold one of each, so a zero,
# an empty string or an all-zero count object is a reader that read nothing.
PROVED='def read: if type == "object" then any(.[]; read) else . != null and . != 0 and . != "" and . != false end; .[$k] | read'

# problems <map> -> one line per broken clause of the contract; nothing when the map keeps it.
problems() {
  local map="$1" h l facts k v
  for h in $(jq -r '.harnesses | keys[]' "$map"); do
    l=$(jq -r --arg h "$h" '.harnesses[$h].launcher // $h' "$map")
    facts=$(reader "$l" "$map")
    for k in resume $KEYS; do
      v=$(jq -c --arg h "$h" --arg k "$k" '.harnesses[$h] | if $k == "resume" then .resume else .reports[$k] end' "$map")
      case "$v" in
        true) jq -e --arg k "$k" "$PROVED" <<<"$facts" >/dev/null || echo "$h $k: true, but the $l reader gives no value on its fixture" ;;
        false) jq -e --arg h "$h" --arg k "$k" '.harnesses[$h].why_not[$k] | type == "string" and test("\\S")' "$map" >/dev/null || echo "$h $k: false with no why_not" ;;
        *) echo "$h $k: not stated (${v})" ;;
      esac
    done
    jq -r --arg h "$h" --arg keys "$KEYS" '.harnesses[$h] as $e | (($e.reports // {}) | (keys - ($keys | split(" ")))[] | "\($h) reports.\(.): not a contract fact"),
      (($e.why_not // {}) | keys[] | select((if . == "resume" then $e.resume else $e.reports[.] end) != false) | "\($h) why_not.\(.): the fact is not false"),
      ($e | select(has("max_tier") and ([1, 2, 3] | index($e.max_tier) | not)) | "\($h) max_tier: \(.max_tier | tojson) is not 1, 2 or 3")' "$map"
  done
  # Harnesses on one launcher read their facts from one reader, so they state the same ones.
  jq -r '.harnesses | to_entries | sort_by(.key) | group_by(.value.launcher // .key)[] | select(length > 1)
    | (.[0] | {key, f: {resume: .value.resume, reports: .value.reports}}) as $a | .[1:][]
    | select({resume: .value.resume, reports: .value.reports} != $a.f) | "\(.key): states other facts than \($a.key) on the same launcher"' "$map"
}

# fixture_map -> a map with one harness of each reader kept, to doctor in the negative controls.
fixture_map() {
  jq -n '{harnesses: {
    codex: {launcher: "codex", resume: true, reports: {end_reason: true, tokens: true, cost: true, hard_errors: true, tests: true, effort: true},
            prices: {"gpt-6.1-sol": {input: 2, cached_input: 0.1, output: 10}}},
    glm: {launcher: "opencode", resume: false, reports: {end_reason: false, tokens: true, cost: true, hard_errors: false, tests: false, effort: false},
          why_not: {resume: "r", end_reason: "e", hard_errors: "h", tests: "t", effort: "f"}},
    "lazer-reserve": {launcher: "claude-lazer", resume: false, reports: {end_reason: false, tokens: true, cost: false, hard_errors: true, tests: true, effort: false},
                     why_not: {resume: "r", end_reason: "e", cost: "c", effort: "f"}},
    "claude-lazer": {resume: false, reports: {end_reason: false, tokens: true, cost: false, hard_errors: true, tests: true, effort: false},
                     why_not: {resume: "r", end_reason: "e", cost: "c", effort: "f"}}}}' > "$SANDBOX/harnesses.json"
}

@test "the real harnesses.json keeps the contract: every fact stated, a why_not on each false, a fixture for each true" {
  [ -f "$MAP" ] || skip "no private overlay map at $MAP"
  run problems "$MAP"
  assert_success
  assert_output ''
  # The point of the contract: codex reports why its runs end, and resumes.
  jq -e '.harnesses.codex | .reports.end_reason == true and .resume == true' "$MAP"
}

@test "a map with one harness per reader keeps the contract" {
  fixture_map
  run problems "$SANDBOX/harnesses.json"
  assert_success
  assert_output ''
}

@test "each reader gives its facts on its fixture: codex all six and resume, opencode tokens and cost, claude transcripts tokens, errors and tests" {
  fixture_map
  assert_equal "$(reader codex "$SANDBOX/harnesses.json" | jq -c '[.resume, .end_reason, .tokens, .cost, .hard_errors.tool_errors, .tests, .effort]')" '["cx-contract","limit",240,0.00061,1,2,"medium"]'
  # cost in thousandths: jq 1.6 prints the stored 0.042 as 0.0420000000000000026.
  assert_equal "$(reader opencode "$SANDBOX/harnesses.json" | jq -c '[.tokens, (.cost * 1000 | round)]')" '[480,42]'
  assert_equal "$(reader claude-lazer "$SANDBOX/harnesses.json" | jq -c '[.tokens, .hard_errors.tool_errors, .tests]')" '[35,1,1]'
}

@test "negative controls: a false with no why, a true no reader proves, an unstated fact, a stray key, a stale why, a max_tier that is no tier and launcher siblings that disagree each fail" {
  fixture_map
  jq '.harnesses.glm.why_not |= del(.tests, .effort)
      | .harnesses.glm.reports.effort = true
      | .harnesses.codex.reports |= del(.effort)
      | .harnesses.codex.reports.vibes = true
      | .harnesses.codex.why_not = {tokens: "stale"}
      | .harnesses["lazer-reserve"].reports.cost = true | .harnesses["lazer-reserve"].why_not |= del(.cost)
      | .harnesses.glm.max_tier = "1"
      | .harnesses.cloud = {resume: false, reports: {end_reason: false, tokens: true, cost: false, hard_errors: false, tests: false, effort: false},
                            why_not: {resume: "r", end_reason: "e", cost: "c", hard_errors: "h", tests: "t", effort: "f"}}' \
    "$SANDBOX/harnesses.json" > "$SANDBOX/bad.json"
  run problems "$SANDBOX/bad.json"
  assert_line 'glm tests: false with no why_not'
  assert_line 'glm effort: true, but the opencode reader gives no value on its fixture'
  assert_line 'codex effort: not stated (null)'
  assert_line 'codex reports.vibes: not a contract fact'
  assert_line 'codex why_not.tokens: the fact is not false'
  assert_line 'cloud tokens: true, but the cloud reader gives no value on its fixture'
  assert_line 'lazer-reserve cost: true, but the claude-lazer reader gives no value on its fixture'
  assert_line 'lazer-reserve: states other facts than claude-lazer on the same launcher'
  assert_line 'glm max_tier: "1" is not 1, 2 or 3'
  assert_equal "${#lines[@]}" 9
}

@test "negative control: a codex fixture with no turn, no token count and no tool run proves no end_reason, tokens, cost, hard_errors or tests" {
  fixture_map
  FIX="$BATS_TEST_TMPDIR/fix"; mkdir -p "$FIX"; cp "$REPO_ROOT/tests/fixtures/harness-contract/"* "$FIX/"
  jq -c 'select(.type == "session_meta" or .type == "turn_context")' "$REPO_ROOT/tests/fixtures/harness-contract/codex-rollout.jsonl" > "$FIX/codex-rollout.jsonl"
  run problems "$SANDBOX/harnesses.json"
  assert_line 'codex end_reason: true, but the codex reader gives no value on its fixture'
  assert_line 'codex tokens: true, but the codex reader gives no value on its fixture'
  assert_line 'codex cost: true, but the codex reader gives no value on its fixture'
  assert_line 'codex hard_errors: true, but the codex reader gives no value on its fixture'
  assert_line 'codex tests: true, but the codex reader gives no value on its fixture'
}
