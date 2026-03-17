#!/bin/bash
# judge.sh — Codex wrapper for llm-judge
# Reads session summary from stdin, forwards to the main llm-judge.sh
#
# Usage: echo '<session summary>' | bash judge.sh

set -euo pipefail

JUDGE_SCRIPT="$HOME/.dotfiles/.claude/hooks/llm-judge.sh"

if [[ ! -f "$JUDGE_SCRIPT" ]]; then
  echo "ERROR: llm-judge.sh not found at $JUDGE_SCRIPT" >&2
  exit 0
fi

# Forward stdin to the main judge script
exec bash "$JUDGE_SCRIPT"
