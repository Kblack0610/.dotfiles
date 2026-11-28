# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# frontmatter.sh - the one reader and writer of a `key: value` header: an agent-queue item, an ask, a hold.
#
#   fm_get <file> <key>                         the first value of the key in the header; nothing when it is absent
#   fm_set <file> <key> <value> [<key> <value>...]   those keys in one atomic, locked rewrite
#
# The header is every line up to the first `---` line, or the whole file when it has none (a caller whose
# file is flat, an ask or a hold, sets FM_FLAT=1 so a value line of `---` ends nothing in fm_set). fm_get reads
# the file by redirect, never as an awk operand: awk reads stdin for an empty operand, and a caller whose
# lookup came back empty hung on the tool shell's open stdin (ar-3455).
#
# fm_set replaces a key in place (the first line; a later repeat is dropped), appends a new key at the
# end of the header, and keeps every other line. A value is taken as it is, a backslash included. It
# writes a temp file beside the target and renames it, so a reader sees the old file or the new one. It
# fails, writing nothing, for a file that is gone (a released hold is never brought back); for a value that
# spans lines, or a key that is not one word, it refuses with status 2, and a caller that defines `die` exits through it.
#
# The rewrite runs under flock on FM_LOCK (default: `.lock` in the file's directory), waiting for
# it with no bound, or FM_LOCK_WAIT seconds when set: two unlocked rewrites lose whichever finished first. A caller that
# already holds the lock for its own writes (agent-queue's queue lock, an ask's per-project lock) sets
# FM_LOCKED=1: flock on a second descriptor of a file the caller holds would wait on the caller itself.

fm_get() { # file key
  awk -v k="$2" '$0 == "---" { exit }
    index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^ +/, "", v); print v; exit }' 2>/dev/null <"$1"
}

_fm_fail() { echo "fm_set: $1" >&2; return 1; }

# _fm_refuse <why>: a call wrong as made (a bad key, a value of several lines); a caller that defines `die` exits through it.
_fm_refuse() {
  if declare -F die >/dev/null 2>&1; then die "$1"; fi
  _fm_fail "$1"
  return 2
}

# _fm_write <file> <key> <value>...: the rewrite, with the lock already settled.
_fm_write() {
  local f="$1" tmp
  shift
  [ -f "$f" ] || { _fm_fail "no such file: $f"; return; }
  tmp="$(mktemp "$(dirname "$f")/.${f##*/}.XXXXXX")" || { _fm_fail "cannot write in $(dirname "$f")"; return; }
  # The pairs ride in ARGV, which awk takes raw: -v would read a backslash in a value as an escape.
  # The file comes in on stdin, so no operand is left to be mistaken for a var=value assignment.
  awk -v flat="${FM_FLAT-}" '
    function flush(  i) { for (i = 1; i <= n; i++) if (!(k[i] in done)) { print k[i] ": " v[k[i]]; done[k[i]] = 1 } }
    BEGIN {
      n = (ARGC - 1) / 2
      for (i = 1; i <= n; i++) { k[i] = ARGV[2 * i - 1]; v[k[i]] = ARGV[2 * i]; ARGV[2 * i - 1] = ARGV[2 * i] = "" }
      ARGC = 1
    }
    !flat && !body && $0 == "---" { flush(); body = 1 }
    !body {
      for (i = 1; i <= n; i++) if (index($0, k[i] ":") == 1) {
        if (!(k[i] in done)) { print k[i] ": " v[k[i]]; done[k[i]] = 1 }
        next
      }
    }
    { print }
    END { if (!body) flush() }
  ' "$@" <"$f" >"$tmp" && mv -- "$tmp" "$f" || { rm -f -- "$tmp"; _fm_fail "cannot rewrite $f"; return; }
}

fm_set() { # file key value [key value]...
  local f="${1-}" i lw=()
  if [ $# -lt 3 ] || [ $((($# - 1) % 2)) -ne 0 ]; then _fm_refuse "usage: fm_set <file> <key> <value> [<key> <value>...]"; return; fi
  for ((i = 2; i <= $#; i += 2)); do
    case "${!i}" in '' | *[[:space:]:]*) _fm_refuse "not a header key: ${!i}"; return ;; esac
    case "${@:i+1:1}" in *$'\n'*) _fm_refuse "a value cannot span lines: ${!i}"; return ;; esac
  done
  [ -z "${FM_LOCKED-}" ] || { _fm_write "$@"; return; }
  [ -z "${FM_LOCK_WAIT-}" ] || lw=(-w "$FM_LOCK_WAIT")
  (
    command -v flock >/dev/null 2>&1 && { flock "${lw[@]}" 9 || { _fm_fail "$f is locked by another writer"; exit 1; }; }
    _fm_write "$@"
  ) 9>>"${FM_LOCK:-$(dirname "$f")/.lock}"
}
