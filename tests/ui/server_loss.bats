#!/usr/bin/env bats
# Tier 3: a world server dies and one verb brings its conversations back, against a real server.
#
# The stub tier pins the decisions; this pins what only tmux and real processes can answer: real
# pane ids joined to their conversations, a server killed by a signal leaving a stale
# socket, and windows reopened under the same session and name by the real tmx ensure. `claude` is
# a fake that registers itself in the shared registry the way Claude does. agent-panel is Rust, not
# in this image: its stub answers from what each fake claude wrote about its own pane.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  FD="$REPO_ROOT/.local/bin/fleet-dispatch"
  SRV="batsloss$$"
  export FLEET_DISPATCH_DIR="$HOME/.agent/dispatch" RUN_ACCOUNT='' TMUX_SERVERS_DIR="$SANDBOX/manifests"
  export DISPATCH_PROJECT_MAP="$SANDBOX/map.json"
  echo '{}' > "$DISPATCH_PROJECT_MAP"
  REG="$HOME/.claude/sessions"
  # Space-free dir: the manifest is whitespace-delimited and $HOME here has a space on purpose.
  MDIR="$(mktemp -d /tmp/serverloss.XXXXXX)"
  mkdir -p "$TMUX_SERVERS_DIR" "$REG" "$HOME/.claude/projects/p" "$HOME/.agent/spin-down" "$MDIR/plan" "$MDIR/work"
  echo "desk $MDIR" > "$TMUX_SERVERS_DIR/$SRV.conf"
  ln -sf "$REPO_ROOT/.local/src/tmux/servers.sh" "$SANDBOX/bin/tmx"
  printf '#!/usr/bin/env bash\necho "agent-notify $*" >> "$HOME/pages"\n' > "$SANDBOX/bin/agent-notify"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/claude-acct"
  printf '#!/usr/bin/env bash\ncat "$HOME"/panel.* 2>/dev/null\nexit 0\n' > "$SANDBOX/bin/agent-panel"
  cat > "$SANDBOX/bin/claude" <<'FAKE'
#!/usr/bin/env bash
sid=fresh args="$*"
while [ $# -gt 0 ]; do [ "$1" = --resume ] && sid="$2"; shift; done
reg="$HOME/.claude/sessions/$$.json"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","kind":"interactive"}\n' "$$" "$sid" "$PWD" > "$reg"
srv=${TMUX##*/}
printf '{"pane":"%s/%s","session_id":"%s","cwd":"%s"}\n' "${srv%%,*}" "$TMUX_PANE" "$sid" "$PWD" > "$HOME/panel.$sid"
echo "$args" > "$HOME/argv.$sid"
read -r _
FAKE
  chmod +x "$SANDBOX/bin/agent-notify" "$SANDBOX/bin/claude-acct" "$SANDBOX/bin/agent-panel" "$SANDBOX/bin/claude"

  "$SANDBOX/bin/tmx" ensure "$SRV" >/dev/null
  conversation plan "$MDIR/plan" conv-plan
  conversation work "$MDIR/work" conv-work
  conversation closed "$MDIR/work" conv-closed
  printf '{"permissionMode":"bypassPermissions"}\n{"type":"permission-mode","permissionMode":"plan"}\n' > "$HOME/.claude/projects/p/conv-plan.jsonl"
  printf '{"permissionMode":"bypassPermissions"}\n' > "$HOME/.claude/projects/p/conv-work.jsonl"
}

teardown() {
  tmux_kill_named "${SRV:-}"
  [ -z "${MDIR:-}" ] || rm -rf "$MDIR"
  return 0
}

# conversation <window> <cwd> <id> -- a window running a fake claude on that conversation.
conversation() {
  tmux -L "$SRV" new-window -d -t '=desk:' -n "$1" -c "$2" "sh -c 'claude --resume $3; true'"
  tmux -L "$SRV" set-option -w -t "=desk:$1" automatic-rename off
  wait_until "grep -qs '\"$3\"' \"$REG\"/*.json"
}

windows() { tmux -L "$SRV" list-windows -t '=desk' -F '#W' | sort | tr '\n' ' '; }

# kill_server -- the way 2026-11-04 went: no goodbye from the server, its panes hung up, a stale socket.
kill_server() {
  local pid p
  pid=$(tmux -L "$SRV" display-message -p '#{pid}')
  kill -9 "$pid"
  wait_until "! kill -0 $pid 2>/dev/null"
  for p in $(jq -r .pid "$REG"/*.json); do wait_until "! kill -0 $p 2>/dev/null"; done
}

@test "a killed server pages once, and restore reopens its conversations under the same names and modes" {
  "$FD" record
  assert_equal "$(jq -r '.panes[] | select(.window == "plan") | .claude + " " + .cwd' "$FLEET_DISPATCH_DIR/panes/$SRV.json")" "conv-plan $MDIR/plan"
  : > "$HOME/.agent/spin-down/game__conv-closed.fired"

  kill_server
  rm -f "$HOME"/argv.*
  "$FD" record
  run cat "$HOME/pages"
  assert_output --partial "tmux $SRV server died 3 conversation(s)"
  assert_equal "$(wc -l < "$HOME/pages" | tr -d ' ')" 1

  run "$FD" restore
  assert_success
  assert_output --partial "$SRV: reopened 2, failed 0"
  wait_until 'test -s "$HOME/argv.conv-plan" && test -s "$HOME/argv.conv-work"'
  [[ "$(windows)" == *plan* && "$(windows)" == *work* ]] || fail "windows are: $(windows)"
  [[ "$(windows)" != *closed* ]] || fail "a wound-down conversation came back: $(windows)"
  assert_equal "$(cat "$HOME/argv.conv-plan")" '--permission-mode plan --allow-dangerously-skip-permissions --resume conv-plan'
  assert_equal "$(cat "$HOME/argv.conv-work")" '--permission-mode bypassPermissions --resume conv-work'
  assert_equal "$(tmux -L "$SRV" display-message -p -t '=desk:plan' '#{pane_current_path}')" "$MDIR/plan"
  [ ! -e "$HOME/argv.conv-closed" ] || fail "resumed a wound-down conversation"
}

@test "the next record after a restore sees the reopened windows and pages nothing" {
  "$FD" record
  kill_server
  "$FD" restore >/dev/null
  wait_until 'test -s "$HOME/argv.conv-work"'
  wait_until "grep -qs 'conv-work' \"\$REG\"/*.json"
  "$FD" record
  assert_equal "$(wc -l < "$HOME/pages" | tr -d ' ')" 1
  assert_equal "$(jq -r '[.panes[] | select(.claude != "")] | length' "$FLEET_DISPATCH_DIR/panes/$SRV.json")" 3
}
