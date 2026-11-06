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
  # fleet-bench stats, canned: serves $BENCH_FX when it exists, nothing otherwise
  export SO_BENCH=bench-stub BENCH_FX="$SANDBOX/bench.jsonl"
  printf '#!/usr/bin/env bash\n[ "$*" = "stats --json" ] || exit 9\ncat "%s" 2>/dev/null || true\n' "$BENCH_FX" > "$SANDBOX/bin/bench-stub"
  chmod +x "$SANDBOX/bin/bench-stub"
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
  # no calls.jsonl line names it, so its agent is unknown rather than guessed
  assert_equal "$(field d .agent)" null
}

@test "a runner session carries the agent calls.jsonl names for it; a human session never does" {
  mkdir -p "$AGENTCTL_STATE_DIR"
  # sess-c is interactive: a stray call line on its id must not make it a runner
  printf '%s\n' '{"id":"c1","agent":"dream","session_id":"sess-d"}' '{"id":"c2","agent":"ask-judge","session_id":"sess-c"}' \
    '{"id":"c3","agent":"dream"}' > "$AGENTCTL_STATE_DIR/calls.jsonl"
  AGENTCTL_CALLS="$AGENTCTL_STATE_DIR/calls.jsonl" "$SUBJECT" run
  assert_equal "$(field d .agent)" dream
  assert_equal "$(field c .agent)" null
  assert_equal "$(field a .agent)" null
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
  assert_output '{"tool_calls":5,"test_runs":1,"ci_polls":1,"api_messages":3,"tokens":123,"tokens_after_last_edit":7,"compactions":{"auto":0,"manual":0}}'
}

@test "plan_gate: counts every ExitPlanMode and only the gate's own denials" {
  cat > "$TR/gate.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"a","name":"ExitPlanMode","input":{"plan":"x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","is_error":true,"content":"PreToolUse:ExitPlanMode hook error: plan-standard: 2 gap(s) for p (infra). Fix the plan file and call ExitPlanMode again."}]}}
{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"b","name":"ExitPlanMode","input":{"plan":"x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","is_error":true,"content":"The user doesn't want to proceed with this tool use."}]}}
{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"c","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c","is_error":true,"content":"PreToolUse:Bash hook error: plan-standard: not this tool"}]}}
EOF
  run bash -c ". '$SO_LIB_DIR/session-outcomes.sh'; so_transcript_metrics '$TR/gate.jsonl' | jq -c .plan_gate"
  assert_output '{"exits":2,"denied":1}'
}

@test "guards: each hook denial counted by the name its reason leads with, PreToolUse and Stop alike" {
  cat > "$TR/guards.jsonl" <<'EOF'
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","is_error":true,"content":"PreToolUse:Bash hook error: block-poll: This foreground loop polls"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","is_error":true,"content":"PreToolUse:Bash hook error: block-poll: `gh run watch` polls"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c","is_error":true,"content":"PreToolUse:ExitPlanMode hook error: plan-standard: 1 gap(s)"}]}}
{"type":"user","message":{"content":"Stop hook feedback:\nfocus-gate: this session edited files"}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"d","is_error":true,"content":"PreToolUse:Bash hook error: Use uv add instead of bare pip."}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"e","is_error":false,"content":"PreToolUse:Bash hook error: block-poll: quoted in output"}]}}
{"type":"user","message":{"content":"please mention Stop hook feedback:\nfocus-gate: in the doc"}}
EOF
  run bash -c ". '$SO_LIB_DIR/session-outcomes.sh'; so_transcript_metrics '$TR/guards.jsonl' | jq -c '[.guards, .plan_gate.denied]'"
  assert_output '[{"block-poll":2,"plan-standard":1,"focus-gate":1},1]'
}

@test "lesson_hits: a sig counts Bash commands only on days after its date; an anchored sig skips a grep for it; a bad regex never crashes" {
  cat > "$TR/sig.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-10-02T09:00:00Z","message":{"id":"m1","content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"killall node"}}]}}
{"type":"assistant","timestamp":"2026-10-03T09:00:00Z","message":{"id":"m2","content":[{"type":"tool_use","id":"b","name":"Bash","input":{"command":"cd x && killall node"}}]}}
{"type":"assistant","timestamp":"2026-10-04T09:00:00Z","message":{"id":"m3","content":[{"type":"tool_use","id":"c","name":"Bash","input":{"command":"killall vite"}}]}}
{"type":"assistant","timestamp":"2026-10-04T10:00:00Z","message":{"id":"m4","content":[{"type":"tool_use","id":"d","name":"Bash","input":{"command":"grep -rn 'killall node' ~/.agent/lessons"}}]}}
{"type":"assistant","timestamp":"2026-10-04T11:00:00Z","message":{"id":"m5","content":[{"type":"tool_use","id":"e","name":"Read","input":{"file_path":"killall"}}]}}
EOF
  sigs='[{"sig":"(^|[;&|]\\s*)killall\\s","since":"2026-10-02"},{"sig":"([","since":"2026-01-01"}]'
  run bash -c ". '$SO_LIB_DIR/session-outcomes.sh'; so_transcript_metrics '$TR/sig.jsonl' '$sigs' | jq -c .lesson_hits"
  assert_success
  assert_output '{"(^|[;&|]\\s*)killall\\s":2}'
  run bash -c ". '$SO_LIB_DIR/session-outcomes.sh'; so_transcript_metrics '$TR/sig.jsonl' | jq -c .lesson_hits"
  assert_output '{}'
}

@test "so_lesson_sigs: one entry per sig with its earliest date, file and bolded claim; lessons without a sig are left out" {
  L="$BATS_TEST_TMPDIR/lessons"; mkdir -p "$L"
  cat > "$L/a.md" <<'EOF'
- **2026-10-02** **Never killall node; name the pid.** It took the shared dev server down. <!-- sig:2026-10-02 (^|[;&|]\s*)killall\s -->
- **2026-10-03** a lesson with no sig
EOF
  cat > "$L/b.md" <<'EOF'
- killall again, written later in another project <!-- sig:2026-10-09 (^|[;&|]\s*)killall\s -->
EOF
  run bash -c ". '$SO_LIB_DIR/session-outcomes.sh'; so_lesson_sigs '$L' | jq -c '.[]'"
  assert_success
  assert_output '{"sig":"(^|[;&|]\\s*)killall\\s","since":"2026-10-02","file":"a.md","claim":"Never killall node; name the pid."}'
  run bash -c ". '$SO_LIB_DIR/session-outcomes.sh'; so_lesson_sigs '$BATS_TEST_TMPDIR/none' | jq -c ."
  assert_output '[]'
}

@test "activity: a commit ends the edit count, for edits made through Bash" {
  cat > "$TR/act.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":100},"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"git add -A && git commit -m x"}}]}}
{"type":"assistant","message":{"id":"m2","usage":{"output_tokens":7},"content":[{"type":"text","text":"done"}]}}
EOF
  run activity_of "$TR/act.jsonl"
  assert_output --partial '"tokens_after_last_edit":7'
}

@test "uses: agents by subagent_type, Skill calls and typed /commands; quoted or tool-result tags do not count" {
  cat > "$TR/uses.jsonl" <<'EOF'
{"type":"user","message":{"content":"<command-name>/one-shot</command-name>"}}
{"type":"user","message":{"content":"<command-message>one-shot</command-message>\n<command-name>/one-shot</command-name>"}}
{"type":"user","message":{"content":"This session is being continued. Earlier: <command-name>/quoted</command-name>"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Agent","input":{"subagent_type":"Explore"}},{"type":"tool_use","id":"b","name":"Task","input":{}},{"type":"tool_use","id":"c","name":"Skill","input":{"skill":"final-pass"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"<command-name>/inner</command-name>"},{"type":"text","text":"<command-name>/inner</command-name>"}]}}
EOF
  run bash -c '. "$SO_LIB_DIR/session-outcomes.sh"; so_transcript_metrics "$1" | jq -c .uses' _ "$TR/uses.jsonl"
  assert_output '{"subagents":{"Explore":1,"general-purpose":1},"skills":{"final-pass":1},"slash":{"one-shot":2}}'
}

@test "activity: a transcript with no usage counts its calls and no tokens, and reaches the row" {
  "$SUBJECT" run
  run jq -sr 'map(select(.session_id == "sess-a"))[0].activity | "\(.tool_calls) \(.tokens)"' "$SO_OUT/proj/2026-10.jsonl"
  assert_output '3 0'
}

@test "time use: the row carries what agent-panel prints, and null when it cannot say" {
  cat > "$SANDBOX/panel" <<'SH'
#!/usr/bin/env bash
[ "$1" = time-use ] || exit 2
case "$2" in
  */a.jsonl) echo '{"work_min":5,"gate_min":60,"test_min":7,"jobs_min":1,"human_min":2,"parked_min":3}' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$SANDBOX/panel"
  AGENT_PANEL="$SANDBOX/panel" "$SUBJECT" run
  run jq -sc 'map(select(.session_id == "sess-a"))[0].time_use | [.gate_min, .test_min, .parked_min]' "$SO_OUT/proj/2026-10.jsonl"
  assert_output '[60,7,3]'
  run jq -s '[.[] | select(.session_id != "sess-a" and .time_use != null)] | length' "$SO_OUT/proj/2026-10.jsonl"
  assert_output '0'
}

@test "time use: a panel that is not installed leaves the field null and the run still writes" {
  AGENT_PANEL="$SANDBOX/no-such-panel" "$SUBJECT" run
  run jq -sc 'map(select(.session_id == "sess-a"))[0] | [.time_use, .transcript]' "$SO_OUT/proj/2026-10.jsonl"
  assert_output '[null,true]'
}

@test "worst ranks the reverted session first and leaves A out" {
  "$SUBJECT" run
  run "$SUBJECT" worst --project proj --days 7 -n 5
  assert_success
  assert_line --index 2 --partial '`sess-b`'
  assert_line --index 2 --partial '5 x 1 reverted'
  refute_output --partial 'sess-a'
}

# bench_fx: fleet-bench stats rows for A (2 nudges, 1 CI red before merge, 30 lines) and for
# a session the registry does not know, which must not become a row.
bench_fx() {
  printf '%s\n' \
    '{"session_id":"sess-a","project":"proj","target":"lab/proj-agent-1:1","plan":"p","phase":"1/1","ticked":1,"minutes":{"WORKING":90,"NEEDS":20},"nudges":2,"escalations":1,"peak_context":150000,"first_epoch":1,"last_epoch":2,"merged":{"prs":1,"lines_added":25,"lines_deleted":5,"ci_runs":3,"ci_reds":1}}' \
    '{"session_id":"sess-zz","project":"other","sampled":false,"merged":null}' > "$BENCH_FX"
}

@test "row: delivery is the bench's stats for the session, null when the bench never saw it" {
  bench_fx
  "$SUBJECT" run
  assert_equal "$(field a '.delivery | [.nudges, .escalations, .minutes.WORKING, .merged.ci_reds, .merged.lines_added] | @tsv')" "$(printf '2\t1\t90\t1\t25')"
  assert_equal "$(field a '.delivery | has("session_id") or has("project")')" false
  assert_equal "$(field b .delivery)" null
  assert_equal "$(lines | grep -c sess-zz)" 0
}

@test "row: a failing bench leaves delivery null, still writes, and says so in the report" {
  printf '#!/usr/bin/env bash\necho boom >&2; exit 3\n' > "$SANDBOX/bin/bench-stub"
  run "$SUBJECT" run
  assert_success
  assert_output --partial 'fleet-bench stats failed: boom'
  assert_equal "$(outcome)" WORKED
  assert_equal "$(field a .delivery)" null
}

@test "row: models, cost by model and uses from the registry and transcript; account from the transcript's config dir" {
  mkdir -p "$HOME/.claude-work/projects/-x"
  cp "$TR/a.jsonl" "$HOME/.claude-work/projects/-x/a.jsonl"
  jq -c --arg t "$HOME/.claude-work/projects/-x/a.jsonl" \
    'if .session_id == "sess-a" then . + {transcript: $t, models: ["m1", "m2"], cost_by_model: {m1: 0.75, m2: 0.25}} else . end' \
    "$SO_SESSIONS/proj/sessions.jsonl" > "$SANDBOX/reg" && mv "$SANDBOX/reg" "$SO_SESSIONS/proj/sessions.jsonl"
  "$SUBJECT" run
  assert_equal "$(field a '[.account, (.models | join(",")), .cost_by_model.m1] | @tsv')" "$(printf 'claude-work\tm1,m2\t0.75')"
  assert_equal "$(field a '.uses | keys | join(",")')" 'skills,slash,subagents'
  assert_equal "$(field b '[.account, .models, .cost_by_model] | tojson')" '[null,null,null]'
}

@test "activity: compactions count compact_boundary records by trigger" {
  cat > "$TR/compact.jsonl" <<'EOF'
{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":160000}}
{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":150000}}
{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":90000}}
{"type":"system","subtype":"turn_duration"}
{"type":"user","message":{"content":"compact_boundary is only a word here"}}
EOF
  run bash -c '. "$SO_LIB_DIR/session-outcomes.sh"; so_transcript_metrics "$1" | jq -c .activity.compactions' _ "$TR/compact.jsonl"
  assert_output '{"auto":2,"manual":1}'
}

@test "friction counts nudges and CI reds before merge; worst --json says why, weights included" {
  bench_fx
  "$SUBJECT" run
  run "$SUBJECT" worst --project proj --days 7 -n 5 --json
  assert_success
  run jq -sc 'map({s: .session_id, friction, why})' <<<"$output"
  assert_output --partial '{"s":"sess-a","friction":3,"why":"2 nudges + 1 CI reds before merge"}'
  assert_output --partial '{"s":"sess-b","friction":5,"why":"5 x 1 reverted"}'
}

@test "card: one session's full card, every section, by an id prefix" {
  bench_fx
  "$SUBJECT" run
  run "$SUBJECT" card sess-a
  assert_success
  assert_line --index 0 --partial 'title a (sess-a), proj, updated 2026-10-19 00:00:'
  assert_line --index 0 --partial 'friction 3, $1, 1 of 1 PRs merged'
  assert_line --index 2 '  Stages    WORKING 1h30, NEEDS 20m; phases ticked 1; nudges 2, escalations 1; peak context 150k'
  assert_line --index 4 '  Delivery  1 merged, 0 open, 0 closed unmerged, 0 reverted (#10); +25 -5 landed; CI 3 runs, 1 red before merge'
  assert_line --index 5 '  Friction  3 = 2 nudges + 1 CI reds before merge'
  assert_line --index 6 --partial '0 compactions (0 auto)'
  run "$SUBJECT" card sess-b
  assert_line --index 2 '  Stages    never sampled by fleet-bench'
  run "$SUBJECT" card sess-a --json
  assert_equal "$(jq -r '[.friction, .why] | @tsv' <<<"$output")" "$(printf '3\t2 nudges + 1 CI reds before merge')"
}

@test "card: a prefix naming no session is 1, more than one is 2 and lists them" {
  "$SUBJECT" run
  run "$SUBJECT" card nope
  assert_failure 1
  run "$SUBJECT" card sess-
  assert_failure 2
  assert_output --partial 'names 4 sessions'
  run "$SUBJECT" card
  assert_failure 2
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
  report | grep -q 'langfuse: 38 score(s) for 4 session(s)'
  assert_equal "$(posted | jq -s 'length')" 38
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-d") | .body.name' | grep -c -E 'interrupts|lessons_written')" 0
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-b" and .body.name == "reverted_7d") | .body.value')" 1
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-c" and .body.name == "friction") | .body.value')" 5
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-a" and .body.name == "prs_merged") | .body.id')" so:sess-a:prs_merged
  assert_equal "$(posted | jq -r 'select(.body.name == "nudges")' | wc -l)" 0   # no bench row, no score
  assert_equal "$(posted | jq -r 'select(.body.sessionId == "sess-d" and .body.name == "friction") | .body.metadata | has("agent")')" true
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
  assert_equal "$(wc -l <<<"$first")" 38
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
  assert_equal "$(posted | jq -s 'length')" 38
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

# ── the work ledger: cost and time onto queue items ──────────────────────────
# queue_stub -- a queue that serves $SANDBOX/items.jsonl to `list` and logs every `set`.
queue_stub() {
  export SO_QUEUE=queue-stub
  printf '#!/usr/bin/env bash\ncase "$1" in list) cat "%s/items.jsonl" ;; set) echo "set ${*:2}" >> "%s/sets.log" ;; *) exit 9 ;; esac\n' \
    "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/queue-stub"
  chmod +x "$SANDBOX/bin/queue-stub"
}

@test "ledger: an item gets the summed cost and work time of the sessions it lists, and only a change is written" {
  queue_stub
  mkdir -p "$SO_OUT/proj"
  # A session observed before, with agent-panel time: not due, still counted.
  jq -cn '{session_id: "sess-old", project: "proj", observed: "2026-10-18T00:00:00Z", updated: 1, cost_usd: 2, time_use: {work_min: 30}}' > "$SO_OUT/proj/2026-10.jsonl"
  {
    jq -cn '{slug: "it-ab", sessions: "sess-a sess-b"}'
    jq -cn '{slug: "it-old", sessions: "sess-old sess-a"}'
    jq -cn '{slug: "it-unseen", sessions: "sess-nobody"}'
    jq -cn '{slug: "it-hand"}'
  } > "$SANDBOX/items.jsonl"
  run "$SUBJECT" run
  assert_success
  assert_equal "$(sort "$SANDBOX/sets.log")" "$(printf 'set it-ab cost_usd=4\nset it-old cost_usd=3 work_min=30')"
  assert_equal "$(outcome)" WORKED
  # Already carrying those values, nothing is written again.
  { jq -cn '{slug: "it-ab", sessions: "sess-a sess-b", cost_usd: "4"}'; jq -cn '{slug: "it-old", sessions: "sess-old sess-a", cost_usd: "3", work_min: "30"}'; } > "$SANDBOX/items.jsonl"
  rm "$SANDBOX/sets.log"
  run "$SUBJECT" run --all
  assert_success
  [ ! -f "$SANDBOX/sets.log" ] || fail "wrote again: $(cat "$SANDBOX/sets.log")"
}

@test "ledger: a queue it cannot read changes nothing and the run still works" {
  export SO_QUEUE=false
  run "$SUBJECT" run
  assert_success
  assert_equal "$(outcome)" WORKED
  assert_equal "$(lines | wc -l)" 3
}

# Judge verdicts: an ask file's judge_* fields and dispatch's verdicts.jsonl, each linked by
# judge_call to its line in calls.jsonl, whose session_id is the trace the score lands on.
judge_fixture() {
  export SO_ASKS="$HOME/.agent/asks" SO_VERDICTS="$HOME/.agent/dispatch/verdicts.jsonl"
  export AGENTCTL_CALLS="$HOME/.local/state/agentctl/calls.jsonl"
  mkdir -p "$SO_ASKS/demo" "${SO_VERDICTS%/*}" "${AGENTCTL_CALLS%/*}"
  printf '%s\n' 'id: ask-1' 'project: demo' 'question: open the PR?' 'judge: take-recommend' \
    'judge_rule: ship_deploy' 'judge_reason: landing is standing authorization' \
    'judge_call: c1' 'judged_at: 2026-10-19T10:00:00-07:00' > "$SO_ASKS/demo/ask-1.md"
  # a gate: never sent to the model, so no call and no score
  printf '%s\n' 'id: ask-2' 'project: demo' 'judge: human' 'judge_rule: gate' \
    'judged_at: 2026-10-19T10:00:00-07:00' > "$SO_ASKS/demo/ask-2.md"
  printf '%s\n' \
    '{"project":"p","lane":"agent","key":"k1","verdict":"skip","rule":"tier3","reason":"tier 3","judge_call":"c2","at":"2026-10-19T11:00:00-07:00"}' \
    '{"project":"p","lane":"agent","key":"k2","verdict":"error","reason":"call failed (exit 7): x","judge_call":"c3","at":"2026-10-19T11:00:00-07:00"}' \
    '{"project":"p","lane":"agent","key":"k3","verdict":"dispatch","reason":"old, no call","at":"2026-10-19T11:00:00-07:00"}' \
    > "$SO_VERDICTS"
  # c3 failed before it had a session: nothing to hang a score on
  printf '%s\n' '{"id":"c1","session_id":"js-1"}' '{"id":"c2","session_id":"js-2"}' '{"id":"c3"}' > "$AGENTCTL_CALLS"
}
judge_posted() { posted | jq -c 'select(.body.dataType == "CATEGORICAL")'; }

@test "langfuse: each judge verdict with a call session is one CATEGORICAL score, named for its agent, valued with its call" {
  lf_setup; judge_fixture
  run "$SUBJECT" run
  assert_success
  report | grep -q 'langfuse: 38 score(s) for 4 session(s); judge: 2 score(s)'
  assert_equal "$(judge_posted | wc -l)" 2
  run judge_posted
  assert_line --partial '"id":"jv:c1:ask-1","sessionId":"js-1","name":"ask-judge","value":"take-recommend"'
  assert_line --partial '"comment":"ship_deploy: landing is standing authorization"'
  assert_line --partial '"id":"jv:c2:p/agent/k1","sessionId":"js-2","name":"dispatch-judge","value":"skip"'
  assert_line --partial '"comment":"tier3: tier 3"'
  # its own mark: the latest verdict's epoch (11:00 at -07:00 is 18:00Z)
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/session-outcomes/langfuse-judge-mark")" "$(date -d 2026-10-19T18:00:00Z +%s)"
}

@test "langfuse: a second run sends no judge score again, a new verdict goes alone, and no verdicts add nothing to the report" {
  lf_setup; judge_fixture
  "$SUBJECT" run
  : > "$BATS_TEST_TMPDIR/lf.posted"
  "$SUBJECT" run
  report | grep -q 'langfuse: nothing new$'
  [ ! -s "$BATS_TEST_TMPDIR/lf.posted" ]
  printf '%s\n' '{"project":"p","lane":"agent","key":"k4","verdict":"dispatch","rule":"fits","reason":"small","judge_call":"c4","at":"2026-10-19T12:00:00-07:00"}' >> "$SO_VERDICTS"
  printf '%s\n' '{"id":"c4","session_id":"js-4"}' >> "$AGENTCTL_CALLS"
  "$SUBJECT" run
  report | grep -q 'langfuse: nothing new; judge: 1 score(s)'
  assert_equal "$(judge_posted | jq -r .body.id)" jv:c4:p/agent/k4
}

@test "langfuse: a failed judge push keeps its mark and says FAILED" {
  lf_setup; judge_fixture
  "$SUBJECT" run
  printf '%s\n' '{"project":"p","lane":"agent","key":"k4","verdict":"dispatch","rule":"fits","reason":"small","judge_call":"c4","at":"2026-10-19T12:00:00-07:00"}' >> "$SO_VERDICTS"
  printf '%s\n' '{"id":"c4","session_id":"js-4"}' >> "$AGENTCTL_CALLS"
  local before; before="$(cat "$AGENTCTL_STATE_DIR/session-outcomes/langfuse-judge-mark")"
  LF_CODE=500 "$SUBJECT" run
  report | grep -q '; judge: FAILED (HTTP 500) after 0 score(s), retried next run'
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/session-outcomes/langfuse-judge-mark")" "$before"
}

# ── opencode sessions and gateway cost ───────────────────────────────────────
# oc_db -- an opencode DB as 2.1.4 writes it, the columns this reads: a root session that stopped
# at $STOP with a child subagent, and one `gh pr create` that printed #10 beside a `gh pr view` of #99.
oc_db() {
  export SO_OPENCODE_DB="$SANDBOX/opencode.db" SO_PROJECT_LIB="$SANDBOX/project-name.sh"
  echo 'resolve_project_name() { basename "$1"; }' > "$SO_PROJECT_LIB"
  local stop_ms=$((STOP * 1000)) create view
  create=$(jq -cn '{content: [{type: "tool", name: "bash", state: {status: "completed", input: {command: "gh pr create --fill"}, content: [{type: "text", text: "https://github.com/o/r/pull/10\n"}]}}]}')
  view=$(jq -cn '{content: [{type: "tool", name: "bash", state: {status: "completed", input: {command: "gh pr view 99"}, content: [{type: "text", text: "https://github.com/o/r/pull/99"}]}}]}')
  sqlite3 "$SO_OPENCODE_DB" <<EOF
CREATE TABLE session_v2 (id text, parent_id text, directory text, title text, model text, summary_files integer, cost real, tokens_input integer, tokens_output integer, tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer, time_created integer, time_updated integer);
CREATE TABLE session_message (session_id text, type text, data text);
INSERT INTO session_v2 VALUES ('ses_root', NULL, '/w/proj', 'fix-menu', '{"id":"claude-sonnet-5","providerID":"litellm"}', 2, 1.5, 10, 20, 0, 100, 30, $((stop_ms - 600000)), $((stop_ms - 5000)));
INSERT INTO session_v2 VALUES ('ses_child', 'ses_root', '/w/proj', 'sub', NULL, NULL, 0.25, 1, 2, 3, 4, 5, $((stop_ms - 300000)), $stop_ms);
INSERT INTO session_message VALUES ('ses_root', 'assistant', '$create');
INSERT INTO session_message VALUES ('ses_child', 'assistant', '$view');
EOF
}

@test "an opencode session gets one line: milliseconds read as seconds, its child rolled in, its own PR, not one it looked at" {
  oc_db
  run "$SUBJECT" run
  assert_success
  assert_equal "$(cat "$SO_OUT"/proj/*.jsonl | jq -rs '[.[].session_id | select(startswith("ses_"))] | join(" ")')" ses_root
  r() { cat "$SO_OUT"/proj/*.jsonl | jq -rs "map(select(.session_id == \"ses_root\")) | last | $1"; }
  assert_equal "$(r '[.harness, .project, .title, .updated_epoch, .duration_s, .cost_usd, .tokens_total, .edits] | join(" ")')" "opencode proj fix-menu $STOP 600 1.75 175 2"
  assert_equal "$(r '[.prs[].number] | join(" ")')" 10
  assert_equal "$(r '.prs_merged')" 1
  assert_equal "$(r '.models | join(" ")')" claude-sonnet-5
}

@test "an opencode session is observed once, and turns final like any other" {
  oc_db
  "$SUBJECT" run >/dev/null
  run "$SUBJECT" run
  assert_success
  assert_equal "$(outcome)" NOOP
  SO_NOW=$((SO_NOW + 8 * 86400)) run "$SUBJECT" run
  assert_success
  assert_equal "$(cat "$SO_OUT"/proj/*.jsonl | jq -rs 'map(select(.session_id == "ses_root")) | last | .final')" true
}

@test "the harness comes from the queue item: claude-lazer on its session, claude with no item, and an opencode item's PR joins" {
  oc_db
  queue_stub
  {
    jq -cn '{slug: "lz", agent: "claude-lazer", sessions: "sess-a"}'
    jq -cn '{slug: "oc", agent: "opencode", sessions: "ses_root", pr: "o/r#11"}'
  } > "$SANDBOX/items.jsonl"
  run "$SUBJECT" run
  assert_success
  assert_equal "$(field a .harness) $(field b .harness)" 'claude-lazer claude'
  assert_equal "$(cat "$SO_OUT"/proj/*.jsonl | jq -rs 'map(select(.session_id == "ses_root")) | last | [.prs[].number] | join(" ")')" '10 11'
}

@test "backfill-harness: a month's rows with no harness get the run's rule, nothing else changes, and the old file stays as .bak" {
  queue_stub
  jq -cn '{slug: "lz", agent: "claude-lazer", sessions: "old-lz"}' > "$SANDBOX/items.jsonl"
  mkdir -p "$SO_OUT/proj" "$SO_OUT/_runner" "$SO_OUT/done"
  {
    jq -cn '{session_id: "old-lz", cost_usd: 2.5, harness: null}'
    jq -cn '{session_id: "old-cc", cost_usd: 1.25}'
    jq -cn '{session_id: "new-oc", cost_usd: 3, harness: "opencode"}'
  } > "$SO_OUT/proj/2026-11.jsonl"
  jq -cn '{session_id: "runner", cost_usd: 0.5, runner: true}' > "$SO_OUT/_runner/2026-11.jsonl"
  jq -cn '{session_id: "other-month", cost_usd: 9}' > "$SO_OUT/proj/2026-10.jsonl"
  jq -cn '{session_id: "all-set", harness: "claude"}' > "$SO_OUT/done/2026-11.jsonl"
  before=$(cat "$SO_OUT"/*/2026-11.jsonl | jq -s 'map(.cost_usd // 0) | add')
  run "$SUBJECT" backfill-harness 2026-11
  assert_success
  assert_output 'session-outcomes: 3 row(s) in 2 file(s) given a harness for 2026-11'
  assert_equal "$(jq -r .harness "$SO_OUT/proj/2026-11.jsonl" | paste -sd' ')" 'claude-lazer claude opencode'
  assert_equal "$(jq -r .harness "$SO_OUT/_runner/2026-11.jsonl")" claude
  assert_equal "$(cat "$SO_OUT"/*/2026-11.jsonl | jq -s 'map(.cost_usd // 0) | add')" "$before"
  assert_equal "$(jq -c 'del(.harness)' "$SO_OUT/proj/2026-11.jsonl" | md5sum)" "$(jq -c 'del(.harness)' "$SO_OUT/proj/2026-11.jsonl.bak" | md5sum)"
  # negative controls: another month and a file with every harness set are not touched
  assert_equal "$(jq -c .harness "$SO_OUT/proj/2026-10.jsonl")" null
  [ ! -e "$SO_OUT/done/2026-11.jsonl.bak" ] && [ ! -e "$SO_OUT/proj/2026-10.jsonl.bak" ]
  run "$SUBJECT" backfill-harness 2026-11
  assert_output 'session-outcomes: 0 row(s) in 0 file(s) given a harness for 2026-11'
}

@test "backfill-harness: a row with no session_id still gets claude; a .bak left from an earlier run leaves that file alone" {
  queue_stub
  : > "$SANDBOX/items.jsonl"
  mkdir -p "$SO_OUT/proj" "$SO_OUT/held"
  jq -cn '{cost_usd: 1}' > "$SO_OUT/proj/2026-11.jsonl"
  chmod 600 "$SO_OUT/proj/2026-11.jsonl"
  jq -cn '{session_id: "old", cost_usd: 2}' > "$SO_OUT/held/2026-11.jsonl"
  echo stale > "$SO_OUT/held/2026-11.jsonl.bak"
  run "$SUBJECT" backfill-harness 2026-11
  assert_success
  assert_output --partial 'held/2026-11.jsonl.bak from an earlier backfill is still there'
  assert_output --partial '1 row(s) in 1 file(s)'
  assert_equal "$(jq -r .harness "$SO_OUT/proj/2026-11.jsonl")" claude
  assert_equal "$(stat -c %a "$SO_OUT/proj/2026-11.jsonl")" 600
  [ ! -e "$SO_OUT/proj/2026-11.jsonl.next" ]
  assert_equal "$(jq -c .harness "$SO_OUT/held/2026-11.jsonl")" null
  assert_equal "$(cat "$SO_OUT/held/2026-11.jsonl.bak")" stale
}

@test "backfill-harness: an unreadable queue changes nothing, and a bad month is a usage error" {
  export SO_QUEUE=false
  mkdir -p "$SO_OUT/proj"
  jq -cn '{session_id: "old", cost_usd: 1}' > "$SO_OUT/proj/2026-11.jsonl"
  run "$SUBJECT" backfill-harness 2026-11
  assert_failure 1
  assert_equal "$(jq -c .harness "$SO_OUT/proj/2026-11.jsonl")" null
  run "$SUBJECT" backfill-harness 11
  assert_failure 2
}

@test "a row names every work item whose sessions list it, in ledger order, and none with no item" {
  queue_stub
  {
    jq -cn '{slug: "first", sessions: "sess-a"}'
    jq -cn '{slug: "second", sessions: "sess-old sess-a"}'
  } > "$SANDBOX/items.jsonl"
  run "$SUBJECT" run
  assert_success
  assert_equal "$(field a '.items | join(" ")')" 'first second'
  assert_equal "$(field b '.items | length')" 0
}

@test "a reshaped opencode DB costs its own rows only: Claude sessions still write, and the report says so" {
  oc_db
  sqlite3 "$SO_OPENCODE_DB" 'ALTER TABLE session_v2 DROP COLUMN cost'
  run "$SUBJECT" run
  assert_success
  assert_output --partial 'opencode rows unread'
  assert_equal "$(outcome)" WORKED
  assert_equal "$(lines | wc -l)" 3
}

# cx_rollouts -- Codex rollout files as 0.164 writes them: a root exec session in /w/proj that ran
# 600s to $STOP, a `gh pr create` that printed #12 beside a `gh pr view` of #99, and a subagent rollout.
cx_rollouts() {
  export SO_CODEX_SESSIONS="$SANDBOX/codex" SO_PROJECT_LIB="$SANDBOX/project-name.sh"
  echo 'resolve_project_name() { basename "$1"; }' > "$SO_PROJECT_LIB"
  mkdir -p "$SO_CODEX_SESSIONS/2026/10/19"
  local t0 t1 d="$SO_CODEX_SESSIONS/2026/10/19"
  t0=$(date -u -d "@$((STOP - 600))" +%Y-%m-%dT%H:%M:%S.000Z); t1=$(date -u -d "@$STOP" +%Y-%m-%dT%H:%M:%S.500Z)
  jq -cn --arg t0 "$t0" --arg t1 "$t1" '
    {timestamp: $t0, type: "session_meta", payload: {id: "cx-root", cwd: "/w/proj", originator: "codex_exec", source: "exec"}},
    {timestamp: $t0, type: "turn_context", payload: {model: "gpt-6.1-sol"}},
    {timestamp: $t0, type: "event_msg", payload: {type: "user_message", message: "fix the menu\nmore"}},
    {timestamp: $t0, type: "response_item", payload: {type: "custom_tool_call", name: "apply_patch", call_id: "p1", input: "x"}},
    {timestamp: $t0, type: "response_item", payload: {type: "function_call", name: "exec_command", call_id: "c1", arguments: ({cmd: "gh pr create --fill"} | tojson)}},
    {timestamp: $t0, type: "response_item", payload: {type: "function_call_output", call_id: "c1", output: "https://github.com/o/r/pull/12\n"}},
    {timestamp: $t0, type: "response_item", payload: {type: "function_call", name: "exec_command", call_id: "c2", arguments: ({cmd: "gh pr view 99"} | tojson)}},
    {timestamp: $t0, type: "response_item", payload: {type: "function_call_output", call_id: "c2", output: "https://github.com/o/r/pull/99"}},
    {timestamp: $t1, type: "event_msg", payload: {type: "token_count", info: {total_token_usage: {input_tokens: 100, cached_input_tokens: 60, output_tokens: 20}}}}
  ' > "$d/rollout-2026-10-19T00-00-00-cx-root.jsonl"
  jq -cn --arg t0 "$t0" '
    {timestamp: $t0, type: "session_meta", payload: {id: "cx-sub", cwd: "/w/proj", source: {subagent: {thread_spawn: {parent_thread_id: "cx-root"}}}}},
    {timestamp: $t0, type: "turn_context", payload: {model: "gpt-6-luna"}},
    {timestamp: $t0, type: "event_msg", payload: {type: "token_count", info: {total_token_usage: {input_tokens: 10, cached_input_tokens: 0, output_tokens: 5}}}}
  ' > "$d/rollout-2026-10-19T00-01-00-cx-sub.jsonl"
}

@test "a codex session gets one line from its rollout: uncached input, its subagent rolled in, its own PR and the queue's" {
  cx_rollouts
  queue_stub
  jq -cn '{slug: "cx", agent: "codex", sessions: "cx-root", pr: "o/r#13"}' > "$SANDBOX/items.jsonl"
  run "$SUBJECT" run
  assert_success
  assert_equal "$(cat "$SO_OUT"/proj/*.jsonl | jq -rs '[.[].session_id | select(startswith("cx-"))] | join(" ")')" cx-root
  r() { cat "$SO_OUT"/proj/*.jsonl | jq -rs "map(select(.session_id == \"cx-root\")) | last | $1"; }
  assert_equal "$(r '[.harness, .project, .title, .updated_epoch, .duration_s, .tokens_total, .edits] | join(" ")')" "codex proj fix the menu $STOP 600 135 1"
  assert_equal "$(r '.cost_usd')" null
  assert_equal "$(r '[.prs[].number] | join(" ")')" '12 13'
  assert_equal "$(r '.models | join(" ")')" 'gpt-6-luna gpt-6.1-sol'
}

@test "two sessions with no transcript side by side still let every PR get its state" {
  cx_rollouts
  jq -cn --arg t0 "$(date -u -d "@$STOP" +%Y-%m-%dT%H:%M:%S.000Z)" '
    {timestamp: $t0, type: "session_meta", payload: {id: "cx-two", cwd: "/w/proj", source: "exec"}}
  ' > "$SO_CODEX_SESSIONS/2026/10/19/rollout-2026-10-19T00-03-00-cx-two.jsonl"
  run "$SUBJECT" run
  assert_success
  refute_output --partial 'parse error'
  assert_equal "$(cat "$SO_OUT"/proj/*.jsonl | jq -rs 'map(select(.session_id == "cx-root")) | last | .prs[0] | "\(.number) \(.state)"')" '12 MERGED'
}

@test "an unreadable codex rollout costs its own line only, and the rest still write" {
  cx_rollouts
  printf '{not json\n' > "$SO_CODEX_SESSIONS/2026/10/19/rollout-2026-10-19T00-02-00-bad.jsonl"
  run "$SUBJECT" run
  assert_success
  assert_equal "$(cat "$SO_OUT"/proj/*.jsonl | jq -rs '[.[].session_id | select(startswith("cx-"))] | join(" ")')" cx-root
}

# gw_ready -- a harness map, a reader key and a gateway serving $SANDBOX/gw.json for any tag.
gw_ready() {
  queue_stub
  printf 'sk-read\n' > "$SANDBOX/reader.key"
  export SO_HARNESSES="$SANDBOX/harnesses.json" SO_CURL=curl-gw
  jq -n --arg k "$SANDBOX/reader.key" '{gateway: {url: "https://gw.test", reader_key_file: $k}}' > "$SO_HARNESSES"
  printf '#!/usr/bin/env bash\ncat > "%s/gw.stdin"; echo "$*" >> "%s/gw.log"\ncat "%s/gw.json"\n' "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/curl-gw"
  chmod +x "$SANDBOX/bin/curl-gw"
  echo '{"metadata":{"total_spend":3.14159,"total_api_requests":12}}' > "$SANDBOX/gw.json"
  {
    jq -cn '{slug: "oc", agent: "opencode", started: "2026-10-18T23:30:00Z", sessions: "sess-a"}'
    jq -cn '{slug: "plain", agent: "claude", started: "2026-10-18T23:30:00Z", sessions: "sess-b"}'
    jq -cn '{slug: "queued", agent: "opencode"}'
  } > "$SANDBOX/items.jsonl"
}

@test "gateway spend lands on the item by its tag and UTC dates, beside cost_usd; the key stays off the command line" {
  gw_ready
  run "$SUBJECT" run
  assert_success
  grep -qx 'set oc gateway_cost_usd=3.1416' "$SANDBOX/sets.log" || fail "no gateway cost: $(cat "$SANDBOX/sets.log")"
  grep -q '^set oc cost_usd=' "$SANDBOX/sets.log" || fail "cost_usd did not write"
  ! grep -q 'plain gateway\|queued gateway' "$SANDBOX/sets.log" || fail "wrote a gateway cost on a claude or unstarted item"
  grep -q 'tags=queue:oc&start_date=2026-10-18&end_date=2026-10-20' "$SANDBOX/gw.log" || fail "wrong query: $(cat "$SANDBOX/gw.log")"
  ! grep -q sk-read "$SANDBOX/gw.log" || fail "key on the command line"
  grep -q 'Bearer sk-read' "$SANDBOX/gw.stdin" || fail "key not handed over"
}

@test "gateway cost does not wait on a new session: the NOOP path writes it too" {
  gw_ready
  "$SUBJECT" run >/dev/null
  : > "$SANDBOX/sets.log"
  echo '{"metadata":{"total_spend":4,"total_api_requests":13}}' > "$SANDBOX/gw.json"
  run "$SUBJECT" run
  assert_success
  assert_equal "$(outcome)" NOOP
  assert_equal "$(cat "$SANDBOX/sets.log")" 'set oc gateway_cost_usd=4'
}

@test "a failed gateway read leaves the field unset, never 0, and cost_usd still writes; so does a tag with no requests" {
  gw_ready
  printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin/curl-gw"
  run "$SUBJECT" run
  assert_success
  ! grep -q gateway_cost_usd "$SANDBOX/sets.log" || fail "a failed read wrote a cost"
  grep -q '^set oc cost_usd=' "$SANDBOX/sets.log" || fail "cost_usd did not write"
  assert_equal "$(outcome)" WORKED
  gw_ready
  : > "$SANDBOX/sets.log"
  echo '{"metadata":{"total_spend":0,"total_api_requests":0}}' > "$SANDBOX/gw.json"
  SO_NOW=$((SO_NOW + 60)) run "$SUBJECT" run
  assert_success
  ! grep -q gateway_cost_usd "$SANDBOX/sets.log" || fail "a tag with no requests wrote \$0"
}
