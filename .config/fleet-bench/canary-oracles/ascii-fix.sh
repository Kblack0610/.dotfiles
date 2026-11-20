#!/usr/bin/env bash
# fleet-bench canary oracle: a plain-ASCII fix of one file, at a pinned base. fleet-bench pipes this on stdin
# (`bash -s -- <file> <base> <lines>`), so the session being scored never sees it and cannot edit it.
# The answer key: only <file> changed since <base>; it holds no non-ASCII byte; git diff --numstat is
# <lines> <lines>; and each changed line keeps its words (runs of [A-Za-z0-9_]), so a dash to a comma or a
# key glyph to Ctrl+Cmd+M passes. The key-name words below are dropped from both sides, because a glyph
# has no words of its own and its ASCII spelling adds them.
file=$1 base=$2 n=$3
fail() { echo "oracle: $*" >&2; exit 1; }
keys='Ctrl|Cmd|Opt|Shift|Alt'

# Inside the lane jail, srt masks its protected names (.profile, .mcp.json, .idea ...) with character devices
# that git lists as untracked; a device is no file the session wrote, so it is skipped.
changed=$({ git diff --name-only "$base"; git ls-files --others --exclude-standard | while IFS= read -r p; do [ -c "$p" ] || printf '%s\n' "$p"; done; })
[ "$changed" = "$file" ] || fail "changed files are not only $file: $(tr '\n' ' ' <<<"$changed")"

if LC_ALL=C grep -nP '[^\x00-\x7F]' "$file"; then fail "$file still has non-ASCII bytes"; fi

stat=$(git diff --numstat "$base" -- "$file")
[ "$stat" = "$(printf '%s\t%s\t%s' "$n" "$n" "$file")" ] || fail "numstat is '$stat', want $n $n"

diff=$(git diff -U0 --no-color "$base" -- "$file")
mapfile -t old < <(awk '/^@@/ {h = 1; next} h && /^-/ {print substr($0, 2)}' <<<"$diff")
mapfile -t new < <(awk '/^@@/ {h = 1; next} h && /^\+/ {print substr($0, 2)}' <<<"$diff")
[ "${#old[@]}" = "$n" ] && [ "${#new[@]}" = "$n" ] || fail "${#old[@]} lines removed and ${#new[@]} added, want $n each"
words() { grep -oE '[A-Za-z0-9_]+' <<<"$1" | grep -vxE "$keys" | tr '\n' ' '; true; }
for i in "${!old[@]}"; do
  [ "$(words "${old[i]}")" = "$(words "${new[i]}")" ] || fail "the words changed on line $((i + 1)) of the diff: ${old[i]} -> ${new[i]}"
done
