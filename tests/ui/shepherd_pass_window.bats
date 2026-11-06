#!/usr/bin/env bats
# Tier 3: `fleet-shepherd run` on a REAL tmux server. Every run starts a pass in the one pass window,
# hub:shepherd, in ~/.dotfiles, unless the last pass is mid-sweep with nobody talking to it, or the
# human is talking to it while it answers or is young. The new pass takes the last one's pane with
# respawn-pane, so a run makes no window in hub after the first, and a pass is found by its pane
# wherever a resume put it. Every other collaborator is a stub; the pass's
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
  room) [ -z "${STUB_NO_ROOM:-}" ] || { echo "claude-acct: no account has room; alt is the closest, 1 point over its weekly pace" >&2; exit 1; }
        printf "%s\n" "${STUB_ROOM:-}" ;;
  pick) echo "$HOME/.claude-best" ;;
esac'
  stub agentctl ':'
  stub tmx 'echo "$*" >> "$HOME/tmx.calls"'
  # With $HOME/hold there, the pass stays in its pane the way a claude does, until the server goes.
  stub agentctl-run "pwd >> \"\$HOME/pass.cwd\"
echo \"\${AGENTCTL_ACCOUNT:-}\" >> \"\$HOME/pass.config\"
printf '%s' \"\${@: -1}\" > \"\$HOME/last-prompt\"
\"$REAL_TMUX\" -L $SRV wait-for -S pass
[ ! -e \"\$HOME/hold\" ] || exec \"$REAL_TMUX\" -L $SRV wait-for hold"
  export PROM_LIB="$HOME/prom-stub.sh"
  echo 'prom_q() { printf %s "{\"status\":\"success\",\"data\":{\"result\":[{\"value\":[0,\"0\"]}]}}"; }' > "$PROM_LIB"

  # hub as the human has it: the landing session, and dotfiles with an agent window.
  t new-session -d -s dotfiles -n claude -c "$HOME"
  t set-option -g remain-on-exit on
  t set-hook -g pane-died 'wait-for -S died'
  t new-session -d -s hub -n base
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
# aged <minutes>: the pass running now started that long ago.
aged() { awk -F'\t' -v OFS='\t' -v t="$(( $(date +%s) - $1 * 60 ))" '{ $2 = t } 1' "$FLEET_SHEPHERD_DIR/.pass" > "$FLEET_SHEPHERD_DIR/.pass.t" && mv "$FLEET_SHEPHERD_DIR/.pass.t" "$FLEET_SHEPHERD_DIR/.pass"; }
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

@test "every run starts a pass in the one window hub:shepherd, in ~/.dotfiles; the next takes the finished one's pane, and session dotfiles is untouched" {
  run "$SH" run
  assert_success
  assert_output --partial 'attach -t hub:shepherd'
  ended
  local pane; pane="$(pass_pane)"
  assert_equal "$(windows hub)" 'base shepherd'
  assert_equal "$(windows dotfiles)" 'claude'
  assert_equal "$(cat "$HOME/pass.cwd")" "$HOME/.dotfiles"
  [ ! -e "$HOME/tmx.calls" ]
  # The pass ended having logged a move: the next run scores it WORKED and starts another in the
  # finished pass's pane.
  echo "- moved a" >> "$FLEET_SHEPHERD_DIR/log.md"
  run "$SH" run
  assert_success
  ended
  assert_equal "$(windows hub)" 'base shepherd'
  assert_equal "$(windows dotfiles)" 'claude'
  assert_equal "$(pass_pane)" "$pane"
  assert_equal "$(wc -l < "$HOME/pass.cwd")" 2
  assert_equal "$(tail -n 1 "$HOME/pass.cwd")" "$HOME/.dotfiles"
}

@test "the human talking to a pass: no new pass while it answers; idle past the limit, the next takes its pane with the conversation" {
  touch "$HOME/hold"
  run "$SH" run
  ran
  local id pane new
  id="$(pass_id)" pane="$(pass_pane)"
  live "$id" busy
  said "$id" $(( $(date +%s) - 120 )) '/fleet-lead pass'
  said "$id" $(( $(date +%s) - 60 )) 'why is agent-47 stalled?'
  aged 40
  run "$SH" run
  assert_success
  assert_output --partial "the human is talking to pass ${id:0:8}"
  assert_equal "$(pass_id)" "$id"
  assert_equal "$(windows hub)" 'base shepherd'
  # Negative control: the same pass idle past the limit is replaced, in the same pane and window.
  echo "- answered the human" >> "$FLEET_SHEPHERD_DIR/log.md"
  live "$id" idle
  run "$SH" run
  assert_success
  ran
  new="$(pass_id)"
  [ "$new" != "$id" ]
  assert_equal "$(pass_pane)" "$pane"
  assert_equal "$(window_of "$pane")" shepherd
  assert_equal "$(t list-panes -a -f "#{==:#{pane_id},$pane}" -F '#{pane_dead}')" 0
  assert_equal "$(windows hub)" 'base shepherd'
  run cat "$HOME/last-prompt"
  assert_line "Handover: $FLEET_SHEPHERD_DIR/.handover-$new"
  grep -qxF 'why is agent-47 stalled?' "$FLEET_SHEPHERD_DIR/.handover-$new"
}

@test "a pass hub resumed in a window named by its id, in another session, is found by its pane and closed there" {
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
  assert_equal "$(jq -r .attach <<< "$output")" "tmux -L $SRV attach -t hub:shepherd"
  # idle, it is replaced: its pane outside the pass session closes, and the next pass gets the pass window
  live "$id" idle "dotfiles:$where"
  echo "- moved a" >> "$FLEET_SHEPHERD_DIR/log.md"
  run "$SH" run
  assert_success
  ran
  assert_equal "$(windows dotfiles)" 'claude'
  assert_equal "$(windows hub)" 'base shepherd'
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
  assert_equal "$(grep -c 'alt is the closest, 1 point over its weekly pace' "$HOME/pages")" 1
}

@test "killing session dotfiles leaves the pass running" {
  touch "$HOME/hold"
  run "$SH" run
  ran
  local pane; pane="$(pass_pane)"
  t kill-session -t '=dotfiles'
  assert_equal "$(window_of "$pane")" shepherd
  # Negative control: the same kill on the pass's own session does take it.
  t kill-session -t '=hub'
  assert_equal "$(window_of "$pane")" ''
}

@test "with no session hub the pass still starts: hub's manifest makes it" {
  export TMUX_SERVERS_DIR="$HOME/servers"
  mkdir -p "$TMUX_SERVERS_DIR"
  cp "$REPO_ROOT/.config/tmux-servers/hub.conf" "$TMUX_SERVERS_DIR/$SRV.conf"
  stub tmx "exec \"$REPO_ROOT/.local/bin/tmx\" \"\$@\""
  # hub.conf roots session hub at ~/.notes, and tmx ensure skips an entry whose dir is missing
  mkdir -p "$HOME/.notes"
  t kill-session -t '=hub'
  run "$SH" run
  assert_success
  ran
  t has-session -t '=hub'
  assert_equal "$(window_of "$(pass_pane)")" shepherd
}

@test "with the shipped manifests the pass is window shepherd of session hub, which no manifest declares, and the next run makes no window" {
  export TMUX_SERVERS_DIR="$HOME/servers"
  mkdir -p "$TMUX_SERVERS_DIR"
  cp "$REPO_ROOT/.config/tmux-servers/hub.conf" "$TMUX_SERVERS_DIR/$SRV.conf"
  # tmx ensure would give a declared window a shell or a second pass: the runner owns this one.
  run grep -E '^hub:shepherd[[:space:]]' "$REPO_ROOT/.config/tmux-servers/hub.conf"
  assert_failure
  [ ! -e "$REPO_ROOT/.config/tmux-servers/shepherd.conf" ]
  unset FLEET_SHEPHERD_SERVER
  stub tmux-world "exec \"$REPO_ROOT/.local/bin/tmux-world\" \"\$@\""
  stub tmx "exec \"$REPO_ROOT/.local/bin/tmx\" \"\$@\""
  touch "$HOME/hold"
  run "$SH" run
  assert_success
  assert_output --partial "tmux -L $SRV attach -t hub:shepherd"
  ran
  local id pane; id="$(pass_id)" pane="$(pass_pane)"
  assert_equal "$(window_of "$pane")" shepherd
  assert_equal "$(windows hub)" 'base shepherd'
  assert_equal "$(windows dotfiles)" 'claude'
  echo "- moved a" >> "$FLEET_SHEPHERD_DIR/log.md"
  live "$id" idle
  run "$SH" run
  assert_success
  ran
  [ "$(pass_id)" != "$id" ]
  assert_equal "$(pass_pane)" "$pane"
  assert_equal "$(windows hub)" 'base shepherd'
  assert_equal "$(windows dotfiles)" 'claude'
}
