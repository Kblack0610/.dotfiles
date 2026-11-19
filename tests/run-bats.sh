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
slot_base=
jobs=1
slot_fits() {
  local held=0 claimed=0 f pid j t free now; printf -v now '%(%s)T' -1
  for f in "$slot_base".*; do
    [ -e "$f" ] || continue
    flock -n "$f" true && continue            # nobody holds it: a dead run's file
    held=$((held + 1))
    read -r pid j t <"$f" || continue
    [ $((now - ${t:-0})) -lt "$CLAIM_S" ] && claimed=$((claimed + ${j:-0}))
  done
  [ "$held" -eq 0 ] && return 0
  free=$(awk -v c="$(nproc 2>/dev/null || echo 2)" -v min=0 -f "$(dirname "$self")/unit-jobs.awk" "${UNIT_LOADAVG:-/proc/loadavg}" 2>/dev/null) || free=2
  slot_why="$held runs hold slots, $((free > claimed ? free - claimed : 0)) cores free"
  [ $((free - claimed)) -ge "$jobs" ]
}
slot_take() {
  local k=0 now; printf -v now '%(%s)T' -1
  while :; do
    exec {slot_fd}>>"$slot_base.$k" || return 1
    if flock -n "$slot_fd"; then
      printf '%s %s %s\n' $$ "$jobs" "$now" >"$slot_base.$k"
      RUN_BATS_SLOT="$slot_base.$k"
      return 0
    fi
    exec {slot_fd}>&-
    k=$((k + 1))
  done
}
slot_admit() {
  local admit_fd told= prev= a rc
  for a in "$@"; do
    case $a in --jobs=*) jobs=${a#--jobs=} ;; -j[0-9]*) jobs=${a#-j} ;; esac
    case $prev in --jobs | -j) jobs=$a ;; esac
    prev=$a
  done
  case $jobs in '' | *[!0-9]* | 0) jobs=1 ;; esac
  slot_base="${XDG_RUNTIME_DIR:-/tmp}/run-bats.slot"
  exec {admit_fd}>>"${slot_base%.slot}.admit" || return 1
  # The waiter at the head holds the admit lock while it polls, so the rest queue on the lock, an
  # event, and a run that does not fit yet is not overtaken by smaller ones arriving after it.
  flock "$admit_fd" || return 1
  until slot_fits; do
    [ -n "$told" ] || echo "run-bats.sh: --jobs $jobs does not fit ($slot_why), waiting" >&2
    told=1
    sleep "$SLOT_POLL_S"
  done
  slot_take; rc=$?
  exec {admit_fd}>&-
  return $rc
}

# Every run that takes a slot is recorded where the hub's Jobs list reads it (source `tests`,
# hub-core jobs/local.rs): a live file `$LOCAL_TESTS_LIVE/<pid>` while it waits or runs, and one
# ledger row when it ends, `end start result kind worktree branch repo waited what`, tab-separated
# (the Unity ledger's columns, then the seconds spent waiting and the test files). Why: the runs
# were invisible, so nine stacked suites showed only as a load number (ar-3291).
slot_fd= own= sid= rec=
ledger="${LOCAL_TESTS_LEDGER:-${XDG_STATE_HOME:-$HOME/.local/state}/local-tests/runs.tsv}"
live="${LOCAL_TESTS_LIVE:-${XDG_RUNTIME_DIR:-/tmp}/local-tests}"
record_live() {   # <state>: this run's live line, replaced whole so a reader never sees half of it
  printf '%s\t%s\tbats\t%s\t%s\t%s\t%s\n' "$t_state" "$1" "$wt" "$branch" "$repo" "$what" \
    >"$live/.$$" 2>/dev/null && mv -f -- "$live/.$$" "$live/$$"
}
is_run() {        # <pid>: alive and still a run of this script, not a pid reused since a KILL
  kill -0 "$1" 2>/dev/null && { [ ! -r "/proc/$1/cmdline" ] || grep -qa run-bats "/proc/$1/cmdline"; }
}
record_end() {    # <exit status>
  local end res
  printf -v end '%(%s)T' -1
  case "$1" in 0) res=pass ;; 1) res=fail ;; 129|130|143) res=killed ;; *) res=error ;; esac
  rm -f -- "$live/$$"
  mkdir -p "${ledger%/*}" 2>/dev/null &&
    printf '%s\t%s\t%s\tbats\t%s\t%s\t%s\t%s\t%s\n' "$end" "$t_run" "$res" "$wt" "$branch" "$repo" \
      "$((t_run - t_wait))" "$what" >>"$ledger"
}
if [ -z "${RUN_BATS_SLOT:-}" ] && [ -z "${CI:-}" ]; then
  export RUN_BATS_SLOT="${XDG_RUNTIME_DIR:-/tmp}/run-bats.slot"
  rec=1
  top=$(dirname "$(dirname "$self")")   # the checkout this script is in, whatever the cwd
  top=$(git -C "$top" rev-parse --show-toplevel 2>/dev/null || echo "$top")
  common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  wt=${top##*/} branch=$(git -C "$top" branch --show-current 2>/dev/null) repo=${common%/.git}
  repo=${repo##*/} repo=${repo#.} what=
  for a in "$@"; do   # the test files, or the dirs (make test-unit passes tests/unit)
    case "$a" in *.bats) ;; *) [ -d "$a" ] || continue ;; esac
    a=${a%/} what+="${what:+ }${a##*/}"
  done
  what=${what:0:120}
  printf -v t_wait '%(%s)T' -1
  t_run=$t_wait t_state=$t_wait
  mkdir -p "$live" 2>/dev/null
  for f in "$live"/*; do [ -e "$f" ] && ! is_run "${f##*/}" && rm -f -- "$f"; done  # dead runs
  record_live waiting
  trap 'rm -f -- "$live/$$"' EXIT
  if ! command -v flock >/dev/null; then
    echo "run-bats.sh: no flock; running without a slot" >&2
  elif ! slot_admit "$@"; then
    echo "run-bats.sh: cannot take a slot under ${XDG_RUNTIME_DIR:-/tmp}; running without one" >&2
    slot_fd=
  fi
  printf -v t_run '%(%s)T' -1
  t_state=$t_run
  record_live running
fi
[ -n "$slot_fd" ] || exec {slot_fd}</dev/null   # so the launch below always has an fd to close
own=$(mktemp -d "${TMPDIR:-/tmp}/bats-run-XXXXXX") || exit 1

# pidwait returns once every process it matched has exited (it waits on pidfds), so nothing of the
# session still writes into the dir when rm runs.
reap() {
  local rc=$?
  if [ -n "$sid" ]; then
    pkill -KILL -s "$sid" 2>/dev/null
    exec {slot_fd}>&-   # the suite is over: free the slot before waiting on the dying session (ar-3377)
    pidwait -s "$sid" 2>/dev/null
  fi
  rm -rf -- "$own"
  [ -n "$rec" ] && record_end "$rc"
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
