#!/usr/bin/env bash
# Emit the list of shell files shellcheck should lint, one per line.
#
# Single source of truth for both `make -C tests lint` and the CI lint job. Without it the
# two drift, and a lint gate that passes locally but fails in CI (or the reverse) gets
# ignored within a week.
#
# The filter is not cosmetic: shellcheck supports sh/bash/dash/ksh only and reports SC1071
# as an ERROR on anything else, so a single zsh script in the tree would fail the whole gate
# with nothing to fix. Selection is by SHEBANG rather than by a hardcoded path list, so a
# new zsh script is handled automatically instead of breaking CI for whoever adds it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Fail LOUDLY when git cannot answer, instead of emitting an empty list.
#
# An empty list makes the lint gate pass vacuously - it reports "clean" having checked
# nothing - which is strictly worse than no gate at all. This is not hypothetical: run the
# suite from a git WORKTREE inside the container and `.git` is a file pointing at a path
# outside the bind mount, so `git ls-files` fails and every file silently disappears.
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "lint-files: not a usable git repository from $PWD" >&2
  echo "  (in a container, a git worktree needs its parent .git dir mounted too)" >&2
  exit 1
}

git ls-files '*.sh' '*.bash' | while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$(head -1 "$f")" in
    *zsh*|*fish*|*csh*) continue ;;
  esac
  printf '%s\n' "$f"
done
