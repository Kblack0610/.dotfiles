#!/usr/bin/env bash
# Shrink the cargo cache main saves (tests.yml "Save cargo") to what a later run reuses.
#
# Every pull request that picks a crate restores that cache: 879 MB, about 53 s to download and
# 90 s to unpack on the pool, more than the Rust gate itself (ar-4235, 2026-11-26). Two parts of it
# never serve a later run:
# - this repo's own crates' artifacts (deps, .fingerprint, build, the uplifted binaries): a fresh
#   checkout's mtimes make cargo rebuild them on every run;
# - .cargo-ci/registry/src, the unpacked crate sources: cargo unpacks them again from
#   registry/cache's .crate files when it needs one.
# Third-party dependency artifacts stay; they are what the cache is for.
#
# Usage: tests/cargo-prune.sh [repo]   (default: the current directory)
set -euo pipefail
shopt -s nullglob

cd "${1:-.}"
# Best effort: the sizes are only the log line, so a du error never stops the prune.
size() { { du -sm .cargo-ci .local/src/*/target 2>/dev/null || true; } | awk '{ s += $1 } END { print s + 0 }'; }
before=$(size)

# Every name cargo gives an artifact of ours: each package and each [lib], [[bin]], [[test]],
# [[bench]] and [[example]] target, in a crate root or a workspace member (timebox's crates/*), and
# each tests/*.rs and src/bin/*.rs file there, which cargo names after the file. Only those
# directories are read, so a fixture manifest deeper down names nothing. A dependency that shares
# a name only gets rebuilt: cargo rebuilds an artifact whose output is gone.
manifests=(.local/src/*/Cargo.toml .local/src/*/crates/*/Cargo.toml)
targets=(.local/src/*/{,crates/*/}{tests,src/bin}/*.rs)
mapfile -t names < <({
  [ "${#manifests[@]}" -eq 0 ] || awk '/^\[/ { sec = $0 }
    sec ~ /^\[(package|lib|\[(bin|test|bench|example)\])\]/ && match($0, /^name *= *"[^"]+"/) {
      v = substr($0, RSTART, RLENGTH); sub(/^name *= *"/, "", v); sub(/"$/, "", v); print v }' "${manifests[@]}"
  for f in "${targets[@]}"; do f=${f##*/}; echo "${f%.rs}"; done
} | sort -u)
[ "${#names[@]}" -gt 0 ] || { echo "cargo-prune: no crate found under .local/src" >&2; exit 1; }

# A cargo metadata hash is 16 hex digits, so the exact-length glob cannot take a dependency whose
# name only starts with one of ours (hub-core-foo-<hash> is longer).
h='????????????????'
for prof in .local/src/*/target/{debug,release}; do
  [ -d "$prof" ] || continue
  find "$prof" -maxdepth 1 -type f -delete
  rm -rf "$prof/examples" "$prof/incremental"
  for n in "${names[@]}"; do
    u=${n//-/_}
    rm -rf "$prof/.fingerprint/$n-"$h "$prof/build/$n-"$h
    rm -f "$prof/deps/$u-"$h "$prof/deps/$u-"$h.* "$prof/deps/lib$u-"$h.*
  done
done
rm -rf .cargo-ci/registry/src

echo "cargo-prune: the artifacts of ${#names[@]} names of ours and registry/src gone, ${before} MB -> $(size) MB"
