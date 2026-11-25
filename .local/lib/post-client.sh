# post-client.sh: what the one-provider post clients (bluesky-post, discord-post, mastodon-post)
# share: a private work dir for the curl config and the response, one post at a time per machine,
# and reading the response's headers and retry waits. The caller sets MAX_WAIT.

# post_begin <name>: $work, a mode-700 dir removed on exit (the curl config there holds the
# token), then the machine's <name>.lock, held until exit so a second post waits its turn.
post_begin() {
  work="$(umask 077; mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  local lockdir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  if command -v flock >/dev/null; then
    exec 9>"$lockdir/$1.lock"
    flock 9
  fi
}

# header <name>: the last value of that response header in $work/headers, matched case-blind.
header() { tr -d '\r' <"$work/headers" | awk -v h="$(tr 'A-Z' 'a-z' <<<"$1"):" 'tolower($1) == h { print $2 }' | tail -n1; }

# too_long <secs>: true when a retry wait is over MAX_WAIT, so the caller fails instead of blocking.
too_long() { awk -v s="$1" -v m="$MAX_WAIT" 'BEGIN { exit !(s + 0 > m + 0) }'; }
