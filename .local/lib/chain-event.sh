# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather than a shebang.
#
# chain-event.sh - one line on the notes ingest record per chain step a shell writer makes:
# agent-queue's item writes (stage queue), fleet-dispatch's start, reap and settle (dispatch),
# agent-land's merge (land). The record is the one log of what happened to a task from intake
# to landed (`notes log --item <slug>`); notes owns its format, so this only calls it.
#
#   chain_event <stage> <action> <from> <text> [notes ingest record flags...]
#
# Best effort, like the record itself: a step never fails because its log line did not land.
chain_event() {
  local stage=$1 action=$2 from=$3 text=$4
  shift 4
  notes ingest record --stage "$stage" --action "$action" --from "${from:--}" "$@" -- "${text:--}" >/dev/null 2>&1 || true
}
