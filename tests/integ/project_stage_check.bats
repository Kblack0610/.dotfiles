#!/usr/bin/env bats
# project-stage-check runs the Requirements rows of stages.md for a project, and
# project-map-doctor 6c turns its exit into WARN or FAIL. A tiny stages doc stands in for
# the real one, so each test pins one row kind against a real repo and lab dir.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  CHECK="$REPO_ROOT/.local/bin/project-stage-check"
  DOCTOR="$REPO_ROOT/.local/bin/project-map-doctor"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export LAB_FEED_LIB="$REPO_ROOT/.local/lib/lab-feed.sh"
  export AGENT_DIR="$HOME/agent"
  mkdir -p "$AGENT_DIR/plans" "$AGENT_DIR/lessons" "$AGENT_DIR/sessions"
  printf 'draft dev alpha beta prod\n' > "$NOTES_FIXTURE/stages"

  export STAGES_DOC="$HOME/stages.md"
  cat > "$STAGES_DOC" <<'EOF'
# Stages

## Requirements

Enforced from: 2026-11-19

| Stage | Applies | Requirement | Check | Dept |
|---|---|---|---|---|
| draft | base | A lab sheet | `[ -f "$LAB/README.md" ]` | product |
| draft | game | The shared packages | `grep -q blacknbrown "$REPO/Packages/manifest.json"` | engineering |
| dev | base | A README where the project lives | `[ -f README.md ]` | engineering |
| dev | app | An app-only row | `false` | product |
| alpha | base | Plays start to finish | human | product |
| alpha | base | A deploy workflow | not yet: needs the forge API | ops |
| alpha | base | A cell with a \| pipe | `printf 'a\|b' \| grep -q b` | engineering |
| beta | base | A changelog | `[ -f CHANGELOG.md ]` | engineering |

## Elsewhere

| draft | base | A table outside Requirements | `false` | product |

## Departments

| Id | Title | Question | Owns |
| --- | --- | --- | --- |
| product | Product | Is it the thing? | the brief |
| engineering | Engineering | Does it build? | the README |
| ops | Ops | Does it stay up? | the runbook |
EOF

  # A game inside a monorepo: the packages live at the repo root, its README in its folder.
  REPO="$HOME/games"
  mkdir -p "$REPO/Packages" "$REPO/Assets/Games/Shooter"
  printf '{"dependencies":{"com.blacknbrown.core":"1.0.0"}}\n' > "$REPO/Packages/manifest.json"
  printf '# shooter\n' > "$REPO/Assets/Games/Shooter/README.md"
  export PROJECT_MAP_FILE="$HOME/project-map.json"
  jq -n --arg r "$REPO" '{
    paths: {($r): "games-canon"},
    trackers: {
      "games-canon": {system: "board"},
      shooter: {repo: "games-canon", path: "Assets/Games/Shooter", lab: "personal", type: "game"},
      default: {system: "board"}
    }}' > "$PROJECT_MAP_FILE"

  ROOTS="$HOME/vault/personal/projects/current"
  printf '%s\n' "$ROOTS" > "$NOTES_FIXTURE/path.personal.projects"
  printf 'lab_roots() { printf "%%s\\n" "%s"; }\n' "$ROOTS" > "$HOME/lab-roots.sh"
  export LAB_ROOTS_LIB="$HOME/lab-roots.sh"
  LAB="$ROOTS/shooter"
  mkdir -p "$LAB"
  printf '# shooter\n' > "$LAB/summary.md"
  declare_stage dev
  export STAGE_GATE_TODAY=2026-11-01
  # The row a --file run adds on the agent sheet, as `notes ptask --agent add` prints it.
  printf -- '- [ ] chore(stage): meet the beta stage standard <!-- id:sh-7 -->\n' > "$NOTES_FIXTURE/ptask.agent.added"
}

declare_stage() { printf '# shooter\nVersion: v0.1.0 #%s\n\n## Tasks\n' "$1" > "$LAB/README.md"; }

@test "the declared stage and every stage below it run, for base and the project's type" {
  run "$CHECK" shooter
  assert_success
  assert_line --index 0 --regexp '^PASS +draft +A lab sheet$'
  assert_line --index 1 --regexp '^PASS +draft +The shared packages$'
  assert_line --index 2 --regexp '^PASS +dev +A README where the project lives$'
  assert_line --index 3 'gate: shooter meets #dev'
  refute_output --partial 'app-only'
  refute_output --partial 'alpha'
  refute_output --partial 'outside Requirements'
}

@test "a predicate runs from the project's own folder in a monorepo, not the repo root" {
  rm "$REPO/Assets/Games/Shooter/README.md"
  printf '# games\n' > "$REPO/README.md"
  run "$CHECK" shooter
  assert_output --regexp 'FAIL +dev +A README where the project lives'
}

@test "human rows are listed, prose rows are TODO, and an escaped pipe stays in its cell" {
  run "$CHECK" shooter --stage alpha
  assert_success
  assert_output --regexp 'HUMAN alpha +Plays start to finish'
  assert_output --regexp 'TODO +alpha +A deploy workflow \(not yet: needs the forge API\)'
  assert_output --regexp 'PASS +alpha +A cell with a \| pipe'
}

@test "before the Enforced from date a failing row reports and exits 0" {
  run "$CHECK" shooter --stage beta
  assert_success
  assert_output --regexp 'FAIL +beta +A changelog'
  assert_output --partial 'gate: shooter fails 1 row(s) for #beta (report-only until 2026-11-19)'
}

@test "from the Enforced from date a failing row blocks with exit 1" {
  STAGE_GATE_TODAY=2026-11-19 run "$CHECK" shooter --stage beta
  assert_failure 1
  assert_output --partial 'gate: shooter fails 1 row(s) for #beta'
  refute_output --partial 'report-only'
}

@test "--json gives the stage, counts, gate and each row, with the text mode's exit" {
  run "$CHECK" shooter --stage alpha --json
  assert_success
  assert_equal "$(jq -c '[.project, .type, .stage, .met, .total, .fail, .human, .todo, .enforced_from, .blocks]' <<<"$output")" \
    '["shooter","game","alpha",4,6,0,1,1,"2026-11-19",false]'
  assert_equal "$(jq -r '.requirements[5] | "\(.stage) \(.result) \(.requirement)"' <<<"$output")" 'alpha PASS A cell with a | pipe'
  assert_equal "$(jq -r '.requirements[4].check' <<<"$output")" 'not yet: needs the forge API'
  refute_output --partial 'gate:'
  STAGE_GATE_TODAY=2026-11-19 run "$CHECK" shooter --stage beta --json
  assert_failure 1
  assert_equal "$(jq -c '[.fail, .blocks, .requirements[-1].result]' <<<"$output")" '[1,true,"FAIL"]'
}

@test "--by-dept groups each row under its department's title with a met count, in the Departments order" {
  run "$CHECK" shooter --stage alpha --by-dept
  assert_success
  assert_line --index 0 'Product: 1/2 met'
  assert_line --index 1 --regexp '^  PASS +draft +A lab sheet$'
  assert_line --index 2 --regexp '^  HUMAN alpha +Plays start to finish$'
  assert_line --index 3 'Engineering: 3/3 met'
  assert_line --index 7 'Ops: 0/1 met'
  assert_line --index 8 --regexp '^  TODO +alpha +A deploy workflow'
  refute_output --partial 'app-only'
  for flag in --json --systems '--system docs'; do
    # shellcheck disable=SC2086 # one flag and its argument
    run "$CHECK" shooter --by-dept $flag
    assert_failure 2
    assert_output --partial '--by-dept is a stage-mode view and takes only --stage'
  done
}

@test "a Dept cell outside Departments, an empty one or a missing column exits 2 and names the row" {
  sed -i 's/^\(| draft | base | A lab sheet | .*| \)product |$/\1sales |/' "$STAGES_DOC"
  run "$CHECK" shooter
  assert_failure 2
  assert_output --partial 'the Requirements row "A lab sheet" names Dept "sales"'
  run "$CHECK" --requirements
  assert_failure 2
  sed -i 's/^\(| draft | base | A lab sheet | .*| \)sales |$/\1 |/' "$STAGES_DOC"
  run "$CHECK" shooter
  assert_failure 2
  assert_output --partial 'names Dept ""'
  sed -i 's/^\(| draft | base | A lab sheet | [^|]* |\).*$/\1/' "$STAGES_DOC"
  run "$CHECK" shooter
  assert_failure 2
  assert_output --partial 'names Dept ""'
}

@test "--json carries each row's dept, and every row of the shipped stages.md names a known one" {
  run "$CHECK" shooter --stage alpha --json
  assert_equal "$(jq -r '[.requirements[].dept] | join(" ")' <<<"$output")" 'product engineering engineering product ops engineering'
  run bash -c '"$0" --requirements --json | jq -r "[.requirements[].dept] | unique | join(\" \")"' "$CHECK"
  assert_output 'engineering ops product'
  # NEGATIVE CONTROL: the real doc exits 2 when any row names a dept its Departments table lacks.
  STAGES_DOC="$REPO_ROOT/.local/src/docs/stages.md" run "$CHECK" --requirements --json
  assert_success
  assert_equal "$(jq '[.requirements[] | select(.dept == null or .dept == "")] | length' <<<"$output")" 0
}

@test "--requirements --json carries the Departments table, and a reworded requirement keeps its dept" {
  run "$CHECK" --requirements --json
  assert_success
  assert_equal "$(jq -c '.departments' <<<"$output")" '[{"id":"product","title":"Product","question":"Is it the thing?","owns":"the brief"},{"id":"engineering","title":"Engineering","question":"Does it build?","owns":"the README"},{"id":"ops","title":"Ops","question":"Does it stay up?","owns":"the runbook"}]'
  assert_equal "$(jq -r '.requirements[] | select(.requirement == "A lab sheet") | .dept' <<<"$output")" product
  # NEGATIVE CONTROL: rewording the requirement leaves its Dept cell, so the department stays.
  sed -i 's/| A lab sheet |/| A reworded lab sheet |/' "$STAGES_DOC"
  run "$CHECK" --requirements --json
  assert_success
  assert_equal "$(jq -r '.requirements[] | select(.requirement == "A reworded lab sheet") | .dept' <<<"$output")" product
  # The shipped doc carries the nine departments.
  STAGES_DOC="$REPO_ROOT/.local/src/docs/stages.md" run "$CHECK" --requirements --json
  assert_equal "$(jq -r '[.departments[].id] | join(" ")' <<<"$output")" 'product engineering ops design analytics marketing legal support money'
}

# docs_tree: the game's docs: x.md, a data file that is not a doc, and an ignored doc.
docs_tree() {
  mkdir -p "$REPO/Assets/Games/Shooter/docs"
  printf '# x\n## Rollback\n' > "$REPO/Assets/Games/Shooter/docs/x.md"
  printf '{"zebra": 1}\n' > "$REPO/Assets/Games/Shooter/docs/data.json"
  printf '# ignored\n' > "$REPO/Assets/Games/Shooter/docs/ignored.md"
}

# origin_repo: $REPO as a git repo whose origin/HEAD holds the game's docs, removed from the
# working tree, the shape of a clone that is behind its remote.
origin_repo() {
  docs_tree
  printf 'docs/ignored.md\n' > "$REPO/Assets/Games/Shooter/.gitignore"
  git -C "$REPO" init -q -b main
  git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm docs
  git clone -q --bare "$REPO" "$HOME/origin.git"
  git -C "$REPO" remote add origin "$HOME/origin.git"
  git -C "$REPO" fetch -q origin && git -C "$REPO" remote set-head origin -a >/dev/null
  rm -r "$REPO/Assets/Games/Shooter/docs"
  cat >> "$STAGES_DOC" <<'EOF2'

## Requirements

| dev | base | A doc on origin | `doc docs/x.md` | engineering |
| dev | base | Its text on origin | `doc_text docs/x.md \| grep -qx '## Rollback'` | ops |
| dev | base | Its path on origin | `doc_files \| grep -qx docs/x.md` | engineering |
| dev | base | A grep on origin | `doc_grep rollback docs` | ops |
| dev | base | A doc nowhere | `doc docs/missing.md` | engineering |
| dev | base | A word only outside the docs | `doc_grep zebra docs` | ops |
| dev | base | An ignored file | `doc_files \| grep -qx docs/ignored.md` | ops |
EOF2
}

@test "doc helpers read the project's folder on origin/HEAD, so a clone behind its remote still passes" {
  origin_repo
  run "$CHECK" shooter
  assert_line --regexp '^PASS +dev +A doc on origin$'
  assert_line --regexp '^PASS +dev +Its text on origin$'
  assert_line --regexp '^PASS +dev +Its path on origin$'
  assert_line --regexp '^PASS +dev +A grep on origin$'
  # NEGATIVE CONTROL: a path on neither origin nor disk fails, a word only in a .json is no doc,
  # and an ignored file is not on origin.
  assert_line --regexp '^FAIL +dev +A doc nowhere$'
  assert_line --regexp '^FAIL +dev +A word only outside the docs$'
  assert_line --regexp '^FAIL +dev +An ignored file$'
  refute_output --partial 'no origin/HEAD'
}

@test "doc helpers read the working tree with no origin, and warn when origin has no origin/HEAD" {
  origin_repo
  git -C "$REPO" remote set-head origin -d
  run "$CHECK" shooter
  assert_output --partial 'has an origin but no origin/HEAD'
  assert_line --regexp '^FAIL +dev +A doc on origin$'
  git -C "$REPO" remote remove origin
  docs_tree
  run "$CHECK" shooter
  refute_output --partial 'no origin/HEAD'
  assert_line --regexp '^PASS +dev +A doc on origin$'
  assert_line --regexp '^PASS +dev +Its text on origin$'
  assert_line --regexp '^PASS +dev +Its path on origin$'
  assert_line --regexp '^PASS +dev +A grep on origin$'
  assert_line --regexp '^FAIL +dev +A doc nowhere$'
  # NEGATIVE CONTROL: the working tree reads lose neither rule; `find .` saw the ignored file.
  assert_line --regexp '^FAIL +dev +A word only outside the docs$'
  assert_line --regexp '^FAIL +dev +An ignored file$'
}

@test "systems.md: the docs index passes only when it names each doc and each subdirectory of the docs tree" {
  write_systems_doc
  { sed -n '1,/^## Criteria/p' "$SYSTEMS_DOC"; printf '\n| System | Applies | Criterion | Check | Why |\n| --- | --- | --- | --- | --- |\n'
    grep -F '| docs | base | A docs index' "$REPO_ROOT/.local/src/docs/systems.md"; } > "$SYSTEMS_DOC.new" && mv "$SYSTEMS_DOC.new" "$SYSTEMS_DOC"
  d="$REPO/Assets/Games/Shooter/docs"
  mkdir -p "$d/operations"
  printf '# arch\n' > "$d/architecture.md"; printf '# deploy\n' > "$d/operations/deploy.md"; printf '{}\n' > "$d/data.json"
  printf '# Docs\n\n- [Architecture](architecture.md)\n' > "$d/README.md"
  run "$CHECK" shooter --system docs
  # NEGATIVE CONTROL: the operations/ tree is in no link.
  assert_line --regexp '^FAIL +docs +A docs index'
  printf -- '- [Deploy](operations/deploy.md)\n' >> "$d/README.md"
  run "$CHECK" shooter --system docs
  assert_line --regexp '^PASS +docs +A docs index'
  rm "$d/README.md"
  run "$CHECK" shooter --system docs
  assert_line --regexp '^FAIL +docs +A docs index'
}

@test "an unknown project, an unknown stage or no declared stage exits 2" {
  run "$CHECK" nobody
  assert_failure 2
  assert_output --partial 'no lab dir and no project-map type for "nobody"'
  run "$CHECK" shooter --stage gold
  assert_failure 2
  assert_output --partial 'unknown stage "gold"'
  printf '# shooter\n' > "$LAB/README.md"
  run "$CHECK" shooter
  assert_failure 2
  assert_output --partial 'declares no stage'
}

@test "a repo the map names but this machine has not cloned is not judged" {
  mv "$REPO" "$HOME/moved"
  run "$CHECK" shooter
  assert_failure 2
  assert_output --partial 'is not checked out here'
}

@test "a missing project folder reports stage gaps without borrowing repo or lab files" {
  mv "$REPO/Assets/Games/Shooter" "$HOME/moved"
  printf '# repo\n' > "$REPO/README.md"
  run "$CHECK" shooter --json
  assert_success
  assert_equal "$(jq -c '[.met, .fail, (.requirements | map(.result))]' <<<"$output")" \
    '[2,1,["PASS","PASS","FAIL"]]'
  STAGE_GATE_TODAY=2026-11-19 run "$CHECK" shooter --json
  assert_failure 1
  assert_equal "$(jq -c '[.fail, .blocks]' <<<"$output")" '[1,true]'
}

@test "with no repo a repo-file row reads as missing, never as the lab sheet" {
  jq '.trackers.shooter = {lab: "personal", type: "game"}' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.t"
  mv "$PROJECT_MAP_FILE.t" "$PROJECT_MAP_FILE"
  run "$CHECK" shooter
  assert_output --regexp 'PASS +draft +A lab sheet'
  assert_output --regexp 'FAIL +dev +A README where the project lives'
}

# -- the doctor's 6c, which runs the checker for every lab project --

@test "doctor: a project that meets its stage passes" {
  run "$DOCTOR" "$PROJECT_MAP_FILE"
  assert_output --partial 'PASS  all 1 lab projects declare a stage and meet it'
}

@test "doctor: a failing row warns in the report-only window and names the stage it is at" {
  declare_stage beta
  run "$DOCTOR" "$PROJECT_MAP_FILE"
  assert_output --partial 'WARN  lab project "shooter" fails 1 row(s) of #beta (at beta); see: project-stage-check shooter'
}

@test "doctor: a failing row fails once the gate is enforced" {
  declare_stage beta
  STAGE_GATE_TODAY=2026-11-19 run "$DOCTOR" "$PROJECT_MAP_FILE"
  assert_failure
  assert_output --partial 'FAIL  lab project "shooter" fails 1 row(s) of #beta (at beta)'
}

@test "doctor: a project with no stage warns and names the command that sets one" {
  printf '# shooter\n' > "$LAB/README.md"
  run "$DOCTOR" "$PROJECT_MAP_FILE"
  assert_output --partial 'lab project "shooter" declares no stage'
}

@test "doctor: a project the checker cannot judge is SKIP, and the section does not PASS" {
  mv "$REPO" "$HOME/moved"
  run "$DOCTOR" "$PROJECT_MAP_FILE"
  assert_output --partial 'SKIP  project-stage-check could not run for "shooter"'
  refute_output --partial 'declare a stage and meet it'
}

# -- systems mode: the Criteria rows of systems.md, met/total per system --

write_systems_doc() {
  export SYSTEMS_DOC="$HOME/systems.md"
  cat > "$SYSTEMS_DOC" <<'DOC'
# Systems

## Systems

| System | Applies | What it is |
| --- | --- | --- |
| docs | base | The docs |
| netcode | game | Multiplayer |
| payments | app | Purchases |

## Criteria

| System | Applies | Criterion | Check | Why |
| --- | --- | --- | --- | --- |
| docs | base | A README | `[ -f README.md ]` | first read |
| docs | base | An architecture doc | `[ -f docs/architecture.md ]` | the shape |
| netcode | game | A pipeline that exits early | `ls "$REPO" "$REPO/missing" 2>/dev/null \| grep -q .` | pipefail |
| netcode | game | Plays under lag | human | real players |
| netcode | app | An app-only row inside a game system | `false` | never runs |
| payments | app | Receipts verified | `false` | never runs |
DOC
}

@test "systems: rows run for base and the type, with met/total per system, and a FAIL exits 1" {
  write_systems_doc
  run "$CHECK" shooter --systems
  assert_failure 1
  assert_line --index 0 --regexp '^PASS +docs +A README$'
  assert_line --index 1 --regexp '^FAIL +docs +An architecture doc$'
  assert_line --index 2 --regexp '^PASS +netcode +A pipeline that exits early$'
  assert_line --index 3 --regexp '^HUMAN +netcode +Plays under lag$'
  assert_line --index 4 'systems: shooter: docs 1/2, netcode 1/2'
  refute_output --partial 'app-only'
  refute_output --partial 'payments'
}

@test "systems: a missing project folder still evaluates repository criteria and emits JSON" {
  write_systems_doc
  mv "$REPO/Assets/Games/Shooter" "$HOME/moved"
  printf '# repo\n' > "$REPO/README.md"
  mkdir -p "$REPO/docs"
  printf '# arch\n' > "$REPO/docs/architecture.md"
  run "$CHECK" shooter --systems --json
  assert_failure 1
  assert_equal "$(jq -c '[.met, .total, [.systems[] | [.id, .met, .fail, .human]]]' <<<"$output")" \
    '[1,4,[["docs",0,2,0],["netcode",1,0,1]]]'
}

@test "systems: a project missing docs/architecture.md fails the docs criterion, and adding it passes" {
  write_systems_doc
  run "$CHECK" shooter --system docs
  assert_failure 1
  assert_output --regexp 'FAIL +docs +An architecture doc'
  mkdir -p "$REPO/Assets/Games/Shooter/docs"
  printf '# arch\n' > "$REPO/Assets/Games/Shooter/docs/architecture.md"
  run "$CHECK" shooter --system docs
  assert_success
  assert_line 'systems: shooter: docs 2/2'
}

@test "systems: --json gives met, total and each row per system; the alias is the same mode" {
  write_systems_doc
  run "$CHECK" shooter --systems --json
  assert_failure 1
  assert_equal "$(jq -c '[.project, .type, .met, .total]' <<<"$output")" '["shooter","game",2,4]'
  assert_equal "$(jq -c '[.systems[] | [.id, .met, .total, .fail, .human, .todo]]' <<<"$output")" '[["docs",1,2,1,0,0],["netcode",1,2,0,1,0]]'
  assert_equal "$(jq -r '.systems[0].criteria[1] | "\(.result) \(.criterion)"' <<<"$output")" 'FAIL An architecture doc'
  ln -s "$CHECK" "$HOME/project-system-check"
  run "$HOME/project-system-check" shooter --json
  assert_equal "$(jq -c '[.met, .total]' <<<"$output")" '[2,4]'
}

@test "systems: an unknown system, one that does not apply, or a Criteria row naming no system exits 2" {
  write_systems_doc
  run "$CHECK" shooter --system nope
  assert_failure 2
  assert_output --partial 'unknown system "nope" (want: docs netcode payments)'
  run "$CHECK" shooter --system payments
  assert_failure 2
  assert_output --partial 'system "payments" does not apply to "shooter", which takes: base game store'
  printf '| ghost | base | A row with no system | `true` | none |\n' >> "$SYSTEMS_DOC"
  run "$CHECK" shooter --systems
  assert_failure 2
  assert_output --partial 'a Criteria row names unknown system "ghost"'
}

@test "systems: --list prints the doc systems for base and the type, then the project's own" {
  write_systems_doc
  run "$CHECK" shooter --list
  assert_success
  assert_line --index 0 "$(printf 'docs\tdoc\t\tThe docs')"
  assert_line --index 1 "$(printf 'netcode\tdoc\t\tMultiplayer')"
  refute_output --partial 'payments'
  jq '.trackers.shooter.systems = {netcode: {aliases: ["mp", "lobby"]}, dispatch: {is: "The queue", aliases: ["queue"]}}' \
    "$PROJECT_MAP_FILE" > "$HOME/map.tmp" && mv "$HOME/map.tmp" "$PROJECT_MAP_FILE"
  run "$CHECK" shooter --list
  assert_success
  assert_line --index 1 "$(printf 'netcode\tdoc\tmp,lobby\tMultiplayer')"
  assert_line --index 2 "$(printf 'dispatch\town\tqueue\tThe queue')"
  run "$CHECK" shooter --list --json
  assert_success
  assert_equal "$(jq -c '[.[] | [.id, .source, (.aliases | length)]]' <<<"$output")" '[["docs","doc",0],["netcode","doc",2],["dispatch","own",1]]'
}

@test "systems: an own entry cannot pull in another type's system or reuse an alias, --list needs no checkout, and takes no --file" {
  write_systems_doc
  setmap() { jq ".trackers.shooter.systems = $1" "$PROJECT_MAP_FILE" > "$HOME/map.tmp" && mv "$HOME/map.tmp" "$PROJECT_MAP_FILE"; }
  setmap '{payments: {aliases: ["iap"]}}'
  run "$CHECK" shooter --list
  assert_failure 2
  assert_output --partial 'payments does not apply to a game project'
  setmap '{netcode: {aliases: ["queue"]}, dispatch: {is: "The queue", aliases: ["queue"]}}'
  run "$CHECK" shooter --list
  assert_failure 2
  assert_output --partial 'an alias names two systems or is itself a system id: queue'
  setmap '{dispatch: {is: "The queue", aliases: ["docs"]}}'
  run "$CHECK" shooter --list
  assert_failure 2
  assert_output --partial 'is itself a system id: docs'
  setmap '{dispatch: {is: "The queue", aliases: ["queue"]}}'
  mv "$REPO" "$HOME/gone"
  run "$CHECK" shooter --list
  assert_success
  assert_line --index 2 "$(printf 'dispatch\town\tqueue\tThe queue')"
  run "$CHECK" shooter --list --file
  assert_failure 2
  assert_output --partial '--list takes only --json'
}

@test "systems: a malformed own entry exits 2 and names it, never an empty list" {
  write_systems_doc
  for bad in '{netcode: "mp"}' '{netcode: {aliases: "mp"}}' '{Dispatch: {is: "x"}}' '"dispatch"'; do
    jq ".trackers.shooter.systems = $bad" "$PROJECT_MAP_FILE" > "$HOME/map.tmp" && mv "$HOME/map.tmp" "$PROJECT_MAP_FILE"
    run "$CHECK" shooter --list
    assert_failure 2
    assert_output --partial 'cannot read the systems of "shooter"'
  done
  jq '.trackers.shooter.systems = {dispatch: {aliases: ["queue"]}}' "$PROJECT_MAP_FILE" > "$HOME/map.tmp" && mv "$HOME/map.tmp" "$PROJECT_MAP_FILE"
  run "$CHECK" shooter --list
  assert_failure 2
  assert_output --partial 'own systems need an "is" line: dispatch'
}

@test "a stage row can require a system by calling the checker, so the predicate lives in one doc" {
  write_systems_doc
  cat >> "$STAGES_DOC" <<'EOF2'

## Requirements

| dev | base | The docs system meets its criteria | `project-stage-check "$NAME" --system docs` | engineering |
EOF2
  mkdir -p "$HOME/bin"; ln -s "$CHECK" "$HOME/bin/project-stage-check"
  PATH="$HOME/bin:$PATH" run "$CHECK" shooter
  assert_output --regexp 'FAIL +dev +The docs system meets its criteria'
  mkdir -p "$REPO/Assets/Games/Shooter/docs"
  printf '# arch\n' > "$REPO/Assets/Games/Shooter/docs/architecture.md"
  PATH="$HOME/bin:$PATH" run "$CHECK" shooter
  assert_output --regexp 'PASS +dev +The docs system meets its criteria'
}

# -- --file: a stage's failing rows on one rollup row under the open epic for its target --

epics() { jq -n --argjson e "$1" '[{name: "shooter", epics: $e}]' > "$NOTES_FIXTURE/stats.json"; }
# board <lines>: the agent sheet's Tasks; board_row <row> writes one row and its parse.
board() { mkdir -p "$LAB/agent"; printf '# shooter agent\n\n## Tasks\n%s\n' "$1" > "$LAB/agent/README.md"; }
board_row() { board "$1"; parses "$1"; }
# parses <row> [title] [area]: `notes row parse` answers it as chore(<area>): <title>, by default
# chore(beta): A changelog (a lookup table, never the grammar: that lives in notes-cli alone)
parses() { printf '%s\tchore\t%s\t%s\t1\n' "$1" "${3:-beta}" "${2:-A changelog}" >> "$NOTES_FIXTURE/row.parse"; }
# license_row: a second beta row that fails until LICENSE exists.
license_row() { sed -i 's/^| beta | base | A changelog .*/&\n| beta | base | A license | `[ -f LICENSE ]` | engineering |/' "$STAGES_DOC"; }
# rollup <id> <stage> <prio> <line>...: an open rollup row of <stage> with these list lines.
rollup() {
  local id="$1" s="$2" p="$3"; shift 3
  printf -- '- [ ] chore(stage): meet the %s stage standard #of/sh-1 #size/m #%s <!-- id:%s -->\n' "$s" "$p" "$id"
  printf '  from project-stage-check shooter --file: the stages.md rows this project fails for #%s, one a line; a met row leaves the list and the row closes when none is left\n' "$s"
  [ $# -eq 0 ] || printf '  %s\n' "$@"
}
# from <check>: the from line a per-row filing left under its row.
from() { printf '  from project-stage-check shooter --file, stages.md #beta, check: `%s`' "$1"; }
# ptask_calls: the `notes ptask` calls the run made, each with its multi-line arguments.
ptask_calls() { awk '/^notes /{ p = /^notes ptask/ } p' "$NOTES_FIXTURE/calls.log"; }
HEAD_BETA='from project-stage-check shooter --file: the stages.md rows this project fails for #beta, one a line; a met row leaves the list and the row closes when none is left'
CL='#beta: A changelog, check: `[ -f CHANGELOG.md ]`'
LI='#beta: A license, check: `[ -f LICENSE ]`'

@test "file: every failing row of the stage goes on one rollup row under the stage epic" {
  license_row
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter, testers"}]'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^row +sh-7 +meet the beta stage standard, filed$'
  assert_line --regexp '^filed +beta +A changelog$'
  assert_line --regexp '^filed +beta +A license$'
  assert_line 'file: shooter #beta: 2 failing, 2 listed on sh-7 (2 new), 0 held by their own row, 0 closed or dropped, 0 met and closed'
  run ptask_calls
  assert_output "notes ptask shooter --agent add chore(stage): meet the beta stage standard #of/sh-1 #size/m #low --detail $HEAD_BETA --detail $CL --detail $LI --origin project-stage-check"
  # From the Enforced from date the gate blocks on its gaps, so the rollup is #high.
  : > "$NOTES_FIXTURE/calls.log"
  STAGE_GATE_TODAY=2026-11-19 run "$CHECK" shooter --file
  assert_called 'meet the beta stage standard #of/sh-1 #size/m #high --detail'
  # NEGATIVE CONTROL: an add that prints no id is an error, and nothing is folded into nothing.
  : > "$NOTES_FIXTURE/calls.log"; : > "$NOTES_FIXTURE/ptask.agent.added"
  run "$CHECK" shooter --file
  assert_failure 1
  assert_line --regexp '^error +rollup +meet the beta stage standard \(ptask add exit 0, no id\)$'
  assert_not_called 'drop'
  # A sheet notes cannot parse fails the run rather than filing a twin of every row on it.
  board_row '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->'
  mkdir -p "$HOME/bin"; printf '#!/usr/bin/env bash\n[ "$1" != row ] || exit 1\n' > "$HOME/bin/notes"; chmod +x "$HOME/bin/notes"
  : > "$NOTES_FIXTURE/calls.log"
  PATH="$HOME/bin:$PATH" run "$CHECK" shooter --file
  assert_failure 2
  assert_output --partial 'notes row parse failed'
  assert_not_called 'ptask'
}

@test "file: a rerun with the list as the check reads it writes nothing" {
  license_row
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(rollup sh-7 beta low "$CL" "$LI")"
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^open +beta +A changelog$'
  assert_line --regexp '^open +beta +A license$'
  assert_line 'file: shooter #beta: 2 failing, 2 listed on sh-7 (0 new), 0 held by their own row, 0 closed or dropped, 0 met and closed'
  assert_not_called 'ptask'
  # Trailing blanks the sheet keeps are no change either.
  sed -i '/^  /s/$/  /' "$LAB/agent/README.md"
  run "$CHECK" shooter --file
  assert_output --partial '2 listed on sh-7 (0 new)'
  assert_not_called 'ptask'
}

@test "file: a row that passes now leaves the list, and a row that starts failing joins it" {
  license_row
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(rollup sh-7 beta low "$CL" "$LI")"
  touch "$REPO/Assets/Games/Shooter/LICENSE"
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^met +sh-7 +A license$'
  assert_line --regexp '^open +beta +A changelog$'
  assert_line 'file: shooter #beta: 1 failing, 1 listed on sh-7 (0 new), 0 held by their own row, 0 closed or dropped, 1 met and closed'
  run ptask_calls
  assert_output "notes ptask shooter --agent edit sh-7 --brief $HEAD_BETA
$CL"
  rm "$REPO/Assets/Games/Shooter/LICENSE"; board "$(rollup sh-7 beta low "$CL")"; : > "$NOTES_FIXTURE/calls.log"
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^filed +beta +A license$'
  assert_output --partial '2 listed on sh-7 (1 new)'
  run ptask_calls
  assert_output "notes ptask shooter --agent edit sh-7 --brief $HEAD_BETA
$CL
$LI"
}

@test "file: the rollup closes, with the check as proof, once no row is left to list" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(rollup sh-7 beta low "$CL")"
  printf '# log\n' > "$REPO/Assets/Games/Shooter/CHANGELOG.md"
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^row +sh-7 +meet the beta stage standard, closed: no gap left to list$'
  assert_line --regexp '^met +sh-7 +A changelog$'
  assert_line 'file: shooter #beta: 0 failing, 0 listed, sh-7 closed, 0 held by their own row, 0 closed or dropped, 1 met and closed'
  run ptask_calls
  assert_output "notes ptask shooter --agent done sh-7 --proof check:project-stage-check shooter PASS $(date +%F)"
  # NEGATIVE CONTROL: with no rollup open and nothing failing, nothing is written.
  board ''; : > "$NOTES_FIXTURE/calls.log"
  run "$CHECK" shooter --file
  assert_success
  assert_line 'file: shooter #beta: 0 failing, 0 listed, 0 held by their own row, 0 closed or dropped, 0 met and closed'
  assert_not_called 'ptask'
}

@test "file: the rows this check filed for each gap fold into the rollup, a reworded one by its from line" {
  license_row
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(printf -- '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->\n%s\n- [ ] docs(docs): add a license file #low <!-- id:sh-3 -->\n%s' \
    "$(from '[ -f CHANGELOG.md ]')" "$(from '[ -f LICENSE ]')")"
  parses '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->'
  parses '- [ ] docs(docs): add a license file #low <!-- id:sh-3 -->' 'add a license file' docs
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^folded +sh-2 +A changelog \(into sh-7\)$'
  assert_line --regexp '^folded +sh-3 +A license \(into sh-7\)$'
  assert_line 'file: shooter #beta: 2 failing, 2 listed on sh-7 (2 new), 0 held by their own row, 0 closed or dropped, 0 met and closed, 2 folded'
  assert_called 'notes ptask shooter --agent drop sh-2 --dup sh-7'
  assert_called 'notes ptask shooter --agent drop sh-3 --dup sh-7'
  # NEGATIVE CONTROL: a row folded into the rollup is no closed twin, so the next run keeps
  # its gap listed and writes nothing.
  board "$(rollup sh-7 beta low "$CL" "$LI"; printf -- '- [x] chore(beta): A changelog #size/s <!-- id:sh-2 dup:sh-7 -->\n%s' "$(from '[ -f CHANGELOG.md ]')")"
  parses '- [x] chore(beta): A changelog #size/s <!-- id:sh-2 dup:sh-7 -->'
  : > "$NOTES_FIXTURE/calls.log"
  run "$CHECK" shooter --file
  assert_success
  assert_output --partial '2 failing, 2 listed on sh-7 (0 new), 0 held by their own row, 0 closed or dropped'
  assert_not_called 'ptask'
}

@test "file: a twin closed as dup of an open twin leaves the gap open, and the open one folds" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(printf -- '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->\n%s' "$(from '[ -f CHANGELOG.md ]')")"
  parses '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->'
  mkdir -p "$LAB/agent/versions"
  printf -- '- [x] docs(docs): add a CHANGELOG #size/s <!-- id:sh-3 dup:sh-2 -->\n%s\n' "$(from '[ -f CHANGELOG.md ]')" > "$LAB/agent/versions/v0.0.1.md"
  parses '- [x] docs(docs): add a CHANGELOG #size/s <!-- id:sh-3 dup:sh-2 -->' 'add a CHANGELOG' docs
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^filed +beta +A changelog$'
  assert_line --regexp '^folded +sh-2 +A changelog \(into sh-7\)$'
  assert_line 'file: shooter #beta: 1 failing, 1 listed on sh-7 (1 new), 0 held by their own row, 0 closed or dropped, 0 met and closed, 1 folded'
  # The next run follows the chain: sh-3 into sh-2, sh-2 into the rollup; nothing is written.
  board "$(rollup sh-7 beta low "$CL"; printf -- '- [x] chore(beta): A changelog #size/s <!-- id:sh-2 dup:sh-7 -->\n%s' "$(from '[ -f CHANGELOG.md ]')")"
  parses '- [x] chore(beta): A changelog #size/s <!-- id:sh-2 dup:sh-7 -->'
  : > "$NOTES_FIXTURE/calls.log"
  run "$CHECK" shooter --file
  assert_success
  assert_output --partial '1 failing, 1 listed on sh-7 (0 new), 0 held by their own row, 0 closed or dropped'
  assert_not_called 'ptask'
  # NEGATIVE CONTROL: a twin closed as dup of a row that is no twin hands the gap to that row: closed.
  board '- [ ] feat(docs): release notes <!-- id:sh-9 -->'; parses '- [ ] feat(docs): release notes <!-- id:sh-9 -->' 'release notes' docs
  printf -- '- [x] docs(docs): add a CHANGELOG #size/s <!-- id:sh-3 dup:sh-9 -->\n%s\n' "$(from '[ -f CHANGELOG.md ]')" > "$LAB/agent/versions/v0.0.1.md"
  parses '- [x] docs(docs): add a CHANGELOG #size/s <!-- id:sh-3 dup:sh-9 -->' 'add a CHANGELOG' docs
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^closed +beta +A changelog$'
  assert_not_called 'ptask'
  # A dup cycle, and a row that is its own dup, hold nothing: the gap stays closed.
  printf -- '- [x] docs(docs): add a CHANGELOG #size/s <!-- id:sh-3 dup:sh-4 -->\n%s\n- [x] chore(beta): A changelog #size/s <!-- id:sh-4 dup:sh-3 -->\n%s\n- [x] chore(beta): A changelog #size/s <!-- id:sh-5 dup:sh-5 -->\n%s\n' \
    "$(from '[ -f CHANGELOG.md ]')" "$(from '[ -f CHANGELOG.md ]')" "$(from '[ -f CHANGELOG.md ]')" > "$LAB/agent/versions/v0.0.1.md"
  parses '- [x] docs(docs): add a CHANGELOG #size/s <!-- id:sh-3 dup:sh-4 -->' 'add a CHANGELOG' docs
  parses '- [x] chore(beta): A changelog #size/s <!-- id:sh-4 dup:sh-3 -->'
  parses '- [x] chore(beta): A changelog #size/s <!-- id:sh-5 dup:sh-5 -->'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^closed +beta +A changelog$'
  assert_not_called 'ptask'
}

@test "file: a gap held by a row in progress, a parent, a human row or a row with no from line stays off the list, untouched" {
  license_row
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(printf -- '- [/] chore(beta): A changelog <!-- id:sh-2 -->\n%s\n- [ ] chore(beta): A license <!-- id:sh-3 -->\n%s\n  - [ ] fix(x): a child <!-- id:sh-4 -->' \
    "$(from '[ -f CHANGELOG.md ]')" "$(from '[ -f LICENSE ]')")"
  parses '- [/] chore(beta): A changelog <!-- id:sh-2 -->'
  parses '- [ ] chore(beta): A license <!-- id:sh-3 -->' 'A license'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^open +beta +A changelog \(held by sh-2\)$'
  assert_line --regexp '^open +beta +A license \(held by sh-3\)$'
  assert_line 'file: shooter #beta: 2 failing, 0 listed, 2 held by their own row, 0 closed or dropped, 0 met and closed'
  assert_not_called 'ptask'
  # A human-sheet row, and an agent row with no from line (a hand-written twin), hold their gap too.
  printf -- '- [ ] chore(beta): A changelog <!-- id:sh-5 -->\n' >> "$LAB/README.md"
  parses '- [ ] chore(beta): A changelog <!-- id:sh-5 -->'
  board '- [ ] chore(beta): A license <!-- id:sh-6 -->'; parses '- [ ] chore(beta): A license <!-- id:sh-6 -->' 'A license'
  run "$CHECK" shooter --file
  assert_line --regexp '^open +beta +A changelog \(held by sh-5\)$'
  assert_line --regexp '^open +beta +A license \(held by sh-6\)$'
  assert_not_called 'ptask'
  # An open rollup whose every gap is held closes, saying so in its proof, and leaves the holders be.
  board "$(rollup sh-7 beta low "$CL" "$LI"; printf -- '- [ ] chore(beta): A license <!-- id:sh-6 -->')"
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^gone +sh-7 +A license$'
  run ptask_calls
  assert_output "notes ptask shooter --agent done sh-7 --proof check:project-stage-check shooter --file, each gap left is held or closed by its own row, $(date +%F)"
}

@test "file: a gap the human dropped or closed is never listed again, and a rollup closed by hand is not filed again" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board_row '- [x] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 dropped: not this year -->'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^closed +beta +A changelog$'
  assert_line 'file: shooter #beta: 1 failing, 0 listed, 0 held by their own row, 1 closed or dropped, 0 met and closed'
  assert_not_called 'ptask'
  # A row archived into a version note counts as well.
  rm "$LAB/agent/README.md"; mkdir -p "$LAB/agent/versions"
  printf '## Done rows\n- [x] chore(beta): A changelog #size/s <!-- id:sh-2 done:2026-10-01 pr:9 -->\n' > "$LAB/agent/versions/v0.0.9.md"
  parses '- [x] chore(beta): A changelog #size/s <!-- id:sh-2 done:2026-10-01 pr:9 -->'
  run "$CHECK" shooter --file
  assert_line --regexp '^closed +beta +A changelog$'
  assert_not_called 'ptask'
  # NEGATIVE CONTROL: a row this check closed on a PASS is no closed twin: a regression is listed.
  printf '## Done rows\n- [x] chore(beta): A changelog #size/s <!-- id:sh-2 done:2026-10-01 check:project-stage-check shooter PASS 2026-10-01 -->\n' > "$LAB/agent/versions/v0.0.9.md"
  parses '- [x] chore(beta): A changelog #size/s <!-- id:sh-2 done:2026-10-01 check:project-stage-check shooter PASS 2026-10-01 -->'
  run "$CHECK" shooter --file
  assert_line --regexp '^filed +beta +A changelog$'
  assert_called 'agent add chore(stage): meet the beta stage standard'
  # A rollup the human closed stays closed for its stage, with the way back named.
  rm -r "$LAB/agent/versions"; : > "$NOTES_FIXTURE/calls.log"
  board "$(rollup sh-7 beta low "$CL" | sed '1s/^- \[ \]/- [x]/; 1s/-->$/dropped: not now -->/')"
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^closed +sh-7 +meet the beta stage standard was closed by hand, so it is not filed again \(notes ptask shooter reopen sh-7\)$'
  assert_not_called 'ptask'
  # NEGATIVE CONTROL: one this check closed on its own proof is filed again when a gap returns.
  board "$(rollup sh-7 beta low "$CL" | sed "1s/^- \[ \]/- [x]/; 1s/-->\$/done:2026-10-01 check:project-stage-check shooter PASS 2026-10-01 -->/")"
  run "$CHECK" shooter --file
  assert_success
  assert_called 'agent add chore(stage): meet the beta stage standard'
}

@test "file: with no open epic the stage's epic is filed on the human sheet once, and the rollup goes under it" {
  epics '[]'
  printf -- '- [ ] epic(stage): beta to standard <!-- id:sh-9 -->\n' > "$NOTES_FIXTURE/ptask.added"
  run "$CHECK" shooter --stage beta --file
  assert_success
  assert_line --regexp '^filed +beta +A changelog$'
  assert_output --partial 'epic    beta        beta to standard (sh-9)'
  assert_line 'file: shooter #beta: 1 failing, 1 listed on sh-7 (1 new), 0 held by their own row, 0 closed or dropped, 0 met and closed, 1 epic opened'
  assert_called 'notes ptask shooter add epic(stage): beta to standard'
  assert_called 'notes ptask shooter --agent add chore(stage): meet the beta stage standard #of/sh-9 #size/m #low'
  # An epic for another stage is not this target's epic: beta's is still opened.
  : > "$NOTES_FIXTURE/calls.log"
  epics '[{"id":"sh-1","system":"stage","title":"prod for shooter"}]'
  run "$CHECK" shooter --stage beta --file
  assert_called 'notes ptask shooter add epic(stage): beta to standard'
  # NEGATIVE CONTROL: an add that prints no id files no orphan rollup.
  : > "$NOTES_FIXTURE/calls.log"; : > "$NOTES_FIXTURE/ptask.added"; epics '[]'
  run "$CHECK" shooter --stage beta --file
  assert_failure 1
  assert_line --regexp '^error +rollup +meet the beta stage standard \(could not file the stage epic\)$'
  assert_not_called 'ptask shooter --agent add'
}

@test "file: with no --stage the target is the stage after the declared one, or a later open epic's" {
  declare_stage alpha
  epics '[]'
  printf -- '- [ ] epic(stage): beta to standard <!-- id:sh-9 -->\n' > "$NOTES_FIXTURE/ptask.added"
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^filed +beta +A changelog$'
  assert_called 'notes ptask shooter add epic(stage): beta to standard'
  # A project at the top of the ladder checks its own stage.
  declare_stage prod; : > "$NOTES_FIXTURE/calls.log"
  printf -- '- [ ] epic(stage): prod to standard <!-- id:sh-10 -->\n' > "$NOTES_FIXTURE/ptask.added"
  run "$CHECK" shooter --file
  assert_line --regexp '^filed +beta +A changelog$'
  assert_called 'notes ptask shooter add epic(stage): prod to standard'
  assert_called 'agent add chore(stage): meet the prod stage standard #of/sh-10'
  # A leftover epic for a stage already passed never holds the target below the next one.
  declare_stage alpha; : > "$NOTES_FIXTURE/calls.log"
  epics '[{"id":"sh-1","system":"stage","title":"dev to standard"}]'
  printf -- '- [ ] epic(stage): beta to standard <!-- id:sh-9 -->\n' > "$NOTES_FIXTURE/ptask.added"
  run "$CHECK" shooter --file
  assert_line --regexp '^filed +beta +A changelog$'
  assert_called 'notes ptask shooter add epic(stage): beta to standard'
}

@test "file: when the target rises the rollup is retitled, a second one folds in, and its priority follows the gate" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(rollup sh-7 alpha low "$CL"; rollup sh-8 dev low '#dev: An old line, check: `false`')"
  STAGE_GATE_TODAY=2026-11-19 run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^row +sh-7 +meet the beta stage standard, retitled from #alpha$'
  assert_line --regexp '^folded +sh-8 +another stage rollup \(into sh-7\)$'
  run ptask_calls
  assert_output "notes ptask shooter --agent edit sh-7 --text chore(stage): meet the beta stage standard #of/sh-1
notes ptask shooter --agent edit sh-7 --brief $HEAD_BETA
$CL
notes ptask shooter --agent tag sh-7 --add high --remove low
notes ptask shooter --agent drop sh-8 --dup sh-7"
  # NEGATIVE CONTROL: a priority set by hand stays, and a rollup in progress is never folded.
  board "$(rollup sh-7 beta urgent "$CL"; rollup sh-8 dev low | sed '1s/^- \[ \]/- [\/]/')"
  : > "$NOTES_FIXTURE/calls.log"
  STAGE_GATE_TODAY=2026-11-19 run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^open +sh-8 +another stage rollup, in progress, left as it is$'
  assert_not_called 'ptask'
}

@test "file: an open agent row whose check now passes is closed by its id with the check as proof" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  printf '# log\n' > "$REPO/Assets/Games/Shooter/CHANGELOG.md"
  board_row '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^met +sh-2 +A changelog$'
  assert_output --partial '0 failing, 0 listed, 0 held by their own row, 0 closed or dropped, 1 met and closed'
  assert_called "notes ptask shooter --agent done sh-2 --proof check:project-stage-check shooter PASS $(date +%F)"
  # --json counts the row it closed as closed.
  run --separate-stderr "$CHECK" shooter --file --json
  assert_success
  run jq -c '[.fail, .filed_open, .filed_closed]' <<<"$output"
  assert_output '[0,0,1]'
  # NEGATIVE CONTROL: a human-sheet row and a closed row with the same title are never touched.
  : > "$NOTES_FIXTURE/calls.log"
  rm "$LAB/agent/README.md"
  printf '# shooter\nVersion: v0.1.0 #dev\n\n## Tasks\n- [ ] chore(beta): A changelog <!-- id:sh-3 -->\n- [x] chore(beta): A changelog <!-- id:sh-4 -->\n' > "$LAB/README.md"
  parses '- [ ] chore(beta): A changelog <!-- id:sh-3 -->'
  parses '- [x] chore(beta): A changelog <!-- id:sh-4 -->'
  run "$CHECK" shooter --file
  assert_success
  assert_not_called 'done'
}

@test "file: --json reads a board past the kernel's 128 KB argument limit, not a quiet error" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board_row '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->'
  awk 'BEGIN { pad = sprintf("%600s", ""); gsub(/ /, "x", pad); for (i = 0; i < 300; i++) print "- [ ] feat(ui): filler " i " " pad " <!-- id:sh-" (i + 10) " -->" }' >> "$LAB/agent/README.md"
  [ "$(wc -c < "$LAB/agent/README.md")" -gt 140000 ]
  run --separate-stderr "$CHECK" shooter --file --json
  assert_success
  run jq -c '[.fail, .filed_open, .filed_closed]' <<<"$output"
  assert_output '[1,1,0]'
}

@test "file: a title that passes on one row and fails on another stays a gap" {
  sed -i 's/^| beta | base | A changelog .*/&\n| beta | game | A changelog | `false` | engineering |/' "$STAGES_DOC"
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  printf '# log\n' > "$REPO/Assets/Games/Shooter/CHANGELOG.md"
  board_row '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->'
  run "$CHECK" shooter --file
  assert_line --regexp '^open +beta +A changelog \(held by sh-2\)$'
  assert_not_called 'done'
}

# wrap_notes <case pattern> <exit> [stderr]: a notes on PATH that prints [stderr] and exits <exit>
# when its arguments match, else runs the stub.
wrap_notes() {
  mkdir -p "$HOME/bin"
  printf '#!/usr/bin/env bash\ncase "$*" in %s) printf "notes %%s\\n" "$*" >> "$NOTES_FIXTURE/calls.log"; printf %%s %q >&2; exit %s ;; esac\nexec %q "$@"\n' \
    "$1" "${3:-}" "$2" "$(command -v notes)" > "$HOME/bin/notes"
  chmod +x "$HOME/bin/notes"
}

@test "file: a priority the open sprint holds is kept and is no failure; any other tag failure is" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(rollup sh-7 beta low "$CL")"
  wrap_notes '*"--agent tag sh-7"*' 1 "refused: changing the priority of 'x', a row of the open v0.1.0 sprint: the cut carries open rows, and only the human moves it"
  STAGE_GATE_TODAY=2026-11-19 PATH="$HOME/bin:$PATH" run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^held +sh-7 +meet the beta stage standard, #low kept: the open sprint holds it$'
  # NEGATIVE CONTROL: a tag that fails for another reason still counts.
  : > "$NOTES_FIXTURE/calls.log"
  wrap_notes '*"--agent tag sh-7"*' 1 'no open task matches'
  STAGE_GATE_TODAY=2026-11-19 PATH="$HOME/bin:$PATH" run "$CHECK" shooter --file
  assert_failure 1
  assert_line --regexp '^error +sh-7 +meet the beta stage standard \(ptask tag failed\)$'
}

@test "file: a write that fails folds nothing, and a twin from a concurrent run is no failure" {
  license_row
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board "$(rollup sh-7 beta low "$CL"; printf -- '- [ ] chore(beta): A license <!-- id:sh-3 -->\n%s' "$(from '[ -f LICENSE ]')")"
  parses '- [ ] chore(beta): A license <!-- id:sh-3 -->' 'A license'
  wrap_notes '*"--agent edit sh-7 --brief"*' 1
  PATH="$HOME/bin:$PATH" run "$CHECK" shooter --file
  assert_failure 1
  assert_line --regexp '^error +sh-7 +meet the beta stage standard \(ptask edit --brief failed\)$'
  assert_output --partial 'the list on sh-7 not written'
  assert_not_called 'drop'
  # A retitle that fails leaves the list as it was, for the next run to retry both.
  board "$(rollup sh-7 alpha low "$CL")"; : > "$NOTES_FIXTURE/calls.log"
  wrap_notes '*"--agent edit sh-7 --text"*' 1
  PATH="$HOME/bin:$PATH" run "$CHECK" shooter --file
  assert_failure 1
  assert_line --regexp '^error +sh-7 +meet the beta stage standard \(ptask edit --text failed\)$'
  assert_not_called 'edit sh-7 --brief'
  # Exit 3 from add is its twin check: another run filed the rollup, so this one holds off.
  board ''; : > "$NOTES_FIXTURE/calls.log"
  wrap_notes '*"--agent add chore(stage)"*' 3
  PATH="$HOME/bin:$PATH" run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^open +rollup +meet the beta stage standard, filed by another run$'
  refute_output --partial 'failed'
}

@test "file: a rollup in progress is not closed, and a row with no id is held, never dropped" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  printf '# log\n' > "$REPO/Assets/Games/Shooter/CHANGELOG.md"
  board "$(rollup sh-7 beta low "$CL" | sed '1s/^- \[ \]/- [\/]/')"
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^open +sh-7 +meet the beta stage standard, no gap left but in progress, left as it is$'
  assert_not_called 'ptask'
  # NEGATIVE CONTROL: a row with a from line but no id cannot be dropped by id, so it holds its gap.
  rm "$REPO/Assets/Games/Shooter/CHANGELOG.md"
  board "$(printf -- '- [ ] chore(beta): A changelog\n%s' "$(from '[ -f CHANGELOG.md ]')")"
  parses '- [ ] chore(beta): A changelog'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^open +beta +A changelog \(held by a row with no id\)$'
  assert_not_called 'ptask'
}

@test "file: a check with a backslash is listed as stages.md spells it" {
  sed -i 's/^| beta | base | A changelog .*/| beta | base | A changelog | `grep -q "a\\.b" CHANGELOG.md` | engineering |/' "$STAGES_DOC"
  grep -qF 'grep -q "a\.b" CHANGELOG.md' "$STAGES_DOC"
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  run "$CHECK" shooter --file
  assert_success
  assert_called '--detail #beta: A changelog, check: `grep -q "a\.b" CHANGELOG.md`'
  assert_not_called 'a\\.b'
}

@test "file: systems rows go under their system's epic, and a long title is cut with the whole text kept" {
  write_systems_doc
  printf '| docs | base | A contributor guide that says how to build, run and test every part of the project from a fresh clone | `false` | onboarding |\n' >> "$SYSTEMS_DOC"
  epics '[{"id":"sh-5","system":"docs","title":"docs for shooter"}]'
  run "$CHECK" shooter --systems --file
  assert_success
  assert_line --regexp '^filed +docs +An architecture doc$'
  assert_line 'file: shooter systems: 2 failing, 2 filed, 0 already open, 0 closed or dropped, 0 met and closed'
  assert_called 'notes ptask shooter --agent add chore(docs): An architecture doc #of/sh-5 #size/s #low'
  assert_called 'add chore(docs): A contributor guide that says how to build, run and test every part of the #of/sh-5 #size/s #low --detail A contributor guide that says how to build, run and test every part of the project from a fresh clone --detail'
}

@test "file: a systems row with no open epic is filed bare, for notes ptask add to link its standing epic" {
  write_systems_doc
  run "$CHECK" shooter --systems --file
  assert_success
  assert_called 'notes ptask shooter --agent add chore(docs): An architecture doc #size/s #low'
  # NEGATIVE CONTROL: systems mode never opens a stage epic on the human sheet.
  assert_not_called 'add epic(stage)'
  refute_output --partial 'epic opened'
}

@test "file: a repo with no sheet files its systems rows on its board, each naming the repo, and one with no board exits 2" {
  write_systems_doc
  mkdir -p "$HOME/tool"
  jq --arg r "$HOME/tool" '.paths[$r] = "tool-canon" | .trackers["tool-canon"] = {type: "infra"}' "$PROJECT_MAP_FILE" > "$HOME/map.new" && mv "$HOME/map.new" "$PROJECT_MAP_FILE"
  # NEGATIVE CONTROL: no `board` key, so there is no sheet to file on.
  run "$CHECK" tool-canon --systems --file
  assert_failure 2
  assert_output --partial 'has no lab sheet to file rows on'
  assert_not_called 'ptask'
  jq '.trackers["tool-canon"].board = "shooter"' "$PROJECT_MAP_FILE" > "$HOME/map.new" && mv "$HOME/map.new" "$PROJECT_MAP_FILE"
  epics '[{"id":"sh-5","system":"docs","title":"docs for shooter"}]'
  run "$CHECK" tool-canon --systems --file
  assert_success
  assert_line --regexp '^filed +docs +tool-canon: An architecture doc$'
  assert_called 'notes ptask shooter --agent add chore(docs): tool-canon: An architecture doc #of/sh-5 #size/s #low'
  assert_called 'from project-stage-check tool-canon --file, tool-canon: systems.md docs'
  assert_not_called 'ptask tool-canon'
}

@test "file: --json keeps the report on stderr and prints the check of its target with the rows it filed" {
  # Declared dev, but an open beta epic raises the target past alpha: the JSON says beta.
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board_row '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->'
  mkdir -p "$LAB/agent/versions"
  printf -- '- [x] chore(beta): A changelog #size/s <!-- id:sh-3 dropped: twin -->\n- [x] feat(ui): hand work <!-- id:sh-4 -->\n' > "$LAB/agent/versions/v0.0.9.md"
  parses '- [x] chore(beta): A changelog #size/s <!-- id:sh-3 dropped: twin -->'
  # NEGATIVE CONTROL: a human-sheet twin and an agent row of another title count as neither.
  printf -- '- [ ] chore(beta): A changelog <!-- id:sh-5 -->\n' >> "$LAB/README.md"
  parses '- [ ] chore(beta): A changelog <!-- id:sh-5 -->'
  run --separate-stderr "$CHECK" shooter --file --json
  assert_success
  [[ "$stderr" == *'file: shooter #beta: 1 failing, 0 listed, 0 held by their own row, 1 closed or dropped'* ]]
  run jq -c '[.stage, .met, .total, .fail, .blocks, .filed_open, .filed_closed]' <<<"$output"
  assert_output '["beta",4,7,1,false,1,1]'
  assert_not_called 'ptask'
  # Systems mode prints its own check, the row it filed counted open.
  write_systems_doc
  run --separate-stderr "$CHECK" shooter --systems --file --json
  assert_success
  jq -e 'has("systems") and .filed_open == 1 and .filed_closed == 0' <<<"$output"
  [[ "$stderr" == *'file: shooter systems:'* ]]
}

@test "file: an unknown project exits 2, with --json too and nothing on stdout" {
  run "$CHECK" nobody --file
  assert_failure 2
  run --separate-stderr "$CHECK" nobody --file --json
  assert_failure 2
  assert_output ''
}

# -- predicates in the real stages.md, run against fixtures --

# real_check <requirement prefix>: the Check cell of that row in the shipped stages.md, as the
# only Requirements row of the test's doc.
real_row() {
  local row
  row="$(grep -F "| $1" "$REPO_ROOT/.local/src/docs/stages.md" | head -1)"
  [ -n "$row" ] || { echo "no row: $1" >&2; return 1; }
  { printf '# Stages\n\n## Requirements\n\n| Stage | Applies | Requirement | Check | Dept |\n|---|---|---|---|---|\n%s\n\n' "$row"; real_depts; } > "$STAGES_DOC"
}

# real_depts: the Departments section of the shipped stages.md, which every Dept cell must name.
real_depts() {
  awk '/^## /{p = ($0 == "## Departments")} p' "$REPO_ROOT/.local/src/docs/stages.md"
}

@test "stages.md: a game's design doc is read at the repo root on origin/HEAD, whatever the default branch is called" {
  real_row 'draft | game | A pitch in the lab'
  mkdir -p "$LAB/docs" "$REPO/docs/games"; printf '# idea\n' > "$LAB/docs/idea.md"
  printf '# shooter\n' > "$REPO/docs/games/shooter.md"
  git -C "$REPO" init -q -b develop
  git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm docs
  git clone -q --bare "$REPO" "$HOME/origin.git"
  git -C "$REPO" remote add origin "$HOME/origin.git"
  git -C "$REPO" fetch -q origin && git -C "$REPO" remote set-head origin -a >/dev/null
  rm "$REPO/docs/games/shooter.md"
  # NEGATIVE CONTROL: the row read origin/main, which a develop repo has not got.
  run "$CHECK" shooter --stage draft
  assert_line --regexp '^PASS +draft +A pitch in the lab'
  git -C "$REPO" remote remove origin
  run "$CHECK" shooter --stage draft
  assert_line --regexp '^FAIL +draft +A pitch in the lab'
  printf '# shooter\n' > "$REPO/docs/games/shooter.md"
  run "$CHECK" shooter --stage draft
  assert_line --regexp '^PASS +draft +A pitch in the lab'
}

@test "stages.md: the incident runbook needs how to tell it is down, who is paged and the rollback" {
  real_row 'prod | base | An incident runbook'
  d="$REPO/Assets/Games/Shooter/docs/operations"; mkdir -p "$d"
  printf '# Runbook\n\n## Rollback\n\nRedeploy the last tag.\n' > "$d/runbook.md"
  run "$CHECK" shooter --stage prod
  # NEGATIVE CONTROL: a runbook that is only a rollback is not met.
  assert_line --regexp '^FAIL +prod +An incident runbook'
  printf '# Runbook\n\n## Is it down\n\nThe health watch goes red.\n\n## Who is paged\n\nThe owner, by agent-notify.\n\n## Rollback\n\nRedeploy the last tag.\n' > "$d/runbook.md"
  run "$CHECK" shooter --stage prod
  assert_line --regexp '^PASS +prod +An incident runbook'
}

@test "stages.md: privacy and terms are met by files of those names or by a route named exactly privacy or terms" {
  real_row 'beta | app | Published privacy and terms'
  jq '.trackers.shooter.type = "app"' "$PROJECT_MAP_FILE" > "$HOME/map.json" && mv "$HOME/map.json" "$PROJECT_MAP_FILE"
  s="$REPO/Assets/Games/Shooter"; mkdir -p "$s/docs/legal"
  printf '# Privacy\n' > "$s/docs/legal/PRIVACY.md"; printf '# Terms\n' > "$s/docs/legal/TERMS.md"
  run "$CHECK" shooter --stage beta
  assert_line --regexp '^PASS +beta +Published privacy and terms'
  rm -r "$s/docs/legal"
  d="$s/web/src"; mkdir -p "$d/app/privacy" "$d/app/terms" "$d/app/account/privacy-settings"
  printf 'export default function P() {}\n' > "$d/app/privacy/page.tsx"
  printf 'export default function T() {}\n' > "$d/app/terms/layout.tsx"
  printf 'export default function S() {}\n' > "$d/app/account/privacy-settings/page.tsx"
  run "$CHECK" shooter --stage beta
  # NEGATIVE CONTROL: a terms route with only a layout is not a page.
  assert_line --regexp '^FAIL +beta +Published privacy and terms'
  # NEGATIVE CONTROL: a settings screen whose route only starts with privacy is not the policy.
  rm -r "$d/app/privacy"
  printf 'export default function T() {}\n' > "$d/app/terms/page.tsx"
  run "$CHECK" shooter --stage beta
  assert_line --regexp '^FAIL +beta +Published privacy and terms'
  # A pages-router index route counts the same as an app-router page.
  mkdir -p "$d/pages/privacy"; printf 'export default function P() {}\n' > "$d/pages/privacy/index.tsx"
  run "$CHECK" shooter --stage beta
  assert_line --regexp '^PASS +beta +Published privacy and terms'
}

@test "stages.md: the STATUS row passes a status under 14 days old and fails an older or missing one" {
  real_row 'beta | base | A STATUS line under 14 days old'
  jq -n --arg d "$(date -d '3 days ago' +%F)" '[{name: "shooter", status_date: $d}]' > "$NOTES_FIXTURE/stats.json"
  run "$CHECK" shooter --stage beta
  assert_line --regexp '^PASS +beta +A STATUS line under 14 days old$'
  # NEGATIVE CONTROL: before this row had a predicate it was TODO whatever the date.
  jq -n --arg d "$(date -d '20 days ago' +%F)" '[{name: "shooter", status_date: $d}]' > "$NOTES_FIXTURE/stats.json"
  run "$CHECK" shooter --stage beta
  assert_line --regexp '^FAIL +beta +A STATUS line under 14 days old$'
  jq -n '[{name: "shooter", status_date: ""}]' > "$NOTES_FIXTURE/stats.json"
  run "$CHECK" shooter --stage beta
  assert_line --regexp '^FAIL +beta +A STATUS line under 14 days old$'
}

@test "stages.md: a game needs its build profile and a play test class; the whole-repo playground passes" {
  real_row 'dev | game | A build profile in'
  git -C "$REPO" init -q
  run "$CHECK" shooter --stage dev
  assert_line --regexp '^FAIL +dev +A build profile'
  mkdir -p "$REPO/scripts/build/games" "$REPO/Assets/Playground/Tests/Runtime"
  printf '{}\n' > "$REPO/scripts/build/games/shooter.json"
  run "$CHECK" shooter --stage dev
  assert_line --regexp '^FAIL +dev +A build profile'
  printf 'class ShooterArenaPlayTests {}\n' > "$REPO/Assets/Playground/Tests/Runtime/ShooterArenaPlayTests.cs"
  git -C "$REPO" add -A
  run "$CHECK" shooter --stage dev
  assert_line --regexp '^PASS +dev +A build profile'
  # The playground project is the repo itself; its games carry the row on their own projects.
  rm "$REPO/scripts/build/games/shooter.json"
  jq --arg r "$REPO" '.trackers["games-canon"] += {lab: "personal", type: "game"}' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  mkdir -p "$ROOTS/games-canon"; printf '# games\nVersion: v0.1.0 #dev\n' > "$ROOTS/games-canon/README.md"; printf '# g\n' > "$ROOTS/games-canon/summary.md"
  run "$CHECK" games-canon --stage dev
  assert_line --regexp '^PASS +dev +A build profile'
}

# rs_stub <stages-json>: release-state's snapshot as the stage rows read it.
rs_stub() {
  printf '{"rows": [], "stages": %s}\n' "$1" > "$SANDBOX/rs.json"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/rs.json" > "$SANDBOX/bin/release-state"
  chmod +x "$SANDBOX/bin/release-state"
}

@test "stages.md: no draft or dev row reads where a project deploys (a deploy is not the app being live)" {
  # Every real draft and dev row, run for a project with a prod deploy: none may ask release-state,
  # the only source of deploy facts, so none can cap where a project deploys.
  { printf '# Stages\n\n## Requirements\n\n| Stage | Applies | Requirement | Check | Dept |\n|---|---|---|---|---|\n'
    grep -E '^\| (draft|dev) \|' "$REPO_ROOT/.local/src/docs/stages.md"; echo; real_depts; } > "$STAGES_DOC"
  rs_stub '{"shooter": {"stage": "draft", "rungs": ["prod"]}}'
  printf '#!/usr/bin/env bash\ntouch "%s"\ncat "%s"\n' "$SANDBOX/rs.asked" "$SANDBOX/rs.json" > "$SANDBOX/bin/release-state"
  for stage in draft dev; do run "$CHECK" shooter --stage "$stage"; done
  [ ! -e "$SANDBOX/rs.asked" ]
  # Negative control: the alpha rung row does ask, so the marker would have caught a draft one.
  real_row 'alpha | game, app | A private target live'
  run "$CHECK" shooter --stage alpha
  [ -e "$SANDBOX/rs.asked" ]
}

@test "stages.md: each deploy rung row passes only when a live target serves that rung" {
  real_row 'alpha | game, app | A private target live'
  rs_stub '{"shooter": {"stage": "alpha", "rungs": ["prod"]}}'
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +A private target live'
  rs_stub '{"shooter": {"stage": "alpha", "rungs": ["alpha", "prod"]}}'
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^PASS +alpha +A private target live'
  real_row 'beta | store | Its external tester channel live'
  run "$CHECK" shooter --stage beta
  assert_line --regexp '^FAIL +beta +Its external tester channel live'
  real_row 'prod | game, app | Live on a public channel'
  run "$CHECK" shooter --stage prod
  assert_line --regexp '^PASS +prod +Live on a public channel'
}

# Shooter's root is Assets/Games/Shooter in $REPO, so its id is shooter.
@test "stages.md: a game's title screen, icon and splash, taste and rating rows read its own files" {
  local root="$REPO/Assets/Games/Shooter"
  export SYSTEMS_DOC="$REPO_ROOT/.local/src/docs/systems.md" PATH="$REPO_ROOT/.local/bin:$PATH"
  for r in 'alpha | game | A title screen' 'alpha | game | An app icon and splash' 'alpha | game | A written taste' 'beta | game | Content rating done'; do
    real_row "$r"
    run "$CHECK" shooter --stage beta
    assert_line --regexp "^FAIL +[a-z]+ +${r##*| }"
  done
  mkdir -p "$root/Resources/Games" "$REPO/scripts/build/games" "$REPO/Assets/Br" "$REPO/docs/games" "$REPO/store/shooter"
  printf '{"standalone": true, "titleScreen": {"modes": [{"label": "Play", "game": "shooter"}]}}\n' > "$root/Resources/Games/shooter.json"
  printf '{"branding": {"icon": "Assets/Br/icon.png", "splash": ["Assets/Br/splash.png", "Assets/Br/splash2.png"]}}\n' > "$REPO/scripts/build/games/shooter.json"
  touch "$REPO/Assets/Br/icon.png" "$REPO/Assets/Br/splash.png" "$REPO/Assets/Br/splash2.png"
  printf '# Shooter: look\n\n## Taste\n\nDraft\n' > "$REPO/docs/games/shooter-look.md"
  printf '{"rating": {"answers": {"violence": "fantasy"}}}\n' > "$REPO/store/shooter/game.json"
  for r in 'alpha | game | A title screen' 'alpha | game | An app icon and splash' 'alpha | game | A written taste' 'beta | game | Content rating done'; do
    real_row "$r"
    run "$CHECK" shooter --stage beta
    assert_line --regexp "^PASS +[a-z]+ +${r##*| }"
  done
  # NEGATIVE CONTROLS: no repo at all, a title screen with no modes, the second splash missing, empty answers.
  jq 'del(.trackers.shooter.repo, .trackers.shooter.path)' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && cp "$PROJECT_MAP_FILE" "$PROJECT_MAP_FILE.keep" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  for r in 'alpha | game | A title screen' 'alpha | game | An app icon and splash' 'alpha | game | A written taste' 'beta | game | Content rating done'; do
    real_row "$r"
    run "$CHECK" shooter --stage beta
    assert_line --regexp "^FAIL +[a-z]+ +${r##*| }"
  done
  mv "$PROJECT_MAP_FILE.keep" "$PROJECT_MAP_FILE"
  printf '{"standalone": true, "titleScreen": {"modes": []}}\n' > "$root/Resources/Games/shooter.json"
  real_row 'alpha | game | A title screen'; run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +A title screen'
  rm "$REPO/Assets/Br/splash2.png"
  real_row 'alpha | game | An app icon and splash'; run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +An app icon and splash'
  printf '{"rating": {"answers": {}}}\n' > "$REPO/store/shooter/game.json"
  real_row 'beta | game | Content rating done'; run "$CHECK" shooter --stage beta
  assert_line --regexp '^FAIL +beta +Content rating done'
}

@test "stages.md: the store listing row reads a game's listing.json or an app's metadata.yaml" {
  export SYSTEMS_DOC="$REPO_ROOT/.local/src/docs/systems.md" PATH="$REPO_ROOT/.local/bin:$PATH"
  real_row 'alpha | store | Its store listing'
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +Its store listing'
  # NEGATIVE CONTROL: a listing with no name or title is a scaffold, not a listing.
  mkdir -p "$REPO/store/shooter/steam"; printf '{}\n' > "$REPO/store/shooter/steam/listing.json"
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +Its store listing'
  printf '{"name": "Shooter"}\n' > "$REPO/store/shooter/steam/listing.json"
  mkdir -p "$REPO/store/shooter/play"; printf '{"title": "Shooter"}\n' > "$REPO/store/shooter/play/listing.json"
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^PASS +alpha +Its store listing'
  # A store app (a play target): its listing is mobile/metadata.yaml in its own folder.
  jq '.trackers.shooter.type = "app" | .trackers.shooter.targets = [{"id": "shooter-play", "where": "play", "live": {"play": {}}}]' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  rm -r "$REPO/store"
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +Its store listing'
  mkdir -p "$REPO/Assets/Games/Shooter/mobile"; touch "$REPO/Assets/Games/Shooter/mobile/metadata.yaml"
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +Its store listing'
  printf 'title: Shooter\n' > "$REPO/Assets/Games/Shooter/mobile/metadata.yaml"
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^PASS +alpha +Its store listing'
}

@test "stages.md: an app's icon and splash, brand sheet and a UI audit under 90 days" {
  jq '.trackers.shooter.type = "app"' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  local root="$REPO/Assets/Games/Shooter"
  mkdir -p "$root/mobile/assets" "$root/docs" "$REPO/docs/plans"
  printf '{"expo": {"icon": "./assets/icon.png", "splash": {"image": "./assets/splash.png"}}}\n' > "$root/mobile/app.json"
  touch "$root/mobile/assets/icon.png"
  real_row "alpha | app | A mobile app's icon"; run "$CHECK" shooter --stage alpha
  assert_line --regexp "^FAIL +alpha +A mobile app's icon"
  touch "$root/mobile/assets/splash.png"; run "$CHECK" shooter --stage alpha
  assert_line --regexp "^PASS +alpha +A mobile app's icon"
  real_row 'alpha | app | A brand sheet'
  printf '# Brand\n\n## Palette\n' > "$root/docs/brand.md"; run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +A brand sheet'
  printf '\n## Logo\n' >> "$root/docs/brand.md"; run "$CHECK" shooter --stage alpha
  assert_line --regexp '^PASS +alpha +A brand sheet'
  real_row 'beta | app | A UI polish pass'
  touch "$REPO/docs/plans/$(date -d '120 days ago' +%F)_Shooter_ui_audit.md"; run "$CHECK" shooter --stage beta
  assert_line --regexp '^FAIL +beta +A UI polish pass'
  touch "$REPO/docs/plans/$(date -d '10 days ago' +%F)_Shooter_ui_audit.md"; run "$CHECK" shooter --stage beta
  assert_line --regexp '^PASS +beta +A UI polish pass'
}

@test "Applies store: an app with no store target skips the store rows; a play target brings them in" {
  export SYSTEMS_DOC="$REPO_ROOT/.local/src/docs/systems.md" PATH="$REPO_ROOT/.local/bin:$PATH"
  jq '.trackers.shooter.type = "app"' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  real_row 'alpha | store | Its store listing'
  run "$CHECK" shooter --stage alpha
  refute_line --partial 'Its store listing'
  run "$CHECK" shooter --system store
  assert_failure 2
  assert_output --partial 'does not apply'
  # NEGATIVE CONTROL: a play target makes it a store project, so the row runs and fails.
  jq '.trackers.shooter.targets = [{"id": "shooter-play", "channel": "internal", "where": "play", "live": {"play": {}}}]' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  run "$CHECK" shooter --stage alpha
  assert_line --regexp '^FAIL +alpha +Its store listing'
  run "$REPO_ROOT/.local/bin/project-system-check" shooter --list
  assert_line --regexp '^store'
}

@test "Applies store: an unreadable target fails the check with exit 2, never a silent skip" {
  jq '.trackers.shooter.type = "app" | .trackers.shooter.targets = [{"id": "bad", "live": "play"}]' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  run "$CHECK" shooter --stage alpha
  assert_failure 2
  assert_output --partial 'cannot read the targets of "shooter"'
}

@test "--requirements lists every Requirements row with its check kind, for no project" {
  run "$CHECK" --requirements --json
  assert_success
  run jq -c '[.enforced_from, (.requirements | length)]' <<<"$output"
  assert_output '["2026-11-19",8]'
  run bash -c '"$0" --requirements --json | jq -r ".requirements[] | [.stage, (.applies | join(\",\")), .kind, .requirement] | @tsv"' "$CHECK"
  assert_line --index 0 "$(printf 'draft\tbase\tpredicate\tA lab sheet')"
  assert_line --index 4 "$(printf 'alpha\tbase\thuman\tPlays start to finish')"
  assert_line --index 5 "$(printf 'alpha\tbase\tnot-yet\tA deploy workflow')"
  # An escaped pipe stays one cell and one predicate.
  assert_line --index 6 "$(printf 'alpha\tbase\tpredicate\tA cell with a | pipe')"
  refute_output --partial 'outside Requirements'
}

@test "--requirements names only the backticked skills that exist, and a check that names one never runs" {
  export SKILLS_DIR="$HOME/skills"
  mkdir -p "$SKILLS_DIR/docs-write" "$SKILLS_DIR/half-made"
  printf -- '---\nname: docs-write\n---\n' > "$SKILLS_DIR/docs-write/SKILL.md"
  cat >> "$STAGES_DOC" <<'EOF2'

## Requirements

| dev | app, store | A brand sheet, by `docs-write`, `docs-write` again, `half-made` and `no-such-skill` | `regen-anchor.sh` marks it `STALE` | engineering |
EOF2
  run bash -c '"$0" --requirements --json | jq -c ".requirements[-1] | [.applies, .kind, .skills]"' "$CHECK"
  assert_success
  # NEGATIVE CONTROL: a dir with no SKILL.md and an unknown name are not skills; a cell of two
  # code spans names a check, so it is not-yet, never a predicate.
  assert_output '[["app","store"],"not-yet",["docs-write"]]'
}

@test "--requirements keeps an empty cell in its column" {
  cat >> "$STAGES_DOC" <<'EOF2'

## Requirements

| beta |  | A row whose Applies cell is empty | `true` | ops |
EOF2
  run bash -c '"$0" --requirements --json | jq -c ".requirements[-1] | [.applies, .kind, .requirement, .check]"' "$CHECK"
  assert_success
  # NEGATIVE CONTROL: read on tabs, the empty cell collapsed and the requirement became Applies.
  assert_output '[[],"predicate","A row whose Applies cell is empty","`true`"]'
}

@test "--requirements takes no project, and a doc with no Requirements rows exits 2" {
  run "$CHECK" shooter --requirements
  assert_failure 2
  assert_output --partial 'takes no project'
  printf '# Stages\n' > "$STAGES_DOC"
  run "$CHECK" --requirements
  assert_failure 2
  assert_output --partial 'no Requirements rows'
}
