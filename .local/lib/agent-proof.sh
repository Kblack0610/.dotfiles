# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# agent-proof.sh — did the headless agent actually DO anything?
#
# Source this from an agentctl wrapper. It answers the one question systemd
# cannot: a headless `claude --print` exits 0 whether it did the whole job or
# politely declined and wrote nothing, so `Result=success` is not evidence of
# work. Two separate multi-week outages on this box came from trusting it:
#
#   * agentctl-dream ran 150 consecutive no-op sweeps (2026-07-09 .. 07-25).
#     settings.json set "defaultMode": "plan", the headless run inherited it,
#     and the agent wrote a plan file asking for approval nobody was there to
#     give. Seventeen nights of memory consolidation were lost silently.
#   * agentctl-nightly-sync repeated it from 2026-07-22, writing zero mem0
#     entries for six nights. The guard had been added to dream but not here.
#
# dream grew an artifact-watermark guard in response; this is that idea lifted
# out so every runner gets it, plus the plan-mode detector the outage taught us
# to look for. The verdict is written where a reader can see it, because an
# outcome nobody surfaces is the failure mode all over again.
#
# Usage:
#   source "$HOME/.local/lib/agent-proof.sh"
#   proof_watch "$dreams_md" "$staging_json"      # BEFORE the run
#   ... run the agent, tee its output to $LOG ...
#   proof_verdict "$LOG"                          # -> WORKED | NOOP | STALLED
#   proof_report nightly-sync "$verdict"          # -> last-outcome file
#
# proof_verdict exits non-zero on STALLED so a wrapper can `|| exit 1` and let
# systemd record the failure, which is what turns the fleet row red.

# Phrases that mean the model produced a PLAN instead of doing the work. This is
# the signature of the plan-mode regression, and it is definitive: a headless run
# with no human present has nobody to approve anything.
: "${AGENT_PROOF_STALL_RE:=ExitPlanMode|ready for your approval|the plan above|awaiting your approval|would you like me to proceed}"

# Phrases a wrapper's prompt instructs the agent to emit when there was
# legitimately nothing to do. Override per wrapper. Without an explicit marker a
# run that changed nothing counts as STALLED, not NOOP — "silence" must not be
# allowed to read as "healthy", which is the whole point of this file.
: "${AGENT_PROOF_NOOP_RE:=no new facts|nothing to capture|nothing met the bar|no new material|nothing to promote}"

_AGENT_PROOF_PRE=""

# proof_watch FILE... — record a fingerprint of each artifact before the run.
# mtime AND size: two writes inside the same second are common for small files,
# and mtime alone would call that "unchanged".
proof_watch() {
  local f
  _AGENT_PROOF_PRE=""
  for f in "$@"; do
    _AGENT_PROOF_PRE+="$f=$(stat -c '%Y:%s' "$f" 2>/dev/null || echo 0:0)"$'\n'
  done
}

# proof_changed — 0 if any watched artifact changed since proof_watch.
proof_changed() {
  local line f pre now
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line%%=*}"; pre="${line#*=}"
    now="$(stat -c '%Y:%s' "$f" 2>/dev/null || echo 0:0)"
    [ "$now" != "$pre" ] && return 0
  done <<< "$_AGENT_PROOF_PRE"
  return 1
}

# proof_verdict [LOGFILE] — echo WORKED | NOOP | STALLED; non-zero on STALLED.
#
# Order matters: the plan-mode check runs FIRST and beats a changed artifact,
# because a plan-mode run does write a file (the plan) and would otherwise be
# scored as real work — exactly how the dream outage stayed invisible.
proof_verdict() {
  local log="${1:-}"
  if [ -n "$log" ] && [ -r "$log" ] && grep -qiE "$AGENT_PROOF_STALL_RE" "$log"; then
    echo STALLED; return 1
  fi
  if proof_changed; then echo WORKED; return 0; fi
  if [ -n "$log" ] && [ -r "$log" ] && grep -qiE "$AGENT_PROOF_NOOP_RE" "$log"; then
    echo NOOP; return 0
  fi
  echo STALLED; return 1
}

# proof_report NAME VERDICT [DETAIL] — publish the verdict where readers look.
# fleet.sh and the drift/liveness watches read last-outcome; the activity log is
# what `agentctl status <name>` tails.
proof_report() {
  local name="$1" verdict="$2" detail="${3:-}"
  local dir="${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}/$name"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s' "$verdict" > "$dir/last-outcome" 2>/dev/null || true
  printf '[%s] outcome=%s %s\n' "$(date -Is)" "$verdict" "$detail" >> "$dir/activity.log" 2>/dev/null || true
}
