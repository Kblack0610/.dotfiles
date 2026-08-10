#!/usr/bin/env bash
# Emit the list of Rust crate ROOTS cargo should be run in, one per line.
#
# Sibling of lint-files.sh, and the same single-source-of-truth argument: both
# `make -C tests test-rust` and the CI rust job read this, so the two cannot drift.
#
# ROOTS, not every Cargo.toml. `.local/src/timebox` is a workspace whose members
# (crates/timebox-core, crates/timebox-cli) each carry their own Cargo.toml. Running
# cargo in a member directory works but re-tests the workspace once per member, and a
# member of a workspace has no independent lockfile -- so the roots are the correct
# unit. A path is a root when no OTHER tracked Cargo.toml sits above it.
#
# Selection is by `git ls-files`, which means target/ is excluded for free (gitignored)
# and a newly added crate is picked up with no edit here.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Fail LOUDLY when git cannot answer, instead of emitting an empty list -- same failure
# mode lint-files.sh documents: from a git worktree inside the container, `.git` is a file
# pointing outside the bind mount, `git ls-files` fails, and every crate silently
# disappears. A gate that checked nothing must not report success.
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "rust-crates: not a usable git repository from $PWD" >&2
  echo "  (in a container, a git worktree needs its parent .git dir mounted too)" >&2
  exit 1
}

mapfile -t manifests < <(git ls-files '*Cargo.toml' | sort)

for m in "${manifests[@]}"; do
  dir="${m%/Cargo.toml}"
  nested=0
  for other in "${manifests[@]}"; do
    parent="${other%/Cargo.toml}"
    [ "$parent" = "$dir" ] && continue
    # Trailing slash so `.../timebox` matches `.../timebox/crates/x` but never
    # a sibling like `.../timebox-extra`.
    case "$dir/" in "$parent"/*) nested=1; break ;; esac
  done
  [ "$nested" = 1 ] || printf '%s\n' "$dir"
done
