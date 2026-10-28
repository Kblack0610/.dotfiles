#!/bin/bash
# llm-judge.sh — LLM-as-Judge for assistant sessions: prints a compliance verdict to
# stdout. Used by /my:judge, on demand only. The per-Stop eval mode was retired
# 2026-10-28: session-outcomes and the fleet-bench scorecard are the eval.
#
# Usage:
#   bash llm-judge.sh <transcript_path>
#   echo '<summary>' | bash llm-judge.sh           # piped input
#   LLM_JUDGE_DRY_RUN=1 bash llm-judge.sh ...      # print prompt, skip LLM
#
# Always exits 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.config/llm-judge/config.json"
AUDIT_TEMPLATE="$HOME/.config/llm-judge/prompt-template.md"

source "$SCRIPT_DIR/lib/rules-loader.sh"
source "$SCRIPT_DIR/lib/transcript-extractor.sh"
source "$SCRIPT_DIR/lib/llm-call.sh"

# --- argv parsing -----------------------------------------------------------

transcript_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; break ;;
    -*) echo "WARN: unknown flag $1" >&2; shift ;;
    *)  transcript_path="$1"; shift ;;
  esac
done

# --- helpers ----------------------------------------------------------------

read_template() {
  local f="$1"
  [[ -f "$f" ]] || { echo "ERROR: template not found: $f" >&2; return 1; }
  cat "$f"
}

# --- audit mode -------------------------------------------------------------

audit_main() {
  echo "╔══════════════════════════════════════════╗"
  echo "║       LLM Judge — Compliance Check       ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  echo "→ Loading rules..."
  local rules
  rules=$(load_rules) || { echo "FAIL: Could not load rules"; exit 0; }

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "FAIL: Config not found at $CONFIG_FILE"; exit 0
  fi
  local tail_lines max_chars
  tail_lines=$(jq -r '.transcript_tail_lines // 80' "$CONFIG_FILE")
  max_chars=$(jq -r '.max_content_chars_per_message // 500' "$CONFIG_FILE")

  echo "→ Extracting transcript..."
  local transcript=""
  if [[ -n "$transcript_path" ]] && [[ -f "$transcript_path" ]]; then
    transcript=$(extract_transcript "$transcript_path" "$tail_lines" "$max_chars")
  elif [[ ! -t 0 ]]; then
    transcript=$(cat)
  else
    echo "FAIL: No transcript provided."
    echo "Usage: llm-judge.sh <transcript_path>"
    exit 0
  fi

  if [[ -z "$transcript" ]]; then
    echo "FAIL: Empty transcript — nothing to judge."; exit 0
  fi

  echo "→ Building judge prompt..."
  local template
  template=$(read_template "$AUDIT_TEMPLATE") || exit 0
  local system_prompt="${template/\{\{RULES\}\}/$rules}"
  local user_content="$transcript"

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
    echo "═══ End Dry Run ═══"
    exit 0
  fi

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

  display_verdict "$verdict"
}

display_verdict() {
  local raw="$1"
  local json
  json=$(echo "$raw" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  [[ -z "$json" ]] && json=$(echo "$raw" | sed -n '/^{/,/^}/p')
  [[ -z "$json" ]] && json="$raw"

  if ! echo "$json" | jq empty 2>/dev/null; then
    echo "WARN: Could not parse LLM response as JSON."
    echo ""
    echo "Raw response:"
    echo "$raw"
    return
  fi

  local overall icon
  overall=$(echo "$json" | jq -r '.overall // "unknown"')
  case "$overall" in
    pass) icon="✓" ;; warn) icon="⚠" ;; fail) icon="✗" ;; *) icon="?" ;;
  esac

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Overall: $icon $(echo "$overall" | tr '[:lower:]' '[:upper:]')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Categories:"
  echo "$json" | jq -r '.categories // {} | to_entries[] |
    (if .value == "pass" then "  ✓"
     elif .value == "warn" then "  ⚠"
     elif .value == "block" then "  ✗"
     else "  ?" end) + " " + .key + ": " + .value'
  echo ""

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

  local summary
  summary=$(echo "$json" | jq -r '.summary // empty')
  [[ -n "$summary" ]] && echo "Summary: $summary"
  echo ""
}

# --- entry point ------------------------------------------------------------

audit_main
