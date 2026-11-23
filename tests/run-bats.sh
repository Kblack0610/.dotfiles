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

# Every run outside CI is recorded where the hub's Jobs list reads it (source `tests`, hub-core
# jobs/local.rs): a live file `$LOCAL_TESTS_LIVE/<pid>` while it runs, and one ledger row when it
# ends, `end start result kind worktree branch repo waited what`, tab-separated (the Unity ledger's
# columns, then a waited column the reader keeps, always 0 here, and the test files).
# Why: the runs were invisible, so nine stacked suites showed only as a load number
# (ar-3291). A nested run (a test of this script) inherits RUN_BATS_OUTER and records nothing, and
# neither does CI.
own= sid= rec=
ledger="${LOCAL_TESTS_LEDGER:-${XDG_STATE_HOME:-$HOME/.local/state}/local-tests/runs.tsv}"
live="${LOCAL_TESTS_LIVE:-${XDG_RUNTIME_DIR:-/tmp}/local-tests}"
record_live() {   # this run's live line, replaced whole so a reader never sees half of it
  printf '%s\trunning\tbats\t%s\t%s\t%s\t%s\n' "$t_run" "$wt" "$branch" "$repo" "$what" \
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
    printf '%s\t%s\t%s\tbats\t%s\t%s\t%s\t0\t%s\n' "$end" "$t_run" "$res" "$wt" "$branch" "$repo" \
      "$what" >>"$ledger"
}
if [ -z "${RUN_BATS_OUTER:-}" ] && [ -z "${CI:-}" ]; then
  export RUN_BATS_OUTER=$$
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
  printf -v t_run '%(%s)T' -1
  mkdir -p "$live" 2>/dev/null
  for f in "$live"/*; do [ -e "$f" ] && ! is_run "${f##*/}" && rm -f -- "$f"; done  # dead runs
  record_live
fi
# Made just before the reap is armed: a signal before here leaves no dir, and the next run's sweep
# of dead runs takes a live file it left.
own=$(mktemp -d "${TMPDIR:-/tmp}/bats-run-XXXXXX") || exit 1

# pidwait returns once every process it matched has exited (it waits on pidfds), so nothing of the
# session still writes into the dir when rm runs.
reap() {
  local rc=$?
  if [ -n "$sid" ]; then
    pkill -KILL -s "$sid" 2>/dev/null
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
TMPDIR="$own" setsid setpriv --pdeathsig TERM "$self" --lead $$ "$@" <&0 &
sid=$!
wait "$sid"
