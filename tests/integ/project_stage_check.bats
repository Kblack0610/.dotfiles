#!/usr/bin/env bats
# project-stage-check runs the Requirements rows of stages.md for a project, and
# project-map-doctor 6c turns its exit into WARN or FAIL. A tiny stages doc stands in for
# the real one, so each test pins one row kind against a real repo and lab dir.

setup() {
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

| Stage | Applies | Requirement | Check |
|---|---|---|---|
| draft | base | A lab sheet | `[ -f "$LAB/README.md" ]` |
| draft | game | The shared packages | `grep -q blacknbrown "$REPO/Packages/manifest.json"` |
| dev | base | A README where the project lives | `[ -f README.md ]` |
| dev | app | An app-only row | `false` |
| alpha | base | Plays start to finish | human |
| alpha | base | A deploy workflow | not yet: needs the forge API |
| alpha | base | A cell with a \| pipe | `printf 'a\|b' \| grep -q b` |
| beta | base | A changelog | `[ -f CHANGELOG.md ]` |

## Elsewhere

| draft | base | A table outside Requirements | `false` |
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
  assert_output --partial 'system "payments" does not apply to a game project'
  printf '| ghost | base | A row with no system | `true` | none |\n' >> "$SYSTEMS_DOC"
  run "$CHECK" shooter --systems
  assert_failure 2
  assert_output --partial 'a Criteria row names unknown system "ghost"'
}

@test "a stage row can require a system by calling the checker, so the predicate lives in one doc" {
  write_systems_doc
  cat >> "$STAGES_DOC" <<'EOF2'

## Requirements

| dev | base | The docs system meets its criteria | `project-stage-check "$NAME" --system docs` |
EOF2
  mkdir -p "$HOME/bin"; ln -s "$CHECK" "$HOME/bin/project-stage-check"
  PATH="$HOME/bin:$PATH" run "$CHECK" shooter
  assert_output --regexp 'FAIL +dev +The docs system meets its criteria'
  mkdir -p "$REPO/Assets/Games/Shooter/docs"
  printf '# arch\n' > "$REPO/Assets/Games/Shooter/docs/architecture.md"
  PATH="$HOME/bin:$PATH" run "$CHECK" shooter
  assert_output --regexp 'PASS +dev +The docs system meets its criteria'
}

# -- --file: each FAIL row becomes a story under the open epic for its target --

epics() { jq -n --argjson e "$1" '[{name: "shooter", epics: $e}]' > "$NOTES_FIXTURE/stats.json"; }
board_row() { mkdir -p "$LAB/agent"; printf '# shooter agent\n\n## Tasks\n%s\n' "$1" > "$LAB/agent/README.md"; }

@test "file: the stage epic names the target, and each FAIL row is filed once under it" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter, testers"}]'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^filed +beta +A changelog$'
  assert_line 'file: shooter #beta: 1 failing, 1 filed, 0 already open, 0 closed or dropped'
  assert_called 'notes ptask shooter --agent add chore(beta): A changelog #of/sh-1 #size/s --detail from project-stage-check shooter --file, stages.md #beta, check: `[ -f CHANGELOG.md ]`'
  # NEGATIVE CONTROL: the row the first run filed is on the board now, so nothing is added.
  : > "$NOTES_FIXTURE/calls.log"
  board_row '- [ ] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 -->'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^open +beta +A changelog$'
  assert_not_called 'ptask'
}

@test "file: a gap the human dropped or closed is never filed again" {
  epics '[{"id":"sh-1","system":"stage","title":"beta for shooter"}]'
  board_row '- [x] chore(beta): A changelog #of/sh-1 #size/s <!-- id:sh-2 dropped: not this year -->'
  run "$CHECK" shooter --file
  assert_success
  assert_line --regexp '^closed +beta +A changelog$'
  assert_line 'file: shooter #beta: 1 failing, 0 filed, 0 already open, 1 closed or dropped'
  assert_not_called 'ptask'
  # A row archived into a version note counts as well.
  rm "$LAB/agent/README.md"; mkdir -p "$LAB/agent/versions"
  printf '## Done rows\n- [x] chore(beta): A changelog #size/s <!-- id:sh-2 done:2026-10-01 pr:9 -->\n' > "$LAB/agent/versions/v0.0.9.md"
  run "$CHECK" shooter --file
  assert_line --regexp '^closed +beta +A changelog$'
  assert_not_called 'ptask'
}

@test "file: with no open epic it lists the gap and writes nothing; it never files the epic" {
  epics '[]'
  run "$CHECK" shooter --stage beta --file
  assert_success
  assert_line --regexp '^no epic +beta +A changelog$'
  assert_output --partial '1 with no open epic (file `epic(stage): beta ...` on the human sheet)'
  assert_not_called 'ptask'
  # An epic for another stage is not this target's epic.
  epics '[{"id":"sh-1","system":"stage","title":"prod for shooter"}]'
  run "$CHECK" shooter --stage beta --file
  assert_line --regexp '^no epic +beta +A changelog$'
  assert_not_called 'ptask'
}

@test "file: systems rows go under their system's epic, and a long title is cut with the whole text kept" {
  write_systems_doc
  printf '| docs | base | A contributor guide that says how to build, run and test every part of the project from a fresh clone | `false` | onboarding |\n' >> "$SYSTEMS_DOC"
  epics '[{"id":"sh-5","system":"docs","title":"docs for shooter"}]'
  run "$CHECK" shooter --systems --file
  assert_success
  assert_line --regexp '^filed +docs +An architecture doc$'
  assert_line 'file: shooter systems: 2 failing, 2 filed, 0 already open, 0 closed or dropped'
  assert_called 'notes ptask shooter --agent add chore(docs): An architecture doc #of/sh-5 #size/s'
  assert_called 'add chore(docs): A contributor guide that says how to build, run and test every part of the #of/sh-5 #size/s --detail A contributor guide that says how to build, run and test every part of the project from a fresh clone --detail'
}

@test "file: --file with --json is refused, and an unknown project exits 2" {
  run "$CHECK" shooter --file --json
  assert_failure 2
  assert_output --partial '--file and --json do not mix'
  run "$CHECK" nobody --file
  assert_failure 2
}

# -- predicates in the real stages.md, run against fixtures --

# real_check <requirement prefix>: the Check cell of that row in the shipped stages.md, as the
# only Requirements row of the test's doc.
real_row() {
  local row
  row="$(grep -F "| $1" "$REPO_ROOT/.local/src/docs/stages.md" | head -1)"
  [ -n "$row" ] || { echo "no row: $1" >&2; return 1; }
  printf '# Stages\n\n## Requirements\n\n| Stage | Applies | Requirement | Check |\n|---|---|---|---|\n%s\n' "$row" > "$STAGES_DOC"
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
