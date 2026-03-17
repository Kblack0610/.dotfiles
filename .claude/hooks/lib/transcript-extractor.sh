#!/bin/bash
# transcript-extractor.sh — Extracts and truncates session transcripts
# Handles JSONL transcript files from Claude Code sessions.

extract_transcript() {
  local source="$1"          # file path or "-" for stdin
  local tail_lines="${2:-80}"
  local max_chars="${3:-500}"

  local raw_json

  if [[ "$source" == "-" ]] || [[ -z "$source" ]]; then
    # Read from stdin (e.g., Codex self-summary)
    cat
    return 0
  fi

  if [[ ! -f "$source" ]]; then
    echo "ERROR: Transcript file not found: $source" >&2
    return 1
  fi

  # Tail the JSONL, extract user/assistant messages, truncate long content
  tail -n "$tail_lines" "$source" | jq -r --argjson max "$max_chars" '
    select(.type == "message" or .type == "human" or .type == "assistant" or
           .role == "user" or .role == "assistant") |
    # Normalize role
    (if .role then .role
     elif .type == "human" then "user"
     elif .type == "assistant" then "assistant"
     elif .type == "message" then (.message.role // "unknown")
     else "unknown" end) as $role |
    # Extract text content
    (if .message.content then
      (if (.message.content | type) == "array" then
        [.message.content[] | select(.type == "text") | .text] | join("\n")
       elif (.message.content | type) == "string" then
        .message.content
       else "" end)
     elif .content then
      (if (.content | type) == "string" then .content
       elif (.content | type) == "array" then
        [.content[] | select(.type == "text") | .text] | join("\n")
       else "" end)
     elif .text then .text
     else "" end) as $text |
    select($text != "") |
    # Truncate long messages
    "\($role | ascii_upcase): \(if ($text | length) > $max then ($text[:$max] + "... [truncated]") else $text end)"
  ' 2>/dev/null

  if [[ $? -ne 0 ]]; then
    # Fallback: just tail the raw file
    echo "# Raw transcript tail (jq parsing failed)" >&2
    tail -n "$tail_lines" "$source" | head -c 10000
  fi
}
