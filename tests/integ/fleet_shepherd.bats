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
  *) printf "%b" "${STUB_PANE:-}" ;;
esac'
  stub systemd-run 'echo "$*" >> "$HOME/systemd-run.calls"'
  stub tmx 'echo "$*" >> "$HOME/tmx.calls"'
  stub tmux-world '[ -z "${STUB_NO_WORLD:-}" ] && [ "$*" = "session hub" ] && echo hub'
  stub claude-acct 'case "$1" in
  room) [ -z "${STUB_NO_ROOM:-}" ] || { [ -n "${STUB_ROOM_QUIET:-}" ] || echo "claude-acct: no account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack), runs out Mon 10:40 at this rate" >&2; exit 1; }
        echo "claude-acct: room on alt (2% of its week, 9% gone)" >&2
        printf "%s\n" "${STUB_ROOM-$HOME/.claude-acct2}" ;;
  status) printf "%b" "${STUB_ACCTS:-}" ;;
  pick) echo "$HOME/.claude-best" ;;
  trust) echo "$*" >> "$HOME/trust.calls" ;;
esac'
  stub agentctl 'echo "$*" >> "$HOME/agentctl.calls"'
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

row() { # target bucket nudged escalated [labels-json]
  jq -n --arg t "$1" --arg b "$2" --argjson n "$3" --argjson e "$4" --argjson l "${5:-[]}" \
    '{target:$t, bucket:$b, nudged:$n, escalated:$e, labels:$l, fact:"f-\($t)", reason:"r-\($t)"}'
}

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
  list) printf "%s\n" "${STUB_ACTIVE:-}" ;;
  add) echo "queued shared-red-footests -> /q/x.md" ;;
esac'
  shared_doc '["sid-1","sid-2"]'
  run "$SH" check
  assert_success
  assert_line 'nudge SHARED: P.Tests.FooTests.Bar("x") is owned by queue item shared-red-footests; tell sid-1,sid-2: do not gate again on it, merge main once shared-red-footests lands; then: fleet-sessions mark shared-P_Tests "SHARED P.Tests.FooTests.Bar("x") @100"'
  refute_output --partial 'shared red:'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 1
  run grep '^add ' "$HOME/aq.calls"
  assert_output --partial '--project unity-core-playground'
  assert_output --partial '--slug shared-red-FooTests'
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
[ "$1" = list ] && printf "%s\n" "{\"slug\":\"other\",\"task\":\"fix the BarTests class\"}" "{\"slug\":\"nightly-fix-foo-ucp-9\",\"task\":\"fix FooTests on the nightly\"}"
exit 0'
  shared_doc '["sid-1"]'
  run "$SH" check
  assert_line --partial 'is owned by queue item nightly-fix-foo-ucp-9; tell sid-1'
  run grep -c '^add ' "$HOME/aq.calls"
  assert_output 0
  # negative control: no live session in the failing worktrees, so there is no one to tell
  shared_doc '[]'
  run "$SH" due
  refute_output --partial FooTests
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

# chat <target> <nudged> <escalated> <idle_min> [age_min]: a CHAT row, quiet for the lesser of the two
chat() { row "$1" CHAT "$2" "$3" | jq -c --argjson i "$4" --argjson a "${5:-5000}" '. + {idle_min:$i, age_min:$a}'; }

@test "a CHAT row is due only past FLEET_CHAT_CLOSE_H, then nudged once and escalated once" {
  doc "[$(chat a false false 60), $(chat b false false 1440), $(chat c false false 2000 30), $(row d CHAT false false)]"
  run "$SH" due
  assert_success
  assert_output 'nudge CHAT: b f-b'
  FLEET_CHAT_CLOSE_H=1 run "$SH" due
  assert_line 'nudge CHAT: a f-a'
  refute_output --partial ' c '
  doc "[$(chat b true false 1500)]"
  run "$SH" due
  assert_output 'escalate CHAT: b r-b'
  doc "[$(chat b true true 3000)]"
  run "$SH" due
  assert_failure
  assert_output ''
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
}

@test "run with nothing due still starts a pass, told so, and refreshes the document" {
  doc "[$(row a WORKING false false)]"
  run "$SH" run
  assert_success
  assert_output --partial 'started pass'
  [ -e "$FLEET_SHEPHERD_DIR/.pass" ]
  assert_equal "$(starts)" 1
  assert_equal "$(outcome)" WORKED
  assert_equal "$(cat "$HOME/sessions.calls")" --write
  [ ! -e "$HOME/pages" ]
  run prompt
  assert_line 'Roles due: none'
  assert_line 'nothing'
  # with nothing to move it logs nothing, and that is no failure of the pass or the run
  local id; id="$(pass_id)"; live "$id" idle
  run "$SH" run
  assert_success
  assert_equal "$(outcome)" WORKED
  grep -qP "\t$id\tNOOP\t" "$FLEET_SHEPHERD_DIR/passes.tsv" || fail "$(cat "$FLEET_SHEPHERD_DIR/passes.tsv")"
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
  grep -qP "\t$id\tSTALLED\tpass ${id:0:8}: 1 due, 31m, still waiting, replaced$" "$FLEET_SHEPHERD_DIR/passes.tsv" ||
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
  doc "[$(row a WORKING false false)]"
  STUB_ROOM="$HOME/.claude-acct3" run "$SH" run
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  assert_equal "$(tail -n 1 "$HOME/run.env")" "holder=runner account=$HOME/.claude-acct3"
  # the main account: room says so with an empty line, and no config dir is set
  STUB_ROOM='' run "$SH" run
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  assert_equal "$(tail -n 1 "$HOME/run.env")" 'holder=runner account=default'
  [ ! -e "$HOME/pages" ]
  # no room anywhere is not a skip: the pass runs, and the human hears about it once
  STUB_NO_ROOM=1 run "$SH" run
  assert_success
  assert_equal "$(starts)" 3
  bash "$FLEET_SHEPHERD_DIR/.pass.sh"
  assert_equal "$(tail -n 1 "$HOME/run.env")" "holder=runner account=$HOME/.claude-best"
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

@test "a high or urgent trip and a red cluster lead the due lines, ahead of sessions" {
  doc "[$(row a DONE false false)]"
  export STUB_TRIPPED='home-k3s-node-disk\turgent\nqueue-starved\thigh\n' STUB_K3S='[{"value":[0,"2"]}]'
  run "$SH" run
  assert_output --partial $': due\ninfra: k3s domain red\nwatch: home-k3s-node-disk tripped (urgent)\nwatch: queue-starved tripped (high)\nnudge DONE: a'
  refute_output --partial 'unbound variable'
  grep -q 'watch: queue-starved tripped (high)' "$FLEET_SHEPHERD_DIR/.pass.sh"
}

@test "a standing trip stays due until a pass answers it; a skip lasts while it trips, and a new trip is news" {
  doc "[$(row d WORKING false false)]"
  export STUB_TRIPPED='queue-starved\thigh\n'
  run "$SH" check
  assert_output 'watch: queue-starved tripped (high)'
  # Negative control: a pass that only reported it still owes it.
  run "$SH" check
  assert_output 'unhandled: watch: queue-starved tripped (high)'
  "$SH" skip 'unhandled: watch: queue-starved tripped (high)' 'started the head item by hand; gate fix in #795'
  run "$SH" check
  assert_failure 1
  STUB_TRIPPED='' run "$SH" check
  assert_failure 1
  run "$SH" check
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
  sed -i 's/\t[0-9]*\t/\t1000\t/' "$FLEET_SHEPHERD_DIR/.due"
  "$SH" check >/dev/null
  run cat "$HOME/pages"
  assert_output --partial '-p high -t shepherd unhandled'
  assert_output --partial 'watch: queue-starved tripped (high)'
  sed -i 's/\t[0-9]*\t/\t1000\t/' "$FLEET_SHEPHERD_DIR/.due"
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
  sed -i 's/\t[0-9]*\t/\t1000\t/' "$FLEET_SHEPHERD_DIR/.due"
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
    '{target:"t-\($s)", session_id:$s, bucket:$b, reason:$r, activity:$a, nudged:false,
    escalated:false, labels:[], next_phase:"P2 the thing", fact:"f", idle_min:0}' >> "$HOME/rows"
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
  assert_output 'limit: lab/agent-1:1 stopped on the usage limit'
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
# accts <main week> <main 5h>: claude-acct status --json with main at those numbers, alt with room
accts() {
  printf '[{"name":"main","dir":"","state":"ok","week_used":%s,"five_hour":%s},{"name":"alt","dir":"%s","state":"ok","week_used":20,"five_hour":5}]' \
    "$1" "$2" "$HOME/.claude-acct2"
}

@test "an account at its week cap: its idle sessions move to the room account, a dialog is listed, busy and shell wait" {
  doc "[$(acct_row hub/dotfiles:2 %27 idle main), $(acct_row hub/dotfiles:3 %19 waiting main),
        $(acct_row hub/dotfiles:4 %35 shell main), $(acct_row hub/dotfiles:5 %17 busy main),
        $(acct_row hub/dotfiles:7 %45 idle main '["manual"]'), $(acct_row lab/agent-1:1 %5 idle alt)]"
  STUB_ACCTS="$(accts 100 40)" STUB_PANE='You have hit your weekly limit\n' run "$SH" due
  assert_success
  assert_output "limit: hub/dotfiles:2 idle on main, out of usage; then: claude-acct move hub/dotfiles:2 --to alt
limit: hub/dotfiles:3 on main, out of usage, is in a dialog; then: list it for the human, and fleet-shepherd skip it"
  # the account read covers them: no pane on main is read for the limit text
  run grep -sc capture-pane "$HOME/tmux.calls"
  refute_output --regexp '^[1-9]'
}

@test "a 5h cap moves sessions too; under both caps nothing moves; the pane line still reads sessions on other accounts" {
  doc "[$(acct_row hub/dotfiles:2 %27 idle main), $(idle_row lab/agent-1:1 %5 9)]"
  STUB_ACCTS="$(accts 50 100)" run "$SH" due
  assert_success
  assert_output 'limit: hub/dotfiles:2 idle on main, out of usage; then: claude-acct move hub/dotfiles:2 --to alt'
  # Negative control: main under both caps is not out of usage
  STUB_ACCTS="$(accts 99 99)" run "$SH" due
  assert_failure
  STUB_ACCTS="$(accts 99 99)" STUB_PANE='hit your weekly limit\n' run "$SH" due
  assert_output 'limit: lab/agent-1:1 stopped on the usage limit'
}

@test "an account out of usage with no room anywhere is one line for the human" {
  doc "[$(acct_row hub/dotfiles:2 %27 idle main), $(acct_row hub/dotfiles:3 %19 idle main)]"
  STUB_ACCTS="$(accts 100 40)" STUB_NO_ROOM=1 run "$SH" due
  assert_success
  assert_output 'limit: main is out of usage and no account has room; then: tell the human once (2 live on it), and fleet-shepherd skip it'
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
  run "$SH" check
  assert_success
  assert_line 'nudge DONE: a f-a'
  assert_equal "$(cat "$HOME/sessions.calls")" --write
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
}

@test "check on a quiet fleet exits 1 and pages settled once" {
  doc "[$(row a NEEDS false true)]"
  run "$SH" check
  assert_failure 1
  assert_output ''
  "$SH" check || true
  [ "$(wc -l < "$HOME/pages")" -eq 1 ] || { cat "$HOME/pages"; false; }
}

@test "check exits 2 when the document cannot be refreshed, and run records FAILED with a pass started" {
  stub fleet-sessions 'exit 1'
  run "$SH" check
  assert_failure 2
  run "$SH" run
  assert_failure
  assert_equal "$(outcome)" FAILED
  assert_equal "$(starts)" 1
}

@test "a due line the last pass left as it was leads the next check as unhandled" {
  doc "[$(row a DONE false false), $(row b LANDED false false)]"
  run "$SH" check
  assert_output "$(printf 'nudge DONE: a f-a\nnudge LANDED: b f-b')"
  # the pass nudged a (so it is an escalate line now) and did nothing about b
  doc "[$(row a DONE true false), $(row b LANDED false false)]"
  run "$SH" check
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
  run "$SH" check
  assert_failure 1
  assert_output ''
  run cut -f2 "$FLEET_SHEPHERD_DIR/.skipped"
  assert_output 'the human is on it in chat'
  run tail -1 "$FLEET_SHEPHERD_DIR/log.md"
  assert_output --partial 'skipped: nudge DONE: a f-a: the human is on it in chat'
  doc "[]"; "$SH" check || true        # no longer due: the skip is spent
  doc "[$(row a DONE false false)]"
  run "$SH" check
  assert_output 'nudge DONE: a f-a'
}

@test "an overdue line an hour older is still the same line, and skip needs a why" {
  phase s1 shell 40 100
  phases_doc
  "$SH" check >/dev/null
  : > "$HOME/rows"; : > "$HOME/eta"; phase s1 shell 40 160; phases_doc
  run "$SH" check
  assert_line --partial 'unhandled: overdue: t-s1 phase 2/4'
  assert_line --partial 'open 160m'
  run "$SH" skip 'overdue: t-s1 phase 2/4'
  assert_failure 2
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
  run "$SH" check
  run "$SH" check
  assert_equal "$(grep -c 'budget: lab/w-agent-1:1 (q1 spent \$27, 1x its \$25 unsized budget), still working: carries on to 2x' "$FLEET_SHEPHERD_DIR/log.md")" 1
  assert_equal "$(parks)" 0
  [ ! -s "$HOME/pages" ]
  export STUB_COST='{"s-now":51}'   # the next checkpoint is news again
  run "$SH" check
  grep -q 'q1 spent \$51, 2x its \$25 unsized budget), still working: carries on to 3x' "$FLEET_SHEPHERD_DIR/log.md"
}

@test "budget: a STALLED session at its size budget is parked and paged once; an unpark buys one more budget" {
  budget_setup
  doc "[$(brow STALLED)]"
  export STUB_TASK='feat(x): y #size/s' STUB_COST='{"s-old1":7,"s-now":6}'   # $13 past the s $12
  run "$SH" check
  run "$SH" check
  assert_equal "$(parks)" 1
  grep -q 'budget: parked lab/w-agent-1:1 (q1 spent \$13, 1x its \$12 s budget, STALLED)' "$FLEET_SHEPHERD_DIR/log.md"
  assert_equal "$(grep -c 'lab/w-agent-1:1 parked at its budget' "$HOME/pages")" 1
  grep -q 'claude-acct unpark lab/w-agent-1:1' "$HOME/pages"
  export STUB_COST='{"s-now":25}'   # resumed and spent a second budget: the next checkpoint parks again
  run "$SH" check
  assert_equal "$(parks)" 2
}

@test "budget: WORKING past the last extension parks once its turn ends: one page, retried until it takes" {
  budget_setup
  doc "[$(brow WORKING)]"
  export STUB_COST='{"s-now":80}' STUB_PARK_BUSY=1   # 3x of $25
  run "$SH" check
  run "$SH" check
  assert_equal "$(parks)" 2
  grep -q 'budget: lab/w-agent-1:1 (q1 spent \$80, 3x its \$25 unsized budget, WORKING) parks once its turn ends' "$FLEET_SHEPHERD_DIR/log.md"
  unset STUB_PARK_BUSY
  run "$SH" check
  assert_equal "$(parks)" 3
  grep -q 'budget: parked lab/w-agent-1:1' "$FLEET_SHEPHERD_DIR/log.md"
  assert_equal "$(grep -c . "$HOME/pages")" 1
  run "$SH" check
  assert_equal "$(parks)" 3
}

@test "budget: a session waiting on the human is only logged, and an unread cost takes no checkpoint" {
  budget_setup
  doc "[$(brow NEEDS)]"
  export STUB_COST=''
  run "$SH" check
  [ ! -e "$FLEET_SHEPHERD_DIR/.budget" ] || [ ! -s "$FLEET_SHEPHERD_DIR/.budget" ]
  export STUB_COST='{"s-now":30}'
  run "$SH" check
  assert_equal "$(parks)" 0
  grep -q 'budget: lab/w-agent-1:1 (q1 spent \$30, 1x its \$25 unsized budget), NEEDS: not parked, it is not spending' "$FLEET_SHEPHERD_DIR/log.md"
}
