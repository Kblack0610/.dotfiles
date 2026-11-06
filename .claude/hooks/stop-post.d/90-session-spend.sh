#!/usr/bin/env bash
# Stop-post: tell the human when one hand-started session's spend passes CLAUDE_SESSION_ALERT_USD.
# ALERT ONLY: it never blocks, prints nothing the agent reads, and every path exits 0.
#
# Automated lanes stop themselves at their budgets (runner confs, the shepherd's queue session
# checkpoint); a human session is never stopped (Ken, ask F8z7aT, 2026-11-05), only flagged. A
# Sentinel watch cannot do this: a steady TRIP renotifies on a timer, not once per session per
# threshold, and it cannot link the session's pane.
#
# Spend is the session's OTel cost in Prometheus (claude_code_cost_usage_USD_total by session_id),
# the same series `claude-acct cost` reads. It lags by a scrape and misses off-LAN sessions, which
# is fine for an alert. Pings at 1x, 2x, 4x, 8x ... the threshold, once each.
#
# CLAUDE_SESSION_ALERT_USD (default 60, about 2x the main-checkout p90 of $30 a session)
# CLAUDE_SESSION_ALERT_EVERY seconds between Prometheus reads for one session (default 300)

trap 'exit 0' ERR
exec 2>/dev/null >/dev/null   # nothing it says may reach the agent or the transcript
set -u

# Queue sessions are the shepherd's (fleet-shepherd budget_sample); headless runs carry
# --max-budget-usd.
[ -z "${AGENT_QUEUE_ITEM:-}" ] || exit 0
[ "${CLAUDE_CODE_SESSION_ATTENDED:-0}" = 1 ] || exit 0

INPUT=$(cat) || exit 0
SID=$(jq -r '.session_id // empty' <<<"$INPUT") || exit 0
[[ "$SID" =~ ^[A-Za-z0-9-]+$ ]] || exit 0
CWD=$(jq -r '.cwd // empty' <<<"$INPUT") || CWD=

AT=${CLAUDE_SESSION_ALERT_USD:-60}
EVERY=${CLAUDE_SESSION_ALERT_EVERY:-300}
DIR=${XDG_CACHE_HOME:-$HOME/.cache}/agent-budget/session-spend
mkdir -p "$DIR" || exit 0
F="$DIR/$SID"   # "<level paged>"; its mtime is the last read

# One read per EVERY seconds: a Stop fires on every turn and the alert does not need more.
[ -f "$F" ] && [ $(( $(date +%s) - $(stat -c %Y "$F") )) -lt "$EVERY" ] && exit 0
had=$(cat "$F" 2>/dev/null || echo 0); [[ "$had" =~ ^[0-9]+$ ]] || had=0
echo "$had" > "$F"

# shellcheck source=../../../.local/lib/prom.sh
. "$(dirname "$(readlink -f "$0")")/../../../.local/lib/prom.sh"
usd=$(PROM_TIMEOUT=3 prom_q "sum(increase(claude_code_cost_usage_USD_total{session_id=\"$SID\"}[7d]))" |
  jq -r '.data.result[0].value[1] // empty | tonumber | . * 100 | round / 100') || exit 0
[ -n "$usd" ] || exit 0

# The level is the largest of 1, 2, 4, 8 ... that the spend has passed.
level=$(awk -v u="$usd" -v a="$AT" 'BEGIN { l = 0; if (a > 0) for (k = 1; u >= k * a; k *= 2) l = k; print l }')
[ "$level" -gt "$had" ] || exit 0
echo "$level" > "$F"

REF=""
[ -n "${TMUX_PANE:-}" ] && REF="$(tmux display-message -p -t "$TMUX_PANE" '#{b:socket_path}/#S:#I')"
agent-notify -p normal -t "Session spend: ${CWD##*/}" ${REF:+-r "tmux:$REF"} \
  "Session $SID has spent \$$usd (alert at \$$AT, this is ${level}x). Nothing was stopped. cwd: $CWD" || true

find "$DIR" -type f -mtime +7 -delete || true
exit 0
