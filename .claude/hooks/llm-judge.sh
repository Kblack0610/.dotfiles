#!/bin/bash
# llm-judge.sh — LLM-as-Judge for assistant sessions.
#
# Two modes:
#   audit  (default): print compliance verdict to stdout. Used by /my:judge.
#   eval:             append a daily-eval session entry to a markdown file.
#                     Used by stop-post.d/90-eval-gate.sh in async background.
#
# Usage:
#   bash llm-judge.sh [--mode audit|eval] \
#                     [--eval-file <path>] [--project <name>] \
#                     [--session-num <N>] [--ci-status <STR>] \
#                     [--section-overrides <STR>] \
#                     <transcript_path>
#
#   echo '<summary>' | bash llm-judge.sh           # audit mode, piped input
#   LLM_JUDGE_DRY_RUN=1 bash llm-judge.sh ...      # print prompt, skip LLM
#
# Always exits 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.dotfiles/.config/llm-judge/config.json"
AUDIT_TEMPLATE="$HOME/.dotfiles/.config/llm-judge/prompt-template.md"
EVAL_TEMPLATE="$HOME/.dotfiles/.config/llm-judge/prompt-template-eval.md"

source "$SCRIPT_DIR/lib/rules-loader.sh"
source "$SCRIPT_DIR/lib/transcript-extractor.sh"
source "$SCRIPT_DIR/lib/llm-call.sh"

# --- argv parsing -----------------------------------------------------------

mode="audit"
eval_file=""
project=""
session_num=""
ci_status=""
section_overrides=""
transcript_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)              mode="$2"; shift 2 ;;
    --eval-file)         eval_file="$2"; shift 2 ;;
    --project)           project="$2"; shift 2 ;;
    --session-num)       session_num="$2"; shift 2 ;;
    --ci-status)         ci_status="$2"; shift 2 ;;
    --section-overrides) section_overrides="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "WARN: unknown flag $1" >&2; shift ;;
    *)  transcript_path="$1"; shift ;;
  esac
done

# --- helpers ----------------------------------------------------------------

count_sessions() {
  local file="$1"
  [[ -f "$file" ]] || { echo 0; return; }
  grep -c '^## Session ' "$file" 2>/dev/null || echo 0
}

read_template() {
  local f="$1"
  [[ -f "$f" ]] || { echo "ERROR: template not found: $f" >&2; return 1; }
  cat "$f"
}

# Substitute {{KEY}} placeholders. Bash literal-string replace — no regex.
# {{LABEL}} is intentionally left untouched; the LLM fills it in its output.
render_template() {
  local tpl="$1" rules="$2" sn="$3" proj="$4" ci="$5" overrides="$6" tx="$7"
  tpl="${tpl//\{\{RULES\}\}/$rules}"
  tpl="${tpl//\{\{SESSION_NUM\}\}/$sn}"
  tpl="${tpl//\{\{PROJECT\}\}/$proj}"
  tpl="${tpl//\{\{CI_STATUS\}\}/$ci}"
  tpl="${tpl//\{\{SECTION_OVERRIDES\}\}/$overrides}"
  tpl="${tpl//\{\{TRANSCRIPT\}\}/$tx}"
  printf '%s' "$tpl"
}

strip_code_fence() {
  local raw="$1"
  if [[ "$raw" == '```'* ]]; then
    raw=$(printf '%s\n' "$raw" | sed -e '1d' -e '$d')
  fi
  printf '%s' "$raw"
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

# --- eval mode --------------------------------------------------------------

eval_main() {
  if [[ -z "$project" ]]; then
    project=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
  fi
  if [[ -z "$eval_file" ]]; then
    eval_file="$HOME/.agent/evals/${project}/$(date +%Y-%m-%d).md"
  fi
  if [[ -z "$session_num" ]]; then
    session_num=$(( $(count_sessions "$eval_file") + 1 ))
  fi
  [[ -z "$ci_status" ]] && ci_status="(none)"
  [[ -z "$section_overrides" ]] && section_overrides="(none — use default sections)"

  mkdir -p "$(dirname "$eval_file")" 2>/dev/null || true

  local rules
  rules=$(load_rules) || { append_stub "rules-load-failed"; exit 0; }

  if [[ ! -f "$CONFIG_FILE" ]]; then
    append_stub "config-not-found"; exit 0
  fi
  local tail_lines max_chars
  tail_lines=$(jq -r '.transcript_tail_lines // 80' "$CONFIG_FILE")
  max_chars=$(jq -r '.max_content_chars_per_message // 500' "$CONFIG_FILE")

  local transcript=""
  if [[ -n "$transcript_path" ]] && [[ -f "$transcript_path" ]]; then
    transcript=$(extract_transcript "$transcript_path" "$tail_lines" "$max_chars")
  elif [[ ! -t 0 ]]; then
    transcript=$(cat)
  fi
  if [[ -z "$transcript" ]]; then
    append_stub "empty-transcript"; exit 0
  fi

  local template
  template=$(read_template "$EVAL_TEMPLATE") || { append_stub "template-not-found"; exit 0; }
  local system_prompt
  system_prompt=$(render_template "$template" "$rules" "$session_num" "$project" "$ci_status" "$section_overrides" "$transcript")

  if [[ "${LLM_JUDGE_DRY_RUN:-0}" == "1" ]]; then
    echo "═══ EVAL MODE DRY RUN ═══"
    echo "eval_file=$eval_file"
    echo "project=$project"
    echo "session_num=$session_num"
    echo "ci_status=$ci_status"
    echo "section_overrides=$section_overrides"
    echo ""
    echo "--- SYSTEM PROMPT (first 80 lines) ---"
    echo "$system_prompt" | head -80
    echo "..."
    echo "═══ End Dry Run ═══"
    exit 0
  fi

  local entry err_log
  err_log=$(mktemp)
  entry=$(call_judge_llm "$system_prompt" "Produce the session eval entry now." 2>"$err_log") || {
    append_stub "llm-call-failed: $(head -c 200 "$err_log" | tr '\n' ' ')"
    rm -f "$err_log"
    exit 0
  }
  rm -f "$err_log"

  entry=$(strip_code_fence "$entry")

  if [[ "$entry" != "## Session "* ]]; then
    append_stub "malformed-output: $(echo "$entry" | head -c 200)"
    exit 0
  fi

  {
    printf '\n'
    printf '%s\n' "$entry"
  } >> "$eval_file"
}

append_stub() {
  local reason="$1"
  mkdir -p "$(dirname "$eval_file")" 2>/dev/null || true
  {
    printf '\n## Session %s (EVAL PENDING — judge unavailable: %s)\n\n' \
      "$session_num" "$reason"
    printf -- '- **Workflow**: n/a — async judge failed to render entry.\n'
    printf '\n**Summary:** Entry slot reserved; judge error: %s. Overall: n/a.\n' \
      "$reason"
  } >> "$eval_file"
}

# --- entry point ------------------------------------------------------------

case "$mode" in
  audit) audit_main ;;
  eval)  eval_main ;;
  *)     echo "ERROR: unknown mode '$mode' (expected: audit, eval)" >&2; exit 0 ;;
esac
