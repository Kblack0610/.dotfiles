#!/usr/bin/env bats
# .config/agent-panel/time-use.conf is the one list of which command is a merge gate, a test run or a
# build. Three readers match it the same way: agent-core's time_use.rs (time by what was running),
# session-outcomes.sh (test_runs and ci_polls) and agent-usage-burn.py (the wait turn). Each used to
# carry its own regex, and they disagreed. tests/fixtures/time-use-commands.tsv is the golden all
# three assert; agent-core's cargo test holds the Rust reader to it.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  GOLDEN="$REPO_ROOT/tests/fixtures/time-use-commands.tsv"
  BURN="$REPO_ROOT/.local/lib/agent-usage-burn.py"
}

@test "session-outcomes.sh and agent-usage-burn.py classify commands as the shared golden says" {
  local want c got n=0
  run python3 -I - "$BURN" "$GOLDEN" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("burn", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("burn", loader))
loader.exec_module(mod)
patterns = mod.time_use_patterns()
for ln in open(sys.argv[2], encoding="utf-8"):
    ln = ln.rstrip("\n")
    if ln and not ln.startswith("#"):
        want, c = ln.split("\t", 1)
        got = mod.time_use_class(c.replace("\\n", "\n"), patterns)
        if got != want:
            print(f"agent-usage-burn.py: want {want}, got {got}: {c}")
EOF
  assert_success
  assert_output ''
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.local/lib/session-outcomes.sh"
  while IFS=$'\t' read -r want c; do
    [[ -z "$want" || "$want" == \#* ]] && continue
    n=$((n + 1))
    got=$(jq -rn --arg c "${c//\\n/$'\n'}" "$SO_PR_JQ"'$c | time_use_class')
    [ "$got" = "$want" ] || { echo "session-outcomes.sh: want $want, got $got: $c"; return 1; }
  done < "$GOLDEN"
  [ "$n" -ge 30 ] || { echo "$n golden cases, want 30"; return 1; }
}

@test "a transcript counts a test run and a CI poll by its time-use.conf class, never prose or a heredoc" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.local/lib/session-outcomes.sh"
  cat > "$SANDBOX/t.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"cat > pr.md <<'EOF'\ncargo test is green\nEOF"}}]}}
{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"b","name":"Bash","input":{"command":"grep -n \"x; pytest\" log"}}]}}
{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"c","name":"Bash","input":{"command":"timeout 300 tests/vendor/bats-core/bin/bats tests/unit/x.bats"}}]}}
{"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"d","name":"Bash","input":{"command":"gh-run-wait 42 checks"}}]}}
EOF
  run so_transcript_metrics "$SANDBOX/t.jsonl"
  assert_success
  assert_equal "$(jq -c '.activity | [.test_runs, .ci_polls]' <<<"$output")" '[1,1]'
}

@test "agent-usage-burn.py: a gate line is a wait, agent-land stays a write, a test run is investigate" {
  run python3 -I - "$BURN" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("burn", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("burn", loader))
loader.exec_module(mod)
p = mod.time_use_patterns()
for c in ("gh run watch 1 --exit-status", "gh-run-wait 42 checks", "agent-land 12 --item x",
          "sleep 30", "scripts/test/run.sh Foo", "rg -n 'gh run watch' docs"):
    print(mod.call_class("Bash", {"command": c}, p), c)
EOF
  assert_success
  assert_output - <<'EOF'
wait gh run watch 1 --exit-status
wait gh-run-wait 42 checks
write agent-land 12 --item x
wait sleep 30
investigate scripts/test/run.sh Foo
investigate rg -n 'gh run watch' docs
EOF
}

# agent-core's open_job_reads_what_a_session_written_wrapper_runs holds time_use.rs to the same
# files: a wrapper script a session wrote is read by its text (agent-11, 2026-11-05: `bash Logs/gate-land.sh`
# ran scripts/test/suite.sh and read as a plain job in the two shell readers).
wrapper_fixture() {
  mkdir -p "$SANDBOX/wd/Logs"
  printf '#!/bin/bash\n# not gh run view here\nset -e\nscripts/test/suite.sh --pr 1\n' > "$SANDBOX/wd/Logs/gate-land.sh"
  printf "sleep 600\necho 'agent-land 1'\n" > "$SANDBOX/wd/Logs/plain.sh"
  printf 'cd x && bats tests/unit\n' > "$SANDBOX/wd/Logs/test.sh"
}

@test "session-outcomes.sh counts a session-written wrapper by the text it runs, the strongest class of a chain" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.local/lib/session-outcomes.sh"
  wrapper_fixture
  local n=0 cmd
  : > "$SANDBOX/t.jsonl"
  for cmd in 'bash Logs/gate-land.sh; echo exit=$?' './Logs/gate-land.sh' 'bash Logs/test.sh; bash Logs/gate-land.sh' \
             'bash Logs/test.sh' 'bash Logs/plain.sh' 'bash Logs/gone.sh' 'echo Logs/gate-land.sh'; do
    n=$((n + 1))
    jq -nc --arg c "$cmd" --arg w "$SANDBOX/wd" --arg id "t$n" \
      '{type: "assistant", cwd: $w, message: {id: "m\($id)", content: [{type: "tool_use", id: $id, name: "Bash", input: {command: $c}}]}}' >> "$SANDBOX/t.jsonl"
  done
  run so_transcript_metrics "$SANDBOX/t.jsonl"
  assert_success
  # gate: 3 (the first, the second, the chain); test: 1; plain, gone and the echoed path: none
  assert_equal "$(jq -c '.activity | [.test_runs, .ci_polls]' <<<"$output")" '[1,3]'
  assert_equal "$(jq -c 'has("wrap")' <<<"$output")" 'false'
}

@test "agent-usage-burn.py reads a session-written wrapper's text: a gate is a wait, a test run is not" {
  wrapper_fixture
  run python3 -I - "$BURN" "$SANDBOX/wd" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("burn", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("burn", loader))
loader.exec_module(mod)
p = mod.time_use_patterns()
for c in ("bash Logs/gate-land.sh; echo exit=$?", "./Logs/gate-land.sh", "bash Logs/test.sh; bash Logs/gate-land.sh",
          "bash Logs/test.sh", "bash Logs/plain.sh", "bash Logs/gone.sh", "echo Logs/gate-land.sh"):
    print(mod.call_class("Bash", {"command": c}, p, sys.argv[2]), c)
print(mod.call_class("Bash", {"command": "bash Logs/gate-land.sh"}, p), "no cwd")
EOF
  assert_success
  assert_output - <<'EOF'
wait bash Logs/gate-land.sh; echo exit=$?
wait ./Logs/gate-land.sh
wait bash Logs/test.sh; bash Logs/gate-land.sh
investigate bash Logs/test.sh
investigate bash Logs/plain.sh
investigate bash Logs/gone.sh
investigate echo Logs/gate-land.sh
investigate no cwd
EOF
}
