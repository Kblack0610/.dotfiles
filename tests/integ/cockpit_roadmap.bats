#!/usr/bin/env bats
# The `o` version browser, once a project sheet has a ROADMAP.
#
# The browser used to list one thing (frozen version notes, newest first) and so needed no
# row grammar. It now holds three: the overview, the live waves (current + planned), and
# the frozen notes. One list, three behaviours for `enter`/preview/`C-s` -- which only works
# because every row carries its KIND and its VERSION. These tests pin that wire and the two
# things a wrong row would silently do: preview the wrong version's work, or add a task to a
# version the human was not looking at.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PROJ="$HOME/vault/demo"
  mkdir -p "$PROJ/versions"
  : > "$PROJ/summary.md"
  printf 'demo\t%s\tactive\tv1.13.0\n' "$PROJ/summary.md" > "$NOTES_FIXTURE/projects.personal"

  # A sheet mid-roadmap. v1.140.0 is a DECOY: as a regex, `v1.14.0` is six wildcards, so a
  # preview that pattern-matches instead of comparing can land on the wrong heading.
  cat > "$PROJ/README.md" <<'EOF'
# demo
Version: v1.13.0

## Wave: v1.13.0 (current)
- [ ] LIVE-TASK

## Wave: v1.14.0 (planned)
- [ ] PLANNED-TASK

## Wave: v1.140.0 (planned)
- [ ] DECOY-TASK

## Backlog
- [ ] BACKLOG-TASK
EOF

  cat > "$NOTES_FIXTURE/waves.demo" <<'EOF'
v1.13.0	current	1	0	Wave: v1.13.0 (current)
v1.14.0	planned	1	0	Wave: v1.14.0 (planned)
v1.140.0	planned	1	0	Wave: v1.140.0 (planned)
EOF

  printf '# v1.11.0\n\nOLDER-RELEASE\n' > "$PROJ/versions/v1.11.0.md"
  printf '# v1.12.0\n\nFROZEN-BODY\n' > "$PROJ/versions/v1.12.0.md"
}

notes_calls() { grep '^notes ' "$NOTES_FIXTURE/calls.log" 2>/dev/null || true; }
kinds() { awk -F'\t' '{print $3}'; }

# ── the row list ─────────────────────────────────────────────────────────────

# The list reads DOWN out of the future and into the past. Getting this backwards is not
# cosmetic: the human's eye lands at the top, and the top should be the furthest plan.
@test "the roadmap reads future -> past: overview, planned descending, current, frozen" {
  run "$COCKPIT" --wave-rows personal demo
  assert_success
  local got
  got="$(printf '%s\n' "$output" | awk -F'\t' '{print $4}' | tr '\n' ' ')"
  assert_equal "$got" "- v1.140.0 v1.14.0 v1.13.0 v1.12.0.md v1.11.0.md "
}

@test "every row carries the kind that decides how enter, preview and C-s behave" {
  run "$COCKPIT" --wave-rows personal demo
  assert_success
  local got
  got="$(printf '%s\n' "$output" | kinds | tr '\n' ' ')"
  assert_equal "$got" "overview wave wave wave frozen frozen "
}

# A wave row must point at the live SHEET (that is what `enter` opens and what the preview
# slices); a frozen row at its own note.
@test "wave rows point at the sheet and frozen rows at their note" {
  run "$COCKPIT" --wave-rows personal demo
  assert_success
  local waves frozen
  waves="$(printf '%s\n' "$output" | awk -F'\t' '$3=="wave"{print $2}' | sort -u)"
  frozen="$(printf '%s\n' "$output" | awk -F'\t' '$3=="frozen"{print $2}' | head -1)"
  assert_equal "$waves" "$PROJ/README.md"
  assert_equal "$frozen" "$PROJ/versions/v1.12.0.md"
}

@test "the current wave is marked apart from the planned ones" {
  run "$COCKPIT" --wave-rows personal demo
  assert_success
  assert_line --partial '> v1.13.0'
  assert_line --partial '+ v1.14.0'
}

# A project with no wave sheet at all (a legacy changelog-only one) still browses.
@test "a project with no waves still lists its overview and frozen notes" {
  rm -f "$PROJ/README.md" "$NOTES_FIXTURE/waves.demo"
  run "$COCKPIT" --wave-rows personal demo
  assert_success
  local got
  got="$(printf '%s\n' "$output" | kinds | tr '\n' ' ')"
  assert_equal "$got" "overview frozen frozen "
}

# ── the preview ──────────────────────────────────────────────────────────────

@test "previewing a wave shows that wave alone -- not its neighbour, not the backlog" {
  run "$COCKPIT" --preview-version wave "$PROJ/README.md" v1.14.0 personal demo
  assert_success
  assert_output --partial 'PLANNED-TASK'
  refute_output --partial 'DECOY-TASK'
  refute_output --partial 'LIVE-TASK'
  refute_output --partial 'BACKLOG-TASK'
}

# Asked for the version further down the roadmap, the scan must reach it rather than stop
# at the first heading that is merely close.
@test "previewing a later wave reaches it instead of stopping at an earlier one" {
  run "$COCKPIT" --preview-version wave "$PROJ/README.md" v1.140.0 personal demo
  assert_success
  assert_output --partial 'DECOY-TASK'
  refute_output --partial 'PLANNED-TASK'
}

@test "previewing a wave with no AI note says so instead of rendering nothing" {
  run "$COCKPIT" --preview-version wave "$PROJ/README.md" v1.13.0 personal demo
  assert_success
  assert_output --partial 'LIVE-TASK'
  assert_output --partial 'no AI notes for v1.13.0'
}

@test "previewing a wave appends the version's AI note" {
  mkdir -p "$PROJ/ai"
  printf '# demo v1.13.0 - AI notes\n\n## Proof\nPROOF-ROW-HERE\n' > "$PROJ/ai/v1.13.0.md"
  run "$COCKPIT" --preview-version wave "$PROJ/README.md" v1.13.0 personal demo
  assert_success
  assert_output --partial 'LIVE-TASK'
  assert_output --partial 'PROOF-ROW-HERE'
}

@test "a frozen row still previews its whole note" {
  run "$COCKPIT" --preview-version frozen "$PROJ/versions/v1.12.0.md" v1.12.0 personal demo
  assert_success
  assert_output --partial 'FROZEN-BODY'
  refute_output --partial 'OLDER-RELEASE'
}

# ── adding to a wave ─────────────────────────────────────────────────────────

@test "adding to the highlighted wave targets THAT version" {
  run bash -c "printf 'a new thing\n' | '$COCKPIT' --wave-add personal demo wave v1.14.0"
  assert_success
  run notes_calls
  assert_output --partial 'ptask demo add --to v1.14.0 a new thing'
}

# The guard that stops `a` on the overview or a frozen row from guessing a version. Without
# it the task lands on whatever `--to` was left holding.
@test "adding from a non-wave row refuses instead of guessing a version" {
  run bash -c "printf 'a new thing\n' | '$COCKPIT' --wave-add personal demo frozen v1.12.0"
  assert_success
  assert_output --partial 'not a wave row'
  run notes_calls
  refute_output --partial 'ptask demo add'
}

@test "an empty answer adds nothing" {
  run bash -c "printf '\n' | '$COCKPIT' --wave-add personal demo wave v1.14.0"
  assert_success
  run notes_calls
  refute_output --partial 'ptask demo add'
}

# ── planning a version ───────────────────────────────────────────────────────

@test "planning a version opens it with its first task" {
  run bash -c "printf 'v1.15.0\nthe first thing\n' | '$COCKPIT' --wave-plan personal demo"
  assert_success
  run notes_calls
  assert_output --partial 'ptask demo add --to v1.15.0 the first thing'
}

# A heading with nothing under it is a version that says nothing, and `ptask add --to` is
# what mints the section -- so there is no way to open one empty, and no second verb.
@test "planning a version with no first task opens nothing" {
  run bash -c "printf 'v1.15.0\n\n' | '$COCKPIT' --wave-plan personal demo"
  assert_success
  assert_output --partial 'opens with its first task'
  run notes_calls
  refute_output --partial 'ptask demo add'
}
