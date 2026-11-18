#!/usr/bin/env bash
# run-bats.sh <bats args...>: run the vendored bats with a run dir this script owns, and remove
# it however the run ends. The Makefile's unit, integ and files targets run bats through it.
#
# Why: bats removes its run dir (BATS_RUN_TMPDIR) only in its own EXIT trap, so a run killed past
# that trap (a KILL, or a TERM that reaches the bats main but not GNU parallel's jobs, which each
# set their own process group) left the dir and its tests running (ar-1819). setsid puts bats and
# every job parallel starts in one session, so the reap below reaches them all, along with any
# background process a test left behind. Two paths reap that session: this script's EXIT trap,
# and, for a KILL that skips every trap, the session leader's parent-death TERM (--lead below).
set -uo pipefail

self=$(readlink -f "$0")
bats="$(dirname "$self")/vendor/bats-core/bin/bats"

# --lead <wrapper pid> <bats args...>: the session leader, a child of the wrapper started with a
# parent-death TERM, with TMPDIR the owned dir. A wrapper killed past its traps (a KILL from the
# tool or hook that ran it) reaps nothing, and the session it started ran on for hours: a parallel
# job's bats-exec-file waits forever for a semaphore slot once the bats main has removed its run
# dir (ar-3253). The kernel TERMs this leader when the wrapper dies, however it dies, and the
# leader then kills the rest of its session (-A spares itself) and removes the owned dir, as the
# wrapper's reap would. It removes only a bats-run-* dir, so a hand run cannot delete a real TMPDIR.
if [ "${1:-}" = --lead ]; then
  case "${TMPDIR:-}" in */bats-run-*) ;; *) echo "run-bats.sh: --lead is internal" >&2; exit 2 ;; esac
  lead_reap() { pkill -KILL -A -s $$; pidwait -A -s $$; rm -rf -- "$TMPDIR"; exit 143; }
  trap lead_reap TERM HUP
  [ "$PPID" = "$2" ] || lead_reap   # the wrapper died before the parent-death signal was set
  shift 2
  trap '' INT                       # the wrapper's Ctrl-C is for bats, which reports it
  env --default-signal=INT "$bats" "$@" <&0 &
  wait $!
  exit
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
# fork and $! is the new session's id, the leader's pid, whose parent is this script. Such a job
# also starts with stdin on /dev/null and SIGINT ignored, past any trap: <&0 keeps stdin, and the
# leader's env restores SIGINT for bats so the Ctrl-C handed on reaches it.
TMPDIR="$own" setsid setpriv --pdeathsig TERM "$self" --lead $$ "$@" <&0 &
sid=$!
wait "$sid"
