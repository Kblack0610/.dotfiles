# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# audit.sh - one line on the operator audit log for a change a shell tool makes (agent-hold's
# holds, claude-acct's parks), in the shape hub_core::audit writes and Log > Actions reads:
#
#   audit_append <actor> <noun.verb> <target> <outcome> [to]
#
# outcome is "ok" or "failed: <why>"; to, when given, is what was asked, as plain text. target and
# to are cut at 200 characters (hub_core::audit::TEXT_MAX), and the log is created readable only by you. A tool run
# by agent-web or the hub TUI (hub_core's System runner sets AGENT_AUDITED to its own pid, which
# is this tool's $PPID) writes nothing: its caller records the change under the person who asked.
# Best effort: a change never fails because its line did not land, but a lost line says so.
audit_append() {
  [ "${AGENT_AUDITED:-}" != "$PPID" ] || return 0
  local log="${AGENT_AUDIT_LOG:-$HOME/.agent/audit/actions.jsonl}" line
  mkdir -p "$(dirname "$log")" 2>/dev/null
  line=$(jq -nc --argjson at "$(date +%s)" --arg actor "$1" --arg action "$2" --arg target "$3" \
    --arg outcome "$4" --arg to "${5:-}" \
    'def clip: if length > 200 then .[:200] + "..." else . end;
     {at: $at, actor: $actor, action: $action, target: $target, outcome: $outcome, via: "cli"}
     | .target |= clip | if $to == "" then . else . + {to: ($to | clip)} end') &&
    (umask 077 && printf '%s\n' "$line" >>"$log") ||
    echo "audit: $2 $3 not recorded in $log" >&2
}
