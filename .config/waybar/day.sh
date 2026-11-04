#!/usr/bin/env bash
# Waybar module: the day. The bar is the PRs merged today, then a red !N when anything is
# red right now (cc:red_now: a tripped watch, a failed agent runner, a NotReady node, a frozen
# agent feed, a silent Sentinel). The hover groups
# the merged PRs by area and repo, lists the latest few, says what waits on you, and names
# what is red.
#
# Merged PRs come from day-log's record for today (DAYLOG_DIR/<YYYY-MM-DD>.json, local
# day), which day-log.timer refreshes every 5 minutes; this chip only reads it, so it spends
# no gh calls. A record older than STALE_SECS is shown dimmed with its age, and no record
# reads -, never 0. Red-now is cc:red_now, the home-config recording rule the hub board's
# "red now" line and the Grafana table also read; Prometheus unreadable reads !? in amber, never a quiet nothing.
# The phone lines (fleet-overview) are the merged count and the red-now line.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# nf-oct-git_merge, written as an escape so an editor cannot strip the glyph from this file.
MERGE_ICON=$'\uf419'
# day-log.timer refreshes the record every 5 minutes; past this the timer is not running.
STALE_SECS=900
C_DIM="#7f7f7f"
LATEST=5

: "${DAYLOG_DIR:=$HOME/.agent/daylog}"
now="${DAYLOG_NOW:-$(date +%s)}"
rec="$DAYLOG_DIR/$(date -d "@$now" +%F).json"

merged_text="${MERGE_ICON} -" merged_tip="merged today: no record (day-log.timer writes it)"
if [ -s "$rec" ] && summary="$(jq -r --argjson n "$LATEST" '
    def tally(f): group_by(f) | map({k: (.[0] | f // "other"), n: length}) | sort_by(-.n, .k)
      | map("\(.k) \(.n)") | join(", ");
    .merged as $m
    | ($m | length),
      "by area: \($m | tally(.area))",
      "by repo: \($m | tally(.repo))",
      ($m | sort_by(.merged_at) | reverse | .[:$n][] | "  \(.repo)#\(.number) \(.title)"),
      "--",
      "waiting on you: \(.waiting.asks // [] | length) asks, \(.waiting.needs // [] | length) sessions need you"
        + (if (.waiting.main // [] | length) > 0 then ", nightly red: \(.waiting.main | map(.repo) | join(", "))" else "" end),
      "open PRs: \(.open // [] | length)"' "$rec" 2>/dev/null)"; then
  mapfile -t L <<< "$summary"
  count="${L[0]}"
  age=$((now - $(stat -c %Y "$rec")))
  merged_text="${MERGE_ICON} ${count}"
  stamp="record $(prom_dur "$age") old"
  if ((age > STALE_SECS)); then
    merged_text="$(paint "$C_DIM" "$merged_text")"
    stamp+=", day-log.timer is not refreshing it"
  fi
  merged_tip="merged today: $count"
  for line in "${L[@]:1}"; do
    [ "$line" = -- ] && { merged_tip+=$'\n'; continue; }
    merged_tip+=$'\n'"$(pango_esc "$line")"
  done
  merged_tip+=$'\n'"$stamp"
fi

red_text="" class=ok
if red="$(prom_q 'cc:red_now')"; then
  mapfile -t RED < <(jq -r '.data.result[].metric.item' <<< "$red" | sort)
  if ((${#RED[@]} > 0)); then
    red_text=" $(paint "$C_RED" "!${#RED[@]}")" class=critical
    red_tip="red now (${#RED[@]}): $(pango_esc "$(printf '%s, ' "${RED[@]}")")"
    red_tip="${red_tip%, }"
  else
    red_tip="red now: nothing"
  fi
else
  red_text=" $(paint "$C_YEL" '!?')" class=warn red_tip="red now: cannot read $PROM_URL"
fi

emit "${merged_text}${red_text}" "<b>Today</b>  merged PRs, red now"$'\n'"$merged_tip"$'\n\n'"$red_tip" "$class" \
  "${merged_tip%%$'\n'*}"$'\n'"$red_tip"
