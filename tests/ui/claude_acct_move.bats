#!/usr/bin/env bats
# Tier 3: claude-acct move against a REAL tmux server and real processes, container only.
# The integ tier pins the decisions against a stub; this pins what only tmux can answer: a
# pane held open by remain-on-exit survives its claude and is respawned in place, keeping
# the session and its @dispatch label, and a resume typed into a real shell starts there.
# `claude` is a fake that registers itself in the shared registry the way Claude does, and
# shows the background-shell dialog on /exit when FAKE_DIALOG is set.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  ACCT="$REPO_ROOT/.local/bin/claude-acct"
  ALT="$HOME/.claude-alt"
  REG="$HOME/.claude/sessions"
  SRV="batsacct$$"
  export CLAUDE_ACCT_CONFIG="$SANDBOX/accounts" CLAUDE_ACCT_POLL=0.05 CLAUDE_ACCT_MOVE_TIMEOUT=10
  mkdir -p "$REG" "$ALT" "$XDG_CACHE_HOME/claude-acct" "$HOME/wt"
  printf 'main -\nalt %s\n' "$ALT" > "$CLAUDE_ACCT_CONFIG"
  printf '{"five_hour":{"utilization":30},"seven_day":{"utilization":100}}\n' > "$XDG_CACHE_HOME/claude-acct/main.json"
  printf '{"five_hour":{"utilization":5},"seven_day":{"utilization":10}}\n' > "$XDG_CACHE_HOME/claude-acct/alt.json"
  cat > "$SANDBOX/bin/claude" <<'FAKE'
#!/usr/bin/env bash
sid=sid-1 args="$*"
while [ $# -gt 0 ]; do [ "$1" = --resume ] && sid="$2"; shift; done
reg="$HOME/.claude/sessions/$$.json"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","status":"%s"}\n' "$$" "$sid" "$PWD" "${FAKE_STATUS:-idle}" > "$reg"
trap 'rm -f "$reg"' EXIT
echo "fake claude $$ account=${CLAUDE_CONFIG_DIR:-main} args=$args"
while IFS= read -r line; do
  [ "${line//$'\e'/}" = /exit ] || continue
  [ -n "${FAKE_DIALOG:-}" ] || exit 0
  printf '  1. Exit and stop tasks\n  2. Move to background and exit\n  3. Stay\n'
  IFS= read -rn1 c
  echo "$c" >> "$HOME/choices"
  [ "$c" = 2 ] && exit 0
done
FAKE
  chmod +x "$SANDBOX/bin/claude"
}

teardown() {
  tmux_kill_named "${SRV:-}"
  return 0
}

t() { "$REAL_TMUX" -L "$SRV" -f /dev/null "$@"; }

# registered <account dir|main> -- one fake claude is up, on that account
registered() {
  local f pid
  for f in "$REG"/*.json; do
    [ -f "$f" ] || continue
    pid=$(jq -r .pid "$f")
    [ -d "/proc/$pid" ] || continue
    if [ "$1" = main ]; then ! tr '\0' '\n' < "/proc/$pid/environ" | grep -q '^CLAUDE_CONFIG_DIR='
    else tr '\0' '\n' < "/proc/$pid/environ" | grep -qxF "CLAUDE_CONFIG_DIR=$1"; fi && return 0
  done
  return 1
}

@test "a fleet-dispatch pane (claude is the pane) is respawned in place, label and all" {
  t new-session -d -s agent-d -c "$HOME/wt" "exec claude --model opus --permission-mode bypassPermissions 'the brief'"
  t set-option -t '=agent-d:' @dispatch 'proj: row'
  wait_until 'registered main'
  run "$ACCT" move agent-d --server "$SRV"
  assert_success
  assert_output --partial 'claude is the pane'
  assert_output --partial 'claude-acct: moved agent-d to alt'
  t has-session -t '=agent-d'
  [ "$(t show-options -qv -t '=agent-d:' @dispatch)" = 'proj: row' ]
  # the hold is released: the next exit closes the pane as before
  [ -z "$(t show-options -p -qv -t '=agent-d:' remain-on-exit)" ]
  wait_until 'registered "$ALT"'
  wait_until 't capture-pane -pJ -t "=agent-d:" | grep -q "account=$ALT args=--model opus --permission-mode bypassPermissions --resume sid-1 This session was moved"'
  run t capture-pane -p -t '=agent-d:'
  refute_output --partial 'the brief'
}

@test "a claude under a shell exits to it and the resume is typed there" {
  t new-session -d -s agent-s -c "$HOME/wt" "bash --norc --noprofile"
  t send-keys -t '=agent-s:' -l 'FAKE_STATUS=shell FAKE_DIALOG=1 claude --dangerously-skip-permissions'
  t send-keys -t '=agent-s:' Enter
  wait_until 'registered main'
  run "$ACCT" move agent-s --server "$SRV"
  assert_success
  assert_output --partial 'claude-acct: moved agent-s to alt'
  [ "$(cat "$HOME/choices")" = 2 ]
  wait_until 'registered "$ALT"'
  wait_until 't capture-pane -pJ -t "=agent-s:" | grep -q "account=$ALT args=--dangerously-skip-permissions --resume sid-1"'
}
