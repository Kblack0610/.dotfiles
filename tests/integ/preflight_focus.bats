#!/usr/bin/env bats
# session-preflight.sh: the turn-1 context injection. Most of these pin the byte budget and the
# lessons lane; the first ones pin what turn 1 no longer carries (the human's Focus list, a second
# copy of the commits Claude Code's gitStatus already shows).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # gh is the one network-reaching call in the hook. Stub it so this test is hermetic and
  # does not depend on a runner having credentials (or a repo having a remote).
  gh_script 'exit 1'
  # The lessons ranker, as stow deploys it onto PATH. CI has no stow.
  ln -s "$REPO_ROOT/.local/bin/lessons" "$SANDBOX/bin/lessons"

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

@test "the human's Focus list is not turn-1 context" {
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
{ "paths": { "$REPO": "toolrepo" },
  "trackers": { "shop": { "repo": "toolrepo", "path": "apps/shop" } } }
EOF
  mkdir -p "$REPO/apps/shop"
  echo x > "$REPO/apps/shop/f"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "shop commit"
  export CLAUDE_PROJECT_DIR="$REPO/apps/shop"
  item_stub 'x P2: repo wide lesson'
  run context
  assert_output --partial 'Recent commits (last 5, apps/shop)'
  assert_output --partial 'shop commit'
  # Negative control: the commit outside the subtree stays out.
  refute_output --partial 'first commit'
}

# -- the tracker registry and the one size budget ----------------------------------

# A registry whose repo hop matches this test's project, INCLUDING the string-valued
# comment key that lives in the real one.
seed_tracker_map() {
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$REPO": "toolrepo" },
  "trackers": {
    "_comment_lab_projects": "a STRING value; an unguarded .value.repo dies on this",
    "notes-cockpit": { "system": "board", "repo": "toolrepo" },
    "agent-runtime": { "system": "board", "repo": "toolrepo" }
  }
}
EOF
}

@test "a registry with a STRING-valued trackers key still emits a full context" {
  # The direct negative control for the jq trap. `.trackers` holds a documentation key
  # whose value is a string; an unguarded `.value.repo` over it exits 5, and under this
  # hook's `set -e` that costs the ENTIRE turn-1 context with no error anyone sees.
  cp "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  # The hold scoping joins through project_lab_names, the other reader of the registry.
  export AGENT_HOLD_DIR="$HOME/.agent/holds"
  "$REPO_ROOT/.local/bin/agent-hold" set pause --kind resource --by human "pause the agent-runtime lanes"

  run context
  assert_success
  assert_output --partial 'Session Preflight'
  assert_output --partial 'pause since'
  refute_output --partial 'Cannot index string'
}

@test "an app session gets its REPO's lessons as parent, and no other tracker's" {
  # The corpus that binds an app is its repo's. NEGATIVE CONTROL: another registered
  # tracker's lessons stay out.
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$REPO": "toolrepo" },
  "trackers": {
    "_comment": "a string value",
    "ticket-parent": { "system": "board" },
    "shop": { "repo": "toolrepo", "path": "apps/shop" }
  }
}
EOF
  mkdir -p "$REPO/apps/shop" "$HOME/.agent/lessons"
  echo "- a repo-wide lesson" > "$HOME/.agent/lessons/toolrepo.md"
  echo "- a repo wide ticket-parent lesson" > "$HOME/.agent/lessons/ticket-parent.md"
  export CLAUDE_PROJECT_DIR="$REPO/apps/shop"
  item_stub 'x P2: repo wide lesson'

  run context
  assert_success
  assert_output --partial 'Session Preflight: shop'
  assert_output --partial 'a repo-wide lesson'
  refute_output --partial 'ticket-parent lesson'
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
  } > "$a"
  mkdir -p "$HOME/.agent/lessons"
  {
    echo "- a digest lesson"
    for i in $(seq 2 "$2"); do echo "- lesson $i $(printf 'word %.0s' $(seq 1 40))"; done
  } > "$HOME/.agent/lessons/toolrepo.md"
}

# item_stub <title>: an agent-queue whose item has that title, so the lessons are matched to it.
item_stub() {
  printf '#!/usr/bin/env bash\n[ "$1" = show ] && echo %s\n' "'{\"title\":\"$1\"}'" > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  export AGENT_QUEUE_ITEM=some-plan-p2
}

@test "a large anchor stays under 9,000 B: the lessons digest is left out and named" {
  cp "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_anchor_sized 40 10
  item_stub 'some-plan P2: digest lesson words'

  local out n
  out=$(context)
  n=$(printf '%s' "$out" | wc -c)
  [ "$n" -lt 9000 ] || { echo "turn-1 context is $n bytes, over 9,000" >&2; return 1; }
  [[ "$out" == *"a fact that must survive"* ]]
  [[ "$out" == *"Decisions log: 40 entries"* ]]
  [[ "$out" == *"+ omitted to fit the 9000 B turn-1 budget:"* ]]
  [[ "$out" == *"lessons digest ("* ]]
  # A digest that did not reach the context is not a delivery.
  [ ! -e "$HOME/.agent/lessons/_delivered" ]
}

@test "small inputs omit nothing, and the matched lessons and plans arrive" {
  cp "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  seed_anchor_sized 1 2
  item_stub 'some-plan P2: digest lesson words'

  run context
  assert_success
  refute_output --partial 'omitted to fit'
  assert_output --partial '## Lessons for this work ('
  assert_output --partial 'a digest lesson'
  assert_output --partial 'a-plan.md'
  [ "$(grep -c 'a-plan.md' <<<"$output")" -eq 1 ]
}

@test "lessons that match the queue item's task come first, and only the matched one is logged" {
  cp "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" "$DEPLOY/"
  seed_tracker_map
  mkdir -p "$HOME/.agent/lessons"
  {
    echo "- **2026-01-01** A waybar chip costs width on the bar."
    for i in 1 2 3 4 5 6; do echo "- **2026-02-0$i** unrelated lesson number $i."; done
  } > "$HOME/.agent/lessons/toolrepo.md"
  printf '#!/usr/bin/env bash\n[ "$1" = show ] && echo %s\n' \
    "'{\"title\":\"some-plan P2: make the waybar chip narrower\"}'" > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  export AGENT_QUEUE_ITEM=some-plan-p2

  run context
  assert_success
  assert_output --partial '## Lessons for this work (1 matched on: waybar, chip)'
  [ "$(grep -A1 '## Lessons for this work' <<<"$output" | tail -1)" = "- **2026-01-01** A waybar chip costs width on the bar." ]
  refute_output --partial 'unrelated lesson'
  run cat "$HOME/.agent/lessons/_delivered/$(date +%Y-%m).tsv"
  assert_output --regexp "^$(date +%F)	toolrepo	[0-9a-f]{8}$"
}
