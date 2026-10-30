#!/usr/bin/env bats
# agentctl-session-outcomes + session-outcomes.sh: the measured quality signal dream
# ranks sessions by, in place of eval scores that read 10/10 89% of the time.
#
# Fixture: three registry sessions in one project. A opened PR #10 (merged, kept) and
# closed a board row with --proof. B opened #11, which #12 reverted a day later. C hit an
# API error, was interrupted, had a tool call rejected, and wrote a lesson. D is a headless
# runner (entrypoint sdk-cli) that wrote a lesson. `gh` is the sandbox stub serving canned
# `pr list` JSON; nothing here reaches the network.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SUBJECT="$REPO_ROOT/.local/bin/agentctl-session-outcomes"
  export SO_LIB_DIR="$REPO_ROOT/.local/lib"
  export SO_SESSIONS="$HOME/.agent/sessions"
  export SO_OUT="$HOME/.agent/outcomes"
  export AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  # 2026-10-20T00:00:00Z; every fixture session stopped 2026-10-19.
  export SO_NOW=1792454400
  STOP=1792368000
  TR="$HOME/transcripts"
  mkdir -p "$TR" "$SO_SESSIONS/proj"

  # A: gh pr create -> PR 10 URL; a board row closed with proof; a `gh pr view` of PR 99
  # whose URL must NOT be claimed (the session only looked at it).
  cat > "$TR/a.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"u1","name":"Bash","input":{"command":"gh pr create --title 'feat: a' --body x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u1","content":"https://github.com/o/r/pull/10\n"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"u2","name":"Bash","input":{"command":"notes ptask proj --agent done \"feat a\" --proof pr:10"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u2","content":"done"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"u3","name":"Bash","input":{"command":"gh pr view 99 -R o/r"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u3","content":"url: https://github.com/o/r/pull/99"}]}}
EOF
  # B: gh pr merge output names PR 11.
  cat > "$TR/b.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"v1","name":"Bash","input":{"command":"gh pr merge 11 --squash -R o/r"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"v1","content":[{"type":"text","text":"Squashed and merged pull request o/r#11 (feat: b)"}]}]}}
EOF
  # C: an API error, an interrupt, a rejected tool call, a lesson appended through Bash,
  # one malformed line (a crash mid-write) and a quoted "API Error" in prose that must
  # not count.
  cat > "$TR/c.jsonl" <<'EOF'
{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 529 overloaded"}]}}
{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"the log said API Error twice"},{"type":"tool_use","id":"w1","name":"Edit","input":{"file_path":"/x/y.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"w1","is_error":true,"content":"The user doesn't want to proceed with this tool use. The tool use was rejected"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"w2","name":"Bash","input":{"command":"cat >> ~/.agent/lessons/proj.md <<'X'\n- lesson\nX"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"w2","content":""}]}}
{"type":"assistant","message":{"content":[{"ty
EOF
  # D: a dream sweep promoting a lesson, as `claude -p` records it.
  cat > "$TR/d.jsonl" <<'EOF'
{"type":"queue-operation"}
{"type":"user","entrypoint":"sdk-cli","message":{"content":"sweep"}}
{"type":"assistant","entrypoint":"sdk-cli","message":{"content":[{"type":"tool_use","id":"x1","name":"Bash","input":{"command":"cat >> ~/.agent/lessons/proj.md <<'X'\n- promoted\nX"}}]}}
{"type":"user","entrypoint":"sdk-cli","message":{"content":[{"type":"tool_result","tool_use_id":"x1","content":""}]}}
EOF

  # B and C both score friction 5, so cost (B 3, C 2) decides the order in `worst`.
  local s cost
  for s in a:1 b:3 c:2 d:0; do
    cost="${s#*:}" s="${s%:*}"
    jq -cn --arg s "$s" --arg t "$TR/$s.jsonl" --argjson u "$STOP" --argjson c "$cost" \
      '{session_id: ("sess-" + $s), project: "proj", transcript: $t, title: ("title " + $s),
        updated: $u, edits: 1, cost_usd: $c, tokens: {total: 100}}'
  done > "$SO_SESSIONS/proj/sessions.jsonl"

  cat > "$GH_FIXTURE/prs.o-r" <<'EOF'
[{"number":10,"state":"MERGED","title":"feat: a","mergedAt":"2026-10-19T01:00:00Z"},
 {"number":11,"state":"MERGED","title":"feat: b","mergedAt":"2026-10-19T02:00:00Z"},
 {"number":12,"state":"MERGED","title":"Revert \"feat: b (#11)\"","mergedAt":"2026-10-20T02:00:00Z"},
 {"number":99,"state":"OPEN","title":"someone else","mergedAt":null}]
EOF
}

outcome() { cat "$AGENTCTL_STATE_DIR/session-outcomes/last-outcome"; }
lines() { cat "$SO_OUT"/proj/*.jsonl; }
# field <session-letter> <jq-path> - from the newest observation of that session
field() { cat "$SO_OUT"/*/*.jsonl | jq -rs --arg s "sess-$1" "map(select(.session_id == \$s)) | last | $2"; }
# reverted <number> - so_pr_index over the shared revert fixture
reverted() { (. "$REPO_ROOT/.local/lib/session-outcomes.sh"; so_pr_index 7 < "$BATS_TEST_TMPDIR/revs.json") | jq -r --arg n "$1" '.[$n].reverted'; }

# The shapes the old title-only rule missed. 241 is private #241, which undid #240 by
# re-arming a timer with "Reverts #240" in its body and no revert in its title.
revert_fixture() {
  cat > "$BATS_TEST_TMPDIR/revs.json" <<'EOF'
[{"number":240,"state":"MERGED","title":"chore(agentctl): park the fleet-dispatch timer","body":"","mergedAt":"2026-10-27T14:55:14Z","mergeCommit":{"oid":"1111111aaaa"}},
 {"number":241,"state":"MERGED","title":"chore(agentctl): re-arm the fleet-dispatch timer","body":"Reverts #240: the 2h dispatch loop stays on.","mergedAt":"2026-10-27T14:59:28Z","mergeCommit":{"oid":"2222222bbbb"}},
 {"number":5,"state":"MERGED","title":"feat: five","body":"","mergedAt":"2026-10-27T10:00:00Z","mergeCommit":{"oid":"abcdef1234567"}},
 {"number":50,"state":"MERGED","title":"feat: fifty","body":"","mergedAt":"2026-10-27T10:00:00Z","mergeCommit":{"oid":"5555555cccc"}},
 {"number":60,"state":"MERGED","title":"fix: undo five","body":"This reverts commit abcdef1.","mergedAt":"2026-10-27T12:00:00Z","mergeCommit":{"oid":"6666666dddd"}},
 {"number":61,"state":"MERGED","title":"feat: sixty-one","body":"","mergedAt":"2026-10-27T10:00:00Z","mergeCommit":{"oid":"7777777eeee"}},
 {"number":62,"state":"MERGED","title":"docs: revert-safe parsing","body":"Follows #61.\nWe may revert this later.","mergedAt":"2026-10-27T12:00:00Z","mergeCommit":{"oid":"8888888ffff"}},
 {"number":63,"state":"MERGED","title":"chore: tidy","body":"reverting #50 would break nothing","mergedAt":"2026-10-20T12:00:00Z","mergeCommit":{"oid":"9999999aaaa"}},
 {"number":64,"state":"MERGED","title":"feat: x again","body":"Re-applies #61 (reverted in #62) without the menu change.","mergedAt":"2026-10-27T13:00:00Z","mergeCommit":{"oid":"aaaaaaa1111"}}]
EOF
}

@test "three sessions -> three lines, WORKED, one gh call for the one repo" {
  run "$SUBJECT" run
  assert_success
  assert_equal "$(lines | wc -l)" 3
  assert_equal "$(outcome)" WORKED
  assert_equal "$(grep -c '^gh pr list -R o/r' "$GH_FIXTURE/calls.log")" 1
  grep -q -- '--json number,state,title,mergedAt,body,mergeCommit' "$GH_FIXTURE/calls.log"
  [ -f "$SO_OUT/proj/2026-10.jsonl" ]
}

@test "merged PR kept: A has one merged PR, no revert, a proof row, and did not claim #99" {
  "$SUBJECT" run
  assert_equal "$(field a '[.prs[].number] | join(",")')" 10
  assert_equal "$(field a .prs_merged)" 1
  assert_equal "$(field a .reverted_7d)" 0
  assert_equal "$(field a .board_done.proof)" 1
}

@test "reverted PR: B's #11 is reverted by #12 within the window" {
  "$SUBJECT" run
  assert_equal "$(field b '.prs[0].number')" 11
  assert_equal "$(field b .reverted_7d)" 1
}

@test "hard errors: C counts the flagged API error only, the interrupt, the denial, the lesson" {
  "$SUBJECT" run
  assert_equal "$(field c .hard_errors.api_error)" 1
  assert_equal "$(field c .hard_errors.denied)" 1
  assert_equal "$(field c .corrections.interrupts)" 1
  assert_equal "$(field c .corrections.lessons_written)" 1
  assert_equal "$(field c '.prs | length')" 0
}

@test "a headless runner files under _runner and its lesson is not a correction" {
  "$SUBJECT" run
  [ -f "$SO_OUT/_runner/2026-10.jsonl" ]
  assert_equal "$(field d .project)" _runner
  assert_equal "$(field d .runner)" true
  assert_equal "$(field d .corrections)" null
  assert_equal "$(field c .runner)" false
}

@test "revert in a body: #241 Reverts #240" {
  revert_fixture
  assert_equal "$(reverted 240)" true
  assert_equal "$(reverted 241)" false
}

@test "revert by commit: This reverts commit <sha> of #5's merge commit, not #50" {
  revert_fixture
  assert_equal "$(reverted 5)" true
  assert_equal "$(reverted 50)" false
}

@test "not a revert: revert-safe, a revert word on another line, reverted in #N, outside the window" {
  revert_fixture
  assert_equal "$(reverted 61)" false
  assert_equal "$(reverted 62)" false
}

@test "second run is NOOP and writes nothing" {
  "$SUBJECT" run
  run "$SUBJECT" run
  assert_success
  assert_equal "$(outcome)" NOOP
  assert_equal "$(lines | wc -l)" 3
}

@test "run --all observes every session again, so a fixed detector reaches final rows" {
  "$SUBJECT" run
  local before; before=$(cat "$SO_OUT"/*/*.jsonl | wc -l)
  SO_NOW=$((SO_NOW + 60)) run "$SUBJECT" run --all
  assert_success
  assert_equal "$(outcome)" WORKED
  assert_equal "$(cat "$SO_OUT"/*/*.jsonl | wc -l)" $((before * 2))
}

@test "run with an unknown arg fails and writes nothing" {
  run "$SUBJECT" run --bogus
  assert_failure 2
  [ ! -d "$SO_OUT/proj" ]
}

@test "turning FINAL_DAYS old re-observes once with final=true" {
  "$SUBJECT" run
  assert_equal "$(field a .final)" false
  SO_NOW=$((SO_NOW + 8 * 86400)) "$SUBJECT" run
  assert_equal "$(lines | wc -l)" 6
  assert_equal "$(field a .final)" true
  SO_NOW=$((SO_NOW + 9 * 86400)) run "$SUBJECT" run
  assert_equal "$(outcome)" NOOP
}

@test "a gh failure is STALLED, exits 1, and writes nothing" {
  printf '#!/bin/sh\necho "HTTP 403: rate limit" >&2\nexit 1\n' > "$SANDBOX/bin/gh-broken"
  chmod +x "$SANDBOX/bin/gh-broken"
  SO_GH=gh-broken run "$SUBJECT" run
  assert_failure
  assert_equal "$(outcome)" STALLED
  [ ! -d "$SO_OUT/proj" ]
}

# One API message split across two records, a commit message that names a
# test command, a test run, a CI poll, an edit, then a message spent after it, ending on a
# write to its own notes, which does not reset the count.
activity_of() {
  # shellcheck source=/dev/null
  . "$SO_LIB_DIR/session-outcomes.sh"
  so_transcript_metrics "$1" | jq -c .activity
}

@test "activity: tool calls, test runs and CI polls come from the commands, each message's tokens once" {
  cat > "$TR/act.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":2,"output_tokens":3},"content":[{"type":"text","text":"x"}]}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":2,"output_tokens":3},"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"git commit -m 'make test and bats pass'"}}]}}
{"type":"assistant","message":{"id":"m2","usage":{"output_tokens":100},"content":[{"type":"tool_use","id":"b","name":"Bash","input":{"command":"cd x && FOO=1 timeout 60 scripts/test/run.sh Bar"}},{"type":"tool_use","id":"c","name":"Edit","input":{"file_path":"/repo/a.sh"}}]}}
{"type":"assistant","message":{"id":"m3","usage":{"output_tokens":7},"content":[{"type":"tool_use","id":"d","name":"Bash","input":{"command":"gh pr checks 5 --watch"}},{"type":"tool_use","id":"e","name":"Write","input":{"file_path":"/home/u/.agent/lessons/p.md"}}]}}
EOF
  run activity_of "$TR/act.jsonl"
  assert_output '{"tool_calls":5,"test_runs":1,"ci_polls":1,"api_messages":3,"tokens":123,"tokens_after_last_edit":7}'
}

@test "activity: a commit ends the edit count, for edits made through Bash" {
  cat > "$TR/act.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":100},"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"git add -A && git commit -m x"}}]}}
{"type":"assistant","message":{"id":"m2","usage":{"output_tokens":7},"content":[{"type":"text","text":"done"}]}}
EOF
  run activity_of "$TR/act.jsonl"
  assert_output --partial '"tokens_after_last_edit":7'
}

@test "activity: a transcript with no usage counts its calls and no tokens, and reaches the row" {
  "$SUBJECT" run
  run jq -sr 'map(select(.session_id == "sess-a"))[0].activity | "\(.tool_calls) \(.tokens)"' "$SO_OUT/proj/2026-10.jsonl"
  assert_output '3 0'
}

@test "worst ranks the reverted session first and leaves A out" {
  "$SUBJECT" run
  run "$SUBJECT" worst --project proj --days 7 -n 5
  assert_success
  assert_line --index 2 --partial '`sess-b`'
  assert_line --index 2 --partial '1 reverted'
  refute_output --partial 'sess-a'
}

# Langfuse push. `curl-lf` stands in for curl: it records each request body and argv,
# answers LF_CODE (default 207) with LF_ERRORS per-event errors (default none), and never
# reaches the network. The key comes from the rbw stub's fixture.
lf_setup() {
  printf 'pk-lf-test:sk-lf-secret' > "$RBW_FIXTURE/langfuse-api"
  cat > "$SANDBOX/bin/curl-lf" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null    # the -K - config carrying the key
out="" body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    --data-binary) body="${2#@}"; shift ;;
  esac
  shift
done
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/lf.argv"
cat "$body" >> "$BATS_TEST_TMPDIR/lf.posted"; echo >> "$BATS_TEST_TMPDIR/lf.posted"
errs="[]"; [ "${LF_ERRORS:-0}" -gt 0 ] && errs='[{"id":"x","status":400,"message":"bad"}]'
printf '{"successes":[],"errors":%s}' "$errs" > "$out"
printf '%s' "${LF_CODE:-207}"
STUB
  chmod +x "$SANDBOX/bin/curl-lf"
  export SO_CURL=curl-lf SO_LF_URL=http://langfuse.test
}
posted() { jq -c '.batch[]' "$BATS_TEST_TMPDIR/lf.posted"; }
report() { tail -1 "$AGENTCTL_STATE_DIR/session-outcomes/activity.log"; }
mark() { cat "$AGENTCTL_STATE_DIR/session-outcomes/langfuse-mark" 2>/dev/null; }

@test "langfuse: with no URL the push is skipped" {
  printf 'pk-lf-test:sk-lf-secret' > "$RBW_FIXTURE/langfuse-api"
  run "$SUBJECT" run
  assert_success
  report | grep -q 'langfuse: no URL (SO_LF_URL)'
  run grep -c '^rbw' "$RBW_FIXTURE/calls.log"
  assert_output 0
}

@test "langfuse: with no key the run still works and says it skipped the push" {
  export SO_LF_URL=http://langfuse.test
  run "$SUBJECT" run
  assert_success
  assert_equal "$(outcome)" WORKED
  report | grep -q 'langfuse: no key (rbw langfuse-api)'
  [ -z "$(mark)" ]
}

@test "langfuse: one score per measure per session, keyed on sessionId, a runner sends no corrections" {
  lf_setup
  run "$SUBJECT" run
  assert_success
  report | grep -q 'langfuse: 34 score(s) for 4 session(s)'
  assert_equal "$(posted | jq -s 'length')" 34
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-d") | .body.name' | grep -c -E 'interrupts|lessons_written')" 0
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-b" and .body.name == "reverted_7d") | .body.value')" 1
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-c" and .body.name == "friction") | .body.value')" 5
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-a" and .body.name == "prs_merged") | .body.id')" so:sess-a:prs_merged
  assert_equal "$(mark)" 2026-10-20T00:00:00Z
}

@test "langfuse: the key never appears in curl's argv" {
  lf_setup
  "$SUBJECT" run
  run grep -c 'sk-lf-secret' "$BATS_TEST_TMPDIR/lf.argv"
  assert_output 0
}

@test "langfuse: a second run sends nothing new; --all resends the same score ids" {
  lf_setup
  "$SUBJECT" run
  local first; first=$(posted | jq -r .body.id | sort)
  assert_equal "$(wc -l <<<"$first")" 34
  : > "$BATS_TEST_TMPDIR/lf.posted"
  "$SUBJECT" run
  report | grep -q 'langfuse: nothing new'
  [ ! -s "$BATS_TEST_TMPDIR/lf.posted" ]
  run "$SUBJECT" langfuse --all
  assert_success
  assert_equal "$(posted | jq -r .body.id | sort)" "$first"
}

@test "langfuse: a failed push leaves the mark, says FAILED, and the next run sends it again" {
  lf_setup
  LF_CODE=500 run "$SUBJECT" run
  assert_success
  assert_equal "$(outcome)" WORKED
  report | grep -q 'langfuse: FAILED (HTTP 500)'
  [ -z "$(mark)" ]
  : > "$BATS_TEST_TMPDIR/lf.posted"
  "$SUBJECT" run
  assert_equal "$(outcome)" NOOP
  assert_equal "$(posted | jq -s 'length')" 34
  assert_equal "$(mark)" 2026-10-20T00:00:00Z
}

@test "langfuse: a 207 carrying per-event errors is a failure" {
  lf_setup
  LF_ERRORS=1 "$SUBJECT" run
  report | grep -q 'langfuse: FAILED (HTTP 207)'
  [ -z "$(mark)" ]
}

@test "langfuse: sessions past the 90-day trace TTL are not sent" {
  lf_setup
  "$SUBJECT" run
  : > "$BATS_TEST_TMPDIR/lf.posted"
  SO_NOW=$((SO_NOW + 91 * 86400)) run "$SUBJECT" langfuse --all
  assert_success
  assert_output --partial 'langfuse: nothing new'
}
