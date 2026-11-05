#!/usr/bin/env bats
# research-pick: the nightly research stage files one facet a night, never a facet already queued,
# and one "add a facet" row for a project the roster neither covers nor excludes.

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
  repo hot 6; repo cold 1; repo other 1
  mkdir -p "$SANDBOX/excluded"
  jq -n --arg s "$SANDBOX" '{paths: {($s + "/hot"): "hot", ($s + "/cold"): "cold", ($s + "/other"): "other", ($s + "/excluded"): "excluded", ($s + "/gone"): "gone"}}' > "$RESEARCH_MAP"
  jq -n --arg s "$SANDBOX" '{per_night: 1, exclude: ["excluded"], facets: [
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

@test "the busier of two equally stale facets is filed, though a tie would go to the other, with its scope and lenses, and recorded" {
  run "$PICK" run
  assert_success
  assert_called "ptask b2 --agent add research(hot): /rigor /stack-review plan $SANDBOX/hot src, lenses: hot paths, duplication; findings on b2"
  assert_not_called 'research(cold)'
  run jq -r .facet "$RESEARCH_DIR/picks.jsonl"
  assert_output hot
}

@test "a facet with an open research row is skipped, though nothing records it as picked" {
  echo 'research(hot): filed by hand' > "$NOTES_FIXTURE/board.b2"
  run "$PICK" run
  assert_success
  assert_called 'ptask b1 --agent add research(cold):'
  assert_not_called 'research(hot)'
}

@test "a facet picked today ranks below one never picked, whatever its churn" {
  mkdir -p "$RESEARCH_DIR"
  jq -cn '{facet: "hot", board: "b2", day: (now / 86400 | floor), date: "today"}' > "$RESEARCH_DIR/picks.jsonl"
  run "$PICK" rank
  assert_success
  assert_line --index 1 --regexp $'^[0-9]+\tcold\t60\t1\t0$'
  assert_line --index 2 --regexp $'^0\thot\t0\t6\t0$'
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

@test "--dry-run prints the rows and writes nothing" {
  run "$PICK" run --dry-run
  assert_success
  assert_output --partial 'would file [b2] research(hot):'
  assert_not_called 'add'
  [ ! -e "$RESEARCH_DIR/picks.jsonl" ]
}

@test "no roster: nothing to pick, and dream goes on" {
  rm "$RESEARCH_FACETS"
  run "$PICK" run
  assert_success
  assert_output --partial 'no roster'
}
