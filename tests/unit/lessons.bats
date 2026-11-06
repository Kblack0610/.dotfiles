#!/usr/bin/env bats
# lessons: pick ranks a project's lessons against the session's work, log records the lessons
# pick matched to the work, archive moves dated lessons nobody picked or repeated in N days.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  BIN="$BATS_TEST_DIRNAME/../../.local/bin/lessons"
  DIR="$BATS_TEST_TMPDIR/lessons"
  mkdir -p "$DIR"
  F="$DIR/proj.md"
  export LESSONS_DELIVERED_DIR="$DIR/_delivered" LESSONS_OUTCOMES_DIR="$BATS_TEST_TMPDIR/outcomes"
  OLD=$(date -d '-200 days' +%F)
  RECENT=$(date -d '-3 days' +%F)
  cat > "$F" <<EOF
# proj lessons

- Undated rule before any section: keep the waybar chip narrow.

## $OLD: Waybar chips cost width
A new waybar chip costs about 54 px of the bar.
- a sub-bullet that belongs to the section

## $OLD: Nightly reds need one owner
The nightly test run goes red and nobody owns it.
<!-- sig:$OLD nightly.*red -->

- **$OLD** Tmux sessions survive a reboot only through the snapshot.
- **$RECENT** Lessons reach a session through the preflight digest.
EOF
}

# A delivery log that starts before the 90-day window, so archive acts, and that delivered
# the key in $1 (if any) yesterday.
covered_log() {
  mkdir -p "$LESSONS_DELIVERED_DIR"
  printf '%s\tproj\t00000000\n' "$(date -d '-100 days' +%F)" > "$LESSONS_DELIVERED_DIR/$(date -d '-100 days' +%Y-%m).tsv"
  [ -z "${1:-}" ] || printf '%s\tproj\t%s\n' "$(date -d '-1 day' +%F)" "$1" >> "$LESSONS_DELIVERED_DIR/$(date -d '-1 day' +%Y-%m).tsv"
}

@test "pick puts the lessons that match the work first, then the newest" {
  run "$BIN" pick -n 3 "$F" "waybar chip width"
  assert_success
  assert_line --index 0 --partial "## Lessons for this work ("
  assert_line --index 1 --partial "Waybar chips cost width"
  assert_line --index 3 --partial "Lessons reach a session"
}

@test "pick with nothing matching says so and gives the newest" {
  run "$BIN" pick -n 2 "$F" "kubernetes ingress"
  assert_success
  assert_line --index 0 "## Lessons (newest 2; nothing matched this work)"
  assert_line --index 1 --partial "Lessons reach a session"
  assert_line --index 2 --partial "Tmux sessions survive"
}

@test "pick needs two shared words from a multi-word query" {
  run "$BIN" pick -n 1 "$F" "nightly kubernetes"
  assert_line --index 0 --partial "nothing matched"
  run "$BIN" pick -n 1 "$F" "nightly owner"
  assert_line --index 1 --partial "Nightly reds need one owner"
}

@test "pick cuts a long lesson on a word boundary at 200 chars" {
  printf -- '- **%s** %s ~/.dotfiles/path/that/must/not/be/cut/mid/word\n' "$RECENT" "$(printf 'word %.0s' $(seq 1 37))" >> "$F"
  run "$BIN" pick -n 1 "$F"
  line="${lines[1]}"
  [ "${#line}" -le 200 ]
  [[ $line == *"..." ]]
  [[ $line != *"~/.d..." ]]
}

@test "pick on a missing file prints nothing and succeeds" {
  run "$BIN" pick "$DIR/none.md" anything
  assert_success
  assert_output ""
}

@test "log records the keys of the matched lines only, one line per call" {
  "$BIN" pick -n 4 "$F" "waybar chip" | "$BIN" log proj "$F"
  run cat "$LESSONS_DELIVERED_DIR/$(date +%Y-%m).tsv"
  assert_output --regexp "^$(date +%F)	proj	[0-9a-f]{8},[0-9a-f]{8}$"
}

@test "log records nothing for a digest that matched nothing" {
  "$BIN" pick -n 3 "$F" "kubernetes ingress" | "$BIN" log proj "$F"
  [ ! -e "$LESSONS_DELIVERED_DIR/$(date +%Y-%m).tsv" ]
}

@test "archive moves nothing until the delivery log covers the window" {
  run "$BIN" archive "$DIR"
  assert_success
  assert_output --partial "nothing moves until it covers 90 days"
  run grep -c Tmux "$F"
  assert_output 1
}

@test "archive moves a stale dated lesson and keeps picked, sig-hit, recent and undated ones" {
  key=$("$BIN" archive --dry-run "$DIR" | awk '/Waybar chips/ { print $2 }')
  [ -n "$key" ]
  covered_log "$key"
  mkdir -p "$LESSONS_OUTCOMES_DIR/proj"
  printf '{"updated":"%s","lesson_hits":{"nightly.*red":2}}\n' "$RECENT" > "$LESSONS_OUTCOMES_DIR/proj/$(date +%Y-%m).jsonl"
  run "$BIN" archive "$DIR"
  assert_success
  assert_output --partial "proj: moved 1"
  run cat "$F"
  refute_output --partial "Tmux sessions survive"
  assert_output --partial "Waybar chips cost width"
  assert_output --partial "a sub-bullet that belongs to the section"
  assert_output --partial "Nightly reds need one owner"
  assert_output --partial "Undated rule"
  assert_output --partial "Lessons reach a session"
  assert_line --index 0 "# proj lessons"
  run cat "$DIR/_archive/proj-stale.md"
  assert_output --partial "## Archived $(date +%F): no preflight pick and no sig hit in 90 days"
  assert_output --partial "Tmux sessions survive"
}

@test "archive without a sig hit moves the section whole" {
  covered_log
  run "$BIN" archive "$DIR"
  assert_output --partial "proj: moved 3"
  run cat "$DIR/_archive/proj-stale.md"
  assert_output --partial "a sub-bullet that belongs to the section"
  assert_output --partial "<!-- sig:"
}

@test "archive dry run lists candidates and writes nothing" {
  before=$(cat "$F")
  run "$BIN" archive --dry-run "$DIR"
  assert_success
  assert_line --regexp '^proj [0-9a-f]{8} [0-9-]{10} \*\*.*Tmux sessions'
  [ "$(cat "$F")" = "$before" ]
  [ ! -e "$DIR/_archive" ]
}

@test "archive prunes delivery months wholly before the window" {
  covered_log
  old="$LESSONS_DELIVERED_DIR/$(date -d '-150 days' +%Y-%m).tsv" now="$LESSONS_DELIVERED_DIR/$(date +%Y-%m).tsv"
  printf '%s\tproj\tabc\n' "$(date -d '-150 days' +%F)" > "$old"
  printf '%s\tproj\tabc\n' "$(date +%F)" >> "$now"
  run "$BIN" archive "$DIR"
  assert_success
  [ ! -e "$old" ]
  [ -e "$now" ]
}
