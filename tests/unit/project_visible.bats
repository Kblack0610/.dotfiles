#!/usr/bin/env bats
# Machine visibility, shell side: every project row of tests/fixtures/project-visibility.tsv
# through project_visible in project-name.sh gives what the project-map crate's cargo test reads
# from the same rows, so the shell and Rust rules cannot diverge. Profile rows are Rust-only:
# the shell reads profiles from `notes config --profiles`, which applies the Rust rule.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export PROJECT_MAP_FILE="$REPO_ROOT/tests/fixtures/project-visibility.json"
  TSV="$REPO_ROOT/tests/fixtures/project-visibility.tsv"
  # shellcheck source=../../.config/shared-hooks/project-name.sh
  . "$REPO_ROOT/.config/shared-hooks/project-name.sh"
}

@test "project_visible: every project row of the shared fixture" {
  local n=0 bad="" machine kind name want got
  while IFS=$'\t' read -r machine kind name want; do
    [ "$kind" = project ] || continue
    if PROJECT_MACHINE_PROFILE="$machine" project_visible "$name"; then got=yes; else got=no; fi
    [ "$got" = "$want" ] || bad="$bad$machine $name -> $got (want $want)"$'\n'
    n=$((n + 1))
  done < <(grep -v '^#' "$TSV" | grep -v '^$')
  [ "$n" -ge 12 ] || fail "the fixture lost its rows: $n"
  [ -z "$bad" ] || fail "$bad"
}

@test "project_keys: the personal fleet lists no work project; the work machine lists its own" {
  PROJECT_MACHINE_PROFILE=personal run project_keys
  assert_success
  assert_output "$(printf '%s\n' dotfiles finance)"
  PROJECT_MACHINE_PROFILE=acmework run project_keys
  assert_output "$(printf '%s\n' acme-platform acme_kiosk dotfiles finance)"
}

@test "project_all_keys lists work projects on every machine; project_keys filters it" {
  PROJECT_MACHINE_PROFILE=personal run project_all_keys
  assert_output --partial acme_kiosk
  PROJECT_MACHINE_PROFILE=personal run project_keys
  refute_output --partial acme_kiosk
}

@test "project_machine_profile: notes decides, personal when notes cannot say" {
  unset PROJECT_MACHINE_PROFILE
  notes() { [ "$*" = "config --machine-profile" ] && echo acmework; }
  run project_machine_profile
  assert_output acmework
  notes() { return 1; }
  unset PROJECT_MACHINE_PROFILE
  run --separate-stderr project_machine_profile
  assert_output personal
  [[ "$stderr" == *"work projects are hidden here"* ]] || fail "no warning: $stderr"
}

@test "project_visible and project_keys ask notes once per shell, not once per call" {
  unset PROJECT_MACHINE_PROFILE
  calls="$BATS_TEST_TMPDIR/calls"
  notes() { echo x >> "$calls"; echo acmework; }
  project_visible acme_kiosk
  project_visible dotfiles
  project_keys >/dev/null
  [ "$(wc -l < "$calls")" -eq 1 ] || fail "notes ran $(wc -l < "$calls") times"
}
