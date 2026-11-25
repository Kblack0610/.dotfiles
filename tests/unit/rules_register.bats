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
  # What a rule row's enforced_by points at: a file that exists, so a fixture row has an enforcer.
  export ENF="test:$SANDBOX/rules.md"
}

# row <anchor> <confidence> <measure> <max>: a provisional row on the sandbox source.
row() {
  jq -nc --arg s "$SANDBOX/rules.md" --arg a "$1" --arg c "$2" --arg m "$3" --argjson x "$4" \
    '{source: $s, anchor: $a, kind: "provisional", enforced_by: env.ENF, confidence: $c, action: "keep", measure: $m, max: $x}' >> "$RULES_REGISTER"
}

@test "rules: the summary counts kinds, confidence, actions and what was measured" {
  row 'under ten' high 'echo 3' 10
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "force push", kind: "invariant", enforced_by: env.ENF, action: "keep"}' >> "$RULES_REGISTER"
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
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "under ten", kind: "provisional", enforced_by: env.ENF, confidence: "high", measure: "echo 3", min: 5}' >> "$RULES_REGISTER"
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

# gh_stub <stderr text>: a gh that fails the way the real one does.
gh_stub() { gh_script "echo $(printf %q "$1") >&2; exit 1"; }

@test "rules --check: a rate-limited gh measure is not a dead one, and says nothing was measured" {
  gh_stub 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)'
  row 'under ten' high "gh run list" 10
  run "$SUBJECT" rules --check
  assert_success
  assert_output ''
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '.[0] | [.state, .limited, .dead, .holds]' <<<"$output")" '["absent",true,false,null]'
}

@test "rules --check: a gh 403 that is not a rate limit, or other tool text naming one, stays dead" {
  gh_stub 'gh: Resource not accessible by integration (HTTP 403)'
  row 'under ten' high "gh run list" 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'dead measure: rules.md: under ten'
  : > "$RULES_REGISTER"
  gh_stub 'gh: some tool hit its rate limit config'
  row 'under ten' high "gh run list" 10
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'dead measure: rules.md: under ten'
}

@test "rules: a rate-limited counting measure drops its 0 and is counted as limited" {
  gh_stub 'gh: API rate limit exceeded for user ID 1. (HTTP 403)'
  jq -nc --arg s "$SANDBOX/rules.md" --arg m "gh run list | wc -l" \
    '{source: $s, anchor: "under ten", kind: "provisional", enforced_by: env.ENF, confidence: "low", measure: $m, min: 5}' >> "$RULES_REGISTER"
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
  jq -nc '{source: "~/r.md", anchor: "under ten", kind: "provisional", enforced_by: env.ENF, confidence: "low", measure: "sed -n '"'"'s/^CAP=//p'"'"' \"$HOME/r.md\"", max: 10}' >> "$RULES_REGISTER"
  jq -nc '{source: "~/r.md", anchor: "Never force push", kind: "provisional", enforced_by: env.ENF, confidence: "high", measure: "grep -c \"^- \" ~/r.md", max: 5}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '[.[] | .state]' <<<"$output")" '["restates","ok"]'
}

@test "rules --json: each row carries the one state --check fails on, and a source elsewhere is absent, not a failure" {
  row 'under ten' high 'echo 11' 10
  jq -nc '{source: "/nonexistent/x.md", anchor: "elsewhere rule", kind: "invariant", enforced_by: env.ENF}' >> "$RULES_REGISTER"
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
    '{source: $s, anchor: "Never force push", kind: "provisional", enforced_by: env.ENF, confidence: "low", measure: $m}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_success
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '[.[] | [.holds, .restates, .moved]]' <<<"$output")" '[[true,false,false],[null,false,false]]'
  assert_equal "$(jq -c '.[1].value' <<<"$output")" 10
}

@test "rules --check: a reading that prints no number is dead too" {
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "under ten", kind: "provisional", enforced_by: env.ENF, confidence: "low", measure: "echo nope"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'dead measure: rules.md: under ten'
}

@test "rules --json: a .md source is a rule, a script or config a mechanism, and a row's own form wins" {
  printf 'Never force push\n' > "$SANDBOX/hook.sh"
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "under ten", kind: "provisional", enforced_by: env.ENF, confidence: "low"}' >> "$RULES_REGISTER"
  jq -nc --arg s "$SANDBOX/hook.sh" '{source: $s, anchor: "Never force push", kind: "invariant", enforced_by: env.ENF}' >> "$RULES_REGISTER"
  jq -nc --arg s "$SANDBOX/hook.sh" '{source: $s, anchor: "Never force push", kind: "invariant", enforced_by: env.ENF, form: "rule"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '[.[] | .form]' <<<"$output")" '["rule","mechanism","rule"]'
  run "$SUBJECT" rules
  assert_line 'mechanisms=1'
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "under ten", kind: "invariant", enforced_by: env.ENF, form: "mechanims"}' >> "$RULES_REGISTER"
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
  jq -nc '{source: "/nonexistent/x.md", anchor: "a", kind: "invariant", enforced_by: env.ENF}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --check
  assert_success
}

@test "rules: a ~ source resolves under HOME" {
  cp "$SANDBOX/rules.md" "$HOME/r.md"
  jq -nc '{source: "~/r.md", anchor: "under ten", kind: "invariant", enforced_by: env.ENF}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --json
  assert_success
  assert_equal "$(jq -r '.[0].anchored' <<<"$output")" true
}

@test "rules: a multi-line anchor is stale on its own row and leaves the next row's value alone" {
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "two\nlines", kind: "invariant", enforced_by: env.ENF}' >> "$RULES_REGISTER"
  row "under ten" high 'echo 3' 10
  run "$SUBJECT" rules --json
  assert_success
  assert_equal "$(jq -c '[.[] | [.anchored, .value]]' <<<"$output")" '[[false,null],[true,3]]'
}

@test "rules --scenarios: each hard scenario is listed with whether its rule text is still in its source" {
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "Never force push.", kind: "invariant", enforced_by: env.ENF, scenario: "a pushed branch has the wrong history"}' >> "$RULES_REGISTER"
  jq -nc --arg s "$SANDBOX/rules.md" '{source: $s, anchor: "Always force push.", kind: "invariant", enforced_by: env.ENF, scenario: "a trim reworded the rule away"}' >> "$RULES_REGISTER"
  jq -nc '{source: "/nonexistent/x.md", anchor: "elsewhere rule", kind: "invariant", enforced_by: env.ENF, scenario: "a source on another machine"}' >> "$RULES_REGISTER"
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

# gate_repo: a git repo of gate code under $SANDBOX/g: one tool with a marked refusal and eight lines after it (past GATE_NEAR), one hook that denies
# with its marker, committed as the base the diff check reads against. GATE_* point fleet-bench at it.
gate_repo() {
  G="$SANDBOX/g"
  mkdir -p "$G/.local/bin" "$G/.claude/hooks"
  { printf '#!/bin/bash\n# gate: tool-refuse\ndie "no"\n'; printf '# filler\n%.0s' 1 2 3 4 5 6 7 8; } > "$G/.local/bin/agent-x"
  printf 'import json\n# gate: hook-deny\nprint(json.dumps({"permissionDecision": "deny"}))\n' > "$G/.claude/hooks/h.py"
  git -C "$G" init -q -b main
  git -C "$G" -c user.name=t -c user.email=t@t add -A
  git -C "$G" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$G" branch -q work && git -C "$G" checkout -q work
  export GATE_ROOT="$G" GATE_TOOLS=".local/bin/agent-x"
  gate_row tool-refuse 'agent:#1' ''
  gate_row hook-deny 'agent:#2' ''
}

# gate_row <id> <asked_by> <extra json object or ''>: a gate row on the sandbox repo.
gate_row() {
  jq -nc --arg id "$1" --arg a "$2" --argjson x "${3:-null}" \
    '{source: "~/g/x", anchor: ("# gate: " + $id), rule: "a refusal", kind: "provisional", confidence: "low", action: "keep", id: $id, asked_by: $a, added: "2026-11-20"} + ($x // {})' >> "$RULES_REGISTER"
}

@test "rules --gates: every marker has a row and every denying hook has a marker" {
  gate_repo
  run "$SUBJECT" rules --gates main
  assert_success
  assert_output ''
}

@test "rules --gates: a marker whose id has no row fails, naming the file, line and id" {
  gate_repo
  printf '# gate: ghost-gate\ndie "x"\n' >> "$G/.local/bin/agent-x"
  run "$SUBJECT" rules --gates main
  assert_failure 1
  assert_output --partial 'unregistered gate: .local/bin/agent-x:12: gate: ghost-gate has no row in the register'
}

@test "rules --gates: a marker inside a continued command fails, since it would swallow the next line" {
  gate_repo
  printf 'jq -n --arg r "$x" \\\n  # gate: tool-refuse\n  filter\n' >> "$G/.local/bin/agent-x"
  run "$SUBJECT" rules --gates main
  assert_failure 1
  assert_output --partial 'misplaced gate: .local/bin/agent-x:13'
}

@test "rules --gates: a hook that denies with no marker fails (negative control)" {
  gate_repo
  printf 'import json\nprint(json.dumps({"permissionDecision": "deny"}))\n' > "$G/.claude/hooks/new.py"
  run "$SUBJECT" rules --gates main
  assert_failure 1
  assert_output --partial 'unmarked gate: .claude/hooks/new.py'
}

@test "rules --gates: a refusal the branch adds with no marker fails; a marker, gate: none or a comment passes" {
  gate_repo
  printf 'if bad; then\n  die "new refusal"\nfi\n' >> "$G/.local/bin/agent-x"
  run "$SUBJECT" rules --gates main
  assert_failure 1
  assert_output --partial 'unmarked refusal: .local/bin/agent-x:13: an added refusal names no register row'
  git -C "$G" checkout -q -- .local/bin/agent-x
  printf 'if bad; then\n  # gate: none\n  die "usage: agent-x <id>"\nfi\n# a comment that says die "x" is no refusal\n' >> "$G/.local/bin/agent-x"
  run "$SUBJECT" rules --gates main
  assert_success
  git -C "$G" checkout -q -- .local/bin/agent-x
  printf 'if bad; then\n  # gate: tool-refuse\n  die "same gate, second site"\nfi\n' >> "$G/.local/bin/agent-x"
  run "$SUBJECT" rules --gates main
  assert_success
}

@test "rules --gates: no base to diff against is no failure, the marker checks still run" {
  gate_repo
  printf 'die "new refusal"\n' >> "$G/.local/bin/agent-x"
  run "$SUBJECT" rules --gates no-such-ref
  assert_success
}

@test "rules --check: a gate row needs asked_by as an ask id, the human's words, or agent:" {
  gate_repo
  gate_row bare-gate '' ''
  gate_row typo-gate 'somebody' ''
  gate_row ask-gate 'ask:YVyqvq' ''
  gate_row human-gate 'human:2026-11-23 "no gate without my ask"' ''
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'gate asked_by: bare-gate'
  assert_output --partial 'gate asked_by: typo-gate'
  refute_output --partial 'ask-gate'
  refute_output --partial 'human-gate'
}

@test "rules --check: a gate an agent added that routes work to the human fails unless an unexpired removal covers it" {
  gate_repo
  gate_row route-gate 'agent:#9' '{"routes": "human"}'
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'agent route: route-gate: it routes work to the human and an agent added it'
  : > "$RULES_REGISTER"
  gate_row route-gate 'agent:#9' '{"routes": "human", "remove_item": "ar-1", "remove_by": "2999-01-01"}'
  run "$SUBJECT" rules --check
  assert_success
  : > "$RULES_REGISTER"
  gate_row route-gate 'agent:#9' '{"routes": "human", "remove_item": "ar-1", "remove_by": "2020-01-01"}'
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'agent route: route-gate: its removal by ar-1 was due 2020-01-01; delete the gate'
  : > "$RULES_REGISTER"
  gate_row route-gate 'ask:YVyqvq' '{"routes": "human"}'
  gate_row own-rule 'human:~/.claude/CLAUDE.md "approvals are mine"' '{"routes": "human"}'
  run "$SUBJECT" rules --check
  assert_success
}

@test "rules: no register is an empty count, not an error" {
  run "$SUBJECT" rules
  assert_success
  assert_line 'rules=0'
}

# enf_row <enforced_by|null> [source]: a rule row (a .md source) with that enforced_by.
enf_row() {
  jq -nc --arg s "${2:-$SANDBOX/rules.md}" --argjson e "$1" \
    '{source: $s, anchor: "Never force push", kind: "invariant", action: "keep"} + (if $e == null then {} else {enforced_by: $e} end)' >> "$RULES_REGISTER"
}

@test "rules --check: a rule row that names no enforced_by fails, and a mechanism row is its own enforcer" {
  enf_row null
  enf_row null "$SANDBOX/hook.sh"
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'enforcer: rules.md: Never force push: names no enforced_by'
  refute_output --partial 'hook.sh'
  run "$SUBJECT" rules --json
  assert_equal "$(jq -c '[.[] | [.enforcer, .state]]' <<<"$output")" '[["missing","enforcer"],["self","ok"]]'
}

@test "rules --check: an enforced_by that is not test:, hook:, ci: or review is bad" {
  enf_row '"lint"'
  enf_row '"test:"'
  enf_row "\"test:$SANDBOX/rules.md::\""
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_equal "$(grep -c 'enforcer: rules.md: Never force push: enforced_by .* is not review' <<<"$output")" 3
}

@test "rules --check: an enforcer whose file is gone, or whose test name is not in the file, is dead (negative control)" {
  enf_row "\"hook:$SANDBOX/gone.sh\""
  enf_row "\"ci:$SANDBOX/gone.yml\""
  enf_row "\"test:$SANDBOX/rules.md::no such test\""
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_equal "$(grep -c 'does not resolve: no such file, or the test name is not in it' <<<"$output")" 3
}

@test "rules --check: a test, hook or ci that is there passes, a ~ path resolves under HOME and a test name is found in the file" {
  printf '@test "a named test" {\n}\n' > "$SANDBOX/x.bats"
  mkdir -p "$HOME/.dotfiles/.claude/hooks"
  : > "$HOME/.dotfiles/.claude/hooks/h.sh"
  enf_row "\"test:$SANDBOX/x.bats::a named test\""
  enf_row '"hook:~/.dotfiles/.claude/hooks/h.sh"'
  enf_row "\"ci:$SANDBOX/rules.md\""
  run "$SUBJECT" rules --check
  assert_success
  assert_output ''
}

@test "rules --check: a source on another machine is absent before its enforcer is read" {
  enf_row '"hook:/nonexistent/h.sh"' /nonexistent/x.md
  run "$SUBJECT" rules --check
  assert_success
}

@test "rules --check: the review rows only shrink against the baseline, in both directions" {
  export RULES_PROSE_BASELINE="$SANDBOX/prose-baseline"
  enf_row '"review"'
  enf_row '"review"'
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial "prose-only: 2 rule rows name no check but review, and $RULES_PROSE_BASELINE has no review=N line"
  printf '# comment\nreview=1\n' > "$RULES_PROSE_BASELINE"
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'prose-only: 2 rule rows name no check but review, over the baseline 1'
  printf 'review=2\n' > "$RULES_PROSE_BASELINE"
  run "$SUBJECT" rules --check
  assert_success
  printf 'review=3\n' > "$RULES_PROSE_BASELINE"
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial "under the baseline 3; lower review= in $RULES_PROSE_BASELINE to 2"
  run "$SUBJECT" rules
  assert_line 'prose_only=2'
}

@test "rules --check: a mechanism row that says review is not a prose-only rule row" {
  export RULES_PROSE_BASELINE="$SANDBOX/prose-baseline"
  echo 'review=0' > "$RULES_PROSE_BASELINE"
  enf_row '"review"' "$SANDBOX/hook.sh"
  run "$SUBJECT" rules --check
  assert_success
}

# lesson_dir <seen> [enforced_by marker]: a lessons dir with one lesson the sweep found <seen> times.
lesson_dir() {
  export RULES_LESSONS_DIR="$SANDBOX/lessons" RULES_LESSONS_CMD="$REPO_ROOT/.local/bin/lessons"
  mkdir -p "$RULES_LESSONS_DIR"
  printf -- '- **2026-11-20** **Run it twice.** Why: it recurred.\n  <!-- seen:%s 2026-11-21 -->%s\n' "$1" "${2:+ $2}" > "$RULES_LESSONS_DIR/proj.md"
}

@test "rules --check: a lesson the sweep found twice must name a check that resolves; once is no failure" {
  lesson_dir 1
  run "$SUBJECT" rules --check
  assert_success
  lesson_dir 2
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'lesson: proj.md:1: seen 2 times, enforced_by missing'
  lesson_dir 2 '<!-- enforced_by:review -->'
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'enforced_by review'
  lesson_dir 2 "<!-- enforced_by:hook:$SANDBOX/gone.sh -->"
  run "$SUBJECT" rules --check
  assert_failure 1
  lesson_dir 2 "<!-- enforced_by:test:$SANDBOX/rules.md -->"
  run "$SUBJECT" rules --check
  assert_success
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
      or (.form != null and (.form | IN("rule", "mechanism") | not))
      or ((.form // (if (.source | test("\\.md$")) then "rule" else "mechanism" end)) == "rule" and (.enforced_by // "") == "")
      or ((.enforced_by // "review") | test("^(review|(test|hook|ci):.+)$") | not)) | .anchor' "$REAL"
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
  run jq -r '.[] | select((.source | startswith("~/.dotfiles/")) and (.anchored == false or .dead or .enforcer == "dead"))
    | "\(.source): \(.anchor)"' <<<"$states"
  assert_output ''
  # A copied bound is the register's own fault wherever its source lives, so no row may carry one.
  run jq -r '.[] | select(.restates) | "\(.source): \(.anchor)"' <<<"$states"
  assert_output ''
  # A pass above means nothing if no source resolved: the rows must have been read.
  [ "$(jq '[.[] | select(.anchored == true)] | length' <<<"$states")" -gt 0 ]
}

@test "register: every gate in the code has a row, every denying hook a marker, and every gate row says who asked" {
  real_register
  RULES_REGISTER="$REAL" GATE_ROOT="$REPO_ROOT" run "$SUBJECT" rules --gates "${GATE_BASE:-origin/main}"
  assert_output ''
  # Only the gate rows' own problems: another row moving is the scorecard's line, not this PR's.
  PATH="$REAL_PATH" HOME="$REAL_HOME" XDG_CONFIG_HOME="$REAL_HOME/.config" RULES_REGISTER="$REAL" run "$SUBJECT" rules --check
  run grep -E '^(gate asked_by|agent route):' <<<"$output"
  assert_output ''
  [ "$(jq -s '[.[] | select(.id != null)] | length' "$REAL")" -gt 0 ]
}

@test "rules --check: a gate row needs the date it was added" {
  gate_repo
  gate_row undated-gate 'agent:#3' '{"added": null}'
  gate_row loose-gate 'agent:#4' '{"added": "Nov 20"}'
  gate_row no-such-day 'agent:#5' '{"added": "2026-11-31"}'
  run "$SUBJECT" rules --check
  assert_failure 1
  assert_output --partial 'gate added: undated-gate: missing is not the YYYY-MM-DD'
  assert_output --partial 'gate added: loose-gate: Nov 20 is not the YYYY-MM-DD'
  assert_output --partial 'gate added: no-such-day: 2026-11-31 is not the YYYY-MM-DD'
  refute_output --partial 'tool-refuse'
}

@test "rules --new: the gates added in the window, agent-added first, newest first, each with its PR" {
  gate_row old-gate 'agent:#1' '{"added": "2026-11-01"}'
  gate_row human-gate 'human:2026-11-19 "hold the release"' '{"added": "2026-11-21", "source": "~/.dotfiles-private/x"}'
  gate_row agent-late 'agent:#30' '{"added": "2026-11-22", "source": "~/.dotfiles/x"}'
  gate_row agent-early 'agent:abc1234 (before PR numbers)' '{"added": "2026-11-20"}'
  jq -nc '{source: "~/r.md", anchor: "a rule", kind: "provisional", enforced_by: env.ENF, added: "2026-11-21"}' >> "$RULES_REGISTER"
  run "$SUBJECT" rules --new --since 2026-11-20 --until 2026-11-22
  assert_success
  assert_output "$(printf '%s\t%s\t%s\t%s\t%s\n' \
    2026-11-22 agent-late 'agent:#30' 'dotfiles #30' 'a refusal' \
    2026-11-20 agent-early 'agent:abc1234 (before PR numbers)' - 'a refusal' \
    2026-11-21 human-gate 'human:2026-11-19 "hold the release"' - 'a refusal')"
  run "$SUBJECT" rules --new --since 2026-11-20 --until 2026-11-22 --line
  assert_output '3 gates added from 2026-11-20 to 2026-11-22, 2 by an agent without your ask: agent-late (dotfiles #30), agent-early (abc1234). List: fleet-bench rules --new --since 2026-11-20 --until 2026-11-22.'
  run "$SUBJECT" rules --new --since 2026-11-21 --until 2026-11-21 --line
  assert_output '1 gate added on 2026-11-21, on your ask. List: fleet-bench rules --new --since 2026-11-21 --until 2026-11-21.'
  run "$SUBJECT" rules --new --since 2026-11-20 --until 2026-11-22 --json
  assert_success
  run jq -c 'map([.id, .by_agent, .pr])' <<<"$output"
  assert_output '[["agent-late",true,"dotfiles #30"],["agent-early",true,null],["human-gate",false,null]]'
}

@test "rules --new: --days ends today; a window with no new gate prints no line, and bad input is a usage error (negative control)" {
  gate_row today-gate 'agent:#5' "$(jq -nc --arg d "$(date +%F)" '{added: $d}')"
  gate_row old-gate 'agent:#1' '{"added": "2020-01-01"}'
  run "$SUBJECT" rules --new --days 7
  assert_success
  assert_output --partial 'today-gate'
  refute_output --partial 'old-gate'
  run "$SUBJECT" rules --new --since 2030-01-01 --line
  assert_success
  assert_output ''
  run "$SUBJECT" rules --new --days 0
  assert_failure 2
  run "$SUBJECT" rules --new --since soon
  assert_failure 2
  run "$SUBJECT" rules --new --days 3 --until 2026-11-10
  assert_failure 2
  run "$SUBJECT" rules --new --days 3 --since 2026-11-10
  assert_failure 2
  : > "$RULES_REGISTER"
  run "$SUBJECT" rules --new --line
  assert_failure 1
  assert_output --partial 'no register'
}
