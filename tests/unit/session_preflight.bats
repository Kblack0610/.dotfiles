#!/usr/bin/env bats
# session-preflight.sh turn-1 cuts (context trim p2, phase 2): no board block, a dispatched
# session's own queue row, matched lessons only and cut at a sentence end, holds scoped to the
# project, one count line for open sessions, and an anchor without Lab, Links or an empty
# Blockers. Each cut has a negative control: what must still print does.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  gh_script 'exit 1'
  ln -s "$REPO_ROOT/.local/bin/lessons" "$SANDBOX/bin/lessons"

  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo hello > "$REPO/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "first commit"
  REPO="$(realpath "$REPO")"
  export CLAUDE_PROJECT_DIR="$REPO"

  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$REPO": "toolrepo" },
  "trackers": {
    "_comment": "a string value",
    "toolboard": { "system": "board", "repo": "toolrepo" },
    "otherproj": { "system": "board", "repo": "otherrepo" }
  }
}
EOF

  DEPLOY="$SANDBOX/shared-hooks"
  mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/session-preflight.sh" \
     "$REPO_ROOT/.config/shared-hooks/anchor-lib.sh" \
     "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$DEPLOY/"

  export AGENT_HOLD_DIR="$HOME/.agent/holds"
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  unset AGENT_QUEUE_ITEM
}

context() {
  printf '{"source":"startup","session_id":"me-0000-0000"}' \
    | bash "$DEPLOY/session-preflight.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

# -- board ---------------------------------------------------------------------------------

@test "no board block: notes is never asked, and a board row never reaches turn 1" {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/notes-calls.log"
printf 'toolboard\tsome backlog row\n'
EOF
  chmod +x "$SANDBOX/bin/notes"
  run context
  assert_success
  assert_output --partial 'Session Preflight: toolrepo'
  refute_output --partial 'some backlog row'
  refute_output --partial 'in flight'
  refute_output --partial 'Agent board'
  [ ! -e "$SANDBOX/notes-calls.log" ]
}

@test "a dispatched session gets its own queue item row, and nothing else of the board" {
  export AGENT_QUEUE_ITEM=my-item
  printf '#!/usr/bin/env bash\n[ "$1" = show ] && echo %s\n' \
    "'{\"title\":\"my-item P2: narrow the preflight\",\"row\":\"toolboard:ar-9\"}'" > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  run context
  assert_success
  assert_output --partial 'Your queue item: my-item (board row toolboard:ar-9): narrow the preflight'
}

@test "a hand session has no queue item line" {
  run context
  refute_output --partial 'Your queue item'
}

# -- lessons -------------------------------------------------------------------------------

seed_lessons() {
  mkdir -p "$HOME/.agent/lessons"
  {
    echo "- **2026-01-01** A waybar chip costs width on the bar. Keep each chip narrow."
    for i in 1 2 3 4 5 6; do echo "- **2026-02-0$i** unrelated lesson number $i."; done
  } > "$HOME/.agent/lessons/toolrepo.md"
}

item_stub() { # <title>
  printf '#!/usr/bin/env bash\n[ "$1" = show ] && echo %s\n' "'{\"title\":\"$1\"}'" > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
}

@test "a lesson that matches the work prints (negative control for the cut)" {
  seed_lessons
  export AGENT_QUEUE_ITEM=my-item
  item_stub 'my-item P2: make the waybar chip narrower'
  run context
  assert_success
  assert_output --partial '## Lessons for this work (1 matched on: '
  assert_output --partial 'A waybar chip costs width'
  refute_output --partial 'unrelated lesson'
}

@test "no match, no lessons: the newest five are not a fallback" {
  seed_lessons
  run context
  assert_success
  refute_output --partial 'Lessons'
  refute_output --partial 'unrelated lesson'
  refute_output --partial 'nothing matched'
}

@test "a long matched lesson is cut where a sentence ends, not mid-rule" {
  mkdir -p "$HOME/.agent/lessons"
  {
    printf -- '- **2026-03-01** **A waybar chip costs width on the bar.** '
    printf 'Keep it narrow because %s all of it adds up. ' "$(printf 'every extra pixel %.0s' $(seq 1 8))"
    printf 'THIS SENTENCE STARTS PAST THE CAP %s and has no reason to be in turn one at all.\n' "$(printf 'padding %.0s' $(seq 1 30))"
  } > "$HOME/.agent/lessons/toolrepo.md"
  export AGENT_QUEUE_ITEM=my-item
  item_stub 'my-item P2: make the waybar chip narrower'
  run context
  assert_success
  line=$(grep -F 'A waybar chip costs width' <<<"$output")
  [[ $line == *'all of it adds up.' ]]
  refute_output --partial 'THIS SENTENCE'
}

# -- holds ---------------------------------------------------------------------------------

@test "a load hold and a hold naming this project print; another project's hold is one count line" {
  hold() { "$REPO_ROOT/.local/bin/agent-hold" set "$@"; }
  hold unity-tests --by cap "96 C, 16 editors"
  hold row-x-1 --kind resource --by fleet-dispatch "keep the console step held (otherproj)"
  hold toolrepo-freeze --kind resource --by human "no merges to toolrepo until the human says"
  run context
  assert_success
  assert_output --partial 'Active holds'
  assert_output --partial 'unity-tests since'
  assert_output --partial 'toolrepo-freeze since'
  refute_output --partial 'row-x-1'
  refute_output --partial 'console step'
  assert_output --partial '+1 hold(s) for other projects or claims'
}

@test "a hold naming one of the repo's lab projects prints" {
  "$REPO_ROOT/.local/bin/agent-hold" set pause-it --kind resource --by human "pause the toolboard lanes"
  run context
  assert_output --partial 'pause-it since'
}

@test "only other projects' holds: no heading, just the count line" {
  "$REPO_ROOT/.local/bin/agent-hold" set row-y-2 --kind resource --by fleet-dispatch "held (otherproj)"
  run context
  refute_output --partial 'Active holds'
  assert_output --partial '+1 hold(s) for other projects or claims'
}

@test "a long hold reason is one line, cut at its first sentence end" {
  long="Stop the playloop until the playground is stable, as the human decided on the 19th. $(printf 'more detail %.0s' $(seq 1 30))"
  "$REPO_ROOT/.local/bin/agent-hold" set unity-slow --by human "$long"
  run context
  line=$(grep -F 'unity-slow since' <<<"$output")
  [[ $line == *'on the 19th.' ]]
  refute_output --partial 'more detail'
}

@test "a resource hold naming no project prints (a workflow pause), a claim does not" {
  hold() { "$REPO_ROOT/.local/bin/agent-hold" set "$@"; }
  hold dispatch --by human "paused while the cluster is rebuilt"
  printf 'resource: row-z-3\nkind: claim\nsince: now\nby: fleet-dispatch\nreason: claimed for a session\n' > "$AGENT_HOLD_DIR/row-z-3"
  run context
  assert_output --partial 'dispatch since'
  refute_output --partial 'row-z-3'
  assert_output --partial '+1 hold(s) for other projects or claims'
}

# -- open sessions -------------------------------------------------------------------------

@test "open sessions are one count line, with no topics" {
  jq -n --argjson e "$(date +%s)" --arg c "$REPO" '{generated_epoch: $e,
    vocab: {buckets: ["WORKING","DONE"], finished: ["DONE"]},
    sessions: [{session_id: "aaaaaaaa-1", bucket: "WORKING", idle_min: 0, topic: "a private topic", cwd: $c},
               {session_id: "bbbbbbbb-2", bucket: "WORKING", idle_min: 0, topic: "another topic", cwd: $c},
               {session_id: "cccccccc-3", bucket: "DONE", idle_min: 0, topic: "finished", cwd: $c},
               {session_id: "me-0000-0000", bucket: "WORKING", idle_min: 0, topic: "me", cwd: $c}]}' > "$FLEET_STATE_FILE"
  run context
  assert_success
  assert_output --partial '2 other session(s) open in this checkout'
  refute_output --partial 'a private topic'
  refute_output --partial 'Open sessions'
}

# -- anchor --------------------------------------------------------------------------------

seed_anchor() { # <blockers body>
  mkdir -p "$HOME/.agent/anchors"
  cat > "$HOME/.agent/anchors/toolrepo.md" <<EOF
# toolrepo - anchor

## Key URLs & facts
- **Repo:** a fact that must survive

## Decisions log
- **2026-08-01:** a decision

## Blockers / known issues
$1

## Links
- Plans: ~/.agent/plans/toolrepo/

## Lab
- **toolboard** (personal) v0.1: no window
EOF
}

@test "an empty none-yet Blockers is dropped too, and a blocker saying none active is kept" {
  seed_anchor '- _(none yet)_'
  run context
  refute_output --partial 'Blockers'
  seed_anchor '- the deploy is down; none active workaround exists'
  run context
  assert_output --partial 'none active workaround exists'
}

@test "the anchor drops Lab, Links and an empty Blockers, and keeps the facts" {
  seed_anchor '- _(none active)_'
  run context
  assert_success
  assert_output --partial 'a fact that must survive'
  assert_output --partial 'Decisions log: 1 entry'
  refute_output --partial 'Blockers'
  refute_output --partial '## Links'
  refute_output --partial '## Lab'
  refute_output --partial 'no window'
}

@test "a real blocker still prints (negative control)" {
  seed_anchor '- the registry is down until Friday'
  run context
  assert_output --partial '## Blockers / known issues'
  assert_output --partial 'the registry is down until Friday'
}
