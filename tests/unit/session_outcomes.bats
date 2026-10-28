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

@test "worst ranks the reverted session first and leaves A out" {
  "$SUBJECT" run
  run "$SUBJECT" worst --project proj --days 7 -n 5
  assert_success
  assert_line --index 2 --partial '`sess-b`'
  assert_line --index 2 --partial '1 reverted'
  refute_output --partial 'sess-a'
}
