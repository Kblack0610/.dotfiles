#!/usr/bin/env bats
# custom/webcam: the red CAM pill while a process holds a /dev/video* node open. What these pin:
# the module is wired ungated beside custom/gungan on both profiles and drawn as the red pill;
# webcam.sh shows on an open fd, names the holder, hides on the close; a camera plugged in after
# start is watched too; stopping it leaves no inotifywait behind, and neither does a run killed past
# its traps (ar-1870). The device directory is a temp dir (WEBCAM_DEV_DIR): inotify reports opens
# and closes of a plain file the same way.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  W="$REPO_ROOT/.config/waybar"
  DEV="$BATS_TEST_TMPDIR/dev"
  mkdir -p "$DEV"
  touch "$DEV/video0"
}

teardown() {
  [[ -n ${HOLDER:-} ]] && kill "$HOLDER" 2>/dev/null
  [[ -n ${MOD:-} ]] && kill "$MOD" 2>/dev/null
  [[ -n ${RUN:-} ]] && kill -KILL "$RUN" 2>/dev/null
  # A failed assertion can leave a watcher running: the temp dir path is unique to this test, and
  # an empty DEV (setup failed early) would match every inotifywait the user owns.
  [[ -n ${DEV:-} ]] && pkill -f "inotifywait.*$DEV" 2>/dev/null
  true
}

# DIE_WITH_RUN <cmd...>: the command gets a TERM from the kernel when the process that started it
# dies, however it dies. A bats run killed past its traps (a KILL) never reaches teardown, and the
# module, its inotifywaits and a holder's sleep ran on in the leaked run dir (ar-1870). The TERM
# runs webcam.sh's EXIT trap, which ends its watchers. Same idiom as run-bats.sh.
# A prefix, not a function: a function would fork, and $! must be the command itself.
DIE_WITH_RUN=(setpriv --pdeathsig TERM)

need_tools() {
  command -v inotifywait >/dev/null || skip "inotify-tools not installed"
  command -v setpriv >/dev/null || skip "setpriv (util-linux) not installed"
}

# start: run webcam.sh on $DEV, its lines into fd 4. fd 3 is closed so bats does not wait on it.
start() {
  need_tools
  mkfifo "$BATS_TEST_TMPDIR/out"
  WEBCAM_DEV_DIR="$DEV" "${DIE_WITH_RUN[@]}" "$W/webcam.sh" > "$BATS_TEST_TMPDIR/out" 3>&- &
  MOD=$!
  exec 4< "$BATS_TEST_TMPDIR/out"
}

# next_line: the module's next line, or TIMEOUT (a guard, not a wait: each line is event-driven).
next_line() { read -r -t 10 -u 4 LINE || LINE=TIMEOUT; }

hold() { # hold <node>: a process with the node open, like a camera app
  # The fd is opened by bash itself, after the exec of setpriv into it, so the holder's name is
  # `bash` from the open on. A `3<` on `setpriv ... sleep` opened it before the exec, and the
  # module's comm read raced it: it named `setpriv` on a loaded runner (PR 3431, integ 3/4).
  # Its sleep child has the fd closed and ends on the TERM that ends the holder.
  "${DIE_WITH_RUN[@]}" bash -c 'exec 3< "$1"; sleep 1000 3<&- & trap "kill \$!" TERM; wait' _ "$DEV/$1" &
  HOLDER=$!
}

@test "the module runs webcam.sh ungated, after custom/gungan on both profiles, as the red pill" {
  run grep -A5 '"custom/webcam": {' "$W/config.base"
  assert_line --partial '"exec": "$HOME/.config/waybar/webcam.sh",'
  refute_output --partial 'modules.sh gate'
  refute_output --partial '"interval"'
  for f in config.desktop config.laptop; do
    run grep -A1 '"custom/gungan",$' "$W/$f"
    assert_line --partial '"custom/webcam"'
  done
  run grep -B1 '#custom-webcam {' "$W/layout.css"
  assert_line '#custom-gungan,'
}

@test "an open fd shows CAM naming the holder; the close hides it" {
  start
  next_line
  assert_equal "$LINE" '{"text":""}'
  hold video0
  next_line
  assert_equal "$(jq -r .text <<< "$LINE")" CAM
  assert_equal "$(jq -r .tooltip <<< "$LINE")" "Webcam in use by:"$'\n'"bash ($HOLDER)"
  kill "$HOLDER"
  next_line
  assert_equal "$LINE" '{"text":""}'
}

@test "a holder gone before its comm is read is not named: the pill stays hidden" {
  # The fd walk can list a process that is reaped before its comm read; a stub find names a pid
  # past pid_max, which never exists, so the race is the same on every run.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho /proc/4194999/fd\n' > "$BATS_TEST_TMPDIR/bin/find"
  chmod +x "$BATS_TEST_TMPDIR/bin/find"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" start
  next_line
  assert_equal "$LINE" '{"text":""}'
}

@test "a camera plugged in after start is watched" {
  start
  next_line
  touch "$DEV/video2"
  hold video2
  next_line
  assert_equal "$(jq -r .text <<< "$LINE")" CAM
}

@test "stopping the module leaves no inotifywait behind" {
  start
  next_line
  touch "$DEV/video2" # a re-arm, so an old watcher would be left over if re-arm leaked one
  hold video2
  next_line
  kill "$MOD"
  wait "$MOD" 2>/dev/null || true
  MOD=
  run pgrep -f "inotifywait.*$DEV"
  assert_failure
}

@test "a run killed past its traps takes the module and its inotifywait with it" {
  need_tools
  mkfifo "$BATS_TEST_TMPDIR/out"
  # A stand-in for the bats test process: it starts the module as start does, then is KILLed.
  export DIE_WITH_RUN_CMD="${DIE_WITH_RUN[*]}"
  W="$W" DEV="$DEV" OUT="$BATS_TEST_TMPDIR/out" PIDFILE="$BATS_TEST_TMPDIR/mod.pid" \
    bash -c 'WEBCAM_DEV_DIR=$DEV $DIE_WITH_RUN_CMD "$W/webcam.sh" > "$OUT" 3>&- & echo $! > "$PIDFILE"; wait' 3>&- &
  RUN=$!
  exec 4< "$BATS_TEST_TMPDIR/out"
  next_line # the module is up and its watchers are armed
  assert_equal "$LINE" '{"text":""}'
  MODPID=$(< "$BATS_TEST_TMPDIR/mod.pid")
  MOD=$MODPID # for teardown, should an assertion fail before the KILL
  run pgrep -f "inotifywait.*$DEV"
  assert_success
  kill -KILL "$RUN"
  # tail --pid returns when the pid exits: the event, with a 10 s guard if it never does.
  run timeout 10 tail --pid="$MODPID" -f /dev/null
  assert_success
  run pgrep -f "inotifywait.*$DEV"
  assert_failure
}
