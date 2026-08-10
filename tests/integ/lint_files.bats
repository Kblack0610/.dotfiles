#!/usr/bin/env bats
# tests/lint-files.sh: WHICH files the lint gate actually checks.
#
# THE INCIDENT
# ------------
# The selector was `git ls-files '*.sh' '*.bash'` from the day the gate was written until
# 2026-08-09. Nearly every executable in .local/bin/ is deliberately EXTENSIONLESS, because
# the extension would be part of the command a human types - agentctl, dotfiles-drift,
# dotfiles-deploy, ticket, sessions, agent-ask, agent-notify, wt, tmx, skill-deploy and ~70
# more. Not one of them was ever linted, locally or in CI, while the gate printed
# "shellcheck: clean at severity=error (153 files)" every single run.
#
# Nothing failed. 153 is a plausible number, so the under-selection was invisible - the same
# disease as an EMPTY input list (which tests/lint.sh already refuses), just wearing a
# convincing disguise. That is what this file exists to stop coming back, and why the
# assertions below NAME specific real scripts instead of asserting a count: a count is what
# fooled everyone for months.
#
# Two halves:
#   1. against the REAL repo - the regression itself, by name.
#   2. against a throwaway fixture repo - the selection RULES, where a zsh/ruby/python/bats
#      file can be planted without adding one to this tree.
#
# The fixture half copies lint-files.sh into <fixture>/tests/ because the script anchors
# itself with `cd "$(dirname "$0")/.."` - by design, so the gate cannot be pointed at the
# wrong tree by an ambient $PWD.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  LINT_FILES="$REPO_ROOT/tests/lint-files.sh"
}

# ── half 1: the real repo, the regression by name ────────────────────────────

@test "selects the EXTENSIONLESS bins that the old '*.sh' glob could never match" {
  run "$LINT_FILES"
  assert_success

  # Named on purpose, and NOT skipped when one is missing: a skip is how a check quietly
  # stops checking. If one of these is renamed or retired, this test should go red and
  # someone should edit the list - that is a five-second fix and a real signal.
  assert_line '.local/bin/agentctl'
  assert_line '.local/bin/dotfiles-deploy'
  assert_line '.local/bin/dotfiles-drift'
  assert_line '.local/bin/sessions'
  assert_line '.local/bin/agent-ask'
  assert_line '.local/bin/tmx'
  assert_line '.local/bin/skill-deploy'
  assert_line '.local/bin/wave-start'

  # .local/bin/ticket is deliberately NOT pinned either way. It is tracked, but as a symlink
  # into the private overlay (~/.dotfiles-private/.local/src/ticket/ticket), so it resolves
  # on a box that has the overlay stowed and DANGLES in CI, in the container, and in a bare
  # worktree. Asserting either outcome would make this test machine-dependent. The rule it
  # exercises - a tracked path with nothing readable behind it is skipped, not emitted - is
  # pinned deterministically in the fixture half below.
}

@test "no tracked bash script under .local/bin is left unlinted" {
  # The self-maintaining half. The list above pins a vocabulary; this one covers whatever
  # gets added tomorrow, so a new extensionless bin cannot slip through the same hole. It
  # also cannot pass vacuously: the input list is asserted non-trivial first.
  run "$LINT_FILES"
  assert_success

  local selected="$output" bins=0 missing=()
  local f first
  while IFS= read -r f; do
    [ -f "$REPO_ROOT/$f" ] || continue
    IFS= read -r first < "$REPO_ROOT/$f" || true
    case "$first" in *bash|*bash\ *|*/sh|*/sh\ *) ;; *) continue ;; esac
    bins=$((bins + 1))
    grep -qxF -- "$f" <<< "$selected" || missing+=("$f")
  done < <(git -C "$REPO_ROOT" ls-files .local/bin)

  [ "$bins" -ge 40 ] || { echo "only $bins shell bins found - the enumeration broke" >&2; return 1; }
  [ "${#missing[@]}" -eq 0 ] || { printf 'unlinted: %s\n' "${missing[@]}" >&2; return 1; }
}

@test "still selects the .sh and .bash files the old selector covered" {
  run "$LINT_FILES"
  assert_success
  assert_line '.local/src/tmux/notes-cockpit.sh'
  assert_line 'tests/lint.sh'
  assert_line 'tests/helpers/sandbox.bash'
}

@test "does NOT select the .bats suite, which shellcheck cannot parse" {
  run "$LINT_FILES"
  assert_success
  refute_line 'tests/integ/lint_files.bats'
  refute_output --partial '.bats'
}

@test "every selected path exists and is readable" {
  # git ls-files reads the INDEX, which can name a path with nothing behind it. Emitting one
  # makes shellcheck fail on "openFile: does not exist", which reads like a lint finding.
  run "$LINT_FILES"
  assert_success
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -r "$REPO_ROOT/$f" ] || { echo "not readable: $f" >&2; return 1; }
  done <<< "$output"
}

# ── half 2: the selection rules, against a planted fixture ───────────────────

# fixture_repo - a throwaway git repo carrying one of each interesting file, with a copy of
# the real lint-files.sh at the path it expects. Echoes the repo dir.
fixture_repo() {
  local d="$SANDBOX/fixt"
  mkdir -p "$d/tests" "$d/bin"

  printf '#!/usr/bin/env bash\ntrue\n'       > "$d/bin/plain-bash"
  printf '#!/bin/bash\ntrue\n'               > "$d/bin/abs-bash"
  printf '#!/bin/sh\ntrue\n'                 > "$d/bin/posix-sh"
  printf '#!/usr/bin/env -S bash -eu\ntrue\n' > "$d/bin/env-dash-s"
  printf '#!/usr/bin/env zsh\ntrue\n'        > "$d/bin/a-zsh"
  printf '#!/usr/bin/env python3\npass\n'    > "$d/bin/a-python"
  printf '#!/usr/bin/env ruby\nnil\n'        > "$d/bin/a-ruby"
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > "$d/bin/a-bats"
  printf 'plain text, no shebang\n'          > "$d/bin/not-a-script"
  printf '# a sourced fragment, no shebang\ntrue\n' > "$d/lib.sh"
  printf '#!/usr/bin/env zsh\ntrue\n'        > "$d/zsh-wearing-sh.sh"
  printf 'not a repo file\n'                 > "$d/README.md"

  cp "$LINT_FILES" "$d/tests/lint-files.sh"
  chmod +x "$d/tests/lint-files.sh" "$d/bin/"*

  git -C "$d" init -q .
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name tester
  git -C "$d" add -A
  git -C "$d" commit -qm fixture
  printf '%s' "$d"
}

@test "the rules: sh-family shebangs in, everything else out" {
  local d
  d="$(fixture_repo)"
  run "$d/tests/lint-files.sh"
  assert_success

  assert_line 'bin/plain-bash'
  assert_line 'bin/abs-bash'
  assert_line 'bin/posix-sh'
  assert_line 'bin/env-dash-s'      # `env -S bash -eu`: the interpreter is not argv[1]
  assert_line 'lib.sh'              # no shebang, but a .sh extension: a sourced fragment

  refute_line 'bin/a-zsh'
  refute_line 'bin/a-python'
  refute_line 'bin/a-ruby'
  refute_line 'bin/a-bats'
  refute_line 'bin/not-a-script'    # no shebang AND no extension: not a shell script
  refute_line 'README.md'
}

@test "an explicit zsh shebang beats a .sh extension" {
  # The old selector took *.sh unconditionally and filtered zsh out afterwards. Keep that
  # outcome: one zsh file in the list is SC1071, an ERROR, with nothing anyone can fix.
  local d
  d="$(fixture_repo)"
  run "$d/tests/lint-files.sh"
  assert_success
  refute_line 'zsh-wearing-sh.sh'
}

@test "an index entry with no file behind it is skipped, not emitted" {
  local d
  d="$(fixture_repo)"
  rm -f "$d/bin/plain-bash"          # tracked, deleted, not staged
  run "$d/tests/lint-files.sh"
  assert_success
  refute_line 'bin/plain-bash'
  assert_line 'bin/abs-bash'         # ...and the walk carries on
}

@test "a tracked symlink that DANGLES is skipped, not handed to shellcheck" {
  # The real instance: .local/bin/ticket is a tracked symlink into the private overlay, so
  # it resolves on a stowed box and dangles in CI and in the container. Emitting it would
  # give shellcheck a path it cannot open, and "openFile: does not exist" reads exactly like
  # a lint finding - a red gate with nothing anyone can fix.
  local d
  d="$(fixture_repo)"
  ln -s ../nowhere/overlay-script "$d/bin/dangler"
  git -C "$d" add bin/dangler
  git -C "$d" commit -qm dangler

  [ -L "$d/bin/dangler" ] && [ ! -e "$d/bin/dangler" ]   # it really does dangle

  run "$d/tests/lint-files.sh"
  assert_success
  refute_line 'bin/dangler'
  assert_line 'bin/abs-bash'
}

@test "REFUSES a list of zero rather than reporting a clean tree" {
  # The house rule, at the producer end: "nothing to check" and "everything passed" must not
  # print the same thing. A repo with no shell script in it at all is indistinguishable from
  # a selector that has stopped working, so the safe reading is the loud one.
  local d="$SANDBOX/empty"
  mkdir -p "$d/tests"
  cp "$LINT_FILES" "$d/tests/lint-files.sh"
  chmod +x "$d/tests/lint-files.sh"
  printf 'nothing here\n' > "$d/README.md"
  git -C "$d" init -q .
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name tester
  # Track ONLY the README; the copied lint-files.sh stays untracked so it cannot select
  # itself and mask the empty case.
  git -C "$d" add README.md
  git -C "$d" commit -qm empty

  run "$d/tests/lint-files.sh"
  assert_failure
  assert_output --partial 'ZERO files'
}

@test "REFUSES outside a git repository instead of emitting nothing" {
  local d="$SANDBOX/nogit"
  mkdir -p "$d/tests"
  cp "$LINT_FILES" "$d/tests/lint-files.sh"
  chmod +x "$d/tests/lint-files.sh"

  # GIT_CEILING_DIRECTORIES stops the discovery walk from climbing out of the sandbox and
  # finding this repo, which would make the test pass for the wrong reason.
  GIT_CEILING_DIRECTORIES="$SANDBOX" run "$d/tests/lint-files.sh"
  assert_failure
  assert_output --partial 'not a usable git repository'
}
