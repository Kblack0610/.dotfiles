# codex-rollout.jq -- why a Codex run ended, read from its rollout. The one classifier: settle_item
# (fleet-dispatch) is the only caller, and its answer is the item's end_reason.
#
#   jq -rs --argjson timeout_s <launcher timeout, 0 for none> -f codex-rollout.jq rollout-*.jsonl
#
# Prints one of: refused (the login or plan turned the run away), limit (the plan's quota ran out),
# provider (the provider failed: overload, connection, 5xx), cut (the run was interrupted or killed),
# timeout (killed after the launcher's timeout), stopped (the session finished its turn: the model's
# own end, so it still rates). Nothing when the rollout holds no turn at all.
#
# The rollout's last turn event decides, from structure only: task_complete with an `error` carries
# `codex_error_info`, a turn_aborted carries a `reason`, and a task_started with neither was killed
# mid-turn. An error code this file does not know is `stopped`: an unknown failure keeps rating
# against the model rather than hiding. Message text is never read. Variants that carry data (http_connection_failed and others) arrive as
# an object with the variant as its one key.
#
# A kill with no terminal event is a timeout when the last turn ran for 90% of the launcher's timeout
# or more (the launcher's clock starts before the rollout's first event); a host reboot or a manual
# kill in a turn that long reads as a timeout too, which rates the model.
def code_end:
  (if type == "object" then keys[0] else . end) |
  if . == "usage_limit_exceeded" then "limit"
  elif . == "unauthorized" then "refused"
  elif IN("server_overloaded", "http_connection_failed", "response_stream_connection_failed",
          "response_stream_disconnected", "response_too_many_failed_attempts", "internal_server_error")
  then "provider"
  else "stopped" end;
def at: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
[.[] | select(.type == "event_msg")] as $ev
| [$ev[] | select(.payload.type | IN("task_started", "task_complete", "turn_aborted"))] | last as $last
| if $last == null then empty
  elif $last.payload.type == "task_complete" then ($last.payload.error.codex_error_info // "" | if . == "" then "stopped" else code_end end)
  elif $last.payload.type == "turn_aborted" then "cut"
  elif $timeout_s > 0 and ((($ev | last).timestamp | at) - ($last.timestamp | at)) >= $timeout_s * 0.9 then "timeout"
  else "cut" end
