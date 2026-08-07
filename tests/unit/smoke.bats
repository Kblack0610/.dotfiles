#!/usr/bin/env bats
# Harness smoke test. If this fails, nothing else in the suite means anything.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # `load` only handles .bash files, and the subject is .sh -- source it directly.
  source "$COCKPIT"
}

@test "sourcing the cockpit does not launch the UI" {
  # The source guard returned before the fzf preflight, so we got here at all.
  # Prove the functions came with us.
  declare -F classify   >/dev/null
  declare -F _task_row  >/dev/null
  declare -F rail       >/dev/null
}

@test "sandbox redirects HOME and TMPDIR away from the real ones" {
  refute [ "$HOME" = "/home/kblack0610" ]
  assert [ -d "$HOME" ]
  [[ "$HOME" == *"$BATS_TEST_TMPDIR"* ]]
  [[ "$TMPDIR" == *"$BATS_TEST_TMPDIR"* ]]
}

@test "sandbox path contains a space, so unquoted expansions fail loudly here" {
  [[ "$HOME" == *" "* ]]
}

@test "every in-repo symlink in .local/bin resolves" {
  # A dangling dispatch alias is a SILENT no-op, which is the failure class this repo keeps
  # getting bitten by. `.local/bin/wt` shipped pointing at `../../.dotfiles/.local/src/...`
  # -- the form the DEPLOYED link in ~/.local/bin uses, where `../../` reaches $HOME. From
  # inside the repo the same string resolves to ~/.dotfiles/.dotfiles/... and nothing is
  # there. In-repo links are relative to .local/bin itself: `../src/tmux/servers.sh`.
  #
  # Nothing caught it. panel_conformance only validates aliases a POPUP binding invokes, and
  # `wt` is reached from a run-shell bind and from wind-down's `[ -x ... ]` gate -- so the
  # keybinding would have done nothing and the reap would never have fired, both silently.
  #
  # IN-REPO only, and the two exclusions are not loopholes:
  #   - a target that ESCAPES the repo is the private overlay (`ticket` ->
  #     ../../../.dotfiles-private/...). Absent by design here and on any runner.
  #   - a target inside a declared SUBMODULE (.local/src/android-suite, gungan) is absent
  #     until the submodule is initialised, which a fresh worktree and CI both skip.
  # Both are "not this repo's file to have"; a wrong relative prefix is.
  local subs=()
  if [ -f "$REPO_ROOT/.gitmodules" ]; then
    mapfile -t subs < <(awk '/^[[:space:]]*path[[:space:]]*=/ {print $NF}' "$REPO_ROOT/.gitmodules")
  fi

  local f target resolved dangling=() s skip
  for f in "$REPO_ROOT"/.local/bin/*; do
    [ -L "$f" ] || continue
    target="$(readlink "$f")"
    # Resolve against .local/bin WITHOUT requiring existence -- realpath -e would just fail
    # here, and the failure is exactly what is being measured.
    resolved="$(realpath -m "$REPO_ROOT/.local/bin/$target")"
    case "$resolved" in
    "$REPO_ROOT"/*) ;;
    *) continue ;; # escapes the repo: the private overlay
    esac
    skip=0
    for s in "${subs[@]}"; do
      case "$resolved" in "$REPO_ROOT/$s"/*) skip=1 ;; esac
    done
    [ "$skip" -eq 1 ] && continue
    [ -e "$f" ] || dangling+=("$(basename "$f") -> $target")
  done

  if [ "${#dangling[@]}" -gt 0 ]; then
    printf 'dangling in-repo symlink under .local/bin:\n' >&2
    printf '  %s\n' "${dangling[@]}" >&2
    printf 'in-repo links are relative to .local/bin, e.g. ../src/tmux/servers.sh\n' >&2
    return 1
  fi
}

@test "the .local/bin scan actually sees links, so an empty sweep cannot pass" {
  # The negative control for the test above: it iterates a glob, and a glob that matched
  # nothing would report a clean tree just as loudly.
  local n=0 f
  for f in "$REPO_ROOT"/.local/bin/*; do
    [ -L "$f" ] && n=$((n + 1))
  done
  [ "$n" -ge 3 ] || fail "expected several symlinks in .local/bin, found $n -- the sweep is looking in the wrong place"
}

@test "the notes stub is on PATH ahead of the real one" {
  run command -v notes
  assert_success
  [[ "$output" == "$SANDBOX/bin/notes" ]]
}

@test "the notes stub serves fixture data and records its calls" {
  run notes config --profiles
  assert_success
  assert_line 'personal'
  assert_line 'work'
  assert_called 'notes config --profiles'
}

@test "cockpit state files land in the sandbox, not the real TMPDIR" {
  [[ "$STATE"   == "$TMPDIR"/* ]]
  [[ "$MODEF"   == "$TMPDIR"/* ]]
  [[ "$PFILTER" == "$TMPDIR"/* ]]
}
