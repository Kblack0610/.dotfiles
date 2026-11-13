#!/usr/bin/env bats
# agent-hold: the durable fleet-wide pause. `check` is what a resource gate (run.sh's slot
# helper) calls, so its exit code is the contract a shell loop obeys.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  HOLD="$REPO_ROOT/.local/bin/agent-hold"
  export AGENT_HOLD_DIR="$HOME/.agent/holds"
  # Record pages instead of sending them.
  NOTIFY_LOG="$SANDBOX/notify.log"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$NOTIFY_LOG" > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/agent-notify"
}

@test "check is free (exit 0) when nothing is held" {
  run "$HOLD" check unity-tests
  assert_success
  assert_output ''
}

@test "set then check reports the hold and exits 1" {
  run "$HOLD" set unity-tests --by coordinator "96 C, too many editors"
  assert_success
  run "$HOLD" check unity-tests
  assert_failure 1
  assert_output --partial 'by coordinator: 96 C, too many editors'
}

@test "a hold on one resource leaves another free" {
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" check gpu
  assert_success
}

@test "list prints one TSV row per hold" {
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" set gpu --by d "training"
  run "$HOLD" list
  assert_success
  assert_line --partial $'unity-tests\t'
  assert_line --partial $'\td\ttraining'
  [ "${#lines[@]}" -eq 2 ]
}

@test "release frees the resource and prints the roster for GO" {
  "$HOLD" set unity-tests --by c --roster agent-19,agent-21 "hot"
  run "$HOLD" release unity-tests
  assert_success
  assert_line 'roster: agent-19,agent-21'
  run "$HOLD" check unity-tests
  assert_success
}

@test "set and release both page low: the overseer acts on holds itself" {
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" release unity-tests
  run cat "$NOTIFY_LOG"
  assert_line --index 0 --partial '-p low -t hold: unity-tests'
  assert_line --index 1 --partial '-p low -t go: unity-tests'
}

@test "release of a resource that is not held fails" {
  run "$HOLD" release unity-tests
  assert_failure 1
}

@test "set without a reason is refused" {
  run "$HOLD" set unity-tests
  assert_failure 2
  [ ! -e "$AGENT_HOLD_DIR/unity-tests" ]
}

@test "a resource name cannot escape the hold dir" {
  run "$HOLD" set ../escape "x"
  assert_failure 2
  run "$HOLD" check ../escape
  assert_failure 2
  [ ! -e "$HOME/.agent/escape" ]
}

# A grant is GO as state. Caller identity is default_by: the tmux session, here (no TMUX in
# the sandbox) the working directory's basename.
as_session() { mkdir -p "$SANDBOX/$1" && cd "$SANDBOX/$1"; }

@test "grant on a resource that is not held fails" {
  run "$HOLD" grant unity agent-1
  assert_failure 1
  assert_output --partial 'not held'
}

@test "a granted session passes check; an ungranted one is still held" {
  "$HOLD" set unity --by shepherd "hot"
  run "$HOLD" grant unity agent-1
  assert_success
  as_session agent-1
  run "$HOLD" check unity
  assert_success
  as_session agent-2
  run "$HOLD" check unity
  assert_failure 1
}

@test "a grant matches a whole session name, not a prefix" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1
  as_session agent-11
  run "$HOLD" check unity
  assert_failure 1
}

@test "grants merge across calls without duplicates" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1 agent-2
  "$HOLD" grant unity agent-2 agent-3
  run "$HOLD" show unity
  assert_output --partial 'granted: agent-1,agent-2,agent-3'
  run "$HOLD" list
  assert_output --partial '(granted: agent-1,agent-2,agent-3)'
}

@test "a fresh set drops every earlier grant" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1
  "$HOLD" set unity --by shepherd "hot again"
  as_session agent-1
  run "$HOLD" check unity
  assert_failure 1
}

@test "claim: a second session is refused, the holder's check passes, release frees it" {
  run "$HOLD" claim mac-desktop --by agent-6 "store-console sign-in"
  assert_success
  assert_output 'claimed: mac-desktop'
  run "$HOLD" claim mac-desktop --by agent-9 "screenshots"
  assert_failure 1
  assert_output --partial 'busy: mac-desktop'
  assert_output --partial 'by agent-6 (other): store-console sign-in'
  run "$HOLD" check mac-desktop
  assert_failure 1
  run env TMUX= bash -c "cd \"\$(mktemp -d)\" && mkdir agent-6 && cd agent-6 && \"$HOLD\" check mac-desktop"
  assert_success
  run "$HOLD" claim mac-desktop --by agent-6 "store-console upload"
  assert_success
  assert_output 'claimed: mac-desktop (refreshed)'
  "$HOLD" release mac-desktop
  run "$HOLD" claim mac-desktop --by agent-9 "screenshots"
  assert_success
}

@test "claim --class records why the desktop is needed; busy names the holder's class and says when the caller outranks it" {
  run "$HOLD" classes
  assert_success
  [ "$(cut -f1 <<<"$output" | paste -sd' ')" = "auth legal release listing other" ]
  run "$HOLD" claim mac-desktop --by agent-6 --class nope "x"
  assert_failure 2
  assert_output --partial "unknown class 'nope'"
  [ ! -e "$AGENT_HOLD_DIR/mac-desktop" ]
  "$HOLD" claim mac-desktop --by agent-6 --class listing "screenshots"
  grep -qx 'class: listing' "$AGENT_HOLD_DIR/mac-desktop"
  run "$HOLD" list
  assert_output --partial $'agent-6\t[listing] screenshots'
  # A better class is told it goes next; it does not take the claim.
  run "$HOLD" claim mac-desktop --by agent-9 --class legal "xbox sign-up"
  assert_failure 1
  assert_output --partial 'by agent-6 (listing): screenshots (you outrank it'
  grep -qx 'by: agent-6' "$AGENT_HOLD_DIR/mac-desktop"
  # The same or a worse class hears only busy.
  run "$HOLD" claim mac-desktop --by agent-9 "explore"
  assert_failure 1
  refute_output --partial 'outrank'
  "$HOLD" release mac-desktop
  "$HOLD" claim mac-desktop --by agent-9 "explore"
  grep -qx 'class: other' "$AGENT_HOLD_DIR/mac-desktop"
}

@test "claim never replaces a set hold, and a set hold's owner is not let through by check" {
  "$HOLD" set unity-tests --by binks "hot"
  run "$HOLD" claim unity-tests --by agent-6 "mine"
  assert_failure 1
  run env TMUX= bash -c "cd \"\$(mktemp -d)\" && mkdir binks && cd binks && \"$HOLD\" check unity-tests"
  assert_failure 1
}

# lower: a fake /proc with one cgroup file per pid; the sandbox's systemctl stub logs each
# call to calls.log.
lower_setup() {
  export AGENT_HOLD_PROC="$SANDBOX/proc"
  local u="/user.slice/user-$(id -u).slice/user@$(id -u).service"
  fake_pid 101 "$u/session.slice/tmux-spawn-aaa.scope"
  fake_pid 102 "$u/session.slice/tmux-spawn-aaa.scope"
  fake_pid 103 "$u/app.slice/agentctl@sentinel.service"
  fake_pid 104 "$u/session.slice/kitty-9327-0.scope"
  fake_pid 105 "/system.slice/docker.service"
  fake_pid 106 "$u/session.slice/tmux-spawn-bbb.scope/run-r1.scope"
  fake_pid self "$u/session.slice/tmux-spawn-me.scope"
  fake_pid 107 "$u/session.slice/tmux-spawn-me.scope"
}
fake_pid() { mkdir -p "$AGENT_HOLD_PROC/$1"; printf '0::%s\n' "$2" > "$AGENT_HOLD_PROC/$1/cgroup"; }
systemctl_calls() { grep '^systemctl ' "$NOTES_FIXTURE/calls.log" 2>/dev/null | sed 's/^systemctl //'; }

@test "lower sets CPUWeight=1 once per unit and records it on the hold" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" lower unity-tests 101 102 103
  assert_success
  assert_line 'lowered: tmux-spawn-aaa.scope (pid 101)'
  assert_line 'lowered: tmux-spawn-aaa.scope (pid 102, already)'
  run systemctl_calls
  assert_output $'--user set-property --runtime tmux-spawn-aaa.scope CPUWeight=1\n--user set-property --runtime agentctl@sentinel.service CPUWeight=1'
  run "$HOLD" show unity-tests
  assert_line 'lowered: tmux-spawn-aaa.scope,agentctl@sentinel.service'
}

@test "lower leaves a desktop scope, a system unit, its own pane and a gone pid alone" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" lower unity-tests 104 105 107 999 101
  assert_failure 1
  assert_output --partial 'kitty-9327-0.scope, not a tmux pane'
  assert_output --partial 'pid 105 is not under this user'
  assert_output --partial 'pid 107 is in this pane'
  assert_output --partial 'no process 999'
  run systemctl_calls
  assert_output '--user set-property --runtime tmux-spawn-aaa.scope CPUWeight=1'
}

@test "lower finds the pane scope around a nested scope" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" lower unity-tests 106
  assert_success
  assert_line 'lowered: tmux-spawn-bbb.scope (pid 106)'
}

@test "a usage error outranks a refused pid in the exit code" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" lower unity-tests abc 999
  assert_failure 2
}

@test "lower refuses a claim, whose refresh would drop the record" {
  lower_setup
  "$HOLD" claim mac-desktop --by agent-6 "mine"
  run "$HOLD" lower mac-desktop 101
  assert_failure 2
  assert_output --partial 'is a claim'
}

@test "lower needs a hold to record on, so release can undo it" {
  lower_setup
  run "$HOLD" lower unity-tests 101
  assert_failure 1
  assert_output --partial 'is not held'
  run systemctl_calls
  assert_output ''
}

@test "a re-set keeps the lowered units, and release restores each one" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" lower unity-tests 101 103
  "$HOLD" set unity-tests --by c "hotter"
  run "$HOLD" show unity-tests
  assert_line 'lowered: tmux-spawn-aaa.scope,agentctl@sentinel.service'
  run "$HOLD" release unity-tests
  assert_success
  assert_line 'restored: tmux-spawn-aaa.scope'
  assert_line 'restored: agentctl@sentinel.service'
  run systemctl_calls
  assert_line -- '--user set-property --runtime tmux-spawn-aaa.scope CPUWeight='
  assert_line -- '--user set-property --runtime agentctl@sentinel.service CPUWeight='
}

@test "release skips a lowered unit whose pane is gone and frees the hold" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" lower unity-tests 101
  printf '#!/usr/bin/env bash\ncase "$*" in *LoadState*) echo not-found ;; *) exit 1 ;; esac\n' > "$SANDBOX/bin/systemctl"
  run "$HOLD" release unity-tests
  assert_success
  assert_line 'gone: tmux-spawn-aaa.scope'
  run "$HOLD" check unity-tests
  assert_success
}

@test "release keeps the hold and the record when a live unit cannot be restored" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" lower unity-tests 101 103
  printf '#!/usr/bin/env bash\ncase "$*" in *LoadState*) echo loaded ;; *agentctl*) exit 0 ;; *) exit 1 ;; esac\n' > "$SANDBOX/bin/systemctl"
  run "$HOLD" release unity-tests
  assert_failure 1
  assert_line 'restored: agentctl@sentinel.service'
  assert_output --partial 'could not restore tmux-spawn-aaa.scope'
  run "$HOLD" show unity-tests
  assert_line 'lowered: tmux-spawn-aaa.scope'
}

@test "set, grant and release each write one audit line; a caller that records it writes none" {
  run "$HOLD" set unity-tests --by coordinator "96 C"
  assert_success
  run "$HOLD" grant unity-tests agent-2
  assert_success
  run "$HOLD" release unity-tests
  assert_success
  log="$HOME/.agent/audit/actions.jsonl"
  run jq -rc '[.actor, .action, .target, .outcome, .via, .to] | @tsv' "$log"
  assert_line --index 0 $'coordinator\thold.placed\tunity-tests\tok\tcli\t96 C'
  assert_line --index 1 --partial $'hold.granted\tunity-tests\tok\tcli\tagent-2'
  assert_line --index 2 --partial $'hold.released\tunity-tests\tok\tcli\twas: 96 C'
  # hub_core's System runner sets AGENT_AUDITED to its own pid, the tool's parent: here the
  # bash that starts it (the trailing exit keeps bash from exec-ing the tool in its place).
  run bash -c 'AGENT_AUDITED=$$ "$0" set unity-tests --by web x; exit $?' "$HOLD"
  assert_success
  run wc -l < "$log"
  assert_output 3
}
