# injected.sh - sourced by UserPromptSubmit hooks that inject a block once per session and again
# after each compaction (the summary drops it): answer-standard.sh, manual-mode-investigate.sh.

# injected_since_compact <transcript> <mark> [mode]: true when a hook-context entry carrying
# <mark> is newer than the last compact boundary and, given a mode, newer than the last entry
# recorded in another permission mode (a block for one mode is sent again when the session comes
# back to it). Only a hook-context entry counts, so a session that types the mark (editing a
# hook) still gets the block. A forward read, as BSD userlands (the mac-mini) have no tac.
injected_since_compact() {
  awk -v m="$2" -v mode="${3:-}" 'index($0, "\"compact_boundary\"") {f = 0}
    mode != "" && match($0, /"permissionMode":"[^"]*"/) && substr($0, RSTART + 18, RLENGTH - 19) != mode {f = 0}
    index($0, "\"hook_additional_context\"") && index($0, m) {f = 1}
    END {exit !f}' "$1"
}
