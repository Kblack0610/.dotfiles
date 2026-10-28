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
so_transcript_metrics() {
  jq -nR '
    def text_of: if type == "string" then .
                 elif type == "array" then ([.[]? | .text? // empty] | join("\n"))
                 else "" end;
    reduce (inputs | fromjson? | select(type == "object")) as $r (
      { pr_ids: {}, lesson_ids: {}, done_ids: {}, prs: [], entrypoint: null,
        interrupts: 0, lessons_written: 0, proof: 0, unverified: 0,
        api_error: 0, denied: 0, tool_errors: 0 };
      (if .entrypoint == null and ($r.entrypoint | type) == "string" then .entrypoint = $r.entrypoint else . end)
      | if $r.type == "assistant" then
        (if $r.isApiErrorMessage == true then .api_error += 1 else . end)
        | reduce ($r.message.content | if type == "array" then .[] else empty end
                  | select(.type == "tool_use")) as $u (.;
            if $u.name == "Bash" then
              ($u.input.command // "") as $c
              | (if ($c | test("\\bgh\\s+pr\\s+(create|merge)\\b")) then .pr_ids[$u.id] = true else . end)
              | (if ($c | test("(>>|tee\\s+-a)\\s*\\S*\\.agent/lessons/")) then .lesson_ids[$u.id] = true else . end)
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
        if ($r.message.content | type) == "string" then
          (if ($r.message.content | startswith("[Request interrupted by user")) then .interrupts += 1 else . end)
        else
          reduce ($r.message.content | if type == "array" then .[] else empty end) as $c (.;
            if $c.type == "tool_result" then
              ($c.content | text_of) as $t
              | ($c.is_error == true) as $err
              | (if $err then .tool_errors += 1 else . end)
              | (if $err and ($t | startswith("The user doesn'"'"'t want to proceed")) then .denied += 1 else . end)
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
      else . end)
    | { prs: (.prs | unique),
        entrypoint,
        corrections: { interrupts, lessons_written },
        board_done: { proof, unverified },
        hard_errors: { api_error, denied, tool_errors } }
  ' < "$1"
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
  jq -c --argjson days "$1" '
    def revert_re: "(?i)\\brevert(s|ed|ing)?(?![-\\w])";
    (map(select(.state == "MERGED")
         | . + {text: ((.title // "") + "\n" + (.body // ""))}
         | select(.text | test(revert_re)))) as $rev
    | map(. as $p
        | { key: ($p.number | tostring),
            value: { state: $p.state, merged_at: $p.mergedAt,
                     reverted: ( $p.state == "MERGED" and $p.mergedAt != null
                       and ([ $rev[]
                              | select(.number != $p.number)
                              | select(.title == ("Revert \"" + $p.title + "\"")
                                       or (.text | split("\n")
                                           | any(test(revert_re + "(?!\\s+(in|by)\\b)[^\\n]*#\($p.number)\\b")))
                                       or ($p.mergeCommit.oid != null
                                           and ([.text | scan("(?i)this reverts commit ([0-9a-f]{7,40})")[0]]
                                                | any(. as $sha | $p.mergeCommit.oid | startswith($sha)))))
                              | select(((.mergedAt | fromdateiso8601) - ($p.mergedAt | fromdateiso8601))
                                       as $d | $d >= 0 and $d <= $days * 86400) ]
                            | length > 0) ) } })
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
# work (2); an interrupt, rejected tool call or API error is friction (1). tool_errors
# stay out: failed commands are how work gets done.
so_friction_def() {
  cat <<'EOF'
def friction:
  5 * (.reverted_7d // 0)
  + 2 * (.prs_closed_unmerged // 0)
  + 2 * (.corrections.lessons_written // 0)
  + (.corrections.interrupts // 0)
  + (.hard_errors.denied // 0)
  + (.hard_errors.api_error // 0);
EOF
}
