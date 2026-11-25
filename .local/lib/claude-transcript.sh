# shellcheck shell=bash
# claude-transcript.sh -- what a reopen of a Claude conversation reads and needs: its transcript, the
# branch it last ran on, and its worktree put back. agent-ask (reopen, resume, the card) and
# fleet-dispatch (restore, its resume mode) source it, so both reopen paths find a transcript and
# put a tree back the same way.

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

# session_tree_due <cwd>: the conversation's directory needs wt revive before a resume: it is gone
# (a wind-down or wt done reaped it), or it is a linked worktree (its git dir is not the common dir),
# which wt new may have re-cut for another session on another branch.
session_tree_due() {
  [ ! -d "$1" ] || [ "$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" != \
    "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]
}

# session_tree_back <cwd> <claude session>: put the conversation's worktree back with wt revive, on
# the branch it last ran on; wt refuses a slot another tree or live session holds now. Prints wt's
# last line, the reason on a failure. Fails too when the revived tree lacks <cwd> (a subdirectory
# the revived branch does not have).
session_tree_back() {
  local out rc=0
  out="$(wt revive "$1" --branch "$(session_branch "$2")" </dev/null 2>&1)" || rc=$?
  [ "$rc" != 0 ] || [ -d "$1" ] || { out="the revived tree has no $1"; rc=1; }
  printf '%s\n' "${out##*$'\n'}"
  return "$rc"
}
