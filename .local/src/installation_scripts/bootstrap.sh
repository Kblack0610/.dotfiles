#!/usr/bin/env bash
# bootstrap.sh — Lazer-style one-liner entry point for Linux / macOS / WSL.
#
# Designed to be piped from a fetch tool (no clone required up-front):
#
#   # Via gh (works through corporate proxies that block raw.githubusercontent.com):
#   gh api repos/Kblack0610/.dotfiles/contents/.local/src/installation_scripts/bootstrap.sh \
#     --jq '.content' | base64 -d | bash
#
#   # Via curl (simpler, no gh auth):
#   curl -fsSL https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/bootstrap.sh | bash
#
# What this does:
#   1. Installs git via the system package manager if missing.
#   2. Clones the dotfiles to $DOTFILES_DIR (default: ~/.dotfiles), or pulls if present.
#   3. exec's install.sh with stdin reattached to /dev/tty so its prompts work.
#
# Idempotent: re-running re-pulls and re-runs the installer.

set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/Kblack0610/.dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"

step() { printf '\033[0;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

# 1. Ensure git is on PATH.
if ! command -v git &>/dev/null; then
    step "Installing git"
    if   command -v apt    &>/dev/null; then sudo apt update && sudo apt install -y git
    elif command -v pacman &>/dev/null; then sudo pacman -Sy --noconfirm git
    elif command -v brew   &>/dev/null; then brew install git
    elif command -v pkg    &>/dev/null; then pkg install -y git   # termux
    else die "No supported package manager found. Install git manually and re-run."
    fi
fi

# 2. Clone or fast-forward the repo.
if [[ ! -d "$DOTFILES_DIR" ]]; then
    step "Cloning $DOTFILES_REPO -> $DOTFILES_DIR"
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
else
    step "Dotfiles already at $DOTFILES_DIR — pulling latest"
    git -C "$DOTFILES_DIR" pull --ff-only || warn "git pull --ff-only failed (local divergence?); continuing with on-disk version"
fi

# 3. Hand off. Reattach stdin to /dev/tty so install.sh's interactive prompts
#    work even when bootstrap was piped in (stdin was the script bytes).
INSTALLER="$DOTFILES_DIR/.local/src/installation_scripts/install.sh"
[[ -f "$INSTALLER" ]] || die "Installer not found at $INSTALLER — bad clone?"

# Args passed to bootstrap.sh (e.g. --no-sudo) are forwarded to install.sh.
# NO_SUDO is also honored via the environment, so the curl one-liner works as:
#   curl -fsSL .../bootstrap.sh | NO_SUDO=1 bash
step "Running $INSTALLER $*"
if [[ -e /dev/tty ]]; then
    exec bash "$INSTALLER" "$@" </dev/tty
else
    # No tty (CI, container without -t). install.sh's interactive prompts will
    # fall through; assume non-interactive and pass DOTFILES_YES=1 if the
    # caller wants to skip confirmation.
    exec bash "$INSTALLER" "$@"
fi
