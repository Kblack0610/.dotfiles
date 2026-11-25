#!/usr/bin/env bash
# cpus.sh: the CPUs this run may use, one integer >= 1, for sizing `bats --jobs`.
#
# The smallest of: nproc, the CPU quota of this cgroup (cgroup v2 cpu.max, the container's own
# when run in one; a parent's quota and cgroup v1 are not read; rounded up), and $CI_CPU_MILLI
# (millicores, a CI pod's own CPU request, which its spec passes in by the downward API).
# Why: `nproc` is the host's core count inside a pod. A runner pod asks for 370m and has no CPU
# limit, so cpu.max reads "max" and the request is only a scheduler weight: bats --jobs took
# nproc and ran 32 jobs on a 32-core host in a pod that booked 0.37 (ar-5586, hc-1021). An
# integer count cannot share a core, so a fraction rounds up to 1.
# CGROUP_CPU_MAX points at another cpu.max file (a test's).
set -uo pipefail

n=$(nproc 2>/dev/null) || n=2
case $n in '' | *[!0-9]* | 0) n=2 ;; esac

read -r quota period 2>/dev/null <"${CGROUP_CPU_MAX:-/sys/fs/cgroup/cpu.max}" || quota=max
case ${quota:-max}:${period:-} in
  *[!0-9:]* | '' | :*) ;;   # "max", or no file: no quota
  *:0 | *:) ;;
  *) c=$(((quota + period - 1) / period)); [ "$c" -ge "$n" ] || n=$c ;;
esac

case ${CI_CPU_MILLI:-} in
  '' | *[!0-9]*) ;;
  *) c=$(((CI_CPU_MILLI + 999) / 1000)); [ "$c" -ge "$n" ] || n=$c ;;
esac

echo "$((n < 1 ? 1 : n))"
