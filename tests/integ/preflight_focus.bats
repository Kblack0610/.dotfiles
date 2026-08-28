#!/usr/bin/env bats
# session-preflight.sh: the turn-1 context injection. These tests cover exactly one
# property -- that a partial deploy cannot silence the whole hook.
#
# The hooks ship via `stow --no-folding .`, one symlink per file, so a checkout can reach a
# commit that adds focus-lib.sh before stow has linked it. Under `set -e` an unguarded
# source of the missing lib exits the script before it prints anything, and the only
# symptom is an empty turn 1: no anchor, no plans, no lessons, no git context, no error
# anyone sees. That is a much worse failure than losing the Focus block, so the source is
# guarded and the Focus block is skipped when the lib did not load.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # gh is the one network-reaching call in the hook. Stub it so this test is hermetic and
  # does not depend on a runner having credentials (or a repo having a remote).
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$SANDBOX/bin/gh"

  # A disposable repo to be the project dir, so the git section has something to read.
  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo hello > "$REPO/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "first commit"
  export CLAUDE_PROJECT_DIR="$REPO"

  # A deploy dir holding the hook and its required sibling, mirroring the stow layout.
  DEPLOY="$SANDBOX/shared-hooks"
  mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/session-preflight.sh" \
     "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$DEPLOY/"
}

# context -- the injected additionalContext string, or empty if the hook produced nothing.
context() {
  bash "$DEPLOY/session-preflight.sh" </dev/null 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

@test "with focus-lib present the hook emits context including the Focus block" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" "$DEPLOY/"
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  assert_output --partial 'Recent commits'
  assert_output --partial 'Focus'
}

@test "with focus-lib missing the hook still exits 0" {
  # The regression: `set -e` plus an unguarded source made this exit 1.
  rm -f "$DEPLOY/focus-lib.sh"
  run bash "$DEPLOY/session-preflight.sh" </dev/null
  assert_success
}

@test "with focus-lib missing the rest of the context still ships" {
  # This is the whole point. Losing Focus is survivable; losing the anchor, the plans, the
  # lessons and the git context at turn 1, silently, is not.
  rm -f "$DEPLOY/focus-lib.sh"
  run context
  assert_output --partial 'Session Preflight'
  assert_output --partial 'Recent commits'
  assert_output --partial 'first commit'
}

@test "with focus-lib missing the Focus block is skipped, not half-rendered" {
  # A half-rendered block would mean the functions were called anyway and errored inline.
  rm -f "$DEPLOY/focus-lib.sh"
  run context
  refute_output --partial 'Focus (today'
  refute_output --partial 'focus_daily_note'
  refute_output --partial 'command not found'
}

# --- where the nudge sends an agent's work --------------------------------------------
#
# The turn-1 nudge and the turn-N Stop gate (86-focus-reconcile.sh) state the same rule
# from both ends and MUST agree. #204 taught the gate to accept a `ptask:` write but left
# this hook saying "notes focus add", so an agent was instructed to use the human's list
# and then blocked for having used it. These pin the halves together.
#
# `focus_daily_note` falls back to $HOME/.notes/journal/daily/<date>.md when `notes path
# daily` prints nothing, which is exactly what the stub does -- so seeding that file is
# enough to drive either branch.

seed_focus() {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" "$DEPLOY/"
  mkdir -p "$HOME/.notes/journal/daily"
  printf '# %s\n\n## Focus\n%s\n\n## Notes\n' \
    "$(date +%F)" "${1:-}" > "$HOME/.notes/journal/daily/$(date +%F).md"
}

@test "with Focus items the nudge sends PROJECT work to ptask, not to Focus" {
  seed_focus '- [ ] a human task'
  run context
  assert_output --partial 'a human task'
  assert_output --partial 'notes ptask <project> add|start|done'
  assert_output --partial 'notes board'
}

@test "with Focus items the nudge never tells an agent to add to Focus" {
  # NEGATIVE CONTROL for the whole change. Before it, this line read
  # "If not, \`notes focus add\`" -- the instruction that put five of six items on the
  # human's 2026-08-05 list. If `notes focus add` ever comes back as advice here, the
  # turn-1 half has silently reverted to disagreeing with the gate.
  seed_focus '- [ ] a human task'
  run context
  refute_output --partial 'notes focus add'
}

@test "an empty Focus is reported as fine, and still points at the board" {
  # The old empty-state text ("capture what we're on") read as an instruction to fill the
  # human's list. An agent with nothing on Focus must be sent to ptask, not to `notes today`.
  seed_focus ''
  run context
  assert_output --partial 'none set'
  assert_output --partial 'notes ptask <project> add|start|done'
  refute_output --partial 'notes focus add'
}

# -- the agent board lane: the channel that replaced "## -> For the agents" ------

# seed_agent_stub -- a `notes` stub that emits <project>\t<text> rows for --agent, and records
# the projects it was asked for so the JOIN can be asserted, not just the output.
seed_agent_stub() {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
if [ "${1:-}" = "board" ] && [ "${2:-}" = "--agent" ]; then
  for a in "$@"; do
    case "$a" in
      notes-cockpit) printf 'notes-cockpit\tcockpit row one\n' ;;
      agent-runtime) printf 'agent-runtime\truntime row one\n' ;;
    esac
  done
  exit 0
fi
exit 0
EOF
  chmod +x "$SANDBOX/bin/notes"
}

# A registry whose repo hop matches this test's project, INCLUDING the string-valued
# comment key that lives in the real one.
seed_tracker_map() {
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$REPO": "toolrepo" },
  "apps": {},
  "aliases": {},
  "trackers": {
    "_comment_lab_projects": "a STRING value; an unguarded .value.repo dies on this",
    "notes-cockpit": { "system": "vikunja", "repo": "toolrepo" },
    "agent-runtime": { "system": "vikunja", "repo": "toolrepo" }
  }
}
EOF
}

@test "the agent board surfaces the in-flight rows for THIS repo's lab projects" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_agent_stub

  run context
  assert_success
  assert_output --partial 'Left in flight'
  assert_output --partial '[notes-cockpit] cockpit row one'
  assert_output --partial '[agent-runtime] runtime row one'
}

@test "the agent lane joins through trackers.repo, NOT the directory name" {
  # The whole point. The project resolves to `toolrepo`; its board projects are named
  # something else entirely. A directory-name join asks for the wrong thing and finds
  # nothing -- which is what the replaced lab readback did for every real session.
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_agent_stub

  context >/dev/null
  assert_called '--project notes-cockpit'
  assert_called '--project agent-runtime'
  # It must NOT have asked for the repo's own name, which has no board.
  run grep -c -- '--project toolrepo' "$NOTES_FIXTURE/calls.log"
  assert_output '0'
}

@test "a registry with a STRING-valued trackers key still emits a full context" {
  # The direct negative control for the jq trap. `.trackers` holds a documentation key
  # whose value is a string; an unguarded `.value.repo` over it exits 5, and under this
  # hook's `set -e` that costs the ENTIRE turn-1 context with no error anyone sees.
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_agent_stub

  run context
  assert_success
  assert_output --partial 'Session Preflight'
  assert_output --partial 'Recent commits'
  refute_output --partial 'Cannot index string'
}

@test "the retired '-> For the agents' channel is gone" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_agent_stub
  run context
  assert_success
  refute_output --partial 'For the agents'
  refute_output --partial 'via lab'
}

@test "no notes binary means no agent block, and the rest of the context survives" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  # Removing the stub is not enough: sandbox.bash PREPENDS $SANDBOX/bin to the real PATH,
  # so the hook fell through to the machine's own `notes`. That made this test pass on the
  # real binary erroring against the sandboxed HOME rather than on the binary being gone.
  rm -f "$SANDBOX/bin/notes"
  PATH="$SANDBOX/bin:/usr/bin:/bin"

  run context
  assert_success
  assert_output --partial 'Recent commits'
  refute_output --partial 'Left in flight'
  refute_output --partial 'Agent board clear'
  refute_output --partial 'Agent board unavailable'
}

# The third outcome, and the reason the exit status is kept: a notes that FAILS must not
# render as a clean board. "Nothing to do" and "I could not find out" are different facts.
@test "a failing notes reports the query failed, not that the board is clear" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
  chmod +x "$SANDBOX/bin/notes"

  run context
  assert_success
  assert_output --partial 'Agent board unavailable'
  refute_output --partial 'Agent board clear'
}

@test "the injected context stays well under the old 28.5 KB" {
  # The budget this rewrite exists for. Not a hard 8 KB: measured, the anchor's
  # non-truncatable sections alone are 5.3 KB and its newest single decision entry is
  # 2.9 KB, so ~8.3 KB is the anchor's floor before anything else is added.
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_agent_stub

  local n
  n=$(context | wc -c)
  [ "$n" -lt 16384 ] || {
    echo "turn-1 context is ${n} bytes, over the 16 KB ceiling" >&2
    return 1
  }
}
