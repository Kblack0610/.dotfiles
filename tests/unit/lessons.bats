#!/usr/bin/env bats
# lessons: pick ranks a project's lessons against the session's work, log records the lessons
# pick matched to the work, archive moves dated lessons nobody picked or repeated in N days,
# dup scores a memory file against the lessons (agentctl-dream refuses one that restates a lesson).

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

@test "pick --matched gives only the matched lessons, and nothing when none match" {
  run "$BIN" pick -n 3 --matched "$F" "waybar chip width"
  assert_success
  assert_line --index 0 --regexp '^## Lessons for this work \([0-9]+ matched on: [a-z, ]+\)$'
  assert_line --index 1 --partial "Waybar chips cost width"
  refute_output --partial "Lessons reach a session"
  run "$BIN" pick --matched "$F" "kubernetes ingress"
  assert_success
  assert_output ""
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

@test "pick cuts a long lesson where a sentence ends, never mid-rule, and skips e.g. as an end" {
  printf -- '- **%s** **The rule is stated here, e.g. in one sentence, and it runs past a hundred characters so that the cut keeps the whole rule.** %s and a tail that goes on.\n' \
    "$RECENT" "$(printf 'extra %.0s' $(seq 1 60))" >> "$F"
  run "$BIN" pick -n 1 "$F"
  line="${lines[1]}"
  [ "${#line}" -le 300 ]
  [[ $line == *"whole rule.**"* ]]
  [[ $line != *"..." ]]
  [[ $line != *"extra"* ]]
}

@test "pick on a missing file prints nothing and succeeds" {
  run "$BIN" pick "$DIR/none.md" anything
  assert_success
  assert_output ""
}

@test "dup names the lesson a memory file restates, with its line and first line" {
  printf -- '---\nname: x\ndescription: unrelated words\n---\nA new waybar chip costs about 54 px of the bar, so keep each chip narrow.\n' > "$DIR/mem.md"
  run "$BIN" dup "$DIR/mem.md" "$F"
  assert_success
  [[ $output == "0."[3-9]*" 5 ## $OLD: Waybar chips cost width" ]]
  printf 'Tmux sessions survive a reboot only through snapshots, never by themselves.\n' > "$DIR/mem.md"
  run "$BIN" dup "$DIR/mem.md" "$F"
  [[ $output == *" 13 - **$OLD** Tmux sessions survive"* ]]
}

@test "dup scores a memory file no lesson holds at zero, front matter ignored" {
  printf -- '---\nname: waybar chip nightly tmux snapshot\n---\nThe backup drive holds weekly mirrors of the shared storage.\n' > "$DIR/mem.md"
  run "$BIN" dup "$DIR/mem.md" "$F"
  assert_success
  assert_output "0.00 0 "
}

@test "dup and pick share a tokenizer: a plural folds to its singular in both" {
  run "$BIN" pick -n 1 "$F" "tmux sessions snapshots"
  assert_line --index 1 --partial "Tmux sessions survive"
  printf 'Tmux sessions survive a reboot only through snapshots.\n' > "$DIR/mem.md"
  run "$BIN" dup "$DIR/mem.md" "$F"
  assert_output --partial " Tmux sessions survive a reboot only through the snapshot."
}

@test "dup reads a memory file whose front matter never closes as body" {
  printf -- '---\nname: x\nTmux sessions survive a reboot only through snapshots, never by themselves.\n' > "$DIR/mem.md"
  run "$BIN" dup "$DIR/mem.md" "$F"
  [[ $output == "0."[3-9]*" 13 - **$OLD** Tmux sessions survive"* || $output == "1.00 13 "* ]]
}

@test "dup ignores the words of a sig marker" {
  sed -i 's/nightly\.\*red/xyzzy plugh/' "$F"
  printf 'The regexes cover xyzzy plugh.\n' > "$DIR/mem.md"
  run "$BIN" dup "$DIR/mem.md" "$F"
  assert_output "0.00 0 "
}

@test "dup on an unreadable file exits 2 and prints no score" {
  run "$BIN" dup "$DIR/none.md" "$F"
  assert_failure 2
}

# One chain and a decoy: the 08-20 bullet marks the 08-18 section (line 3) superseded by its key;
# the 08-21 bullet only reads like a correction, and the old guess by date and words listed it.
chain_file() {
  cat > "$DIR/chain.md" <<'EOF'
# chain lessons

## Dreaming sweep 2026-08-18
- Waybar chips cost about 54 px each on the laptop bar.
- The backup mirror is alive when rev-list counts zero commits ahead of the backup remote.

- **2026-08-20** CORRECTION to the 08-18 section: a zero rev-list count says the backup mirror is reachable. MARK
- **2026-08-21** Correction to the 08-18 bullet: the backup mirror count is zero commits ahead, I listed packages instead.
EOF
  local k; k=$("$BIN" key "$DIR/chain.md" 3)
  sed -i "s/MARK/<!-- supersedes:$k -->/" "$DIR/chain.md"
}

@test "chains lists a lesson whose supersedes marker names a lesson still in the file, and nothing that only reads like a correction" {
  chain_file
  run "$BIN" chains "$DIR/chain.md"
  assert_success
  assert_output --regexp $'^chain.md:7\t3\t- \\*\\*2026-08-20\\*\\* CORRECTION to the 08-18 section'
  assert_equal "${#lines[@]}" 1
}

@test "a marker whose key no lesson carries any more is a dangling chain, target -" {
  chain_file
  sed -i 's/supersedes:[0-9a-f]*/supersedes:deadbeef/' "$DIR/chain.md"
  run "$BIN" chains "$DIR/chain.md"
  assert_success
  assert_output --regexp $'^chain.md:7\t-\t- \\*\\*2026-08-20\\*\\*'
  assert_equal "${#lines[@]}" 1
}

@test "key prints the key of the lesson whose first line it is, and exits 1 on a line inside a lesson or owned by none" {
  chain_file
  run "$BIN" key "$DIR/chain.md" 3
  assert_success
  assert_output --regexp '^[0-9a-f]{8}$'
  refute [ "$output" = "$("$BIN" key "$DIR/chain.md" 7)" ]
  # A marker hides the whole lesson, so one bullet of a section is refused.
  run "$BIN" key "$DIR/chain.md" 5
  assert_failure 1
  assert_output --partial 'line 5 is inside the lesson at line 3'
  run "$BIN" key "$DIR/chain.md" 1
  assert_failure 1
  assert_output --partial 'no lesson owns line 1'
  run "$BIN" key "$DIR/chain.md" x
  assert_failure 2
}

@test "supersede moves a chain target verbatim to _archive/<project>-superseded.md, names its corrector, and drops the marker" {
  chain_file
  cp "$DIR/chain.md" "$BATS_TEST_TMPDIR/before.md"
  run "$BIN" supersede "$DIR"
  assert_success
  assert_output --partial 'lessons supersede: chain: moved 1 to _archive/chain-superseded.md'
  # The section and its bullets left; both correctors stay, the marked one without its marker.
  refute grep -q 'Waybar chips cost' "$DIR/chain.md"
  grep -q 'CORRECTION to the 08-18 section: a zero rev-list count says the backup mirror is reachable.$' "$DIR/chain.md"
  grep -q 'Correction to the 08-18 bullet' "$DIR/chain.md"
  refute grep -q 'supersedes:' "$DIR/chain.md"
  run "$BIN" chains "$DIR"
  assert_output ''
  # The archive holds the old lines as they were, under the replaced-by comment.
  A="$DIR/_archive/chain-superseded.md"
  grep -q '^# chain lessons: superseded entries' "$A"
  grep -q 'replaced by: - \*\*2026-08-20\*\* CORRECTION to the 08-18 section' "$A"
  grep -qxF -- '## Dreaming sweep 2026-08-18' "$A"
  # The comment is one line that closes once: the corrector's own marker is not copied into it.
  [ "$(grep -c 'archived .* by lessons supersede' "$A")" = 1 ]
  [ "$(grep 'archived .* by lessons supersede' "$A" | grep -o -e '-->' | wc -l)" = 1 ]
  grep -qxF -- '- The backup mirror is alive when rev-list counts zero commits ahead of the backup remote.' "$A"
  # Nothing else changed: the kept lines plus the archived ones are the old file, minus the marker.
  sed -E 's/ <!-- supersedes:[0-9a-f]+ -->//' "$BATS_TEST_TMPDIR/before.md" | grep -vxFf "$DIR/chain.md" | grep -v '^$' | grep -vxFf "$A" && fail "a line was lost"
  # A rerun finds no chain and changes nothing.
  cp "$DIR/chain.md" "$BATS_TEST_TMPDIR/after.md"
  run "$BIN" supersede "$DIR"
  assert_output 'lessons supersede: moved 0 superseded lesson(s)'
  cmp "$DIR/chain.md" "$BATS_TEST_TMPDIR/after.md"
}

@test "supersede's replaced-by comment drops the corrector's own marker, even on a short first line" {
  printf -- '- **2026-08-18** Old fact about the mirror.\n- **2026-08-20** Fix: it is up. MARK\n' > "$DIR/short.md"
  k=$("$BIN" key "$DIR/short.md" 1)
  sed -i "s/MARK/<!-- supersedes:$k -->/" "$DIR/short.md"
  run "$BIN" supersede "$DIR"
  assert_success
  run grep 'archived .* by lessons supersede' "$DIR/_archive/short-superseded.md"
  assert_output --regexp 'replaced by: - \*\*2026-08-20\*\* Fix: it is up\. -->$'
}

@test "supersede --dry-run lists the target and writes nothing" {
  chain_file
  cp "$DIR/chain.md" "$BATS_TEST_TMPDIR/before.md"
  run "$BIN" supersede --dry-run "$DIR"
  assert_success
  assert_output --regexp '^chain [0-9a-f]{8} 2026-08-18 Dreaming sweep 2026-08-18$'
  cmp "$DIR/chain.md" "$BATS_TEST_TMPDIR/before.md"
  [ ! -e "$DIR/_archive/chain-superseded.md" ]
}

@test "negative control: supersede leaves a dangling marker for a session to read" {
  chain_file
  sed -i 's/supersedes:[0-9a-f]*/supersedes:deadbeef/' "$DIR/chain.md"
  cp "$DIR/chain.md" "$BATS_TEST_TMPDIR/before.md"
  run "$BIN" supersede "$DIR"
  assert_output 'lessons supersede: moved 0 superseded lesson(s)'
  cmp "$DIR/chain.md" "$BATS_TEST_TMPDIR/before.md"
}

@test "chains over a directory reads each lessons file and not _archive" {
  chain_file
  mkdir -p "$DIR/_archive"
  cp "$DIR/chain.md" "$DIR/_archive/chain-superseded.md"
  run "$BIN" chains "$DIR"
  assert_success
  assert_equal "${#lines[@]}" 1
  refute_output --partial "superseded"
}

@test "chains prefixes a file name sed would choke on as is" {
  chain_file
  mv "$DIR/chain.md" "$DIR/a|b&c.md"
  run "$BIN" chains "$DIR/a|b&c.md"
  assert_success
  assert_line --index 0 --partial 'a|b&c.md:7'
}

@test "pick never hands out a lesson a supersedes marker names, matched or as a newest fill" {
  chain_file
  run "$BIN" pick "$DIR/chain.md" backup mirror reachable
  assert_success
  assert_output --partial 'CORRECTION to the 08-18 section'
  refute_output --partial 'Dreaming sweep'
  run "$BIN" pick -n 5 "$DIR/chain.md" nothing shares this
  assert_line --index 0 '## Lessons (newest 2; nothing matched this work)'
  refute_output --partial 'Dreaming sweep'
  # Negative control: with the marker naming no lesson, the section is handed out again.
  sed -i 's/supersedes:[0-9a-f]*/supersedes:deadbeef/' "$DIR/chain.md"
  run "$BIN" pick -n 5 "$DIR/chain.md" nothing shares this
  assert_output --partial 'Dreaming sweep'
}

@test "pick ignores a stopword shared with a lesson" {
  run "$BIN" pick -n 1 "$F" "never since"
  assert_line --index 0 --partial "nothing matched"
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

@test "archive keeps a stale lesson a supersedes marker names: the docs-cleanup pass folds it, and moving it would dangle the marker" {
  run "$BIN" archive --dry-run "$DIR"
  assert_output --partial "Tmux sessions survive"
  k=$("$BIN" key "$F" 13)
  sed -i "14s/\$/ <!-- supersedes:$k -->/" "$F"
  run "$BIN" archive --dry-run "$DIR"
  assert_success
  refute_output --partial "Tmux sessions survive"
}

@test "a marker names every lesson that carries its key, so a copy of the target is hidden too" {
  printf -- '- **2026-08-18** The mirror is alive at zero.\n- **2026-08-18** The mirror is alive at zero.\n- **2026-08-20** The mirror is reachable at zero. MARK\n' > "$DIR/dup.md"
  k=$("$BIN" key "$DIR/dup.md" 1)
  sed -i "s/MARK/<!-- supersedes:$k -->/" "$DIR/dup.md"
  run "$BIN" chains "$DIR/dup.md"
  assert_line --index 0 --regexp $'^dup.md:3\t1\t'
  assert_line --index 1 --regexp $'^dup.md:3\t2\t'
  run "$BIN" pick -n 5 "$DIR/dup.md" nothing shares this
  assert_line --index 0 '## Lessons (newest 1; nothing matched this work)'
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

# --- groups: a heading that labels bullets is no lesson; each bullet is one -------------------

group_file() {
  G="$DIR/group.md"
  cat > "$G" <<EOF2
# group lessons

## $OLD (dream sweep)

- **Forgejo runners need the dind sidecar restarted after a node drain.**
  Seen on the 04-21 drain.
- **Flux pauses hide a drifted HelmRelease until resume.** <!-- sig:$OLD flux.*paused -->

## Shell and tooling gotchas

- **$RECENT** **IFS tab read merges empty fields**, use a non-whitespace separator.
- **Grep under pipefail dies of SIGPIPE** when the writer writes again.

## $OLD: One bullet is the body

- the only bullet, which belongs to the section above

## $OLD

A date heading over prose stays one lesson.
EOF2
}

@test "a day-group heading is no lesson; each bullet under it is one, dated by the heading" {
  group_file
  run "$BIN" pick -n 20 "$G"
  assert_line --index 0 "## Lessons (newest 6; nothing matched this work)"
  assert_line --partial "Forgejo runners need the dind sidecar"
  assert_line --partial "Flux pauses hide"
  refute_line --partial "(dream sweep)"
  # Dated by the heading: archive sees both as old, and the sig stays on its bullet.
  covered_log
  mkdir -p "$LESSONS_OUTCOMES_DIR/proj"
  printf '{"updated":"%s","lesson_hits":{"flux.*paused":1}}\n' "$RECENT" > "$LESSONS_OUTCOMES_DIR/proj/$(date +%Y-%m).jsonl"
  run "$BIN" archive --dry-run "$DIR"
  assert_line --regexp "^group [0-9a-f]{8} $OLD \*\*Forgejo runners"
  refute_line --partial "Flux pauses hide"
}

@test "a titled heading stays one lesson over its bullets; a dated bullet in it opens its own" {
  group_file
  run "$BIN" pick -n 20 "$G"
  assert_line "- Shell and tooling gotchas"
  assert_line --partial "IFS tab read merges"
  refute_line --partial "Grep under pipefail"
}

@test "archive moves a day heading with its bullets, and keeps it while any bullet stays" {
  group_file
  covered_log
  mkdir -p "$LESSONS_OUTCOMES_DIR/proj"
  printf '{"updated":"%s","lesson_hits":{"flux.*paused":1}}\n' "$RECENT" > "$LESSONS_OUTCOMES_DIR/proj/$(date +%Y-%m).jsonl"
  run "$BIN" archive "$DIR"
  assert_success
  # Flux is kept by its sig hit, so the heading stays over it and goes with Forgejo too.
  run grep -c "^## $OLD (dream sweep)$" "$G" "$DIR/_archive/group-stale.md"
  assert_output "$G:1
$DIR/_archive/group-stale.md:1"
  run cat "$G"
  assert_output --partial "Flux pauses hide"
  refute_output --partial "Forgejo runners"
  # With Flux stale too, the heading leaves with its last bullet.
  rm "$LESSONS_OUTCOMES_DIR/proj/$(date +%Y-%m).jsonl"
  run "$BIN" archive "$DIR"
  run grep -c "^## $OLD (dream sweep)$" "$G"
  assert_output "0"
}

@test "fat refuses a --max that is not a byte count" {
  group_file
  run "$BIN" fat --max "$G"
  assert_failure 2
  run "$BIN" fat --max 1k "$G"
  assert_failure 2
  assert_output --partial "--max takes a byte count"
}
@test "negative control: a titled heading over one bullet, and a date heading over prose, stay one lesson" {
  group_file
  run "$BIN" pick -n 20 "$G"
  assert_line "- $OLD: One bullet is the body"
  refute_line --partial "the only bullet"
  assert_line "- $OLD"
}

@test "fat lists the lessons over the cap with their line and bytes, and --json counts per file" {
  group_file
  run "$BIN" fat --max 100 "$G"
  assert_success
  assert_output "$G:5	101	**Forgejo runners need the dind sidecar restarted after a node drain.**
$G:11	160	**$RECENT** **IFS tab read merges empty fields**, use a non-whitespace separator."
  run bash -c "\"\$0\" fat --json --max 100 \"\$1\" | jq -c '[.max, .lessons, .over, .over_bytes]'" "$BIN" "$G"
  assert_output "[100,6,2,261]"
  run "$BIN" fat "$G"
  assert_output ""
}

@test "seen lists the lessons the sweep found at least --min times, with the enforced_by marker or a dash" {
  cat > "$F" <<EOF
# proj lessons

- **$RECENT** **Found once.** Why: x.
  <!-- seen:1 $RECENT -->
- **$RECENT** **Found twice, no check.** Why: y.
  <!-- seen:1 $RECENT -->
  <!-- seen:2 $RECENT -->
- **$RECENT** **Found three times, checked.** Why: z.
  <!-- seen:3 $RECENT --> <!-- enforced_by:test:tests/unit/x.bats -->
- **$RECENT** **Never found.** Why: w.
EOF
  run "$BIN" seen --min 2 "$F"
  assert_success
  assert_output "$F:5	2	-	**$RECENT** **Found twice, no check.** Why: y.
$F:8	3	test:tests/unit/x.bats	**$RECENT** **Found three times, checked.** Why: z."
  run bash -c "\"\$0\" seen \"\$1\" | wc -l" "$BIN" "$DIR"
  assert_output 3
  run "$BIN" seen --min x "$F"
  assert_failure 2
}

# group_file with a Forgejo lesson long enough that a short text plus its pointer is smaller.
long_group() {
  group_file
  sed -i "/Seen on the 04-21 drain./a\\  The drain on $OLD left the sidecar wedged for an hour; the runner kept accepting jobs and failed each one at checkout, and nobody saw it until the nightly went red." "$G"
  LESSON_MAX_BYTES=100 "$BIN" compact --dump "$G" "$DIR/c" >/dev/null
  KF=$(basename "$(grep -l Forgejo "$DIR"/c/*.orig)" .orig)
  KI=$(basename "$(grep -l IFS "$DIR"/c/*.orig)" .orig)
}

@test "compact swaps in the short text with a pointer, moves the old text verbatim, keeps the key, and a rerun is a no-op" {
  long_group
  printf -- '- **Forgejo runners need the dind sidecar restarted after a node drain.**\n  Restart it.\n' > "$DIR/c/$KF.md"
  cp "$G" "$DIR/before"
  run "$BIN" compact --dry-run "$G" "$DIR/c"
  assert_success
  assert_output "lessons compact: group: would compact 1"
  cmp "$G" "$DIR/before"
  run "$BIN" compact "$G" "$DIR/c"
  assert_success
  assert_output "lessons compact: group: compacted 1, old text in _archive/group-evidence.md"
  run diff "$DIR/before" "$G"
  assert_output "6,7c6,7
<   Seen on the 04-21 drain.
<   The drain on $OLD left the sidecar wedged for an hour; the runner kept accepting jobs and failed each one at checkout, and nobody saw it until the nightly went red.
---
>   Restart it.
>   Evidence: \`_archive/group-evidence.md\` $KF."
  run cat "$DIR/_archive/group-evidence.md"
  assert_output "
<!-- $KF compacted $(date +%F) -->
$(sed -n 5,7p "$DIR/before")"
  LESSON_MAX_BYTES=0 "$BIN" compact --dump "$G" "$DIR/after" >/dev/null
  [ -f "$DIR/after/$KF.orig" ] || fail "the key moved: $(ls "$DIR/after")"
  run "$BIN" compact "$G" "$DIR/c"
  assert_success
  assert_output "lessons compact: group: compacted 0"
  [ "$(grep -c compacted "$DIR/_archive/group-evidence.md")" = 1 ]
  cp "$DIR/after/$KF.orig" "$DIR/c/$KF.md"
  run "$BIN" compact "$G" "$DIR/c"
  assert_output "lessons compact: group: compacted 0"
}

@test "compact refuses a text that changes the key, drops the date, is not shorter, stays over the cap or names no lesson" {
  long_group
  printf -- '- **Forgejo runners: restart the dind sidecar after a drain.**\n' > "$DIR/c/$KF.md"
  printf -- '- **%s** **IFS tab read merges empty fields**, use a non-whitespace separator.\n  Use a non-whitespace separator, always, in every read loop.\n' "$RECENT" > "$DIR/c/$KI.md"
  printf -- '- nothing\n' > "$DIR/c/00000000.md"
  run "$BIN" compact "$G" "$DIR/c"
  assert_failure 1
  assert_line "refused 00000000: no lesson with that key"
  assert_line --regexp "^refused $KI: not shorter than the lesson \([0-9]+ >= [0-9]+ bytes\)$"
  assert_line "refused $KF: the first 160 chars of the first line changed (the key)"
  assert_line "lessons compact: group: compacted 0"
  printf -- '- **Forgejo runners need the dind sidecar restarted after a node drain.**\n  Restart it, see %s.\n' "$(printf 'x%.0s' {1..60})" > "$DIR/c/$KF.md"
  rm "$DIR/c/$KI.md" "$DIR/c/00000000.md"
  LESSON_MAX_BYTES=150 run "$BIN" compact "$G" "$DIR/c"
  assert_output --regexp "^refused $KF: [0-9]+ bytes with the pointer, over 150"
}

@test "compact refuses a text whose first line drops the lesson's date" {
  group_file
  sed -i "s/separator\.\$/separator. $(printf 'Long tail. %.0s' {1..20})/" "$G"
  LESSON_MAX_BYTES=100 "$BIN" compact --dump "$G" "$DIR/c" >/dev/null
  k=$(basename "$(grep -l IFS "$DIR"/c/*.orig)" .orig)
  head -c 300 "$DIR/c/$k.orig" | sed "s/\*\*$RECENT\*\* //" > "$DIR/c/$k.md"
  run "$BIN" compact "$G" "$DIR/c"
  assert_failure 1
  assert_line --partial "refused $k: the first"
}

@test "compact refuses a text line that would open a lesson, and writes nothing" {
  long_group
  printf -- '- **Forgejo runners need the dind sidecar restarted after a node drain.**\n# a heading\n' > "$DIR/c/$KF.md"
  cp "$G" "$DIR/before"
  run "$BIN" compact "$G" "$DIR/c"
  assert_failure 1
  assert_line "refused $KF: line 2 would open a lesson or section; indent it"
  cmp "$G" "$DIR/before"
  [ ! -e "$DIR/_archive/group-evidence.md" ]
}

@test "compact refuses a text that drops a marker the old lesson carried" {
  group_file
  LESSON_MAX_BYTES=0 "$BIN" compact --dump "$G" "$DIR/c" >/dev/null
  k=$(basename "$(grep -l Flux "$DIR"/c/*.orig)" .orig)
  printf -- '- **Flux pauses hide a drifted HelmRelease until resume.**\n' > "$DIR/c/$k.md"
  run "$BIN" compact "$G" "$DIR/c"
  assert_failure 1
  assert_line "refused $k: it drops the marker <!-- sig:$OLD flux.*paused -->"
}

@test "under a titled heading, a bracketed-date bullet and a bullet whose bold title ends in a dated parenthetical open lessons" {
  F="$DIR/dated.md"
  cat > "$F" <<EOF2
# dated bullets

## Shell gotchas

- **[$RECENT dream, Lane A] Bracketed dream bullets are lessons.** Body.
- **Parenthetical dream bullets are lessons ($RECENT, dream sweep).** Body.
- **Corrected $RECENT:** a sub-point that stays body.
- **Supporting facts, all measured $RECENT, stay body.**
- **Fix (see $RECENT)**: a parenthetical before a colon stays body.
- **Observed ($RECENT)**: a dated title with no period stays body.
- [$RECENT 14:00] a bracketed timestamp with no bold stays body.
EOF2
  run "$BIN" pick -n 20 "$F"
  assert_line "- Shell gotchas"
  assert_line --partial "[$RECENT dream, Lane A] Bracketed dream bullets"
  assert_line --partial "Parenthetical dream bullets are lessons ($RECENT"
  refute_line --partial "Corrected $RECENT"
  refute_line --partial "Supporting facts"
  refute_line --partial "a parenthetical before a colon"
  refute_line --partial "a dated title with no period"
  refute_line --partial "a bracketed timestamp"
  run bash -c "\"\$0\" fat --json --max 0 \"\$1\" | jq .lessons" "$BIN" "$F"
  assert_output "3"
}

@test "pick does not cut at a short title sentence: a word cut with an ellipsis instead" {
  printf -- '- **%s** **A short title.** %s\n' "$RECENT" "$(printf 'no stop here %.0s' $(seq 1 40))" >> "$F"
  run "$BIN" pick -n 1 "$F"
  line="${lines[1]}"
  [[ $line == *"..." ]]
  [[ $line == *"no stop here"* ]]
}
