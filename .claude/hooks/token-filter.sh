#!/usr/bin/env bash
# token-filter.sh - PreToolUse + PostToolUse(Bash): rewrite a command through the method in
# $STATE/mode (off | rtk | rtk-vcs) so less output reaches the model. Methods, the breaker
# and the safety contract: .claude/hooks/README.md "Token filter".
# Fail-open: every path exits 0 and any error leaves the command as written. It never sets
# permissionDecision, so a rewrite is approved exactly like the original (rtk's own hook
# auto-allows). A command carrying RTK_DISABLED=1, or matching $STATE/skip, is left alone.

trap 'exit 0' ERR
exec 2>/dev/null
set -u

STATE=${TOKEN_FILTER_STATE:-$HOME/.agent/token-filter}
CONF=${TOKEN_FILTER_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/token-filter}
CACHE=${TOKEN_FILTER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/token-filter}
TRIP=${TOKEN_FILTER_TRIP:-5}

MODE=$(head -c 32 "$STATE/mode" 2>/dev/null | tr -dc 'a-z-') || MODE=
case "$MODE" in rtk|rtk-vcs) ;; *) exit 0 ;; esac

INPUT=$(cat) || exit 0
command -v jq >/dev/null || exit 0
mkdir -p "$CACHE" || exit 0
EVENT=$(jq -r '.hook_event_name // empty' <<<"$INPUT") || exit 0
ID=$(jq -r '.tool_use_id // empty' <<<"$INPUT") || ID=
SID=$(jq -r '.session_id // empty' <<<"$INPUT") || SID=
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

fail() {  # fail <kind> <detail>: one failures.jsonl line, then the breaker check
  jq -cn --arg ts "$NOW" --arg sid "$SID" --arg id "$ID" --arg m "$MODE" \
    --arg k "$1" --arg d "${2:0:300}" \
    '{ts:$ts,sid:$sid,id:$id,method:$m,kind:$k,detail:$d}' >> "$CACHE/failures.jsonl"
  local since n
  since=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
  n=$(tail -n 200 "$CACHE/failures.jsonl" | jq -r --arg s "$since" 'select(.ts >= $s) | .ts' | wc -l)
  [ "$n" -ge "$TRIP" ] || return 0
  (
    exec 9>>"$STATE/mode.lock"
    flock -w 2 9 || exit 0
    [ "$(cat "$STATE/mode" 2>/dev/null)" = off ] && exit 0
    echo off > "$STATE/mode"
    jq -cn --arg ts "$NOW" --arg from "$MODE" --arg r "breaker: $n rtk failures in the last hour, last: $1" \
      '{ts:$ts,method:"off",from:$from,by:"breaker",reason:$r}' >> "$STATE/methods.jsonl"
    agent-notify -p high -t "token-filter tripped to off" \
      "$n rtk failures in an hour (last: $1: ${2:0:120}). Commands run unfiltered now. Look: token-filter doctor; back on: token-filter use $MODE" \
      >/dev/null 2>&1 || true
  )
}

if [ "$EVENT" = PreToolUse ]; then
  CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT") || exit 0
  [ -n "$CMD" ] || exit 0
  case "$CMD" in *RTK_DISABLED=1*|rtk\ *) exit 0 ;; esac
  # skip: one ERE per line, tracked defaults in $CONF, local additions in $STATE.
  if grep -qEf <(cat "$CONF/skip" "$STATE/skip" 2>/dev/null | grep -vE '^(#|$)') <<<"$CMD"; then
    exit 0
  fi
  if ! command -v rtk >/dev/null; then fail rtk-missing "$CMD"; exit 0; fi
  RC=0  # the || keeps a nonzero rewrite (3 is "rewritten, ask") from firing the ERR trap
  NEW=$(RTK_SUPPRESS_HOOK_WARNING=1 timeout 2 rtk rewrite "$CMD") || RC=$?
  case "$RC" in
    0|3) ;;
    1|2) exit 0 ;;   # 1 no rtk equivalent, 2 a deny rule: Claude Code's own deny handles it
    124) fail rewrite-timeout "$CMD"; exit 0 ;;
    *) fail rewrite-error "rc=$RC $CMD"; exit 0 ;;
  esac
  [ -n "$NEW" ] && [ "$NEW" != "$CMD" ] || exit 0
  if [ "$MODE" = rtk-vcs ] && grep -qE '(^|[;&|(] *)rtk (grep|rg|read|ls|find|tree|wc|jq|json|log|diff)\b' <<<"$NEW"; then
    exit 0
  fi
  jq -cn --arg ts "$NOW" --arg sid "$SID" --arg id "$ID" --arg m "$MODE" --arg o "$CMD" --arg n "$NEW" \
    '{ts:$ts,sid:$sid,id:$id,method:$m,orig:$o,new:$n}' >> "$CACHE/rewrites.jsonl"
  jq -c --arg cmd "$NEW" '.tool_input.command = $cmd
    | {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: .tool_input}}' <<<"$INPUT"
  exit 0
fi

# PostToolUse / PostToolUseFailure: only commands this hook rewrote are looked at.
[ -n "$ID" ] || exit 0
REW=$(tail -n 500 "$CACHE/rewrites.jsonl" | grep -F "\"id\":\"$ID\"" | tail -n 1)
[ -n "$REW" ] || exit 0
OUT=$(jq -r '[.tool_response | .. | strings] + [.error // empty | tostring] | join("\n")' <<<"$INPUT" | head -c 20000)
SIG=$(grep -m1 -E '^\[rtk\] (error|warning: filter panicked)|^rtk: |^error: (unexpected|unrecognized|invalid)|^Usage: rtk' <<<"$OUT") || exit 0
ORIG=$(jq -r '.orig' <<<"$REW")
fail rtk-error "$SIG | $ORIG"
jq -cn --arg o "$ORIG" --arg s "$SIG" --arg ev "$EVENT" '{hookSpecificOutput: {hookEventName: $ev,
  additionalContext: ("The token filter rewrote this command through rtk and rtk reported: " + $s
    + ". If the output looks wrong or incomplete, run the original unfiltered: RTK_DISABLED=1 " + $o)}}'
exit 0
