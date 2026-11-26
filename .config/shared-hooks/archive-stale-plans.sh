#!/bin/bash
# One-shot janitor: move stale ~/.agent/plans/ subdirs into _archive/, and finished plans out of
# the _live store into _archive/_live/. Idempotent. Interactive by default; --yes for non-interactive.
#
# A subdir is "stale" if its newest *.md (recursive) is older than $STALE_DAYS. A _live plan is
# finished when every phase of its checklist is done (plan_left, .local/lib/plan-phases.sh: deferred
# phases and a superseded plan count as done) and it has not changed in more than $LIVE_DAYS days.
# A plan with a phase still open and no change in $LIVE_DAYS days is only listed, with the count.

set -uo pipefail

PLANS_DIR="$HOME/.agent/plans"
ARCHIVE_DIR="$PLANS_DIR/_archive"
STALE_DAYS="${STALE_DAYS:-60}"
LIVE_DAYS="${LIVE_DAYS:-14}"
LIVE_DIR="$PLANS_DIR/_live"
# shellcheck source=../../.local/lib/plan-phases.sh
. "${PLAN_PHASES_LIB:-$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../.local/lib/plan-phases.sh}" \
  || { echo "archive-stale-plans: cannot load plan-phases.sh" >&2; exit 1; }
case "$LIVE_DAYS" in ''|*[!0-9]*) echo "archive-stale-plans: LIVE_DAYS must be a whole number" >&2; exit 1 ;; esac
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
  echo "=== scanning _live for finished plans untouched more than ${LIVE_DAYS}d ==="
  # fd 3 carries the list, so confirm still reads the terminal on stdin.
  while IFS= read -r -d '' f <&3; do
    [ "$(plan_left "$f")" = 0 ] || continue
    name=$(basename "$f") dest="$ARCHIVE_DIR/_live/$(basename "$f")"
    { [ -e "$dest" ] || [ -L "$dest" ]; } && { echo "  _archive/_live/$name exists, left as is"; continue; }
    confirm "  move _live/$name -> _archive/_live/ ?" || continue
    mkdir -p "$ARCHIVE_DIR/_live"
    mv "$f" "$dest" || continue
    echo "  archived _live/$name"
    # Links are matched by exact readlink, never a find pattern, so a name's glob characters match only themselves.
    for l in "$PLANS_DIR"/[!_]*/"$name"; do
      [ -L "$l" ] && [ "$(readlink "$l")" = "../_live/$name" ] && rm -f "$l"
    done
    for l in "$ARCHIVE_DIR"/*/"$name"; do
      [ -L "$l" ] && [ "$(readlink "$l")" = "../../_live/$name" ] && ln -sfn "../_live/$name" "$l"
    done
    for a in "$LIVE_DIR"/*; do
      [ -L "$a" ] || continue
      case "$(readlink "$a")" in "$name"|"$LIVE_DIR/$name") ;; *) continue ;; esac
      if [ -e "$ARCHIVE_DIR/_live/${a##*/}" ] || [ -L "$ARCHIVE_DIR/_live/${a##*/}" ]; then
        ln -sfn "../_archive/_live/$name" "$a"   # its name is taken there: it stays, still reaching the plan
      else
        mv "$a" "$ARCHIVE_DIR/_live/" && ln -sfn "$name" "$ARCHIVE_DIR/_live/${a##*/}"
      fi
    done
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

# 5. Idle plans: a phase still open and untouched more than $LIVE_DAYS days, anywhere but _archive.
# Listed, never moved: ticking a landed phase and marking the rest `[-]` with its row (planning.md,
# Phases) is a judgment, and once every phase is done step 2 archives a _live plan.
echo "=== open plans untouched more than ${LIVE_DAYS}d (tick, mark [-] with a row, or supersede) ==="
idle=0
while IFS= read -r -d '' f; do
  left=$(plan_left "$f")
  case "$left" in -|0) continue ;; esac
  m=$(stat -c %Y "$f" 2>/dev/null) || continue   # gone since the find
  idle=$((idle + 1))
  echo "  $(( ($(date +%s) - m) / 86400 ))d  $left open  ${f#"$PLANS_DIR"/}"
done < <(find "$PLANS_DIR" -path "$ARCHIVE_DIR" -prune -o -type f -name '*.md' -mtime +"$LIVE_DAYS" -print0 \
  | xargs -0r grep -lZ '^## Phases' | sort -z)
echo "  idle plans: $idle"

echo "=== done ==="
