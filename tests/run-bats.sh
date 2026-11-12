#!/usr/bin/env bash
# run-bats.sh <bats args...>: run the vendored bats with a run dir this script owns, and remove
# it however the run ends. The Makefile's unit, integ and files targets run bats through it.
#
# Why: bats removes its run dir (BATS_RUN_TMPDIR) only in its own EXIT trap. A run killed past that trap
# (a KILL, or a stop-hook timeout whose TERM reaches the bats main but not GNU parallel's jobs,
# which each set their own process group) left the dir on tmpfs and its tests still running in
# it: 135 dirs held 21G of /tmp on 2026-11-11, until parallel failed "Cannot append to buffer
# file in /tmp" (ar-1819). setsid puts bats and every job parallel starts in one session, so the
# reap below reaches them all, along with any background process a test left behind.
set -uo pipefail

bats="$(dirname "$(readlink -f "$0")")/vendor/bats-core/bin/bats"
own=$(mktemp -d "${TMPDIR:-/tmp}/bats-run-XXXXXX") || exit 1
sid=

reap() {
  [ -n "$sid" ] && pkill -KILL -s "$sid" 2>/dev/null
  rm -rf -- "$own"
}
trap reap EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# bats resets BATS_RUN_TMPDIR from the environment and makes its run dir under TMPDIR, so TMPDIR
# is the owned dir: the run dir, parallel's buffer files and a test's bare mktemp all land in it.
# A background job of a non-interactive shell is not a process group leader, so setsid does not
# fork and $! is the new session's id.
TMPDIR="$own" setsid "$bats" "$@" <&0 &
sid=$!
wait "$sid"
