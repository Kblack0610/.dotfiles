#!/usr/bin/env bash
# image-kind.sh - the test image stage a fast shard needs: `tools` if any of its files runs bun or nvim, else `lean`.
#
#   image-kind.sh <file>...      files relative to tests/ (the shard's list, as shard.sh prints it)
#   image-kind.sh -              the same list on stdin
#
# Why: the lean stage (tests/Dockerfile) leaves out bun, nvim and npm, 86 of its 218 MB (npm is not matched: a file that ran it would fail loudly, not skip), because 22 of
# a run's 24 unit shards have no file that runs them, and every shard pulls its image from the pool
# registry's one link (ar-5970). A file that needs one of them starts it by a name this matches:
# a `command -v` or `need_nvim` guard, `bun test`, `nvim --headless`. unit/image_kind.bats checks that every
# file whose skip or fail line names nvim or bun matches, because a file that matched nothing would
# skip on CI and pass a gate that tested nothing. A file that only mentions nvim (a stub, a string) may
# match too: the cost of a false `tools` is a bigger pull, never a missed test.
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ $# -ge 1 ] || { echo "usage: image-kind.sh <file>... | -" >&2; exit 2; }
if [ "$1" = - ]; then
  mapfile -t files
else
  files=("$@")
fi

# One pattern, the place to teach a new tool. `bun` and `nvim` as words only.
NEEDS='(command -v|type -P|which|hash) +"?[$]?(nvim|bun|NVIM|BUN)\b|-x +[^ ]*(nvim|bun)\b|need_nvim|have_(nvim|bun)|\bbunx?( +(test|run|x))?\b +[^ ]*[.]ts|\bbun +(test|run|x)\b|\bnvim +(--headless|-l|-u|-es|-c)\b'

kind=lean
for f in "${files[@]}"; do
  [ -n "$f" ] || continue
  [ -r "$DIR/$f" ] || { echo "image-kind.sh: cannot read $DIR/$f" >&2; exit 2; }
  if grep -qE "$NEEDS" "$DIR/$f"; then
    kind=tools
    break
  fi
done
echo "$kind"
