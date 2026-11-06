# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# judge.sh - what every judge lane shares: the rule ids its policy defines, the id that links a
# verdict to its call line, and its verdicts read back in one shape for Langfuse.
#
# A policy defines its rules as bullets that open with the id in parentheses, `- (gate) ...`;
# the policy file (the agent conf's PROMPT) is the one list, so a rule added there is valid
# here with no code change. A verdict names one, and a verdict naming none of them is an
# `error`. A verdict stays in its subject's store (an ask file's judge_* fields, fleet-dispatch's
# verdicts.jsonl) and carries judge_call, the id of its line in calls.jsonl; the caller passes it
# to agentctl-run as AGENTCTL_CALL_ID.

# shellcheck source=../src/agent-run/lib/calls.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../src/agent-run/lib/calls.sh"

# judge_rules <policy>: its rule ids, one per line.
judge_rules() { sed -n 's/^- (\([a-z][a-z0-9-]*\)) .*/\1/p' "$1" 2>/dev/null; }

# judge_call_id: a fresh call id, in the form agentctl-run gives its own.
judge_call_id() { calls_new_id; }

# judge_ask_docs <asks root>: every ask file under <root>/<project>/ as one JSON object of its
# `key: value` fields, the first line of a key winning (agent-ask's `field`). One jq for all.
judge_ask_docs() {
  local files=()
  [ -d "$1" ] && mapfile -t files < <(find "$1" -mindepth 2 -maxdepth 2 -name '*.md' 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || return 0
  jq -cRn '[inputs | {f: input_filename} + (capture("^(?<k>[a-z_]+): (?<v>.*)$") // {})]
    | group_by(.f)[] | map(select(.k) | {(.k): .v}) | reverse | add' "${files[@]}" 2>/dev/null
  return 0
}

# judge_verdicts <asks root> <verdicts.jsonl>: every verdict that names its call, one JSON line
# each: {agent, subject, project, value, rule, reason, judge_call, at}. A gate the ask judge
# never sent to the model has no call and is left out; so is every verdict written before
# judge_call existed.
judge_verdicts() {
  local asks="$1" verdicts="$2"
  judge_ask_docs "$asks" | jq -c 'select(.judge_call // "" | length > 0)
    | {agent: "ask-judge", subject: .id, project, value: (.judge | sub(":.*"; "")),
       rule: (.judge_rule // ""), reason: (.judge_reason // ""), judge_call, at: .judged_at}'
  [ -f "$verdicts" ] && jq -c 'select(.judge_call // "" | length > 0)
    | {agent: "dispatch-judge", subject: "\(.project)/\(.lane)/\(.key)", project, value: .verdict,
       rule: (.rule // ""), reason: (.reason // ""), judge_call, at}' "$verdicts" 2>/dev/null
  return 0
}

# judge_langfuse_events <calls.jsonl> <since epoch> <mark epoch>: stdin judge_verdicts lines.
# stdout: one Langfuse score-create event per verdict judged after <mark> and since <since>
# whose call has a session id: a CATEGORICAL score named for the agent, valued with its call,
# its comment the rule and reason, on the session its call ran as (the trace key). The score id
# is the verdict's, so a resend overwrites it. Each event carries `epoch` at the top level for
# the caller's mark; strip it before sending.
judge_langfuse_events() {
  jq -cn --slurpfile calls <(jq -c 'select(.session_id) | {(.id): .session_id}' "$1" 2>/dev/null) \
    --argjson since "$2" --argjson mark "$3" '
    def epoch: (.[0:19] + "Z" | fromdateiso8601)
      - ((.[19:] | capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})")
          | (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60)) // 0);
    ($calls | add // {}) as $sid
    | inputs | . as $v | ($v.at | epoch? // null) as $e
    | select($e != null and $e > $mark and $e >= $since and $sid[$v.judge_call] != null)
    | {id: "jv:\($v.judge_call):\($v.subject):\($e)", type: "score-create", timestamp: $v.at, epoch: $e,
       body: {id: "jv:\($v.judge_call):\($v.subject)", sessionId: $sid[$v.judge_call],
              name: $v.agent, value: $v.value, dataType: "CATEGORICAL",
              comment: "\($v.rule): \($v.reason)",
              metadata: {subject: $v.subject, project: $v.project, rule: $v.rule, judge_call: $v.judge_call}}}'
}
