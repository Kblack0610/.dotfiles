#!/bin/bash
# Build meeting-status (Swift/EventKit helper for the SketchyBar meeting bar) and link it
# onto PATH. macOS-only; needs the Xcode command-line tools (`swiftc`).
#   ./build.sh        compile + symlink ~/.local/bin/meeting-status → here
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/meeting-status"
swiftc -O "$DIR/meeting-status.swift" -o "$OUT"
mkdir -p "$HOME/.local/bin"
ln -sf "$OUT" "$HOME/.local/bin/meeting-status"
echo "built + linked: $HOME/.local/bin/meeting-status"
