#!/bin/bash
# PostToolUse: record a sprint-board stage transition at the moment the board is edited.
#
# A board row's Status cell is edited by an LLM agent (the /wave dispatcher,
# kb-coordinator, wave-overseer) and the edit OVERWRITES the previous value, so the board
# holds a current stage and no history. board_observe reconstructs the history by diffing
# the board against what it saw last time; this hook is what makes it look at the RIGHT
# MOMENT, so the recorded timestamp is the real one rather than "some time in the last
# twelve minutes".
#
# WHY A HOOK AND NOT A WRITER THE DISPATCHERS CALL. Nothing is asked of the agents. A
# prompt that says "call board_set_status" is a second copy of the rule that has to agree
# with the first, and agent-board.sh's header documents five parsers that drifted exactly
# that way. A dispatcher that forgets does not error, it silently records nothing.
#
# THE MATCHER CANNOT SCOPE TO A PATH. For PreToolUse/PostToolUse the harness matches on
# the TOOL NAME only (`Read`, `Bash`, `Edit|Write`); the FileChanged event is the one that
# matches a basename. So this fires on EVERY file edit in EVERY session, and board edits
# are a rounding error of that. The first test below is therefore a raw string match on
# stdin, before jq is ever spawned - the harness times hooks and reports slow ones.
#
# Coverage this hook does NOT have, which is why the 12-minute timers also observe:
# writes via Bash (sed/cat), edits from another machine, edits from Codex/opencode, and a
# human in nvim. board_observe is idempotent, so the two paths cannot double-record.
#
# Exit discipline matches the rest of this repo's hooks: `set -uo pipefail` and never
# `-e`, every failure swallowed, always `exit 0`. A PostToolUse hook exiting 2 blocks the
# tool and shows stderr to the model; recording telemetry must never do that. It also must
# never modify the edited file - the harness detects that and injects a "hook modified
# <f> after your edit" warning into the model's context on every single board edit.

set -uo pipefail

STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)
[ -n "$STDIN_JSON" ] || exit 0

# The cheap gate, deliberately first: a substring test on the raw payload. Anything that
# is not under a plans directory leaves here having spawned no subprocess at all.
case "$STDIN_JSON" in
  *'/.agent/plans/'*) ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

# `.tool_response.filePath` first: it is the path the tool actually wrote, which is the
# one that matters when the input was relative. `.tool_input.file_path` is the fallback
# and is what the PreToolUse hooks in this repo read.
FILE=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_response.filePath // .tool_input.file_path // empty' 2>/dev/null)
[ -n "$FILE" ] || exit 0

# Only a board. The `sprint-*.md` glob is agent-board.sh's one definition of one, and the
# events log is deliberately named so it cannot match (a self-triggering hook would
# otherwise observe its own write).
case "$FILE" in
  */.agent/plans/*/sprint-*.md) ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0

LIB="$HOME/.local/lib/agent-board.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0

# Tags the event so a reader can tell an exact timestamp from a timer's upper bound. That
# distinction is load-bearing: the factory view computes stage DURATIONS from these, and a
# transition seen by a timer collapses however many intermediate stages happened since the
# last pass.
export BOARD_OBSERVE_SRC=hook
board_observe "$FILE" 2>/dev/null

exit 0
