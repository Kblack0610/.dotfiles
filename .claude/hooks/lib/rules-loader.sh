#!/bin/bash
# rules-loader.sh — Loads shared AI rules for the LLM judge
# Reads overview.md + project CLAUDE.md, strips YAML frontmatter, concatenates.

load_rules() {
  local rules=""

  # Primary rules source
  local overview="$HOME/.dotfiles/.config/rulesync-global/.rulesync/rules/overview.md"
  if [[ -f "$overview" ]]; then
    rules+="$(strip_frontmatter "$overview")"
    rules+=$'\n\n'
  fi

  # Project-specific CLAUDE.md (if in a project context)
  local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  local claude_md="$project_dir/CLAUDE.md"
  if [[ -f "$claude_md" ]]; then
    local project_rules
    project_rules="$(strip_frontmatter "$claude_md")"
    # Only append if it differs from overview (avoid duplication)
    if [[ "$project_rules" != "$(strip_frontmatter "$overview")" ]]; then
      rules+="### Project-Specific Rules"$'\n\n'
      rules+="$project_rules"
      rules+=$'\n'
    fi
  fi

  if [[ -z "$rules" ]]; then
    echo "ERROR: No rules files found" >&2
    return 1
  fi

  printf '%s' "$rules"
}

strip_frontmatter() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; past_fm = 0 }
    /^---$/ && !past_fm { in_fm = !in_fm; if (!in_fm) past_fm = 1; next }
    !in_fm { print }
  ' "$file"
}
