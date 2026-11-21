# injected.sh - sourced by UserPromptSubmit hooks that inject a block once per session and again
# after each compaction (the summary drops it): answer-standard.sh, manual-mode-investigate.sh.

# injected_since_compact <transcript> <mark>: true when a hook-context entry carrying <mark> is
# newer than the last compact boundary. Only a hook-context entry counts, so a session that types
# the mark (editing a hook) still gets the block. A forward read, as BSD userlands (the mac-mini)
# have no tac.
injected_since_compact() {
  awk -v m="$2" 'index($0, "\"compact_boundary\"") {f = 0}
    index($0, "\"hook_additional_context\"") && index($0, m) {f = 1}
    END {exit !f}' "$1"
}
