#!/usr/bin/env bats
# The name index, shell side: every row of tests/fixtures/project-names.tsv resolves through
# project_canonical in project-name.sh to what the project-map crate's cargo test reads from the
# same rows, so the shell and Rust lookups cannot diverge (rule: docs/operations/release-state.md,
# "Project identity").

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export PROJECT_MAP_FILE="$REPO_ROOT/tests/fixtures/project-names.json"
  TSV="$REPO_ROOT/tests/fixtures/project-names.tsv"
  # shellcheck source=../../.config/shared-hooks/project-name.sh
  . "$REPO_ROOT/.config/shared-hooks/project-name.sh"
}

rows() { grep -v '^#' "$1" | grep -v '^$'; }

# check_rows <tsv> -- each row's spelling through project_canonical; prints the misses and
# fails when there is one, or when the file holds fewer than 20 rows.
check_rows() {
  local n=0 bad="" spelling want got
  while IFS=$'\t' read -r spelling want; do
    got="$(project_canonical "$spelling")"
    [ "$got" = "$want" ] || bad="$bad$spelling -> $got (want $want)"$'\n'
    n=$((n + 1))
  done < <(rows "$1")
  [ "$n" -ge 20 ] || { echo "the fixture lost its rows: $n"; return 1; }
  [ -z "$bad" ] || { printf '%s' "$bad"; return 1; }
}

@test "every fixture spelling resolves through project_canonical as the Rust lookup does" {
  run check_rows "$TSV"
  assert_success
}

@test "project_of_repos_json answers the same rows in one call" {
  local want got
  want="$(rows "$TSV" | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')"
  mapfile -t spellings < <(rows "$TSV" | cut -f1)
  got="$(project_of_repos_json "${spellings[@]}")"
  assert_equal "$(jq -S . <<<"$got")" "$(jq -S . <<<"$want")"
}

@test "negative control: a row naming the wrong key fails the check and is named" {
  { cat "$TSV"; printf 'waybar\tbnb-platform\n'; } > "$SANDBOX/bad.tsv"
  run check_rows "$SANDBOX/bad.tsv"
  assert_failure
  assert_output 'waybar -> dotfiles (want bnb-platform)'
}
