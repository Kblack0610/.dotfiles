#!/usr/bin/env bats
# judge-eval: every judge lane scored against its ground truth (~/.local/src/docs/judges.md).
# The fixture is written as files, never by running a judge: asks under $HOME/.agent/asks,
# calls.jsonl, dispatch's verdicts.jsonl, a canned agent-queue list and a canned notes ingest record.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  JUDGE_EVAL="$REPO_ROOT/.local/bin/judge-eval"
  export AGENTCTL_CONF_DIR="$HOME/conf" AGENTCTL_CALLS="$HOME/calls.jsonl" FLEET_DISPATCH_DIR="$HOME/dispatch"
  unset AGENT_ASK_DELAY_RULES
  mkdir -p "$AGENTCTL_CONF_DIR" "$FLEET_DISPATCH_DIR" "$HOME/.agent/asks/demo"
  echo 'ask policy v2' > "$HOME/ask-policy.md"; echo 'dispatch policy v1' > "$HOME/dispatch-policy.md"
  printf 'PROMPT="%s"\nDELAY_RULES=fast=0\nSCORE=ask-answers\n' "$HOME/ask-policy.md" > "$AGENTCTL_CONF_DIR/ask-judge.conf"
  printf 'PROMPT="%s"\nSCORE=dispatch-queue\n' "$HOME/dispatch-policy.md" > "$AGENTCTL_CONF_DIR/dispatch-judge.conf"
  echo 'SCORE=unrecorded' > "$AGENTCTL_CONF_DIR/ask-sweep.conf"
  echo 'SCORE=triage-untouched' > "$AGENTCTL_CONF_DIR/inbox-triage.conf"
  echo 'SCORE=plan-dispatched' > "$AGENTCTL_CONF_DIR/inbox-plan.conf"
  echo 'EFFECT=acts' > "$AGENTCTL_CONF_DIR/shepherd.conf"
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
  # notes log --json --days 30, canned
  export JUDGE_EVAL_INGEST_CMD=ingest-stub INGEST="$HOME/ingest.jsonl"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$INGEST" > "$SANDBOX/bin/ingest-stub"
  chmod +x "$SANDBOX/bin/ingest-stub"
  : > "$INGEST"
}

# ago <date -d offset>: that time as the ingest record writes it
ago() { date -d "$1" +%Y-%m-%dT%H:%M:%S.123456789%:z; }

# ev <action> <id> <at> [key=value]...: one ingest record line, by the triager unless a pair says
ev() {
  local a="$1" id="$2" at="$3" kv; shift 3
  { printf '{"action":"%s","id":"%s","ts":"%s","from":"demo","by":"","text":"row %s"}' "$a" "$id" "$at" "$id"
    for kv in "$@"; do jq -cn --arg k "${kv%%=*}" --arg v "${kv#*=}" '{($k): $v}'; done; } | jq -sc add
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

@test "ask-judge: an answer assumed after its wait is counted, and an override on it is an fp" {
  ask_fixture
  ask as_over judge=take-recommend judge_rule=fast answered_by=judge assume_at=2026-11-06T10:00:00-0800 judge_override=no answer=yes
  ask as_ok judge=take-recommend judge_rule=fast answered_by=judge assume_at=2026-11-06T10:00:00-0800 judge_override=none answer=yes
  # a human answer inside the wait is the human's, never an assumed one
  ask as_human judge=take-recommend judge_rule=fast assume_at=2026-11-06T10:00:00-0800 assume_answer=yes answer=no
  run "$JUDGE_EVAL" ask-judge --json
  assert_success
  run jq -c '.agents[0].total | [.assumed, .assumed_overridden]' <<<"$output"
  assert_output '[2,1]'
  run "$JUDGE_EVAL" ask-judge
  assert_line '  assumed 2, 1 overridden'
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
  # row five's skip is recent and nothing started it: pending, not yet a right defer
  assert_line '[6,1,1,2,2,0,0.1]'
  assert_line '[["row three","failed"],["row two","done/failed"]]'
}

@test "kpi --json: the five fleet-bench KPIs over 7 and 28 days, every prompt" {
  ask_fixture
  printf '{"verdict":"error","project":"p","key":"k","at":"%s"}\n' "$(date -Iseconds)" > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run "$JUDGE_EVAL" kpi --json
  assert_success
  run jq -c '[.judge_errors["7d"], .judge_precision["7d"], .ask_answered_pct["7d"], .ask_false_defer_pct["7d"], .ask_unclear_pct["28d"]]' <<<"$output"
  # judge_precision needs 10 scored answers in a rule: none here. 3 of 12 asks were answered live.
  assert_output '[2,null,25,33.3,8.3]'
}

@test "the verdict list: every verdict under any prompt, what it said, why and what you did" {
  ask live1 judge=take-recommend answered_by=judge judge_override=none judge_rule=ship_deploy judge_type=ship_deploy judge_evidence=merged judge_reason=merged
  ask live2 judge=take-recommend answered_by=judge judge_override=no 'answer=yes'
  ask would judge=take-recommend answer=no
  ask pass judge=human judge_rule=knowledge judge_type=human_fact judge_reason=only-you answer=yes
  ask wait judge=human status=pending answer=
  ask old judge=human judge_call=c0 answer=no
  ask err1 judge=error judge_rule= answer=yes
  ask gate judge=human judge_rule=gate judge_call= answer=yes
  # No verdict at all: never shown, so it cannot read as a pass (negative control).
  printf 'id: none\nproject: demo\nquestion: none?\nstatus: pending\n' > "$HOME/.agent/asks/demo/none.md"
  run "$JUDGE_EVAL" log --json
  assert_success
  run jq -c 'sort_by(.id) | map([.id, .said, .you, .score])' <<<"$output"
  assert_output '[["err1","error","yes","-"],["live1","answered","kept","right"],["live2","answered","no","wrong"],["old","passed","no","right"],["pass","passed","yes","needless"],["wait","passed","pending","pending"],["would","would answer","no","wrong"]]'
  run "$JUDGE_EVAL" log passed --json
  run jq -c 'map(.id) | sort' <<<"$output"
  assert_output '["old","pass","wait"]'
  run "$JUDGE_EVAL" log wrong --limit 1 --json
  run jq 'length' <<<"$output"
  assert_output 1
  run "$JUDGE_EVAL" log
  assert_output --partial 'knowledge: only-you'
  assert_output --partial 'ship_deploy  answered  you: kept  right'
  assert_output --partial 'merged  "merged"'
  run "$JUDGE_EVAL" log sideways
  assert_failure 2
  # The dashboards read the same rows, with the week beside them; the scores stay current-prompt.
  run "$JUDGE_EVAL" ask-judge --json
  run jq -c '.agents[0] | [(.verdicts | length), .week.verdicts, .week.live_answered, .week.live_pct, .total.verdicts]' <<<"$output"
  assert_output '[7,7,2,33.3,6]'
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
  ask right judge=human assume_at=2026-11-06T10:00:00-0800 assume_answer=yes assume_disarmed=2026-11-06T09:00:00-0800 answer=yes
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
  # nor the judge's own arm, which would tell it what it said last time
  run grep -c '^assume_[a-z]*: .' "$HOME/replay/blind/demo/right.md"
  assert_output 0
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

# --- the registry and the runner lanes ------------------------------------------------------

@test "the lanes are the confs that name a SCORE: one without it is not a lane" {
  run "$JUDGE_EVAL" --json
  assert_success
  assert_equal "$(jq -c '[.agents[] | [.agent, .score]]' <<<"$output")" \
    '[["ask-judge","ask-answers"],["ask-sweep","unrecorded"],["dispatch-judge","dispatch-queue"],["inbox-plan","plan-dispatched"],["inbox-triage","triage-untouched"]]'
  echo 'SCORE=no-such-source' > "$AGENTCTL_CONF_DIR/shepherd.conf"
  run "$JUDGE_EVAL" shepherd
  assert_success
  assert_line --partial 'truth: unknown SCORE "no-such-source"'
  sed -i '/^SCORE=/d' "$AGENTCTL_CONF_DIR/ask-sweep.conf"
  run "$JUDGE_EVAL" ask-sweep
  assert_failure 2
  assert_output --partial 'no scored lane'
}

@test "inbox-triage: a filed row is right when nothing touches it for 48h; the planner's writes and session filings do not count" {
  {
    ev filed t-kept "$(ago '-3 days')"
    ev filed t-edited "$(ago '-3 days')"; ev edited t-edited "$(ago '-3 days +2 hours')" by=ab12cd34
    ev filed t-late "$(ago '-5 days')"; ev dropped t-late "$(ago '-2 days')"
    ev filed t-moved "$(ago '-4 days')" by=human; ev rehomed t-moved "$(ago '-4 days +1 hour')"
    ev filed t-young "$(ago '-1 hour')"
    ev filed t-session "$(ago '-3 days')" by=ab12cd34
    ev filed t-planned "$(ago '-3 days')"; ev tagged t-planned "$(ago '-3 days +10 min')" 'why=+#size/m'
    ev planned t-planned "$(ago '-3 days +10 min +20 sec')"
  } > "$INGEST"
  run "$JUDGE_EVAL" inbox-triage --json
  assert_success
  # tp: t-kept, t-late (dropped after the window), t-planned; fp: t-edited, t-moved; pending: t-young
  run jq -c '.agents[0] | [.total | .verdicts, .tp, .fp, .pending, .scored, .precision], (.misses | map([.id, .answer]) | sort)' <<<"$output"
  assert_line '[6,3,2,1,5,60]'
  assert_line '[["t-edited","edited by ab12cd34"],["t-moved","rehomed"]]'
}

@test "inbox-triage negative control: every filed row dropped scores 0, with n shown, and the KPI shows it at the bar" {
  local i
  for i in $(seq 1 30); do ev filed "t-$i" "$(ago '-3 days')"; ev dropped "t-$i" "$(ago '-3 days +1 hour')" by=ab12cd34; done > "$INGEST"
  run "$JUDGE_EVAL" inbox-triage --json
  assert_success
  assert_equal "$(jq -c '.agents[0].total | [.scored, .tp, .fp, .precision]' <<<"$output")" '[30,0,30,0]'
  # the score cell: the week at the bar
  assert_equal "$(jq -c '.agents[0].score_7d' <<<"$output")" '{"window":"7d","right":0,"n":30,"pending":0,"value":0,"text":"0% untouched","title":"7d, 0 of 30 right, 0 pending, triage-untouched"}'
  run "$JUDGE_EVAL" inbox-triage
  assert_line --regexp '^  all +30 +0 +100% +30 +0% \[0-11\.4\]'
  run "$JUDGE_EVAL" kpi --json
  assert_equal "$(jq -c '.runner_score_inbox_triage' <<<"$output")" '{"7d":0,"28d":0}'
  # one short of the bar, no score
  sed -i '1,2d' "$INGEST"
  run "$JUDGE_EVAL" kpi --json
  assert_equal "$(jq -c '.runner_score_inbox_triage' <<<"$output")" '{"7d":null,"28d":null}'
  run "$JUDGE_EVAL" inbox-triage --json
  assert_equal "$(jq -c '.agents[0].score_7d | [.n, .value, .text, .title]' <<<"$output")" '[29,null,"n<30","7d, 0 of 29 right, 0 pending, triage-untouched; a percent at 30 rows"]'
  # a lane with no counted outcome has no score word
  run "$JUDGE_EVAL" ask-sweep --json
  assert_equal "$(jq -c '.agents[0].score_7d | [.text, .title]' <<<"$output")" '["-","unrecorded: no counted outcome"]'
}

@test "inbox-plan: a planned row is right when it, or a row it split into, starts before anyone re-splits it" {
  local p; p="$(ago '-2 days')"
  {
    ev planned p-whole "$p"
    ev added p-kid "$(ago '-2 days -10 sec')" 'text=part one #of/p-split'; ev planned p-split "$p"
    ev planned p-resplit "$p"; ev added p-late "$(ago '-1 day')" 'text=more #of/p-resplit' by=ab12cd34
    ev planned p-twice "$p"; ev planned p-twice "$(ago '-1 day')"
    ev planned p-idle "$p"
  } > "$INGEST"
  {
    jq -cn --arg s "$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)" '{from: "board:demo:p-whole", row: "demo:p-whole", started: $s, origin: "run"}'
    jq -cn --arg s "$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)" '{from: "human", row: "demo:p-kid", started: $s}'
    jq -cn --arg s "$(date -u -d '-12 hours' +%Y-%m-%dT%H:%M:%SZ)" '{from: "board:demo:p-resplit", started: $s, origin: "hand"}'
    jq -cn --arg s "$(date -u -d '-12 hours' +%Y-%m-%dT%H:%M:%SZ)" '{from: "board:demo:p-twice", started: $s, origin: "run"}'
  } > "$QUEUE"
  run "$JUDGE_EVAL" inbox-plan --json
  assert_success
  # tp: p-whole, p-split (its child started); fp: p-resplit, p-twice (re-split before the start); pending: p-idle
  run jq -c '.agents[0] | [.total | .verdicts, .tp, .fp, .pending, .precision], (.misses | map(.id) | sort)' <<<"$output"
  assert_line '[5,2,2,1,50]'
  assert_line '["p-resplit","p-twice"]'
}

@test "dispatch-judge: a skip is a false defer when the row is started by hand after its skips began" {
  v() { jq -cn --arg v "$1" --arg k "$2" --arg at "$(date -d "$3" -Iseconds)" '{verdict: $v, project: "p", key: $k, at: $at, rule: "too-big", judge_call: "d1"}'; }
  st() { jq -cn --arg r "p:$1" --arg s "$(date -u -d "$2" +%Y-%m-%dT%H:%M:%SZ)" --arg o "$3" '{from: "human", row: $r, started: $s} + (if $o == "" then {} else {origin: $o} end)'; }
  {
    v skip hand '-5 days'; v skip hand '-1 day'
    v skip button '-5 days'
    v skip run '-5 days'
    v skip resume '-5 days'
    v skip before '-5 days'
    v skip quiet '-5 days'
    v skip young '-1 hour'
  } > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  { st hand '-3 days' ''; st button '-4 days' hand; st run '-4 days' run; st resume '-4 days' resume; st before '-6 days' ''; } > "$QUEUE"
  run "$JUDGE_EVAL" dispatch-judge --json
  assert_success
  # fn: hand (a later skip does not hide the start), button; tn: run, resume, before, quiet; pending: young
  run jq -c '.agents[0].total | [.deferred, .fn, .tn, .pending, .false_defer_pct]' <<<"$output"
  assert_output '[7,2,4,1,33.3]'
  run "$JUDGE_EVAL" kpi --json
  assert_equal "$(jq -c '.dispatch_false_defer_pct' <<<"$output")" '{"7d":33.3,"28d":33.3}'
}
