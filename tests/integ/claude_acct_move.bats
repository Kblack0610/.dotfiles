#!/usr/bin/env bats
# claude-acct move: exit a session's claude and resume it on the account with room, in the
# same pane. No tmux server and no real claude: tmux is a stub that plays the pane (it
# "exits" the fake claude when /exit is entered, shows the background-shell dialog when
# asked to, and "starts" a claude when a resume is typed or respawned), and /proc is a
# directory the test writes. The same flow against a real tmux server is
# tests/ui/claude_acct_move.bats, container only.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  ACCT="$REPO_ROOT/.local/bin/claude-acct"
  ALT="$HOME/.claude-alt"
  REG="$HOME/.claude/sessions"
  export CLAUDE_ACCT_PROC="$SANDBOX/proc" CLAUDE_ACCT_POLL=0.01 CLAUDE_ACCT_MOVE_TIMEOUT=3
  export CLAUDE_ACCT_CONFIG="$SANDBOX/accounts" FIX="$SANDBOX/fx"
  mkdir -p "$REG" "$ALT" "$XDG_CACHE_HOME/claude-acct" "$CLAUDE_ACCT_PROC" "$FIX" "$HOME/wt"
  printf 'main -\nalt %s\n' "$ALT" > "$CLAUDE_ACCT_CONFIG"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin/curl"
  printf '#!/usr/bin/env bash\necho "2.1.0 (Claude Code)"\n' > "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/claude"
  usage main 30 100
  usage alt 5 10
  write_tmux_stub
}

usage() {
  printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s}}\n' "$2" "$3" \
    > "$XDG_CACHE_HOME/claude-acct/$1.json"
}

# proc <pid> <ppid> [config dir] [argv...] -- a live process
proc() {
  local pid="$1" ppid="$2" dir="${3:-}"
  shift 3 2>/dev/null || shift $#
  mkdir -p "$CLAUDE_ACCT_PROC/$pid"
  echo "$pid (claude) S $ppid $pid $pid 0 -1" > "$CLAUDE_ACCT_PROC/$pid/stat"
  if [ -n "$dir" ]; then printf 'CLAUDE_CONFIG_DIR=%s\0' "$dir"; else printf 'TERM=x\0'; fi > "$CLAUDE_ACCT_PROC/$pid/environ"
  printf '%s\0' claude "$@" > "$CLAUDE_ACCT_PROC/$pid/cmdline"
}

# session <server> <name> <pane> <pane pid> <claude pid> <status> [config dir] [argv...]
session() {
  local server="$1" name="$2" pane="$3" ppid="$4" pid="$5" status="$6" dir="${7:-}"
  shift 7 2>/dev/null || shift $#
  echo "$name" >> "$FIX/sessions.$server"
  echo "$pane $ppid" >> "$FIX/panes.$server.$name"
  [ "$ppid" = "$pid" ] || proc "$ppid" 1 ""
  proc "$pid" "$ppid" "$dir" "$@"
  jq -n --argjson pid "$pid" --arg st "$status" --arg cwd "$HOME/wt" \
    '{pid: $pid, sessionId: "sid-1", cwd: $cwd, status: $st}' > "$REG/$pid.json"
  echo "$pid" > "$FIX/claude.pid"
}

# The pane. send-keys Enter after `-l /exit` ends the claude, or shows the dialog when
# $FIX/dialog holds one; a digit picks from it. A typed command (send-keys -l, then Enter) or
# a respawn-pane command "starts" claude: a new pid registered under the same session id,
# on whatever CLAUDE_CONFIG_DIR the command names.
write_tmux_stub() {
  cat > "$SANDBOX/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$FIX/calls.log"
server=""; [ "$1" = -L ] && { server="$2"; shift 2; }
verb="$1"; shift
target=""; prev=""; last=""
for a in "$@"; do [ "$prev" = -t ] && target="$a"; prev="$a"; last="$a"; done
start_claude() {
  local dir pid=900 cmd="$1"
  eval "set -- ${1#*CLAUDE_CONFIG_DIR=}"   # the command's own shell words; the first is the dir
  dir="$1"
  [ -f "$FIX/wrong-account" ] && dir=$(cat "$FIX/wrong-account")
  mkdir -p "$CLAUDE_ACCT_PROC/$pid"
  printf 'CLAUDE_CONFIG_DIR=%s\0' "$dir" > "$CLAUDE_ACCT_PROC/$pid/environ"
  printf '{"pid":%s,"sessionId":"sid-1","cwd":"x","status":"busy"}\n' "$pid" > "$HOME/.claude/sessions/$pid.json"
  printf '%s\n' "$cmd" > "$FIX/started"
}
end_claude() {
  local pid; pid=$(cat "$FIX/claude.pid")
  rm -rf "${CLAUDE_ACCT_PROC:?}/$pid" "$HOME/.claude/sessions/$pid.json" "$FIX/screen"
}
case "$verb" in
  has-session) grep -qxF -- "${target#=}" "$FIX/sessions.$server" 2>/dev/null; exit ;;
  list-panes) t="${target#=}"; cat "$FIX/panes.$server.${t%:}" 2>/dev/null ;;
  capture-pane) cat "$FIX/screen" 2>/dev/null; exit 0 ;;
  send-keys)
    if [ "$2" = -l ] || [ "$3" = -l ]; then printf '%s' "$last" > "$FIX/typed"; exit 0; fi
    case "$last" in
      Enter)
        typed=$(cat "$FIX/typed" 2>/dev/null); : > "$FIX/typed"
        if [ "$typed" = /exit ]; then
          if [ -f "$FIX/dialog" ]; then cp "$FIX/dialog" "$FIX/screen"; else end_claude; fi
        elif [ -n "$typed" ]; then start_claude "$typed"; fi ;;
      [0-9]) [ "$last" = "$(cat "$FIX/bg-option" 2>/dev/null)" ] && end_claude ;;
    esac ;;
  respawn-pane) start_claude "$last" ;;
esac
exit 0
STUB
  chmod +x "$SANDBOX/bin/tmux"
}

q() { printf %q "$1"; }

# socket <server> -- a socket file where tmux_servers looks; nothing listens on it
socket() {
  mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMUX_TMPDIR/tmux-$(id -u)/$1"
}

# Not `calls`: the sandbox helper defines that one, over the fixture dir the stock stubs use.
tmux_calls() { cat "$FIX/calls.log"; }


@test "a claude under the pane's shell is exited and resumed there, on the account with room" {
  session lab agent-1 %5 100 101 idle "" --permission-mode bypassPermissions 'old brief'
  run "$ACCT" move agent-1 --server lab
  assert_success
  assert_output --partial 'from main to alt (5h 5%, 7d 10%)'
  assert_output --partial 'claude-acct: moved agent-1 to alt: claude 900, busy'
  run tmux_calls
  assert_line 'tmux -L lab send-keys -t %5 Escape'
  assert_line 'tmux -L lab send-keys -t %5 -l /exit'
  refute_output --partial 'remain-on-exit'
  refute_output --partial 'respawn-pane'
  run cat "$FIX/started"
  assert_output --partial "cd $(q "$HOME/wt") && CLAUDE_CONFIG_DIR=$(q "$ALT") claude --permission-mode bypassPermissions --resume sid-1 This\ session\ was\ moved\ from\ the\ main\ Claude\ account\ to\ alt"
  refute_output --partial 'old brief'
  refute_output --partial 'background\ shells'
}

@test "a claude that is the pane's own process is respawned in a pane held open" {
  session lab agent-2 %7 200 200 idle "" --model opus
  run "$ACCT" move agent-2 --server lab
  assert_success
  run tmux_calls
  assert_line 'tmux -L lab set-option -p -t %7 remain-on-exit on'
  assert_line --partial "tmux -L lab respawn-pane -t %7 -c $HOME/wt CLAUDE_CONFIG_DIR=$(q "$ALT") claude --model opus --resume sid-1"
  assert_line 'tmux -L lab set-option -p -u -t %7 remain-on-exit'
  # held open before the exit, released after the respawn
  local on exit respawn off
  on=$(grep -n 'remain-on-exit on' "$FIX/calls.log" | cut -d: -f1)
  exit=$(grep -n -- '-l /exit' "$FIX/calls.log" | cut -d: -f1)
  respawn=$(grep -n respawn-pane "$FIX/calls.log" | cut -d: -f1)
  off=$(grep -n 'remain-on-exit$' "$FIX/calls.log" | cut -d: -f1)
  (( on < exit && exit < respawn && respawn < off ))
}

@test "a session with a background shell answers the exit dialog with Move to background" {
  session lab agent-3 %9 300 301 shell ""
  printf '  1. Stay\n  2. Exit and stop tasks\n  3. Move to background and exit\n' > "$FIX/dialog"
  echo 3 > "$FIX/bg-option"
  run "$ACCT" move agent-3 --server lab
  assert_success
  assert_output --partial "answer /exit's dialog with 'Move to background'"
  run tmux_calls
  assert_line 'tmux -L lab send-keys -t %9 3'
  refute_line 'tmux -L lab send-keys -t %9 2'
  run cat "$FIX/started"
  assert_output --partial 'Your\ background\ shells\ kept\ running'
}

@test "a claude that never exits is reported, and a held pane is released" {
  session lab agent-4 %11 400 400 shell ""
  printf '  1. Exit and stop tasks\n  2. Stay\n' > "$FIX/dialog"
  CLAUDE_ACCT_MOVE_TIMEOUT=1 run "$ACCT" move agent-4 --server lab
  assert_failure
  assert_output --partial 'did not exit'
  run tmux_calls
  assert_line 'tmux -L lab set-option -p -u -t %11 remain-on-exit'
  refute_output --partial 'respawn-pane'
  refute_line --partial 'send-keys -t %11 1'
}

@test "a resume that comes up on another account is not a move" {
  session lab agent-6 %15 600 601 idle ""
  echo "$HOME/.claude" > "$FIX/wrong-account"
  CLAUDE_ACCT_MOVE_TIMEOUT=1 run "$ACCT" move agent-6 --server lab
  assert_failure
  assert_output --partial 'resume did not register'
  refute_output --partial 'moved agent-6'
}

@test "dry-run says what it would do and touches nothing" {
  session lab agent-5 %13 500 501 shell ""
  socket lab; socket hub
  run "$ACCT" move agent-5 --dry-run
  assert_success
  assert_output --partial 'claude-acct: move agent-5 (lab %13, claude 501, shell)'
  assert_output --partial 'claude runs under the pane'
  assert_output --partial "then: cd $(q "$HOME/wt") && CLAUDE_CONFIG_DIR=$(q "$ALT") claude --resume sid-1"
  run tmux_calls
  refute_output --partial 'send-keys'
  refute_output --partial 'set-option'
  [ ! -L "$ALT/sessions" ]
}

@test "refusals: busy, a dialog, already on the pick, no room, no data" {
  session lab busy %1 10 11 busy ""
  run "$ACCT" move busy --server lab
  assert_failure; assert_output 'claude-acct: move busy: busy mid-turn; move it once the turn ends'
  session lab ask %2 20 21 waiting ""
  run "$ACCT" move ask --server lab
  assert_failure; assert_output --partial 'permission or question dialog'
  session lab onalt %3 30 31 idle "$ALT"
  run "$ACCT" move onalt --server lab
  assert_failure; assert_output --partial 'already on alt, the account with the most room'
  usage alt 100 40
  run "$ACCT" move onalt --server lab
  assert_failure; assert_output --partial 'no account has room (the best is main: 5h 30%, 7d 100%)'
  rm "$XDG_CACHE_HOME"/claude-acct/*.json
  run "$ACCT" move onalt --server lab
  assert_failure; assert_output --partial 'no usage data'
  run tmux_calls
  refute_output --partial 'send-keys'
}

@test "refusals: no session, no claude, two claudes, a name on two servers" {
  run "$ACCT" move nope --server lab
  assert_failure; assert_output --partial 'no such session on server lab'
  run "$ACCT" move nope
  assert_failure; assert_output --partial 'no tmux server has that session'
  echo bare >> "$FIX/sessions.lab"; echo '%4 40' > "$FIX/panes.lab.bare"
  run "$ACCT" move bare --server lab
  assert_failure; assert_output --partial 'no live claude in its panes'
  session lab two %5 50 51 idle ""
  session lab two %6 60 61 idle ""
  run "$ACCT" move two --server lab
  assert_failure; assert_output --partial 'more than one claude'
  # both servers have a socket and a session named dup
  for s in hub lab; do socket "$s"; echo dup >> "$FIX/sessions.$s"; done
  run "$ACCT" move dup
  assert_failure; assert_output --partial 'on servers hub lab; pass --server'
}

@test "move takes one session and known flags only" {
  run "$ACCT" move
  [ "$status" -eq 2 ]; assert_output --partial 'name the tmux session'
  run "$ACCT" move a b
  [ "$status" -eq 2 ]; assert_output --partial 'one session at a time'
  run "$ACCT" move a --force
  [ "$status" -eq 2 ]; assert_output --partial "unknown flag '--force'"
  run "$ACCT" move a --server
  [ "$status" -eq 2 ]
}
