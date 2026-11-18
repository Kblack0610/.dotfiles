#!/usr/bin/env bash
# run-bats.sh <bats args...>: run the vendored bats with a run dir this script owns, and remove
# it however the run ends. The Makefile's unit, integ and files targets run bats through it.
#
# Why: bats removes its run dir (BATS_RUN_TMPDIR) only in its own EXIT trap, so a run killed past
# that trap (a KILL, or a TERM that reaches the bats main but not GNU parallel's jobs, which each
# set their own process group) left the dir and its tests running (ar-1819). setsid puts bats and
# every job parallel starts in one session, so the reap below reaches them all, along with any
# background process a test left behind.
set -uo pipefail

bats="$(dirname "$(readlink -f "$0")")/vendor/bats-core/bin/bats"

# One suite at a time per machine (ar-3277): nine sessions each ran a --jobs 2 suite at once and
# load reached 86 on 32 cores. A second run waits on the flock, an event and not a timer, and says
# so. A nested run (a test of this script) inherits RUN_BATS_SLOT and skips it; bats gets fd 9
# closed, so a process a test leaks cannot hold the slot after this script exits.
if [ -z "${RUN_BATS_SLOT:-}" ]; then
  export RUN_BATS_SLOT="${XDG_RUNTIME_DIR:-/tmp}/run-bats.slot"
  exec 9>>"$RUN_BATS_SLOT"
  flock -n 9 || { echo "run-bats.sh: another suite holds $RUN_BATS_SLOT, waiting" >&2; flock 9; }
fi
own=$(mktemp -d "${TMPDIR:-/tmp}/bats-run-XXXXXX") || exit 1
sid=

# pidwait returns once every process it matched has exited (it waits on pidfds), so nothing of the
# session still writes into the dir when rm runs.
reap() {
  if [ -n "$sid" ]; then
    pkill -KILL -s "$sid" 2>/dev/null
    pidwait -s "$sid" 2>/dev/null
  fi
  rm -rf -- "$own"
}
# A Ctrl-C reaches the terminal's process group, this script, and not bats in its own session:
# hand it on so bats stops and prints its summary as it would by hand, then reap. A second Ctrl-C
# reaps at once. HUP and TERM (the stop hook's timeout) reap at once: no KILL follows them.
interrupt() {
  trap 'exit 130' INT
  [ -n "$sid" ] && kill -INT -- "-$sid" 2>/dev/null && wait "$sid"
  exit 130
}
trap reap EXIT
trap 'exit 129' HUP
trap interrupt INT
trap 'exit 143' TERM

# bats resets BATS_RUN_TMPDIR from the environment and makes its run dir under TMPDIR, so TMPDIR
# is the owned dir: the run dir, parallel's buffer files and a test's bare mktemp all land in it.
# A background job of a non-interactive shell is not a process group leader, so setsid does not
# fork and $! is the new session's id. Such a job also starts with stdin on /dev/null and SIGINT
# ignored, past any trap: <&0 keeps stdin, and env restores SIGINT so the Ctrl-C handed on reaches it.
TMPDIR="$own" setsid env --default-signal=INT "$bats" "$@" <&0 9>&- &
sid=$!
wait "$sid"
