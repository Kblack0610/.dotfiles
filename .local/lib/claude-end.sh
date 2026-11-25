# shellcheck shell=bash
# claude-end.sh -- the one parse of how a Claude Code transcript says its session ended, the Claude peer of
# codex-rollout.jq, opencode-session.jq and agy-result.jq. Its callers: fleet-sessions api_error_stop (a turn
# that stopped at an idle prompt), session-outcomes.sh so_transcript_metrics (its api_error count) and
# fleet-dispatch item_claude_end (the item's end_reason), so no one reads `isApiErrorMessage` on its own.
# Claude Code writes its own error line as an assistant entry with isApiErrorMessage: `API Error: <code> ...`
# is a provider fault (the CLI retried first, so the turn is over); a line with no code that says the weekly or usage limit
# (fleet-shepherd's LIMIT_RE wording) is the plan's usage limit, and a context or output limit is neither. Structure and the CLI's own wording only, never a model's prose.

# CLAUDE_END_JQ: jq defs. is_api_error: that record is the CLI's error line (what so_transcript_metrics counts).
# api_error_end: {reason: provider|limit, code} for such a record, else null. transcript_end: the same for the
# LAST user or assistant record of an array of records, with at (its timestamp to the minute), else null: a later
# message, a nudge or the human's, means the error is not how the session ended.
CLAUDE_END_JQ='
def is_api_error: .type == "assistant" and .isApiErrorMessage == true;
def api_error_end:
  if is_api_error then
    ([.message.content[]? | select(.type == "text") | .text] | join(" ")) as $t
    | (($t | capture("API Error: (?<c>[0-9]+)")? // {c: ""}).c) as $c
    | if $c != "" then {reason: "provider", code: $c}
      elif ($t | test("weekly limit|usage limit|hit your .*limit"; "i")) then {reason: "limit", code: ""}
      else null end
  else null end;
def transcript_end:
  [.[] | select(type == "object" and (.type == "assistant" or .type == "user"))] | last // null
  | if . == null then null
    else (api_error_end) as $e | if $e == null then null else $e + {at: ((.timestamp // "-")[:16])} end end;
'

# claude_end <transcript> -> "<reason>\t<code or ->\t<timestamp to the minute>" when the transcript's last
# message is the CLI's own error line, else nothing. Only the tail is read (a first line cut by tail is
# skipped).
claude_end() {
  [ -s "${1:-}" ] || return 0
  tail -n 100 "$1" | jq -nRr "$CLAUDE_END_JQ"'[inputs | fromjson?] | transcript_end | select(. != null)
      | [.reason, (if .code == "" then "-" else .code end), .at] | @tsv' 2>/dev/null || true
}
