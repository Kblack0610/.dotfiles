# shellcheck shell=bash
# test-pick.sh - which fast-tier test files a change can affect: the Stop hook's 60-shell-tests.sh
# picks by it, and fleet-bench's hold check reads a merge's "area tests" by it.

# test_picked <changed paths, one a line> <test path, repo-relative>, the test's text on stdin:
# status 0 when that test is picked. A test is picked when it changed, names a changed file's
# basename, or names a directory a changed file sits under as `<dir>/` or `<dir>/*...` (a glob
# such as `.claude/hooks/stop-post.d/*.sh`); a change to the shared harness (helpers, fixtures,
# vendor, Makefile) picks every file.
test_picked() {
  grep -qE '^tests/(helpers|fixtures|vendor)/|^tests/Makefile$' <<<"$1" && return 0
  grep -qxF "$2" <<<"$1" && return 0
  local text
  text="$(cat)"
  grep -qwFf <(grep -v '^$' <<<"$1" | sed 's#.*/##' | sort -u) <<<"$text" && return 0
  # Every ancestor directory of a changed path, regex-escaped, as one alternation; a caller
  # loops over every test file with one change list, so it is built once per list.
  if [ "${_TEST_PICK_FOR-}" != "$1" ]; then
    _TEST_PICK_FOR="$1"
    _TEST_PICK_DIRS="$(awk -F/ '{p=$1; for (i=2; i<=NF; i++) {if (!(p in s)) {s[p]; e=p
          gsub(/[][\\.*^$+?(){}|]/, "\\\\&", e); o=o (o==""?"":"|") e}; p=p "/" $i}}
          END {printf "%s", o}' <<<"$1")"
  fi
  [ -n "$_TEST_PICK_DIRS" ] || return 1
  # A reference starts the path or follows a root: `$VAR/`, `"$VAR"/`, `${VAR}/`, `~/`, `./`,
  # `../` or `$(...)/`; after any other `/` it is a deeper directory of the same name
  # (`.local/src/docs/` is not `docs/`). After the slash comes `*`, a quote, a space, `)`, `;`
  # or the line end, so `<dir>/<file>` is a path to one file, not to the directory.
  local start='(^|[^A-Za-z0-9._/-]|(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?|~|\.\.?|\))/)'
  local after='($|[*"'"'"'[:space:]);])'
  grep -qE "$start($_TEST_PICK_DIRS)/$after" <<<"$text"
}
