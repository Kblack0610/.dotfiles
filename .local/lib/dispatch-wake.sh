# shellcheck shell=bash
# dispatch-wake.sh - the one wake signal for fleet-dispatch (plan dispatch-event-wake, phase 2).
#
#   . dispatch-wake.sh; dispatch_wake <why>
#
# Rewrites ~/.agent/dispatch/.wake, which fleet-dispatch-kick.path watches: each write starts one
# `fleet-dispatch kick` (agentctl@fleet-dispatch-kick.service), the fast start-only path, and systemd
# drops writes that land while it runs (the kick reads the queue again when .wake moved during its run). A writer is anything that frees a slot or adds something to
# start: agent-queue (an add, an item closed), agent-hold (a release), agent-ask (an answer that
# releases held items), store-sync (a pull that changed queue/ on the lease holder), a fleet-sessions write of the state
# document (its live count dropped: a session that just finished is live in it until a write drops it). The 15-minute
# `fleet-dispatch run` stays the resync that catches a wake systemd merged away.
#
# Never fails and never waits: a wake that is not written is read by the next timed pass.
dispatch_wake() {
  local d="${FLEET_DISPATCH_DIR:-$HOME/.agent/dispatch}"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 0
  printf '%(%s)T %s\n' -1 "$*" > "$d/.wake" 2>/dev/null || true
}
