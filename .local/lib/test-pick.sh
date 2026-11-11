# shellcheck shell=bash
# test-pick.sh - which fast-tier test files a change can affect: the Stop hook's 60-shell-tests.sh
# picks by it, and fleet-bench's hold check reads a merge's "area tests" by it.

# _test_pick_names <changed paths>: the words and parent/name paths test_picked matches, built
# once per change list. A shared basename has an extension and names two or more files outside
# tests/ in the repo this file sits in (README.md, lib.rs); an extensionless one is a command a
# test runs by bare name, so it stays a word even when .local/bin links it from .local/src or a
# stub in tests/helpers shadows it.
_TEST_PICK_REPO="$(git -C "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" rev-parse --show-toplevel 2>/dev/null || echo .)"
_test_pick_names() {
  [ "${_TEST_PICK_NAMES_FOR-}" = "$1" ] && return 0
  _TEST_PICK_NAMES_FOR="$1"
  local shared
  shared="$(git -C "$_TEST_PICK_REPO" ls-files 2>/dev/null | grep -v '^tests/' | sed 's#.*/##' | grep -E '.\.' | sort | uniq -d)"
  # The words as one ERE alternation, bounded by anything but a name character: `-` counts as
  # part of the name, so agentctl is not a word of agentctl-run.
  _TEST_PICK_WORDS="$(grep -v '^$' <<<"$1" | sed 's#.*/##' | sort -u | { grep -vxFf <(printf '%s\n' "$shared") || true; } |
    awk '{gsub(/[][\\.*^$+?(){}|]/, "\\\\&"); o=o (o==""?"":"|") $0} END {if (o!="") printf "(^|[^A-Za-z0-9_-])(%s)($|[^A-Za-z0-9_-])", o}')"
  _TEST_PICK_PATHS="$(grep -v '^$' <<<"$1" | grep '/' | awk -F/ 'NR==FNR {d[$0]; next} ($NF in d) {print $(NF-1) "/" $NF}' \
    <(printf '%s\n' "$shared") - | sort -u)" || true
}

# test_picked <changed paths, one a line> <test path, repo-relative>, the test's text on stdin:
# status 0 when that test is picked. A test is picked when it or a file it loads from beside it
# changed, or its text with what it loads names a changed file's basename (not as a stub or a
# directory) or a directory a changed file sits under as `<dir>/` or `<dir>/*...` (a glob such as
# `.claude/hooks/stop-post.d/*.sh`); a change to the shared harness (helpers, fixtures, vendor,
# Makefile) picks every file.
test_picked() {
  grep -qE '^tests/(helpers|fixtures|vendor)/|^tests/Makefile$' <<<"$1" && return 0
  grep -qxF "$2" <<<"$1" && return 0
  local text rel inc new more seen=$'\n'
  text="$(cat)" new=$text
  # A file the test loads from beside it (`load 'fleet_dispatch/common'`) is part of its text, and
  # a change to it picks the test; so is a file that one loads, to any depth. bats resolves `load
  # x` against the test's own directory, as x.bash and then x. The shared harness (../helpers,
  # ../vendor) is matched above.
  while [ -n "$new" ]; do
    more=
    while read -r rel; do
      case $rel in ../* | /*) continue ;; esac
      grep -qxF -e "${2%/*}/$rel.bash" -e "${2%/*}/$rel" <<<"$1" && return 0
      inc="${2%/*}/$rel.bash"
      [ -f "$_TEST_PICK_REPO/$inc" ] || inc="${2%/*}/$rel"
      [ -f "$_TEST_PICK_REPO/$inc" ] || continue
      [[ $seen == *$'\n'"$inc"$'\n'* ]] && continue
      seen+=$inc$'\n'
      more+=$'\n'"$(cat "$_TEST_PICK_REPO/$inc")"
    done < <(sed -nE "s/^[[:space:]]*load[[:space:]]+['\"]?([^'\" ]+).*/\1/p" <<<"$new")
    text+=$more new=$more
  done
  # A basename counts where it can name the file. Dropped first: comment lines and @test titles
  # (prose), `stub <name>` (a fake stands in for it), `<name>/` (a directory of that name, such
  # as ~/.config/agentctl/) and `<name>@` (a systemd unit). A shared basename (README.md,
  # SKILL.md) is matched as `<parent dir>/<name>`. Without these,
  # unit/fleet_dispatch.bats, a third of the unit tier, was picked by 33 of 40 commits on main.
  _test_pick_names "$1"
  [ -n "$_TEST_PICK_PATHS" ] && grep -qFf <(printf '%s\n' "$_TEST_PICK_PATHS") <<<"$text" && return 0
  [ -n "$_TEST_PICK_WORDS" ] && grep -qE "$_TEST_PICK_WORDS" \
    <(sed -E '/^[[:space:]]*#/d; s/^@test[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"')//
      s/(^|[[:space:];&|(])stub[[:space:]]+[^[:space:]]+/\1stub/g; s#[A-Za-z0-9._-]+[/@]#/#g' <<<"$text") && return 0
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
