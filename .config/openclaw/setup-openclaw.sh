#!/usr/bin/env bash
set -euo pipefail

DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
TEMPLATE_DIR="$DOTFILES_ROOT/.config/openclaw"
CONFIG_TEMPLATE="$TEMPLATE_DIR/openclaw.base.json5"
APPROVALS_TEMPLATE="$TEMPLATE_DIR/exec-approvals.base.json"
FORCE=0

if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

run_openclaw() {
  local bin
  if bin="$(type -P openclaw 2>/dev/null)"; then
    "$bin" "$@"
    return
  fi

  if bin="$(type -P bunx 2>/dev/null)"; then
    "$bin" openclaw "$@"
    return
  fi

  echo "OpenClaw requires either the openclaw binary or bunx." >&2
  exit 1
}

copy_if_missing_or_forced() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ "$FORCE" -eq 1 || ! -e "$dst" ]]; then
    cp "$src" "$dst"
    echo "Installed $dst"
  else
    echo "Keeping existing $dst"
  fi
}

maybe_allowlist() {
  local agent="$1"
  local bin_name="$2"
  local path
  path="$(type -P "$bin_name" 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    run_openclaw approvals allowlist add --agent "$agent" "$path" >/dev/null
    echo "Allowlisted $path for $agent"
  fi
}

allowlist_many() {
  local agent="$1"
  shift
  local bin_name
  for bin_name in "$@"; do
    maybe_allowlist "$agent" "$bin_name"
  done
}

mkdir -p \
  "$OPENCLAW_HOME" \
  "$OPENCLAW_HOME/logs" \
  "$OPENCLAW_HOME/workspace" \
  "$OPENCLAW_HOME/workspace-home-orchestrator" \
  "$OPENCLAW_HOME/workspace-ops-observer" \
  "$OPENCLAW_HOME/workspace-ops-escalate" \
  "$OPENCLAW_HOME/workspace-pr-coordinator" \
  "$OPENCLAW_HOME/agents/home-orchestrator/agent" \
  "$OPENCLAW_HOME/agents/ops-observer/agent" \
  "$OPENCLAW_HOME/agents/ops-escalate/agent" \
  "$OPENCLAW_HOME/agents/pr-coordinator/agent"

copy_if_missing_or_forced "$CONFIG_TEMPLATE" "$OPENCLAW_HOME/openclaw.json"
copy_if_missing_or_forced "$TEMPLATE_DIR/workspaces/home-orchestrator/AGENTS.md" "$OPENCLAW_HOME/workspace-home-orchestrator/AGENTS.md"
copy_if_missing_or_forced "$TEMPLATE_DIR/workspaces/ops-observer/AGENTS.md" "$OPENCLAW_HOME/workspace-ops-observer/AGENTS.md"
copy_if_missing_or_forced "$TEMPLATE_DIR/workspaces/ops-escalate/AGENTS.md" "$OPENCLAW_HOME/workspace-ops-escalate/AGENTS.md"
copy_if_missing_or_forced "$TEMPLATE_DIR/workspaces/pr-coordinator/AGENTS.md" "$OPENCLAW_HOME/workspace-pr-coordinator/AGENTS.md"

if [[ "$FORCE" -eq 1 || ! -e "$OPENCLAW_HOME/exec-approvals.json" ]]; then
  copy_if_missing_or_forced "$APPROVALS_TEMPLATE" "$OPENCLAW_HOME/exec-approvals.json"
else
  echo "Keeping existing $OPENCLAW_HOME/exec-approvals.json"
fi

allowlist_many ops-observer kubectl flux docker rg find ls cat sed head tail jq
allowlist_many ops-escalate kubectl flux docker rg find ls cat sed head tail jq
allowlist_many pr-coordinator git gh rg find ls cat sed head tail jq

run_openclaw config validate

cat <<EOF

OpenClaw bootstrap complete.

Next steps:
  1. openclaw dashboard
  2. openclaw models auth login
  3. openclaw gateway run
  4. use home-orchestrator as the default entrypoint

Agents:
  - home-orchestrator
  - ops-observer
  - ops-escalate
  - pr-coordinator
EOF
