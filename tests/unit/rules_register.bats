#!/usr/bin/env bats
# fleet-bench rules: every rule is tagged invariant or provisional in one register, and a provisional
# rule's number is re-measured rather than trusted (standards.md, the last rule). The fixtures are a
# sandbox register. The second half reads the real one in the private overlay against policy.md,
# standards.md, CLAUDE.md and the hooks: skipped in public CI, it runs in the Stop fast tier.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  # sandbox_init moves HOME, so the real register and the ~ sources in it are read from here.
  REAL_HOME="$HOME"
  REAL="${RULES_PRIVATE_REPO:-$HOME/.dotfiles-private}/.config/agentctl/rules.jsonl"
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/fleet-bench"
  export FLEET_BENCH_DIR="$HOME/.agent/bench" BENCH_LIB_DIR="$REPO_ROOT/.local/lib"
  export RULES_REGISTER="$SANDBOX/rules.jsonl"
  printf -- '- Keep it under ten.\n- Never force push.\n' > "$SANDBOX/rules.md"
}

# row <anchor> <confidence> <measure> <max>: a provisional row on the sandbox source.
row() {
  jq -nc --arg s "$SANDBOX/rules.md" --arg a "$1" --arg c "$2" --arg m "$3" --argjson x "$4" \
    '{source: $s, anchor: $a, kind: "provisional", confidence: $c, action: "keep", measure: $m, max: $x}' >> "$RULES_REGISTER"
}

@test "rules: the summary counts kinds, confidence, actions and what was measured" {
  row 'under ten' high 'echo 3' 10
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "force push", kind: "invariant", action: "keep"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules
  assert_success
  assert_line 'rules=2'
  assert_line 'invariant=1'
  assert_line 'provisional=1'
  assert_line 'confidence_high=1'
  assert_line 'measured=1'
  assert_line 'holds=1'
}

@test "rules --check: a number inside its bound passes" {
  row 'under ten' high 'echo 3' 10
  run "$SUBJECT" rules --check
  assert_success
  assert_output ''
}

@test "rules --check: a number past its bound on a confident row has moved" {
  row 'under ten' high 'echo 11' 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'moved: rules.md: under ten: 11 against max 10, recorded high'
}

@test "rules --check: a low-confidence row past its bound is what the register says, not a move" {
  row 'under ten' low 'echo 11' 10
  run "$SUBJECT" rules --check
  assert_success
}

@test "rules --check: a low-confidence row back inside its bound has moved too" {
  row 'under ten' low 'echo 3' 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'moved: rules.md'
}

@test "rules --check: a min bound reads the other way" {
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "under ten", kind: "provisional", confidence: "high", measure: "echo 3", min: 5}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'against min 5'
}

@test "rules --check: a measure that prints no number is dead, never a pass" {
  row 'under ten' high 'echo nope' 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'dead measure: rules.md: under ten'
}

@test "rules --check: a rule whose text left its source is stale" {
  row 'not in the file' high 'echo 3' 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'stale: rules.md: not in the file'
}

@test "rules --check: a source not on this machine is no failure" {
  jq -nc '{source: "/nonexistent/x.md", anchor: "a", kind: "invariant"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_success
}

@test "rules: a ~ source resolves under HOME" {
  cp "$SANDBOX/rules.md" "$HOME/r.md"
  jq -nc '{source: "~/r.md", anchor: "under ten", kind: "invariant"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --json
  assert_success
  assert_equal "$(jq -r '.[0].anchored' <<<"$output")" true
}

@test "rules: no register is an empty count, not an error" {
  run "$SUBJECT" rules
  assert_success
  assert_line 'rules=0'
}

real_register() { [ -s "$REAL" ] || skip "no register at $REAL"; }

@test "register: every row is a whole row of its kind" {
  real_register
  run jq -r 'select(
      (.kind == "invariant" and ((.number // "") != "" or (.confidence // "") != "" or (.revisit // "") != ""))
      or (.kind == "provisional" and ((.number // "") == "" or ((.confidence // "") | IN("high", "med", "low") | not) or (.revisit // "") == ""))
      or ((.kind // "") | IN("invariant", "provisional") | not)
      or ((.action // "") | IN("keep", "rewrite", "drop") | not)
      or ((.action != "keep") and (.why // "") == "")) | .anchor' "$REAL"
  assert_output ''
}

@test "register: every bullet of policy.md and standards.md has a row" {
  real_register
  local f miss=""
  for f in "$REPO_ROOT/.config/fleet-dispatch/policy.md" "$REPO_ROOT/.local/src/docs/standards.md"; do
    local anchors="$SANDBOX/anchors"
    jq -r --arg b "/$(basename "$f")" 'select(.source | endswith($b)) | .anchor' "$REAL" > "$anchors"
    miss+=$(grep -E '^- ' "$f" | grep -vFf "$anchors" | cut -c1-80)
  done
  assert_equal "$miss" ''
}

@test "register: the text of every rule here is still in its source, and every bounded measure prints a number" {
  real_register
  HOME="$REAL_HOME" RULES_REGISTER="$REAL" run "$SUBJECT" rules --json
  assert_success
  local states="$output"
  # Only this repo's sources: a rule edited in another repo is the scorecard's line, and must not go
  # red on a session here that only touched fleet-bench.
  run jq -r '.[] | select((.anchored == false and (.source | startswith("~/.dotfiles/"))) or .dead)
    | "\(.source): \(.anchor)"' <<<"$states"
  assert_output ''
  # A pass above means nothing if no source resolved: the rows must have been read.
  [ "$(jq '[.[] | select(.anchored == true)] | length' <<<"$states")" -gt 0 ]
}
