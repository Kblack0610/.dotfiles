# shellcheck shell=bash
# claude-transcript.sh -- the one locate of a Claude session's transcript, and the facts a reopen reads
# from it: agent-ask (reopen, resume, the card) and fleet-dispatch (restore, its resume mode) source it,
# so no caller globs ~/.claude*/projects on its own.

# session_transcript <claude session>: its transcript file. Accounts share the transcripts, so
# any copy will do.
session_transcript() { ls "$HOME"/.claude*/projects/*/"$1".jsonl 2>/dev/null | awk 'NR==1'; }

# session_branch <claude session>: the git branch the conversation last ran on, from the last
# transcript line that records one (a session can switch branches mid-run).
session_branch() {
  local t; t="$(session_transcript "$1")"
  [ -n "$t" ] || return 0
  # Only a top-level field counts: a message can quote the key.
  grep '"gitBranch":' "$t" | jq -rR 'fromjson? | objects | .gitBranch // empty | strings' 2>/dev/null | tail -1
}
