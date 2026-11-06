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
