#!/usr/bin/env bats
# fleet.sh's row wire format and its three parsing helpers.
#
# The row format is the contract with fzf: every --bind runs `$SELF --verb {2} {3}` and
# reloads, and fzf slices rows with `--delimiter=$'\t' --with-nth='5..'`. Documented at
# fleet.sh:34 as
#   1 type(head|runner|watch|ask|agent|hint)  2 id  3 target  4 state  5 DISPLAY
# If a field moves, every keybinding silently acts on the wrong thing -- fzf passes {2}
# and {3} positionally and cannot know they now mean something else.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$FLEET"
}

# ── row / head_row / hint_row ────────────────────────────────────────────────

@test "row emits exactly 5 tab-separated fields" {
  run bash -c 'source "$FLEET"; row runner n svc active DISP | awk -F"\t" "{print NF}"'
  assert_output '5'
}

@test "row places each field in its documented position" {
  local r; r="$(row watch home-k3s /path/to.yaml TRIP 'the display')"
  assert_equal "$(printf '%s' "$r" | cut -f1)" 'watch'
  assert_equal "$(printf '%s' "$r" | cut -f2)" 'home-k3s'
  assert_equal "$(printf '%s' "$r" | cut -f3)" '/path/to.yaml'
  assert_equal "$(printf '%s' "$r" | cut -f4)" 'TRIP'
  assert_equal "$(printf '%s' "$r" | cut -f5)" 'the display'
}

@test "head_row is non-actionable: its id and target fields are empty" {
  # fzf binds act on {2}/{3}; a header that carried an id would make Enter do something.
  local r; r="$(head_row 'runners')"
  assert_equal "$(printf '%s' "$r" | cut -f1)" 'head'
  assert_equal "$(printf '%s' "$r" | cut -f2)" ''
  assert_equal "$(printf '%s' "$r" | cut -f3)" ''
}

@test "hint_row is non-actionable too" {
  local r; r="$(hint_row 'nothing pending')"
  assert_equal "$(printf '%s' "$r" | cut -f1)" 'hint'
  assert_equal "$(printf '%s' "$r" | cut -f2)" ''
}

# ── _age ─────────────────────────────────────────────────────────────────────

@test "_age renders seconds, minutes, hours and days at the right scale" {
  local now; now="$(date +%s)"
  assert_equal "$(_age $((now - 30)))"    '30s'
  assert_equal "$(_age $((now - 300)))"   '5m'
  assert_equal "$(_age $((now - 7200)))"  '2h0m'
  assert_equal "$(_age $((now - 200000)))" '2d7h'
}

@test "_age returns a dash for a missing or non-numeric epoch" {
  assert_equal "$(_age '')" '-'
  assert_equal "$(_age 'not-a-number')" '-'
}

@test "_age clamps a future timestamp to zero rather than printing a negative age" {
  # Clock skew between the watch writer and this reader must not render "-3s ago".
  local now; now="$(date +%s)"
  assert_equal "$(_age $((now + 600)))" '0s'
}

# ── _clip ────────────────────────────────────────────────────────────────────

@test "_clip leaves text shorter than the width untouched" {
  assert_equal "$(_clip 'short' 20)" 'short'
}

@test "_clip truncates over-long text to exactly the requested width" {
  local out; out="$(_clip 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 10)"
  assert_equal "${#out}" '10'
}

@test "_clip marks truncation so a cut description is not mistaken for the whole one" {
  local out; out="$(_clip 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 10)"
  [[ "$out" == *'…' ]]
}

# ── _yaml_desc ───────────────────────────────────────────────────────────────

@test "_yaml_desc reads a plain inline description" {
  seed_watch w1 OK 'a plain description'
  assert_equal "$(_yaml_desc "$WATCH_DIR/w1.yaml")" 'a plain description'
}

@test "_yaml_desc flattens a YAML folded block into one line" {
  # Real manifests use `description: >-`; the first cut of this rendered the literal ">-".
  seed_watch_folded w2 OK
  local d; d="$(_yaml_desc "$WATCH_DIR/w2.yaml")"
  assert_equal "$d" 'first line of the folded description second line that must be joined'
}

@test "_yaml_desc never returns the block scalar marker itself" {
  seed_watch_folded w3 OK
  local d; d="$(_yaml_desc "$WATCH_DIR/w3.yaml")"
  refute [ "$d" = '>-' ]
  [[ "$d" != *'>-'* ]]
}

@test "_yaml_desc stops at the next top-level key rather than swallowing the file" {
  seed_watch_folded w4 OK
  local d; d="$(_yaml_desc "$WATCH_DIR/w4.yaml")"
  [[ "$d" != *'probe'* ]]
  [[ "$d" != *'interval'* ]]
}

@test "_yaml_desc is empty for a manifest with no description" {
  printf 'name: w5\nprobe: http\n' > "$WATCH_DIR/w5.yaml"
  assert_equal "$(_yaml_desc "$WATCH_DIR/w5.yaml")" ''
}
