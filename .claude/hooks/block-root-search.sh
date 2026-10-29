#!/usr/bin/env bash
# PreToolUse guard: deny a recursive search whose root contains a network mount.
# 2026-10-29 three sessions ran Grep/Glob from `/`; the bundled ugrep and bfs walked into
# /mnt/nas (CIFS) and crawled the photo library and its snapshots for 25-43 minutes. About
# 15 threads sat blocked on the share, load 28 on 24 cores with every process at 0% CPU.
# A search inside the share (a subdirectory of the mount) is deliberate and stays allowed.
set -uo pipefail

MOUNTS="${ROOT_SEARCH_MOUNTS:-/proc/mounts}"
INPUT=$(cat)
TOOL=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null) || exit 0
CWD=$(jq -r '.cwd // empty' <<<"$INPUT")

net_mounts() { awk '$3 ~ /^(cifs|smb3|nfs|nfs4|fuse\.sshfs|autofs)$/ { print $2 }' "$MOUNTS" 2>/dev/null | sort -u; }

# covered <path> -> prints the first network mount a walk from path reaches; false if none.
# Lexical only (realpath -s): resolving the path would stat it and wake the automount.
covered() {
  local p="$1" m
  case "$p" in "~"*) p="$HOME${p#\~}" ;; /*) ;; *) p="${CWD:-$PWD}/$p" ;; esac
  p="$(realpath -m -s -- "$p" 2>/dev/null)" || return 1
  while read -r m; do
    [ -n "$m" ] || continue
    if [ "$p" = / ] || [ "$p" = "$m" ] || [[ "$m" == "$p"/* ]]; then echo "$m"; return 0; fi
  done < <(net_mounts)
  return 1
}

deny() {
  jq -nc --arg r "Search from the repo or worktree root, or a named subdirectory, not \`$1\`: it contains the network mount \`$2\`, and a recursive walk there blocks on the share for tens of minutes and loads the whole machine. To search the share, name a subdirectory of it." \
    '{hookSpecificOutput: {hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
  exit 0
}

# glob_root <pattern> -> the directory part before the first wildcard component.
glob_root() {
  local out="" c
  IFS=/ read -ra parts <<<"$1"
  for c in "${parts[@]}"; do
    case "$c" in *['*?[{']*) break ;; esac
    out+="$c/"
  done
  echo "${out:-/}"
}

check_bash() {
  local clause tok cmd recursive onefs
  local -a toks
  # One clause per line: a search hidden behind `&&`, a pipe or `$(` is still a search.
  while IFS= read -r clause; do
    read -ra toks <<<"$(tr -d "\"'" <<<"$clause")"
    cmd=""; recursive=0; onefs=0
    for tok in "${toks[@]}"; do
      if [ -z "$cmd" ]; then
        case "${tok##*/}" in
          find|bfs|fd|fdfind|rg|ugrep) cmd="${tok##*/}"; recursive=1 ;;
          grep|egrep) cmd='grep' ;;
        esac
        continue
      fi
      case "$tok" in
        -xdev|-mount|--one-file-system) onefs=1 ;;
        --recursive|--dereference-recursive) recursive=1 ;;
        --*) ;;
        -*[rR]*) [ "$cmd" = grep ] && recursive=1 ;;
      esac
    done
    [ -n "$cmd" ] && [ "$recursive" = 1 ] && [ "$onefs" = 0 ] || continue
    local prev="" m
    for tok in "${toks[@]}"; do
      # find/bfs: a path after a primary (`-path /mnt`, `-newer /x`) is its argument, not a root.
      if [[ "$cmd" =~ ^(find|bfs)$ && "$prev" == -* ]]; then prev="$tok"; continue; fi
      prev="$tok"
      case "$tok" in /*|"~"*) ;; *) continue ;; esac
      m="$(covered "$tok")" && deny "$tok" "$m"
    done
  done < <(sed -E 's/(&&|\|\||;|\||\$\(|`|\(|\))/\n/g' <<<"$1")
}

case "$TOOL" in
  Grep|Glob)
    path=$(jq -r '.tool_input.path // empty' <<<"$INPUT")
    if [ -n "$path" ] && m="$(covered "$path")"; then deny "$path" "$m"; fi
    pattern=$(jq -r '.tool_input.pattern // empty' <<<"$INPUT")
    if [ "$TOOL" = Glob ] && [[ "$pattern" == /* ]]; then
      root="$(glob_root "$pattern")"
      if m="$(covered "$root")"; then deny "$root" "$m"; fi
    fi
    ;;
  Bash)
    check_bash "$(jq -r '.tool_input.command // empty' <<<"$INPUT")"
    ;;
esac
exit 0
