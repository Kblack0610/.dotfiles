#!/usr/bin/env bats
# judge-eval: every judge lane scored against its ground truth (~/.local/src/docs/judges.md).
# The fixture is written as files, never by running a judge: asks under $HOME/.agent/asks,
# calls.jsonl, dispatch's verdicts.jsonl and a canned agent-queue list.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  JUDGE_EVAL="$REPO_ROOT/.local/bin/judge-eval"
  export AGENTCTL_CONF_DIR="$HOME/conf" AGENTCTL_CALLS="$HOME/calls.jsonl" FLEET_DISPATCH_DIR="$HOME/dispatch"
  unset AGENT_ASK_LIVE_RULES
  mkdir -p "$AGENTCTL_CONF_DIR" "$FLEET_DISPATCH_DIR" "$HOME/.agent/asks/demo"
  echo 'ask policy v2' > "$HOME/ask-policy.md"; echo 'dispatch policy v1' > "$HOME/dispatch-policy.md"
  printf 'PROMPT="%s"\nLIVE_RULES=fast\n' "$HOME/ask-policy.md" > "$AGENTCTL_CONF_DIR/ask-judge.conf"
  printf 'PROMPT="%s"\n' "$HOME/dispatch-policy.md" > "$AGENTCTL_CONF_DIR/dispatch-judge.conf"
  NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
  local ask_sha dispatch_sha
  ask_sha="$(git hash-object "$HOME/ask-policy.md")"; dispatch_sha="$(git hash-object "$HOME/dispatch-policy.md")"
  {
    call c1 ask-judge "$ask_sha" 1000 0.12
    call c0 ask-judge "an-older-prompt" 3000 0.5
    call d1 dispatch-judge "$dispatch_sha" 20000 0.6
  } > "$AGENTCTL_CALLS"
  # agent-queue list --json --state all, canned
  export JUDGE_EVAL_QUEUE_CMD=queue-stub QUEUE="$HOME/queue.jsonl"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$QUEUE" > "$SANDBOX/bin/queue-stub"
  chmod +x "$SANDBOX/bin/queue-stub"
  : > "$QUEUE"
}

# call <id> <agent> <prompt sha> <ms> <cost>: one calls.jsonl line
call() {
  jq -cn --arg i "$1" --arg a "$2" --arg s "$3" --argjson ms "$4" --argjson c "$5" --arg at "$NOW_ISO" \
    '{id: $i, agent: $a, at: $at, duration_ms: $ms, exit: 0, is_error: false, prompt_sha: $s, cost_usd: $c}'
}

# ask <id> <key=value>...: one ask file, judged now by call c1 unless a pair says otherwise
ask() {
  local id="$1" kv; shift
  # agent-ask keeps a key's first value, so the pairs go before the defaults they override
  {
    printf 'id: %s\nproject: demo\nquestion: %s?\n' "$id" "$id"
    for kv in "$@"; do printf '%s: %s\n' "${kv%%=*}" "${kv#*=}"; done
    printf 'options: yes|no\nrecommend: yes\nstatus: answered\nanswered_by: human\n'
    printf 'judge_rule: taste\njudge_call: c1\njudged_at: %s\nanswered_at: %s\n' "$NOW_ISO" "$NOW_ISO"
  } > "$HOME/.agent/asks/demo/$id.md"
}

ask_fixture() {
  ask tp1 judge=take-recommend answer=Yes
  ask fp1 judge=answer:left answer=right
  ask fn1 judge=human answer=yes
  ask tn1 judge=human answer=no
  ask tn2 judge=human 'answer=in session: ok, no then'
  ask unsc judge=take-recommend 'answer=in session: sure thing'
  ask gate judge=human judge_rule=gate judge_call= answer=yes
  ask err1 judge=error judge_rule= answer=yes
  ask old1 judge=take-recommend judge_call=c0 answer=yes
  ask live_over judge=take-recommend judge_rule=fast answered_by=judge judge_override=no answer=yes
  ask live_none judge=take-recommend judge_rule=fast answered_by=judge judge_override=none answer=yes
  ask live_wait judge=take-recommend judge_rule=fast answered_by=judge answer=yes
  ask pend judge=human status=pending answer=
  ask unclear judge=human judge_rule=unclear-ask answer=yes
}

@test "ask-judge: the confusion matrix against the human, live reviews, in-session picks, gates and unclear asks" {
  ask_fixture
  run "$JUDGE_EVAL" ask-judge --json
  assert_success
  run jq -c '.agents[0].total | [.verdicts, .errors, .tp, .fp, .fn, .tn, .pending, .unscorable, .coverage, .precision, .false_defer_pct, .kappa]' <<<"$output"
  # tp: tp1, live_none; fp: fp1, live_over; fn: fn1; tn: tn1, tn2 (the session text names "no");
  # pending: live_wait, pend; unscorable: unsc (free text), unclear (the asker's fault); gate and
  # old1 (another prompt) are out
  assert_output '[12,1,2,2,1,2,2,2,54.5,50,33.3,0.16]'
}

@test "ask-judge: precision carries its 95% Wilson interval, each rule its live flag and distance to the bar" {
  ask_fixture
  run "$JUDGE_EVAL" ask-judge --json
  run jq -c '.agents[0] | [.total.precision_lo, .total.precision_hi, .live,
    (.rules[] | select(.rule == "taste") | [.live, .bar.labels, .bar.need, .bar.met]),
    (.rules[] | select(.rule == "fast") | .live), (.misses | map(.id) | sort)]' <<<"$output"
  assert_output '[15,85,["fast"],[false,2,30,false],true,["fp1","live_over"]]'
  run "$JUDGE_EVAL" ask-judge
  assert_success
  assert_line --regexp '^  taste .* 2/30$'
  assert_line --regexp '^  fast .* live$'
  assert_line --partial 'calls 1, 0 failed'
}

@test "--any-prompt also counts verdicts under an older prompt; the default is the current prompt only" {
  ask_fixture
  run "$JUDGE_EVAL" ask-judge --any-prompt --json
  run jq -c '[.scope.prompt, .agents[0].total.tp, .agents[0].calls.n]' <<<"$output"
  assert_output '["any",3,2]'
  echo 'ask policy v3' > "$HOME/ask-policy.md"
  run "$JUDGE_EVAL" ask-judge
  assert_success
  assert_line '  no verdicts in scope'
}

@test "dispatch-judge: the newest verdict per row against its queue item; a failed line or failed item is wrong" {
  local at; at="$(date -Iseconds)"
  v() { jq -cn --arg v "$1" --arg k "$2" --arg at "${3:-$at}" '{verdict: $v, project: "p", key: $k, at: $at, rule: "fits", judge_call: "d1"}'; }
  {
    v skip 'row two' 2026-01-01T00:00:00-08:00
    v dispatch 'row one'; v dispatch 'row two'; v dispatch 'row three'; v dispatch 'row four'
    v skip 'row five'; v error 'row six'
    jq -cn --arg at "$(date -d '+1 min' -Iseconds)" '{verdict: "failed", project: "p", key: "row three", at: $at}'
  } > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  {
    echo '{"from":"board:p:row one","state":"done","status":"ok"}'
    echo '{"from":"board:p:row two","state":"done","status":"failed"}'
    echo '{"from":"board:p:row four","state":"running","status":""}'
    echo '{"from":"intake:x","state":"done","status":"ok"}'
  } > "$QUEUE"
  run "$JUDGE_EVAL" dispatch-judge --json
  assert_success
  run jq -c '.agents[0] | [.total | .verdicts, .errors, .tp, .fp, .pending, .unscorable, .cost_per_verdict],
    (.misses | map([.id, .answer]) | sort)' <<<"$output"
  assert_line '[6,1,1,2,1,1,0.1]'
  assert_line '[["row three","failed"],["row two","done/failed"]]'
}

@test "kpi --json: the four fleet-bench KPIs over 7 and 28 days, every prompt" {
  ask_fixture
  printf '{"verdict":"error","project":"p","key":"k","at":"%s"}\n' "$(date -Iseconds)" > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run "$JUDGE_EVAL" kpi --json
  assert_success
  run jq -c '[.judge_errors["7d"], .judge_precision["7d"], .ask_false_defer_pct["7d"], .ask_unclear_pct["28d"]]' <<<"$output"
  # judge_precision needs 10 scored answers in a rule: none here
  assert_output '[2,null,33.3,8.3]'
}

@test "nothing to score reads as no verdicts, and an unknown lane is a usage error" {
  run "$JUDGE_EVAL"
  assert_success
  assert_line '  no verdicts in scope'
  assert_line --partial 'truth: not recorded'
  run "$JUDGE_EVAL" no-such-judge
  assert_failure 2
  run "$JUDGE_EVAL" --days 0
  assert_failure 2
}

# --- replay ---------------------------------------------------------------------------------

# replay_stub: a judge that logs its input and scores every ask an answerable ship_deploy.
replay_stub() {
  cat > "$SANDBOX/bin/replay-stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HOME/replay.calls"
printf '{"type":"ship_deploy","decisions":[{"decision":"d",%s}],"reason":"r","answer":""}\n' \
  '"knowledge":{"evidence":"","met":false},"external":{"evidence":"","met":false},"taste":{"evidence":"","met":false},"unclear-ask":{"evidence":"","met":false},"against-precedent":{"evidence":"","met":false},"reversible":{"evidence":"q","met":true},"grounded":{"evidence":"q","met":true}'
SH
  chmod +x "$SANDBOX/bin/replay-stub"
  export JUDGE_EVAL_REPLAY_CMD=replay-stub
}

@test "replay: the real judge runs on blind copies, the real asks do not change, and the score is judge-eval's" {
  replay_stub
  ask right judge=human answer=yes
  ask wrong judge=human answer=no
  ask gated kind=gate judge=human answer=yes
  ask freetext judge=human 'answer=do something else entirely'
  local before; before="$(cat "$HOME"/.agent/asks/demo/*.md | sha256sum)"
  run --separate-stderr "$JUDGE_EVAL" replay --out "$HOME/replay" --json
  assert_success
  assert_equal "$(jq -c '.agents[].rules[] | select(.rule == "ship_deploy") | [.tp, .fp]' <<<"$output")" '[1,1]'
  assert_equal "$(cat "$HOME"/.agent/asks/demo/*.md | sha256sum)" "$before"
  assert_equal "$(grep -c '^question: ' "$HOME/replay.calls")" 2
  # the copy the judge saw has the question and no answer
  run grep -c '^answer: .' "$HOME/replay/blind/demo/right.md"
  assert_output 0
  assert_equal "$(grep -c '^status: pending' "$HOME/replay/blind/demo/right.md")" 1
}

@test "replay: a copy reads the real store's earlier disagreements, never its own answer" {
  replay_stub
  ask early judge=human answer=no created=2026-11-01T10:00:00-0800 answered_at=2026-11-01T11:00:00-0800
  ask late judge=human answer=no created=2026-11-02T10:00:00-0800 answered_at=2026-11-02T11:00:00-0800
  run "$JUDGE_EVAL" replay
  assert_success
  assert_equal "$(grep -c '^early (demo): ' "$HOME/replay.calls")" 1
  assert_equal "$(grep -c '^late (demo): ' "$HOME/replay.calls")" 0
}

@test "replay: an answer left on the copy stops the run before any call (negative control)" {
  replay_stub
  ask right judge=human answer=yes
  JUDGE_EVAL_BLIND_FIELDS=answered_at run "$JUDGE_EVAL" replay
  assert_failure
  assert_output --partial 'survived the blinding'
  [ ! -e "$HOME/replay.calls" ]
}

@test "replay: --limit caps the calls, and nothing labelled is not an error" {
  replay_stub
  ask a judge=human answer=yes created=2026-11-01
  ask b judge=human answer=yes created=2026-11-02
  run "$JUDGE_EVAL" replay --limit 1
  assert_success
  assert_equal "$(grep -c '^question: ' "$HOME/replay.calls")" 1
  rm -f "$HOME"/.agent/asks/demo/*.md
  run "$JUDGE_EVAL" replay
  assert_success
  assert_output --partial 'no labelled asks'
}
