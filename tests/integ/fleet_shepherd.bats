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
  SH="$REPO_ROOT/.local/bin/fleet-shepherd"
  export AGENTCTL_NAME=shepherd-test AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  export FLEET_STATE_FILE="$HOME/state.json" FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  mkdir -p "$FLEET_SHEPHERD_DIR"
  stub fleet-sessions 'echo "$*" >> "$HOME/sessions.calls"'
  stub fleet-assess 'if [ "${1:-}" = --blocked ]; then printf "%b" "${STUB_BLOCKED:-}"; else echo "verdict: ${STUB_VERDICT:-CLEAR} load 0.5x"; fi'
  stub agent-hold 'printf "%s" "${STUB_HOLDS:-}"'
  stub agent-notify 'echo "$*" >> "$HOME/pages"'
  stub watch-companion-loop '[ "$1" = tripped ] && printf "%b" "${STUB_TRIPPED:-}"'
  stub fleet-bench '[ -z "${STUB_BENCH_FAIL:-}" ] || exit 1; if [ "$1" = eta ]; then printf "%b" "${STUB_ETA:-}"; else printf "%b" "${STUB_FINDINGS:-}"; fi'
  stub tmux 'echo "$*" >> "$HOME/tmux.calls"; [ -n "${STUB_TMUX_FAIL:-}" ] && [[ "$*" =~ $STUB_TMUX_FAIL ]] && exit 1; printf "%b" "${STUB_PANE:-}"'
  stub systemd-run 'echo "$*" >> "$HOME/systemd-run.calls"'
  stub tmx 'echo "$*" >> "$HOME/tmx.calls"'
  stub claude-acct '[ "$1" = pick ] && echo "$HOME/.claude-acct2"; [ "$1" = trust ] && echo "$*" >> "$HOME/trust.calls"; exit 0'
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
echo "holder=$FLEET_SHEPHERD_HOLDER config=${CLAUDE_CONFIG_DIR:-}" >> "$HOME/run.env"'
}
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

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
starts() { grep -cE 'respawn-pane|new-window' "$HOME/tmux.calls"; }
# live <id> <status>: claude's session file for the pass, on a live pid (this test's).
live() { mkdir -p "$HOME/.claude/sessions"; printf '{"pid":%s,"sessionId":"%s","status":"%s"}' "$$" "$1" "$2" > "$HOME/.claude/sessions/$$.json"; }
gone() { rm -f "$HOME/.claude/sessions/$$.json"; }
# said <id> <origin> <epoch> [assistant tool]: a transcript entry for the pass.
said() {
  mkdir -p "$HOME/.claude/projects/-home"
  if [ "$2" = assistant ]; then
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s"}]}}\n' "$3"
  else
    printf '{"type":"user","turnOrigin":"%s","timestamp":"%s"}\n' "$2" "$(date -u -d "@$3" +%FT%T.000Z)"
  fi >> "$HOME/.claude/projects/-home/$1.jsonl"
}
# aged <minutes>: the pass in the window started that long ago.
aged() { awk -F'\t' -v t="$(( $(date +%s) - $1 * 60 ))" 'BEGIN { OFS = FS } { $2 = t; print }' "$FLEET_SHEPHERD_DIR/.pass" > "$HOME/p" && mv "$HOME/p" "$FLEET_SHEPHERD_DIR/.pass"; }

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

@test "run with nothing due calls no model, records NOOP, and refreshes the document" {
  doc "[$(row a WORKING false false)]"
  run "$SH" run
  assert_success
  assert_output --partial 'nothing to move'
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
  assert_equal "$(outcome)" NOOP
  assert_equal "$(cat "$HOME/sessions.calls")" --write
  [ ! -e "$HOME/pages" ]
}

@test "a settled fleet pages once, and work coming back re-arms the page" {
  doc "[$(row a NEEDS false true)]"
  "$SH" run
  "$SH" run
  run cat "$HOME/pages"
  assert_output '-p normal -t shepherd fleet settled: 1 need you; rundown in '"$FLEET_SHEPHERD_DIR"'/log.md'
  [ "$(wc -l < "$HOME/pages")" -eq 1 ] || { cat "$HOME/pages"; false; }
  doc "[$(row a WORKING false false)]"
  "$SH" run
  [ ! -e "$FLEET_SHEPHERD_DIR/.settled" ]
}

@test "run with something due starts a pass in window shepherd of hub session dotfiles, as the runner, and does not wait for it" {
  doc "[$(row a DONE false false)]"
  run "$SH" run
  assert_success
  assert_output --partial 'started pass'
  local id; id="$(pass_id)"
  [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || fail "no pass id recorded: '$id'"
  grep -qxF -- "-L hub new-window -d -t =dotfiles: -n shepherd -c $HOME/.dotfiles bash $(printf %q "$FLEET_SHEPHERD_DIR/.pass.sh")" "$HOME/tmux.calls" ||
    fail "$(cat "$HOME/tmux.calls")"
  assert_equal "$(cut -f4 "$FLEET_SHEPHERD_DIR/.pass")" dotfiles:shepherd
  # labelled shepherd, so fleet-sessions and the sessions feed list the pass but count it nowhere
  assert_equal "$(cat "$FLEET_SHEPHERD_DIR/labels/$id" | paste -sd' ')" 'manual shepherd'
  grep -qxF -- 'trust hub =dotfiles:=shepherd bypass permissions on' "$HOME/trust.calls"
  grep -qxF -- "report --name shepherd-test item=pass ${id:0:8}: tmux -L hub attach -t dotfiles:shepherd" "$HOME/agentctl.calls"
  # the session exists, so nothing creates it, and no session is ever closed without a legacy pass
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
  assert_equal "$(cat "$HOME/run.env")" "holder=runner config=$HOME/.claude-acct2"
  # the window already there: the pass respawns it in place, never a second window
  rm "$FLEET_SHEPHERD_DIR/.pass"; : > "$HOME/tmux.calls"
  STUB_PANE='shepherd\n' run "$SH" run
  assert_success
  grep -qxF -- "-L hub respawn-pane -k -t =dotfiles:=shepherd -c $HOME/.dotfiles bash $(printf %q "$FLEET_SHEPHERD_DIR/.pass.sh")" "$HOME/tmux.calls" ||
    fail "$(cat "$HOME/tmux.calls")"
  run grep -c new-window "$HOME/tmux.calls"
  assert_output 0
}

@test "with no dotfiles session hub's own tmx ensure makes it, and with no tmux server it gets a scope of its own" {
  doc "[$(row a DONE false false)]"
  STUB_TMUX_FAIL='has-session' run "$SH" run
  assert_success
  assert_equal "$(cat "$HOME/tmx.calls")" 'ensure hub dotfiles'
  grep -q -- "-L hub new-window -d -t =dotfiles: -n shepherd -c $HOME/.dotfiles bash" "$HOME/tmux.calls"
  [ ! -e "$HOME/systemd-run.calls" ]
  rm "$FLEET_SHEPHERD_DIR/.pass"
  STUB_TMUX_FAIL='has-session|list-sessions' run "$SH" run
  assert_success
  assert_equal "$(cat "$HOME/systemd-run.calls")" '--user --scope --quiet tmx ensure hub dotfiles'
}

@test "migration: a pass in the old shepherd session is never killed busy, and its session closes once it is done" {
  doc "[$(row a DONE false false)]"
  # a pass recorded the old way, three fields, no window
  local old=11111111-2222-3333-4444-555555555555
  printf '%s\t%s\t1\n' "$old" "$(date +%s)" > "$FLEET_SHEPHERD_DIR/.pass"
  live "$old" busy
  run "$SH" run
  assert_output --partial "pass ${old:0:8} is busy"
  [ ! -e "$HOME/tmux.calls" ] || [ "$(starts)" = 0 ]
  # past the limit it is replaced in the new window, but its session stays: it is still busy
  aged 31
  run "$SH" run
  assert_equal "$(outcome)" STALLED
  grep -q -- "-L hub new-window -d -t =dotfiles: -n shepherd" "$HOME/tmux.calls"
  run grep -c kill-session "$HOME/tmux.calls"
  assert_output 0
  assert_equal "$(cat "$FLEET_SHEPHERD_DIR/.legacy")" "$old"
  # the old pass goes idle (the new one is gone and scored): the next run closes the old session
  live "$old" idle
  run "$SH" run
  assert_output --partial "closed session shepherd on hub, its pass ${old:0:8} done"
  grep -qxF -- '-L hub kill-session -t =shepherd' "$HOME/tmux.calls"
  [ ! -e "$FLEET_SHEPHERD_DIR/.legacy" ]
}

@test "migration: an idle pass in the old session is closed on the first run; a closed session only clears the record" {
  doc "[$(row a DONE false false)]"
  local old=11111111-2222-3333-4444-555555555555
  printf '%s\t%s\t1\n' "$old" "$(date +%s)" > "$FLEET_SHEPHERD_DIR/.pass"
  live "$old" idle
  run "$SH" run
  grep -qxF -- '-L hub kill-session -t =shepherd' "$HOME/tmux.calls"
  assert_equal "$(cut -f4 "$FLEET_SHEPHERD_DIR/.pass")" dotfiles:shepherd
  # negative control: the old session already gone, nothing is killed and the record clears
  : > "$HOME/tmux.calls"
  echo "$old" > "$FLEET_SHEPHERD_DIR/.legacy"
  STUB_TMUX_FAIL='has-session -t =shepherd' run "$SH" run
  run grep -c kill-session "$HOME/tmux.calls"
  assert_output 0
  [ ! -e "$FLEET_SHEPHERD_DIR/.legacy" ]
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

@test "a pass still working keeps its window and its due lines; past the limit it is STALLED and replaced" {
  doc "[$(row a DONE false false)]"
  "$SH" run
  local id; id="$(pass_id)"
  live "$id" busy
  run "$SH" run
  assert_success
  assert_output --partial "pass ${id:0:8} is busy"
  assert_equal "$(starts)" 1
  assert_equal "$(outcome)" NOOP
  # each run clears the runner's item, so the run that started nothing names the pass again
  assert_equal "$(grep -cxF -- "report --name shepherd-test item=pass ${id:0:8}: tmux -L hub attach -t dotfiles:shepherd" "$HOME/agentctl.calls")" 2
  # check did not run, so the line the pass holds is not counted against it
  assert_equal "$(grep -c -- --write "$HOME/sessions.calls")" 1
  live "$id" waiting
  run "$SH" run
  assert_equal "$(outcome)" BLOCKED
  aged 31
  run "$SH" run
  assert_failure
  assert_equal "$(starts)" 2
  assert_equal "$(outcome)" STALLED
  grep -qP "\t$id\tSTALLED\tpass ${id:0:8}: 1 due, 31m, still waiting, replaced$" "$FLEET_SHEPHERD_DIR/passes.tsv" ||
    fail "$(cat "$FLEET_SHEPHERD_DIR/passes.tsv")"
  [ "$(pass_id)" != "$id" ]
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
  said "$id" assistant ExitPlanMode
  run "$SH" run
  assert_failure
  assert_equal "$(cut -f3 "$FLEET_SHEPHERD_DIR/passes.tsv" | paste -sd' ')" 'WORKED STALLED STALLED'
}

@test "the human typing to a pass stands the runner down; the pass's own first prompt does not" {
  doc "[$(row a DONE false false)]"
  "$SH" run
  local id; id="$(pass_id)"
  aged 5
  live "$id" idle
  # The pass's own prompt, recorded three minutes after its start (a slow startup), is not the human.
  said "$id" human "$(( $(date +%s) - 2 * 60 ))"
  run "$SH" run
  assert_equal "$(starts)" 2
  id="$(pass_id)"
  aged 5
  said "$id" human "$(( $(date +%s) - 5 * 60 ))"
  said "$id" human "$(( $(date +%s) - 60 ))"
  live "$id" busy
  aged 40
  run "$SH" run
  assert_success
  assert_output --partial "the human is talking to pass ${id:0:8}"
  assert_equal "$(starts)" 2
  assert_equal "$(outcome)" NOOP
}

@test "a pass with only its own prompt is not talked-to, even just after local midnight" {
  # GNU `date -d ""` is today's local midnight; an empty last-human timestamp once read as that,
  # so for a lease after midnight every pass looked talked-to and the runner stood down.
  local s; s=$(( $(date -u +%s) % 86400 - 60 )); [ "$s" -ge 0 ] || s=$(( s + 86400 ))
  export TZ="ZZZ+$(( s / 3600 )):$(( s % 3600 / 60 )):$(( s % 60 ))" # local time is 00:01
  doc "[$(row a DONE false false)]"
  "$SH" run
  local id; id="$(pass_id)"
  aged 5
  live "$id" idle
  said "$id" human "$(( $(date +%s) - 4 * 60 ))"
  run "$SH" run
  refute_output --partial "the human is talking"
  assert_equal "$(starts)" 2
}

@test "a pass that cannot start in tmux is FAILED and leaves no pass behind" {
  doc "[$(row a DONE false false)]"
  STUB_TMUX_FAIL='respawn-pane|new-window' run "$SH" run
  assert_failure
  assert_equal "$(outcome)" FAILED
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass.proof" ]
}

@test "passes lists the pass in the window, then the scored ones newest first; open names a missing window" {
  run "$SH" passes
  assert_success
  assert_output --partial 'no passes yet'
  doc "[$(row a DONE false false)]"
  "$SH" run
  local first; first="$(pass_id)"
  echo "- moved" >> "$FLEET_SHEPHERD_DIR/log.md"
  "$SH" run
  run "$SH" passes
  assert_line --index 0 --regexp "^[0-9-]+ [0-9:]+	$(pass_id)	now	1 due, gone$"
  assert_line --index 1 --regexp "	$first	WORKED	"
  run "$SH" open
  assert_failure 2
  assert_output --partial 'no pass window: no dotfiles:shepherd on hub'
  run "$SH" open nosuchpass
  assert_failure 2
  # the window there: open attaches to it, outside tmux
  STUB_PANE='shepherd\n' TMUX='' run "$SH" open
  assert_success
  grep -qxF -- '-L hub attach -t =dotfiles:shepherd' "$HOME/tmux.calls"
  # a pass recorded the old way (no window) is opened in the old session
  cut -f1-3 "$FLEET_SHEPHERD_DIR/.pass" > "$HOME/p" && mv "$HOME/p" "$FLEET_SHEPHERD_DIR/.pass"
  STUB_PANE='1\n' TMUX='' run "$SH" open
  assert_success
  grep -qxF -- '-L hub attach -t =shepherd:' "$HOME/tmux.calls"
}

@test "a live interactive lease stands the runner down; a stale one or the runner's own does not" {
  doc "[$(row a DONE false false)]"
  "$SH" lease
  run "$SH" run
  assert_output --partial 'standing down'
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
  assert_equal "$(outcome)" NOOP
  printf 'interactive %s\n' "$(( $(date +%s) - 31 * 60 ))" > "$FLEET_SHEPHERD_DIR/.lease"
  run "$SH" run
  [ -e "$FLEET_SHEPHERD_DIR/.pass" ]
  rm "$FLEET_SHEPHERD_DIR/.pass"
  FLEET_SHEPHERD_HOLDER=runner "$SH" lease
  run "$SH" run
  [ -e "$FLEET_SHEPHERD_DIR/.pass" ]
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

agent-48 is on enemies-throw-real, PR #1680 red on PlayMode."
  run cat "$FLEET_SHEPHERD_DIR/log.md"
  assert_output "- 19:05 UTC 11-03: rundown: what is agent-48 doing (rundowns/2026-11-03T1905Z.md)
- 19:05 UTC 11-03: rundown: fleet at 19:05 (rundowns/2026-11-03T1905Z-2.md)"
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
  assert_output --partial 'nothing to move'
  run "$SH" run
  assert_output --partial 'blocked: pid 3546209 bfs, 7 threads on I/O for 38m, claude session unity-core-playground-agent-28'
  grep -q 'open /mnt/nas/private/immich/upload/thumbs' "$FLEET_SHEPHERD_DIR/.pass.sh"
}

@test "a process blocked in one pass only is not due" {
  doc "[$(row d WORKING false false)]"
  STUB_BLOCKED='4100000\t1\t5m\tUnity\tclaude\ts\tw\t-\t/usr/share/fonts/x.ttf\tUnity\n' run "$SH" run
  STUB_BLOCKED="$WALK" run "$SH" run
  assert_output --partial 'nothing to move'
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
  STUB_BENCH_FAIL=1 run "$SH" due
  assert_success
  assert_output --partial 'fleet-bench findings unreadable'
}

# phase <sid> <reason> <phase_min> <age_min> [done/total]: a WORKING state row and its `fleet-bench eta --json` row
phase() {
  local d="${5:-1/4}"
  jq -cn --arg s "$1" --arg r "$2" '{target:"t-\($s)", session_id:$s, bucket:"WORKING", reason:$r, nudged:false,
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

@test "an unreadable state document fails the pass; it does not read as a quiet fleet" {
  echo 'not json' > "$FLEET_STATE_FILE"
  run "$SH" run
  assert_failure 2
  assert_equal "$(outcome)" FAILED
  [ ! -e "$FLEET_SHEPHERD_DIR/.pass" ]
  [ ! -e "$HOME/pages" ]
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

@test "check exits 2 when the document cannot be refreshed, and run records FAILED" {
  stub fleet-sessions 'exit 1'
  run "$SH" check
  assert_failure 2
  run "$SH" run
  assert_failure
  assert_equal "$(outcome)" FAILED
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

@test "stuck: lines due and no pass started in an hour; a recent pass, a live interactive lease or nothing due is passing" {
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
  assert_success
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

@test "stats names the pass running now: its id, status, age and attach line; a pass from the old session attaches there" {
  printf '%s\tp1\tWORKED\tx\n' "$(date -u -d '30 minutes ago' '+%F %H:%M')" > "$FLEET_SHEPHERD_DIR/passes.tsv"
  printf 'sid-2\t%s\t3\tdotfiles:shepherd\n' "$(( $(date +%s) - 120 ))" > "$FLEET_SHEPHERD_DIR/.pass"
  live sid-2 busy
  run "$SH" stats
  assert_success
  assert_equal "$(jq -c '[.pass_running, .pass_id, .pass_status, .attach, .last_pass_id, .last_verdict]' <<< "$output")" \
    '[true,"sid-2","busy","tmux -L hub attach -t dotfiles:shepherd","p1","WORKED"]'
  age="$(jq .pass_age_s <<< "$output")"
  [ "$age" -ge 115 ] && [ "$age" -le 180 ] || fail "pass_age_s $age"
  assert_equal "$(jq .last_pass_age_s <<< "$output")" "$age"
  gone
  printf 'sid-2\t%s\t3\n' "$(( $(date +%s) - 120 ))" > "$FLEET_SHEPHERD_DIR/.pass"
  assert_equal "$("$SH" stats | jq -c '[.pass_status, .attach]')" '["gone","tmux -L hub attach -t shepherd"]'
}
