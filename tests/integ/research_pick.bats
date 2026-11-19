#!/usr/bin/env bats
# research-pick: the nightly research stage queues one facet a night, nothing while a research item
# is in flight, and one "add a facet" row for a project the roster neither covers nor excludes.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  PICK="$REPO_ROOT/.local/bin/research-pick"
  export RESEARCH_DIR="$SANDBOX/research" RESEARCH_FACETS="$SANDBOX/facets.json" RESEARCH_MAP="$SANDBOX/map.json"
  # The board: add appends the row (exit 3 on an open twin, like notes), list prints them as ptask list does.
  stub notes 'b="$NOTES_FIXTURE/board.$2"; touch "$b"; case "$4" in
    list) while IFS= read -r r; do printf "p\t1\t%s\t%s\n" "$r" "$r"; done < "$b" ;;
    add) printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; grep -qxF "$5" "$b" && exit 3; printf "%s\n" "$5" >> "$b" ;;
  esac; exit 0'
  # The queue: list prints queue.jsonl (exit 1 when it holds "unreadable"), add logs its arguments.
  stub agent-queue 'case "$1" in
    list) grep -q unreadable "$NOTES_FIXTURE/queue.jsonl" 2>/dev/null && exit 1; cat "$NOTES_FIXTURE/queue.jsonl" 2>/dev/null ;;
    add) printf "agent-queue %s\n" "$*" >> "$NOTES_FIXTURE/calls.log" ;;
  esac; exit 0'
  # A full board: the picker must not ask, and files regardless (the board-open watch alerts instead).
  stub fleet-bench 'echo "fleet-bench $*" >> "$NOTES_FIXTURE/calls.log"; echo "full: board_days 4 past board_days_max 2, board_open 9 (backlog 0)"; exit 1'
  repo hot 6; repo cold 1; repo other 1
  mkdir -p "$SANDBOX/excluded"
  jq -n --arg s "$SANDBOX" '{paths: {($s + "/hot"): "hot", ($s + "/cold"): "cold", ($s + "/other"): "other", ($s + "/excluded"): "excluded", ($s + "/gone"): "gone"}}' > "$RESEARCH_MAP"
  jq -n --arg s "$SANDBOX" '{exclude: ["excluded"], facets: [
    {id: "cold", repo: ($s + "/cold"), paths: [], board: "b1", lenses: ["gates"]},
    {id: "hot", repo: ($s + "/hot"), paths: ["src"], board: "b2", lenses: ["hot paths", "duplication"]}]}' > "$RESEARCH_FACETS"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# repo <name> <commits>: a git repo with that many commits under src/.
repo() {
  local d="$SANDBOX/$1" i
  git init -q "$d"; mkdir -p "$d/src"
  for i in $(seq "$2"); do echo "$i" > "$d/src/f"; git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -qm "c$i"; done
}

@test "the busier of two equally stale facets is queued, though a tie would go to the other, with its scope and lenses, and recorded" {
  run "$PICK" run
  assert_success
  assert_called "agent-queue add --project hot --priority low --from research:hot --tags research --repeat --slug research-hot --title research(hot) -- /rigor /stack-review research $SANDBOX/hot src, lenses: hot paths, duplication; findings on the b2 agent board tagged #research/hot"
  assert_not_called 'research(cold)'
  run jq -r .facet "$RESEARCH_DIR/picks.jsonl"
  assert_output hot
}

@test "a pick the queue sends to the board (exit 5) is said as filed and recorded with its row" {
  stub agent-queue 'case "$1" in add) echo "agent-queue: only the board fills the queue" >&2; echo "held research-hot -> agent-runtime:ar-7"; exit 5 ;; esac; exit 0'
  run "$PICK" run
  assert_output --partial 'hot: filed on its board as agent-runtime:ar-7, nothing queued'
  refute_output --partial 'agent-queue add failed'
  run jq -r '"\(.facet) \(.row)"' "$RESEARCH_DIR/picks.jsonl"
  assert_output 'hot agent-runtime:ar-7'
}

@test "a pick the outbox took (exit 5, no held line) is recorded with no row, so tomorrow picks another facet" {
  stub agent-queue 'case "$1" in add) echo "agent-queue: a session follow-up is no board row" >&2; echo "inboxed research-hot -> inbox"; exit 5 ;; esac; exit 0'
  run "$PICK" run
  assert_output --partial 'hot: filed through the outbox'
  run jq -c '[.facet, .row]' "$RESEARCH_DIR/picks.jsonl"
  assert_output '["hot",null]'
}

@test "a picked board row is in flight while the board lists it, open or under the item dispatch promoted it to (ar-3227)" {
  mkdir -p "$RESEARCH_DIR"
  # An older pick's row still counts after a later pick that was queued straight, with no row.
  printf '%s\n' '{"facet": "cold", "day": 1, "row": "agent-runtime:ar-7"}' '{"facet": "hot", "day": 2}' > "$RESEARCH_DIR/picks.jsonl"
  # The promoted item carries the row's slug and from, not research-cold: only the row says it is ours.
  echo '{"slug": "ar-7", "from": "board:agent-runtime:ar-7"}' > "$NOTES_FIXTURE/queue.jsonl"
  stub notes 'case "$1" in board) cat "$NOTES_FIXTURE/board.json" ;; *) case "$4" in list) exit 0 ;; add) printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log" ;; esac ;; esac; exit 0'
  echo '{"rows": [{"project": "agent-runtime", "id": "ar-7", "state": "doing"}]}' > "$NOTES_FIXTURE/board.json"
  run "$PICK" run
  assert_success
  assert_output --partial 'still in flight, nothing queued: ar-7 board row on agent-runtime, doing'
  assert_not_called 'agent-queue add'
  # negative control: the row closed, so the board no longer lists it, and tonight's pick is queued
  echo '{"rows": [{"project": "agent-runtime", "id": "ar-8", "state": "open"}]}' > "$NOTES_FIXTURE/board.json"
  run "$PICK" run
  assert_called 'agent-queue add --project '
}

@test "a board that cannot be read while a pick has a row queues nothing" {
  mkdir -p "$RESEARCH_DIR"
  echo '{"facet": "cold", "day": 1, "row": "agent-runtime:ar-7"}' > "$RESEARCH_DIR/picks.jsonl"
  stub notes 'case "$1" in board) exit 1 ;; esac; exit 0'
  run "$PICK" run
  assert_output --partial 'could not be read, nothing queued'
  assert_not_called 'agent-queue add'
}
@test "while a research item is in flight nothing is queued; another project's item does not count" {
  echo '{"slug": "x", "from": "research:cold"}' > "$NOTES_FIXTURE/queue.jsonl"
  run "$PICK" run
  assert_success
  assert_output --partial 'still in flight, nothing queued: x research:cold'
  assert_not_called 'agent-queue add'
  [ ! -e "$RESEARCH_DIR/picks.jsonl" ]
  echo '{"slug": "y", "from": "board:b2:ar-1"}' > "$NOTES_FIXTURE/queue.jsonl"
  run "$PICK" run
  assert_called 'agent-queue add --project hot'
}

@test "an unreadable queue queues nothing" {
  echo unreadable > "$NOTES_FIXTURE/queue.jsonl"
  run "$PICK" run
  assert_success
  assert_output --partial 'could not be read'
  assert_not_called 'agent-queue add'
}

@test "a facet picked today ranks below one never picked, whatever its churn" {
  mkdir -p "$RESEARCH_DIR"
  jq -cn '{facet: "hot", day: (now / 86400 | floor), date: "today"}' > "$RESEARCH_DIR/picks.jsonl"
  run "$PICK" rank
  assert_success
  assert_line --index 1 --regexp $'^[0-9]+\tcold\t60\t1$'
  assert_line --index 2 --regexp $'^0\thot\t0\t6$'
}

@test "one roster row for the first uncovered project; excluded, covered and missing ones never" {
  run "$PICK" run
  assert_success
  assert_called "ptask agent-runtime --agent add research(roster): add a facet for other ($SANDBOX/other)"
  assert_not_called 'facet for excluded'
  assert_not_called 'facet for gone'
  assert_not_called 'facet for hot'
}

@test "no second roster row while one is open" {
  "$PICK" run
  jq '.exclude += ["other"]' "$RESEARCH_FACETS" > "$SANDBOX/f" && mv "$SANDBOX/f" "$RESEARCH_FACETS"
  jq --arg s "$SANDBOX" '.paths[$s + "/new"] = "new"' "$RESEARCH_MAP" > "$SANDBOX/m" && mv "$SANDBOX/m" "$RESEARCH_MAP"
  mkdir -p "$SANDBOX/new"
  : > "$NOTES_FIXTURE/calls.log"
  run "$PICK" run
  assert_success
  assert_output --partial 'coverage: new uncovered, a roster row is already open'
  assert_not_called 'research(roster)'
}

@test "an open roster row on a long board is seen with SIGPIPE ignored, as under systemd" {
  # The row comes first and 5000 more follow (about 130 KB, past the 64 KB pipe buffer), so a
  # reader that stops at the first hit leaves the writer an EPIPE; before, pipefail read that
  # as "none open" and the log said "picked".
  stub notes 'case "$4" in
    list) printf "p\t1\tr\tresearch(roster): add a facet for x\n"; for i in $(seq 5000); do printf "p\t%s\tr\tfiller row %s\n" "$i" "$i"; done ;;
    add) printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; exit 3 ;;
  esac; exit 0'
  run bash -c 'trap "" PIPE; exec "$0" run' "$PICK"
  assert_success
  assert_output --partial 'coverage: other uncovered, a roster row is already open'
  refute_output --partial 'filed a roster row'
  assert_not_called 'research(roster)'
}

@test "an open twin (notes exit 3) is said as already open, not as filed" {
  stub notes 'case "$4" in list) exit 0 ;; add) printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; exit 3 ;; esac; exit 0'
  run "$PICK" run
  assert_success
  assert_output --partial 'coverage: other uncovered, a roster row is already open'
  refute_output --partial 'filed a roster row'
}

@test "an unreadable board files nothing and says so" {
  stub notes 'case "$4" in list) exit 1 ;; add) printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log" ;; esac; exit 0'
  run "$PICK" run
  assert_success
  assert_output --partial 'coverage: other uncovered, the board could not be read, nothing filed'
  assert_not_called 'research(roster)'
}

@test "an add that fails, even with exit 2, is said as failed, not as an unreadable board" {
  stub notes 'case "$4" in list) exit 0 ;; add) exit 2 ;; esac; exit 0'
  run "$PICK" run
  assert_success
  assert_output --partial 'coverage: other uncovered, notes ptask add failed (exit 2)'
  refute_output --partial 'could not be read'
}

@test "a full board does not hold the roster row, and the picker never asks fleet-bench" {
  run "$PICK" run
  assert_success
  assert_output --partial 'coverage: filed a roster row for other'
  assert_called 'research(roster)'
  assert_called 'agent-queue add'
  assert_not_called 'fleet-bench'
}

@test "--dry-run prints the rows and writes nothing" {
  run "$PICK" run --dry-run
  assert_success
  assert_output --partial "would queue [hot] /rigor /stack-review research $SANDBOX/hot"
  assert_output --partial 'coverage: would file a roster row for other'
  refute_output --partial 'coverage: filed'
  assert_not_called 'add'
  [ ! -e "$RESEARCH_DIR/picks.jsonl" ]
}

@test "no roster: nothing to pick, and dream goes on" {
  rm "$RESEARCH_FACETS"
  run "$PICK" run
  assert_success
  assert_output --partial 'no roster'
}

@test "against the real agent-queue: a script's pick is never queued; it goes to the board, here none, which it says" {
  ln -sf "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export AGENT_QUEUE_DIR="$SANDBOX/queue" AGENT_QUEUE_PROJECT_MAP="$RESEARCH_MAP"
  unset AGENT_QUEUE_PULL AGENT_QUEUE_ITEM
  jq '.facets |= map(select(.id == "hot"))' "$RESEARCH_FACETS" > "$SANDBOX/f" && mv "$SANDBOX/f" "$RESEARCH_FACETS"
  run "$PICK" run
  assert_success
  assert_output --partial 'hot: nothing queued, agent-queue add failed: agent-queue: hot has no board row'
  run agent-queue list --json --state queued
  assert_output ''
}
