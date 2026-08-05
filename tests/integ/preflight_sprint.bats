#!/usr/bin/env bats
# session-preflight.sh: the stranded-sprint banner at turn 1.
#
# Its whole job is to stop in-flight work being forgotten after a crash or a process exit.
# It was itself forgotten: it grepped rows for the literal words queued|in-progress|pr-open,
# which are three of the many strings a Status cell actually holds and NOT the ones a wave
# writes (`in-wave`, `reverted-from-wave`) or a human writes by hand (`**DONE - PR #1036
# merged**`, `blocked on access`). Measured against the real boards on this machine the
# regex matched NOTHING while two rows sat `working`.
#
# There was no test. A banner that silently stops firing produces no output, no error and
# no failing check - the exact shape this suite exists to catch, so every test below
# asserts on the banner PRESENT as well as absent.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$SANDBOX/bin/gh"

  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo hello > "$REPO/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "first commit"
  export CLAUDE_PROJECT_DIR="$REPO"

  # Mirror the stow layout: the hook plus every sibling it sources.
  DEPLOY="$SANDBOX/shared-hooks"
  mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/session-preflight.sh" \
     "$REPO_ROOT/.config/shared-hooks/project-name.sh" \
     "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" "$DEPLOY/"
  export AGENT_BOARD_LIB="$REPO_ROOT/.local/lib/agent-board.sh"

  # resolve_project_name falls back to the basename, so the project is "repo".
  PLAN_DIR="$HOME/.agent/plans/repo"
  mkdir -p "$PLAN_DIR"
}

context() {
  bash "$DEPLOY/session-preflight.sh" </dev/null 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

# board <status-cell>... -- a board shaped like the REAL ones: no `#` column, Status last.
board() {
  {
    printf '# Sprint\n\n## Queue\n\n| Ticket | P | Title | Lane | Agent | Status | Sentinel |\n'
    printf '|---|---|---|---|---|---|---|\n'
    local i=0
    for s in "$@"; do
      i=$((i + 1))
      printf '| %s | P1 | thing %s | ai | - | %s | - |\n' "55$i" "$i" "$s"
    done
  } > "$PLAN_DIR/sprint-2026-08-03.md"
}

@test "GUARD: the hook emits context at all" {
  # Without this, every assertion below could pass by the hook printing nothing.
  board 'working'
  run context
  assert_success
  assert_output --partial 'Session Preflight'
}

@test "a board whose rows say 'working' fires the banner" {
  # THE regression. `working` is what board_rows returns for the most common real cell,
  # and it is not one of the three words the old regex knew.
  board 'working'
  run context
  assert_output --partial 'ACTIVE SPRINT'
}

@test "the real 2026-07-15 board fires the banner" {
  # VERBATIM status cells from ~/.agent/plans/bnb-platform/sprint-2026-07-15.md - the
  # board that had live rows while the banner stayed silent. Copied from the file rather
  # than written from the stage names on purpose: an earlier draft of this test used
  # 'queued'/'working', which the OLD regex happens to match, so it passed against the
  # very bug it was meant to pin. The real board says `dispatched` and `filed, not
  # dispatched` and contains none of queued|in-progress|pr-open anywhere.
  board '**DONE — PR #1036 merged `31f11fd6`, 13/13 CI green**' \
        'filed, not dispatched' \
        'dispatched' \
        'dispatched' \
        'dispatched'
  run context
  assert_output --partial 'ACTIVE SPRINT'
}

@test "a wave board fires the banner" {
  # `/wave` writes in-wave and reverted-from-wave. The old regex knew neither, so a wave
  # mid-flight was invisible at turn 1.
  board 'in-wave' 'reverted-from-wave'
  run context
  assert_output --partial 'ACTIVE SPRINT'
}

@test "a blocked row fires the banner - that is the one most needing a human" {
  board 'blocked on access'
  run context
  assert_output --partial 'ACTIVE SPRINT'
}

@test "a hand-written terminal status does NOT fire the banner" {
  # The other direction, and the reason this cannot just match everything: a finished
  # board must stay quiet or the banner becomes noise and gets ignored.
  board '**DONE - PR #1036 merged**' 'merged'
  run context
  refute_output --partial 'ACTIVE SPRINT'
}

@test "no board at all does NOT fire the banner" {
  run context
  assert_success
  refute_output --partial 'ACTIVE SPRINT'
}

@test "the row count reports non-terminal rows, not the whole table" {
  # 2 live + 2 terminal -> the human is told 2, so the number means something.
  board 'working' 'merged' 'queued' 'skipped'
  run context
  assert_output --partial 'ACTIVE SPRINT'
  assert_output --partial '2 in-flight row(s)'
}

@test "with agent-board.sh unreachable the hook still ships the rest of turn 1" {
  # Same contract as focus-lib: losing the banner is survivable, losing the anchor, plans,
  # lessons and git context silently is not.
  board 'working'
  AGENT_BOARD_LIB=/nonexistent HOME="$HOME" run bash -c '
    AGENT_BOARD_LIB=/nonexistent bash "$1" </dev/null' _ "$DEPLOY/session-preflight.sh"
  assert_success
  assert_output --partial 'Session Preflight'
}
