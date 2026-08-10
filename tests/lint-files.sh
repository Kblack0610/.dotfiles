#!/usr/bin/env bash
# Emit the list of shell files shellcheck should lint, one per line.
#
# Single source of truth for both `make -C tests lint` and the CI lint job. Without it the
# two drift, and a lint gate that passes locally but fails in CI (or the reverse) gets
# ignored within a week.
#
# WHY SELECTION IS NOT `git ls-files '*.sh' '*.bash'`
# ---------------------------------------------------
# It was, until 2026-08-09, and that meant the gate had NEVER linted the scripts people
# actually run. Almost everything in .local/bin/ is deliberately EXTENSIONLESS, because the
# extension would be part of the command a human types: agentctl, dotfiles-drift,
# dotfiles-deploy, ticket, sessions, agent-ask, agent-notify, wt, tmx, skill-deploy, and
# ~70 more. None of them matched '*.sh', so none of them was ever checked - locally or in
# CI - while the gate printed "shellcheck: clean at severity=error (153 files)" and everyone
# read that as "the tree is clean". It was clean over the half of the tree nobody runs.
#
# That is the house failure mode written down in tests/lint.sh and the shell-test-harness
# skill: "nothing to check" and "everything passed" print the same green. An input list
# that silently under-selects is the same disease as one that comes back empty, just harder
# to notice, because 153 looks like a real number.
#
# So a file is selected if it is a shell script by EXTENSION *or* by SHEBANG.
#
# THE FILTER IS NOT COSMETIC
# --------------------------
# The linter supports sh/bash/dash/ksh only and reports SC1071 as an ERROR on anything
# else, so a single zsh script in the tree would fail the whole gate with nothing to fix.
# (That sentence deliberately does not open with the tool's name: a comment whose first
# word after `#` is that name is parsed as a shellcheck DIRECTIVE, and this file linting
# itself found that out - SC1072/SC1073, an error, in a prose paragraph.) The
# shebang test therefore runs as an ALLOWLIST of sh-family interpreters, not as "has a
# shebang": the tree also carries ruby, python3 and bats scripts, and 60 of those .bats
# files would each be an SC1071 error the moment selection got sloppy. A new zsh (or ruby,
# or python) script is handled automatically instead of breaking CI for whoever adds it.
#
# CARE ITEMS
# ----------
#   * `git ls-files` lists the INDEX, which can name paths that are not in the working tree
#     (a deleted-but-unstaged file, a sparse checkout, a submodule gitlink). Reading a
#     shebang needs the file to be present and readable, so both are tested first and a
#     missing path is skipped rather than being an error.
#   * The first line is read with the bash `read` builtin, not `head -1`. At ~1500 tracked
#     files a subprocess each is seconds of wall clock on every lint run and every Stop
#     hook; the builtin is one open() and costs nothing. It also cannot be confused by a
#     binary file, since it stops at the first newline and we only ever pattern-match the
#     result.
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

# Interpreters shellcheck can actually parse. Anything else - zsh, fish, tcsh, ruby,
# python3, bats, perl, node - is not a shellcheck subject and must not be selected.
is_shell_interp() {
  case "$1" in
    sh|bash|dash|ksh|ksh93|mksh|pdksh|ash|busybox) return 0 ;;
    *) return 1 ;;
  esac
}

# shebang_is_shell <first-line> - does this line name an sh-family interpreter?
#
# Handles the three forms in this tree plus the portable one:
#   #!/bin/bash                  -> bash
#   #!/usr/bin/env bash          -> bash        (env: the interpreter is the next word)
#   #!/usr/bin/env -S bash -eu   -> bash        (env -S, with flags)
#   #!/bin/sh -e                 -> sh          (flags after the interpreter)
shebang_is_shell() {
  local line="$1" word
  case "$line" in '#!'*) ;; *) return 1 ;; esac
  line="${line#\#!}"
  line="${line%$'\r'}"   # tolerate a CRLF checkout
  # shellcheck disable=SC2086  # deliberate word splitting: that is how a shebang is parsed
  set -- $line
  [ $# -gt 0 ] || return 1
  word="${1##*/}"
  if [ "$word" = env ]; then
    shift
    # Skip env's own options, including `-S <command>` and any NAME=VALUE assignments.
    while [ $# -gt 0 ]; do
      case "$1" in
        -S|--split-string) shift ;;
        -*) shift ;;
        *=*) shift ;;
        *) break ;;
      esac
    done
    [ $# -gt 0 ] || return 1
    word="${1##*/}"
  fi
  is_shell_interp "$word"
}

n=0
while IFS= read -r -d '' f; do
  # Index entries with no readable file behind them: deleted-but-unstaged, sparse checkout,
  # submodule gitlink. Not an error - just nothing to lint.
  [ -f "$f" ] && [ -r "$f" ] || continue

  first=""
  IFS= read -r first < "$f" 2>/dev/null || true

  # An explicit non-shellcheck shebang wins over the extension, so a `.sh` file that is
  # really zsh still gets skipped rather than failing the gate with SC1071.
  case "$first" in
    '#!'*)
      shebang_is_shell "$first" || continue
      printf '%s\n' "$f"
      n=$((n + 1))
      continue
      ;;
  esac

  # No shebang at all: fall back to the extension. This is what keeps sourced fragments
  # (lib/*.sh, tests/helpers/*.bash) in the list - they have no shebang by design.
  case "$f" in
    *.sh|*.bash)
      printf '%s\n' "$f"
      n=$((n + 1))
      ;;
  esac
done < <(git ls-files -z)

# Same reasoning as the git guard above, one layer in: if the walk produced nothing, the
# selection logic broke, not the tree. Callers check this too (tests/lint.sh), but a
# producer that can emit a vacuously-clean list should refuse to.
[ "$n" -gt 0 ] || {
  echo "lint-files: selected ZERO files out of $(git ls-files | wc -l) tracked - that is a bug here, not a clean tree" >&2
  exit 1
}
