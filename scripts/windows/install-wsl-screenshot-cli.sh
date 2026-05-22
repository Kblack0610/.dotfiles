#!/usr/bin/env bash
# Install wsl-screenshot-cli: makes Windows screenshots pasteable in WSL terminals.
# Idempotent — safe to re-run.
#
# Upstream: https://github.com/Nailuu/wsl-screenshot-cli
set -euo pipefail

if ! grep -qiE 'wsl|microsoft' /proc/version 2>/dev/null; then
    echo "Not running inside WSL — skipping." >&2
    exit 0
fi

if command -v wsl-screenshot-cli >/dev/null 2>&1; then
    echo "wsl-screenshot-cli already installed: $(wsl-screenshot-cli --version)"
    exit 0
fi

# Run installer non-interactively (stdin closed) so it skips the auto-start
# menu — auto-start is configured in ~/.commonrc instead.
curl -fsSL https://nailu.dev/wscli/install.sh | bash </dev/null

echo
echo "Installed. Daemon auto-start is wired in ~/.commonrc — open a new shell,"
echo "or run: wsl-screenshot-cli start --daemon"
