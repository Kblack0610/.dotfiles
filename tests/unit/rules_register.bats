#!/usr/bin/env bats
# fleet-bench rules: every rule is tagged invariant or provisional in one register, and a provisional
# rule's number is re-measured rather than trusted (standards.md, the last rule). The fixtures are a
# sandbox register. The second half reads the real one in the private overlay against policy.md,
# standards.md, CLAUDE.md and the hooks: skipped in public CI, it runs in the Stop fast tier.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  # The suite and sandbox_init both move HOME, so the ~ sources the register names are read from the
  # account home (ACCOUNT_HOME, helpers/suite_home.bash). Test 16 only reads there.
  REAL_HOME="${ACCOUNT_HOME:-$HOME}" REAL_PATH="$PATH"
  REAL="${RULES_PRIVATE_REPO:-${ACCOUNT_HOME:-/nonexistent}/.dotfiles-private}/.config/agentctl/rules.jsonl"
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

# gh_stub <stderr text>: a gh that fails the way the real one does, into $SANDBOX/fail/gh.
gh_stub() {
  mkdir -p "$SANDBOX/fail"
  printf '#!/bin/sh\necho %q >&2\nexit 1\n' "$1" > "$SANDBOX/fail/gh"
  chmod +x "$SANDBOX/fail/gh"
}

@test "rules --check: a rate-limited gh measure is not a dead one, and says nothing was measured" {
  gh_stub 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)'
  row 'under ten' high "PATH='$SANDBOX/fail':\$PATH gh run list" 10
  run "$SUBJECT" rules --check
  assert_success
  assert_output ''
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '.[0] | [.state, .limited, .dead, .holds]' <<<"$output")" '["absent",true,false,null]'
}

@test "rules --check: a gh 403 that is not a rate limit, or other tool text naming one, stays dead" {
  gh_stub 'gh: Resource not accessible by integration (HTTP 403)'
  row 'under ten' high "PATH='$SANDBOX/fail':\$PATH gh run list" 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'dead measure: rules.md: under ten'
  : > "$RULES_REGISTER"
  gh_stub 'gh: some tool hit its rate limit config'
  row 'under ten' high "PATH='$SANDBOX/fail':\$PATH gh run list" 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'dead measure: rules.md: under ten'
}

@test "rules: a rate-limited counting measure drops its 0 and is counted as limited" {
  gh_stub 'gh: API rate limit exceeded for user ID 1. (HTTP 403)'
  jq -nc --arg s "$SANDBOX/rules.md" --arg m "PATH='$SANDBOX/fail':\$PATH gh run list | wc -l" \
    '{source: $s, anchor: "under ten", kind: "provisional", confidence: "low", measure: $m, min: 5}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_success
  run "$SUBJECT" rules
  assert_line 'limited=1'
  assert_line 'measured=0'
}

@test "rules --check: a bound copied from the file its measure reads restates it, whatever the number" {
  printf 'CAP=10\n' >> "$SANDBOX/rules.md"
  row 'under ten' low "sed -n 's/^CAP=//p' '$SANDBOX/rules.md'" 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'restates: rules.md: under ten'
}

@test "rules --check: a copy read through \$HOME restates too, and a count of its own lines is a real bound" {
  cp "$SANDBOX/rules.md" "$HOME/r.md"
  printf 'CAP=10\n' >> "$HOME/r.md"
  jq -nc '{source: "~/r.md", anchor: "under ten", kind: "provisional", confidence: "low", measure: "sed -n '"'"'s/^CAP=//p'"'"' \"$HOME/r.md\"", max: 10}' >> "$RULES_REGISTER"
  jq -nc '{source: "~/r.md", anchor: "Never force push", kind: "provisional", confidence: "high", measure: "grep -c \"^- \" ~/r.md", max: 5}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '[.[] | .state]' <<<"$output")" '["restates","ok"]'
}

@test "rules --json: each row carries the one state --check fails on, and a source elsewhere is absent, not a failure" {
  row 'under ten' high 'echo 11' 10
  jq -nc '{source: "/nonexistent/x.md", anchor: "elsewhere rule", kind: "invariant"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '[.[] | .state]' <<<"$output")" '["moved","absent"]'
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_equal "${#lines[@]}" 1
}

@test "rules --check: a size read with wc is a real bound on its own source, and a reading has no bound to move" {
  row 'under ten' high "wc -c < '$SANDBOX/rules.md'" 100000
  printf 'CAP=10\n' >> "$SANDBOX/rules.md"
  jq -nc --arg s "$SANDBOX/rules.md" --arg m "sed -n 's/^CAP=//p' '$SANDBOX/rules.md'" \
    '{source: $s, anchor: "Never force push", kind: "provisional", confidence: "low", measure: $m}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_success
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '[.[] | [.holds, .restates, .moved]]' <<<"$output")" '[[true,false,false],[null,false,false]]'
  assert_equal "$(jq -c '.[1].value' <<<"$output")" 10
}

@test "rules --check: a reading that prints no number is dead too" {
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "under ten", kind: "provisional", confidence: "low", measure: "echo nope"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'dead measure: rules.md: under ten'
}

@test "rules --json: a .md source is a rule, a script or config a mechanism, and a row's own form wins" {
  printf 'Never force push\n' > "$SANDBOX/hook.sh"
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "under ten", kind: "provisional", confidence: "low"}' >> "$RULES_REGISTER"
  jq -nc --arg s "$SANDBOX/hook.sh" '{source: $s, anchor: "Never force push", kind: "invariant"}' >> "$RULES_REGISTER"
  jq -nc --arg s "$SANDBOX/hook.sh" '{source: $s, anchor: "Never force push", kind: "invariant", form: "rule"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '[.[] | .form]' <<<"$output")" '["rule","mechanism","rule"]'
  run "$SUBJECT" rules
  assert_line 'mechanisms=1'
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "under ten", kind: "invariant", form: "mechanims"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'form: rules.md: under ten: mechanims is neither rule nor mechanism'
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

@test "rules: a multi-line anchor is stale on its own row and leaves the next row's value alone" {
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "two\nlines", kind: "invariant"}' >> "$RULES_REGISTER"
  row "under ten" high 'echo 3' 10
  run "$SUBJECT" rules --json
  assert_success
  assert_equal "$(jq -c '[.[] | [.anchored, .value]]' <<<"$output")" '[[false,null],[true,3]]'
}

@test "rules --scenarios: each hard scenario is listed with whether its rule text is still in its source" {
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "Never force push.", kind: "invariant", scenario: "a pushed branch has the wrong history"}' >> "$RULES_REGISTER"
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "Always force push.", kind: "invariant", scenario: "a trim reworded the rule away"}' >> "$RULES_REGISTER"
  jq -nc '{source: "/nonexistent/x.md", anchor: "elsewhere rule", kind: "invariant", scenario: "a source on another machine"}' >> "$RULES_REGISTER"
  row 'under ten' high 'echo 3' 10
  run "$SUBJECT" rules --scenarios
  assert_failure 1
  assert_equal "${#lines[@]}" 3
  assert_line "$(printf 'ok\t%s\ta pushed branch has the wrong history\tNever force push.' "$SANDBOX/rules.md")"
  assert_line "$(printf 'stale\t%s\ta trim reworded the rule away\tAlways force push.' "$SANDBOX/rules.md")"
  assert_line "$(printf 'absent\t/nonexistent/x.md\ta source on another machine\telsewhere rule')"
  run "$SUBJECT" rules
  assert_line 'scenarios=3'
  # The stale scenario fails --check like any rule whose text left its source.
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'stale: rules.md: Always force push.'
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
      or (.confidence == "high" and .number == "none on record" and (.how // "") == "" and (.measure // "") == "")
      or ((.kind // "") | IN("invariant", "provisional") | not)
      or ((.action // "") | IN("keep", "rewrite", "drop") | not)
      or ((.action != "keep") and (.why // "") == "")
      or ((.anchor // "") | length < 12)
      or (((.anchor // "") + (.measure // "")) | test("\n"))
      or (.kind == "invariant" and (.measure != null or .max != null or .min != null))
      or (.kind == "invariant" and (.scenario // "") == "")
      or (.form != null and (.form | IN("rule", "mechanism") | not))) | .anchor' "$REAL"
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
  # The real gh and its login too: the sandbox's gh stub would make every gh measure read as dead.
  PATH="$REAL_PATH" HOME="$REAL_HOME" XDG_CONFIG_HOME="$REAL_HOME/.config" RULES_REGISTER="$REAL" run "$SUBJECT" rules --json
  assert_success
  local states="$output"
  # Only this repo's sources: a rule edited or a measure gone elsewhere is the scorecard's line, and
  # must not go red on a session here that only touched fleet-bench.
  run jq -r '.[] | select((.source | startswith("~/.dotfiles/")) and (.anchored == false or .dead))
    | "\(.source): \(.anchor)"' <<<"$states"
  assert_output ''
  # A copied bound is the register's own fault wherever its source lives, so no row may carry one.
  run jq -r '.[] | select(.restates) | "\(.source): \(.anchor)"' <<<"$states"
  assert_output ''
  # A pass above means nothing if no source resolved: the rows must have been read.
  [ "$(jq '[.[] | select(.anchored == true)] | length' <<<"$states")" -gt 0 ]
}
