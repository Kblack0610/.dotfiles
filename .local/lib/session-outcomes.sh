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

# SO_PR_JQ - the jq defs every harness's scan shares: the PR scan, and test_run and ci_poll, the regexes that count a
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
SO_PR_JQ='
  def pr_cmd: test("(^|[\\n;&|({`!]|\\b(ba|z)?sh\\s+-[a-z]*c\\s+[\"\u0027]?|\\bssh\\s+(-\\S+\\s+)*\\S+\\s+[\"\u0027]?)\\s*((\\w+=(\\$\\([^)]*\\)|\"[^\"]*\"|\u0027[^\u0027]*\u0027|\\S*)|env|command|exec|time|then|do|else|sudo|nohup|timeout\\s+\\S+|xargs(\\s+-\\S+)*)\\s+)*gh\\s+pr\\s+(create|merge)\\b")
    or (test("\\bcurl\\b") and test("/pulls(/[0-9]+/merge)?([\"\u0027?\\s]|$)")
        and test("(-X\\s*|--request[=\\s]+)POST\\b|\\s(-d|--data[a-z-]*)([=\\s@\u0027\"]|$)"));
  def pr_refs: [ (scan("https://github\\.com/([^/\\s]+)/([^/\\s]+)/pull/([0-9]+)")
                  | {repo: "\(.[0])/\(.[1])", number: (.[2] | tonumber)}),
                 (scan("[Mm]erged pull request ([^/\\s]+)/([^#\\s]+)#([0-9]+)")
                  | {repo: "\(.[0])/\(.[1])", number: (.[2] | tonumber)}),
                 (scan("https?://([^/\\s\"]+)/([^/\\s\"]+)/([^/\\s\"]+)/pulls/([0-9]+)") | select(.[0] != "github.com")
                  | {repo: "\(.[0])/\(.[1])/\(.[2])", number: (.[3] | tonumber)}) ] | unique;
  def test_run: "(^|[;&|(\\n])\\s*((until|while|if|time|env|timeout\\s+\\S+|\\w+=\\S*)\\s+)*(\\S*scripts/test/(run|suite)\\.sh|(\\S*/)?bats\\s|pytest\\b|cargo\\s+test\\b|make\\s+(-C\\s+\\S+\\s+)?test|(npm|pnpm|yarn)\\s+(\\S+\\s+)*?test\\b)";
  def ci_poll: "\\bgh\\s+(run\\s+(view|watch|list)|pr\\s+checks)\\b";
'

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
  jq -nR --argjson sigs "${2:-[]}" "$SO_PR_JQ"'
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
# night (qmk_firmware, bnb-agents, binks-agent-orchestrator). With no registry to read
# (project_known rc 2, or a resolver lib without it) the resolver's name stands.
so_project_of() {
  local p rc=0
  p="$(resolve_project_name "$1")"
  case "$p" in _*) ;; *) project_known "$p" 2>/dev/null || rc=$?; [ "$rc" -ne 1 ] || p=_unscoped ;; esac
  printf '%s\n' "$p"
}

# so_opencode_rows DB WORK - one registry-shaped line per root opencode session, read-only: opencode
# has no Stop hook, and its own DB already holds cost and tokens. `session_v2` is the live table;
# `session` and `part` stopped being written at 2.1.4. Times are milliseconds. A child session (a
# subagent) adds to its root and gets no line. PRs follow the rule at the top of this file: a
# PR call's own output printed it (SO_PR_JQ). `provider` is the session model's providerID:
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
  # shellcheck source=/dev/null
  . "${SO_PROJECT_LIB:-$HOME/.config/shared-hooks/project-name.sh}" || return 1
  jq -r '(. // [])[].directory' "$work/oc.sessions.json" | sort -u | while IFS= read -r dir; do
    jq -cn --arg d "$dir" --arg p "$(so_project_of "$dir")" '{key: $d, value: $p}'
  done | jq -cs from_entries > "$work/oc.projects.json" || return 1
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
        edits: (.edits // 0), cost_usd, models: [$model.id // empty],
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
  # shellcheck source=/dev/null
  . "${SO_PROJECT_LIB:-$HOME/.config/shared-hooks/project-name.sh}" || return 1
  jq -r '.cwd // empty' "$work/cx.rows.jsonl" | sort -u | while IFS= read -r dir; do
    jq -cn --arg d "$dir" --arg p "$(so_project_of "$dir")" '{key: $d, value: $p}'
  done | jq -cs from_entries > "$work/cx.projects.json" || return 1
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
        .[$c.parent] |= (.edits += $c.edits | .tokens = add_tok(.tokens; $c.tokens)
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

# so_forgejo_repo CHECKOUT - HOST/OWNER/REPO of so_forgejo_remote (home-config's remote is `forgejo`,
# its origin the GitHub mirror); rc 1 when no remote is on a listed host.
so_forgejo_repo() {
  local r
  r="$(so_forgejo_remote "$1")" || return 1
  printf '%s\n' "${r#* }"
}

# so_forgejo_auth HOST/OWNER/REPO - may the token go to this repo's host, and is it read? Sets
# SO_FORGEJO_TOKEN (once per process) and, on a failure, SO_FORGEJO_ERR (rc 1 = no token or the read failed, rc 2 = the host is not listed).
so_forgejo_auth() {
  local repo="$1" entry="${SO_FORGEJO_ENTRY:-forgejo_repo_admin}"
  case " $(so_forgejo_hosts) " in
    *" ${repo%%/*} "*) ;;
    *) SO_FORGEJO_ERR="${repo%%/*} is not in SO_FORGEJO_HOSTS, $repo unread"; return 2 ;;
  esac
  if [ -z "$SO_FORGEJO_TOKEN" ]; then
    SO_FORGEJO_TOKEN="$("${SO_RBW:-rbw}" get "$entry" 2>/dev/null)" || SO_FORGEJO_TOKEN=""
    [ -n "$SO_FORGEJO_TOKEN" ] || { SO_FORGEJO_ERR="no token (rbw $entry), $repo unread"; return 1; }
  fi
}

# so_forgejo_get HOST/OWNER/REPO PATH [CURL ARG...] - one authed API call, after so_forgejo_auth; on
# an HTTP error it fails and still prints the body, which carries Forgejo's reason (.message).
so_forgejo_get() {
  local repo="$1" path="$2"; shift 2
  printf 'header = "Authorization: token %s"\n' "$SO_FORGEJO_TOKEN" |
    "${SO_CURL:-curl}" -sS --fail-with-body -K - --max-time 30 "$@" "https://${repo%%/*}/api/v1/repos/${repo#*/}/$path"
}

# so_forgejo_hosts - the Forgejo hosts a lookup may send the token to, space-separated:
# SO_FORGEJO_HOSTS when set (even empty), else the private session-outcomes runner conf's. A host
# comes from transcript text, so one not listed is never called.
so_forgejo_hosts() {
  if [ -n "${SO_FORGEJO_HOSTS+set}" ]; then printf '%s' "$SO_FORGEJO_HOSTS"; return; fi
  ( . "${AGENTCTL_CONF_DIR:-$HOME/.config/agentctl/agents}/session-outcomes.conf" 2>/dev/null
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
# changed (.md .json .jsonl .txt are not code). A change a fix rewrote within SO_REWORK_DAYS (7)
# is a rework CANDIDATE; one a fix rewrote within SO_REWORK_VERIFY_DAYS (30) whose message names
# it, as its PR (#N) or its sha, is VERIFIED. A candidate is a lead, never a defect: a fix often
# rewrites lines it did not find wrong. The human samples the verified label (`rework --sample`).
# A PR merged with a merge commit is read by that commit alone, so its branch's lines are not seen.
: "${SO_REWORK_DAYS:=7}" "${SO_REWORK_VERIFY_DAYS:=30}"
SO_REWORK_FIX_RE='^(fix|revert|hotfix)([^a-z0-9_]|$)'   # on the lowercased subject

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
      awk '/^diff --git / { h = 1; p = ""; next }
           h && /^--- a\// { p = substr($0, 7); next }
           h && /^--- / { p = ""; next }
           /^@@ / { h = 0
                    if (p == "" || p ~ /[.](md|json|jsonl|txt)$/) next
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
