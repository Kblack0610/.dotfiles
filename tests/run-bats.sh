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

# The machine's bats slots (ar-3277, ar-3377): nine sessions each ran a --jobs 2 suite at once and
# load reached 86 on 32 cores, then one slot for the whole machine queued twelve sessions behind a
# single long run while the box sat 78% idle. A run is admitted when its --jobs (1 when serial) fit
# the cores free now, by unit-jobs.awk, the number the Makefile sizes --jobs with; the first run
# always is. A run admitted in the last CLAIM_S seconds is also counted at its --jobs, because its
# workers have not started yet and gates admitted together would all read the box idle. Admission
# is serialised on one lock and each run holds one slot file for its life, so a run that dies
# frees its slot. A waiter names what it waits for and re-checks every SLOT_POLL_S: no event says
# "load fell" or "any slot freed". A nested run (a test of this script) inherits RUN_BATS_SLOT and
# skips all this, and so does CI, whose shards have their own cpusets and must not queue. bats gets
# the fd closed, so a process a test leaks cannot hold the slot once this script exits.
: "${SLOT_POLL_S:=5}"   # env overrides: the test drives a short poll
: "${CLAIM_S:=20}"
slot_fd=
slot_base=
jobs=1
slot_fits() {
  local held=0 claimed=0 f pid j t free
  for f in "$slot_base".*; do
    [ -e "$f" ] || continue
    flock -n "$f" true && continue            # nobody holds it: a dead run's file
    held=$((held + 1))
    read -r pid j t <"$f" || continue
    [ $((EPOCHSECONDS - ${t:-0})) -lt "$CLAIM_S" ] && claimed=$((claimed + ${j:-0}))
  done
  [ "$held" -eq 0 ] && return 0
  free=$(awk -v c="$(nproc 2>/dev/null || echo 2)" -v min=0 -f "$(dirname "$self")/unit-jobs.awk" "${UNIT_LOADAVG:-/proc/loadavg}" 2>/dev/null) || free=2
  slot_why="$held runs hold slots, $((free - claimed)) cores free"
  [ $((free - claimed)) -ge "$jobs" ]
}
slot_take() {
  local k=0
  while :; do
    exec {slot_fd}>>"$slot_base.$k" || return 1
    if flock -n "$slot_fd"; then
      printf '%s %s %s\n' $$ "$jobs" "$EPOCHSECONDS" >"$slot_base.$k"
      RUN_BATS_SLOT="$slot_base.$k"
      return 0
    fi
    exec {slot_fd}>&-
    k=$((k + 1))
  done
}
slot_admit() {
  local admit_fd told= prev= a
  for a in "$@"; do
    case $prev in --jobs | -j) jobs=$a ;; esac
    prev=$a
  done
  case $jobs in '' | *[!0-9]* | 0) jobs=1 ;; esac
  slot_base="${XDG_RUNTIME_DIR:-/tmp}/run-bats.slot"
  exec {admit_fd}>>"${slot_base%.slot}.admit" || return 1
  while :; do
    flock "$admit_fd" || return 1
    if slot_fits; then
      slot_take; local rc=$?
      flock -u "$admit_fd"
      exec {admit_fd}>&-
      return $rc
    fi
    flock -u "$admit_fd"
    [ -n "$told" ] || echo "run-bats.sh: --jobs $jobs does not fit ($slot_why), waiting" >&2
    told=1
    sleep "$SLOT_POLL_S"
  done
}
if [ -z "${RUN_BATS_SLOT:-}" ] && [ -z "${CI:-}" ]; then
  if ! command -v flock >/dev/null; then
    echo "run-bats.sh: no flock; running without a slot" >&2
  elif slot_admit "$@"; then
    export RUN_BATS_SLOT
  else
    echo "run-bats.sh: cannot take a slot under ${XDG_RUNTIME_DIR:-/tmp}; running without one" >&2
    slot_fd=
  fi
fi
[ -n "$slot_fd" ] || exec {slot_fd}</dev/null   # so the launch below always has an fd to close
own=$(mktemp -d "${TMPDIR:-/tmp}/bats-run-XXXXXX") || exit 1
sid=

# pidwait returns once every process it matched has exited (it waits on pidfds), so nothing of the
# session still writes into the dir when rm runs.
reap() {
  if [ -n "$sid" ]; then
    pkill -KILL -s "$sid" 2>/dev/null
    exec {slot_fd}>&-   # the suite is over: free the slot before waiting on the dying session (ar-3377)
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
TMPDIR="$own" setsid setpriv --pdeathsig TERM "$self" --lead $$ "$@" <&0 {slot_fd}>&- &
sid=$!
wait "$sid"
