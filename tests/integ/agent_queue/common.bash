# shellcheck shell=bash
# The setup and fixtures tests/integ/agent_queue.bats and agent_queue_part2.bats both load, so CI shards can spread the two halves.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  sandbox_worlds
  AQ="$REPO_ROOT/.local/bin/agent-queue"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue"
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  # The wall clock never decides a test: holds read this hour (a test that needs another sets its own).
  export AGENT_QUEUE_NOW=12:00
  # Fixtures add as dispatch's pull; the board-only tests unset it to be an agent or a filer.
  export AGENT_QUEUE_PULL=dispatch
  REPO="$SANDBOX/repos/game"
  git init -q "$REPO"
  # Two games in the game repo (level, arena), a repo whose work counts on its owner (tools ->
  # cockpit), and a project with a row code in another checkout (elsewhere).
  jq -n --arg r "$REPO" '{paths: {($r): "game", "/x/app": "app", "/x/tools": "tools"},
    trackers: {"game": {names: ["g2"]}, "level": {repo: "game", path: "Assets/Level", code: "lv"}, "arena": {repo: "game", path: "Assets/Arena/", code: "ar"},
      "notes": {repo: null}, "app": {}, "tools": {owner: "cockpit"}, "cockpit": {repo: "tools"},
      "elsewhere": {repo: "app", code: "el"}}}' > "$AGENT_QUEUE_PROJECT_MAP"
  # A plan item starts its session through fleet-dispatch: a recording stub, never the real one.
  printf '#!/usr/bin/env bash\necho "fleet-dispatch $*" >> "$NOTES_FIXTURE/calls.log"\nexit "${FD_EXIT:-0}"\n' > "$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/fleet-dispatch"
  # The caller's Claude session stamps items and decides mine: a test sets it, never inherits it.
  unset CLAUDE_CODE_SESSION_ID
}

# The file is a redirect, not an operand: awk reads stdin for an empty one, which hangs a local run (ar-3455).
field() { awk -v k="$2: " '$0 == "---" { exit } index($0, k) == 1 { print substr($0, length(k) + 1) }' <"$1"; }
item() { ls "$AGENT_QUEUE_DIR"/"$1"/*-"$2".md; }
# A done item sits under its close day: the glob stays outside the quotes, since the sandbox path has a space.
done_item() { ls "$AGENT_QUEUE_DIR"/done/*/*-"$1".md; }

# The class mix (plan can-we-move-our-mellow-sphinx P3): fixture done items in and out of the window,
# a held item, and the switch off as the negative control.
mix_done() { # <day> <slug> <from> <task> [started]
  local started='' type=''
  mkdir -p "$AGENT_QUEUE_DIR/done/$1"
  # The row type `add` stamps from `notes row parse`; a fixture spells it from the task.
  [[ $4 != *:* ]] || type="type: ${4%%:*}"$'\n'
  [ -z "${5:-}" ] || started="started: $1T00:30:00Z"$'\n'
  printf 'slug: %s\nproject: game\npriority: high\nfrom: %s\nqueued: %sT00:00:00Z\n%s%sstatus: %s\nfinished: %sT01:00:00Z\n---\n%s\n' \
    "$2" "$3" "$1" "$type" "$started" "$([ -n "${5:-}" ] && echo ok || echo cancelled)" "$1" "$4" > "$AGENT_QUEUE_DIR/done/$1/x-$2.md"
}
# The shipped classes without their min_live: these cases are about shares, and a class under its minimum goes first (the "min_live" cases write their own).
mix_classes() { jq --argjson on "$1" '.on = $on | del(.classes[].min_live)' "$REPO_ROOT/.config/fleet-dispatch/classes.json" > "$SANDBOX/classes.json"; }

# A fake rbw for the gate tests: unlocked, list prints rbw.list, every call logged. Never the real one.
gate_rbw() {
  printf '#!/usr/bin/env bash\necho "rbw $*" >> "%s/rbw.calls"\ncase "$1" in unlocked) ;; list) cat "%s/rbw.list" ;; *) exit 9 ;; esac\n' \
    "$SANDBOX" "$SANDBOX" > "$SANDBOX/rbw-fake"
  chmod +x "$SANDBOX/rbw-fake"
  export AGENT_QUEUE_RBW="$SANDBOX/rbw-fake"
  printf 'infra\tx\n' > "$SANDBOX/rbw.list"
}

# handoff_repo: a checkout on branch feat, one commit past origin/main (pushed: main only), and a
# handoff note in the sandbox HOME's plans.
handoff_repo() {
  ORIGIN="$SANDBOX/origin.git" WT="$SANDBOX/wt" NOTE="$HOME/.claude/plans/h.md"
  git init -q --bare "$ORIGIN"
  git init -q -b main "$WT"
  git -C "$WT" remote add origin "$ORIGIN"
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$WT" push -q -u origin main 2>/dev/null
  git -C "$WT" checkout -q -b feat
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  mkdir -p "${NOTE%/*}"
  printf '## Handoff\ndone: the parser, tests green\nnext: the menu\n' > "$NOTE"
}

plan_fixture() {
  cat > "$SANDBOX/my-plan.md" <<'EOF'
# A plan

## Phases

- [x] 1. Landed thing: details
- [ ] 2. Second thing: details
  - [ ] a step inside phase 2
- [-] 3. Deferred thing
- [ ] 4. Fourth thing. More words
- [ ] 5. Fifth thing (with 4): shares the branch of 4
- [ ] 6. Sixth thing

## Verification

- [ ] not a phase
EOF
}

# ar-2922: an add --plan that stopped part way (a lock it timed out on) left the first items of a chain.
chain_plan() {  # <name>: a four-phase plan, each phase after the one before
  printf '# %s\n\n## Phases\n\n- [ ] 1. one\n- [ ] 2. two\n- [ ] 3. three\n- [ ] 4. four\n' "$1" > "$SANDBOX/$1.md"
}

# A test that leaves a writer or reader waiting on a held lock: a failed assert must not leave it behind.
teardown() {
  exec 7>&-
  [ -z "${WRITER:-}" ] || kill "$WRITER" 2>/dev/null || true
  [ -z "${READER:-}" ] || kill "$READER" 2>/dev/null || true
}

# story_notes -- give the level and arena games a lab sheet, and a notes stub for the story write:
# every call lands in calls.log; `ptask ... start <id>` fails once closed.<id> exists (no open row);
# `ptask ... add` prints its row with id lv-9 (lv-<n> counting up from story.seq when that file holds <n>) and exits 0, or, with
# story.rc set, prints story.out on stderr and exits story.rc (3 is ptask's "already open").
# `ptask ... propose` prints propose.out, else its words unchanged; propose.rc makes it refuse.
# `ptask ... done` fails once done.rc exists (no open row), `ptask ... run` once run.rc does; `ptask ... list` prints list.out, or fails with list.rc.
story_notes() {
  jq '.trackers.level.lab = "bnb" | .trackers.arena.lab = "bnb"' "$AGENT_QUEUE_PROJECT_MAP" > "$SANDBOX/m.json"
  mv "$SANDBOX/m.json" "$AGENT_QUEUE_PROJECT_MAP"
  cat > "$SANDBOX/bin/notes" <<'STUB'
#!/usr/bin/env bash
printf 'notes %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
case " $* " in
*' propose '*)
  if [ -e "$NOTES_FIXTURE/propose.rc" ]; then echo "error: unrecognized subcommand 'propose'" >&2; exit 2; fi
  if [ -e "$NOTES_FIXTURE/propose.out" ]; then cat "$NOTES_FIXTURE/propose.out"; else printf '%s\n' "${@: -1}"; fi
  exit 0 ;;
*' add '*)
  rc=$(cat "$NOTES_FIXTURE/story.rc" 2>/dev/null || echo 0)
  id=9; if [ -s "$NOTES_FIXTURE/story.seq" ]; then id=$(cat "$NOTES_FIXTURE/story.seq"); echo $((id + 1)) > "$NOTES_FIXTURE/story.seq"; fi
  if [ "$rc" = 0 ]; then printf -- '- [ ] %s #c1105 <!-- id:lv-%s -->\n' "${@: -1}" "$id"; else cat "$NOTES_FIXTURE/story.out" >&2; fi
  exit "$rc" ;;
*' start '*) [ ! -e "$NOTES_FIXTURE/closed.${@: -1}" ] && [ ! -e "$NOTES_FIXTURE/closed.$4.${@: -1}" ] ||
  { echo "no open task matches" >&2; exit 1; } ;;
*' done '*) [ ! -e "$NOTES_FIXTURE/done.rc" ] || { echo "no open task matches" >&2; exit 1; } ;;
*' run '*) [ ! -e "$NOTES_FIXTURE/run.rc" ] || { echo "no open task matches" >&2; exit 1; } ;;
*' list '*) [ ! -e "$NOTES_FIXTURE/list.rc" ] || exit 1; cat "$NOTES_FIXTURE/list.out" 2>/dev/null ;;
*' board '*) cat "$NOTES_FIXTURE/board.json" 2>/dev/null; exit 0 ;;
' log --trace '*) [ ! -e "$NOTES_FIXTURE/trace.fail" ] || { echo "notes: index locked" >&2; exit 2; }; [ -s "$NOTES_FIXTURE/trace" ] || { echo "no event in the record matches" >&2; exit 1; }; cat "$NOTES_FIXTURE/trace"; exit 0 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/notes"
}

# queue-held-to-board (ar-3121): no writer leaves a queued item with a pending hold; each gate goes on
# the item's board row instead. no_held fails on any queued item list --json reads a hold for.
no_held() {
  local held
  held="$("$AQ" list --state queued --json | jq -r 'select((.hold // "") != "") | "\(.slug): \(.hold)"')"
  [ -z "$held" ] || fail "queued items that hold: $held"
}

# --- admission: the cap on runnable items (ar-2918) ---------------------------------------

# ar-3852: an after: on an item that is live with an open PR is stacked, not held.
stack_gh() {
  export AGENT_QUEUE_PR_CACHE="$SANDBOX/pr-cache"
  # gh stub: the state of PR N is the file $SANDBOX/pr-N.
  gh_script "cat \"$SANDBOX/pr-\$3\""
  echo OPEN > "$SANDBOX/pr-7"
}

# row_item <slug> <row> <priority> [tags] -- a queued item that works <row>, at its own <priority>.
row_item() {
  mkdir -p "$AGENT_QUEUE_DIR/queued"
  local n; n="$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)"
  { printf 'slug: %s\nproject: level\nmode: oneshot\npriority: %s\nweight: light\n' "$1" "$3"
    [ -z "${4:-}" ] || printf 'tags: %s\n' "$4"
    printf 'from: session\nagent: claude\nqueued: 2026-11-07T01:00:0%sZ\nrow: %s\nlane: agent\nprofile: bnb\n---\n%s\n' "$n" "$2" "$1"
  } > "$AGENT_QUEUE_DIR/queued/2026110701000$n-$1.md"
}
