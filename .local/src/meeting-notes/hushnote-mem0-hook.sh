#!/usr/bin/env bash
# hushnote-mem0-hook.sh — HushNote POST_SUMMARY_HOOK target.
#
# HushNote calls this script with the summary markdown path as $1 after every
# meeting summary is generated. It reads the summary + sibling metadata.json and
# POSTs the distilled summary to the self-hosted mem0 instance so meetings are
# recallable across sessions/tools via the mem0-ops skill.
#
# Wire it up in ~/.hushnoterc:
#   POST_SUMMARY_HOOK="${HOME}/.local/bin/hushnote-mem0-hook"
#
# Env (sourced from the shell that runs HushNote, or set in ~/.hushnoterc):
#   MEM0_BASE_URL   default https://mem0.kblab.me  (LAN/Tailscale only; 403 from outside)
#   MEM0_API_KEY    optional; only needed once the server flips AUTH_DISABLED off
#   MEM0_USER_ID    default kblack0610
#   MEM0_AGENT_ID   default meetings
#
# Contract: exits 0 on success (HushNote then writes the .hook_done marker).
# Non-zero leaves the meeting un-marked so `hushnote catchup` retries it.
set -euo pipefail

summary_path="${1:-}"
MEM0_BASE_URL="${MEM0_BASE_URL:-https://mem0.kblab.me}"
MEM0_USER_ID="${MEM0_USER_ID:-kblack0610}"
MEM0_AGENT_ID="${MEM0_AGENT_ID:-meetings}"
log_file="${HOME}/.local/state/meeting-notes/mem0-hook.log"
mkdir -p "$(dirname "$log_file")"

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$log_file"; }

if [[ -z "$summary_path" || ! -f "$summary_path" ]]; then
  log "ERROR: summary path missing or not a file: '${summary_path}'"
  echo "hushnote-mem0-hook: summary path '${summary_path}' not found" >&2
  exit 1
fi

for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { log "ERROR: missing dependency $dep"; echo "missing $dep" >&2; exit 1; }
done

meeting_dir="$(dirname "$summary_path")"
base="$(basename "$summary_path")"; base="${base%_summary.md}"   # e.g. meeting_20260310_090012
metadata_path="${meeting_dir}/${base}_metadata.json"

title=""; timestamp=""
if [[ -f "$metadata_path" ]]; then
  title="$(jq -r '.title // empty' "$metadata_path" 2>/dev/null || true)"
  timestamp="$(jq -r '.timestamp // empty' "$metadata_path" 2>/dev/null || true)"
fi
[[ -n "$title" ]] || title="$base"
run_id="$base"   # unique per meeting → per-meeting isolation, dedup is moot

# Build the payload with jq so the markdown body (newlines, quotes, etc.) is
# encoded safely. infer:false stores the summary verbatim (deterministic).
payload="$(jq -n \
  --rawfile body "$summary_path" \
  --arg title "$title" \
  --arg ts "$timestamp" \
  --arg run "$run_id" \
  --arg base "$base" \
  --arg uid "$MEM0_USER_ID" \
  --arg aid "$MEM0_AGENT_ID" \
  '{
     messages: [{role: "user", content: ("Meeting: " + $title + "\n\n" + $body)}],
     user_id: $uid,
     agent_id: $aid,
     run_id: $run,
     metadata: {type: "meeting-summary", source: "hushnote", title: $title, timestamp: $ts, meeting: $base},
     infer: false
   }')"

auth_args=()
[[ -n "${MEM0_API_KEY:-}" ]] && auth_args=(-H "Authorization: Bearer ${MEM0_API_KEY}")

http_code="$(curl -sS -o "${log_file}.body" -w '%{http_code}' \
  -X POST "${MEM0_BASE_URL}/memories" \
  -H "Content-Type: application/json" \
  "${auth_args[@]}" \
  --data-binary "$payload" 2>>"$log_file" || echo "000")"

if [[ "$http_code" =~ ^2 ]]; then
  log "OK ${http_code} pushed '${title}' (${base}) to ${MEM0_BASE_URL}"
  exit 0
else
  log "ERROR HTTP ${http_code} pushing '${title}' (${base}); response: $(cat "${log_file}.body" 2>/dev/null | head -c 500)"
  echo "hushnote-mem0-hook: mem0 POST failed (HTTP ${http_code}) — see ${log_file}" >&2
  exit 1
fi
