#!/usr/bin/env bats
# fleet-shepherd - the scheduled shepherd's gate. Every collaborator is a stub: the state
# document is written by the test, tmux records the pass it would start, the pass's launcher
# runs a stub agentctl-run that records its prompt instead of calling a model, and
# agent-notify records its page instead of reaching a phone.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  sandbox_worlds
  SH="$REPO_ROOT/.local/bin/fleet-shepherd"
  export AGENTCTL_NAME=shepherd-test AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  export FLEET_STATE_FILE="$HOME/state.json" FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  # every run may start a pass; the debounce has its own test
  export FLEET_SHEPHERD_DEBOUNCE_MIN=0
  mkdir -p "$FLEET_SHEPHERD_DIR"
  stub fleet-sessions 'echo "$*" >> "$HOME/sessions.calls"'
  stub fleet-assess 'if [ "${1:-}" = --blocked ]; then printf "%b" "${STUB_BLOCKED:-}"; else echo "verdict: ${STUB_VERDICT:-CLEAR} load 0.5x"; fi'
  stub agent-hold 'printf "%s" "${STUB_HOLDS:-}"'
  stub agent-notify 'echo "$*" >> "$HOME/pages"'
  stub hub '[ "$*" = "needs --json" ] || exit 2; if [ -n "${STUB_NEEDS:-}" ]; then printf "%s" "$STUB_NEEDS"; else echo "{\"needs\":[],\"errors\":[]}"; fi'
  stub watch-companion-loop '[ "$1" = tripped ] && printf "%b" "${STUB_TRIPPED:-}"'
  stub fleet-bench '[ -z "${STUB_BENCH_FAIL:-}" ] || exit 1; if [ "$1" = requests ]; then printf "## Your requests\n\n- ci-cleanup, 1 of 3\n"; elif [ "$1" = eta ]; then printf "%b" "${STUB_ETA:-}"; elif [ "$1" = improve ]; then [ -n "${STUB_IMPROVE:-}" ] || exit 1; printf "%s\n" "$STUB_IMPROVE"; else printf "%b" "${STUB_FINDINGS:-}"; fi'
  stub tmux 'echo "$*" >> "$HOME/tmux.calls"; [ -n "${STUB_TMUX_FAIL:-}" ] && [[ "$*" =~ $STUB_TMUX_FAIL ]] && exit 1
case "$*" in
  *new-window*) echo %9 ;;
  *" list-panes "*) printf "%b" "${STUB_PANES:-}" ;;
  *list-clients*) printf "%b" "${STUB_CLIENTS:-}" ;;
  *pane_in_mode*) echo "${STUB_IN_MODE:-0}" ;;
  *) printf "%b" "${STUB_PANE:-}" ;;
esac'
  stub systemd-run 'echo "$*" >> "$HOME/systemd-run.calls"'
  # The teardown close_refused_sample runs: wind-down.sh close is tested in tests/unit/wind_down.bats.
  stub wind-down 'echo "$*" >> "$HOME/wind-down.calls"; [ -z "${STUB_WD_FAIL:-}" ]'
  export FLEET_WIND_DOWN="$SANDBOX/bin/wind-down"
  stub tmx 'echo "$*" >> "$HOME/tmx.calls"'
  stub tmux-world '[ -z "${STUB_NO_WORLD:-}" ] && [ "$*" = "session hub" ] && echo hub'
  stub claude-acct 'case "$1" in
  room) [ "${2:-}" != --json ] || { printf "%b" "${STUB_ACCTS:-null}"; exit 0; }
        [ -z "${STUB_NO_ROOM:-}" ] || { [ -n "${STUB_ROOM_QUIET:-}" ] || echo "claude-acct: no account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack), runs out Mon 10:40 at this rate" >&2; exit 1; }
        echo "claude-acct: room on alt (2% of its week, 9% gone)" >&2
        printf "%s\n" "${STUB_ROOM-$HOME/.claude-acct2}" ;;
  pick) echo "$HOME/.claude-best" ;;
  trust) echo "$*" >> "$HOME/trust.calls" ;;
esac'
  # `skill <name>` reads the conf's SKILL=; STUB_SKILL stands for it (unset: the conf names none)
  stub agentctl 'if [ "$1" = skill ]; then echo "${STUB_SKILL-fleet-lead}"; else echo "$*" >> "$HOME/agentctl.calls"; fi'
  export PROM_LIB="$HOME/prom-stub.sh"
  cat > "$PROM_LIB" <<'STUB'
prom_q() {
  [ -z "${STUB_PROM_FAIL:-}" ] || return 1
  printf '{"status":"success","data":{"result":%s}}' "${STUB_K3S:-[{\"value\":[0,\"0\"]\}]}"
}
STUB
  # What a pass's launcher execs: it records its arguments and environment, not a model run.
  stub agentctl-run 'printf "%s\n" "$@" > "$HOME/run.args"; printf "%s" "${@: -1}" > "$HOME/last-prompt"
echo "holder=$FLEET_SHEPHERD_HOLDER account=${AGENTCTL_ACCOUNT:-}" >> "$HOME/run.env"'
}
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }
# The real fleet-sessions, by path: the one on PATH is a stub here.
fleet-sessions-real() { "$REPO_ROOT/.local/bin/fleet-sessions" "$@"; }

# doc <sessions-json> [main-json]
doc() { jq -n --argjson s "$1" --argjson m "${2:-[]}" '{schema:1, sessions:$s, main:$m}' > "$FLEET_STATE_FILE"; }

row() { # target bucket nudged escalated [labels-json] [close verdict: default now for DONE, else keep]
  jq -n --arg t "$1" --arg b "$2" --argjson n "$3" --argjson e "$4" --argjson l "${5:-[]}" --arg v "${6:-}" \
    '{target:$t, bucket:$b, nudged:$n, escalated:$e, labels:$l, fact:"f-\($t)", reason:"r-\($t)",
      close:{verdict:(if $v != "" then $v elif $b == "DONE" then "now" else "keep" end), why:"w"}}'
}

# checked: `check` with the routing lines under each due line dropped, for tests of the due lines
checked() { "$SH" check | grep -v '^  -> '; return "${PIPESTATUS[0]}"; }

outcome() { cat "$AGENTCTL_STATE_DIR/shepherd-test/last-outcome"; }

# The pass the last run started, and what its launcher hands claude.
pass_id() { cut -f1 "$FLEET_SHEPHERD_DIR/.pass"; }
prompt() { bash "$FLEET_SHEPHERD_DIR/.pass.sh" && cat "$HOME/last-prompt"; }
starts() { grep -cE 'new-window|respawn-pane' "$HOME/tmux.calls"; }
windows() { grep -c new-window "$HOME/tmux.calls"; }
# live <id> <status> [tmux field]: claude's session file for the pass, on a live pid (this test's).
live() {
  mkdir -p "$HOME/.claude/sessions"
  jq -n --argjson p "$$" --arg s "$1" --arg st "$2" --arg t "${3:-}" '{pid:$p, sessionId:$s, status:$st} + (if $t == "" then {} else {tmux:$t} end)' > "$HOME/.claude/sessions/$1.json"
}
# idle_pass: the running pass was handed nothing (its due count 0), so replacing it scores NOOP.
idle_pass() {
  awk -F'\t' -v OFS='\t' '{ $3 = 0; print }' "$FLEET_SHEPHERD_DIR/.pass" > "$FLEET_SHEPHERD_DIR/.pass.n0" &&
    mv "$FLEET_SHEPHERD_DIR/.pass.n0" "$FLEET_SHEPHERD_DIR/.pass"
}
gone() { rm -f "$HOME/.claude/sessions"/*.json; }
# said <id> <human|assistant> <epoch> <text>: a transcript entry for the pass.
said() {
  mkdir -p "$HOME/.claude/projects/-home"
  jq -nc --arg o "$2" --arg at "$(date -u -d "@$3" +%FT%T.000Z)" --arg text "$4" '
    if $o == "assistant" then {type:"assistant", timestamp:$at, message:{content:[{type:"text", text:$text}]}}
    else {type:"user", turnOrigin:$o, timestamp:$at, message:{content:$text}} end' >> "$HOME/.claude/projects/-home/$1.jsonl"
}
# used <id> <tool>: the pass called a tool.
used() {
  mkdir -p "$HOME/.claude/projects/-home"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s"}]}}\n' "$2" >> "$HOME/.claude/projects/-home/$1.jsonl"
}
# aged <minutes> [file] [column]: that ledger's time (.pass start by default) is that long ago.
aged() {
  local f="$FLEET_SHEPHERD_DIR/${2:-.pass}"
  awk -F'\t' -v t="$(date +%s)" -v m="$1" -v c="${3:-2}" 'BEGIN { OFS = FS } { $c = int(t - m * 60); print }' "$f" > "$HOME/p" && mv "$HOME/p" "$f"
}
ago() { echo $(( $(date +%s) - $1 * 60 )); }

@test "due lists unnudged DONE/LANDED/STALLED, unescalated rows for the human, and nightly red" {
  doc "[$(row a DONE false false), $(row b LANDED true false), $(row c NEEDS false false), $(row d WORKING false false), $(row e STALLED true true)]" \
      '[{"repo":"r1","reason":"ci red","escalated":false},{"repo":"r2","escalated":true}]'
  run "$SH" due
  assert_success
  assert_line 'nightly red: r1 (ci red)'
  assert_line 'nudge DONE: a f-a'
  assert_line 'escalate LANDED: b r-b'
  assert_line 'escalate NEEDS: c r-c'
  refute_output --partial ' d '
  refute_output --partial ' e '
  refute_output --partial r2
}

@test "due tells a session holding its own open ask to close once its verdict is now, and leaves it alone otherwise" {
  own="$(row a DONE false false '[]' after | jq -c '. + {own_asks: 1}')"
  doc "[$own, $(row b LANDED false false | jq -c '. + {own_asks: 2}'), $(row c STALLED false false | jq -c '. + {own_asks: 1}'), $(row d DONE false false),
        $(row e NEEDS false false '[]' now | jq -c '. + {own_asks: 1}'), $(row f STALLED false false '[]' now | jq -c '. + {own_asks: 1}')]"
  run "$SH" due
  refute_output --partial ' a '
  refute_output --partial ' b '
  refute_output --partial ' c '
  assert_line 'nudge DONE: d f-d'
  # The answer reopens it (agent-ask reopen-on-answer), so its window need not wait.
  assert_line 'nudge CLOSE: e f-e'
  assert_line 'nudge CLOSE: f f-f'
  refute_output --partial 'escalate NEEDS: e'
  # A nudged one whose verdict held goes to the human once.
  doc "[$(row e NEEDS true false '[]' now | jq -c '. + {own_asks: 1}')]"
  run "$SH" due
  assert_output 'escalate NEEDS: e r-e'
  doc "[$(jq -c '. + {own_asks: 0, close: {verdict: "now"}}' <<<"$own")]"
  run "$SH" due
  assert_line 'nudge DONE: a f-a'
}

@test "due nudges a DONE row only on a close-now verdict: a keep or worker row is left alone" {
  doc "[$(row a DONE false false '[]' keep), $(row b DONE false false '[]' now), $(row c DONE true false '[]' keep)]"
  run "$SH" due
  assert_line 'nudge DONE: b f-b'
  refute_output --partial 'nudge DONE: a'
  # One nudged before (the same fact survived) still escalates.
  assert_line 'escalate DONE: c r-c'
}

@test "due lists an unescalated shared red with no owner item with the escalate call that answers it" {
  # no item could be filed (the add fails), so the red is the human's, as before ar-623
  stub agent-queue '[ "$1" = add ] && { echo "agent-queue: unknown project: x" >&2; exit 2; }; exit 0'
  jq -n '{schema: 1, sessions: [], main: [], shared: [
      {test: "T.A", id: "shared-T_A", reason: "T.A red on 3 branches in 2h: a, b, c", fact: "SHARED T.A @100", escalated: false},
      {test: "T.B", id: "shared-T_B", reason: "T.B red on 3 branches in 2h: a, b, c", fact: "SHARED T.B @100", escalated: true}]}' > "$FLEET_STATE_FILE"
  run "$SH" due
  assert_success
  assert_line 'shared red: T.A red on 3 branches in 2h: a, b, c; then: fleet-sessions escalate shared-T_A "SHARED T.A @100"'
  refute_output --partial T.B
  # the shepherd role answers it, keyed without the call, as every `; then:` line is
  "$SH" check >/dev/null
  run awk -F'\t' '$4 ~ /^shared red/ { print $2 "|" $1 }' "$FLEET_SHEPHERD_DIR/.due"
  assert_output 'shepherd|shared red: T.A red on 3 branches in 2h: a, b, c'
}

# shared_doc <owners-json> [nudged]: one shared red on three branches, test P.Tests.FooTests.Bar("x")
shared_doc() {
  jq -n --argjson o "$1" --argjson n "${2:-false}" '{schema: 1, sessions: [], main: [], shared: [
    {test: "P.Tests.FooTests.Bar(\"x\")", id: "shared-P_Tests", reason: "P.Tests.FooTests.Bar(\"x\") red on 3 branches in 2h: a, b, c",
     fact: "SHARED P.Tests.FooTests.Bar(\"x\") @100", nudged: $n, escalated: false, owners: $o}]}' > "$FLEET_STATE_FILE"
}

@test "check files one owner item per shared red episode, and the pass tells its sessions once instead of paging" {
  # ar-623: before, every branch's session gated again into a shared red alone and the human was paged
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"
case "$1" in
  list) cat "$HOME/aq.items" 2>/dev/null || true ;;
  add) jq -nc --arg t "${*: -1}" "{slug: \"shared-red-footests\", priority: \"high\", task: \$t}" > "$HOME/aq.items"   # the item it files is live after
       echo "queued shared-red-footests -> /q/x.md" ;;
esac'
  shared_doc '["sid-1","sid-2"]'
  run checked
  assert_success
  assert_line 'nudge SHARED: P.Tests.FooTests.Bar("x") is owned by queue item shared-red-footests; tell sid-1,sid-2: do not gate again on it, merge main once shared-red-footests lands; then: fleet-sessions mark shared-P_Tests "SHARED P.Tests.FooTests.Bar("x") @100"'
  refute_output --partial 'shared red:'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 1
  run grep '^add ' "$HOME/aq.calls"
  assert_output --partial '--project unity-core-playground'
  assert_output --partial '--slug shared-red-FooTests.Bar'
  assert_output --partial 'scripts/test/quarantine.txt'
  grep -q 'owned by queue item shared-red-footests' "$FLEET_SHEPHERD_DIR/log.md"
  # the same episode on the next check files nothing more
  "$SH" check >/dev/null
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 1
  # once the pass marks it (nudged), nothing is due; nothing was paged at any point
  shared_doc '["sid-1","sid-2"]' true
  run "$SH" due
  refute_output --partial FooTests
  [ ! -s "$HOME/pages" ] || ! grep -q FooTests "$HOME/pages"
}

@test "a shared red a live item already names is owned by that item, and one with no sessions in it is not due" {
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"
[ "$1" = list ] && printf "%s\n" "{\"slug\":\"other\",\"task\":\"fix the BarTests class\"}" "{\"slug\":\"nightly-fix-foo-ucp-9\",\"task\":\"fix FooTests.Bar on the nightly\"}"
exit 0'
  shared_doc '["sid-1"]'
  run checked
  assert_line --partial 'is owned by queue item nightly-fix-foo-ucp-9; tell sid-1'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 0
  # negative control: no live session in the failing worktrees, so there is no one to tell
  shared_doc '[]'
  run "$SH" due
  refute_output --partial FooTests
}

@test "an item that names only the test's class, or is low priority, is no owner, so check files one that is (ar-2448)" {
  # 2026-11-14: NetProtocolTests went to gate-spread-lumping, a low gate-spread item citing it as evidence
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"
case "$1" in
  list) printf "%s\n" "{\"slug\":\"cls-only\",\"task\":\"fix FooTests on the nightly\"}" \
          "{\"slug\":\"gate-spread\",\"priority\":\"low\",\"task\":\"the watch lumps FooTests.Bar per-branch reds\"}" \
          "{\"slug\":\"longer\",\"task\":\"fix FooTests.BarBaz\"}" "{\"slug\":\"full-longer\",\"task\":\"P.Tests.FooTests.BarBaz red\"}" ;;
  add) echo "queued shared-red-footests -> /q/x.md" ;;
esac'
  shared_doc '["sid-1"]'
  run checked
  assert_line --partial 'is owned by queue item shared-red-footests; tell sid-1'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 1
}

# shared_round <active-json>: a fresh shared red episode checked against that queue, with no owner on record
shared_round() {
  : > "$FLEET_SHEPHERD_DIR/.shared"; : > "$HOME/aq.calls"
  STUB_ACTIVE="$1" run checked
}

@test "a nightly-fix item naming the class and method apart owns a shared red, so check files nothing new (ar-2523)" {
  # 2026-11-15: nightly-fix-skylinemoves-ucp-1467 named SkylineMovesPlayTests and TheDashFiresOnARoofAndInTheAir apart, and a duplicate was filed
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"
case "$1" in
  list) printf "%s\n" "$STUB_ACTIVE" ;;
  add) echo "queued shared-red-footests -> /q/x.md" ;;
esac'
  shared_doc '["sid-1"]'
  shared_round '{"slug":"nightly-fix-foo-ucp-8","priority":"urgent","task":"fix(test): FooTests, 3 cases red; Bar red solo too"}'
  assert_line --partial 'is owned by queue item nightly-fix-foo-ucp-8; tell sid-1'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 0
  # negative controls: a nightly-fix item naming the method under another class, and an item not nightly-fix naming both, own nothing
  shared_round '{"slug":"nightly-fix-baz-ucp-7","priority":"urgent","task":"fix(test): BazTests, Bar red solo"}'
  assert_line --partial 'is owned by queue item shared-red-footests; tell sid-1'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 1
  shared_round '{"slug":"other","priority":"high","task":"FooTests, Bar red solo"}'
  assert_line --partial 'is owned by queue item shared-red-footests; tell sid-1'
}

@test "a test quarantined on main is owned by the fix item filed for its row, else by the row, so check files nothing new (ar-2523)" {
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"
case "$1" in
  list) printf "%s\n" "$STUB_ACTIVE" ;;
  add) echo "queued shared-red-footests -> /q/x.md" ;;
esac'
  export FLEET_SHEPHERD_QUARANTINE="$HOME/quarantine.json"
  # quarantine <test> <ends> [<lane error>]: main's quarantine as schedules-sync writes it, one entry under row ucp-9
  quarantine() { jq -n --arg t "$1" --arg e "$2" --arg err "${3:-}" '{repos: [{error: (if $err == "" then null else $err end),
    report: {tests: [{test: $t, ends: $e, row: "ucp-9"}]}}]}' > "$FLEET_SHEPHERD_QUARANTINE"; }
  shared_doc '["sid-1"]'
  quarantine 'P.Tests.FooTests.Bar("x")' 2999-01-01
  shared_round '{"slug":"fix-foo","type":"fix","priority":"high","task":"fix the foo yard","row":"unity-core-playground:ucp-9"}'
  assert_line --partial 'is owned by queue item fix-foo; tell sid-1'
  # an item for the row that is no fix item is no owner, so the row is, and sessions merge main at once
  shared_round '{"slug":"foo-epic","type":"feat","priority":"high","task":"the foo yard","row":"unity-core-playground:ucp-9"}'
  assert_line 'nudge SHARED: P.Tests.FooTests.Bar("x") is quarantined on main under board row ucp-9; tell sid-1: do not gate again on it, merge main to take the quarantine; then: fleet-sessions mark shared-P_Tests "SHARED P.Tests.FooTests.Bar("x") @100"'
  grep -q 'owned by board row ucp-9 (quarantined on main)' "$FLEET_SHEPHERD_DIR/log.md"
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 0
  # an entry with no parameters covers every case
  quarantine 'P.Tests.FooTests.Bar' 2999-01-01
  shared_round '{"slug":"other","task":"x"}'
  assert_line --partial 'is quarantined on main under board row ucp-9'
  # once its quarantine ends, the row is dropped and an owner is filed
  quarantine 'P.Tests.FooTests.Bar' 2000-01-01
  STUB_ACTIVE='{"slug":"other","task":"x"}' run checked
  assert_line --partial 'is owned by queue item shared-red-footests; tell sid-1'
  grep -q 'no longer owned by board row ucp-9' "$FLEET_SHEPHERD_DIR/log.md"
  # negative controls: another case quarantined, a lane whose read failed, and no quarantine file own nothing
  quarantine 'P.Tests.FooTests.Bar("y")' 2999-01-01
  shared_round '{"slug":"other","task":"x"}'
  assert_line --partial 'is owned by queue item shared-red-footests; tell sid-1'
  quarantine 'P.Tests.FooTests.Bar("x")' 2999-01-01 'quarantine.py report: ModuleNotFoundError'
  shared_round '{"slug":"other","task":"x"}'
  assert_line --partial 'is owned by queue item shared-red-footests; tell sid-1'
  rm "$FLEET_SHEPHERD_QUARANTINE"
  shared_round '{"slug":"other","task":"x"}'
  assert_line --partial 'is owned by queue item shared-red-footests; tell sid-1'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 1
}

@test "an owner item that landed, or no longer names the test, is dropped and the episode gets a live owner (ar-2448)" {
  # 2026-11-14: NoFlakePatternCountIsAboveItsBaseline stayed owned by fix-red-trains-2627 after it landed
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"
case "$1" in
  list) [ -z "${STUB_ACTIVE:-}" ] || printf "%s\n" "$STUB_ACTIVE" ;;
  add) echo "queued shared-red-footests -> /q/x.md" ;;
esac'
  printf '%s\t%s\n' 'SHARED P.Tests.FooTests.Bar("x") @100' fix-red-trains 'SHARED Gone.Test @50' old-item > "$FLEET_SHEPHERD_DIR/.shared"
  shared_doc '["sid-1"]'
  # while it is live and names the test, it keeps the episode and nothing is filed
  STUB_ACTIVE='{"slug":"fix-red-trains","priority":"urgent","task":"red on FooTests.Bar"}' run checked
  assert_line --partial 'is owned by queue item fix-red-trains; tell sid-1'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 0
  # an episode no longer on the document is pruned with it
  run grep -c 'Gone.Test' "$FLEET_SHEPHERD_DIR/.shared"
  assert_output 0
  # it landed: no longer active, so the line names the item check files instead
  STUB_ACTIVE='{"slug":"unrelated","task":"x"}' run checked
  assert_line --partial 'is owned by queue item shared-red-footests; tell sid-1'
  refute_output --partial fix-red-trains
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 1
  grep -q 'no longer owned by queue item fix-red-trains' "$FLEET_SHEPHERD_DIR/log.md"
  run cat "$FLEET_SHEPHERD_DIR/.shared"
  assert_output "$(printf '%s\t%s' 'SHARED P.Tests.FooTests.Bar("x") @100' shared-red-footests)"
  # negative controls: a queue that cannot be read, or reads empty, keeps every owner as it is and files nothing
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"'
  "$SH" check >/dev/null || true
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"; exit 1'
  "$SH" check >/dev/null || true
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 1
  run cat "$FLEET_SHEPHERD_DIR/.shared"
  assert_output "$(printf '%s\t%s' 'SHARED P.Tests.FooTests.Bar("x") @100' shared-red-footests)"
}

@test "an add whose slug is taken by an item that does not own the test files no owner, so the red escalates (ar-2448)" {
  # slugs are cut to 40 characters, so two long test names can share one; a low item is no owner either
  stub agent-queue 'echo "$*" >> "$HOME/aq.calls"
case "$1" in
  list) echo "{\"slug\":\"shared-red-footests-bar\",\"priority\":\"low\",\"task\":\"P.Tests.FooTests.Bar red\"}" ;;
  add) echo "agent-queue: already in the queue: shared-red-footests-bar" >&2; exit 1 ;;
esac'
  shared_doc '["sid-1"]'
  run checked
  assert_line --partial 'shared red: P.Tests.FooTests.Bar("x") red on 3 branches'
  refute_output --partial 'is owned by'
  [ ! -s "$FLEET_SHEPHERD_DIR/.shared" ]
}

@test "a manual row is never due, and an all-quiet document exits 1" {
  doc "[$(row a STALLED false false '["manual"]'), $(row b WORKING false false)]"
  run "$SH" due
  assert_failure
  assert_output ''
}

@test "a hold on a CLEAR machine and a HOLD machine with no hold are pace decisions" {
  doc "[]"
  STUB_HOLDS=$'unity\t2026\tme\twhy' run "$SH" due
  assert_line 'pace: hold unity while the machine reads CLEAR'
  STUB_VERDICT=HOLD run "$SH" due
  assert_line 'pace: machine reads HOLD with no hold set'
  STUB_VERDICT=HOLD STUB_HOLDS=$'unity\tx' run "$SH" due
  assert_failure
}

@test "a resource hold or a desktop claim on a CLEAR machine is no pace decision; a load hold beside them is (ar-2605)" {
  doc "[]"
  export AGENT_HOLD_DIR="$HOME/.agent/holds"
  stub agent-hold "exec \"$REPO_ROOT/.local/bin/agent-hold\" \"\$@\""
  agent-hold set deskslim-1-ram --by d --kind resource "bad RAM; release after memtest" >/dev/null
  agent-hold claim mac-desktop --by e "store form" >/dev/null
  run "$SH" due
  assert_failure
  refute_output --partial 'pace: hold'
  # a HOLD machine still needs a load hold, whatever resource holds stand
  STUB_VERDICT=HOLD run "$SH" due
  assert_line 'pace: machine reads HOLD with no hold set'
  agent-hold set unity --by c "96 C" >/dev/null
  run "$SH" due
  assert_line 'pace: hold unity while the machine reads CLEAR'
}

# chat <target> <nudged> <escalated> <idle_min> [age_min] [verdict]: a CHAT row, quiet for the lesser of the two, its close verdict keep unless named
chat() { row "$1" CHAT "$2" "$3" '[]' "${6:-keep}" | jq -c --argjson i "$4" --argjson a "${5:-5000}" '. + {idle_min:$i, age_min:$a}'; }

@test "a CHAT row is due only on a close-now verdict (FLEET_IDLE_CLOSE_MIN quiet, fleet-sessions), then nudged once and escalated once" {
  doc "[$(chat a false false 60), $(chat b false false 1440 5000 now), $(chat c false false 2000 30 after)]"
  run "$SH" due
  assert_success
  assert_output 'nudge CHAT: b f-b'
  doc "[$(chat b true false 1500)]"
  run "$SH" due
  assert_output 'escalate CHAT: b r-b'
  doc "[$(chat b true true 3000)]"
  run "$SH" due
  assert_failure
  assert_output ''
}

# crow <sid> <bucket> <verdict> [extra json]: a session row close_sample reads, in pane %<sid> of server lab
crow() { jq -c -n --arg s "$1" --arg b "$2" --arg v "$3" --argjson x "${4:-{\}}" \
  '{session_id:$s, target:"lab/\($s):1", pane:"%\($s)", bucket:$b, nudged:false, escalated:false, labels:[],
    own_asks:0, fact:"\($b) f-\($s)", reason:"r-\($s)", close:{verdict:$v, why:"w"}} + $x'; }
# An idle Claude prompt: the top rule carries the session name, the box holds the glyph and an NBSP.
IDLE=$'text above\n───────────── name ─\n\xe2\x9d\xaf\xc2\xa0\n─────────────\n  bypass permissions on (shift+tab to cycle)'
typed() { grep -F 'send-keys' "$HOME/tmux.calls" 2>/dev/null; }

@test "check types /wind-down auto into a DONE or CLOSE session on a close-now verdict, /wind-down into a CHAT one, then refreshes the document" {
  doc "[$(crow 1 DONE now), $(crow 2 CHAT now), $(crow 3 NEEDS now '{"own_asks":1}')]"
  STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  # Typed, it writes the document again, so cmd_due reads those rows as nudged and hands a pass nothing.
  [ "$(grep -c -- '--write' "$HOME/sessions.calls")" = 2 ]
  run typed
  assert_line '-L lab send-keys -t %1 -l /wind-down auto'
  assert_line '-L lab send-keys -t %2 -l /wind-down'
  assert_line '-L lab send-keys -t %3 -l /wind-down auto'
  [ "$(grep -c 'send-keys -t %. Enter' "$HOME/tmux.calls")" = 3 ]
  # Each is claimed through the one-per-fact mark first.
  grep -qx 'mark 1 DONE f-1' "$HOME/sessions.calls"
  grep -qx 'mark 3 NEEDS f-3' "$HOME/sessions.calls"
  grep -q 'close: lab/1:1 DONE: typed /wind-down auto (DONE f-1)' "$FLEET_SHEPHERD_DIR/log.md"
  grep -q 'close: lab/3:1 CLOSE: typed /wind-down auto' "$FLEET_SHEPHERD_DIR/log.md"
}

@test "check types nothing into a draft, copy mode, a busy or unreadable screen, and leaves the line for the pass" {
  doc "[$(crow 1 DONE now)]"
  draft="${IDLE/$'\xc2\xa0'/$'\xc2\xa0'half a thought}"
  for screen in "$draft" "${IDLE/cycle)/cycle) · esc to interrupt}" 'just a shell prompt $' ''; do
    STUB_PANE="$screen" run checked
    assert_output --partial 'nudge DONE: lab/1:1 [%1] DONE f-1'
  done
  STUB_IN_MODE=1 STUB_PANE="$IDLE" run checked
  assert_output --partial 'nudge DONE: lab/1:1 [%1] DONE f-1'
  [ -z "$(typed)" ]
  ! grep -q '^mark ' "$HOME/sessions.calls"
  # Nothing typed, nothing to refresh: one write per check.
  [ "$(grep -c -- '--write' "$HOME/sessions.calls")" = 5 ]
  # The same row with an empty prompt is typed into: the screen alone held it back.
  STUB_PANE="$IDLE" run checked
  [ -n "$(typed)" ]
}

@test "check types nothing for a manual, nudged, keep or after row, a row another writer marked, or a session off the lease" {
  doc "[$(crow 1 DONE now '{"labels":["manual"]}'), $(crow 2 DONE now '{"nudged":true}'), $(crow 3 DONE keep),
        $(crow 4 CHAT after), $(crow 5 LANDED after), $(crow 6 NEEDS after '{"own_asks":1}')]"
  STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  [ -z "$(typed)" ]
  # mark exits 1 when the fact was already nudged: the pass got there first.
  stub fleet-sessions 'echo "$*" >> "$HOME/sessions.calls"; [ "$1" != mark ]'
  doc "[$(crow 7 DONE now)]"
  STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  [ -z "$(typed)" ]
  # A session that is not the lease holder never acts for the shepherd.
  stub fleet-sessions 'echo "$*" >> "$HOME/sessions.calls"'
  printf 'x %s other-pass x\n' "$(date +%s)" > "$FLEET_SHEPHERD_DIR/.lease"
  printf 'other-pass %s 1 %%9\n' "$(date +%s)" > "$FLEET_SHEPHERD_DIR/.pass"
  CLAUDE_CODE_SESSION_ID=me STUB_PANE="$IDLE" "$SH" check >/dev/null 2>&1 || true
  [ -z "$(typed)" ]
}

closes() { cat "$HOME/wind-down.calls" 2>/dev/null; }
# nudged_ago <hours> <sid>...: the shepherd ledger's nudge time for each session
nudged_ago() { local h="$1" s; shift; for s in "$@"; do printf 'fact: x\nescalated: x\nat: %s\n' "$(date -Iseconds -d "$h hours ago")" > "$FLEET_SHEPHERD_DIR/$s"; done; }

@test "check closes the window of a nudged session whose verdict is still now, then refreshes the document and pages nobody" {
  # Escalated hours ago: without the close, remind_sample would page "close its window".
  nudged_ago 30 1 2
  # The refresh drops a closed session's row, as the real collect does once its window is gone.
  stub fleet-sessions 'echo "$*" >> "$HOME/sessions.calls"
[ "$1" = --write ] && [ -s "$HOME/wind-down.calls" ] || exit 0
jq --rawfile c "$HOME/wind-down.calls" ".sessions |= map(select(.pane as \$p | \$c | contains(\"--pane \(\$p) \") | not))" \
  "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.n" && mv "$FLEET_STATE_FILE.n" "$FLEET_STATE_FILE"'
  row1="$(crow 1 DONE now '{"nudged":true,"escalated":true,"idle_min":2000}')"
  doc "[$row1, $(crow 2 CHAT now '{"nudged":true}')]"
  STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  run closes
  assert_line 'close --server lab --pane %1 --sid 1'
  assert_line 'close --server lab --pane %2 --sid 2'
  grep -q 'close: lab/1:1: closed its window, still quiet after its nudge (DONE f-1)' "$FLEET_SHEPHERD_DIR/log.md"
  [ "$(grep -c -- '--write' "$HOME/sessions.calls")" = 2 ]
  [ -z "$(typed)" ]
  # Closed before the reminder runs, so the human is not paged to close it.
  [ -z "$(grep 'one decision closes it' "$HOME/pages")" ]
  # Negative control: a close that fails (a protected window) is logged once per fact, and the
  # escalation pages the human as before.
  : > "$HOME/wind-down.calls"; doc "[$row1]"
  STUB_WD_FAIL=1 STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  STUB_WD_FAIL=1 STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  [ "$(grep -c 'close: lab/1:1: closing its window failed; the escalation carries it' "$FLEET_SHEPHERD_DIR/log.md")" = 1 ]
  [ "$(grep -c . "$HOME/wind-down.calls")" = 1 ]
  grep -q 'lab/1:1: one decision closes it' "$HOME/pages"
}

@test "check closes no window for a row not yet nudged, nudged under an hour ago, manual, holding its own ask, with phases left, not now, or a pane that is not an idle prompt" {
  nudged_ago 30 2 3 4 5 6 7 8 9
  nudged_ago 0 10
  doc "[$(crow 1 DONE now), $(crow 2 DONE now '{"nudged":true,"labels":["manual"]}'),
        $(crow 3 NEEDS now '{"nudged":true,"own_asks":1}'), $(crow 4 LANDED now '{"nudged":true,"next_phase":"P2"}'),
        $(crow 5 STALLED now '{"nudged":true,"blockers":["next phase: P3 of x.md"]}'),
        $(crow 6 DONE after '{"nudged":true}'), $(crow 7 DONE keep '{"nudged":true}'), $(crow 8 WORKING now '{"nudged":true}'),
        $(crow 10 DONE now '{"nudged":true}')]"
  STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  [ -z "$(closes)" ]
  # The un-nudged row is typed into instead: close_sample owns the first nudge.
  run typed
  assert_line '-L lab send-keys -t %1 -l /wind-down auto'
  # A draft, a busy screen or copy mode holds the close too.
  doc "[$(crow 9 DONE now '{"nudged":true}')]"
  draft="${IDLE/$'\xc2\xa0'/$'\xc2\xa0'half a thought}"
  for screen in "$draft" "${IDLE/cycle)/cycle) · esc to interrupt}" ''; do
    STUB_PANE="$screen" "$SH" check >/dev/null || true
  done
  STUB_IN_MODE=1 STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  [ -z "$(closes)" ]
  # The same row at an idle prompt is closed: only the screen held it.
  STUB_PANE="$IDLE" "$SH" check >/dev/null || true
  [ -n "$(closes)" ]
}

@test "check's re-page for a LANDED row with no next phase names no phase, and no plan when it has none" {
  # Its decision once read "decide phase '-' of -".
  local row='{target: ("lab/" + $s + ":1"), session_id: $s, bucket: "LANDED", reason: "PR #12 merged, tree clean",
    fact: "LANDED PR #12 merged, tree clean", nudged: true, escalated: true, idle_min: 400, labels: [], pr: "12",
    next_phase: null, plan_file: (if $p == "" then null else $p end)}'
  doc "[$(jq -n --arg s s-nophase --arg p /plans/p.md "$row"), $(jq -n --arg s s-noplan --arg p '' "$row")]"
  for s in s-nophase s-noplan; do
    printf 'fact: x\nescalated: x\nat: %s\n' "$(date -Iseconds -d '5 hours ago')" > "$FLEET_SHEPHERD_DIR/$s"
  done
  "$SH" check >/dev/null || true
  run grep 'lab/s-nophase:1: one decision' "$HOME/pages"
  assert_output --partial 'give p.md a ## Phases checklist, or close its window'
  refute_output --partial "phase '"
  run grep 'lab/s-noplan:1: one decision' "$HOME/pages"
  assert_output --partial 'close its window'
  refute_output --partial 'Phases'
}

# prow <target> [dispatch]: a PARKED row, started for that queue row when one is given
prow() { jq -n --arg t "$1" --arg d "${2:-}" '{target:$t, bucket:"PARKED", nudged:false, escalated:false, labels:[], dispatch:(if $d == "" then null else $d end)}'; }

@test "check re-pages an escalated row left unchanged for hours, once per fact per day, naming the decision (ar-455)" {
  ago() { date -Iseconds -d "@$(( $(date +%s) - $1 * 3600 ))"; }
  row() { jq -n --arg sid "$1" --arg b "$2" --arg r "$3" --argjson n "$4" --argjson e "$5" --argjson i "$6" --argjson l "${7:-[]}" \
    '{session_id: $sid, target: "lab/\($sid):1", bucket: $b, reason: $r, fact: "\($b) \($r)", nudged: $n, escalated: $e,
      idle_min: $i, labels: $l, pr: "12", next_phase: "Phase 4: live money", plan_file: "/p/calm-lagoon.md"}'; }
  doc "[$(row s-landed LANDED 'PR #12 merged, tree clean, next phase: Phase 4: live money' true true 400),
        $(row s-green STALLED 'PR #12 green, not merged' true true 400),
        $(row s-young STALLED 'PR #12 CI red' true true 400),
        $(row s-manual DONE 'clean, nothing on the branch' true true 400 '["manual"]'),
        $(row s-open DONE 'clean, nothing on the branch' true false 400),
        $(row s-busy DONE 'clean, nothing on the branch' true true 30)]"
  for s in s-landed s-green s-manual s-open s-busy; do printf 'fact: x\nescalated: x\nat: %s\n' "$(ago 5)" > "$FLEET_SHEPHERD_DIR/$s"; done
  printf 'fact: x\nescalated: x\nat: %s\n' "$(ago 1)" > "$FLEET_SHEPHERD_DIR/s-young"
  "$SH" check >/dev/null || true
  run grep -c 'one decision closes it' "$HOME/pages"
  assert_output 2
  run grep 'lab/s-landed:1: one decision' "$HOME/pages"
  assert_output --partial "decide phase 'Phase 4: live money' of calm-lagoon.md: queue it, hold it on an ask, or defer it"
  assert_output --partial 'tmux:lab/s-landed:1'
  run grep 'lab/s-green:1: one decision' "$HOME/pages"
  assert_output --partial 'merge PR #12 or close it'
  grep -q 'remind: lab/s-green:1' "$FLEET_SHEPHERD_DIR/log.md"
  # The same facts the same day page nothing more.
  "$SH" check >/dev/null || true
  run grep -c 'one decision closes it' "$HOME/pages"
  assert_output 2
  # The next day they page again, once.
  sed -i "s/^$(date +%F)/2000-01-01/" "$FLEET_SHEPHERD_DIR/.remind"
  "$SH" check >/dev/null || true
  "$SH" check >/dev/null || true
  run grep -c 'one decision closes it' "$HOME/pages"
  assert_output 4
  # A page agent-notify refused is not recorded as sent: the next check tries again.
  : > "$FLEET_SHEPHERD_DIR/.remind"
  stub agent-notify 'exit 1'
  "$SH" check >/dev/null || true
  [ ! -s "$FLEET_SHEPHERD_DIR/.remind" ]
}

@test "a parked session on a CLEAR machine with no hold is a pace line; a budget park and a held machine are not" {
  doc "[$(prow lab/p:1), $(prow lab/q:1 'dotfiles: q2'), $(prow lab/r:1 'dotfiles: q3'), $(row m PARKED false false '["manual"]')]"
  printf 'q3\t1\tparked\nq2\t1\textended\n' > "$FLEET_SHEPHERD_DIR/.budget"
  run "$SH" due
  assert_success
  assert_output 'pace: parked lab/p:1, lab/q:1 while the machine reads CLEAR with no hold; then: claude-acct unpark each'
  STUB_HOLDS=$'unity\tx' run "$SH" due
  refute_output --partial 'pace: parked'
  STUB_VERDICT=HOLD run "$SH" due
  assert_output 'pace: machine reads HOLD with no hold set'
  # Negative control: with no budget park on record, q3's session is unparked too.
  rm "$FLEET_SHEPHERD_DIR/.budget"
  run "$SH" due
  assert_output 'pace: parked lab/p:1, lab/q:1, lab/r:1 while the machine reads CLEAR with no hold; then: claude-acct unpark each'
  # One fleet-dispatch preempted (why=preempt) is its pass's to resume, never a pace line; a why=park one still is.
  export CLAUDE_ACCT_PARKED_DIR="$HOME/parked"; mkdir -p "$CLAUDE_ACCT_PARKED_DIR"
  printf 'session=p\ntarget=lab/p:1\nwhy=preempt\n' > "$CLAUDE_ACCT_PARKED_DIR/p"
  printf 'session=q\ntarget=lab/q:1\nwhy=park\n' > "$CLAUDE_ACCT_PARKED_DIR/q"
  run "$SH" due
  assert_output 'pace: parked lab/q:1, lab/r:1 while the machine reads CLEAR with no hold; then: claude-acct unpark each'
}

@test "run with nothing due starts no pass, calls no model, and still refreshes the document" {
  doc "[$(row a WORKING false false)]"
  run "$SH" run
  assert_success
  assert_output 'shepherd-test: nothing due: no new pass'
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
  [ ! -e "$HOME/tmux.calls" ] || assert_equal "$(starts)" 0
  [ ! -e "$HOME/run.args" ]
  assert_equal "$(outcome)" WORKED
  assert_equal "$(cat "$HOME/sessions.calls")" --write
  [ ! -e "$HOME/pages" ]
  # Negative control: one line due starts the pass, and a pass given nothing to move is NOOP
  doc "[$(row a DONE false false)]"
  run "$SH" run
  assert_output --partial 'started pass'
  local id; id="$(pass_id)"; live "$id" idle
  idle_pass
  run "$SH" run
  assert_success
  grep -qP "\t$id\tNOOP\t" "$FLEET_SHEPHERD_DIR/passes.tsv" || fail "$(cat "$FLEET_SHEPHERD_DIR/passes.tsv")"
}

@test "debounce: a line due within DEBOUNCE_MIN of the last pass waits for it, an urgent one does not, and a held line is not the last pass's miss" {
  export FLEET_SHEPHERD_DEBOUNCE_MIN=30
  doc "[$(row a DONE false false)]"
  "$SH" run >/dev/null
  local id; id="$(pass_id)"; live "$id" idle
  # the pass nudged a; b is new, not urgent, and the last pass started under 30 minutes ago
  doc "[$(row a DONE true true), $(row b LANDED false false)]"
  run "$SH" run
  assert_success
  assert_output --partial '1 due, none urgent, last pass 0m ago: no new pass'
  assert_equal "$(pass_id)" "$id"
  assert_equal "$(starts)" 1
  # b was held back, not handed: past the debounce it goes to the next pass plain, not as unhandled
  aged 31
  run "$SH" run
  assert_output --partial 'started pass'
  run prompt
  assert_line 'nudge LANDED: b f-b'
  refute_output --partial 'unhandled:'
  # the pass leaves b as it was: owed, but not urgent, so it waits for the debounce, and that wait is no streak
  live "$(pass_id)" idle
  local second; second="$(pass_id)"
  run "$SH" run
  assert_output --partial 'unhandled: nudge LANDED: b f-b'
  assert_output --partial 'none urgent'
  assert_equal "$(pass_id)" "$second"
  [ ! -e "$FLEET_SHEPHERD_DIR/.unhandled" ]
  # past the debounce the owed line starts a pass, and that check counts
  aged 31
  run "$SH" run
  assert_output --partial 'started pass'
  [ "$(pass_id)" != "$second" ]
  assert_equal "$(cut -f2 "$FLEET_SHEPHERD_DIR/.unhandled")" 1
  # a STALLED row is urgent too, however young the last pass, and so is each red the producers write
  live "$(pass_id)" idle
  doc "[$(row c STALLED false false)]"
  run "$SH" run
  assert_output --partial 'started pass'
  assert_equal "$(starts)" 4
  live "$(pass_id)" idle; idle_pass
  doc "[$(row c STALLED true true)]" '[{"repo":"r1","reason":"ci red","escalated":false}]'
  run "$SH" run
  assert_output --partial 'nightly red: r1'
  assert_output --partial 'started pass'
  assert_equal "$(starts)" 5
}

@test "a settled fleet pages once, and work coming back re-arms the page" {
  doc "[$(row a NEEDS false true)]"
  # Home's list: one row only the human can answer; a machine-answerable ask and a red nightly are not counted
  export STUB_NEEDS='{"needs":[{"kind":"session","score":{"human":true}},{"kind":"ask","score":{"human":false}},{"kind":"nightly"}],"errors":[]}'
  "$SH" run
  "$SH" run
  run cat "$HOME/pages"
  assert_output '-p normal -t shepherd -r file:'"$FLEET_SHEPHERD_DIR"'/log.md fleet settled: 1 need you; rundown in '"$FLEET_SHEPHERD_DIR"'/log.md'
  [ "$(wc -l < "$HOME/pages")" -eq 1 ] || { cat "$HOME/pages"; false; }
  doc "[$(row a WORKING false false)]"
  "$SH" run
  [ ! -e "$FLEET_SHEPHERD_DIR/.settled" ]
}

@test "the pass runs the skill the conf names, and a conf naming none starts no pass" {
  doc "[$(row a DONE false false)]"
  STUB_SKILL=fleet-chief run "$SH" run
  assert_success
  run prompt
  assert_line '/fleet-chief pass'
  refute_output --partial '/fleet-lead'
  # a conf naming none fails the run before the live pass is replaced
  local id; id="$(pass_id)"
  STUB_SKILL= run "$SH" run
  assert_output --partial 'no SKILL= in the'
  assert_equal "$(pass_id)" "$id"
  assert_equal "$(outcome)" FAILED
}

@test "run starts a pass in window shepherd of session hub on the hub server, as the runner, and does not wait for it" {
  doc "[$(row a DONE false false)]"
  run "$SH" run
  assert_success
  assert_output --partial 'started pass'
  local id; id="$(pass_id)"
  [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || fail "no pass id recorded: '$id'"
  grep -qxF -- "-L hub new-window -d -P -F #{pane_id} -t =hub: -n shepherd -c $HOME/.dotfiles bash $(printf %q "$FLEET_SHEPHERD_DIR/.pass.sh")" "$HOME/tmux.calls" ||
    fail "$(cat "$HOME/tmux.calls")"
  assert_equal "$(cut -f4 "$FLEET_SHEPHERD_DIR/.pass")" %9
  # labelled shepherd, so fleet-sessions and the sessions feed list the pass but count it nowhere
  assert_equal "$(cat "$FLEET_SHEPHERD_DIR/labels/$id" | paste -sd' ')" 'manual shepherd'
  grep -qxF -- 'trust hub %9 bypass permissions on' "$HOME/trust.calls"
  grep -qE -- '^-L hub set-option -p -t %9 @shepherd [0-9]+$' "$HOME/tmux.calls"
  grep -qxF -- "report --name shepherd-test item=pass ${id:0:8}: tmux -L hub attach -t hub:shepherd" "$HOME/agentctl.calls"
  # the session exists, so nothing creates it, and a run never closes a session
  [ ! -e "$HOME/tmx.calls" ]
  run grep -c kill-session "$HOME/tmux.calls"
  assert_output 0
  assert_equal "$(outcome)" WORKED
  # The launcher: the observe role, the pass's own session id, the due lines, the runner's lease.
  run prompt
  assert_line '/fleet-lead pass'
  assert_line 'Roles due: shepherd'
  assert_line 'nudge DONE: a f-a'
  run cat "$HOME/run.args"
  assert_line --index 0 --role
  assert_line --index 1 observe
  assert_line --index 2 --session-id
  assert_line --index 3 "$id"
  refute_output --partial --max-turns
  assert_equal "$(cat "$HOME/run.env")" "holder=runner account=$HOME/.claude-acct2"
}

@test "a run while another holds the run lock starts nothing and touches no tmux; with the lock free it starts a pass" {
  doc "[$(row a DONE false false)]"
  # flock holds the lock while the run inside it runs, so that run is the second one.
  run flock -n "$FLEET_SHEPHERD_DIR/.run.lock" "$SH" run
  assert_success
  assert_output --partial 'another run is starting a pass now'
  [ ! -e "$HOME/tmux.calls" ]
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
  # Negative control: the lock free, the same run starts one.
  run "$SH" run
  assert_success
  assert_output --partial 'started pass'
}

@test "no world declares the session: run stops and says so, and touches no tmux" {
  STUB_NO_WORLD=1 run "$REPO_ROOT/.local/bin/fleet-shepherd" run
  assert_failure
  assert_output --partial 'no world declares session hub'
  [ ! -e "$HOME/tmux.calls" ] || fail "called tmux with no server: $(cat "$HOME/tmux.calls")"
}

@test "with no hub session the world's own tmx ensure makes it, and with no tmux server it gets a scope of its own" {
  doc "[$(row a DONE false false)]"
  STUB_TMUX_FAIL='has-session' run "$SH" run
  assert_success
  assert_equal "$(cat "$HOME/tmx.calls")" 'ensure hub hub'
  grep -q -- "-L hub new-window -d -P -F #{pane_id} -t =hub: -n shepherd -c $HOME/.dotfiles bash" "$HOME/tmux.calls"
  [ ! -e "$HOME/systemd-run.calls" ]
  rm "$FLEET_SHEPHERD_DIR/.pass"
  STUB_TMUX_FAIL='has-session|list-sessions' run "$SH" run
  assert_success
  assert_equal "$(cat "$HOME/systemd-run.calls")" '--user --scope --quiet tmx ensure hub hub'
}

@test "a pass recorded in a window of session dotfiles, with no pane on record, is found by the registry and closed there" {
  doc "[$(row a DONE false false)]"
  local old=11111111-2222-3333-4444-555555555555
  printf '%s\t%s\t1\tdotfiles:shepherd\n' "$old" "$(date +%s)" > "$FLEET_SHEPHERD_DIR/.pass"
  live "$old" idle 'dotfiles:@298.%304'
  export STUB_PANES='%304\tdotfiles\t4\tshepherd\t0\n'
  run "$SH" run
  # outside the pass session its pane closes, and the new pass gets the one pass window
  grep -qxF -- '-L hub kill-pane -t %304' "$HOME/tmux.calls"
  assert_equal "$(windows)" 1
  run grep -cE 'kill-session|kill-window|respawn-pane' "$HOME/tmux.calls"
  assert_output 0
}

@test "a registry entry naming another server's pane is not the pass; a shell left in a gone pass's pane is not touched" {
  doc "[$(row a DONE false false)]"
  local old=11111111-2222-3333-4444-555555555555
  printf '%s\t%s\t1\t%%7\n' "$old" "$(date +%s)" > "$FLEET_SHEPHERD_DIR/.pass"
  # pane ids are per server: %7 here is someone else's, in session work
  live "$old" idle 'other:@1.%7'
  STUB_PANES='%7\twork\t1\tvim\t0\n' run "$SH" run
  # the recorded pane is the fallback, and it matched outside the pass session, so it closes there
  grep -qxF -- '-L hub kill-pane -t %7' "$HOME/tmux.calls"
  : > "$HOME/tmux.calls"; gone
  STUB_PANES='%9\thub\t2\tshepherd\t0\n' run "$SH" run
  run grep -cE 'kill-pane|respawn-pane' "$HOME/tmux.calls"
  assert_output 0
  assert_equal "$(windows)" 1
  # Negative control: the same pane dead is the pass's leftover, and the next pass takes it.
  : > "$HOME/tmux.calls"
  STUB_PANES='%9\thub\t2\tshepherd\t1\n' run "$SH" run
  grep -qxF -- "-L hub respawn-pane -k -t %9 -c $HOME/.dotfiles bash $(printf %q "$FLEET_SHEPHERD_DIR/.pass.sh")" "$HOME/tmux.calls"
  assert_equal "$(windows)" 0
}

@test "check prints the skill and section under each due line; the prompt gives the path to read" {
  doc "[$(row a DONE false false)]"
  STUB_HOLDS=$'unity\t2026\tme\twhy' run "$SH" check
  assert_line 'nudge DONE: a f-a'
  assert_line '  -> shepherd (~/.claude/skills/shepherd/SKILL.md), "Verb: nudge"'
  assert_line '  -> fleet-pace (~/.claude/skills/fleet-pace/SKILL.md), "Pace check"'
  STUB_HOLDS=$'unity\t2026\tme\twhy' run "$SH" run
  run prompt
  assert_line '  shepherd: ~/.claude/skills/shepherd/SKILL.md, "Verb: nudge"'
  assert_line '  fleet-pace: ~/.claude/skills/fleet-pace/SKILL.md, "Pace check"'
}

@test "the pass prompt names only the role skills its due lines need" {
  doc "[$(row a DONE false false)]"
  STUB_HOLDS=$'unity\t2026\tme\twhy' run "$SH" run
  run prompt
  assert_line 'Roles due: shepherd, fleet-pace'
  # Negative control: a pace line alone loads no shepherd, and infra alone loads no role.
  doc "[$(row a WORKING false false)]"
  STUB_HOLDS=$'unity\t2026\tme\twhy' run "$SH" run
  run prompt
  assert_line 'Roles due: fleet-pace'
  STUB_K3S='[{"value":[0,"2"]}]' run "$SH" run
  run prompt
  assert_line 'Roles due: none'
  # A starved queue loads fleet-dispatch for its self-heal; any other watch stays fleet-lead's own.
  STUB_TRIPPED='queue-starved\thigh\n' run "$SH" run
  run prompt
  assert_line 'Roles due: fleet-dispatch'
  STUB_TRIPPED='home-k3s-node-disk\turgent\n' run "$SH" run
  run prompt
  assert_line 'Roles due: none'
}

@test "a pass mid-sweep with nobody talking to it: the run starts nothing; past the limit it is STALLED and replaced" {
  doc "[$(row a DONE false false)]"
  "$SH" run
  local id new; id="$(pass_id)"
  live "$id" busy
  run "$SH" run
  assert_success
  assert_output --partial "pass ${id:0:8} is mid-sweep (busy, 0m) and nobody is talking to it: no new pass"
  # one pass, still holding the lease, and nothing counted against it
  assert_equal "$(starts)" 1
  assert_equal "$(pass_id)" "$id"
  assert_equal "$(cut -d' ' -f3 "$FLEET_SHEPHERD_DIR/.lease")" "$id"
  [ ! -e "$FLEET_SHEPHERD_DIR/.unhandled" ]
  assert_equal "$(outcome)" WORKED
  live "$id" waiting
  run "$SH" run
  assert_success
  assert_equal "$(starts)" 1
  # Negative control: past the working limit it is closed STALLED and replaced.
  aged 31
  run "$SH" run
  assert_failure
  assert_equal "$(starts)" 2
  new="$(pass_id)"
  [ "$new" != "$id" ]
  assert_equal "$(outcome)" STALLED
  assert_output --partial "STALLED pass ${id:0:8}: 1 due, 31m, still waiting, replaced"
  grep -qP "\t$id\tSTALLED\tpass ${id:0:8}: 1 due, 31m, still waiting, replaced\t" "$FLEET_SHEPHERD_DIR/passes.tsv" ||
    fail "$(cat "$FLEET_SHEPHERD_DIR/passes.tsv")"
  grep -qxF -- "report --name shepherd-test item=pass ${new:0:8}: tmux -L hub attach -t hub:shepherd" "$HOME/agentctl.calls"
}

@test "a lease holder mid-sweep that the runner did not start stands the run down too; idle, it does not" {
  doc "[$(row a DONE false false)]"
  printf 'interactive %s sid-h\n' "$(ago 5)" > "$FLEET_SHEPHERD_DIR/.lease"
  live sid-h busy
  run "$SH" run
  assert_success
  assert_output --partial 'pass sid-h is mid-sweep (busy, 5m)'
  [ ! -e "$HOME/tmux.calls" ] || assert_equal "$(starts)" 0
  live sid-h idle
  run "$SH" run
  assert_success
  assert_equal "$(starts)" 1
  assert_equal "$(cut -d' ' -f1,3 "$FLEET_SHEPHERD_DIR/.lease")" "runner $(pass_id)"
}

@test "only the pass holding the lease acts: the replaced pass's lease, skip, log, mark and escalate refuse" {
  doc "[$(row a DONE false false)]"
  "$SH" run
  local old new lease
  old="$(pass_id)"
  live "$old" idle
  run "$SH" run
  new="$(pass_id)"
  [ "$new" != "$old" ]
  # the lease names the new pass from the moment it is started, before its claude registers
  assert_equal "$(cut -d' ' -f1,3 "$FLEET_SHEPHERD_DIR/.lease")" "runner $new"
  lease="$(cat "$FLEET_SHEPHERD_DIR/.lease")"
  local v
  for v in holds lease 'skip|nudge DONE: a f-a|left it' 'log|nudged a'; do
    IFS='|' read -r -a argv <<<"$v"
    CLAUDE_CODE_SESSION_ID="$old" run "$SH" "${argv[@]}"
    assert_failure 3
    assert_output --partial "refused: pass ${new:0:8} holds the shepherd lease"
  done
  for v in mark escalate; do
    CLAUDE_CODE_SESSION_ID="$old" run fleet-sessions-real "$v" sid-9 'DONE f'
    assert_failure 3
  done
  [ ! -e "$FLEET_SHEPHERD_DIR/sid-9" ]
  [ ! -e "$FLEET_SHEPHERD_DIR/log.md" ]
  [ ! -s "$FLEET_SHEPHERD_DIR/.skipped" ]
  assert_equal "$(cat "$FLEET_SHEPHERD_DIR/.lease")" "$lease"
  # the holder acts, and so does a shell outside claude
  live "$new" busy
  CLAUDE_CODE_SESSION_ID="$new" run "$SH" skip 'nudge DONE: a f-a' 'left it'
  assert_success
  CLAUDE_CODE_SESSION_ID="$new" run fleet-sessions-real mark sid-9 'DONE f'
  assert_success
  assert_equal "$(sed -n 's/^fact: //p' "$FLEET_SHEPHERD_DIR/sid-9")" 'DONE f'
  run "$SH" log 'from a shell'
  assert_success
  # Negative control: once the holder is gone and its lease window has passed, nobody holds it.
  gone
  CLAUDE_CODE_SESSION_ID="$old" run "$SH" holds
  assert_failure 3
  printf 'runner %s %s\n' "$(ago 31)" "$new" > "$FLEET_SHEPHERD_DIR/.lease"
  CLAUDE_CODE_SESSION_ID="$old" run "$SH" holds
  assert_success
}

@test "a finished pass is scored by its log: WORKED when it logged a move, STALLED when not or when it planned" {
  doc "[$(row a DONE false false)]"
  "$SH" run
  local id; id="$(pass_id)"
  live "$id" idle
  echo "- 10:00 UTC 11-04: nudged a" >> "$FLEET_SHEPHERD_DIR/log.md"
  run "$SH" run
  assert_success
  assert_output --partial "WORKED pass ${id:0:8}: 1 due"
  assert_equal "$(outcome)" WORKED
  [ ! -e "$FLEET_SHEPHERD_DIR/labels/$id" ]
  # Negative controls: the next pass ends without logging, and the one after logs but planned.
  id="$(pass_id)"; gone
  run "$SH" run
  assert_failure
  assert_equal "$(outcome)" STALLED
  id="$(pass_id)"
  echo "- 10:30 UTC 11-04: nudged a" >> "$FLEET_SHEPHERD_DIR/log.md"
  used "$id" ExitPlanMode
  run "$SH" run
  assert_failure
  assert_equal "$(cut -f3 "$FLEET_SHEPHERD_DIR/passes.tsv" | paste -sd' ')" 'WORKED STALLED STALLED'
}

@test "the human talking to a pass: no new pass while it answers or is young; then the next takes its pane, with the conversation" {
  doc "[$(row a DONE false false)]"
  "$SH" run
  local id new; id="$(pass_id)"
  said "$id" human "$(ago 20)" '/fleet-lead pass'
  said "$id" assistant "$(ago 19)" 'swept the fleet'
  said "$id" human "$(ago 10)" 'why is agent-47 stalled?'
  said "$id" assistant "$(ago 9)" 'looking at it'
  said "$id" assistant "$(ago 8)" 'it waits on CI'
  said "$id" human "$(ago 1)" 'and the NEEDS rows?'
  export STUB_PANES='%5\thub\t3\tshepherd\t0\n'
  # answering, past the working limit: the run starts nothing and types nothing
  live "$id" busy 'hub:@3.%5'
  aged 40
  : > "$HOME/tmux.calls"
  run "$SH" run
  assert_success
  assert_output --partial "the human is talking to pass ${id:0:8} (busy, 40m): no new pass"
  assert_equal "$(pass_id)" "$id"
  run grep -cE 'new-window|respawn-pane|send-keys|kill-' "$HOME/tmux.calls"
  assert_output 0
  # idle and young: still theirs
  live "$id" idle 'hub:@3.%5'
  aged 10
  run "$SH" run
  assert_output --partial "the human is talking to pass ${id:0:8} (idle, 10m): no new pass"
  assert_equal "$(pass_id)" "$id"
  # Negative control: idle past the limit, it is replaced in its own pane, never a new window.
  echo '- told the human why agent-47 waits' >> "$FLEET_SHEPHERD_DIR/log.md"
  aged 31
  run "$SH" run
  assert_success
  new="$(pass_id)"
  [ "$new" != "$id" ]
  grep -qxF -- "-L hub respawn-pane -k -t %5 -c $HOME/.dotfiles bash $(printf %q "$FLEET_SHEPHERD_DIR/.pass.sh")" "$HOME/tmux.calls"
  run grep -cE 'new-window|send-keys -t %5 -l|rename-window|kill-' "$HOME/tmux.calls"
  assert_output 0
  assert_equal "$(cut -f4 "$FLEET_SHEPHERD_DIR/.pass")" %5
  assert_equal "$(outcome)" WORKED
  local hand="$FLEET_SHEPHERD_DIR/.handover-$new"
  run prompt
  assert_line "Handover: $hand"
  run cat "$hand"
  assert_line "# Pass ${id:0:8}"
  assert_line 'why is agent-47 stalled?'
  assert_line 'it waits on CI'
  assert_line 'and the NEEDS rows?'
  refute_output --partial 'looking at it'
  refute_output --partial '/fleet-lead pass'
  refute_output --partial 'swept the fleet'
  # The next pass nobody talked to hands nothing on, and the handover file goes with its pass.
  live "$new" idle 'hub:@3.%5'
  echo '- answered the human' >> "$FLEET_SHEPHERD_DIR/log.md"
  run "$SH" run
  assert_success
  run prompt
  refute_output --partial Handover
  [ ! -e "$hand" ] || fail "the handover file outlived its pass"
}

@test "a pass nobody talked to hands nothing over; its own prompt is not the human, and a later turn is" {
  doc "[$(row a DONE false false)]"
  "$SH" run
  local id; id="$(pass_id)"
  said "$id" human "$(ago 2)" '/fleet-lead pass'
  said "$id" assistant "$(ago 1)" 'swept the fleet'
  live "$id" idle
  run "$SH" run
  run prompt
  refute_output --partial Handover
  # Negative control: the human reached the next pass, which is idle past the limit, so it hands over.
  id="$(pass_id)"
  said "$id" human "$(ago 2)" '/fleet-lead pass'
  said "$id" human "$(( $(date +%s) - 5 ))" 'are you there?'
  live "$id" idle
  aged 31
  run "$SH" run
  run prompt
  assert_line --partial 'Handover: '
  run cat "$FLEET_SHEPHERD_DIR/.handover-$(pass_id)"
  assert_line 'are you there?'
}

@test "a pass with only its own prompt is not talked to, even just after local midnight" {
  # `date -d ""` is midnight today, so an empty last human turn once read as the human talking.
  local s=$(( $(date -u +%s) % 86400 - 60 ))
  (( s >= 0 )) || s=$(( s + 86400 ))
  export TZ="TST+$(( s / 3600 )):$(( s % 3600 / 60 )):$(( s % 60 ))"
  [ "$(date +%H:%M)" = 00:01 ] || fail "TZ pin missed: $(date)"
  doc "[$(row a DONE false false)]"
  "$SH" run
  local id; id="$(pass_id)"
  said "$id" human "$(ago 4)" '/fleet-lead pass'
  live "$id" busy
  run "$SH" run
  assert_output --partial 'nobody is talking to it: no new pass'
}

@test "a pass starts on the account claude-acct room names; with none it starts on the best one and pages once, at normal, naming it" {
  doc "[$(row a DONE false false)]"
  STUB_ROOM="$HOME/.claude-acct3" run "$SH" run
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  assert_equal "$(tail -n 1 "$HOME/run.env")" "holder=runner account=$HOME/.claude-acct3"
  # the main account: room says so with an empty line, and no config dir is set
  # a fresh due line each run, and the last pass given nothing: replacing it is NOOP, not STALLED
  idle_pass; doc "[$(row b DONE false false)]"
  STUB_ROOM='' run "$SH" run
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  assert_equal "$(tail -n 1 "$HOME/run.env")" 'holder=runner account=default'
  [ ! -e "$HOME/pages" ]
  # no room anywhere is not a skip: the pass runs, and the human hears about it once
  idle_pass; doc "[$(row c DONE false false)]"
  STUB_NO_ROOM=1 run "$SH" run
  assert_success
  assert_equal "$(starts)" 3
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  assert_equal "$(tail -n 1 "$HOME/run.env")" "holder=runner account=$HOME/.claude-best"
  idle_pass; doc "[$(row d DONE false false)]"
  STUB_NO_ROOM=1 run "$SH" run
  assert_equal "$(starts)" 4
  assert_equal "$(grep -c 'alt is the closest' "$HOME/pages")" 1
  # the pass carries on as before, so it is normal, not high, and it says which account and how far
  local page='Passes keep running on the closest account and dispatch starts nothing new. No account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack), runs out Mon 10:40 at this rate.'
  assert_equal "$(cat "$HOME/pages")" "-p normal -t No account has room for new starts $page"
  # the page channel's budgets from this repo; the prose checker is the private de-ai-writing one
  echo 'raise SystemExit(0)' > "$HOME/prose-check"
  COMMS_CHANNELS="$REPO_ROOT/.config/comms-lint/channels.toml" COMMS_PROSE_CHECK="$HOME/prose-check" \
    run "$REPO_ROOT/.local/bin/comms-lint" --channel page --priority normal --title 'No account has room for new starts' - <<<"$page"
  assert_success
  # a room with nothing to say still pages a whole sentence
  rm -f "$HOME/pages" "$FLEET_SHEPHERD_DIR/.noroom"
  idle_pass; doc "[$(row e DONE false false)]"
  STUB_NO_ROOM=1 STUB_ROOM_QUIET=1 run "$SH" run
  assert_equal "$(cat "$HOME/pages")" '-p normal -t No account has room for new starts Passes keep running on the closest account and dispatch starts nothing new.'
  # room came back: the next time none has any is news again
  run "$SH" run
  STUB_NO_ROOM=1 run "$SH" run
  assert_equal "$(grep -c 'alt is the closest' "$HOME/pages")" 1
}

@test "a pass that cannot start in tmux is FAILED and leaves no pass behind; the next run starts one" {
  doc "[$(row a DONE false false)]"
  STUB_TMUX_FAIL='new-window' run "$SH" run
  assert_failure
  assert_equal "$(outcome)" FAILED
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
  run compgen -G "$FLEET_SHEPHERD_DIR/.proof-*"
  assert_failure
  run "$SH" run
  assert_success
  [ -e "$FLEET_SHEPHERD_DIR/.pass" ]
}

@test "passes lists the pass running now, then the scored ones newest first; open goes to its pane, never starts one" {
  stub fleet-dispatch 'echo "$*" >> "$HOME/dispatch.calls"'
  run "$SH" passes
  assert_success
  assert_output --partial 'no passes yet'
  STUB_TMUX_FAIL='has-session' run "$SH" open
  assert_failure 2
  assert_output --partial 'no pass running'
  doc "[$(row a DONE false false)]"
  "$SH" run
  local first; first="$(pass_id)"
  echo "- moved" >> "$FLEET_SHEPHERD_DIR/log.md"
  "$SH" run
  local id; id="$(pass_id)"
  run "$SH" passes
  assert_line --index 0 --regexp "^[0-9-]+ [0-9:]+	$id	now	1 due, gone$"
  assert_line --index 1 --regexp "	$first	WORKED	"
  # the pane there, in a window a resume named and another session: open goes to it, outside tmux
  STUB_PANES='%9\tdotfiles\t1\tcbf1b878\t0\n' TMUX='' run "$SH" open
  assert_success
  grep -qxF -- '-L hub attach -t =dotfiles:1' "$HOME/tmux.calls"
  # no pane left: open goes to the pass session, and starts or resumes nothing
  : > "$HOME/tmux.calls"
  TMUX='' run "$SH" open
  assert_success
  grep -qxF -- '-L hub attach -t =hub:' "$HOME/tmux.calls"
  # and to the pass window when hub has one
  STUB_PANE='hub\nshepherd\n' TMUX='' run "$SH" open
  assert_success
  grep -qxF -- '-L hub attach -t =hub:shepherd' "$HOME/tmux.calls"
  [ ! -e "$HOME/dispatch.calls" ] || fail "open started a session: $(cat "$HOME/dispatch.calls")"
  run grep -cE 'new-window|new-session|respawn-pane' "$HOME/tmux.calls"
  assert_output 0
}

@test "a lease taken outside claude does not stand the runner down, and the lease moves to the new pass" {
  doc "[$(row a DONE false false)]"
  "$SH" lease
  assert_equal "$(cut -d' ' -f1,3 "$FLEET_SHEPHERD_DIR/.lease")" 'interactive -'
  run "$SH" run
  assert_success
  assert_equal "$(starts)" 1
  assert_equal "$(cut -d' ' -f1,3 "$FLEET_SHEPHERD_DIR/.lease")" "runner $(pass_id)"
}

@test "log - writes one stamped line per stdin line, in one call" {
  echo "earlier" > "$FLEET_SHEPHERD_DIR/log.md"
  run "$SH" log - <<<$'nudged a\n\nskipped b: waits on CI'
  assert_success
  run cat "$FLEET_SHEPHERD_DIR/log.md"
  assert_line --index 1 --regexp '^- [0-9]{2}:[0-9]{2} UTC [0-9-]+: nudged a$'
  assert_line --index 2 --regexp ': skipped b: waits on CI$'
  [ "$(wc -l < "$FLEET_SHEPHERD_DIR/log.md")" -eq 3 ]
}

@test "log stamps each entry with the clock's time and appends to the rundown" {
  # 2026-10-28: a model-typed ledger carried "00:55 UTC 10-29" at a real 23:44 UTC 10-28.
  stub date 'case "$*" in *%F*) echo "2026-10-28 23:44 UTC" ;; *) echo "23:44 UTC 10-28" ;; esac'
  echo "earlier pass" > "$FLEET_SHEPHERD_DIR/log.md"
  run "$SH" log --heading shepherd
  assert_success
  run "$SH" log "GO agent-25: one run of its class"
  assert_success
  run cat "$FLEET_SHEPHERD_DIR/log.md"
  assert_output "earlier pass

## 2026-10-28 23:44 UTC shepherd
- 23:44 UTC 10-28: GO agent-25: one run of its class"
}

@test "log refuses an empty entry" {
  run "$SH" log
  assert_failure
  run "$SH" log --heading
  assert_failure
  [ ! -e "$FLEET_SHEPHERD_DIR/log.md" ]
}

@test "log --rundown keeps each rundown as its own record and points at it from the log" {
  stub date 'case "$*" in *%F*) echo "2026-11-03 19:05 UTC" ;; *) echo "19:05 UTC 11-03" ;; esac'
  run "$SH" log --rundown "what is agent-48 doing" <<< "agent-48 is on enemies-throw-real, PR #1680 red on PlayMode."
  assert_success
  assert_output "$FLEET_SHEPHERD_DIR/rundowns/2026-11-03T1905Z.md"
  run "$SH" log --rundown "fleet at 19:05" <<< "3 working, 1 needs you."
  assert_success
  assert_output "$FLEET_SHEPHERD_DIR/rundowns/2026-11-03T1905Z-2.md"
  run cat "$FLEET_SHEPHERD_DIR/rundowns/2026-11-03T1905Z.md"
  assert_output "# what is agent-48 doing

2026-11-03 19:05 UTC

## Your requests

- ci-cleanup, 1 of 3

agent-48 is on enemies-throw-real, PR #1680 red on PlayMode."
  run cat "$FLEET_SHEPHERD_DIR/log.md"
  assert_output "- 19:05 UTC 11-03: rundown: what is agent-48 doing (rundowns/2026-11-03T1905Z.md)
- 19:05 UTC 11-03: rundown: fleet at 19:05 (rundowns/2026-11-03T1905Z-2.md)"
}

@test "log --rundown keeps the record and says so when the requests cannot be read" {
  export STUB_BENCH_FAIL=1
  run "$SH" log --rundown "fleet" <<< "3 working."
  assert_success
  run cat "$output"
  assert_output --partial "## Your requests"
  assert_output --partial "Unreadable, so this record does not say what the human is waiting on"
  assert_output --partial "3 working."
}

@test "log --rundown refuses a missing title or an empty body and writes nothing" {
  run "$SH" log --rundown <<< "a body"
  assert_failure
  run "$SH" log --rundown "a title" <<< "   "
  assert_failure
  [ ! -e "$FLEET_SHEPHERD_DIR/log.md" ]
  [ -z "$(ls -A "$FLEET_SHEPHERD_DIR/rundowns" 2>/dev/null)" ]
}

# The 2026-10-29 walk, as `fleet-assess --blocked` prints it (tab-separated).
WALK='3546209\t7\t38m\tbfs\tclaude\tunity-core-playground-agent-28\tunity-core-playground-agent-28\twait_for_response\t/mnt/nas/private/immich/upload/thumbs\tbfs -S dfs / -name CutscenePlayer.cs\n'

@test "a process blocked on I/O in two passes in a row is due, and the pass is told which" {
  doc "[$(row d WORKING false false)]"
  export STUB_BLOCKED="$WALK"
  run "$SH" run
  refute_output --partial 'blocked:'
  run "$SH" run
  assert_output --partial 'blocked: pid 3546209 bfs, 7 threads on I/O for 38m, claude session unity-core-playground-agent-28'
  grep -q 'open /mnt/nas/private/immich/upload/thumbs' "$FLEET_SHEPHERD_DIR/.pass.sh"
}

@test "a process blocked in one pass only is not due" {
  doc "[$(row d WORKING false false)]"
  STUB_BLOCKED='4100000\t1\t5m\tUnity\tclaude\ts\tw\t-\t/usr/share/fonts/x.ttf\tUnity\n' run "$SH" run
  STUB_BLOCKED="$WALK" run "$SH" run
  refute_output --partial 'blocked:'
  run "$SH" due
  assert_failure 1
}

@test "infra reads the k3s domain live: red, unreadable and missing report, green and amber do not" {
  run "$SH" infra
  assert_failure
  assert_output ''
  STUB_K3S='[{"value":[0,"1"]}]' run "$SH" infra
  assert_failure
  STUB_K3S='[{"value":[0,"2"]}]' run "$SH" infra
  assert_success
  assert_output 'infra: k3s domain red'
  STUB_PROM_FAIL=1 run "$SH" infra
  assert_success
  assert_output 'infra: Prometheus not answering'
  STUB_K3S='[]' run "$SH" infra
  assert_success
  assert_output 'infra: no k3s status series'
}

@test "a watch with a live red item raises no line; a tag that only contains red still does" {
  doc "[$(row a DONE false false)]"
  stub agent-queue 'printf "%s\n" "{\"tags\":\"red cause:ab\",\"task\":\"check(watch): home-k3s-node-disk tripped since x\"}" "{\"tags\":\"reddish\",\"task\":\"check(watch): queue-starved tripped since x\"}"'
  export STUB_TRIPPED='home-k3s-node-disk\turgent\nqueue-starved\thigh\n' STUB_K3S='[]'
  run "$SH" run
  refute_output --partial 'watch: home-k3s-node-disk'
  assert_output --partial 'watch: queue-starved tripped (high)'
}

@test "a normal or low trip raises no line (its triage item or the human sheet owns it); a held red item owns nothing" {
  doc "[$(row a DONE false false)]"
  stub agent-queue 'printf "%s\n" "{\"tags\":\"red watch cause:ab\",\"state\":\"queued\",\"hold\":\"after x\",\"task\":\"check(watch): home-k3s-node-disk tripped since x\"}"'
  export STUB_TRIPPED='home-k3s-node-disk\turgent\nfleet-thermal\tlow\nneptune-health\tnormal\n' STUB_K3S='[]'
  run "$SH" run
  assert_output --partial 'watch: home-k3s-node-disk tripped (urgent)'
  refute_output --partial 'watch: fleet-thermal'
  refute_output --partial 'watch: neptune-health'
}

@test "a high or urgent trip and a red cluster lead the due lines, ahead of sessions" {
  doc "[$(row a DONE false false)]"
  export STUB_TRIPPED='home-k3s-node-disk\turgent\nqueue-starved\thigh\n' STUB_K3S='[{"value":[0,"2"]}]'
  run "$SH" run
  assert_output --partial $': due\ninfra: k3s domain red\nwatch: home-k3s-node-disk tripped (urgent)\nwatch: queue-starved tripped (high)\nnudge DONE: a'
  refute_output --partial 'unbound variable'
  grep -q 'watch: queue-starved tripped (high)' "$FLEET_SHEPHERD_DIR/.pass.sh"
}

@test "debounce: a line left unhandled is as urgent as the line itself, so an owed red does not wait" {
  export FLEET_SHEPHERD_DEBOUNCE_MIN=30 STUB_TRIPPED='queue-starved\thigh\n'
  doc "[$(row d WORKING false false)]"
  "$SH" run >/dev/null
  live "$(pass_id)" idle
  local id; id="$(pass_id)"
  run "$SH" run
  assert_output --partial 'unhandled: watch: queue-starved tripped (high)'
  assert_output --partial 'started pass'
  [ "$(pass_id)" != "$id" ]
  assert_equal "$(cut -f2 "$FLEET_SHEPHERD_DIR/.unhandled")" 1
}

@test "a standing trip stays due until a pass answers it; a skip lasts while it trips, and a new trip is news" {
  doc "[$(row d WORKING false false)]"
  export STUB_TRIPPED='queue-starved\thigh\n'
  run checked
  assert_output 'watch: queue-starved tripped (high)'
  # Negative control: a pass that only reported it still owes it.
  run checked
  assert_output 'unhandled: watch: queue-starved tripped (high)'
  "$SH" skip 'unhandled: watch: queue-starved tripped (high)' 'started the head item by hand; gate fix in #795'
  run checked
  assert_failure 1
  STUB_TRIPPED='' run checked
  assert_failure 1
  run checked
  assert_output 'watch: queue-starved tripped (high)'
}

@test "a failed pass leaves the trip due, so the next pass reports it" {
  doc "[$(row d WORKING false false)]"
  export STUB_TRIPPED='home-k3s-node-disk\turgent\n'
  "$SH" run
  run "$SH" run
  assert_output --partial 'watch: home-k3s-node-disk tripped (urgent)'
}

@test "a line owed for an hour pages the human high once; a fresh owed line and a skipped one do not" {
  doc "[$(row d WORKING false false)]"
  export STUB_TRIPPED='queue-starved\thigh\n'
  "$SH" check >/dev/null
  "$SH" check >/dev/null                      # owed, but only just
  [ ! -s "$HOME/pages" ]
  # due for an hour is not owed for an hour: the clock starts when a pass was handed the line
  sed -i 's/\t[0-9]*\t/\t1000\t/' "$FLEET_SHEPHERD_DIR/.due"
  "$SH" check >/dev/null
  [ ! -s "$HOME/pages" ]
  sed -i 's/\t[0-9]*$/\t1000/' "$FLEET_SHEPHERD_DIR/.handed"
  "$SH" check >/dev/null
  run cat "$HOME/pages"
  assert_output --partial '-p high -t shepherd unhandled'
  assert_output --partial 'watch: queue-starved tripped (high)'
  sed -i 's/\t[0-9]*$/\t1000/' "$FLEET_SHEPHERD_DIR/.handed"
  "$SH" check >/dev/null
  assert_equal "$(grep -c unhandled "$HOME/pages")" 1
  # once it stops being due the page is spent, so the next hour-long miss pages again
  STUB_TRIPPED='' "$SH" check || true
  run cat "$FLEET_SHEPHERD_DIR/.paged"
  assert_output ''
}

@test "an unhandled session line's page points at the session; a line with no session points nowhere" {
  doc "[$(row hub/demo-agent-1:2 NEEDS false false)]"
  export STUB_TRIPPED='queue-starved\thigh\n'
  "$SH" check >/dev/null
  "$SH" check >/dev/null
  sed -i 's/\t[0-9]*$/\t1000/' "$FLEET_SHEPHERD_DIR/.handed"
  "$SH" check >/dev/null
  run grep 'escalate NEEDS' "$HOME/pages"
  assert_output --partial '-p high -t shepherd -r tmux:hub/demo-agent-1:2 unhandled'
  run grep 'queue-starved' "$HOME/pages"
  refute_output --partial ' -r '
}

# finding <rule> <scope> <class> <epoch> <episode>: one row of `fleet-bench findings --json`
finding() {
  jq -cn --arg r "$1" --arg s "$2" --arg c "$3" --argjson t "$4" --argjson e "$5" \
    '{rule:$r, scope:$s, decision_class:$c, epoch:$t, episode:$e, conclusion:"c-\($r)", cost:"", fact:"\($r) \($s) @\($e)"}'
}

@test "a finding seen on two samples is due and leads the sessions, with the exact ledger call" {
  doc "[$(row a DONE false false)]"
  export STUB_FINDINGS="$(finding starved pool:unity human 200 100)\n"
  run "$SH" due
  assert_success
  assert_line --index 0 'finding human: starved pool:unity: c-starved; then: fleet-sessions escalate finding-starved-pool:unity "starved pool:unity @100 human"'
  assert_line --index 1 'nudge DONE: a f-a'
}

@test "a finding on one sample, and a report-class finding, are not due" {
  doc "[]"
  export STUB_FINDINGS="$(finding throughput-drop repo human 100 100)\n$(finding host-overload mac report 200 100)\n"
  run "$SH" due
  assert_failure
  assert_output ''
}

@test "a recorded finding is not due again, until it is promoted or recurs" {
  doc "[]"
  printf 'escalated: starved pool @100 shepherd\n' > "$FLEET_SHEPHERD_DIR/finding-starved-pool"
  STUB_FINDINGS="$(finding starved pool shepherd 200 100)\n" run "$SH" due
  assert_failure
  STUB_FINDINGS="$(finding starved pool human 300 100)\n" run "$SH" due
  assert_output --partial 'finding human: starved pool'
  STUB_FINDINGS="$(finding starved pool shepherd 900 800)\n" run "$SH" due
  assert_output --partial 'finding shepherd: starved pool'
}

@test "findings that cannot be read say so, instead of reading as none" {
  doc "[]"
  STUB_BENCH_FAIL=1 STUB_IMPROVE='{"kpi":"revert_rate","value":0.25,"threshold":0.1,"bound":"max","last":null}' run "$SH" due
  assert_success
  assert_output --partial 'fleet-bench findings unreadable'
  refute_output --partial 'improve:'
}

@test "the KPI improve picks is one line after the sessions, with no value in it, so its key holds while the number moves" {
  doc "[$(row a DONE false false)]"
  STUB_IMPROVE='{"kpi":"revert_rate","value":0.25,"threshold":0.1,"bound":"max","last":null}' run "$SH" due
  assert_success
  assert_line --index 0 'nudge DONE: a f-a'
  assert_line --index 1 'improve: revert_rate past max 0.1, no live row; then: fleet-bench improve file revert_rate "<defined fix>", or claim revert_rate <id> when a row or plan already owns it'
  local first="$output"
  STUB_IMPROVE='{"kpi":"revert_rate","value":0.4,"threshold":0.1,"bound":"max","last":null}' run "$SH" due
  assert_equal "$output" "$first"
  # the row that did not move it is named
  STUB_IMPROVE='{"kpi":"revert_rate","value":0.25,"threshold":0.1,"bound":"max","last":{"subject":"ar-139","verdict":"flat"}}' run "$SH" due
  assert_line --index 1 --partial 'improve: revert_rate past max 0.1, no live row, last ar-139 flat; then:'
  # Negative control: nothing due from improve (exit 1) is no line.
  doc "[]"
  run "$SH" due
  assert_failure
  refute_output --partial 'improve:'
}

@test "an improve line is fleet-lead's own: it loads no role skill" {
  doc "[]"
  STUB_IMPROVE='{"kpi":"revert_rate","value":0.25,"threshold":0.1,"bound":"max","last":null}' run "$SH" run
  run prompt
  assert_line 'Roles due: none'
  assert_output --partial 'improve: revert_rate past max 0.1'
}

# phase <sid> <reason> <phase_min> <age_min> [done/total] [bucket] [activity]: a state row (WORKING,
# activity the reason's first word, unless given) and its `fleet-bench eta --json` row
phase() {
  local d="${5:-1/4}"
  jq -cn --arg s "$1" --arg r "$2" --arg b "${6:-WORKING}" --arg a "${7:-${2%% *}}" \
    --arg pr "${8:-}" \
    '{target:"t-\($s)", session_id:$s, bucket:$b, reason:$r, activity:$a, nudged:false,
    escalated:false, labels:[], next_phase:"P2 the thing", fact:"f", idle_min:0,
    phases:[{state:"open", name:"P2 the held item"}], phase_runner:(if $pr == "" then null else $pr end)}' >> "$HOME/rows"
  jq -cn --arg s "$1" --argjson m "$3" --argjson a "$4" --argjson d "${d%/*}" --argjson n "${d#*/}" \
    '{target:"t-\($s)", session_id:$s, phases_done:$d, phases_total:$n, finished:false, phase_min:$m,
      phase_since_epoch:(now - $a * 60 - 30 | floor), basis:"b"}' >> "$HOME/eta"
}
phases_doc() { doc "$(jq -s . "$HOME/rows")"; STUB_ETA="$(cat "$HOME/eta")\n"; export STUB_ETA; }

@test "a WORKING phase open twice its estimate and the floor is overdue, with the exact ledger call" {
  phase s1 shell 40 81
  phase s2 'idle 3m' 40 79                # under 2x its estimate
  phase s3 shell 20 59                    # 2x is 40m, but the floor is 60m
  phase s4 busy 40 500                    # mid-turn: a message would only queue
  phase s5 shell 40 500 4/4               # every box ticked: DONE's to say, not overdue's
  phases_doc
  run "$SH" due
  assert_success
  assert_line "overdue: t-s1 phase 2/4 'P2 the thing' open 81m, expected 40m (b); then: fleet-sessions mark s1 \"overdue phase 2/4\""
  refute_output --partial t-s2
  refute_output --partial t-s3
  refute_output --partial t-s4
  refute_output --partial t-s5
}

@test "an overdue line names the session running the open phase's item, once, not every session on the plan (ar-1497)" {
  phase s1 shell 40 81 1/4 WORKING shell t-s2   # plan owner: P2 is an item running in s2
  phase s3 shell 40 81 1/4 WORKING shell t-s2   # a second session on the same plan file
  phase s2 shell 40 10 1/1                      # the runner: its own phase is young
  phase s4 shell 40 81 1/4 WORKING shell t-gone # a stale session: on the item, no row at all: the plan row keeps its line
  phase s5 shell 40 81 1/4 WORKING shell t-s5   # it runs its own phase: unchanged
  phase s6 shell 40 81 1/4 WORKING shell t-s7   # the runner is mid-turn: left to finish, nobody named
  phase s7 busy 40 10 1/1
  phases_doc
  run "$SH" due
  assert_success
  assert_line "overdue: t-s2 phase 2/4 'P2 the held item' open 81m, expected 40m (b); then: fleet-sessions mark s2 \"overdue phase 2/4\""
  assert_line "overdue: t-s5 phase 2/4 'P2 the thing' open 81m, expected 40m (b); then: fleet-sessions mark s5 \"overdue phase 2/4\""
  refute_output --partial t-s1
  refute_output --partial t-s3
  assert_line "overdue: t-s4 phase 2/4 'P2 the thing' open 81m, expected 40m (b); then: fleet-sessions mark s4 \"overdue phase 2/4\""
  refute_output --partial t-s6
  refute_output --partial t-s7
  [ "$(grep -c '^overdue: ' <<<"$output")" = 3 ]
}

@test "a NEEDS session carrying on past its ask keeps the overdue check; a plain or busy one does not" {
  phase s1 '1 pending ask(s), carrying on' 40 81 1/4 NEEDS shell
  phase s2 '1 pending ask(s)' 40 81 1/4 NEEDS idle                  # its turn ended on the question
  phase s3 '1 pending ask(s), carrying on' 40 81 1/4 NEEDS busy     # mid-turn: a message would only queue
  phases_doc
  run "$SH" due
  assert_success
  assert_line "overdue: t-s1 phase 2/4 'P2 the thing' open 81m, expected 40m (b); then: fleet-sessions mark s1 \"overdue phase 2/4\""
  refute_output --partial 'overdue: t-s2'
  refute_output --partial 'overdue: t-s3'
}

@test "a session waiting its landing turn is not overdue, and a long wait is one landing line per project (ar-2525)" {
  # 2026-11-15 unity-core-playground-agent-3: #2726 green, its gate-and-land.sh 3.5h in the landing-slot
  # queue behind #2733, read as a WORKING shell and nudged overdue.
  phase s1 shell 40 500                                   # queue gates (open_job queue) in one project
  phase s2 shell 40 500
  phase s3 shell 40 500                                   # control: a queue gate with no measured wait (a remote host) keeps the overdue check
  phase s4 shell 40 500                                   # control: a plain shell is still overdue
  phase s5 shell 40 30 1/4 WORKING shell                  # a short queue wait in another project
  phase s6 'PR #7 waiting on the landing queue' 40 500    # control: a labelled PR with no gate driving it
  phase s7 shell 40 500                                   # a manual session is the human's, however long its wait
  phases_doc
  jq '.sessions |= map(if .session_id == "s1" then . + {open_job:"queue", project:"ucp", pr:"2726", pane:"%12", wait_min:210, landing_queue:12}
      elif .session_id == "s2" then . + {open_job:"queue", project:"ucp", wait_min:40, landing_queue:11}
      elif .session_id == "s3" then . + {open_job:"queue", project:"ucp"}
      elif .session_id == "s5" then . + {open_job:"queue", project:"dot", wait_min:30}
      elif .session_id == "s6" then . + {project:"ucp", landing_queue:11}
      elif .session_id == "s7" then . + {open_job:"queue", project:"ucp", wait_min:500, labels:["manual"]} else . end)' \
    "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$SH" due
  assert_success
  refute_output --partial 'overdue: t-s1'
  refute_output --partial 'overdue: t-s2'
  assert_line --partial 'overdue: t-s3 phase 2/4'
  assert_line --partial 'overdue: t-s4 phase 2/4'
  assert_line --partial 'overdue: t-s6 phase 2/4'
  assert_line 'landing: ucp longest wait t-s1 [%12] PR #2726 210m, 2 waiting their landing turn, 12 PRs in the landing queue; then: read what holds the landing slot and its session; when it is moving, fleet-shepherd skip this line naming it'
  refute_output --partial 'landing: dot'
  # the line routes to the shepherd, and keeps its identity while the wait and the queue move
  run "$SH" route "landing: ucp longest wait t-s1 [%12] PR #2726 210m, 3 waiting"
  assert_output --partial shepherd
  FLEET_SHEPHERD_LANDING_WAIT_MIN=20 run "$SH" due
  assert_line --partial 'landing: dot longest wait t-s5 30m, 1 waiting their landing turn; then:'
  "$SH" check >/dev/null
  jq '.sessions |= map(if .session_id == "s1" then .wait_min = 270 else . end | if .landing_queue then .landing_queue = 9 else . end | select(.session_id != "s2"))' \
    "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run checked
  assert_line 'unhandled: landing: ucp longest wait t-s1 [%12] PR #2726 270m, 1 waiting their landing turn, 9 PRs in the landing queue; then: read what holds the landing slot and its session; when it is moving, fleet-shepherd skip this line naming it'
  # skipped, the line stays quiet when a new session becomes the longest waiter: the queue is the fact
  "$SH" skip 'landing: ucp longest wait t-s1 [%12] PR #2726 270m, 1 waiting their landing turn' 'slot holder moving'
  jq '.sessions |= map(select(.session_id != "s1") | if .session_id == "s7" then .labels = [] | .pr = "2731" else . end)' \
    "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$SH" due
  assert_line --partial 'landing: ucp longest wait t-s7 PR #2731 500m'
  run checked
  refute_output --partial 'landing: ucp'
}

@test "an overdue phase is nudged once, escalated once a phase-length after, then left to the human" {
  phase s1 shell 40 200
  phases_doc
  printf 'fact: overdue phase 2/4\nat: %s\n' "$(date -Iseconds -d '-30 min')" > "$FLEET_SHEPHERD_DIR/s1"
  run "$SH" due
  refute_output --partial 't-s1'          # nudged 30m ago, floor 60m: give it time
  printf 'fact: overdue phase 2/4\nat: %s\n' "$(date -Iseconds -d '-61 min')" > "$FLEET_SHEPHERD_DIR/s1"
  run "$SH" due
  assert_line "escalate overdue: t-s1 phase 2/4 'P2 the thing' open 200m, expected 40m (b), nudged and not moved; then: fleet-sessions escalate s1 \"overdue phase 2/4\""
  printf 'fact: overdue phase 2/4\nescalated: overdue phase 2/4\nat: x\n' > "$FLEET_SHEPHERD_DIR/s1"
  run "$SH" due
  refute_output --partial 't-s1'
  # a different fact on the ledger (an older nudge) does not hide the overdue phase
  printf 'fact: PR #9 merged\nat: x\n' > "$FLEET_SHEPHERD_DIR/s1"
  run "$SH" due
  assert_output --partial 'overdue: t-s1 phase 2/4'
}

@test "phase ages that cannot be read say so, instead of reading as none" {
  doc "[]"
  STUB_BENCH_FAIL=1 run "$SH" due
  assert_output --partial 'overdue: fleet-bench eta unreadable'
}

# idle <target> <pane> <idle_min> [escalated]: a row limit_due reads
idle_row() {
  jq -n --arg t "$1" --arg p "$2" --argjson i "$3" --argjson e "${4:-false}" \
    '{target:$t, pane:$p, idle_min:$i, bucket:"WORKING", nudged:false, escalated:$e, labels:[]}'
}

@test "an idle pane stopped on the usage limit is due, read on the session's own server" {
  doc "[$(idle_row lab/agent-1:1 %5 9)]"
  STUB_PANE='some output\n\nYou have hit your weekly limit\n\n' run "$SH" due
  assert_success
  assert_output 'limit: lab/agent-1:1 [%5] stopped on the usage limit'
  grep -q -- '-L lab capture-pane -p -t %5' "$HOME/tmux.calls"
}

@test "the usage-limit line needs an idle session, the text near the bottom, and no escalation" {
  doc "[$(idle_row lab/busy:1 %1 1), $(idle_row lab/told:1 %2 9 true)]"
  STUB_PANE='hit your weekly limit\n' run "$SH" due
  assert_failure
  doc "[$(idle_row lab/old:1 %3 9)]"
  STUB_PANE='hit your weekly limit\n1\n2\n3\n4\n5\n6\n7\n' run "$SH" due
  assert_failure
}

# acct_row <target> <pane> <activity> <account> [labels-json]: a live session limit_due reads
acct_row() {
  jq -n --arg t "$1" --arg p "$2" --arg a "$3" --arg c "$4" --argjson l "${5:-[]}" \
    '{target:$t, pane:$p, activity:$a, account:$c, idle_min:0, bucket:"WORKING", nudged:false, escalated:false, labels:$l}'
}
# accts <main capped> <main week> <main 5h> [noroom]: claude-acct room --json, main's verdict capped
# or not with those numbers beside it, alt with room and the pick (noroom: none either, no pick). limit_due reads the verdict,
# so a number that disagrees with it moves nothing.
accts() {
  jq -cn --argjson c "$1" --argjson w "$2" --argjson f "$3" --argjson ok "$([ "${4:-}" = noroom ] && echo false || echo true)" \
    --arg alt "$HOME/.claude-acct2" '
    {pick: (if $ok then "alt" else null end), why: (if $ok then null else "no account has room" end),
     accounts: [{name: "main", dir: "", state: "ok", rank: 1, week_used: $w, five_hour: $f,
                 room: {ok: false, reason: (if $c then "capped" else "pace" end), capped: $c}},
                {name: "alt", dir: $alt, state: "ok", rank: 2, week_used: 20, five_hour: 5,
                 room: {ok: $ok, reason: (if $ok then "ok" else "pace" end), capped: false}}]}'
}

@test "an account at its week cap: its idle sessions move to the room account, a dialog is listed, busy and shell wait" {
  doc "[$(acct_row hub/dotfiles:2 %27 idle main), $(acct_row hub/dotfiles:3 %19 waiting main),
        $(acct_row hub/dotfiles:4 %35 shell main), $(acct_row hub/dotfiles:5 %17 busy main),
        $(acct_row hub/dotfiles:7 %45 idle main '["manual"]'), $(acct_row lab/agent-1:1 %5 idle alt)]"
  STUB_ACCTS="$(accts true 100 40)" STUB_PANE='You have hit your weekly limit\n' run "$SH" due
  assert_success
  assert_output "limit: hub/dotfiles:2 [%27] idle on main, out of usage; then: claude-acct move hub/dotfiles:2 --to alt
limit: hub/dotfiles:3 [%19] on main, out of usage, is in a dialog; then: list it for the human, and fleet-shepherd skip it"
  # the account read covers them: no pane on main is read for the limit text
  run grep -sc capture-pane "$HOME/tmux.calls"
  refute_output --regexp '^[1-9]'
}

@test "a 5h cap moves sessions too; under both caps nothing moves; the pane line still reads sessions on other accounts" {
  doc "[$(acct_row hub/dotfiles:2 %27 idle main), $(idle_row lab/agent-1:1 %5 9)]"
  STUB_ACCTS="$(accts true 50 100)" run "$SH" due
  assert_success
  assert_output 'limit: hub/dotfiles:2 [%27] idle on main, out of usage; then: claude-acct move hub/dotfiles:2 --to alt'
  # Negative control: main under both caps is not out of usage
  STUB_ACCTS="$(accts false 99 99)" run "$SH" due
  assert_failure
  STUB_ACCTS="$(accts false 99 99)" STUB_PANE='hit your weekly limit\n' run "$SH" due
  assert_output 'limit: lab/agent-1:1 [%5] stopped on the usage limit'
}

# gw_accts <team capped>: accts with the sources rows, the team one capped or not
gw_accts() {
  accts false 50 50 | jq -c --argjson c "$1" '.sources = [
    {name: "lazer", kind: "litellm-team", room: {ok: false, capped: $c}},
    {name: "reserve", kind: "litellm-key", room: {ok: false, capped: false}}]'
}

@test "a gateway team out of budget: its sessions get the exact move, sessions on accounts get nothing" {
  doc "[$(acct_row lab/agent-55:1 %5 idle gateway), $(acct_row hub/dotfiles:2 %27 idle main)]"
  STUB_ACCTS="$(gw_accts true)" run "$SH" due
  assert_success
  assert_output 'limit: lab/agent-55:1 [%5] idle on gateway, out of usage; then: claude-acct move lab/agent-55:1 --to alt'
  # Negative control: the team has budget, and a key's own row is not the team's
  STUB_ACCTS="$(gw_accts false)" run "$SH" due
  assert_failure
}

@test "a gateway session stopped on a 429 names the move; an account session showing that text gets no line" {
  doc "[$(acct_row lab/agent-55:1 %5 idle gateway | jq -c '.idle_min = 9'), $(idle_row lab/agent-1:1 %6 9)]"
  STUB_ACCTS="$(gw_accts false)" STUB_PANE='API Error: 429 Budget has been exceeded! Team=t1 Current cost: 380, Max budget: 250\n' run "$SH" due
  assert_success
  assert_output 'limit: lab/agent-55:1 [%5] stopped on its gateway budget; then: claude-acct move lab/agent-55:1 --to alt'
}

@test "an account out of usage with no room anywhere is one line for the human" {
  doc "[$(acct_row hub/dotfiles:2 %27 idle main), $(acct_row hub/dotfiles:3 %19 idle main)]"
  STUB_ACCTS="$(accts true 100 40 noroom)" run "$SH" due
  assert_success
  assert_output 'limit: main is out of usage and no account has room; then: tell the human once (2 live on it), and fleet-shepherd skip it'
}

@test "out of usage is the published verdict's capped, never the shepherd's own reading of the numbers" {
  doc "[$(acct_row hub/dotfiles:2 %27 idle main)]"
  # the numbers say spent, the verdict says not capped: nothing moves
  STUB_ACCTS="$(accts false 100 100)" run "$SH" due
  assert_failure
  # the verdict says capped under numbers that do not: it moves, to the best account with room
  STUB_ACCTS="$(accts true 40 40)" run "$SH" due
  assert_success
  assert_output 'limit: hub/dotfiles:2 [%27] idle on main, out of usage; then: claude-acct move hub/dotfiles:2 --to alt'
  run grep -nE 'week_used // 0\) >= 100|five_hour // 0\) >= 100' "$REPO_ROOT/.local/bin/fleet-shepherd"
  assert_failure
}

@test "an unreadable state document fails the run; it does not read as a quiet fleet, and the pass still starts, told why" {
  echo 'not json' > "$FLEET_STATE_FILE"
  run "$SH" run
  assert_failure 2
  assert_equal "$(outcome)" FAILED
  [ ! -e "$HOME/pages" ]
  assert_equal "$(starts)" 1
  run prompt
  assert_line --partial 'could not refresh or read the state document'
  refute_line nothing
}

@test "check refreshes like run and prints what is due, calling no model" {
  doc "[$(row a DONE false false)]"
  run checked
  assert_success
  assert_line 'nudge DONE: a f-a'
  assert_equal "$(cat "$HOME/sessions.calls")" --write
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
}

@test "check on a quiet fleet exits 1 and pages settled once" {
  doc "[$(row a NEEDS false true)]"
  run checked
  assert_failure 1
  assert_output ''
  "$SH" check || true
  [ "$(wc -l < "$HOME/pages")" -eq 1 ] || { cat "$HOME/pages"; false; }
}

@test "check exits 2 when the document cannot be refreshed, and run records FAILED with a pass started" {
  stub fleet-sessions 'exit 1'
  run checked
  assert_failure 2
  run "$SH" run
  assert_failure
  assert_equal "$(outcome)" FAILED
  assert_equal "$(starts)" 1
}

@test "a due line the last pass left as it was leads the next check as unhandled" {
  doc "[$(row a DONE false false), $(row b LANDED false false)]"
  run checked
  assert_output "$(printf 'nudge DONE: a f-a\nnudge LANDED: b f-b')"
  # the pass nudged a (so it is an escalate line now) and did nothing about b
  doc "[$(row a DONE true false), $(row b LANDED false false)]"
  run checked
  assert_success
  assert_line --index 0 'unhandled: nudge LANDED: b f-b'
  assert_line --index 1 'escalate DONE: a r-a'
  printf '%s\tp1\tWORKED\tx\n' "$(date -u '+%F %H:%M')" > "$FLEET_SHEPHERD_DIR/passes.tsv"
  assert_equal "$("$SH" stats | jq -c '[.unhandled_checks, .stuck]')" '[1,false]'
  # a second check in a row with a line owed: the shepherd is stuck, and stuck says which
  "$SH" check >/dev/null
  run "$SH" stuck
  assert_failure 1
  assert_line 'stuck: an unhandled due line at 2 checks in a row'
  assert_line 'unhandled: nudge LANDED: b f-b'
  # Negative control: a check that owes nothing ends the run of checks
  doc "[$(row a DONE true true), $(row b LANDED true true), $(row c DONE false false)]"
  "$SH" check >/dev/null
  [ ! -e "$FLEET_SHEPHERD_DIR/.unhandled" ]
  run "$SH" stuck
  assert_success
  assert_output --partial 'passing: 1 due'
}

@test "two checks that each owe a different line are no streak: only the same line left twice is stuck" {
  doc "[$(row a DONE false false), $(row b LANDED false false)]"
  "$SH" check >/dev/null
  # the pass handled b and left a, and c came due and is handed
  doc "[$(row a DONE false false), $(row b LANDED true true), $(row c DONE false false)]"
  run checked
  assert_line --index 0 'unhandled: nudge DONE: a f-a'
  # the next pass handled a and left c: a different line owed at the second check in a row
  doc "[$(row a DONE true true), $(row b LANDED true true), $(row c DONE false false)]"
  run checked
  assert_line --index 0 'unhandled: nudge DONE: c f-c'
  refute_output --partial 'nudge DONE: a'
  printf '%s\tp1\tWORKED\tx\n' "$(date -u '+%F %H:%M')" > "$FLEET_SHEPHERD_DIR/passes.tsv"
  assert_equal "$("$SH" stats | jq -c '[.unhandled_checks, .stuck]')" '[1,false]'
  run "$SH" stuck
  assert_success
  # Negative control: the same line left at the next check too is the streak
  "$SH" check >/dev/null
  run "$SH" stuck
  assert_failure 1
  assert_line 'stuck: an unhandled due line at 2 checks in a row'
  assert_line 'unhandled: nudge DONE: c f-c'
}

@test "stuck: lines due and no pass started in an hour, whatever the lease says; a recent pass or nothing due is passing" {
  printf 'k1\tshepherd\t1\tnudge DONE: a\nk2\tshepherd\t1\tescalate NEEDS: b\n' > "$FLEET_SHEPHERD_DIR/.due"
  printf '%s\tp1-1111\tWORKED\tx\n' "$(date -u -d '70 minutes ago' '+%F %H:%M')" > "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SH" stuck
  assert_failure 1
  assert_line --index 0 --regexp '^stuck: 2 due and no pass started in (69|70|71)m$'
  assert_line 'last pass: p1-1111 WORKED'
  assert_line 'escalate NEEDS: b'
  assert_equal "$("$SH" stats | jq -c '[.stuck, (.stuck_why | test("2 due"))]')" '[true,true]'
  printf 'interactive %s\n' "$(( $(date +%s) - 300 ))" > "$FLEET_SHEPHERD_DIR/.lease"
  run "$SH" stuck
  assert_failure 1
  rm "$FLEET_SHEPHERD_DIR/.lease"
  : > "$FLEET_SHEPHERD_DIR/.due"
  run "$SH" stuck
  assert_success
  printf 'k1\tshepherd\t1\tnudge DONE: a\n' > "$FLEET_SHEPHERD_DIR/.due"
  printf '%s\tp1\tWORKED\tx\n' "$(date -u -d '20 minutes ago' '+%F %H:%M')" > "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SH" stuck
  assert_success
  assert_output --regexp '^passing: 1 due, last pass (19|20|21)m ago$'
}

@test "stuck and the page: a line the debounce can hold gets DEBOUNCE_MIN longer, an urgent line does not" {
  export FLEET_SHEPHERD_DEBOUNCE_MIN=60
  printf 'k1\tshepherd\t1\tnudge DONE: a\n' > "$FLEET_SHEPHERD_DIR/.due"
  printf '%s\tp1\tWORKED\tx\n' "$(date -u -d '90 minutes ago' '+%F %H:%M')" > "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SH" stuck
  assert_success
  printf 'k1\tshepherd\t1\tnudge DONE: a\nk2\tshepherd\t1\tunhandled: watch: x tripped (high)\n' > "$FLEET_SHEPHERD_DIR/.due"
  run "$SH" stuck
  assert_failure 1
  # the page: 90 minutes owed pages an urgent line and not a held one
  doc "[$(row a DONE false false)]"
  export STUB_TRIPPED='queue-starved\thigh\n'
  "$SH" check >/dev/null
  sed -i "s/\t[0-9]*$/\t$(ago 90)/" "$FLEET_SHEPHERD_DIR/.handed"
  "$SH" check >/dev/null
  run cat "$HOME/pages"
  assert_output --partial 'watch: queue-starved tripped (high)'
  refute_output --partial 'nudge DONE: a'
}

@test "the .due record keeps each line's role and first-seen time across checks, for the Shepherd tab" {
  doc "[$(row a DONE false false)]"
  STUB_HOLDS=$'unity\t2026\tme\twhy' "$SH" check >/dev/null
  run cut -f1,2,4 "$FLEET_SHEPHERD_DIR/.due"
  assert_line $'nudge DONE: a f-a\tshepherd\tnudge DONE: a f-a'
  assert_line $'pace: hold unity while the machine reads CLEAR\tfleet-pace\tpace: hold unity while the machine reads CLEAR'
  # a first-seen time from the past survives the next check, and the line comes back unhandled
  sed -i 's/\t[0-9]*\tnudge/\t1000\tnudge/' "$FLEET_SHEPHERD_DIR/.due"
  "$SH" check >/dev/null
  run grep '^nudge' "$FLEET_SHEPHERD_DIR/.due"
  assert_output $'nudge DONE: a f-a\tshepherd\t1000\tunhandled: nudge DONE: a f-a'
  # Negative control: a line that left is gone from the record, so nothing stale shows as owed.
  doc "[]"; "$SH" check || true
  run cat "$FLEET_SHEPHERD_DIR/.due"
  assert_output ''
}

@test "a skipped line stays out while it is due, and is new again once it was not" {
  doc "[$(row a DONE false false)]"
  "$SH" check >/dev/null
  run "$SH" skip 'unhandled: nudge DONE: a f-a' 'the human is on it in chat'
  assert_success
  run checked
  assert_failure 1
  assert_output ''
  run cut -f2 "$FLEET_SHEPHERD_DIR/.skipped"
  assert_output 'the human is on it in chat'
  run tail -1 "$FLEET_SHEPHERD_DIR/log.md"
  assert_output --partial 'skipped: nudge DONE: a f-a: the human is on it in chat'
  doc "[]"; "$SH" check || true        # no longer due: the skip is spent
  doc "[$(row a DONE false false)]"
  run checked
  assert_output 'nudge DONE: a f-a'
}

@test "an overdue line an hour older is still the same line, and skip needs a why" {
  phase s1 shell 40 100
  phases_doc
  "$SH" check >/dev/null
  : > "$HOME/rows"; : > "$HOME/eta"; phase s1 shell 40 160; phases_doc
  run checked
  assert_line --partial 'unhandled: overdue: t-s1 phase 2/4'
  assert_line --partial 'open 160m'
  run "$SH" skip 'overdue: t-s1 phase 2/4'
  assert_failure 2
}

@test "skip refuses a line that is not due, names the nearest due line, and stores nothing" {
  doc "[$(row a DONE false false)]"
  "$SH" check >/dev/null
  run "$SH" skip 'nudge DONE: a f-...' 'shortened'
  assert_failure 2
  assert_output --partial "nearest due: 'nudge DONE: a f-a'"
  [ ! -s "$FLEET_SHEPHERD_DIR/.skipped" ]
  if grep -qs skipped "$FLEET_SHEPHERD_DIR/log.md"; then false; fi
  # Negative control: the line as check printed it is accepted and stays out of the next check.
  run "$SH" skip 'nudge DONE: a f-a' 'the human has it'
  assert_success
  run checked
  assert_failure 1
}

@test "skip with nothing due, or an empty line, says so and stores nothing; a line due since the last check is refused, not recomputed" {
  doc "[]"
  run "$SH" skip 'nudge DONE: a f-a' 'why'
  assert_failure 2
  assert_output --partial 'the last check found nothing due'
  run "$SH" skip 'unhandled: ' 'why'
  assert_failure 2
  assert_output --partial 'is empty'
  [ ! -s "$FLEET_SHEPHERD_DIR/.skipped" ]
  # no check has seen this line: skip reads what the last check wrote, so it is refused until one does
  doc "[$(row a DONE false false)]"
  run "$SH" skip 'nudge DONE: a f-a' 'why'
  assert_failure 2
  [ ! -s "$FLEET_SHEPHERD_DIR/.skipped" ]
  "$SH" check >/dev/null
  run "$SH" skip 'nudge DONE: a f-a' 'why'
  assert_success
  # a skipped line is left out of .due while it is due, but it is still a due line: a second reason is accepted
  "$SH" check >/dev/null || true
  run "$SH" skip 'nudge DONE: a f-a' 'a better why'
  assert_success
}

@test "skip does not rebuild the due lines: it validates against the last check's .due" {
  doc "[$(row a DONE false false)]"
  "$SH" check >/dev/null
  # a copy whose cmd_due fails loudly: skip must not call it
  sed 's/^cmd_due() {$/cmd_due() { echo "cmd_due called" >\&2; return 9;/' "$SH" > "$BATS_TEST_TMPDIR/sh-nocmd"
  chmod +x "$BATS_TEST_TMPDIR/sh-nocmd"
  grep -q 'cmd_due called' "$BATS_TEST_TMPDIR/sh-nocmd"   # the sed matched
  FLEET_LEAD_FUNCTIONS="$(dirname "$(readlink -f "$SH")")/../../.config/fleet-lead/functions.tsv" \
    run "$BATS_TEST_TMPDIR/sh-nocmd" skip 'nudge DONE: a f-a' 'why'
  assert_success
  refute_output --partial 'cmd_due called'
}

@test "skip names every due line tied for nearest, and matches an elided line by both its ends" {
  doc "[$(row a DONE false false),$(row b DONE false false)]"
  "$SH" check >/dev/null
  run "$SH" skip 'nudge DONE: zzz' 'why'
  assert_failure 2
  assert_output --partial "nudge DONE: a f-a'; 'nudge DONE: b f-b"
  run "$SH" skip 'nudge DONE: ...f-b' 'why'
  assert_failure 2
  assert_output --partial "nearest due: 'nudge DONE: b f-b'"
  [ ! -s "$FLEET_SHEPHERD_DIR/.skipped" ]
}

@test "stats counts the ledgers: open, unhandled, skipped and paged lines, 24h receipts from log.md, the last pass" {
  run "$SH" stats
  assert_success
  assert_equal "$(jq -c '[.state, .due, .nudges_24h, .passes_24h, .last_pass_epoch]' <<< "$output")" '[0,0,0,0,null]'
  mkdir -p "$FLEET_SHEPHERD_DIR"
  printf 'k1\tshepherd\t1\tnudge DONE: a\nk2\tshepherd\t1\tunhandled: escalate NEEDS: b\n' > "$FLEET_SHEPHERD_DIR/.due"
  printf 'k3\twhy\t1\n' > "$FLEET_SHEPHERD_DIR/.skipped"
  "$SH" log "nudged a: done, wind down"
  "$SH" log "escalated b: 2 asks"
  "$SH" log "skipped: c: still gating"
  printf -- '- %s: nudged old\n' "$(date -u -d '30 hours ago' '+%H:%M UTC %m-%d')" >> "$FLEET_SHEPHERD_DIR/log.md"
  printf '%s\tp1\tWORKED\tx\n' "$(date -u -d '10 minutes ago' '+%F %H:%M')" > "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SH" stats
  assert_success
  assert_equal "$(jq -c '[.due, .unhandled, .skipped, .nudges_24h, .escalations_24h, .skips_24h, .passes_24h, .last_verdict, .pass_running]' <<< "$output")" '[2,1,1,1,1,1,1,"WORKED",false]'
  age="$(jq .last_pass_age_s <<< "$output")"
  [ "$age" -ge 540 ] && [ "$age" -le 720 ] || fail "last_pass_age_s $age"
  assert_equal "$(jq -c '[.pass_id, .pass_status, .pass_age_s, .attach, .last_pass_id, .stuck]' <<< "$output")" '[null,null,null,null,"p1",false]'
}

@test "stats names the pass running now: its id, status, age and attach line, wherever its pane is" {
  printf '%s\tp1\tWORKED\tx\n' "$(date -u -d '30 minutes ago' '+%F %H:%M')" > "$FLEET_SHEPHERD_DIR/passes.tsv"
  printf 'sid-2\t%s\t3\t%%9\n' "$(( $(date +%s) - 120 ))" > "$FLEET_SHEPHERD_DIR/.pass"
  live sid-2 busy
  export STUB_PANES='%9\thub\t2\tshepherd\t0\n'
  run "$SH" stats
  assert_success
  assert_equal "$(jq -c '[.pass_running, .pass_id, .pass_status, .attach, .last_pass_id, .last_verdict]' <<< "$output")" \
    '[true,"sid-2","busy","tmux -L hub attach -t hub:2","p1","WORKED"]'
  age="$(jq .pass_age_s <<< "$output")"
  [ "$age" -ge 115 ] && [ "$age" -le 180 ] || fail "pass_age_s $age"
  assert_equal "$(jq .last_pass_age_s <<< "$output")" "$age"
  # a resume put it in a window of another session, under another name, in another pane
  live sid-2 busy 'dotfiles:@12.%31'
  STUB_PANES='%9\thub\t2\tzsh\t0\n%31\tdotfiles\t1\tsid-2\t0\n' run "$SH" stats
  assert_equal "$(jq -c '[.pass_running, .pass_status, .attach]' <<< "$output")" '[true,"busy","tmux -L hub attach -t dotfiles:1"]'
  # Negative control: no pane anywhere, the recorded place is all there is.
  gone
  STUB_PANES='' run "$SH" stats
  assert_equal "$(jq -c '[.pass_status, .attach]' <<< "$output")" '["gone","tmux -L hub attach -t hub:shepherd"]'
}

# sweep_setup <runner>...: the runner exporter answers with these busy runners in the pool; each is
# "<event> <branch> <run id>". gh answers a run's finished jobs with $STUB_JOBS (one conclusion a
# line) and records every call; fleet-bench records what it is told.
runner() { jq -cn --arg e "$1" --arg b "$2" --arg r "$3" '{metric: {event: $e, branch: $b, url: "https://github.com/o/r/actions/runs/\($r)/job/1"}}'; }
sweep_setup() {
  local r
  r="$(for x in "$@"; do read -r e b id <<<"$x"; runner "$e" "$b" "$id"; done | jq -sc .)"
  export STUB_RUNNERS="$r"
  cat > "$PROM_LIB" <<'STUB'
prom_q() { [ -z "${STUB_PROM_FAIL:-}" ] || return 1; echo "$1" >> "$HOME/prom.calls"; printf '{"status":"success","data":{"result":%s}}' "$STUB_RUNNERS"; }
STUB
  stub gh 'echo "$*" >> "$HOME/gh.calls"; case "$1" in api) printf "%b" "${STUB_JOBS:-}" ;; esac'
  stub fleet-bench 'echo "$*" >> "$HOME/bench.calls"'
}

@test "sweep-cancel cancels a sweep that holds the pool and mostly fails, records it on the finding, and says who to tell" {
  sweep_setup 'workflow_dispatch sweep/frames 42' 'workflow_dispatch sweep/frames 42' 'workflow_dispatch sweep/frames 42' 'pull_request feat/x 7'
  export STUB_JOBS='failure\nfailure\nsuccess\n'
  run "$SH" sweep-cancel 'starved pool:unity @1700000000'
  assert_success
  assert_line 'cancelled https://github.com/o/r/actions/runs/42: held 3 of 4 unity runners, 2 of 3 finished jobs failed'
  assert_line --partial 'tell the session on sweep/frames:'
  run grep -c 'pool="unity",state="running"' "$HOME/prom.calls"
  assert_output 1
  run grep -x 'run cancel 42 -R o/r' "$HOME/gh.calls"
  assert_success
  run cat "$HOME/bench.calls"
  assert_output 'respond starved pool:unity @1700000000 shepherd cancelled https://github.com/o/r/actions/runs/42'
  run grep -c 'cancelled sweep run 42 (sweep/frames)' "$FLEET_SHEPHERD_DIR/log.md"
  assert_output 1
}

@test "sweep-cancel leaves a sweep whose jobs mostly pass, and one that holds half the pool or less" {
  sweep_setup 'workflow_dispatch sweep/frames 42' 'workflow_dispatch sweep/frames 42' 'workflow_dispatch sweep/frames 42' 'pull_request feat/x 7'
  export STUB_JOBS='failure\nsuccess\n'
  run "$SH" sweep-cancel 'starved pool:unity @1700000000'
  assert_failure 1
  assert_output --partial '1 of 2 finished jobs failed: it stays'
  sweep_setup 'workflow_dispatch sweep/frames 42' 'workflow_dispatch sweep/frames 42' 'pull_request feat/x 7' 'workflow_dispatch feat/y 8'
  rm -f "$HOME/gh.calls"
  run "$SH" sweep-cancel 'starved pool:unity @1700000000'
  assert_failure 1
  assert_output 'sweep-cancel: no sweep run holds most of pool unity'
  [ ! -e "$HOME/gh.calls" ]
  [ ! -e "$HOME/bench.calls" ]
}

@test "sweep-cancel: an unreadable exporter leaves the pool alone, and a fact that is not a starved pool is a usage error" {
  sweep_setup 'workflow_dispatch sweep/frames 42'
  STUB_PROM_FAIL=1 run "$SH" sweep-cancel 'starved pool:unity @1700000000'
  assert_failure 1
  assert_output --partial 'unreadable'
  run "$SH" sweep-cancel 'host-overload host:a @1700000000'
  assert_failure 2
  [ ! -e "$HOME/gh.calls" ]
}

# --- session budgets: checkpoints, not walls ---------------------------------------------------
# budget_setup: claude-acct answers cost from STUB_COST and records parks (STUB_PARK_BUSY refuses
# one as mid-turn); agent-queue shows item q1 with STUB_TASK and two earlier sessions.
budget_setup() {
  stub claude-acct 'case "$1" in
  cost) printf "%s" "${STUB_COST-}" ;;
  park) echo "$2" >> "$HOME/park.calls"
        [ -z "${STUB_PARK_BUSY:-}" ] || { echo "claude-acct: park: $2: busy mid-turn; park it once the turn ends" >&2; exit 1; } ;;
esac'
  stub agent-queue '[ "$1 $2" = "show q1" ] || exit 1
jq -n --arg t "${STUB_TASK:-a task}" "{slug: \"q1\", task: \$t, sessions: \"s-old1 s-old2\"}"'
}
# brow <bucket>: a queue session row for item q1
brow() { jq -n --arg b "$1" '{target:"lab/w-agent-1:1", bucket:$b, nudged:false, escalated:true, labels:[], session_id:"s-now", dispatch:"dotfiles: q1"}'; }
parks() { cat "$HOME/park.calls" 2>/dev/null | grep -c . || true; }

@test "budget <task text> prints the size and budget of its #size/ tag, and no text fails" {
  run "$SH" budget 'do it #size/l'
  assert_success
  assert_output "l 50"
  run "$SH" budget 'do it #size/large'
  assert_success
  assert_output "unsized 25"
  run "$SH" budget
  assert_failure
}

@test "budget: a WORKING session past its budget carries on, logged once per checkpoint, and is not parked" {
  budget_setup
  doc "[$(brow WORKING)]"
  export STUB_COST='{"s-old1":10,"s-old2":8,"s-now":9,"other":500}'   # $27: 1x of the unsized $25
  run checked
  run checked
  assert_equal "$(grep -c 'budget: lab/w-agent-1:1 (q1 spent \$27, 1x its \$25 unsized budget), still working: carries on to 2x' "$FLEET_SHEPHERD_DIR/log.md")" 1
  assert_equal "$(parks)" 0
  [ ! -s "$HOME/pages" ]
  export STUB_COST='{"s-now":51}'   # the next checkpoint is news again
  run checked
  grep -q 'q1 spent \$51, 2x its \$25 unsized budget), still working: carries on to 3x' "$FLEET_SHEPHERD_DIR/log.md"
}

@test "budget: a STALLED session at its size budget is parked and paged once; an unpark buys one more budget" {
  budget_setup
  doc "[$(brow STALLED)]"
  export STUB_TASK='feat(x): y #size/s' STUB_COST='{"s-old1":7,"s-now":6}'   # $13 past the s $12
  run checked
  run checked
  assert_equal "$(parks)" 1
  grep -q 'budget: parked lab/w-agent-1:1 (q1 spent \$13, 1x its \$12 s budget, STALLED)' "$FLEET_SHEPHERD_DIR/log.md"
  assert_equal "$(grep -c 'lab/w-agent-1:1 parked at its budget' "$HOME/pages")" 1
  grep -q 'claude-acct unpark lab/w-agent-1:1' "$HOME/pages"
  export STUB_COST='{"s-now":25}'   # resumed and spent a second budget: the next checkpoint parks again
  run checked
  assert_equal "$(parks)" 2
}

@test "budget: WORKING past the last extension parks once its turn ends: one page, retried until it takes" {
  budget_setup
  doc "[$(brow WORKING)]"
  export STUB_COST='{"s-now":80}' STUB_PARK_BUSY=1   # 3x of $25
  run checked
  run checked
  assert_equal "$(parks)" 2
  grep -q 'budget: lab/w-agent-1:1 (q1 spent \$80, 3x its \$25 unsized budget, WORKING) parks once its turn ends' "$FLEET_SHEPHERD_DIR/log.md"
  unset STUB_PARK_BUSY
  run checked
  assert_equal "$(parks)" 3
  grep -q 'budget: parked lab/w-agent-1:1' "$FLEET_SHEPHERD_DIR/log.md"
  assert_equal "$(grep -c . "$HOME/pages")" 1
  run checked
  assert_equal "$(parks)" 3
}

@test "budget: a session waiting on the human is only logged, and an unread cost takes no checkpoint" {
  budget_setup
  doc "[$(brow NEEDS)]"
  export STUB_COST=''
  run checked
  [ ! -e "$FLEET_SHEPHERD_DIR/.budget" ] || [ ! -s "$FLEET_SHEPHERD_DIR/.budget" ]
  export STUB_COST='{"s-now":30}'
  run checked
  assert_equal "$(parks)" 0
  grep -q 'budget: lab/w-agent-1:1 (q1 spent \$30, 1x its \$25 unsized budget), NEEDS: not parked, it is not spending' "$FLEET_SHEPHERD_DIR/log.md"
}

@test "lean start: a pass gets the conf's PASS_TOOLS and lists by name only every skill and command the routing table names no row for" {
  mkdir -p "$HOME/.claude/skills/shepherd" "$HOME/.claude/skills/fleet-pace" "$HOME/.claude/skills/bug-bash" "$HOME/.claude/commands/my"
  touch "$HOME/.claude/skills/shepherd/SKILL.md" "$HOME/.claude/skills/fleet-pace/SKILL.md" "$HOME/.claude/skills/bug-bash/SKILL.md" "$HOME/.claude/commands/my/autopilot.md"
  doc "[$(row a DONE false false)]"
  PASS_TOOLS=Bash,Read,Skill run "$SH" run
  assert_success
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  run cat "$HOME/run.args"
  assert_line --index 4 --tools
  assert_line --index 5 Bash,Read,Skill
  assert_line --index 6 --settings
  assert_equal "$(sed -n 8p "$HOME/run.args" | jq -c .)" '{"skillOverrides":{"bug-bash":"name-only","my:autopilot":"name-only"}}'
  # a list that is not tool names starts the pass with every tool and says why, never a broken flag
  idle_pass; doc "[$(row b DONE false false)]"
  PASS_TOOLS='Bash Read' run "$SH" run
  assert_output --partial 'PASS_TOOLS is not a comma list of tool names'
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  run cat "$HOME/run.args"
  refute_line --tools
  assert_line --index 4 --settings
  # Negative control: with no PASS_TOOLS and every skill in the table, the pass starts as before
  rm -r "$HOME/.claude/skills/bug-bash" "$HOME/.claude/commands"
  idle_pass; doc "[$(row c DONE false false)]"
  "$SH" run >/dev/null
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  run cat "$HOME/run.args"
  refute_line --tools
  refute_line --settings
}

@test "canary lane: every CANARY_EVERY-th pass runs on CANARY_MODEL, and passes.tsv scores each pass's lane from the due lines" {
  export MODEL=claude-opus-5-5 CANARY_MODEL=claude-sonnet-5-5 CANARY_EVERY=3
  model_of() { grep -oP '^export MODEL=\K.*' "$FLEET_SHEPHERD_DIR/.pass.sh"; }
  doc "[$(row a DONE false false), $(row b LANDED false false)]"
  run "$SH" run
  assert_equal "$(model_of)" claude-opus-5-5
  # the pass nudged a (gone now) and left b as it was (owed); a run the debounce holds in between
  # prunes a from .handed, and the score still counts it, from the pass's own lane file
  doc "[$(row b LANDED false false)]"
  FLEET_SHEPHERD_DEBOUNCE_MIN=30 FLEET_SHEPHERD_URGENT_RE='^$' run "$SH" run
  assert_output --partial 'none urgent'
  refute_output --partial 'started pass'
  run grep -c '^nudge DONE: a' "$FLEET_SHEPHERD_DIR/.handed"
  assert_output 0
  run "$SH" run  # a pass with no transcript is STALLED (exit 1); this test reads its lane, not its verdict
  assert_equal "$(model_of)" claude-opus-5-5
  assert_equal "$(cut -f5- "$FLEET_SHEPHERD_DIR/passes.tsv")" "$(printf 'claude-opus-5-5\t1\t0\t1\t0\t0')"
  # the third pass is the canary's; a nudge whose session is due an escalation now did not move it
  doc "[$(row c STALLED false false)]"
  run "$SH" run
  assert_equal "$(model_of)" claude-sonnet-5-5
  doc "[$(row c STALLED true false)]"
  run "$SH" run
  assert_output --partial 'escalate STALLED: c r-c'
  assert_equal "$(model_of)" claude-opus-5-5
  assert_equal "$(sed -n 3p "$FLEET_SHEPHERD_DIR/passes.tsv" | cut -f5-)" "$(printf 'claude-sonnet-5-5\t1\t1\t0\t0\t0')"
  # Negative control: no CANARY_MODEL, no canary
  unset CANARY_MODEL
  doc "[$(row d DONE false false)]"
  run "$SH" run; run "$SH" run
  assert_equal "$(model_of)" claude-opus-5-5
}

@test "canary lane: a park the pass made counts wrong only when the pace line names that session exactly" {
  export CLAUDE_ACCT_PARKED_DIR="$HOME/parked"; mkdir -p "$CLAUDE_ACCT_PARKED_DIR"
  doc "[$(row a DONE false false)]"
  "$SH" run >/dev/null
  local id; id="$(pass_id)"; live "$id" idle
  aged 1
  # while it ran it parked lab/q (named on a clear machine, once by session and once as <session>:%<pane> with its target) and p and hub:2 (named nowhere)
  touch "$CLAUDE_ACCT_PARKED_DIR/q" "$CLAUDE_ACCT_PARKED_DIR/p" "$CLAUDE_ACCT_PARKED_DIR/hub:2"
  printf "target=lab/q:1\n" > "$CLAUDE_ACCT_PARKED_DIR/z:%9"
  doc "[$(jq -c '.bucket = "PARKED" | .target = "lab/q:1" | .pane = "%9"' <<<"$(row q DONE true true)"), $(row b DONE false false)]"
  run "$SH" run
  assert_output --partial 'pace: parked lab/q:1 [%9] while the machine reads CLEAR'
  assert_equal "$(grep -P "\t$id\t" "$FLEET_SHEPHERD_DIR/passes.tsv" | cut -f9,10)" "$(printf '2\t4')"
}

# paned <target> <bucket> <pane>: a session row whose fact does not name its target, so only the
# target differs between two renumberings of the same window
paned() { row "$1" "$2" false false | jq -c --arg p "$3" '.pane = $p | .fact = "stalled"'; }

@test "a session line keeps its identity when the window renumbers: the pane id, not the index, keys it" {
  doc "[$(paned hub/demo:5 LANDED %7)]"
  run checked
  assert_output 'nudge LANDED: hub/demo:5 [%7] stalled'
  # renumber-windows closed an earlier window: same pane, now :4. It is the line the pass was
  # handed and left, so it comes back owed, not as a new line.
  doc "[$(paned hub/demo:4 LANDED %7)]"
  run checked
  assert_output 'unhandled: nudge LANDED: hub/demo:4 [%7] stalled'
  "$SH" skip 'nudge LANDED: hub/demo:4 [%7] stalled' 'waits on purpose'
  doc "[$(paned hub/demo:3 LANDED %7)]"
  run checked
  assert_failure 1
  # Negative control: another pane at the same index is another session, and a new line
  doc "[$(paned hub/demo:3 LANDED %8)]"
  run checked
  assert_output 'nudge LANDED: hub/demo:3 [%8] stalled'
}

@test "a skip written after the windows renumber still lands: the line check printed names an index that has moved" {
  doc "[$(paned hub/dotfiles:6 STALLED %37), $(paned hub/dotfiles:15 STALLED %41)]"
  run checked
  assert_output 'nudge STALLED: hub/dotfiles:6 [%37] stalled
nudge STALLED: hub/dotfiles:15 [%41] stalled'
  # 2026-11-13: earlier windows closed between check and skip (:6 -> :4, :15 -> :13), and :13 is
  # where another session was. The pass copies the lines check printed, and they still match.
  doc "[$(paned hub/dotfiles:4 STALLED %37), $(paned hub/dotfiles:13 STALLED %41)]"
  run "$SH" skip 'nudge STALLED: hub/dotfiles:6 [%37] stalled' 'waits on purpose'
  assert_success
  run "$SH" skip 'nudge STALLED: hub/dotfiles:15 [%41] stalled' 'waits on purpose'
  assert_success
  run checked
  assert_failure 1
  # Negative control: a pane that was never due is refused, whatever index it names
  run "$SH" skip 'nudge STALLED: hub/dotfiles:13 [%99] stalled' 'nope'
  assert_failure 2
}

@test "a limit line is keyed by its pane: a skip survives the renumbering, another pane at the index is a new line" {
  doc "[$(acct_row hub/dotfiles:3 %19 waiting main)]"
  STUB_ACCTS="$(accts true 100 40)" run checked
  assert_output 'limit: hub/dotfiles:3 [%19] on main, out of usage, is in a dialog; then: list it for the human, and fleet-shepherd skip it'
  "$SH" skip 'limit: hub/dotfiles:3 [%19] on main, out of usage, is in a dialog; then: list it for the human, and fleet-shepherd skip it' 'listed'
  doc "[$(acct_row hub/dotfiles:2 %19 waiting main)]"
  STUB_ACCTS="$(accts true 100 40)" run checked
  assert_failure 1
  # Negative control: another pane at the index is another session, and a new line
  doc "[$(acct_row hub/dotfiles:2 %20 waiting main)]"
  STUB_ACCTS="$(accts true 100 40)" run checked
  assert_output --partial 'limit: hub/dotfiles:2 [%20] on main'
}

@test "a pane stopped on the usage limit is keyed by its pane id too" {
  doc "[$(idle_row lab/agent-1:3 %5 9)]"
  STUB_PANE='You have hit your weekly limit\n' run checked
  assert_output 'limit: lab/agent-1:3 [%5] stopped on the usage limit'
  "$SH" skip 'limit: lab/agent-1:3 [%5] stopped on the usage limit' 'listed'
  doc "[$(idle_row lab/agent-1:2 %5 9)]"
  STUB_PANE='You have hit your weekly limit\n' run checked
  assert_failure 1
}

@test "a pace line keys each parked target by its pane id, so a renumbered window is the same line" {
  doc "[$(prow lab/p:3 | jq -c '.pane = "%8"'), $(prow lab/q:4 | jq -c '.pane = "%9"')]"
  run checked
  assert_output 'pace: parked lab/p:3 [%8], lab/q:4 [%9] while the machine reads CLEAR with no hold; then: claude-acct unpark each'
  "$SH" skip 'pace: parked lab/p:3 [%8], lab/q:4 [%9] while the machine reads CLEAR with no hold; then: claude-acct unpark each' 'held on purpose'
  doc "[$(prow lab/p:2 | jq -c '.pane = "%8"'), $(prow lab/q:3 | jq -c '.pane = "%9"')]"
  run checked
  assert_failure 1
}

@test "an overdue line keeps its identity while its basis count grows: a skip still matches" {
  phase s1 shell 40 200
  sed -i 's/"fact":"f"/"fact":"f","pane":"%3"/' "$HOME/rows"
  sed -i 's/"basis":"b"/"basis":"project-median(274) x1.06 (n=1019)"/' "$HOME/eta"
  sed -i "s/t-s1/hub\/demo:2/" "$HOME/rows" "$HOME/eta"
  phases_doc
  run checked
  assert_output --partial "overdue: hub/demo:2 [%3] phase 2/4 'P2 the thing' open 200m, expected 40m (project-median(274) x1.06 (n=1019))"
  "$SH" skip "overdue: hub/demo:2 [%3] phase 2/4 'P2 the thing' open 200m, expected 40m (project-median(274) x1.06 (n=1019))" 'moving'
  # a phase closed elsewhere: n grows, the age moves, the line is the same one
  sed -i 's/n=1019/n=1020/; s/x1.06/x1.07/' "$HOME/eta"
  sed -i 's/demo:2/demo:1/' "$HOME/rows" "$HOME/eta"   # renumber-windows closed an earlier window
  phases_doc
  run checked
  assert_failure 1
}

@test "canary lane: a nudge to a pane-tagged session that is due an escalation now still scores as survived" {
  export MODEL=claude-opus-5-5 CANARY_MODEL=claude-sonnet-5-5 CANARY_EVERY=1
  doc "[$(paned lab/c:3 STALLED %4)]"
  run "$SH" run
  doc "[$(paned lab/c:2 STALLED %4 | jq -c '.nudged = true')]"
  run "$SH" run
  assert_output --partial 'escalate STALLED: lab/c:2 [%4]'
  assert_equal "$(sed -n 1p "$FLEET_SHEPHERD_DIR/passes.tsv" | cut -f5-)" "$(printf 'claude-sonnet-5-5\t1\t1\t0\t0\t0')"
}

@test "a pane tag inside a fact is part of the fact: only the target's tag is rewritten in the key" {
  doc "[$(paned hub/demo:2 LANDED %7 | jq -c '.fact = "see foo/bar [%9]"')]"
  run checked
  assert_output 'nudge LANDED: hub/demo:2 [%7] see foo/bar [%9]'
  "$SH" skip 'nudge LANDED: hub/demo:2 [%7] see foo/bar [%9]' 'waits'
  assert_equal "$(cut -f1 "$FLEET_SHEPHERD_DIR/.skipped")" 'nudge LANDED: hub/%7 see foo/bar [%9]'
}

@test "an unhandled page names the window the line is about, not only its pane id" {
  doc "[$(paned hub/demo:2 NEEDS %7)]"
  export STUB_TRIPPED=''
  "$SH" check >/dev/null
  "$SH" check >/dev/null
  sed -i 's/\t[0-9]*$/\t1000/' "$FLEET_SHEPHERD_DIR/.handed"
  "$SH" check >/dev/null
  run grep 'escalate NEEDS' "$HOME/pages"
  assert_output --partial '-r tmux:hub/demo:2 unhandled'
  assert_output --partial 'escalate NEEDS: hub/demo:2 [%7]'
}

@test "a LANDED or STALLED row whose close verdict is now gets the close nudge, not its bucket nudge" {
  # The one quiet timer closes a stalled session with nothing to land; it is typed /wind-down auto,
  # not told to fix a state the close flow already reads as closable.
  doc "[$(row a STALLED false false '[]' now), $(row b LANDED false false '[]' now), $(row c STALLED false false)]"
  run "$SH" due
  assert_success
  assert_line 'nudge DONE: a f-a'
  assert_line 'nudge DONE: b f-b'
  assert_line 'nudge STALLED: c f-c'
}
