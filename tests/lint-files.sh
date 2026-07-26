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

cd "$(dirname "${BASH_SOURCE[0]}")/.."

git ls-files '*.sh' '*.bash' | while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$(head -1 "$f")" in
    *zsh*|*fish*|*csh*) continue ;;
  esac
  printf '%s\n' "$f"
done
