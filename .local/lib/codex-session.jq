# codex-session.jq -- one Codex rollout -> one registry-shaped line for the outcome row.
#   jq -cs --argjson prices <harnesses.json .codex.prices> --arg file <path> "$SO_PR_JQ$(cat this)" rollout.jsonl
# so_codex_rows (session-outcomes.sh) is the one caller and rolls a subagent's line into its parent's.
# codex-rollout.jq reads the same files for why a run ended; this one says what the run did.
# Field meanings: DREAMING.md "Session outcomes" (private overlay), "Codex rows".
# Two rollout formats exist, one per run: the item format has a CommandExecution per command with its
# exit code and output; the older one has exec_command calls and no exit code. Commands come from the
# first if it has any. A fact a format lacks is null, never 0: tool_errors 0 would claim every command passed.
# metrics has the shape so_transcript_metrics gives a Claude transcript, so one row builder reads both.
# edits are git's own count (the files each `git commit` printed); a run that never committed falls
# back to its patched files.
def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def shell_cmd: if type == "array" then (if length >= 3 and (.[1] | test("^-[a-z]*c$")) then .[2] else join(" ") end) else tostring end;
def commit_cmd: test("(^|[\\n;&|(])\\s*(\\w+=\\S*\\s+)*git\\s+(-C\\s+\\S+\\s+)?commit\\b");
def first_text: (.content // [] | map(.text // empty) | join("\n"));
def title_of:
  split("\n") | map(select(test("\\S"))) as $l
  | if ($l | length) == 0 then ""
    elif ($l[0] | test(":$")) and ($l | length) > 1 then $l[1] else $l[0] end
  | .[0:120];

(map(select(.type == "session_meta")) | first | .payload) as $m
| select($m.id)
| (map(select(.type == "response_item") | .payload)) as $r
| ($r | map(select(.type == "function_call_output" or .type == "custom_tool_call_output")
            | {key: .call_id, value: (.output | tostring)}) | from_entries) as $out
| [.[] | select(.type == "event_msg")] as $evt
| ($evt | map(.payload)) as $ev
| [$ev[] | select(.type == "item_completed") | .item] as $items
| (map(select(.type == "event_msg" and .payload.type == "token_count") | .payload.info // empty)) as $tc
| ($tc | map(.total_token_usage // empty) | last) as $u
| (map(.timestamp // empty | ts)) as $t
| (map(select(.type == "turn_context") | .payload) | map(.model // empty) | unique) as $mods
| (map(select(.type == "turn_context") | .payload | .effort // .collaboration_mode.settings.reasoning_effort // empty) | first) as $effort
| (if $u != null and ($mods | length) == 1 and ($u.cache_write_input_tokens // 0) == 0
      and ([$prices[$mods[0]].input, $prices[$mods[0]].cached_input, $prices[$mods[0]].output] | all(type == "number"))
   then $prices[$mods[0]] as $pr
     | ((($u.input_tokens - ($u.cached_input_tokens // 0)) * $pr.input + ($u.cached_input_tokens // 0) * $pr.cached_input
         + $u.output_tokens * $pr.output) / 1000000 * 1000000 | round) / 1000000
   else null end) as $cost
| ([$items[] | select(.type == "CommandExecution")
    | {cmd: (.command | shell_cmd), out: (.aggregated_output // ""), exit: .exit_code}]) as $items_cmds
| (if ($items_cmds | length) > 0 then $items_cmds
   else [ ($r[] | select(.type == "function_call" and .name == "exec_command")
           | {cmd: (.arguments | fromjson? | .cmd // ""), out: ($out[.call_id] // ""), exit: null}),
          ($r[] | select(.type == "custom_tool_call" and .name == "exec")
           | {cmd: (.input // ""), out: ($out[.call_id] // ""), exit: null}) ] end) as $cmds
| ($cmds | any(.[]; .exit != null)) as $exits
| ([$items[] | select(.type == "FileChange") | .changes // {} | keys[]] | unique | length) as $filechanges
| (if $filechanges > 0 then 0 else ($r | map(select(.name == "apply_patch")) | length) end) as $patches
| ([$cmds[] | select(.cmd | commit_cmd) | .out | [scan("^\\[[^\\]\\n]+ [0-9a-f]{7,}\\][^\\n]*\\n\\s*([0-9]+) files? changed") | .[0] | tonumber] | add // empty]) as $commits
| ([$ev[] | select(.type == "task_complete" and .error != null)]) as $errs
| (if ($t | length) == 0 then 0 else $t | max end) as $tmax
| (reduce ($evt[] | select(.payload.type | IN("task_started", "task_complete", "turn_aborted"))) as $e ({open: null, s: 0};
     ($e.timestamp | ts) as $at
     | if $e.payload.type == "task_started" then (if .open != null then .s += ($at - .open) else . end) | (.open = $at)
       elif .open != null then (.s += ($at - .open)) | (.open = null) else . end)
   | if .open != null then .s += ($tmax - .open) else . end | .s) as $turn_s
| ([$cmds[] | select(.cmd | test(test_run))]) as $tests
| { session_id: $m.id, harness: "codex", cwd: $m.cwd,
    parent: ($m.source | if type == "object" then .subagent.thread_spawn.parent_thread_id else null end),
    title: (([$items[] | select(.type == "UserMessage") | first_text] + [$ev[] | select(.type == "user_message") | .message // empty])
            | first // "" | title_of),
    updated: ($t | max | floor), duration_s: ((($t | max) - ($t | min)) | floor),
    edits: (if ($commits | length) > 0 then ($commits | add) else $filechanges + $patches end),
    effort: $effort,
    error: ($errs | last | .error.codex_error_info | if type == "object" then keys[0] else . end),
    rollout: $file,
    account: ($file | capture("/(?<a>\\.codex[^/]*)/sessions/").a? // null),
    cost_by_model: (if $cost == null then null else {($mods[0]): $cost} end),
    unpriced: ($u != null and $cost == null),
    models: $mods,
    tokens: (if $u == null then null else
               {input: ($u.input_tokens - ($u.cached_input_tokens // 0)), output: $u.output_tokens,
                cacheCreation: ($u.cache_write_input_tokens // 0), cacheRead: ($u.cached_input_tokens // 0),
                total: ($u.input_tokens + $u.output_tokens)} end),
    peak_context: ([$tc[] | .last_token_usage.input_tokens // empty] | max),
    metrics: {
      prs: [],
      hard_errors: {api_error: ($errs | length), denied: null,
                    tool_errors: (if $exits then [$cmds[] | select(.exit != null and .exit != 0)] | length else null end)},
      activity: {tool_calls: (($cmds | length) + $filechanges + $patches),
                 test_runs: ($tests | length),
                 test_failures: (if $exits then [$tests[] | select(.exit != null and .exit != 0)] | length else null end),
                 ci_polls: ([$cmds[] | select(.cmd | test(ci_poll))] | length),
                 api_messages: ([.[] | select(.type == "token_usage_record") | .payload.response_id // empty] | unique | length
                                | if . == 0 then null else . end),
                 tokens: (if $u == null then null else $u.input_tokens + $u.output_tokens end),
                 tokens_after_last_edit: null, compactions: null},
      time_use: {work_min: (if ($ev | any(.type == "task_started")) then ($turn_s / 60 | floor) else null end),
                 gate_min: null, test_min: null, jobs_min: null, human_min: null, parked_min: null}
    },
    prs: ([ $cmds[] | select(.cmd | pr_cmd) | .out | pr_refs[] ] | unique) }
