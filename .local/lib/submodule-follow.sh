# shellcheck shell=bash
# submodule-follow.sh - after a merge moves submodule pins, move the checkouts still on the old ones.
#
#   submodule_follow <old-rev> [<new-rev>]    run in the superproject; <new-rev> defaults to HEAD
#
# A merge updates the gitlinks but not the submodule checkouts, so a local build after it reads the
# old code. Why: agent-land's catch_up merged 42 commits into ucp-671 PR #2506 and the next
# compile-check failed with CS0117 against a stale External/unity-core. For each submodule whose pin
# the two revs change: an uninitialized one is skipped; a checkout already on the new pin is left;
# one on the old pin with no tracked changes moves to the new pin (`git submodule update
# --checkout`, which fetches the commit when it is missing); a dirty one, or one on any other
# commit, is somebody's work and stays where it is. One "submodule:" line for each one moved or
# left; it always returns 0, so a caller never fails on it.
submodule_follow() {
  local old=$1 new=${2:-HEAD} meta path omode nmode osha nsha at out
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r omode nmode osha nsha _ <<<"${meta#:}"
    [ "$omode $nmode" = '160000 160000' ] && [ -e "$path/.git" ] || continue
    at=$(git -C "$path" rev-parse -q --verify HEAD 2>/dev/null) || at=unknown
    [ "$at" != "$nsha" ] || continue
    if [ "$at" != "$osha" ]; then
      echo "submodule: left $path on ${at:0:8}, neither the old pin ${osha:0:8} nor the new ${nsha:0:8}: move it by hand (git -C $path checkout $nsha)"
    elif [ -n "$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      echo "submodule: left $path on the old pin ${osha:0:8}: it has uncommitted changes (git -C $path status); the new pin is ${nsha:0:8}"
    elif out=$(git submodule update --quiet --checkout -- "$path" 2>&1); then
      echo "submodule: moved $path from ${osha:0:8} to the new pin ${nsha:0:8}"
    else
      echo "submodule: left $path on the old pin ${osha:0:8}: git submodule update failed: $(printf '%s' "$out" | tail -n 1)"
    fi
  done < <(git diff --raw -z --no-abbrev --no-renames --diff-filter=M "$old" "$new" 2>/dev/null)
  return 0
}
