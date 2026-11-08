#!/usr/bin/env bats
# .config/fleet-lead/functions.tsv is the one routing table: function -> skill -> due-line prefixes ->
# section. This guard fails when (a) a row names a skill that does not exist or a section that is not a
# heading in it, (b) a monitoring/fleet-* skill has no row, (c) a due line fleet-shepherd emits matches no
# explicit prefix (checked with the default row removed) or reaches the wrong skill, or (d) the invoked
# column disagrees with the prefixes column. Each check takes the table as an argument, so the negative controls run it on a broken copy.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TABLE="$REPO_ROOT/.config/fleet-lead/functions.tsv"
  SH="$REPO_ROOT/.local/bin/fleet-shepherd"
  export FLEET_SHEPHERD_SERVER=hub   # else the script asks tmux-world, which a unit test does not have
  # One sample of every due-line shape fleet-shepherd emits, and the skill it must reach.
  EMITTED=$'shepherd\tnudge DONE: s/a:1 f
shepherd\tnudge SHARED: t is owned by queue item x
shepherd\tnudge CHAT: s/a:1 f
shepherd\tescalate NEEDS: s/a:1 r
shepherd\toverdue: a, phase 2 is 40m past its ETA
shepherd\tescalate overdue: a, nudged and not moved
shepherd\tnightly red: repo (r)
shepherd\tshared red: t; then: fleet-sessions escalate id "f"
fleet-pace\tpace: hold unity while the machine reads CLEAR
fleet-pace\tpace: machine reads HOLD with no hold set
fleet-pace\tlimit: s/a:1 idle on acct, out of usage
fleet-pace\tblocked: pid 1 d, 3 threads on I/O
fleet-dispatch\twatch: queue-starved tripped (high)
fleet-lead\tfinding x; then: fleet-sessions escalate id "k"
fleet-lead\timprove: kpi past bound 1, no live row
fleet-lead\tinfra: k3s domain red
fleet-lead\twatch: home-k3s-node-disk tripped (urgent)'
}

# skill_file <skill> -> its SKILL.md in this repo, empty when none. The fleet family lives here, so CI
# and a laptop with the private overlay agree.
skill_file() { ls "$REPO_ROOT"/.claude/skills/*/"$1"/SKILL.md 2>/dev/null | head -n 1; }

# rows <table> -> function, skill, section, one per line, split by \037
rows() { awk -F'\t' '!/^#/ && NF { print $1 "\037" $2 "\037" $4 }' "$1"; }

check_rows() { # <table>
  local fn skill section f bad=0
  while IFS=$'\037' read -r fn skill section; do
    f="$(skill_file "$skill")"
    [ -n "$f" ] || { echo "$fn: no skill $skill"; bad=1; continue; }
    grep -E '^#+ ' "$f" | tr -d '`' | grep -qE "^#+ ${section}" || { echo "$fn: no heading '$section' in $skill"; bad=1; }
  done < <(rows "$1")
  return "$bad"
}

check_family() { # <table>: every monitoring/fleet-* skill has a row
  local d bad=0 name
  for d in "$REPO_ROOT"/.claude/skills/monitoring/fleet-*/; do
    name="$(basename "$d")"
    cut -f2 "$1" | grep -qxF "$name" || { echo "no row for $name"; bad=1; }
  done
  return "$bad"
}

# routed <table> <line> -> the skill the script sends the line to
routed() { FLEET_LEAD_FUNCTIONS="$1" "$SH" route "$2" | cut -f1; }

check_invoked() { # <table>: "due line" exactly when the row has prefixes
  local fn prefixes invoked bad=0
  while IFS=$'\037' read -r fn prefixes invoked; do
    if [ -n "$prefixes" ]; then want="due line"; else want="by name"; fi
    [ "$invoked" = "$want" ] || { echo "$fn: invoked is '$invoked', want '$want'"; bad=1; }
  done < <(awk -F'\t' '!/^#/ && NF { print $1 "\037" $3 "\037" $5 }' "$1")
  return "$bad"
}

check_emitted() { # <table>: with the default row removed, so a line must match an explicit prefix
  local skill line bad=0 got t="$BATS_TEST_TMPDIR/explicit.tsv"
  sed 's/|\*\t/\t/' "$1" > "$t"
  set -- "$t"
  while IFS=$'\t' read -r skill line; do
    got="$(routed "$1" "$line")"
    [ "$got" = "$skill" ] || { echo "'$line' -> '$got', want $skill"; bad=1; }
  done <<< "$EMITTED"
  return "$bad"
}

@test "every row names a real skill and a heading in it" {
  run check_rows "$TABLE"
  assert_success
}

@test "every monitoring/fleet-* skill has a row" {
  run check_family "$TABLE"
  assert_success
}

@test "the invoked column agrees with the prefixes column" {
  run check_invoked "$TABLE"
  assert_success
}

@test "every due-line shape fleet-shepherd emits routes to its skill" {
  run check_emitted "$TABLE"
  assert_success
}

@test "every emitted shape is still in fleet-shepherd" {
  local skill line head bad=0
  while IFS=$'\t' read -r skill line; do
    head="${line%% *}"
    grep -qF -- "$head" "$SH" || { echo "fleet-shepherd no longer emits '$head'"; bad=1; }
  done <<< "$EMITTED"
  [ "$bad" = 0 ]
}

@test "a queue-starved watch beats the lead's other watch lines, and an unhandled lead is ignored" {
  run routed "$TABLE" 'unhandled: watch: queue-starved tripped (high)'
  assert_output fleet-dispatch
  run routed "$TABLE" 'unhandled: nudge DONE: s/a:1 f'
  assert_output shepherd
}

@test "an invented prefix lands on the lead's default row" {
  run routed "$TABLE" 'invented: something new'
  assert_output fleet-lead
}

@test "negative control: a deleted row fails the family and emitted checks" {
  local t="$BATS_TEST_TMPDIR/t.tsv"
  grep -v $'\tfleet-queue\t' "$TABLE" > "$t"
  run check_family "$t"
  assert_failure
  assert_output --partial 'no row for fleet-queue'
  grep -v $'\tfleet-pace\t' "$TABLE" > "$t"
  run check_emitted "$t"
  assert_failure
  assert_output --partial 'want fleet-pace'
  # a due line that only the default row would catch fails, even though the default is the right skill
  sed 's/finding|infra:|watch:|improve:/finding|infra:|improve:/' "$TABLE" > "$t"
  run check_emitted "$t"
  assert_failure
  assert_output --partial 'watch: home-k3s-node-disk'
  sed 's/\tby name$/\tdue line/' "$TABLE" > "$t"
  run check_invoked "$t"
  assert_failure
}

@test "a prefix ends at a word boundary" {
  run routed "$TABLE" 'nudged x'
  assert_output fleet-lead
  run routed "$TABLE" 'watch: queue-starved-foo tripped (high)'
  assert_output fleet-lead
}

@test "negative control: a missing heading or skill fails the row check" {
  local t="$BATS_TEST_TMPDIR/t.tsv"
  sed 's/Pace check/No such heading/' "$TABLE" > "$t"
  run check_rows "$t"
  assert_failure
  assert_output --partial "no heading 'No such heading' in fleet-pace"
  sed 's/\tshepherd\t/\tno-such-skill\t/' "$TABLE" > "$t"
  run check_rows "$t"
  assert_failure
  assert_output --partial 'no skill no-such-skill'
}

@test "a missing table fails loudly, with no built-in copy" {
  FLEET_LEAD_FUNCTIONS="$BATS_TEST_TMPDIR/absent.tsv" run "$SH" route 'nudge DONE: x'
  assert_failure
  assert_output --partial 'no routing table'
  # and every verb that routes refuses up front, not with an empty role column
  FLEET_LEAD_FUNCTIONS="$BATS_TEST_TMPDIR/absent.tsv" run "$SH" check
  assert_failure 2
  assert_output --partial 'no routing table'
  grep -v '|\*' "$TABLE" > "$BATS_TEST_TMPDIR/nodefault.tsv"
  FLEET_LEAD_FUNCTIONS="$BATS_TEST_TMPDIR/nodefault.tsv" run "$SH" check
  assert_failure 2
  assert_output --partial 'no default'
}

@test "with no override the script reads the table in its own checkout" {
  run "$SH" route 'pace: hold unity while the machine reads CLEAR'
  assert_output "$(printf 'fleet-pace\tPace check')"
}
