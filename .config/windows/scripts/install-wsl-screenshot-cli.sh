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
# menu - auto-start is configured in ~/.commonrc instead.
#
# The script must arrive as a FILE, not on a pipe. `curl ... | bash </dev/null` looks like
# it does both, but the redirect replaces the very stdin the script was arriving on, so bash
# reads an empty program and installs nothing at all -- silently, rc=0. Fetch first, then
# run with stdin closed (shellcheck SC2259).
installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
curl -fsSL https://nailu.dev/wscli/install.sh -o "$installer"
bash "$installer" </dev/null

echo
echo "Installed. Daemon auto-start is wired in ~/.commonrc — open a new shell,"
echo "or run: wsl-screenshot-cli start --daemon"
