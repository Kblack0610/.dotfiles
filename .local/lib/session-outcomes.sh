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

# shellcheck source=origin-repo.sh
SO_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$SO_LIB/origin-repo.sh" || return 1
# shellcheck source=edit-tools.sh
. "$SO_LIB/edit-tools.sh" || return 1
# shellcheck source=claude-end.sh
. "$SO_LIB/claude-end.sh" || return 1

# SO_PR_JQ - the jq defs every harness's scan shares: the PR scan, and time_use_class (below), which counts a
# session's test runs and CI polls. pr_cmd: a command that opens or merges
# a PR, `gh pr create|merge` in command position (at a line start, after a shell separator, `sh -c`
# or `ssh host`, past assignments and wrappers like env, sudo, timeout, xargs), so a search or
# quoted pattern naming it, whose output is often test fixtures, is not one; or a curl POST to a Forgejo `.../pulls` or
# `.../pulls/N/merge` URL (often `"$API/pulls"`, API set in an earlier call; a POST to a PR's
# comments or reviews is not one). pr_refs:
# the PRs a call's output names, as {repo, number}. A GitHub repo is `owner/repo`; a Forgejo one
# is `host/owner/repo` (gh's own HOST/OWNER/REPO form), so a GitHub mirror of the same name stays
# a different repo. Forgejo is told by its URL shape, `/pulls/N` on a host that is not github.com:
# its hostnames are not named here, since this repo is public. A Forgejo merge prints no URL, so
# its PR is found from the create call's `html_url`.
# An assignment's value is an atomic group (a run of $(...), quoted strings and other non-space
# characters, a stray quote included), so it matches one way and is never re-split: as alternatives
# that `\S*` also matched, each quoted value doubled the paths and 20 of them before a `gh pr` hit
# jq's retry-limit-in-match (ar-920). The 60-assignment case in session_outcomes.bats is the guard.
SO_PR_JQ='
  def pr_cmd: test("(^|[\\n;&|({`!]|\\b(ba|z)?sh\\s+-[a-z]*c\\s+[\"\u0027]?|\\bssh\\s+(-\\S+\\s+)*\\S+\\s+[\"\u0027]?)\\s*((\\w+=(?>(\\$\\([^)]*\\)|\"[^\"]*\"|\u0027[^\u0027]*\u0027|\\S)*)|env|command|exec|time|then|do|else|sudo|nohup|timeout\\s+\\S+|xargs(\\s+-\\S+)*)\\s+)*gh\\s+pr\\s+(create|merge)\\b")
    or (test("\\bcurl\\b") and test("/pulls(/[0-9]+/merge)?([\"\u0027?\\s]|$)")
        and test("(-X\\s*|--request[=\\s]+)POST\\b|\\s(-d|--data[a-z-]*)([=\\s@\u0027\"]|$)"));
  def pr_refs: [ (scan("https://github\\.com/([^/\\s]+)/([^/\\s]+)/pull/([0-9]+)")
                  | {repo: "\(.[0])/\(.[1])", number: (.[2] | tonumber)}),
                 (scan("[Mm]erged pull request ([^/\\s]+)/([^#\\s]+)#([0-9]+)")
                  | {repo: "\(.[0])/\(.[1])", number: (.[2] | tonumber)}),
                 (scan("https?://([^/\\s\"]+)/([^/\\s\"]+)/([^/\\s\"]+)/pulls/([0-9]+)") | select(.[0] != "github.com")
                  | {repo: "\(.[0])/\(.[1])/\(.[2])", number: (.[3] | tonumber)}) ] | unique;
'

# time_use_class: which command is a test run (`test`), a CI poll (`gate`: every gate line, so agent-land
# and `gh pr view` count too) or a build, by the gate, test and build lines of time-use.conf
# (TIME_USE_CONF to read another), read when this file is sourced; a conf that yields no line is said on
# stderr and makes every command `jobs`. A line counts where
# its text runs as a command, the match agent-core's time_use.rs `runs` makes: time_use_unquoted
# drops heredoc bodies, puts each `sh -c` text on lines of its own and empties every other quoted
# string, then each line's `re` wants a command start (a line start, ; & | ( or a backtick), past
# assignments, wrappers with their options, `timeout N`, `flock FILE` and if/while/until/do/then/else/!, any path,
# the text and a boundary. agent-usage-burn.py matches the same way;
# tests/fixtures/time-use-commands.tsv holds the three readers to it.
SO_TIME_USE_LINES="$(jq -Rsc '[splits("\n") | gsub("^\\s+|\\s+$"; "") | capture("^(?<kind>gate|test|build)\\s+(?<text>.*)$")
  | .re = "(^|[;&|(\\n`])\\s*((\\w+=\\S*|(env|nice|xargs|sudo|nohup|exec|command|time|stdbuf|setsid|ionice|sh|bash|zsh)(\\s+-n\\s+[0-9]+|\\s+-\\S+)*|timeout(\\s+-\\S+)*\\s+[0-9]\\S*|flock(\\s+-\\S+)*\\s+\\S+|if|while|until|do|then|else|!)\\s+)*(\\S*/)?"
      + (.text | gsub("(?<c>[\\\\.^$|?*+()\\[\\]{}])"; "\\\(.c)")) + "($|[^\\w.])"]' \
  "${TIME_USE_CONF:-$SO_LIB/../../.config/agent-panel/time-use.conf}" 2>/dev/null)" || SO_TIME_USE_LINES='[]'
[ "$SO_TIME_USE_LINES" != '[]' ] ||
  echo "session-outcomes: no gate or test line in ${TIME_USE_CONF:-time-use.conf}; every command counts as jobs" >&2
# edit_tools: the tools that write a file (edit-tools.conf), for the since-edit and lesson counts.
SO_PR_JQ="$SO_PR_JQ
  def time_use_lines: ${SO_TIME_USE_LINES:-[]};
  def edit_tools: $(edit_tools_json || echo '[]');"'
  def time_use_unquoted:
    gsub("(?<!<)<<(?!<)-?[ \\t]*(?<q>[\u0027\"]?)(?<w>[A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])\\k<q>(?<rest>[^\\n]*)(?:\\n[^\\n]*)*?\\n[ \\t]*\\k<w>[ \\t]*(?![^\\n])"; "\(.rest)")
    | gsub("(?:^|(?<=[\\s;&|(`/]))(?<sh>(?:ba|z)?sh(?:\\s+-\\S+)*?\\s+-[a-z]*c\\s+)(?:\u0027(?<sq>[^\u0027]*)\u0027|\"(?<dq>(?:\\\\.|[^\"\\\\])*)\")"; "\(.sh)\n\(.sq // .dq)\n")
    | gsub("\u0027[^\u0027]*\u0027|\"(?:\\\\.|[^\"\\\\])*\""; "\u0027\u0027");
  def time_use_class:
    . as $c
    | [time_use_lines[] | select(.text as $t | $c | contains($t))]
    | if length == 0 then "jobs"
      else ($c | time_use_unquoted) as $u
        | first(.[] | select(.re as $re | $u | test($re)) | .kind) // "jobs" end;
'

# so_canon_init MAP - the store host and the alias list, read once per run (so_canon_claims reads them
# from SO_CANON_STORE and SO_CANON_ALIASES, or from MAP when unset). An unreadable MAP is rc 1; no MAP file
# is no store host, so nothing is rewritten.
so_canon_init() {
  SO_CANON_STORE=""
  [ ! -e "$1" ] || SO_CANON_STORE="$(jq -r '.forges.forgejo // ""' "$1")" || return 1
  SO_CANON_ALIASES="$(printf '%s\n' "$(so_forgejo_hosts)" | jq -Rc 'ascii_downcase | [splits("\\s+")] | map(select(. != ""))')" || return 1
  export SO_CANON_STORE SO_CANON_ALIASES
}
# so_canon_claims MAP - stdin: JSON values with a `prs` list of {repo, number} (a transcript's metrics, a
# registry row). stdout: the same with a Forgejo claim's host rewritten to the PR store's. A Forgejo repo
# is keyed `host/owner/repo` and the store holds it under MAP's `forges.forgejo` host (schedules-sync
# repos), but a transcript prints the host that serves html_url, the public ROOT_URL, so every host
# so_forgejo_hosts lists is an alias of the store's. A host that list lacks is kept, and its claim is
# dropped by the caller's store read. One alias source: SO_FORGEJO_HOSTS, the list that also gates where
# the token goes.
so_canon_claims() {
  [ -n "${SO_CANON_ALIASES+set}" ] || so_canon_init "$1" || return 1
  jq -c --arg store "$SO_CANON_STORE" --argjson al "$SO_CANON_ALIASES" '
    def canon: if $store != "" and type == "string" and test("^[^/]+/[^/]+/[^/]+$") and (split("/")[0] | ascii_downcase | IN($al[]))
               then ([$store] + split("/")[1:]) | join("/") else . end;
    if type == "object" and (.prs | type) == "array" then .prs |= map(.repo |= canon) else . end'
}

# so_store_key MAP KEY - one PR-store key (host/owner/repo, or owner/repo) with a Forgejo alias host
# mapped to the store's, through so_canon_claims' one alias rule. A key it cannot map is printed as given.
so_store_key() {
  local out
  out=$(jq -nc --arg k "$2" '{prs: [{repo: $k}]}' | so_canon_claims "$1" 2>/dev/null | jq -r '.prs[0].repo // empty' 2>/dev/null) &&
    [ -n "$out" ] || out=$2
  printf '%s\n' "$out"
}

# so_mapped_repos MAP - the PR-store keys of the repos the project map lists, one per line, lower-cased:
# a tracker's Forgejo slug on the `forges.forgejo` host, else its GitHub slug. A tracker with both is
# Forgejo-canonical, so its GitHub slug is the mirror and is not expected in the store. A claim in a
# repo named here that the store does not hold is a gap in the store's list, not a stray URL.
so_mapped_repos() {
  jq -r '(.forges.forgejo // "") as $h | (.trackers // {})[] | select(type == "object")
         | if .forgejo then (if $h != "" then "\($h)/\(.forgejo)" else empty end) else (.github // empty) end
         | ascii_downcase' "$1"
}

# so_transcript_metrics FILE - one pass over a transcript, one JSON object out.
# A PR counts when a PR call's own result printed it (SO_PR_JQ), so a PR merely
# viewed or pasted is not claimed, or when Claude Code wrote a pr-link record for it: that
# record is how a PR made in a subagent, or whose output was persisted to a file, reaches
# this transcript, since neither prints its URL in a tool result here. Claude Code also writes
# a pr-link for a PR URL it only saw printed (a test's fixture o/r#99, session 5642f5f8), so `run`
# drops a claim in a repo gh cannot resolve. (`run` also claims a PR whose body names the
# session's own claude.ai/code link: so_session_links.)
# lessons_written counts corrections (the rule is "after ANY correction, update lessons");
# most land as `cat >>` through Bash, not Edit, so both are counted. Malformed lines are skipped, not fatal:
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
  jq -nR --argjson sigs "${2:-[]}" "$CLAUDE_END_JQ$SO_PR_JQ"'
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
        (if ($r | is_api_error) then .api_error += 1 else . end)
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
            | (if (edit_tools | index($u.name)) != null
                  and (($u.input.file_path // $u.input.notebook_path // "") | test("/\\.agent/|/\\.claude/(plans|projects)/") | not) then
                 .since_edit = {}
               else . end)
            | if $u.name == "Bash" then
              ($u.input.command // "") as $c
              | ($c | time_use_class) as $k
              | .test_runs += (if $k == "test" then 1 else 0 end)
              | .ci_polls += (if $k == "gate" then 1 else 0 end)
              | (if ($c | test("\\bgit\\s+commit\\b")) then .since_edit = {} else . end)
              | (if ($c | pr_cmd) then .pr_ids[$u.id] = true else . end)
              | (if ($c | test("(>>|tee\\s+-a)\\s*\\S*\\.agent/lessons/")) then .lesson_ids[$u.id] = true else . end)
              | reduce ($sigs[] | select((($r.timestamp // "") | .[0:10]) > .since)
                        | select(.sig as $re | try ($c | test($re)) catch false)) as $s (.;
                  .lesson_hits[$s.sig] += 1)
              | (if ($c | test("\\bnotes\\s+ptask\\b.*\\sdone\\b")) then
                   (if ($c | test("--unverified")) then .done_ids[$u.id] = "unverified"
                    elif ($c | test("--proof")) then .done_ids[$u.id] = "proof"
                    else . end)
                 else . end)
            elif (edit_tools | index($u.name)) != null
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
                   .prs += ($t | pr_refs)
                 else . end)
              | (if ($err | not) and .lesson_ids[$c.tool_use_id] then .lessons_written += 1 else . end)
              | (if ($err | not) and .done_ids[$c.tool_use_id] then
                   (if .done_ids[$c.tool_use_id] == "proof" then .proof += 1 else .unverified += 1 end)
                 else . end)
            elif $c.type == "text" and (($c.text // "") | startswith("[Request interrupted by user")) then
              .interrupts += 1
            else . end)
        end
      elif $r.type == "pr-link" and ($r.prNumber | type) == "number" and (($r.prRepository // "") | test("^[^/\\s]+/[^/\\s]+$")) then
        .prs += [{repo: $r.prRepository, number: $r.prNumber}]
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

# so_project_of DIR -> the project an opencode or Codex session in DIR files under: the resolver's
# name when the registry knows it (project_known), else the reserved `_unscoped`. The resolver names
# an unregistered repo by its checkout, a key project-map-doctor FAILs, and these readers re-read
# every session on disk each run, so a stray key moved to ~/.agent/_archive/ came back the next
# night (qmk_firmware, bnb-agents). With no registry to read
# (project_known rc 2, or a resolver lib without it) the resolver's name stands.
so_project_of() {
  local p rc=0
  p="$(resolve_project_name "$1")"
  case "$p" in _*) ;; *) project_known "$p" 2>/dev/null || rc=$?; [ "$rc" -ne 1 ] || p=_unscoped ;; esac
  printf '%s\n' "$p"
}

# so_dir_projects - stdin: a session directory a line; stdout: one {dir: project} object
# (so_project_of on each distinct dir), the map every harness's row reader files its rows by.
so_dir_projects() {
  # shellcheck source=/dev/null
  . "${SO_PROJECT_LIB:-$HOME/.config/shared-hooks/project-name.sh}" || return 1
  sort -u | while IFS= read -r dir; do
    jq -cn --arg d "$dir" --arg p "$(so_project_of "$dir")" '{key: $d, value: $p}'
  done | jq -cs from_entries
}

# so_opencode_rows DB WORK - one registry-shaped line per root opencode session, read-only: opencode
# has no Stop hook, and its own DB already holds cost and tokens. `session_v2` is the live table;
# `session` and `part` stopped being written at 2.1.4. Times are milliseconds. A child session (a
# subagent) adds to its root and gets no line. PRs follow the rule at the top of this file: a
# PR call's own output printed it (SO_PR_JQ). `provider` is the session model's providerID: `litellm`
# and `go` reach the gateway (GATEWAY_PROVIDERS in agent-usage-burn.py; a new one goes there too), and
# `lazer` went to Lazer direct, which the gateway's lazer-pool never sees. No DB is no rows; a schema
# it cannot read is rc 1.
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
    WHERE m.type = 'assistant' AND (m.data LIKE '%gh pr %' OR (m.data LIKE '%/api/v1/repos/%' AND m.data LIKE '%/pulls%'))" > "$work/oc.messages.json" || return 1
  jq -r '(. // [])[].directory' "$work/oc.sessions.json" | so_dir_projects > "$work/oc.projects.json" || return 1
  jq -cn --slurpfile s "$work/oc.sessions.json" --slurpfile m "$work/oc.messages.json" --slurpfile p "$work/oc.projects.json" "$SO_PR_JQ"'
    (($m[0] // []) | group_by(.root)
     | map({key: .[0].root,
            value: [ .[].data | fromjson | .content[]?
                     | select(.type == "tool" and .name == "bash" and .state.status == "completed"
                              and (.state.input.command // "" | pr_cmd))
                     | [.state.content[]?.text] | join("\n") | pr_refs[] ] | unique})
     | from_entries) as $prs
    | ($s[0] // [])[]
    | ((.model // "{}") | fromjson) as $model
    | { session_id, harness: "opencode", project: $p[0][.directory], title,
        updated: (.updated_ms / 1000 | floor), duration_s: ((.updated_ms - .created_ms) / 1000 | floor),
        edits: .edits, cost_usd, models: [$model.id // empty],
        provider: $model.providerID,
        tokens: {input, output, cacheCreation: .cache_write, cacheRead: .cache_read,
                 total: (.input + .output + .reasoning + .cache_read + .cache_write)},
        prs: ($prs[.session_id] // []) }'
}

# so_codex_rows DIR WORK - one registry-shaped line per root Codex session, read-only from its rollout
# files (DIR/YYYY/MM/DD/rollout-*.jsonl): Codex has no Stop hook either. Tokens are the last
# token_count total; OpenAI's input counts the cached part, so input here is what was not cached,
# as claude's rows read. A subagent's rollout (session_meta source.subagent) adds to its parent and
# gets no line. A ChatGPT plan bills no dollars, so cost_usd is an estimate: tokens times the
# model's price in PRICES (a harnesses.json file, `.harnesses.codex.prices`, USD per million tokens
# as {model: {input, cached_input, output}}). A rollout is priced only when it ran one model with a
# price with all three rates and no cache writes (OpenAI bills none), since the token total is not
# split by model; a session with any unpriced rollout, or no
# price file, has cost_usd null, never a partial figure. PRs follow the rule at the top of this
# file, from a PR call (SO_PR_JQ) paired with its own output. The per-rollout read is codex-session.jq,
# which also gives the Claude row's metrics (hard errors, tool and test counts); a subagent's add to its parent's.
so_codex_rows() {
  local dir="$1" work="$2" prices="${3:-}" f pj='{}'
  [ -d "$dir" ] || return 0
  if [ -r "$prices" ]; then
    pj="$(jq -c '.harnesses.codex.prices // {}' "$prices" 2>/dev/null)" || { echo "so_codex_rows: unreadable $prices, no Codex cost" >&2; pj='{}'; }
  fi
  local prog
  prog="$(cat "$SO_LIB/codex-session.jq")" && [ -n "$prog" ] || { echo "so_codex_rows: $SO_LIB/codex-session.jq missing or empty" >&2; return 1; }
  find "$dir" -name 'rollout-*.jsonl' -type f | while IFS= read -r f; do
    jq -cs --argjson prices "$pj" --arg file "$f" "$SO_PR_JQ$prog" "$f" || echo "so_codex_rows: unreadable $f" >&2
  done > "$work/cx.rows.jsonl"
  jq -r '.cwd // empty' "$work/cx.rows.jsonl" | so_dir_projects > "$work/cx.projects.json" || return 1
  jq -cs --slurpfile p "$work/cx.projects.json" '
    def add_tok(a; b): if a == null then b elif b == null then a else
      reduce (b | keys[]) as $k (a; .[$k] = ((.[$k] // 0) + b[$k])) end;
    def nadd(a; b): if a == null and b == null then null else (a // 0) + (b // 0) end;
    def sum_into($c): .metrics.hard_errors.api_error = nadd(.metrics.hard_errors.api_error; $c.metrics.hard_errors.api_error)
      | .metrics.hard_errors.tool_errors = nadd(.metrics.hard_errors.tool_errors; $c.metrics.hard_errors.tool_errors)
      | reduce ("tool_calls", "test_runs", "test_failures", "ci_polls", "api_messages", "tokens") as $k (.;
          .metrics.activity[$k] = nadd(.metrics.activity[$k]; $c.metrics.activity[$k]));
    (map(select(.parent == null) | {key: .session_id, value: .}) | from_entries) as $roots
    | reduce (.[] | select(.parent != null and $roots[.parent] != null)) as $c ($roots;
        .[$c.parent] |= (.edits = nadd(.edits; $c.edits) | .tokens = add_tok(.tokens; $c.tokens)
                         | .cost_by_model = add_tok(.cost_by_model; $c.cost_by_model) | .unpriced = (.unpriced or $c.unpriced)
                         | .models = (.models + $c.models | unique) | .prs = (.prs + $c.prs | unique)
                         | sum_into($c)
                         | .updated = ([.updated, $c.updated] | max)))
    | .[] | .project = $p[0][.cwd]
    | if .unpriced then .cost_by_model = null else . end
    | .cost_usd = (if .cost_by_model == null then null else (.cost_by_model | add * 1000000 | round / 1000000) end)
    | .cost_src = (if .cost_usd == null then null else "price" end)
    | del(.cwd, .parent, .unpriced)' "$work/cx.rows.jsonl"
}

# so_agy_rows DIR WORK - one registry-shaped line per agy run, read-only from the log agent-agy kept
# (DIR/agy_<n>.jsonl, named by the run id fleet-dispatch's item claims): agy has no Stop hook. Tokens
# are the result's usage; agy counts the cached part inside input, so input here is what was not
# cached, as the codex rows read. agy reports no cost and AI Pro publishes no token price, so
# cost_usd is null. effort is the model id's suffix (agy's ids are per effort). Commands are its
# run_command steps, tests among them by time_use_class; edits count its file-writing tool steps. A
# failed command is a DONE step whose output says `Command exited with code N` (N != 0), a tool the
# stream ends in state ERROR is a tool error too, and an agent_response in ERROR is an API error, as the
# codex rows count them; a command with no code (a background one) is neither. 86 real streams
# (2026-11-25) carry no cost, price or credit key.
# A sandboxed run reaches no forge, so prs is empty: its PR comes from the tail and the item.
so_agy_rows() {
  local dir="$1" work="$2" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/agy_*.jsonl; do
    [ -f "$f" ] || continue
    jq -cnR --arg id "$(basename "$f" .jsonl)" --argjson mtime "$(stat -c %Y "$f")" "$SO_PR_JQ"'
      [inputs | fromjson? | objects] as $ev
      | ($ev | map(select(.event == "init")) | first) as $i
      | select($i != null)
      | ($ev | map(select(.event == "result")) | last | .result) as $r
      | ($ev | map(select(.event == "start")) | first | .at) as $t0
      | ($ev | map(select(.event == "exit")) | last | .at) as $t1
      | [$ev[] | .step_update // empty | select(.state == "DONE")] as $steps
      | [$steps[] | select(.step_type == "tool")] as $tools
      | [$ev[] | .step_update // empty | select(.state == "ERROR" and .step_type == "tool")] as $badtools
      | [$ev[] | .step_update // empty | select(.state == "ERROR" and .step_type == "agent_response")] as $badturns
      | [$tools[] | select(.tool_name == "run_command")
         | {cmd: (.tool_info.parameters.CommandLine // ""),
            exit: ((.tool_info.output | strings // "") | first((capture("Command exited with code (?<c>-?[0-9]+)").c | tonumber), null))}
         | .class = (.cmd | time_use_class)] as $cmds
      | $r.usage as $u
      | {session_id: $id, harness: "agy", cwd: $i.init.cwd, title: "",
         updated: ($t1 // $mtime), duration_s: (if $t0 != null and $t1 != null then $t1 - $t0 else ($r.duration_seconds // 0 | floor) end),
         edits: ([$tools[] | select(.tool_name | IN("write_file", "edit_file", "write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file"))] | length),
         cost_usd: null, models: [$i.init.model // empty],
         effort: ($i.init.model // "" | capture("-(?<e>low|medium|high|xhigh|max)$").e // null),
         tokens: (if $u == null then null else
                    {input: (if $u.input_tokens then $u.input_tokens - ($u.cache_read_tokens // 0) else null end), output: (($u.output_tokens // 0) + ($u.thinking_tokens // 0)),
                     cacheCreation: 0, cacheRead: ($u.cache_read_tokens // 0), total: $u.total_tokens} end),
         metrics: {prs: [], hard_errors: {api_error: ($badturns | length), denied: null,
                                          tool_errors: (([$cmds[] | select(.exit != null and .exit != 0)] | length) + ($badtools | length))},
                   activity: {tool_calls: (($tools | length) + ($badtools | length)), test_runs: ([$cmds[] | select(.class == "test")] | length),
                              test_failures: ([$cmds[] | select(.class == "test" and .exit != null and .exit != 0)] | length), ci_polls: ([$cmds[] | select(.class == "gate")] | length),
                              api_messages: ([$steps[] | select(.step_type == "agent_response")] | length),
                              tokens: $u.total_tokens, tokens_after_last_edit: null, compactions: null},
                   time_use: {work_min: null, gate_min: null, test_min: null, jobs_min: null, human_min: null, parked_min: null}},
         prs: []}' "$f" || echo "so_agy_rows: unreadable $f" >&2
  done > "$work/agy.rows.jsonl"
  jq -r '.cwd // empty' "$work/agy.rows.jsonl" | so_dir_projects > "$work/agy.projects.json" || return 1
  jq -c --slurpfile p "$work/agy.projects.json" '.project = $p[0][.cwd // ""] | del(.cwd)' "$work/agy.rows.jsonl"
}

# so_lesson_sigs [DIR] - the lessons that carry a sig, as one JSON array of {sig, since, claim,
# file}. A lesson opts in by ending with `<!-- sig:YYYY-MM-DD <regex> -->`: the regex (jq) matches
# the mistake as a Bash command, anchored so a grep for its words does not count, and the date is
# when the lesson was written. so_transcript_metrics counts a hit only on a later day, so the
# session that wrote it is not its first recurrence. The same sig in several files is one lesson,
# dated by its first writing; a lesson's claim is its first bold span, without `#` (a tag on a row).
so_lesson_sigs() {
  local dir="${1:-${SO_LESSONS_DIR:-$HOME/.agent/lessons}}"
  { grep -H -- '<!-- sig:' "$dir"/*.md 2>/dev/null || true; } | jq -nR "$SO_CLAIM_JQ"'
    [inputs | capture("^(?<file>[^:]+):(?<line>.*)<!-- sig:(?<since>[0-9]{4}-[0-9]{2}-[0-9]{2}) (?<sig>.+?) -->")
     | {sig, since, file: (.file | split("/")[-1]), claim: (.line | claim)}]
    | group_by(.sig) | map(min_by(.since))'
}

# SO_CLAIM_JQ - jq `claim`: a lesson's line to its first bold span, after the bullet and a leading
# date, without `#` (a tag on a row), at most 120 chars.
SO_CLAIM_JQ='def claim: sub("^\\s*-\\s*"; "") | sub("^\\*\\*[0-9-]+\\*\\*:?\\s*"; "") | sub("^[0-9]{4}-[0-9]{2}-[0-9]{2}:?\\s*"; "")
  | ((capture("^\\*\\*(?<c>.+?)\\*\\*") | .c) // .) | gsub("#"; "") | .[0:120];'

# so_lesson_seen [DIR] - the lessons the dream sweep found again, as one JSON array of {title, seen,
# last, claim, file}. Dream marks a corroborated lesson `<!-- seen:N YYYY-MM-DD -->` and never edits
# its first line, the lesson key. Which lesson a marker is in, and its title, come from the lessons
# CLI's parser (`lessons fat --max 0` lists every lesson), never a second parse here; the highest N
# in a lesson wins (the later one on a tie). The title drops inline markers, so a marker edit never
# changes it; one entry per file and title. Fails when that listing does.
so_lesson_seen() {
  local dir="${1:-${SO_LESSONS_DIR:-$HOME/.agent/lessons}}" f starts rows
  rows=$(for f in "$dir"/*.md; do
    [ -f "$f" ] && grep -q -- '<!-- seen:' "$f" || continue
    starts=$("${SO_LESSONS_CMD:-$SO_LIB/../bin/lessons}" fat --max 0 "$f") || return 1
    [ -n "$starts" ] || continue
    LC_ALL=C awk -F'\t' -v file="${f##*/}" '
      function at(s) { sub(/.*:/, "", s); return s + 0 }
      FILENAME == "-" { st[++ns] = at($1); t = $3; gsub(/ *<!--[^>]*-->/, "", t); title[at($1)] = t; next }
      match($0, /<!-- seen:[0-9]+ [0-9-]+ -->/) {
        for (i = ns; i > 0 && st[i] > FNR; i--);
        if (!i) next
        split(substr($0, RSTART + 10, RLENGTH - 14), m, " ")
        s = st[i]
        if (m[1] + 0 >= n[s] + 0) { n[s] = m[1]; d[s] = m[2] }
      }
      END { for (s in n) printf "%s\t%s\t%s\t%s\n", file, n[s], d[s], title[s] }' - "$f" <<<"$starts"
  done) || return 1
  jq -nR "$SO_CLAIM_JQ"'[inputs | select(. != "") | split("\t")
    | {title: .[3], seen: (.[1] | tonumber), last: .[2], claim: (.[3] | claim), file: .[0]}]
    | group_by([.file, .title]) | map(max_by([.seen, .last]))' <<<"$rows"
}

# SO_FORGEJO_ERR says why a Forgejo read failed: rc 1 = no token or the read failed (worth a retry),
# rc 2 = the host is not listed (never called). Seams: SO_CURL SO_RBW.
SO_FORGEJO_PAGE=50   # Forgejo's MAX_RESPONSE_ITEMS caps every list page at 50, whatever limit asks for
SO_FORGEJO_TOKEN=""
# so_forgejo_pr HOST/OWNER/REPO NUMBER - one PR in the `gh pr view --json
# state,headRefName,headRefOid,body,createdAt,mergedAt,additions,deletions,mergeCommit` shape. headRefName is `#N`, the
# branch the run ledger files a Forgejo PR's runs under (schedules-sync forgejo_rows); the API's
# head.ref reads refs/pull/N/head once the branch is deleted. Why it failed goes to stderr.
so_forgejo_pr() {
  local repo="$1" n="$2" pr
  so_forgejo_auth "$repo" || { printf '%s\n' "$SO_FORGEJO_ERR" >&2; return 1; }
  pr="$(so_forgejo_get "$repo" "pulls/$n")" || return 1
  jq -c '{state: (if .merged then "MERGED" elif .state == "open" then "OPEN" else "CLOSED" end),
          headRefName: "#\(.number)", headRefOid: .head.sha, body, createdAt: .created_at, mergedAt: .merged_at,
          additions, deletions, mergeCommit: (if .merge_commit_sha then {oid: .merge_commit_sha} else null end)}' <<<"$pr"
}

# so_forgejo_checks HOST/OWNER/REPO SHA - the commit's statuses as gh's statusCheckRollup, [{state, context}],
# so pr-ci.sh CI_JQ reads them unchanged: a Forgejo status is pending, success, warning, error or
# failure, and warning is a pass (Forgejo's own combined state does not fail on it). After so_forgejo_auth.
so_forgejo_checks() {
  local st
  st="$(so_forgejo_get "$1" "commits/$2/status")" || return 1
  jq -c '[.statuses // [] | .[] | {state: (.status | ascii_upcase | if . == "WARNING" then "SUCCESS" else . end), context}]' <<<"$st"
}

# so_pr_view <owner/repo#N or N> <checkout> <fields> <jq> -> <jq> over the PR's <fields>, as `gh pr view -q`
# prints it; fails when its forge cannot be read. The one forge rule for reading a recorded PR
# (fleet-dispatch item_pr_state, agent-queue pr_state). A checkout whose canonical forge is Forgejo
# (forge_canonical; home-config) is read from that forge's API in gh's shape (so_forgejo_pr,
# so_forgejo_checks): gh sees only its GitHub mirror, which has no PRs, so fix-traefik's reap logged
# "could not read" on every pass for two days (270 lines, 2026-11-08 to 11-10), and agent-queue's pr:
# holds spent 5,241 failed REST calls on 2026-11-14. There <fields> is fixed: <jq> sees only what
# so_forgejo_pr gives, plus statusCheckRollup when <fields> names it (else the status read is skipped).
# The PR is the number on the checkout's own Forgejo remote: the ref names the GitHub mirror, whose
# owner may differ. Else gh reads the repo the ref names, or a bare number from the checkout.
so_pr_view() {
  local n=${1##*#} repo pr ci
  if forge_canonical "$2"; then
    # Authed in this shell, so the token is read once and both reads below carry it (each $(...) is a subshell).
    repo=$(so_forgejo_repo "$2") && so_forgejo_auth "$repo" && pr=$(so_forgejo_pr "$repo" "$n" 2>/dev/null) || return 1
    [[ ",$3," == *,statusCheckRollup,* ]] || { jq -r "$4" <<<"$pr"; return; }
    ci=$(so_forgejo_checks "$repo" "$(jq -r .headRefOid <<<"$pr")" 2>/dev/null) || return 1
    jq -r --argjson ci "$ci" ".statusCheckRollup = \$ci | $4" <<<"$pr"
  elif [[ "$1" == */*#* ]]; then gh pr view "$n" -R "${1%#*}" --json "$3" -q "$4" 2>/dev/null
  else [ -n "$2" ] && (cd "$2" && gh pr view "$n" --json "$3" -q "$4" 2>/dev/null)
  fi
}

# so_pr_dir <pr ref> [project] -> the checkout a recorded PR's repo lives in, for so_pr_view: the repo
# an <owner>/<repo>#<N> ref names, through the project map (one project spans repos: agent-runtime
# lands in .dotfiles, .dotfiles-private and home-config), else, for a bare number, the project's own.
# Needs project-name.sh, which each caller sources.
so_pr_dir() {
  [[ "$1" =~ ^[^/]+/([^/#]+)#[0-9]+$ ]] || { [ -z "$2" ] || project_repo_path "$2"; return; }
  project_repo_path "$(project_of_repos_json "${BASH_REMATCH[1]}" | jq -r '.[]')"
}

# so_forgejo_remote CHECKOUT [REMOTE...] - "<remote> HOST/OWNER/REPO" of the first REMOTE (default:
# each of the checkout's remotes) whose URL is on a host so_forgejo_hosts lists; rc 1 when none is.
so_forgejo_remote() {
  local dir="$1" name url host hosts
  shift
  hosts=" $(so_forgejo_hosts) "
  [ -n "${hosts// /}" ] || return 1
  # shellcheck disable=SC2046 # one remote name a word
  [ $# -gt 0 ] || set -- $(git -C "$dir" remote 2>/dev/null)
  for name; do
    url="$(git -C "$dir" remote get-url "$name" 2>/dev/null)" || continue
    host="$(url_host "$url")"
    [ -n "$host" ] && [[ "$hosts" == *" $host "* ]] || continue
    printf '%s %s/%s\n' "$name" "$host" "$(url_repo "$url")"
    return 0
  done
  return 1
}

# so_forge_remote CHECKOUT - the forge CHECKOUT lands on, the one rule agent-land and `project-map
# forges` share: "<remote> HOST/OWNER/REPO" when it is Forgejo (its checkout commits the mirror
# marker, forge_canonical, or its origin is on a host so_forgejo_hosts lists). rc 1: GitHub (or any
# other origin). rc 2: Forgejo-canonical, but no remote is on a listed host.
so_forge_remote() {
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || top=''
  if forge_canonical "$top"; then
    so_forgejo_remote "$1" || return 2
  else
    so_forgejo_remote "$1" origin || return 1
  fi
}

# so_forgejo_repo CHECKOUT - HOST/OWNER/REPO of so_forgejo_remote (home-config's remote is `forgejo`,
# its origin the GitHub mirror); rc 1 when no remote is on a listed host.
so_forgejo_repo() {
  local r
  r="$(so_forgejo_remote "$1")" || return 1
  printf '%s\n' "${r#* }"
}

# so_forgejo_auth HOST/OWNER/REPO - may the token go to this repo's host, and is it read? Sets
# SO_FORGEJO_TOKEN (once per process, from forgejo-token) and, on a failure, SO_FORGEJO_ERR (rc 1 = no token or the read failed, rc 2 = the host is not listed).
so_forgejo_auth() {
  local repo="$1" entry="${SO_FORGEJO_ENTRY:-forgejo_repo_admin}"
  case " $(so_forgejo_hosts) " in
    *" ${repo%%/*} "*) ;;
    *) SO_FORGEJO_ERR="${repo%%/*} is not in SO_FORGEJO_HOSTS, $repo unread"; return 2 ;;
  esac
  if [ -z "$SO_FORGEJO_TOKEN" ]; then
    local bin="$SO_LIB/../bin/forgejo-token" why
    [ -x "$bin" ] || { SO_FORGEJO_ERR="no token: $bin is missing, $repo unread"; return 1; }
    # One call: on success forgejo-token prints only the token; on a failure only its reason, which
    # names the sources, so they are listed in one place.
    if why="$(FORGEJO_TOKEN_RBW="${SO_RBW:-rbw}" FORGEJO_TOKEN_ENTRY="$entry" "$bin" 2>&1)" && [ -n "$why" ]; then
      SO_FORGEJO_TOKEN="$why"
    else
      SO_FORGEJO_ERR="${why#forgejo-token: }, $repo unread"; return 1
    fi
  fi
}

# so_forgejo_get HOST/OWNER/REPO PATH [CURL ARG...] - one authed API call, after so_forgejo_auth; on
# an HTTP error it fails and still prints the body, which carries Forgejo's reason (.message).
# A plain-text "Forbidden" is not Forgejo's (its API errors are JSON): the proxy in front refused the
# request before Forgejo saw it, so even a write is sent again, SO_FORGEJO_GATE_TRIES in all, waits
# doubling from SO_FORGEJO_GATE_WAIT seconds. On the home cluster that proxy is the CrowdSec bouncer (home-config
# apps/crowdsec, a Traefik forwardAuth), which fails closed when its LAPI lookup times out (5 s): 239
# such 403s on 2026-11-12/13, every one a timeout, in bursts of 0 to 31 s (Loki). A refused try's curl
# line is dropped; still refused, it prints nothing and stderr names the proxy. Seams: SO_CURL SO_FORGEJO_GATE_WAIT.
SO_FORGEJO_GATE_TRIES=4
SO_FORGEJO_GATE_WAIT=${SO_FORGEJO_GATE_WAIT:-5}
so_forgejo_get() {
  local repo="$1" path="$2" out err rc try=1 wait="$SO_FORGEJO_GATE_WAIT"; shift 2
  err=$(mktemp) || return 1
  while :; do
    rc=0
    out=$(printf 'header = "Authorization: token %s"\n' "$SO_FORGEJO_TOKEN" |
      "${SO_CURL:-curl}" -sS --fail-with-body -K - --max-time 30 "$@" "https://${repo%%/*}/api/v1/repos/${repo#*/}/$path" 2>"$err") || rc=$?
    [ "$rc" -eq 22 ] && [ "$out" = Forbidden ] || { cat "$err" >&2; rm -f "$err"; printf '%s' "$out"; return "$rc"; }
    [ "$try" -lt "$SO_FORGEJO_GATE_TRIES" ] || break
    sleep "$wait"
    try=$((try + 1)) wait=$((wait * 2))
  done
  rm -f "$err"
  # agent-land's net_error matches "the proxy in front of Forgejo refused": reword both together.
  printf '%s: the proxy in front of Forgejo refused %s %d times with a plain-text 403 "Forbidden", not Forgejo'"'"'s (the CrowdSec bouncer in home-config apps/crowdsec fails closed when its LAPI is slow)\n' "${repo%%/*}" "${path%%\?*}" "$try" >&2
  return 1
}

# so_forgejo_hosts - the Forgejo hosts a lookup may send the token to, space-separated:
# SO_FORGEJO_HOSTS when set (even empty), else the private nightly-measure runner conf's. A host
# comes from transcript text, so one not listed is never called.
so_forgejo_hosts() {
  if [ -n "${SO_FORGEJO_HOSTS+set}" ]; then printf '%s' "$SO_FORGEJO_HOSTS"; return; fi
  ( . "${AGENTCTL_CONF_DIR:-$HOME/.config/agentctl/agents}/nightly-measure.conf" 2>/dev/null
    printf '%s' "${SO_FORGEJO_HOSTS:-}" ) || true
}

# so_pr_index FINAL_DAYS - stdin: the PR store's rows for ONE repo (`schedules-sync prs`). stdout:
# {"<number>": {state, merged_at, merge_oid, reverted, links}}. links are the claude.ai/code session
# ids the body names, the link Claude Code's attribution puts in every PR it opens (so_session_links
# reads the same id from the session's side); the store parses them, and what a PR reverts, once.
# reverted = a merged PR, merged within FINAL_DAYS after this one, that is titled
# `Revert "<title>"` (GitHub's button), has a title or body line where a revert word comes
# before `#N` ("Reverts #240", `Revert "x (#5)"`), or says "This reverts commit <sha>" of
# this PR's merge commit (schedules-sync revert_of). A revert pushed without a PR is not seen.
so_pr_index() {
  jq -c --argjson days "$1" '
    [ .[] | select(.state == "MERGED" and .revert != null and .merged_at != null)
      | {number, at: (.merged_at | fromdateiso8601), title: .revert.title, refs: .revert.prs, shas: .revert.shas} ] as $rev
    | map(. as $p
        | { key: ($p.number | tostring),
            value: { state: $p.state, merged_at: $p.merged_at, merge_oid: $p.merge_sha, links: ($p.links // []),
                     reverted: ( $p.state == "MERGED" and $p.merged_at != null
                       and (($p.merged_at | fromdateiso8601) as $at
                            | ($p.merge_sha // "") as $oid
                            | any($rev[];
                                .number != $p.number
                                and (.at - $at) >= 0 and (.at - $at) <= $days * 86400
                                and (.title == $p.title
                                     or (.refs | index($p.number)) != null
                                     or ($oid != "" and any(.shas[]; . as $s | $oid | startswith($s))))))) } })
    | from_entries'
}

# --- rework: a fix that rewrote a change's lines soon after it landed (the 2026-11 landscape
# review's method, after arXiv 2609.26847). A fix is a commit whose subject starts fix, revert or
# hotfix. Blame at its parent names the commit that last wrote each code line it deleted or
# changed (SO_REWORK_NONCODE_RE: docs, data and lockfiles are not code). A change a fix rewrote
# within SO_REWORK_DAYS (7) is a rework CANDIDATE; one a fix rewrote within SO_REWORK_VERIFY_DAYS (30) whose message names
# it, as its PR (#N) or its sha, is VERIFIED. A candidate is a lead, never a defect: a fix often
# rewrites lines it did not find wrong. The human samples the verified label (`rework --sample`).
# A PR merged with a merge commit is read by that commit alone, so its branch's lines are not seen.
: "${SO_REWORK_DAYS:=7}" "${SO_REWORK_VERIFY_DAYS:=30}"
SO_REWORK_FIX_RE='^(fix|revert|hotfix)([^a-z0-9_]|$)'   # on the lowercased subject
# A path blame skips: docs and data, and the lockfiles a dependency fix regenerates.
SO_REWORK_NONCODE_RE='([.](md|json|jsonl|txt|lock|lockb)|(^|/)(pnpm-lock[.]yaml|go[.]sum))$'

# so_rework_fixes DIR REF SINCE UNTIL - one JSON line per fix commit on REF committed in
# (SINCE, UNTIL] that rewrote a code line: {fix, at, msg, intros: [the commits blame names]}.
so_rework_fixes() {
  local dir="$1" ref="$2" sha at subj msg intros
  git -C "$dir" log "$ref" --no-merges --since="@$3" --until="@$4" -z --format='%H%x1f%ct%x1f%s%x1f%B' |
  while IFS=$'\x1f' read -r -d '' sha at subj msg; do
    [[ "${subj,,}" =~ $SO_REWORK_FIX_RE ]] || continue
    # Header lines are read only between `diff --git` and the first hunk: a deleted line
    # reading "-- a/x" shows as "--- a/x" in a hunk. One blame per file, with every range.
    intros=$(git -C "$dir" -c core.quotePath=false show -U0 --format= -M --no-ext-diff "$sha" 2>/dev/null |
      awk -v skip="$SO_REWORK_NONCODE_RE" '/^diff --git / { h = 1; p = ""; next }
           h && /^--- a\// { p = substr($0, 7); next }
           h && /^--- / { p = ""; next }
           /^@@ / { h = 0
                    if (p == "" || p ~ skip) next
                    split($2, a, ","); s = substr(a[1], 2); n = (2 in a) ? a[2] : 1
                    if (n > 0) r[p] = r[p] " -L " s "," (s + n - 1) }
           END { for (p in r) print p "\t" r[p] }' |
      while IFS=$'\t' read -r path ranges; do
        # shellcheck disable=SC2086  # ranges is a list of -L flags
        git -C "$dir" blame --root -s -l $ranges "$sha^" -- "$path" 2>/dev/null | awk '{ sub(/^\^/, "", $1); print $1 }'
      done | sort -u)
    [ -n "$intros" ] || continue
    jq -nc --arg fix "$sha" --argjson at "$at" --arg msg "$msg" --arg i "$intros" \
      '{fix: $fix, at: $at, msg: $msg, intros: ($i | split("\n") | map(select(length > 0 and . != $fix)))}'
  done
}

# so_rework_index DIR - stdin: so_rework_fixes lines. stdout: one object keyed by the sha of each
# change a fix rewrote within SO_REWORK_VERIFY_DAYS after it was committed (a squash merge's
# commit time is its merge time): [{fix, subject, days, named}], named when the fix's message
# names the change's PR (`#N` from its `(#N)` subject) or a prefix of its sha.
so_rework_index() {
  local dir="$1" fixes shas
  fixes=$(jq -sc .) || return 1
  shas=$(jq -r '.[].intros[]' <<<"$fixes" | sort -u)
  # An empty --stdin would log HEAD.
  [ -n "$shas" ] || { printf '{}\n'; return 0; }
  so_rework_commits "$dir" --no-walk=unsorted --stdin <<<"$shas" |
    jq -cn --slurpfile fixes <(printf '%s\n' "$fixes") --argjson vd "$SO_REWORK_VERIFY_DAYS" '
      ([inputs] | INDEX(.sha)) as $c
      | [ $fixes[0][] | . as $f | .intros[] | ($c[.] // empty)
          | select(.at < $f.at and ($f.at - .at) <= $vd * 86400)
          | (.s | capture("\\(#(?<n>[0-9]+)\\)$").n // null) as $pr
          | .sha as $sha
          | { intro: $sha, fix: $f.fix, subject: ($f.msg | split("\n")[0]),
              days: ((($f.at - .at) / 8640 | ceil) / 10),
              named: (($pr != null and ($f.msg | test("#" + $pr + "(?![0-9])")))
                      or any($f.msg | scan("\\b[0-9a-f]{7,40}\\b"); . as $p | $sha | startswith($p))) } ]
      | group_by(.intro) | map({key: .[0].intro, value: map(del(.intro))}) | from_entries'
}

# so_rework_commits DIR GIT-LOG-ARGS... - one JSON line per commit `git log` lists: {sha, at, s
# (subject), fix (a fix commit by SO_REWORK_FIX_RE)}.
so_rework_commits() {
  git -C "$1" log "${@:2}" --format='%H %ct %s' |
    jq -cR --arg re "$SO_REWORK_FIX_RE" '
      capture("^(?<sha>[0-9a-f]+) (?<at>[0-9]+) (?<s>.*)$") | .at |= tonumber | .fix = (.s | ascii_downcase | test($re))'
}

# so_rework_repos MAP - one `owner/repo<TAB>dir` line per project-map checkout whose origin is on
# GitHub, so a PR's repo finds the clone blame runs in.
so_rework_repos() {
  local dir repo
  jq -r '.paths // {} | keys[]' "$1" 2>/dev/null | while IFS= read -r dir; do
    repo=$(origin_repo "$dir" github.com) || continue
    printf '%s\t%s\n' "$repo" "$dir"
  done
}

# so_session_links PATH... - the claude.ai/code session ids the transcripts under PATH (files or
# dirs, subagents/ included) recorded, one per line. A session records its link as a
# `remote_session_change` attachment; matched as raw JSON with unescaped quotes, so a transcript that
# quotes one inside a string does not count. A subagent records its own link, and the PRs it opens
# carry that one, so a session's links are its transcript's and its subagents'. A missing PATH is
# skipped; a file that could not be read fails it.
so_session_links() {
  local p paths=()
  for p; do [ -e "$p" ] && paths+=("$p"); done
  [ "${#paths[@]}" -gt 0 ] || return 0
  grep -rhoE --include='*.jsonl' '\{"type":"remote_session_change","url":"https://claude\.ai/code/session_[A-Za-z0-9]+' "${paths[@]}" 2>/dev/null |
    sed 's|.*/code/||' | sort -u
  [ "${PIPESTATUS[0]}" -le 1 ]
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

# so_latest_of OUT PREFIX - so_latest for the sessions whose id starts with PREFIX alone: grep picks
# their lines before jq parses anything, so one card reads its own rows, not the whole store (20 ms
# against 1 s on 29 MB, 2026-11-13). A line naming the prefix only in a nested field gets through
# grep; the caller's select on .session_id drops it.
so_latest_of() {
  local out="$1" p="$2"
  [[ "$p" =~ ^[0-9A-Za-z-]+$ ]] || return 1
  compgen -G "$out/*/*.jsonl" >/dev/null || return 0
  cat "$out"/*/*.jsonl | { grep -E "\"session_id\": *\"$p" || :; } | jq -cn '
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
def in_project($p): $p == "" or .project == $p or any((.projects // [])[]; . == $p);
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

# so_langfuse_deletes - stdin: outcome rows (so_latest lines). stdout: one Langfuse
# score id per line for PR measures that are null (a pruned transcript with no queue/link PRs),
# so re-observing a pruned session clears any 0 scores pushed before null was written.
so_langfuse_deletes() {
  jq -r '
    . as $r
    | [ ["prs_merged", .prs_merged],
        ["prs_closed_unmerged", .prs_closed_unmerged],
        ["reverted_7d", .reverted_7d] ][]
    | select(.[1] == null)
    | "so:\($r.session_id):\(.[0])"'
}
