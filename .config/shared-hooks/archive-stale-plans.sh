#!/bin/bash
# One-shot janitor: move stale ~/.agent/plans/ subdirs into _archive/, and finished plans out of
# the _live store into _archive/_live/. Idempotent. Interactive by default; --yes for non-interactive.
#
# A subdir is "stale" if its newest *.md (recursive) is older than $STALE_DAYS. A _live plan is
# finished when every phase of its checklist is done (plan_left, .local/lib/plan-phases.sh) and it
# has not changed in $LIVE_DAYS.

set -uo pipefail

PLANS_DIR="$HOME/.agent/plans"
ARCHIVE_DIR="$PLANS_DIR/_archive"
STALE_DAYS="${STALE_DAYS:-60}"
LIVE_DAYS="${LIVE_DAYS:-14}"
LIVE_DIR="$PLANS_DIR/_live"
# shellcheck source=../../.local/lib/plan-phases.sh
. "${PLAN_PHASES_LIB:-$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../.local/lib/plan-phases.sh}"
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      echo "Usage: $0 [--yes]"
      echo "  STALE_DAYS=$STALE_DAYS LIVE_DAYS=$LIVE_DAYS (override via env)"
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
  case "$name" in _*) continue ;; esac   # _archive, and _live, the plan store itself

  # -L: a project entry is a link into _live, and its age is the plan's.
  newest=$(find -L "$d" -type f -name '*.md' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
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

  [ -e "$ARCHIVE_DIR/$name" ] && { echo "    _archive/$name exists, left as is"; continue; }
  if confirm "    move $name -> _archive/$name ?"; then
    mv "${d%/}" "$ARCHIVE_DIR/$name" || continue
    # One level deeper now, so each relative link into _live gains a ../ to still reach the store.
    find "$ARCHIVE_DIR/$name" -type l -lname '../_live/*' 2>/dev/null | while IFS= read -r l; do
      ln -sfn "../$(readlink "$l")" "$l"
    done
  fi
done

# 2. Finished plans in _live. Its links move with it: a project entry (../_live/<name>) goes, since
# the project's list is its open work; an archived project's entry (../../_live/<name>) drops a ../
# to reach _archive/_live; an alias in _live itself moves along beside its plan.
if [ -d "$LIVE_DIR" ]; then
  echo "=== scanning _live for finished plans untouched > ${LIVE_DAYS}d ==="
  # fd 3 carries the list, so confirm still reads the terminal on stdin.
  while IFS= read -r -d '' f <&3; do
    [ "$(plan_left "$f")" = 0 ] || continue
    name=$(basename "$f")
    [ -e "$ARCHIVE_DIR/_live/$name" ] && { echo "  _archive/_live/$name exists, left as is"; continue; }
    confirm "  move _live/$name -> _archive/_live/ ?" || continue
    mkdir -p "$ARCHIVE_DIR/_live"
    mv "$f" "$ARCHIVE_DIR/_live/$name" || continue
    echo "  archived _live/$name"
    find "$PLANS_DIR" -mindepth 2 -maxdepth 2 ! -path "$PLANS_DIR/_*" -type l -lname "../_live/$name" -delete
    find "$ARCHIVE_DIR" -mindepth 2 -maxdepth 2 -type l -lname "../../_live/$name" -exec ln -sfn "../_live/$name" {} \;
    while IFS= read -r -d '' a <&4; do
      [ -e "$ARCHIVE_DIR/_live/${a##*/}" ] && continue
      mv "$a" "$ARCHIVE_DIR/_live/" && ln -sfn "$name" "$ARCHIVE_DIR/_live/${a##*/}"
    done 4< <(find "$LIVE_DIR" -maxdepth 1 -type l \( -lname "$name" -o -lname "$LIVE_DIR/$name" \) -print0)
  done 3< <(find "$LIVE_DIR" -maxdepth 1 -type f -name '*.md' -mtime +"$LIVE_DAYS" -print0 | sort -z)
fi

# 3. Loose .md files at the root
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

# 4. Special case: .dotfiles -> dotfiles
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
