#!/usr/bin/env bats
# Tier 3: `fleet-shepherd run` on a REAL tmux server. Every run starts a pass in a window of the
# shepherd session, in ~/.dotfiles, unless the last pass is mid-sweep with nobody talking to it; a
# conversation with an older pass stays in its pane, renamed handed-<id> and told where it went, and
# a pass is found by its pane wherever a resume put it. Every other collaborator is a stub; the pass's
# agentctl-run records what it was given and signals the test through tmux wait-for instead of
# calling a model. Container only, like every ui test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  SH="$REPO_ROOT/.local/bin/fleet-shepherd"
  SRV="batsshep$$"
  export FLEET_SHEPHERD_SERVER="$SRV" FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd" FLEET_STATE_FILE="$HOME/state.json"
  export AGENTCTL_NAME=shepherd-test AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  mkdir -p "$FLEET_SHEPHERD_DIR" "$HOME/.dotfiles"
  jq -n '{schema:1, main:[], sessions:[{target:"a", bucket:"DONE", nudged:false, escalated:false, labels:[], fact:"f"}]}' > "$FLEET_STATE_FILE"
  stub fleet-sessions ':'
  stub fleet-assess '[ "${1:-}" = --blocked ] || echo "verdict: CLEAR load 0.5x"'
  stub agent-hold ':'
  stub agent-notify 'echo "$*" >> "$HOME/pages"'
  stub watch-companion-loop ':'
  stub fleet-bench ':'
  stub claude-acct 'case "$1" in
  room) [ -z "${STUB_NO_ROOM:-}" ] || exit 1; printf "%s\n" "${STUB_ROOM:-}" ;;
  pick) echo "$HOME/.claude-best" ;;
esac'
  stub agentctl ':'
  stub tmx 'echo "$*" >> "$HOME/tmx.calls"'
  # With $HOME/hold there, the pass stays in its pane the way a claude does, until the server goes.
  stub agentctl-run "pwd >> \"\$HOME/pass.cwd\"
echo \"\${CLAUDE_CONFIG_DIR:-}\" >> \"\$HOME/pass.config\"
printf '%s' \"\${@: -1}\" > \"\$HOME/last-prompt\"
\"$REAL_TMUX\" -L $SRV wait-for -S pass
[ ! -e \"\$HOME/hold\" ] || exec \"$REAL_TMUX\" -L $SRV wait-for hold"
  export PROM_LIB="$HOME/prom-stub.sh"
  echo 'prom_q() { printf %s "{\"status\":\"success\",\"data\":{\"result\":[{\"value\":[0,\"0\"]}]}}"; }' > "$PROM_LIB"

  # The hub's dotfiles world with an agent window, and the shepherd's with its shell window.
  t new-session -d -s dotfiles -n claude -c "$HOME"
  t set-option -g remain-on-exit on
  t set-hook -g pane-died 'wait-for -S died'
  t new-session -d -s shepherd -n base
}

teardown() {
  tmux_kill_named "${SRV:-}"
  return 0
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }
t() { "$REAL_TMUX" -L "$SRV" -f /dev/null "$@"; }
windows() { t list-windows -t "=$1" -F '#{window_name}' | paste -sd' '; }
# ran: block until the pass's stub has run in its pane (it signals channel pass), 10s guard.
ran() { timeout 10 "$REAL_TMUX" -L "$SRV" wait-for pass || fail "the pass never ran in its pane"; }
# ended: the same, then block until its pane is dead (the pane-died hook signals channel died).
ended() { ran; timeout 10 "$REAL_TMUX" -L "$SRV" wait-for died || fail "the pass's pane never died"; }
pass_id() { cut -f1 "$FLEET_SHEPHERD_DIR/.pass"; }
pass_pane() { cut -f4 "$FLEET_SHEPHERD_DIR/.pass"; }
# window_of <pane>: its window name; empty when the pane is gone.
window_of() { t list-panes -a -F '#{pane_id} #{window_name}' | awk -v p="$1" '$1 == p { print $2 }'; }
live() {
  mkdir -p "$HOME/.claude/sessions"
  jq -n --argjson p "$$" --arg s "$1" --arg st "$2" --arg t "${3:-}" '{pid:$p, sessionId:$s, status:$st} + (if $t == "" then {} else {tmux:$t} end)' > "$HOME/.claude/sessions/$1.json"
}
said() {
  mkdir -p "$HOME/.claude/projects/-home"
  jq -nc --arg at "$(date -u -d "@$2" +%FT%T.000Z)" --arg text "$3" '{type:"user", turnOrigin:"human", timestamp:$at, message:{content:$text}}' >> "$HOME/.claude/projects/-home/$1.jsonl"
}

@test "every run starts a pass in a window of session shepherd, in ~/.dotfiles; a finished one closes and session dotfiles is untouched" {
  run "$SH" run
  assert_success
  assert_output --partial 'attach -t shepherd:shepherd'
  ended
  assert_equal "$(windows shepherd)" 'base shepherd'
  assert_equal "$(windows dotfiles)" 'claude'
  assert_equal "$(cat "$HOME/pass.cwd")" "$HOME/.dotfiles"
  [ ! -e "$HOME/tmx.calls" ]
  # The pass ended having logged a move: the next run scores it WORKED, starts another, and only
  # the finished pass's pane goes.
  echo "- moved a" >> "$FLEET_SHEPHERD_DIR/log.md"
  run "$SH" run
  assert_success
  ended
  assert_equal "$(windows shepherd)" 'base shepherd'
  assert_equal "$(windows dotfiles)" 'claude'
  assert_equal "$(wc -l < "$HOME/pass.cwd")" 2
}

@test "the human talking to a pass: the sweep still runs, the old pane is named handed-<id> and told, then closes once idle" {
  touch "$HOME/hold"
  run "$SH" run
  ran
  local id pane new
  id="$(pass_id)" pane="$(pass_pane)"
  live "$id" busy
  said "$id" $(( $(date +%s) - 120 )) '/fleet-lead pass'
  said "$id" $(( $(date +%s) - 60 )) 'why is agent-47 stalled?'
  run "$SH" run
  assert_success
  refute_output --partial 'talking'
  ran
  new="$(pass_id)"
  [ "$new" != "$id" ]
  # same pane, alive, named as handed over, and the notice typed into it names the new pass
  assert_equal "$(window_of "$pane")" "handed-${id:0:8}"
  assert_equal "$(t list-panes -a -f "#{==:#{pane_id},$pane}" -F '#{pane_dead}')" 0
  run t capture-pane -p -J -t "$pane"
  assert_output --partial "[fleet-shepherd handover] This conversation was handed over to pass ${new:0:8}"
  run cat "$HOME/last-prompt"
  assert_line "Handover: $FLEET_SHEPHERD_DIR/.handover-$new"
  grep -qxF 'why is agent-47 stalled?' "$FLEET_SHEPHERD_DIR/.handover-$new"
  assert_equal "$(windows shepherd)" "base handed-${id:0:8} shepherd"
  # the human moved on, and the new pass is mid-sweep with nobody talking to it: the run starts
  # nothing, and the old one, idle, winds down
  echo "- answered the human" >> "$FLEET_SHEPHERD_DIR/log.md"
  live "$id" idle
  live "$new" busy
  run "$SH" run
  assert_success
  assert_output --partial "pass ${new:0:8} is mid-sweep"
  assert_equal "$(window_of "$pane")" ''
  assert_equal "$(windows shepherd)" 'base shepherd'
  assert_equal "$(pass_id)" "$new"
  # Negative control: the same pass idle, the run starts the next one.
  echo "- moved a" >> "$FLEET_SHEPHERD_DIR/log.md"
  live "$new" idle
  run "$SH" run
  assert_success
  ran
  [ "$(pass_id)" != "$new" ]
  assert_equal "$(windows shepherd)" 'base shepherd'
}

@test "a pass hub resumed in a window named by its id, in another session, is found by its pane and named handed over" {
  touch "$HOME/hold"
  run "$SH" run
  ran
  local id old where
  id="$(pass_id)" old="$(pass_pane)"
  where="$(t new-window -d -P -F '#{window_id}.#{pane_id}' -t '=dotfiles:' -n "${id:0:8}" "'$REAL_TMUX' -L $SRV wait-for hold")"
  t kill-pane -t "$old"
  live "$id" busy "dotfiles:$where"
  run "$SH" stats
  assert_success
  assert_equal "$(jq -c '[.pass_running, .pass_status, .attach]' <<< "$output")" "[true,\"busy\",\"tmux -L $SRV attach -t dotfiles:$(t list-windows -t =dotfiles -F '#{window_index} #{window_name}' | awk -v n="${id:0:8}" '$2 == n { print $1 }')\"]"
  # Negative control: the registry naming another session's pane is not the pass.
  live "$id" busy "other:$where"
  run "$SH" stats
  assert_equal "$(jq -r .attach <<< "$output")" "tmux -L $SRV attach -t shepherd:shepherd"
  live "$id" busy "dotfiles:$where"
  said "$id" $(( $(date +%s) - 120 )) '/fleet-lead pass'
  said "$id" $(( $(date +%s) - 60 )) 'why is agent-47 stalled?'
  run "$SH" run
  assert_success
  ran
  assert_equal "$(windows dotfiles)" "claude handed-${id:0:8}"
  assert_equal "$(windows shepherd)" 'base shepherd'
}

@test "the launcher a pane runs is on the account with room; with none it is the best one, and the human is paged once" {
  STUB_ROOM="$HOME/.claude-acct2" run "$SH" run
  assert_success
  ended
  assert_equal "$(tail -n 1 "$HOME/pass.config")" "$HOME/.claude-acct2"
  [ ! -e "$HOME/pages" ]
  echo "- moved a" >> "$FLEET_SHEPHERD_DIR/log.md"
  STUB_NO_ROOM=1 run "$SH" run
  assert_success
  ended
  assert_equal "$(tail -n 1 "$HOME/pass.config")" "$HOME/.claude-best"
  assert_equal "$(grep -c 'no account has room' "$HOME/pages")" 1
}

@test "killing session dotfiles leaves the pass running" {
  touch "$HOME/hold"
  run "$SH" run
  ran
  local pane; pane="$(pass_pane)"
  t kill-session -t '=dotfiles'
  assert_equal "$(window_of "$pane")" shepherd
  # Negative control: the same kill on the pass's own session does take it.
  t kill-session -t '=shepherd'
  assert_equal "$(window_of "$pane")" ''
}

@test "with no session shepherd the pass still starts: hub's manifest makes it" {
  export TMUX_SERVERS_DIR="$HOME/servers"
  mkdir -p "$TMUX_SERVERS_DIR"
  cp "$REPO_ROOT/.config/tmux-servers/hub.conf" "$TMUX_SERVERS_DIR/$SRV.conf"
  stub tmx "exec \"$REPO_ROOT/.local/bin/tmx\" \"\$@\""
  t kill-session -t '=shepherd'
  run "$SH" run
  assert_success
  ended
  t has-session -t '=shepherd'
  assert_equal "$(t list-windows -t =shepherd | wc -l)" 2
}
