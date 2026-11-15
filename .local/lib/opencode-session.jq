# opencode-session.jq -- why an opencode run ended (go, nim, ocfree), in codex-rollout.jq's vocabulary
# (end-reasons.sh). fleet-dispatch's item_oc_end feeds it the session_message rows of the item's session:
#   jq -r --argjson timeout_s <launcher timeout, 0 for none> -f opencode-session.jq
#   rows: {type, time_created, time_updated, finish, etype}, finish and etype from the row's data JSON.
# The last assistant row decides, from structure only, never text: error.type auth -> refused, quota ->
# limit, rate-limit or provider error -> provider, aborted or still working (no stop) -> cut, or timeout
# once the session ran 90% of the launcher's timeout; finish stop and any unknown error -> stopped, so
# an unknown failure keeps rating against the model. No assistant row: nothing.
def err_end:
  if . == "provider.auth" then "refused"
  elif . == "provider.quota" then "limit"
  elif IN("provider.rate-limit", "provider.error") then "provider"
  elif . == "aborted" then "killed"
  else "stopped" end;
def killed:
  if $timeout_s > 0 and (([.[].time_updated] | max) - ([.[].time_created] | min)) / 1000 >= $timeout_s * 0.9
  then "timeout" else "cut" end;
. as $rows
| ([$rows[] | select(.type == "assistant")] | last) as $a
| if $a == null then empty
  else (if $a.etype != null then $a.etype | err_end
        elif $a.finish == "tool-calls" or $a.finish == null then "killed"
        else "stopped" end)
       | if . == "killed" then ($rows | killed) else . end
  end
