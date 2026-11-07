# shellcheck shell=bash
# test-pick.sh - which fast-tier test files a change can affect: the Stop hook's 60-shell-tests.sh
# picks by it, and fleet-bench's hold check reads a merge's "area tests" by it.

# test_picked <changed paths, one a line> <test path, repo-relative>, the test's text on stdin:
# status 0 when that test is picked. A test is picked when it changed or names a changed file's
# basename; a change to the shared harness (helpers, fixtures, vendor, Makefile) picks every file.
test_picked() {
  grep -qE '^tests/(helpers|fixtures|vendor)/|^tests/Makefile$' <<<"$1" && return 0
  grep -qxF "$2" <<<"$1" && return 0
  grep -qwFf <(grep -v '^$' <<<"$1" | sed 's#.*/##' | sort -u)
}
