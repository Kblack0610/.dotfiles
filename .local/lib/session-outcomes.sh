# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# session-outcomes.sh - what a session actually did, measured against GitHub and the
# transcript's structure instead of judged from its tail. The eval judge scored 89% of
# October sections 10/10, so it cannot rank sessions; this can.
#
# Everything is counted from STRUCTURE (record types, tool_use ids, is_error, PR state),
# never from prose: a transcript that quotes "API Error" has not hit one.
#
# Output and checkpoint are the same file: $SO_OUT/<project>/YYYY-MM.jsonl, one line per
# session per observation; readers take the last per session_id (so_latest).
# Field meanings and the observation rule: .config/agentctl/DREAMING.md
# ("Session outcomes") in the private overlay.

# so_transcript_metrics FILE - one pass over a transcript, one JSON object out.
# A PR counts only when a `gh pr create|merge` call's own result printed it, so a PR
# merely viewed or pasted is not claimed. lessons_written counts corrections (the rule
# is "after ANY correction, update lessons"); most land as `cat >>` through Bash, not
# Edit, so both are counted. Malformed lines are skipped, not fatal:
# a transcript cut off by a crash is the session this feed most needs to see.
# entrypoint is the first one a record carries: "sdk-cli" is a headless `claude -p`.
# activity is how the session spent itself. A test run is a test command at the start of a
# Bash line, so a commit message naming one does not count. An API message's records repeat
# its usage, so each id counts once, and tokens include cache reads, as the bill does. Tokens
# after the last edit are what it spent past its last commit or change to anything but its
# own notes; a commit counts because an edit made through Bash is not a tool call of its own.
# uses counts what the session reached for, by name: Agent spawns by subagent_type, Skill
# calls, and typed /commands. Calls made inside a subagent live in its own transcript and
# are not counted here; `claude-recall stats` folds those in. A compaction is a
# compact_boundary record, split by what triggered it: auto (the context filled) or manual.
# guards counts each hook denial by the hook's name: a PreToolUse deny reaches the transcript as
# `PreToolUse:<Tool> hook error: <name>: ...` and a Stop block as `Stop hook feedback:\n<name>: ...`,
# so a hook whose reason starts with `<name>: ` is counted and one that does not is invisible.
# plan_gate counts ExitPlanMode calls and how many of them plan-standard.sh denied;
# the human rejecting a plan is `denied` under hard_errors, not a gate denial.
so_transcript_metrics() {
  jq -nR --argjson sigs "${2:-[]}" '
    def test_run: "(^|[;&|(\\n])\\s*((until|while|if|time|env|timeout\\s+\\S+|\\w+=\\S*)\\s+)*(\\S*scripts/test/(run|suite)\\.sh|(\\S*/)?bats\\s|pytest\\b|cargo\\s+test\\b|make\\s+(-C\\s+\\S+\\s+)?test|(npm|pnpm|yarn)\\s+(\\S+\\s+)*?test\\b)";
    def ci_poll: "\\bgh\\s+(run\\s+(view|watch|list)|pr\\s+checks)\\b";
    def text_of: if type == "string" then .
                 elif type == "array" then ([.[]? | .text? // empty] | join("\n"))
                 else "" end;
    reduce (inputs | fromjson? | select(type == "object")) as $r (
      { pr_ids: {}, lesson_ids: {}, done_ids: {}, prs: [], entrypoint: null,
        interrupts: 0, lessons_written: 0, proof: 0, unverified: 0,
        api_error: 0, denied: 0, tool_errors: 0,
        tool_calls: 0, test_runs: 0, ci_polls: 0, messages: {}, since_edit: {},
        plan_exits: 0, plan_denied: 0, guards: {}, lesson_hits: {},
        compactions: { auto: 0, manual: 0 },
        uses: { subagents: {}, skills: {}, slash: {} } };
      (if .entrypoint == null and ($r.entrypoint | type) == "string" then .entrypoint = $r.entrypoint else . end)
      | if $r.type == "assistant" then
        (if $r.isApiErrorMessage == true then .api_error += 1 else . end)
        | (if ($r.message.id | type) == "string" then
             ($r.message.usage // {} | [.input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens, .output_tokens]
              | map(. // 0) | add) as $tokens
             | .messages[$r.message.id] = $tokens | .since_edit[$r.message.id] = $tokens
           else . end)
        | reduce ($r.message.content | if type == "array" then .[] else empty end
                  | select(.type == "tool_use")) as $u (.;
            .tool_calls += 1
            | (if $u.name == "ExitPlanMode" then .plan_exits += 1 else . end)
            | (if $u.name == "Agent" or $u.name == "Task" then
                 .uses.subagents[($u.input.subagent_type // "general-purpose") | tostring] += 1
               elif $u.name == "Skill" and ($u.input.skill | type) == "string" then
                 .uses.skills[$u.input.skill] += 1
               else . end)
            | (if (["Edit", "Write", "MultiEdit", "NotebookEdit"] | index($u.name)) != null
                  and (($u.input.file_path // $u.input.notebook_path // "") | test("/\\.agent/|/\\.claude/(plans|projects)/") | not) then
                 .since_edit = {}
               else . end)
            | if $u.name == "Bash" then
              ($u.input.command // "") as $c
              | (if ($c | test(test_run)) then .test_runs += 1 else . end)
              | (if ($c | test(ci_poll)) then .ci_polls += 1 else . end)
              | (if ($c | test("\\bgit\\s+commit\\b")) then .since_edit = {} else . end)
              | (if ($c | test("\\bgh\\s+pr\\s+(create|merge)\\b")) then .pr_ids[$u.id] = true else . end)
              | (if ($c | test("(>>|tee\\s+-a)\\s*\\S*\\.agent/lessons/")) then .lesson_ids[$u.id] = true else . end)
              | reduce ($sigs[] | select((($r.timestamp // "") | .[0:10]) > .since)
                        | select(.sig as $re | try ($c | test($re)) catch false)) as $s (.;
                  .lesson_hits[$s.sig] += 1)
              | (if ($c | test("\\bnotes\\s+ptask\\b.*\\sdone\\b")) then
                   (if ($c | test("--unverified")) then .done_ids[$u.id] = "unverified"
                    elif ($c | test("--proof")) then .done_ids[$u.id] = "proof"
                    else . end)
                 else . end)
            elif (["Edit", "Write", "MultiEdit"] | index($u.name)) != null
                 and (($u.input.file_path // "") | test("/\\.agent/lessons/")) then
              .lesson_ids[$u.id] = true
            else . end)
      elif $r.type == "user" then
        reduce ($r.message.content
                | if type == "array" and any(.[]?; .type? == "tool_result") then "" else text_of end
                | select(test("^\\s*<command-(name|message)>"))
                | scan("<command-name>/?([^<\\s]+)</command-name>")[0]) as $cmd (.;
          .uses.slash[$cmd] += 1)
        | if ($r.message.content | type) == "string" then
          (if ($r.message.content | startswith("[Request interrupted by user")) then .interrupts += 1 else . end)
          | ((($r.message.content | capture("^Stop hook feedback:\\n(?<g>[a-z][a-z0-9-]+): ") | .g) // null) as $g
             | if $g then .guards[$g] += 1 else . end)
        else
          reduce ($r.message.content | if type == "array" then .[] else empty end) as $c (.;
            if $c.type == "tool_result" then
              ($c.content | text_of) as $t
              | ($c.is_error == true) as $err
              | (if $err then .tool_errors += 1 else . end)
              | (if $err and ($t | startswith("The user doesn'"'"'t want to proceed")) then .denied += 1 else . end)
              | (if $err then
                   (($t | capture("^PreToolUse:(?<tool>[A-Za-z_]+) hook error: (?<g>[a-z][a-z0-9-]+): ")) // null) as $m
                   | if $m then .guards[$m.g] += 1
                       | (if $m == {tool: "ExitPlanMode", g: "plan-standard"} then .plan_denied += 1 else . end)
                     else . end
                 else . end)
              | (if ($err | not) and .pr_ids[$c.tool_use_id] then
                   .prs += ([ $t | scan("https://github\\.com/([^/\\s]+)/([^/\\s]+)/pull/([0-9]+)")
                              | {repo: "\(.[0])/\(.[1])", number: (.[2] | tonumber)} ]
                          + [ $t | scan("[Mm]erged pull request ([^/\\s]+)/([^#\\s]+)#([0-9]+)")
                              | {repo: "\(.[0])/\(.[1])", number: (.[2] | tonumber)} ])
                 else . end)
              | (if ($err | not) and .lesson_ids[$c.tool_use_id] then .lessons_written += 1 else . end)
              | (if ($err | not) and .done_ids[$c.tool_use_id] then
                   (if .done_ids[$c.tool_use_id] == "proof" then .proof += 1 else .unverified += 1 end)
                 else . end)
            elif $c.type == "text" and (($c.text // "") | startswith("[Request interrupted by user")) then
              .interrupts += 1
            else . end)
        end
      elif $r.type == "system" and $r.subtype == "compact_boundary" then
        .compactions[if $r.compactMetadata.trigger == "manual" then "manual" else "auto" end] += 1
      else . end)
    | { prs: (.prs | unique),
        entrypoint,
        corrections: { interrupts, lessons_written },
        board_done: { proof, unverified },
        hard_errors: { api_error, denied, tool_errors },
        plan_gate: { exits: .plan_exits, denied: .plan_denied },
        guards, lesson_hits,
        activity: { tool_calls, test_runs, ci_polls, api_messages: (.messages | length),
                    tokens: (.messages | add // 0), tokens_after_last_edit: (.since_edit | add // 0),
                    compactions },
        uses }
  ' < "$1"
}

# so_opencode_rows DB WORK - one registry-shaped line per root opencode session, read-only: opencode
# has no Stop hook, and its own DB already holds cost and tokens. `session_v2` is the live table;
# `session` and `part` stopped being written at 2.1.4. Times are milliseconds. A child session (a
# subagent) adds to its root and gets no line. PRs follow the rule at the top of this file: a
# `gh pr create|merge` call's own output printed it. No DB is no rows; a schema it cannot read is rc 1.
so_opencode_rows() {
  local db="$1" work="$2" tree dir
  [ -e "$db" ] || return 0
  tree="WITH RECURSIVE tree(root, id) AS (SELECT id, id FROM session_v2 WHERE parent_id IS NULL
        UNION ALL SELECT tree.root, c.id FROM session_v2 c JOIN tree ON c.parent_id = tree.id)"
  sqlite3 -readonly -json "$db" "$tree
    SELECT t.root AS session_id, r.directory, r.title, r.model, r.summary_files AS edits, r.time_created AS created_ms,
           max(s.time_updated) AS updated_ms, sum(s.cost) AS cost_usd,
           sum(s.tokens_input) AS input, sum(s.tokens_output) AS output, sum(s.tokens_reasoning) AS reasoning,
           sum(s.tokens_cache_read) AS cache_read, sum(s.tokens_cache_write) AS cache_write
    FROM tree t JOIN session_v2 r ON r.id = t.root JOIN session_v2 s ON s.id = t.id GROUP BY t.root" > "$work/oc.sessions.json" || return 1
  sqlite3 -readonly -json "$db" "$tree
    SELECT t.root, m.data FROM tree t JOIN session_message m ON m.session_id = t.id
    WHERE m.type = 'assistant' AND m.data LIKE '%gh pr %'" > "$work/oc.messages.json" || return 1
  # shellcheck source=/dev/null
  . "${SO_PROJECT_LIB:-$HOME/.config/shared-hooks/project-name.sh}" || return 1
  jq -r '(. // [])[].directory' "$work/oc.sessions.json" | sort -u | while IFS= read -r dir; do
    jq -cn --arg d "$dir" --arg p "$(resolve_project_name "$dir")" '{key: $d, value: $p}'
  done | jq -cs from_entries > "$work/oc.projects.json" || return 1
  jq -cn --slurpfile s "$work/oc.sessions.json" --slurpfile m "$work/oc.messages.json" --slurpfile p "$work/oc.projects.json" '
    (($m[0] // []) | group_by(.root)
     | map({key: .[0].root,
            value: [ .[].data | fromjson | .content[]?
                     | select(.type == "tool" and .name == "bash" and .state.status == "completed"
                              and (.state.input.command // "" | test("\\bgh pr (create|merge)\\b")))
                     | [.state.content[]?.text] | join("\n")
                     | scan("https://github\\.com/([^/\\s]+)/([^/\\s]+)/pull/([0-9]+)")
                     | {repo: "\(.[0])/\(.[1])", number: (.[2] | tonumber)} ] | unique})
     | from_entries) as $prs
    | ($s[0] // [])[]
    | { session_id, harness: "opencode", project: $p[0][.directory], title,
        updated: (.updated_ms / 1000 | floor), duration_s: ((.updated_ms - .created_ms) / 1000 | floor),
        edits: (.edits // 0), cost_usd, models: [(.model // "{}") | fromjson | .id // empty],
        tokens: {input, output, cacheCreation: .cache_write, cacheRead: .cache_read,
                 total: (.input + .output + .reasoning + .cache_read + .cache_write)},
        prs: ($prs[.session_id] // []) }'
}

# so_codex_rows DIR WORK - one registry-shaped line per root Codex session, read-only from its rollout
# files (DIR/YYYY/MM/DD/rollout-*.jsonl): Codex has no Stop hook either. Tokens are the last
# token_count total; OpenAI's input counts the cached part, so input here is what was not cached,
# as claude's rows read. A subagent's rollout (session_meta source.subagent) adds to its parent and
# gets no line. A ChatGPT plan bills no dollars, so cost_usd is null. PRs follow the rule at the top
# of this file, from a `gh pr create|merge` shell call paired with its own output.
so_codex_rows() {
  local dir="$1" work="$2" f
  [ -d "$dir" ] || return 0
  find "$dir" -name 'rollout-*.jsonl' -type f | while IFS= read -r f; do
    jq -cs 'def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      def prs: [scan("https://github\\.com/([^/\\s]+)/([^/\\s]+)/pull/([0-9]+)") | {repo: "\(.[0])/\(.[1])", number: (.[2] | tonumber)}];
      def pr_cmd: test("\\bgh pr (create|merge)\\b");
      (map(select(.type == "session_meta")) | first | .payload) as $m
      | select($m.id)
      | (map(select(.type == "response_item") | .payload)) as $r
      | ($r | map(select(.type == "function_call_output" or .type == "custom_tool_call_output")
                  | {key: .call_id, value: (.output | tostring)}) | from_entries) as $out
      | (map(select(.type == "event_msg" and .payload.type == "token_count") | .payload.info.total_token_usage // empty) | last) as $u
      | (map(.timestamp // empty | ts)) as $t
      | { session_id: $m.id, harness: "codex", cwd: $m.cwd,
          parent: ($m.source | if type == "object" then .subagent.thread_spawn.parent_thread_id else null end),
          title: (map(select(.type == "event_msg" and .payload.type == "user_message") | .payload.message) | first // "" | split("\n")[0] | .[0:120]),
          updated: ($t | max | floor), duration_s: ((($t | max) - ($t | min)) | floor),
          edits: ($r | map(select(.name == "apply_patch")) | length),
          cost_usd: null,
          models: (map(select(.type == "turn_context") | .payload.model // empty) | unique),
          tokens: (if $u == null then null else
                     {input: ($u.input_tokens - ($u.cached_input_tokens // 0)), output: $u.output_tokens,
                      cacheCreation: ($u.cache_write_input_tokens // 0), cacheRead: ($u.cached_input_tokens // 0),
                      total: ($u.input_tokens + $u.output_tokens)} end),
          prs: ([ ($r[] | select(.type == "function_call" and .name == "exec_command")
                   | select((.arguments | fromjson? | .cmd // "") | pr_cmd) | $out[.call_id] // "" | prs[]),
                  ($r[] | select(.type == "custom_tool_call" and .name == "exec")
                   | select(.input // "" | pr_cmd) | $out[.call_id] // "" | prs[]),
                  (.[] | select(.type == "event_msg" and .payload.type == "item_completed" and .payload.item.type == "CommandExecution")
                   | .payload.item | select(.command | if type == "array" then join(" ") else tostring end | pr_cmd)
                   | .aggregated_output // "" | prs[]) ] | unique) }' "$f" || echo "so_codex_rows: unreadable $f" >&2
  done > "$work/cx.rows.jsonl"
  # shellcheck source=/dev/null
  . "${SO_PROJECT_LIB:-$HOME/.config/shared-hooks/project-name.sh}" || return 1
  jq -r '.cwd // empty' "$work/cx.rows.jsonl" | sort -u | while IFS= read -r dir; do
    jq -cn --arg d "$dir" --arg p "$(resolve_project_name "$dir")" '{key: $d, value: $p}'
  done | jq -cs from_entries > "$work/cx.projects.json" || return 1
  jq -cs --slurpfile p "$work/cx.projects.json" '
    def add_tok(a; b): if a == null then b elif b == null then a else
      reduce (b | keys[]) as $k (a; .[$k] = ((.[$k] // 0) + b[$k])) end;
    (map(select(.parent == null) | {key: .session_id, value: .}) | from_entries) as $roots
    | reduce (.[] | select(.parent != null and $roots[.parent] != null)) as $c ($roots;
        .[$c.parent] |= (.edits += $c.edits | .tokens = add_tok(.tokens; $c.tokens)
                         | .models = (.models + $c.models | unique) | .prs = (.prs + $c.prs | unique)
                         | .updated = ([.updated, $c.updated] | max)))
    | .[] | .project = $p[0][.cwd] | del(.cwd, .parent)' "$work/cx.rows.jsonl"
}

# so_lesson_sigs [DIR] - the lessons that carry a sig, as one JSON array of {sig, since, claim,
# file}. A lesson opts in by ending with `<!-- sig:YYYY-MM-DD <regex> -->`: the regex (jq) matches
# the mistake as a Bash command, anchored so a grep for its words does not count, and the date is
# when the lesson was written. so_transcript_metrics counts a hit only on a later day, so the
# session that wrote it is not its first recurrence. The same sig in several files is one lesson,
# dated by its first writing; a lesson's claim is its first bold span, without `#` (a tag on a row).
so_lesson_sigs() {
  local dir="${1:-${SO_LESSONS_DIR:-$HOME/.agent/lessons}}"
  { grep -H -- '<!-- sig:' "$dir"/*.md 2>/dev/null || true; } | jq -nR '
    [inputs | capture("^(?<file>[^:]+):(?<line>.*)<!-- sig:(?<since>[0-9]{4}-[0-9]{2}-[0-9]{2}) (?<sig>.+?) -->")
     | {sig, since, file: (.file | split("/")[-1]),
        claim: (.line | sub("^\\s*-\\s*"; "") | sub("^\\*\\*[0-9-]+\\*\\*\\s*"; "")
                | ((capture("^\\*\\*(?<c>.+?)\\*\\*") | .c) // .) | gsub("#"; "") | .[0:120])}]
    | group_by(.sig) | map(min_by(.since))'
}

# so_pr_index FINAL_DAYS - stdin: a `gh pr list --json number,state,title,mergedAt,body,mergeCommit`
# array for ONE repo. stdout: {"<number>": {state, merged_at, reverted}}.
# reverted = a merged PR, merged within FINAL_DAYS after this one, that is titled
# `Revert "<title>"` (GitHub's button), has a title or body line where a revert word comes
# before `#N` ("Reverts #240", `Revert "x (#5)"`), or says "This reverts commit <sha>" of
# this PR's merge commit. `#N\b` so #5 never matches #50; "revert-safe" is not a revert
# word, and "reverted in #N" names the reverter (a re-apply PR says it). A revert pushed
# without a PR is not seen.
so_pr_index() {
  # Each revert is parsed once into what it names, so matching a PR is comparisons only:
  # regexes per (PR, revert) pair took 85 s over 561 PRs.
  jq -c --argjson days "$1" '
    def revert_re: "(?i)\\brevert(s|ed|ing)?(?![-\\w])(?!\\s+(in|by)\\b)";
    [ .[] | select(.state == "MERGED")
      | ((.title // "") + "\n" + (.body // "")) as $t
      | select($t | test(revert_re))
      | { number, at: (.mergedAt | fromdateiso8601),
          title: ((.title // "") | capture("^Revert \"(?<t>.*)\"$").t // null),
          refs: [ $t | split("\n")[] | capture(revert_re + "(?<rest>.*)").rest
                  | scan("#([0-9]+)\\b")[0] | tonumber ],
          shas: [ $t | scan("(?i)this reverts commit ([0-9a-f]{7,40})")[0] ] } ] as $rev
    | map(. as $p
        | { key: ($p.number | tostring),
            value: { state: $p.state, merged_at: $p.mergedAt,
                     reverted: ( $p.state == "MERGED" and $p.mergedAt != null
                       and (($p.mergedAt | fromdateiso8601) as $at
                            | ($p.mergeCommit.oid // "") as $oid
                            | any($rev[];
                                .number != $p.number
                                and (.at - $at) >= 0 and (.at - $at) <= $days * 86400
                                and (.title == $p.title
                                     or (.refs | index($p.number)) != null
                                     or ($oid != "" and any(.shas[]; . as $s | $oid | startswith($s))))))) } })
    | from_entries'
}

# so_latest OUT_DIR - the newest observation of every session, one JSON line each.
# Prints nothing (and succeeds) when no outcome has been written yet.
so_latest() {
  local out="$1"
  compgen -G "$out/*/*.jsonl" >/dev/null || return 0
  cat "$out"/*/*.jsonl | jq -cn '
    [inputs] | group_by(.session_id)
    | map(max_by([.observed, .updated])) | .[]'
}

# so_friction_def - the ONE ranking every reader uses: a sort key for "look at this
# session first", not a grade (an idle session scores 0 like a perfect one). A revert
# undoes shipped work (5); a PR closed unmerged or a written-down correction is redirected
# work (2); an interrupt, rejected tool call, API error, shepherd nudge or CI red before a
# merge is friction (1): pipeline-eval found nudges and reds are rework worth scoring.
# tool_errors stay out: failed commands are how work gets done. Minutes, cost and
# escalations stay on the card and out of the sum: they measure size, not friction.
# friction_terms is the one list of [weight, count, words]: friction sums it and why
# reads it out (`worst`, `card`), so the words always add up to the number.
so_friction_def() {
  cat <<'EOF'
def friction_terms:
  [ [5, (.reverted_7d // 0), "reverted"],
    [2, (.prs_closed_unmerged // 0), "closed unmerged"],
    [2, (.corrections.lessons_written // 0), "lessons written"],
    [1, (.corrections.interrupts // 0), "interrupts"],
    [1, (.hard_errors.denied // 0), "denied"],
    [1, (.hard_errors.api_error // 0), "API errors"],
    [1, (.delivery.nudges // 0), "nudges"],
    [1, (.delivery.merged.ci_reds // 0), "CI reds before merge"] ];
def friction: friction_terms | map(.[0] * .[1]) | add;
def why:
  friction_terms | map(select(.[1] > 0) | (if .[0] > 1 then "\(.[0]) x " else "" end) + "\(.[1]) \(.[2])")
  | join(" + ");
EOF
}

# so_langfuse_events - stdin: outcome rows (so_latest lines). stdout: one Langfuse
# `score-create` ingestion event per (session, measure), keyed on sessionId, which is the
# same Claude session id the Alloy -> Langfuse traces carry. The score id has no
# timestamp, so a re-observed session overwrites its scores in place; the event id does,
# because Langfuse dedupes events by it. A measure the row has as null (a runner's
# corrections) is left out rather than sent as 0. These scores are a VIEW of the outcome
# rows, which stay canonical: they exist so Langfuse can filter traces by them.
so_langfuse_events() {
  jq -c "$(so_friction_def)"'
    . as $r
    | [ ["friction", friction],
        ["prs_merged", .prs_merged],
        ["prs_closed_unmerged", .prs_closed_unmerged],
        ["reverted_7d", .reverted_7d],
        ["interrupts", .corrections.interrupts],
        ["lessons_written", .corrections.lessons_written],
        ["denied", .hard_errors.denied],
        ["api_error", .hard_errors.api_error],
        ["tool_errors", .hard_errors.tool_errors],
        ["compactions", (.activity.compactions | values | .auto + .manual)],
        ["nudges", .delivery.nudges],
        ["ci_reds", .delivery.merged.ci_reds],
        ["lines_added", .delivery.merged.lines_added] ][]
    | select(.[1] != null)
    | { id: "so:\($r.session_id):\(.[0]):\($r.observed)",
        type: "score-create",
        timestamp: $r.observed,
        body: { id: "so:\($r.session_id):\(.[0])", sessionId: $r.session_id,
                name: .[0], value: .[1], dataType: "NUMERIC",
                metadata: { project: $r.project, runner: $r.runner, agent: $r.agent, final: $r.final } } }'
}
