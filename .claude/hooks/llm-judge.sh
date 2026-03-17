#!/bin/bash
# llm-judge.sh — LLM-as-Judge session compliance checker
#
# Usage:
#   bash llm-judge.sh <transcript_path>        # Read JSONL transcript file
#   echo '<summary>' | bash llm-judge.sh       # Pipe session summary (Codex)
#   LLM_JUDGE_DRY_RUN=1 bash llm-judge.sh ...  # Print prompt, skip LLM call
#
# Always exits 0 — this is informational, not blocking.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.dotfiles/.config/llm-judge/config.json"
TEMPLATE_FILE="$HOME/.dotfiles/.config/llm-judge/prompt-template.md"

# Source helpers
source "$SCRIPT_DIR/lib/rules-loader.sh"
source "$SCRIPT_DIR/lib/transcript-extractor.sh"
source "$SCRIPT_DIR/lib/llm-call.sh"

main() {
  local transcript_path="${1:-}"

  echo "╔══════════════════════════════════════════╗"
  echo "║       LLM Judge — Compliance Check       ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  # 1. Load rules
  echo "→ Loading rules..."
  local rules
  rules=$(load_rules) || { echo "FAIL: Could not load rules"; exit 0; }

  # 2. Load config
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "FAIL: Config not found at $CONFIG_FILE"
    exit 0
  fi

  local tail_lines max_chars
  tail_lines=$(jq -r '.transcript_tail_lines // 80' "$CONFIG_FILE")
  max_chars=$(jq -r '.max_content_chars_per_message // 500' "$CONFIG_FILE")

  # 3. Get transcript
  echo "→ Extracting transcript..."
  local transcript=""

  if [[ -n "$transcript_path" ]] && [[ -f "$transcript_path" ]]; then
    transcript=$(extract_transcript "$transcript_path" "$tail_lines" "$max_chars")
  elif [[ ! -t 0 ]]; then
    # stdin has content (piped summary)
    transcript=$(cat)
  else
    echo "FAIL: No transcript provided."
    echo "Usage: llm-judge.sh <transcript_path>"
    echo "       echo '<summary>' | llm-judge.sh"
    exit 0
  fi

  if [[ -z "$transcript" ]]; then
    echo "FAIL: Empty transcript — nothing to judge."
    exit 0
  fi

  # 4. Build the judge prompt
  echo "→ Building judge prompt..."
  if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "FAIL: Prompt template not found at $TEMPLATE_FILE"
    exit 0
  fi

  local template
  template=$(cat "$TEMPLATE_FILE")

  local system_prompt
  system_prompt="${template/\{\{RULES\}\}/$rules}"

  local user_content="$transcript"

  # 5. Dry run check
  if [[ "${LLM_JUDGE_DRY_RUN:-0}" == "1" ]]; then
    echo ""
    echo "═══ DRY RUN — Judge Prompt ═══"
    echo ""
    echo "--- SYSTEM PROMPT ---"
    echo "$system_prompt" | head -60
    echo "..."
    echo ""
    echo "--- USER CONTENT (transcript) ---"
    echo "$user_content" | head -40
    echo "..."
    echo ""
    echo "═══ End Dry Run ═══"
    exit 0
  fi

  # 6. Call LLM
  local backend
  backend=$(jq -r '.backend // "mlx"' "$CONFIG_FILE")
  echo "→ Calling judge LLM (backend: $backend)..."
  echo ""

  local verdict
  verdict=$(call_judge_llm "$system_prompt" "$user_content" 2>&1) || {
    echo "WARN: LLM call failed. Error:"
    echo "$verdict"
    exit 0
  }

  # 7. Parse and display results
  display_verdict "$verdict"
}

display_verdict() {
  local raw="$1"

  # Try to extract JSON from the response (LLM may wrap it in markdown)
  local json
  json=$(echo "$raw" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  if [[ -z "$json" ]]; then
    json=$(echo "$raw" | sed -n '/^{/,/^}/p')
  fi
  if [[ -z "$json" ]]; then
    json="$raw"
  fi

  # Validate JSON
  if ! echo "$json" | jq empty 2>/dev/null; then
    echo "WARN: Could not parse LLM response as JSON."
    echo ""
    echo "Raw response:"
    echo "$raw"
    return
  fi

  local overall
  overall=$(echo "$json" | jq -r '.overall // "unknown"')

  # Status icon
  local icon
  case "$overall" in
    pass) icon="✓" ;;
    warn) icon="⚠" ;;
    fail) icon="✗" ;;
    *)    icon="?" ;;
  esac

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Overall: $icon $(echo "$overall" | tr '[:lower:]' '[:upper:]')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Category breakdown
  echo "Categories:"
  echo "$json" | jq -r '.categories // {} | to_entries[] |
    (if .value == "pass" then "  ✓"
     elif .value == "warn" then "  ⚠"
     elif .value == "block" then "  ✗"
     else "  ?" end) + " " + .key + ": " + .value'
  echo ""

  # Violations
  local violation_count
  violation_count=$(echo "$json" | jq -r '.violations | length // 0')

  if [[ "$violation_count" -gt 0 ]]; then
    echo "Violations ($violation_count):"
    echo ""
    echo "$json" | jq -r '.violations[] |
      "  [" + (.severity // "warn") + "] " + .category + "\n" +
      "    Rule: " + .rule + "\n" +
      "    Evidence: " + .evidence + "\n" +
      "    Fix: " + .suggestion + "\n"'
  fi

  # Summary
  local summary
  summary=$(echo "$json" | jq -r '.summary // empty')
  if [[ -n "$summary" ]]; then
    echo "Summary: $summary"
  fi

  echo ""
}

main "$@"
