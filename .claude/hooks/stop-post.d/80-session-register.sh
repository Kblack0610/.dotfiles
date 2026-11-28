#!/bin/bash
# Stop-post: register the session into an agent-facing registry so an
# agent (or the user) can later list / resume / compact it. Never blocks.
#
# Key points:
#   - Destination is the AGENT axis ~/.agent/sessions/{project}/sessions.jsonl,
#     never the human ~/.notes/captures (low-noise, agent-facing by design).
#   - Registered: every interactive session (transcript entrypoint `cli`, a hand or a dispatched
#     tmux session, read-only or editing through Bash: agentctl-session-outcomes, fleet-bench and
#     `sessions` read their sessions from here), and a headless `claude -p` call only when it made
#     an edit call, left a dirty git tree, or is an agentctl runner (AGENTCTL_NAME, which the runner
#     wrapper exports): a read-only runner still spends, and its row carries the runner's name in
#     `agentctl` (outcome rows already use `runner` as a boolean). A read-only headless call (a judge,
#     a probe; thousands a day) -> no entry.
#   - `edits` counts the edit-tool tool_use calls (edit-tools.conf), not lines naming them:
#     an interactive transcript carries the tool schemas, so a line count read 2+ with no edit (ar-143).
#   - Upsert by session_id: exactly ONE line per session, not per turn.
#   - Self-heals: drops lines whose transcript file no longer exists, but only lines
#     this machine wrote (`host`). store-sync shares the registry across the fleet, so
#     another host's transcript is always missing here; a row with no `host` predates
#     the field and is kept, since nothing says which machine holds its transcript.

set -uo pipefail

# --- stdin payload (loop guard + session_id + transcript_path) ---
STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
[ -n "$STDIN_JSON" ] || exit 0
[ "$(echo "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0

SID=$(echo "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$SID" ] || exit 0
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# --- project ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
. "$HOME/.config/shared-hooks/project-name.sh"
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")
# A worktree reaped before this Stop (`wt done`) cannot be collapsed to its repo any more,
# so its basename would mint a namespace; the project an earlier Stop recorded stands.
if [ ! -d "$PROJECT_DIR" ]; then
  PRIOR=$(grep -l -F "\"session_id\":\"$SID\"" "$HOME"/.agent/sessions/*/sessions.jsonl 2>/dev/null \
          | grep -v -F "/$PROJECT_NAME/sessions.jsonl" | awk 'NR==1')
  [ -n "$PRIOR" ] && PROJECT_NAME=$(basename "$(dirname "$PRIOR")")
fi

# --- the gate: an interactive session, or a headless one that did work ---
# edits: the edit tool calls; grep only narrows the lines jq parses, and a line that is not a
# JSON object, or a content block that is not one, is skipped rather than failing the count.
# shellcheck source=../../../.local/lib/edit-tools.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../.local/lib/edit-tools.sh" &&
  EDIT_RE="$(edit_tools_re)" && EDIT_JSON="$(edit_tools_json)" ||
  { echo "80-session-register: no edit-tool list, so the session was not registered" >&2; exit 0; }
EDITS=$(grep -E "\"name\":\"($EDIT_RE)\"" "$TRANSCRIPT" 2>/dev/null |
  jq -Rn --argjson tools "$EDIT_JSON" '[inputs | fromjson? | objects | select(.type == "assistant") | .message.content? | arrays | .[] | objects
           | select(.type == "tool_use" and (.name | IN($tools[])))] | length' 2>/dev/null)
EDITS=${EDITS:-0}
INTERACTIVE=false
grep -m1 -q -F '"entrypoint":"cli"' "$TRANSCRIPT" 2>/dev/null && INTERACTIVE=true
DIRTY=false
cd "$PROJECT_DIR" 2>/dev/null || true
if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    DIRTY=true
  fi
fi
AGENTCTL="${AGENTCTL_NAME:-}"
if [ "$EDITS" -lt 1 ] && [ "$INTERACTIVE" = false ] && [ "$DIRTY" = false ] && [ -z "$AGENTCTL" ]; then
  exit 0
fi

# --- build the record fields ---
HISTORY="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/history.jsonl"
FIRST_PROMPT=""
if [ -f "$HISTORY" ]; then
  # first non-slash-command prompt for this session; fallback to first display
  FIRST_PROMPT=$(jq -rn --arg s "$SID" 'first(inputs | select(.sessionId==$s) | .display | strings | select(startswith("/") | not))' "$HISTORY" 2>/dev/null)
  [ -z "$FIRST_PROMPT" ] && FIRST_PROMPT=$(jq -rcn --arg s "$SID" '[inputs | select(.sessionId==$s) | .display] | .[:1][]' "$HISTORY" 2>/dev/null)
fi
FIRST_PROMPT=$(printf '%s' "$FIRST_PROMPT" | tr '\n' ' ' | cut -c1-140)

HEAD_COMMIT=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  HEAD_COMMIT=$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-100 || true)
fi

# The session's own rolling title, which Claude Code maintains as an `ai-title` record.
# Better than head_commit as a label: HEAD is the repo's state at Stop, so several
# sessions that ended between two commits all describe themselves with the same subject.
# Read from the end and stop at the first hit - ~20ms even on a large transcript.
TITLE=$(tac "$TRANSCRIPT" 2>/dev/null | grep -m1 '"type":"ai-title"' 2>/dev/null \
        | jq -rc '.aiTitle // empty' 2>/dev/null \
        | tr '\n' ' ' | cut -c1-100 | sed 's/[[:space:]]*$//')
NOW=$(date +%s)

# --- telemetry: what this session cost ---
# Resolved ONCE, here, so every consumer (the cockpit agents panel, the release agent
# changelog) reads a flat file and never queries Prometheus on a render path.
#
# Best-effort by contract: this hook must never block or fail a Stop, so an unreachable
# Prometheus, a missing agent-usage, or malformed output all fall through to a record
# without telemetry fields. Consumers already tolerate their absence.
#
# Claude Code's OTel metric export interval is 60s, so the last few seconds of cost may
# not have landed yet. That is accepted - do NOT add a sleep to the Stop path for it.
USAGE=""
if command -v agent-usage >/dev/null 2>&1; then
  USAGE=$(agent-usage session "$SID" --json 2>/dev/null || true)
  printf '%s' "$USAGE" | jq -e . >/dev/null 2>&1 || USAGE=""
fi

# This machine's short name, from the fleet roster lib (FLEET_HOST). Unknown -> no prune.
# shellcheck source=../../../.local/lib/fleet-hosts.sh
. "${FLEET_HOSTS_LIB:-$HOME/.local/lib/fleet-hosts.sh}" 2>/dev/null || true
HOST="${FLEET_HOST:-}"

REG_DIR="$HOME/.agent/sessions/$PROJECT_NAME"
REG="$REG_DIR/sessions.jsonl"
mkdir -p "$REG_DIR" 2>/dev/null || exit 0

# --- upsert + self-heal: rewrite dropping this id and this host's dead transcripts ---
# Under a lock: two Stops that read the same registry would each mv their copy over it, and
# the second drops the first's row. Runner passes made that common. No flock on macOS.
# The copy is made next to the registry so the swap below is one rename (a /tmp copy crossed
# filesystems, and a crash mid-copy emptied the registry, ar-2779); a filter pass that fails swaps nothing.
exec 9>>"$REG.lock"
command -v flock >/dev/null 2>&1 && flock -w 10 9
TMP=$(mktemp "$REG_DIR/.sessions.jsonl.XXXXXX" 2>/dev/null) || exit 0
trap 'rm -f "$TMP"' EXIT
# Two jq passes, no per-line forks: the old loop ran jq twice per registry line, ~6 s per
# Stop on a 1,400-line registry. Pass 1 lists transcript paths so bash only stats short
# strings; pass 2 filters. Raw input (-R) so an unparseable line is kept verbatim, as
# before, instead of aborting the pass and truncating the registry.
if [ -f "$REG" ]; then
  DEAD=""
  [ -n "$HOST" ] && DEAD=$(jq -rR --arg host "$HOST" 'try (fromjson | select(.host == $host) | .transcript // empty | strings) catch empty' "$REG" 2>/dev/null \
         | sort -u | while IFS= read -r p; do [ -f "$p" ] || printf '%s\n' "$p"; done)
  jq -nrR --arg sid "$SID" --arg dead "$DEAD" --arg host "$HOST" '
    ($dead | split("\n") | map(select(length > 0)) | INDEX(.)) as $d
    | inputs | select(length > 0) | . as $raw
    | (try fromjson catch null) as $o
    | select((try ($o.session_id // "") catch "") != $sid)
    | select((try ($host != "" and $o.host == $host and $d[($o.transcript // "") | tostring] != null) catch false) | not)
    | $raw' "$REG" >> "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 0; }
fi

jq -nc \
  --arg sid "$SID" \
  --arg project "$PROJECT_NAME" \
  --arg transcript "$TRANSCRIPT" \
  --arg resume "cl -r $SID" \
  --arg first_prompt "$FIRST_PROMPT" \
  --argjson edits "${EDITS:-0}" \
  --arg head_commit "$HEAD_COMMIT" \
  --arg title "$TITLE" \
  --argjson updated "$NOW" \
  --argjson usage "${USAGE:-null}" \
  --arg harness "${AGENT_HARNESS:-claude}" \
  --arg agentctl "$AGENTCTL" \
  --arg host "$HOST" \
  '{session_id:$sid, project:$project, transcript:$transcript, resume:$resume, first_prompt:$first_prompt, edits:$edits, head_commit:$head_commit, title:$title, updated:$updated,
    harness:$harness}
   + (if $agentctl == "" then {} else {agentctl: $agentctl} end)
   + (if $host == "" then {} else {host: $host} end)
   + (if $usage == null then {} else {
        cost_usd:      $usage.cost_usd,
        usage_source:  $usage.usage_source,
        usage_partial: $usage.usage_partial,
        tokens:        $usage.tokens,
        models:        $usage.models,
        cost_by_model: $usage.cost_by_model,
        duration_s:    $usage.duration_s
      } end)' \
  >> "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 0; }

mv "$TMP" "$REG" 2>/dev/null || rm -f "$TMP"
exit 0
