#!/usr/bin/env bats
# session-preflight.sh: the turn-1 context injection. Most of these pin the agent board
# lane and the byte budget; the first ones pin what turn 1 no longer carries (the human's
# Focus list, a second copy of the commits Claude Code's gitStatus already shows).

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

seed_focus() {
  mkdir -p "$HOME/.notes/journal/daily"
  printf '# %s\n\n## Focus\n%s\n\n## Notes\n' \
    "$(date +%F)" "${1:-}" > "$HOME/.notes/journal/daily/$(date +%F).md"
}

@test "the human's Focus list is not turn-1 context, even with focus-lib deployed" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" "$DEPLOY/"
  seed_focus '- [/] a human task in progress'
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  refute_output --partial 'a human task'
  refute_output --partial 'Focus'
  # The retired nudge must not come back in another block either.
  refute_output --partial 'notes focus add'
}

@test "a whole-repo session gets no commit list: gitStatus already carries it" {
  run context
  assert_success
  refute_output --partial 'Recent commits'
  refute_output --partial 'first commit'
}

@test "an app session still gets the commits scoped to its subtree" {
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  cat > "$PROJECT_MAP_FILE" <<EOF
{ "paths": { "$REPO": "toolrepo" }, "aliases": {},
  "trackers": { "shop": { "repo": "toolrepo", "path": "apps/shop" } } }
EOF
  mkdir -p "$REPO/apps/shop"
  echo x > "$REPO/apps/shop/f"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "shop commit"
  export CLAUDE_PROJECT_DIR="$REPO/apps/shop"
  run context
  assert_output --partial 'Recent commits (last 5, apps/shop)'
  assert_output --partial 'shop commit'
  # Negative control: the commit outside the subtree stays out.
  refute_output --partial 'first commit'
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
  "aliases": {},
  "trackers": {
    "_comment_lab_projects": "a STRING value; an unguarded .value.repo dies on this",
    "notes-cockpit": { "system": "board", "repo": "toolrepo" },
    "agent-runtime": { "system": "board", "repo": "toolrepo" }
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

# board_stub <asks> <others>: a notes stub whose agent board holds follow-up rows first, then asks.
board_stub() {
  cat > "$SANDBOX/bin/notes" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "board --agent" ]; then
  for i in \$(seq 1 $2); do printf 'notes-cockpit\tfollow-up %s\n' "\$i"; done
  for i in \$(seq 1 $1); do printf 'notes-cockpit\tthe ask %s #requested #tier/2\n' "\$i"; done
fi
exit 0
EOF
  chmod +x "$SANDBOX/bin/notes"
}

@test "asks lead the agent board, at most 3 of its 6 rows, so in-flight rows still show" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  board_stub 20 12

  run context
  assert_success
  [ "$(grep -c 'the ask ' <<<"$output")" -eq 3 ]
  [ "$(grep -c 'follow-up ' <<<"$output")" -eq 3 ]
  [ "$(grep -m1 -n 'the ask 1 ' <<<"$output" | cut -d: -f1)" -lt "$(grep -m1 -n 'follow-up 1$' <<<"$output" | cut -d: -f1)" ]
  assert_output --partial '+26 more'
}

@test "spare room on the agent board goes to the asks left over" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  board_stub 20 2

  run context
  assert_success
  [ "$(grep -c 'the ask ' <<<"$output")" -eq 4 ]
  [ "$(grep -c 'follow-up ' <<<"$output")" -eq 2 ]
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
  assert_output --partial 'runtime row one'
  refute_output --partial 'Cannot index string'
}

@test "an app session gets its REPO's lessons as parent, and no other tracker's" {
  # The corpus that binds an app is its repo's. NEGATIVE CONTROL: another registered
  # tracker's lessons stay out.
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$REPO": "toolrepo" },
  "aliases": {},
  "trackers": {
    "_comment": "a string value",
    "ticket-parent": { "system": "board" },
    "shop": { "repo": "toolrepo", "path": "apps/shop" }
  }
}
EOF
  mkdir -p "$REPO/apps/shop" "$HOME/.agent/lessons"
  echo "- a repo-wide lesson" > "$HOME/.agent/lessons/toolrepo.md"
  echo "- a ticket-parent lesson" > "$HOME/.agent/lessons/ticket-parent.md"
  export CLAUDE_PROJECT_DIR="$REPO/apps/shop"

  run context
  assert_success
  assert_output --partial 'Session Preflight: shop'
  assert_output --partial 'a repo-wide lesson'
  refute_output --partial 'a ticket-parent lesson'
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
  assert_output --partial 'Session Preflight'
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

# -- the one size budget -------------------------------------------------------------
#
# Past Claude Code's ~10 KB hook-output cap the whole preflight is saved to a file and
# the model gets a 2 KB preview: on 2026-11-02 that was the anchor header and one
# decisions entry, and nothing after it arrived. The budget keeps the context under
# 9,000 B by leaving out the lowest-priority sections and naming them.

# seed_anchor_sized <blocker-lines> <lesson-lines> -- an anchor whose decisions log is
# far over the cap on its own (40 entries of ~420 B), with <n> 200-byte lines in the
# blockers and lessons sections so the NON-log sections can be made to overflow too.
seed_anchor_sized() {
  mkdir -p "$HOME/.agent/anchors"
  local a="$HOME/.agent/anchors/toolrepo.md" i pad
  pad=$(printf 'x%.0s' $(seq 1 190))
  {
    echo "# toolrepo - anchor"
    echo "## Key URLs & facts"
    echo "- **Repo:** a fact that must survive"
    echo "## Decisions log"
    for i in $(seq 40 -1 1); do echo "- **2026-08-01:** decision $i $pad$pad"; done
    echo "## Blockers / known issues"
    for i in $(seq 1 "$1"); do echo "- blocker $i $pad"; done
    echo "## Active plans (most recent)"
    echo "- \`a-plan.md\`"
    echo "## Recent lessons (digest)"
    echo "- a digest lesson"
    for i in $(seq 2 "$2"); do echo "- lesson $i $pad"; done
  } > "$a"
}

# fat_board_stub <rows> <bytes-per-row>
fat_board_stub() {
  cat > "$SANDBOX/bin/notes" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "board --agent" ]; then
  for i in \$(seq 1 $1); do printf 'notes-cockpit\trow %s %s\n' "\$i" "\$(printf 'y%.0s' \$(seq 1 $2))"; done
fi
exit 0
EOF
  chmod +x "$SANDBOX/bin/notes"
}

@test "a large anchor and a 40-row board stay under 9,000 B and keep the board" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_anchor_sized 30 10
  fat_board_stub 40 200

  local out n
  out=$(context)
  n=$(printf '%s' "$out" | wc -c)
  [ "$n" -lt 9000 ] || { echo "turn-1 context is $n bytes, over 9,000" >&2; return 1; }
  [[ "$out" == *"Left in flight"* ]]
  [[ "$out" == *"a fact that must survive"* ]]
  [[ "$out" == *"Decisions log: 40 entries"* ]]
  [[ "$out" == *"+ omitted to fit the 9000 B turn-1 budget:"* ]]
  [[ "$out" == *"lessons digest ("* ]]
}

@test "small inputs omit nothing, and the lessons digest and plans arrive" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_anchor_sized 1 1
  seed_agent_stub

  run context
  assert_success
  refute_output --partial 'omitted to fit'
  assert_output --partial 'Left in flight'
  assert_output --partial '## Recent lessons (digest)'
  assert_output --partial 'a digest lesson'
  assert_output --partial 'a-plan.md'
  # Each generated section once: from its own slot, not also inside the anchor.
  [ "$(grep -c 'a digest lesson' <<<"$output")" -eq 1 ]
}
