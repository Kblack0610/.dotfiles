#!/usr/bin/env bats
# Checks that read the whole tree, or a whole directory of it, rather than one script: a change
# to any file can turn one red, so tests/pick.sh cannot judge them and tests/broad.txt runs this
# file on every pull request. unit/pick.bats fails a scan like these written anywhere else.
# Why: on 2026-11-12 the env-name scan below lived in agent_run_route.bats, no PR picked it,
# and main was red for 3.4 hours across 15 pushes.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  LINT_FILES="$REPO_ROOT/tests/lint-files.sh"
}

# The classification is DATA, and this is the test that keeps it honest: every
# transport-shaped name anywhere in the tree must be filed under [scrub] or
# [not-transport], with a reason. A new one fails the suite until a human says
# which kind it is.
@test "every transport-shaped env name in the tree is classified" {
  local list="$REPO_ROOT/.local/src/agent-run/lib/scrub.list"
  assert [ -r "$list" ]

  # Scope: code WE own and deploy, so tracked and untracked files but never
  # ignored ones. ~/.claude is stowed from this tree, and Claude Code writes
  # runtime state into it (.claude/cache/changelog.md names ~200 of its own
  # vars), which a plain grep -r picked up. Also excluded, each for a reason:
  #   node_modules vendored third-party JS (the opencode SDK names its own vars)
  #   vendor       vendored bats
  #   .serena      a third-party tool's own config, which names model ids
  # The question this test asks is "what can OUR code be handed", so a vendored
  # library's private variable names are noise, and history is not code at all.
  #
  # Note this file is itself in scope, which is correct and is a small trap: an
  # identifier written into a comment here is indistinguishable from one in real
  # code. It caught me once already. So do not spell unclassified examples out.
  local -a names=()
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(
    git -C "$REPO_ROOT" grep --untracked -hoIwE \
      '(ANTHROPIC|CLAUDE_CODE|LLM|OPENCODE)_[A-Z0-9_]+' -- . \
      ':(exclude,glob)**/node_modules/**' ':(exclude,glob)**/vendor/**' \
      ':(exclude,glob)**/.serena/**' ':(exclude,glob)**/.opencode/**' 2>/dev/null | sort -u
  )
  # Empty input is FAILURE, not success. A scanner that matched nothing would
  # otherwise report a perfectly classified codebase.
  assert [ "${#names[@]}" -gt 20 ]

  local -a unclassified=()
  local n
  for n in "${names[@]}"; do
    grep -qE "^[[:space:]]*${n}([[:space:]]|#|$)" "$list" || unclassified+=("$n")
  done
  # Named in the failure, so the fix is obvious rather than a hunt.
  [ "${#unclassified[@]}" -eq 0 ] || \
    echo "unclassified: ${unclassified[*]}" >&2
  assert [ "${#unclassified[@]}" -eq 0 ]
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

# The resolvers must stay byte-identical in precedence. They are in separate
# files that no single change touches together, which is exactly how they came
# apart the first time. Written as a scan so a NEW reader that honours only one
# name is caught the day it lands, rather than the day someone sets a variable.
@test "every state-dir resolver honours BOTH names" {
  local offenders=()
  local f
  for f in .local/bin/agentctl .local/lib/agent-proof.sh \
           .local/src/tmux/fleet.sh .local/bin/agent-mqtt-publish; do
    # the line that establishes the state dir must mention both names
    grep -qE 'AGENTCTL_STATE_DIR:-\$\{?AGENTCTL_STATE' "$REPO_ROOT/$f" || offenders+=("$f")
  done
  assert [ "${#offenders[@]}" -eq 0 ]
  # A NEW resolver anywhere under .local must join the list above rather than
  # quietly honouring one name. The count is also the empty-input guard: if the
  # grep matched nothing at all, this fails rather than reading as "all fine".
  run bash -c "grep -rlE 'AGENTCTL_STATE_DIR:-\\\$\\{?AGENTCTL_STATE' '$REPO_ROOT'/.local | wc -l"
  assert_output '4'
}
