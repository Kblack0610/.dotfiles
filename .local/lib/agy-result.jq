# agy-result.jq -- why an agy (Antigravity CLI) run ended, from the log agent-agy kept. The one
# classifier: fleet-dispatch's item_end is its one automated caller.
#   jq -rnR --argjson timeout_s <launcher timeout, 0 for none> -f agy-result.jq <log>
# The log is agy's stream-json stdout plus agent-agy's start, stderr and exit lines; a line cut short
# by a kill is skipped. Prints what codex-rollout.jq prints (refused, limit, provider, cut, timeout,
# stopped), or nothing when the log shows no turn, or no result and no exit line.
# Structure only, never message text. agy names a quota or provider fault only in its stderr
# AGY_ERROR line. An ERROR before any conversation began (conversation_id "": no login, a model agy
# does not know) is refused, since the model never ran. A kill or interrupt after 90% of the
# launcher's timeout is timeout. An unknown error is stopped, so it still rates against the model.
[inputs | fromjson? | objects] as $ev
| ($ev | map(select(.event == "result")) | last | .result) as $r
| ($ev | map(select(.event == "start")) | first | .at) as $t0
| ($ev | map(select(.event == "exit")) | last) as $exit
| ([$ev[] | select(.event == "stderr") | .text // "" | select(startswith("AGY_ERROR: ")) | ltrimstr("AGY_ERROR: ") | fromjson? | objects]
   | last // {}) as $e
| ($timeout_s > 0 and $t0 != null and $exit.at != null and ($exit.at - $t0) >= $timeout_s * 0.9) as $ran_out
| if $r == null then
    if $exit == null or ($ev | any(.event == "init" or .event == "step_update") | not) then empty
    elif $ran_out then "timeout" else "cut" end
  elif $r.status == "SUCCESS" then "stopped"
  elif $r.finished_reason == "interrupted" then (if $ran_out then "timeout" else "cut" end)
  elif $r.finished_reason == "print_timeout" then "timeout"
  elif $e.status == "RESOURCE_EXHAUSTED" or ($e.code // $e.http_status) == 429 then "limit"
  elif $e.status | IN("UNAUTHENTICATED", "PERMISSION_DENIED") then "refused"
  elif $e.status | IN("UNAVAILABLE", "INTERNAL", "DEADLINE_EXCEEDED") then "provider"
  elif ($r.conversation_id // "") == "" then "refused"
  else "stopped" end
