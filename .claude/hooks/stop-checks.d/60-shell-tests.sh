#!/bin/bash
# Stop check: the fast tier of the shell test suite (unit + integ) plus shellcheck.
# Exit codes: 0=pass, 1=warn, 2=block.
#
# Only the fast tier runs here, and that is not just a latency call. The fast tier never
# starts a tmux server; the UI tier does, so it runs ONLY inside the disposable container
# (`make -C tests test-ui` -> tests/docker.sh) and must never be reachable from a hook that
# fires automatically on this machine. See tests/Dockerfile for why.

set -uo pipefail

# Scope: run ONLY when the project under test is this repo. The guard has to answer a
# question about IDENTITY, and the old `[ -d "${CLAUDE_PROJECT_DIR:-$PWD}/tests" ]` answered
# one about EXISTENCE -- which is not the same test and was never a scope. `~/tests` is a
# stow symlink onto .dotfiles/tests (laid 2026-07-26) and `-d` follows symlinks, so the
# guard was TRUE from $HOME. Every headless runner works from $HOME and the Stop hook is
# wired globally (matcher ""), so the whole fast tier ran at every Stop of every project
# for two weeks. That is how the suite came to be asserting against live agentctl state.
#
# --git-common-dir is the identifier rather than --show-toplevel because it is stable
# across worktrees: sessions here routinely work from `git worktree add` checkouts, and
# those must still be able to run their own tests. $HOME is not a repository at all, so it
# fails the lookup outright.
_repo_id() {                                        # absolute, worktree-stable repo id
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}
_self="$(realpath "${BASH_SOURCE[0]}")"             # deployed as a symlink; resolve it
OWN_REPO="$(_repo_id "${_self%/*}")"
PROJECT_ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$OWN_REPO" ] || exit 0
[ -n "$PROJECT_ROOT" ] || exit 0
[ "$(_repo_id "$PROJECT_ROOT")" = "$OWN_REPO" ] || exit 0

TESTS_DIR="$PROJECT_ROOT/tests"
[ -f "$TESTS_DIR/Makefile" ] || exit 0              # this checkout carries no suite
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
