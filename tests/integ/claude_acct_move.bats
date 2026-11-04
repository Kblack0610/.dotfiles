#!/usr/bin/env bats
# claude-acct move, park and unpark: exit a session's claude and resume it on the account
# with room, in the same pane (move), or exit it and leave a ledger (park) that resumes it
# later (unpark). No tmux server and no real claude: tmux is a stub that plays the pane (it
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
  case "$cmd" in
    *"env -u CLAUDE_CONFIG_DIR "*) dir="" ;;   # the main account
    *) eval "set -- ${1#*CLAUDE_CONFIG_DIR=}"   # the command's own shell words; the first is the dir
       dir="$1" ;;
  esac
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
  display-message)
    if [ "$last" = '#{pane_in_mode}' ]; then [ -f "$FIX/mode" ] && echo 1 || echo 0; fi
    exit 0 ;;
  send-keys)
    # a pane in a mode takes every key, logged so a test can assert none reached one
    if [ -f "$FIX/mode" ]; then printf '%s\n' "$last" >> "$FIX/mode-keys"; exit 0; fi
    if [ "$2" = -l ] || [ "$3" = -l ]; then printf '%s' "$last" > "$FIX/typed"; exit 0; fi
    case "$last" in
      Enter)
        typed=$(cat "$FIX/typed" 2>/dev/null); : > "$FIX/typed"
        if [ "$typed" = /exit ]; then
          if [ -f "$FIX/dialog" ]; then cp "$FIX/dialog" "$FIX/screen"; else end_claude; fi
        elif [ -n "$typed" ] && [ -f "$FIX/trust" ]; then
          # an account new to the folder asks to trust it first; "No, exit" is the default
          printf '%s' "$typed" > "$FIX/pending"; mv "$FIX/trust" "$FIX/screen"
        elif [ -n "$typed" ]; then start_claude "$typed"
        elif [ -f "$FIX/pending" ] && [ -f "$FIX/down" ]; then
          rm -f "$FIX/screen" "$FIX/down"; start_claude "$(cat "$FIX/pending")"; rm -f "$FIX/pending"
        fi ;;
      Down) touch "$FIX/down" ;;
      [0-9]) [ "$last" = "$(cat "$FIX/bg-option" 2>/dev/null)" ] && end_claude ;;
    esac ;;
  # copy-mode -q leaves any mode, unless the test made it stick
  copy-mode) [ "$1" = -q ] && [ ! -f "$FIX/mode-stuck" ] && rm -f "$FIX/mode"; exit 0 ;;
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

@test "a session with background shells is refused, and the shells are listed" {
  session lab agent-3 %9 300 301 shell ""
  proc 302 301 ""
  printf '/bin/zsh\0-c\0source /s/shell-snapshots/x.sh && eval '"'"'scripts/test/suite.sh'"'"'\0' > "$CLAUDE_ACCT_PROC/302/cmdline"
  run "$ACCT" move agent-3 --server lab
  assert_failure
  assert_output --partial 'background shells are running; move it once they finish, or pass --stop-shells'
  assert_output --partial "shell 302  scripts/test/suite.sh"
  run tmux_calls
  refute_output --partial 'send-keys'
}

@test "--stop-shells answers the exit dialog with Exit and stop tasks, never Move to background" {
  session lab agent-3 %9 300 301 shell ""
  printf '  1. Stay\n  2. Move to background and exit\n  3. Exit and stop tasks\n' > "$FIX/dialog"
  echo 3 > "$FIX/bg-option"
  run "$ACCT" move agent-3 --server lab --stop-shells
  assert_success
  assert_output --partial "--stop-shells: answer /exit's dialog with 'Exit and stop tasks'"
  run tmux_calls
  assert_line 'tmux -L lab send-keys -t %9 3'
  refute_line 'tmux -L lab send-keys -t %9 2'
  run cat "$FIX/started"
  assert_output --partial 'The\ move\ stopped\ your\ background\ shells'
}

@test "a claude that never exits is reported, its dialog closed, and a held pane released" {
  session lab agent-4 %11 400 400 shell ""
  printf '  1. Stay\n  2. Move to background and exit\n' > "$FIX/dialog"
  CLAUDE_ACCT_MOVE_TIMEOUT=1 run "$ACCT" move agent-4 --server lab --stop-shells
  assert_failure
  assert_output --partial 'did not exit'
  run tmux_calls
  assert_line 'tmux -L lab set-option -p -u -t %11 remain-on-exit'
  refute_output --partial 'respawn-pane'
  refute_line --partial 'send-keys -t %11 1'
  refute_line --partial 'send-keys -t %11 2'
  [ "$(grep -c 'send-keys -t %11 Escape' "$FIX/calls.log")" -eq 2 ]
}

@test "an idle session's unexpected dialog is never answered" {
  session lab agent-7 %17 700 701 idle ""
  printf '  1. Exit and stop tasks\n  2. Move to background and exit\n' > "$FIX/dialog"
  CLAUDE_ACCT_MOVE_TIMEOUT=1 run "$ACCT" move agent-7 --server lab
  assert_failure
  run tmux_calls
  refute_line --partial 'send-keys -t %17 1'
  refute_line --partial 'send-keys -t %17 2'
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
  session lab agent-5 %13 500 501 idle ""
  socket lab; socket hub
  run "$ACCT" move agent-5 --dry-run
  assert_success
  assert_output --partial 'claude-acct: move agent-5 (lab %13, claude 501, idle)'
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
  assert_failure; assert_output --partial 'no account has room (the best is alt: 5h 100%, 7d 40%)'
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

@test "move --to resumes on the named account, not the one with the most room" {
  usage main 20 30
  usage alt 5 10
  session lab agent-8 %19 800 801 idle "$ALT"
  run "$ACCT" move agent-8 --server lab --to main
  assert_success
  assert_output --partial 'from alt to main (5h 20%, 7d 30%)'
  run cat "$FIX/started"
  assert_output --partial "cd $(q "$HOME/wt") && env -u CLAUDE_CONFIG_DIR claude --resume sid-1"
}

@test "move --to refuses an unknown account before touching tmux, and a full or current one" {
  run "$ACCT" move agent-9 --server lab --to nobody
  [ "$status" -eq 2 ]; assert_output --partial "no account 'nobody'"
  run "$ACCT" move agent-9 --server lab --to
  [ "$status" -eq 2 ]; assert_output --partial '--to needs an account name'
  run "$ACCT" park agent-9 --server lab --to alt
  [ "$status" -eq 2 ]; assert_output --partial '--to is for move'
  [ ! -f "$FIX/calls.log" ]
  session lab agent-9 %21 900 901 idle "$ALT"
  run "$ACCT" move agent-9 --server lab --to alt
  assert_failure; assert_output --partial 'already on alt (5h 5%, 7d 10%)'
  usage main 100 40
  run "$ACCT" move agent-9 --server lab --to main
  assert_failure; assert_output --partial 'main has no room (5h 100%, 7d 40%)'
  run tmux_calls
  refute_output --partial 'send-keys'
}


# --- park and unpark ---

PARKED_LEDGER() { printf '%s' "$HOME/.agent/parked/$1"; }

@test "park exits the claude, leaves the pane at its shell, and writes the ledger" {
  session lab agent-1 %5 100 101 idle "" --model opus 'old brief'
  run "$ACCT" park agent-1 --server lab
  assert_success
  assert_output --partial 'claude-acct: park agent-1 (lab %5, claude 101, idle) on main'
  assert_output --partial "claude-acct: parked agent-1: $(PARKED_LEDGER agent-1); claude-acct unpark agent-1 resumes it"
  [ ! -d "$CLAUDE_ACCT_PROC/101" ]
  [ ! -f "$FIX/started" ]
  run tmux_calls
  assert_line 'tmux -L lab send-keys -t %5 -l /exit'
  refute_output --partial 'remain-on-exit'
  refute_output --partial 'respawn-pane'
  run cat "$(PARKED_LEDGER agent-1)"
  assert_line 'session=agent-1'
  assert_line 'server=lab'
  assert_line 'target=lab/agent-1'
  assert_line 'pane=%5'
  assert_line 'direct=0'
  assert_line 'pid=101'
  assert_line 'session_id=sid-1'
  assert_line "cwd=$HOME/wt"
  assert_line 'from='
  assert_line 'status=idle'
  assert_line 'why=park'
  assert_line 'resume=claude --model opus --resume sid-1'
  assert_line --regexp '^parked=[0-9]+$'
  refute_output --partial 'old brief'
  # renamed into place: no temp file is left beside it
  [ "$(ls -A "$HOME/.agent/parked")" = agent-1 ]
}

@test "park never refuses over accounts: already on the best one, or no usage data at all" {
  session lab onalt %3 30 31 idle "$ALT"
  rm "$XDG_CACHE_HOME"/claude-acct/*.json
  run "$ACCT" park onalt --server lab
  assert_success
  run cat "$(PARKED_LEDGER onalt)"
  assert_line "from=$ALT"
  # parked again, it has no claude to exit, and says where it is
  run "$ACCT" park onalt --server lab
  assert_failure
  assert_output --partial 'it is parked (claude-acct unpark onalt)'
}

@test "park --stop-shells stops remote waits, and refuses a local run without writing a ledger" {
  session lab wait %9 300 301 shell ""
  proc 302 301 ""
  printf '/bin/zsh\0-c\0source /s/shell-snapshots/x.sh && eval '"'"'until gh pr checks 9 | grep -q pass; do sleep 60; done'"'"'\0' > "$CLAUDE_ACCT_PROC/302/cmdline"
  printf '  1. Stay\n  2. Move to background and exit\n  3. Exit and stop tasks\n' > "$FIX/dialog"
  echo 3 > "$FIX/bg-option"
  run "$ACCT" park wait --server lab
  assert_failure; assert_output --partial 'pass --stop-shells'
  run "$ACCT" park wait --server lab --stop-shells
  assert_success
  assert_line --partial '    302  until gh pr checks 9'
  run tmux_calls
  assert_line 'tmux -L lab send-keys -t %9 3'
  run cat "$(PARKED_LEDGER wait)"
  assert_line 'status=shell'

  session lab gate %11 400 401 shell ""
  proc 402 401 ""
  printf '/bin/zsh\0-c\0source /s/shell-snapshots/x.sh && eval '"'"'scripts/test/ci-gate.sh --pr 9'"'"'\0' > "$CLAUDE_ACCT_PROC/402/cmdline"
  : > "$FIX/calls.log"
  run "$ACCT" park gate --server lab --stop-shells
  assert_failure
  assert_output --partial 'claude-acct: park gate: a local gate or suite is running (402: scripts/test/ci-gate.sh --pr 9'
  assert_output --partial 'stopping it throws the run away, so park it once the run ends'
  assert_output --partial 'shell 402  scripts/test/ci-gate.sh'
  [ ! -e "$(PARKED_LEDGER gate)" ]
  run tmux_calls
  refute_output --partial 'send-keys'
}

@test "park --dry-run says what it would do and writes nothing" {
  session lab agent-5 %13 500 501 idle ""
  run "$ACCT" park agent-5 --server lab --dry-run
  assert_success
  assert_output --partial "then: write $(PARKED_LEDGER agent-5); claude-acct unpark agent-5 resumes it with claude --resume sid-1"
  [ ! -e "$HOME/.agent/parked" ]
  run tmux_calls
  refute_output --partial 'send-keys'
}

@test "unpark resumes in the same pane on the account with room now, and deletes the ledger" {
  session lab agent-1 %5 100 101 idle "$ALT" --permission-mode bypassPermissions
  run "$ACCT" park agent-1 --server lab
  assert_success
  # parked on alt; by unpark time main has the room
  usage main 5 10
  usage alt 90 95
  run "$ACCT" unpark agent-1
  assert_success
  assert_output 'claude-acct: unparked agent-1 on main (5h 5%, 7d 10%): claude 900, busy'
  run cat "$FIX/started"
  assert_output --partial "cd $(q "$HOME/wt") && env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume sid-1 This\ session\ was\ parked\ to\ save\ Claude\ usage"
  assert_output --partial 're-check\ it'
  [ ! -e "$(PARKED_LEDGER agent-1)" ]
}

@test "unpark answers the trust prompt of an account new to the folder, once, and resumes" {
  session lab agent-3 %8 300 301 idle "$ALT" --permission-mode bypassPermissions
  run "$ACCT" park agent-3 --server lab
  assert_success
  usage main 5 10
  usage alt 90 95
  printf ' Quick safety check: Is this a project you created or one you trust?\n \xe2\x9d\xaf No, exit\n   Yes, I trust this folder\n' > "$FIX/trust"
  run "$ACCT" unpark agent-3
  assert_success
  assert_output 'claude-acct: unparked agent-3 on main (5h 5%, 7d 10%): claude 900, busy'
  [ "$(grep -c 'send-keys -t %8 Down' "$FIX/calls.log")" -eq 1 ]
  [ ! -e "$(PARKED_LEDGER agent-3)" ]
}

@test "unpark leaves copy mode in a scrolled pane before it types the resume" {
  session lab agent-4 %10 400 401 idle "$ALT" --permission-mode bypassPermissions
  run "$ACCT" park agent-4 --server lab
  assert_success
  usage main 5 10
  usage alt 90 95
  echo copy-mode > "$FIX/mode"
  run "$ACCT" unpark agent-4
  assert_success
  assert_output 'claude-acct: unparked agent-4 on main (5h 5%, 7d 10%): claude 900, busy'
  run tmux_calls
  assert_line 'tmux -L lab copy-mode -q -t %10'
  [ ! -e "$FIX/mode-keys" ]
  [ ! -e "$(PARKED_LEDGER agent-4)" ]
}

@test "unpark closes the session picker (tree mode) before it types the resume" {
  session lab agent-4 %10 400 401 idle "$ALT" --permission-mode bypassPermissions
  run "$ACCT" park agent-4 --server lab
  assert_success
  usage main 5 10
  usage alt 90 95
  echo tree-mode > "$FIX/mode"
  run "$ACCT" unpark agent-4
  assert_success
  run tmux_calls
  assert_line 'tmux -L lab copy-mode -q -t %10'
  [ ! -e "$FIX/mode-keys" ]
  [ ! -e "$(PARKED_LEDGER agent-4)" ]
}

@test "unpark types nothing into a pane mode that will not close, and keeps the ledger" {
  session lab agent-4 %10 400 401 idle "$ALT" --permission-mode bypassPermissions
  run "$ACCT" park agent-4 --server lab
  assert_success
  usage main 5 10
  usage alt 90 95
  echo tree-mode > "$FIX/mode"; touch "$FIX/mode-stuck"
  run "$ACCT" unpark agent-4
  assert_failure
  assert_output --partial 'in a tmux mode that did not close; typed nothing'
  [ ! -e "$FIX/mode-keys" ]
  [ -e "$(PARKED_LEDGER agent-4)" ]
}

@test "park closes the session picker before it types /exit" {
  session lab agent-5 %11 500 501 idle "$ALT" --permission-mode bypassPermissions
  echo tree-mode > "$FIX/mode"
  run "$ACCT" park agent-5 --server lab
  assert_success
  [ ! -e "$FIX/mode-keys" ]
  [ -e "$(PARKED_LEDGER agent-5)" ]
}

@test "park types nothing into a pane mode that will not close, and writes no ledger" {
  session lab agent-5 %11 500 501 idle "$ALT" --permission-mode bypassPermissions
  echo tree-mode > "$FIX/mode"; touch "$FIX/mode-stuck"
  run "$ACCT" park agent-5 --server lab
  assert_failure
  assert_output --partial 'in a tmux mode that did not close; typed nothing'
  [ ! -e "$FIX/mode-keys" ]
  [ ! -e "$(PARKED_LEDGER agent-5)" ]
}

@test "unpark respawns a pane that was its claude, held open while parked" {
  session lab agent-2 %7 200 200 idle "" --model opus
  run "$ACCT" park agent-2 --server lab
  assert_success
  run tmux_calls
  assert_line 'tmux -L lab set-option -p -t %7 remain-on-exit on'
  refute_line 'tmux -L lab set-option -p -u -t %7 remain-on-exit'
  run cat "$(PARKED_LEDGER agent-2)"
  assert_line 'direct=1'
  run "$ACCT" unpark agent-2
  assert_success
  run tmux_calls
  assert_line --partial "tmux -L lab respawn-pane -t %7 -c $HOME/wt CLAUDE_CONFIG_DIR=$(q "$ALT") claude --model opus --resume sid-1 This\ session\ was\ parked"
  assert_line 'tmux -L lab set-option -p -u -t %7 remain-on-exit'
  [ ! -e "$(PARKED_LEDGER agent-2)" ]
}

@test "unpark refuses a session not parked, one whose tmux session is gone, and one already live" {
  run "$ACCT" unpark nope
  assert_failure; assert_output "claude-acct: unpark nope: not parked: no $(PARKED_LEDGER nope)"
  mkdir -p "$HOME/.agent/parked"
  printf '%s\n' session=ghost server=lab pane=%1 direct=0 pid=1 session_id=sid-1 "cwd=$HOME/wt" status=idle why=park 'resume=claude --resume sid-1' > "$(PARKED_LEDGER ghost)"
  run "$ACCT" unpark ghost
  assert_failure; assert_output --partial "its tmux session is gone from server lab; resume it by hand in $HOME/wt with claude --resume sid-1"
  [ -e "$(PARKED_LEDGER ghost)" ]
  session lab live %3 30 31 idle ""
  sed 's/^session=ghost$/session=live/' "$(PARKED_LEDGER ghost)" > "$(PARKED_LEDGER live)"
  run "$ACCT" unpark live
  assert_failure; assert_output --partial 'a claude is already live in its panes'
  run tmux_calls
  refute_output --partial 'send-keys'
}

@test "unpark --all resumes every parked session, and says so when none is" {
  run "$ACCT" unpark --all
  assert_success; assert_output 'claude-acct: unpark: nothing is parked'
  session lab a1 %5 100 101 idle ""
  "$ACCT" park a1 --server lab
  session lab a2 %6 110 111 idle ""
  "$ACCT" park a2 --server lab
  run "$ACCT" unpark --all
  assert_success
  assert_line --partial 'claude-acct: unparked a1 on alt'
  assert_line --partial 'claude-acct: unparked a2 on alt'
  [ -z "$(ls -A "$HOME/.agent/parked")" ]
}

@test "unpark takes one session or --all and nothing else" {
  run "$ACCT" unpark
  [ "$status" -eq 2 ]; assert_output --partial 'name the tmux session, or --all'
  run "$ACCT" unpark a b
  [ "$status" -eq 2 ]; assert_output --partial 'one session at a time'
  run "$ACCT" unpark --all a
  [ "$status" -eq 2 ]
  run "$ACCT" unpark --force
  [ "$status" -eq 2 ]; assert_output --partial "unknown flag '--force'"
  run "$ACCT" unpark ../x
  [ "$status" -eq 2 ]; assert_output --partial 'is not a tmux session name'
}

@test "move leaves no ledger; a move whose resume fails keeps one that unpark finishes" {
  session lab agent-1 %5 100 101 idle ""
  run "$ACCT" move agent-1 --server lab
  assert_success
  [ ! -e "$HOME/.agent/parked/agent-1" ]

  session lab agent-6 %15 600 601 idle ""
  echo "$HOME/.claude" > "$FIX/wrong-account"
  CLAUDE_ACCT_MOVE_TIMEOUT=1 run "$ACCT" move agent-6 --server lab
  assert_failure
  assert_output --partial "$(PARKED_LEDGER agent-6) is kept for claude-acct unpark"
  run cat "$(PARKED_LEDGER agent-6)"
  assert_line 'why=move'
  rm "$FIX/wrong-account" "$HOME/.claude/sessions/900.json"
  rm -rf "$CLAUDE_ACCT_PROC/900"
  run "$ACCT" unpark agent-6
  assert_success
  run cat "$FIX/started"
  assert_output --partial 'This\ session\ was\ moved\ from\ the\ main\ Claude\ account\ to\ alt'
  [ ! -e "$(PARKED_LEDGER agent-6)" ]
}
