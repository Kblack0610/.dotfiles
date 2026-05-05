#!/bin/bash
# One-shot janitor: move stale ~/.agent/plans/ subdirs into _archive/.
# Idempotent. Interactive by default; --yes for non-interactive.
#
# A subdir is "stale" if its newest *.md (recursive) is older than $STALE_DAYS.

set -uo pipefail

PLANS_DIR="$HOME/.agent/plans"
ARCHIVE_DIR="$PLANS_DIR/_archive"
STALE_DAYS="${STALE_DAYS:-60}"
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      echo "Usage: $0 [--yes]"
      echo "  STALE_DAYS=$STALE_DAYS (override via env)"
      exit 0 ;;
  esac
done

[ -d "$PLANS_DIR" ] || { echo "no plans dir: $PLANS_DIR"; exit 0; }
mkdir -p "$ARCHIVE_DIR"

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf "%s [y/N] " "$1" >&2
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# 1. Stale subdirs
echo "=== scanning $PLANS_DIR for subdirs untouched > ${STALE_DAYS}d ==="
for d in "$PLANS_DIR"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  case "$name" in _archive) continue ;; esac

  newest=$(find "$d" -type f -name '*.md' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  if [ -z "$newest" ]; then
    echo "  $name: (empty / no .md) -> archive candidate"
  else
    age_days=$(awk -v t="$newest" 'BEGIN{print int((systime()-t)/86400)}')
    if [ "$age_days" -gt "$STALE_DAYS" ]; then
      echo "  $name: newest .md is ${age_days}d old -> archive candidate"
    else
      echo "  $name: newest .md is ${age_days}d old, keep"
      continue
    fi
  fi

  if confirm "    move $name -> _archive/$name ?"; then
    mv "$d" "$ARCHIVE_DIR/$name"
  fi
done

# 2. Loose .md files at the root
shopt -s nullglob
loose=("$PLANS_DIR"/*.md)
shopt -u nullglob
if [ "${#loose[@]}" -gt 0 ]; then
  echo "=== loose .md files at root ==="
  printf '  %s\n' "${loose[@]}"
  if confirm "  move all -> _archive/_root/ ?"; then
    mkdir -p "$ARCHIVE_DIR/_root"
    mv "${loose[@]}" "$ARCHIVE_DIR/_root/"
  fi
fi

# 3. Special case: .dotfiles -> dotfiles
if [ -d "$PLANS_DIR/.dotfiles" ]; then
  echo "=== merge .dotfiles/ into dotfiles/ ==="
  if confirm "  move .dotfiles/* into dotfiles/ ?"; then
    mkdir -p "$PLANS_DIR/dotfiles"
    # shellcheck disable=SC2012
    if [ -n "$(ls -A "$PLANS_DIR/.dotfiles" 2>/dev/null)" ]; then
      mv "$PLANS_DIR/.dotfiles"/* "$PLANS_DIR/dotfiles"/ 2>/dev/null || true
    fi
    rmdir "$PLANS_DIR/.dotfiles" 2>/dev/null || true
  fi
fi

echo "=== done ==="
