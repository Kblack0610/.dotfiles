#!/bin/bash
# Stop check: the fast tier of the shell test suite (unit + integ) plus shellcheck.
# Exit codes: 0=pass, 1=warn, 2=block.
#
# Only the fast tier runs here, and that is not just a latency call. The fast tier never
# starts a tmux server; the UI tier does, so it runs ONLY inside the disposable container
# (`make -C tests test-ui` -> tests/docker.sh) and must never be reachable from a hook that
# fires automatically on this machine. See tests/Dockerfile for why.

set -uo pipefail

TESTS_DIR="${CLAUDE_PROJECT_DIR:-$PWD}/tests"
[ -d "$TESTS_DIR" ] || exit 0                       # not applicable outside the dotfiles repo
[ -x "$TESTS_DIR/vendor/bats-core/bin/bats" ] || {
  echo "shell-tests: bats not vendored yet - run 'make -C tests bootstrap'"
  exit 1                                            # warn, do not block a fresh checkout
}

FAILED=0
make -C "$TESTS_DIR" test-fast 2>&1 || FAILED=1

# Linting is advisory here: a regression should be visible without blocking a commit that is
# otherwise green. lint.sh owns the severity ratchet and is the same gate CI runs.
# (Do not begin a comment with the word "shellcheck" -- it is parsed as a directive and
# errors out with SC1072/SC1073.)
if command -v shellcheck >/dev/null 2>&1; then
  "$TESTS_DIR/lint.sh" 2>&1 || echo "shell-tests: lint findings (advisory)"
fi

[ $FAILED -eq 1 ] && exit 2
exit 0
