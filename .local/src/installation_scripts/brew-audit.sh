#!/usr/bin/env bash
# brew-audit — report drift between installed Homebrew packages and the tracked Brewfile.
#
# The Brewfile (.config/brewfile/Brewfile) is the source of truth for provisioning a Mac.
# This script answers "is everything I have installed actually tracked?" so the install
# files don't silently fall behind reality. Read-only; never installs or removes anything.
#
# Exit status: 0 = no drift, 1 = drift found (so it can gate a hook/CI later).

set -uo pipefail

BREWFILE="${BREWFILE:-$HOME/.dotfiles/.config/brewfile/Brewfile}"

if ! command -v brew >/dev/null 2>&1; then
    echo "brew not found on PATH — nothing to audit." >&2
    exit 0
fi
if [[ ! -f "$BREWFILE" ]]; then
    echo "Brewfile not found at $BREWFILE" >&2
    exit 2
fi

# Strip tap prefixes and alias noise so the report is signal-only:
#   felixkratz/formulae/sketchybar -> sketchybar
#   kubernetes-cli                 -> kubectl   (canonical name of a tracked alias)
normalize() {
    sed 's|.*/||' | sed 's/^kubernetes-cli$/kubectl/' | sort -u
}

tracked_brews() { grep '^brew ' "$BREWFILE" | sed 's/brew "//; s/".*//' | normalize; }
tracked_casks() { grep '^cask ' "$BREWFILE" | sed 's/cask "//; s/".*//' | sort -u; }

drift=0

echo "== Brewfile satisfied? =="
if brew bundle check --file="$BREWFILE" >/dev/null 2>&1; then
    echo "  ✓ all Brewfile entries installed"
else
    echo "  ✗ missing entries — run: brew bundle install --file=$BREWFILE"
    drift=1
fi

echo
echo "== Installed formulae NOT in Brewfile =="
extra_brews="$(comm -23 <(brew leaves 2>/dev/null | normalize) <(tracked_brews))"
if [[ -n "$extra_brews" ]]; then
    echo "$extra_brews" | sed 's/^/  brew "/; s/$/"/'
    drift=1
else
    echo "  (none)"
fi

echo
echo "== Installed casks NOT in Brewfile =="
extra_casks="$(comm -23 <(brew list --cask 2>/dev/null | sort) <(tracked_casks))"
if [[ -n "$extra_casks" ]]; then
    echo "$extra_casks" | sed 's/^/  cask "/; s/$/"/'
    drift=1
else
    echo "  (none)"
fi

echo
if [[ "$drift" -eq 0 ]]; then
    echo "No drift — installed packages match the Brewfile."
else
    echo "Drift found. Add the lines above to $BREWFILE (or the commented decide-block at its end)."
fi
exit "$drift"
