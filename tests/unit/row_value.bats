#!/usr/bin/env bats
# row-value: export a board's open agent rows for the value judges, check and merge their
# verdicts against the rubric's lists and rules, compare two judges. Fixtures are files: a saved board
# JSON, a scorecard and a stub reds command; no judge runs and notes is never called.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  RV="$REPO_ROOT/.local/bin/row-value"
  D="$HOME/rv"
  cat >"$HOME/board.json" <<'EOF'
{"today":"2026-11-24","rows":[
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-20","priority":"high","parent":"ar-2","prio_why":"fault","since":"2026-11-20","text":"fix(dispatch): lost item","tags":["of/ar-2"],"details":["seen twice"],"requested":true},
 {"project":"agent-runtime","lane":"agent","state":"doing","id":"ar-3","priority":"normal","parent":"ar-1","prio_why":null,"since":"2026-11-21","text":"feat(bench): a KPI","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-10","priority":"low","parent":"ar-1","prio_why":"upkeep","since":"2026-11-22","text":"chore(notes): tidy","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"done","id":"ar-4","text":"done row","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"human","state":"open","id":"ar-5","text":"human row","tags":[],"details":[]},
 {"project":"other","lane":"agent","state":"open","id":"ot-1","text":"other board","tags":[],"details":[]}
]}
EOF
  # Two tables of the scorecard's shape: vitals lead with a question column, KPIs with the name.
  printf '%s\n' '| Question | KPI | 7d | 28d | threshold | status |' '|---|---|---|---|---|---|' \
    '| you | buzzes_per_day | 20.0 | 5.0 | max 15 | past |' '' \
    '| KPI | 7d | 28d | threshold | status |' '|---|---|---|---|---|' \
    '| ci_red_per_pr | 0.569 | 0.594 | max 0.5 | past |' '| revert_rate | 0.004 | 0.004 | max 0.05 | ok |' \
    '' '| Mode | Status | Pass | Fail | past |' '| nightly | ok | 3 | 0 | past |' >"$HOME/latest.md"
  printf '%s\n' '#!/bin/sh' "echo '| ar-9 | watch chain-lag | still red | x |'" \
    "echo '| ar-9 | watch chain-lag | came back | x |'" "echo '| ar-8 | watch old | fixed | x |'" >"$HOME/reds"
  chmod +x "$HOME/reds"
}

export_fixture() {
  # --reds-cmd is a shell string and the sandbox HOME holds a space, so the path is quoted for sh.
  run "$RV" export --board "$HOME/board.json" --scorecard "$HOME/latest.md" --reds-cmd "$(printf %q "$HOME/reds")" --chunk 2 "$D"
  assert_success
}

judge() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

@test "export: only the project's open and doing agent rows, sorted by epic, in chunks" {
  export_fixture
  assert_output --partial "3 rows in 2 chunks"
  run cut -f1 "$D/rows.tsv"
  assert_output "$(printf 'id\nar-3\nar-10\nar-20')"
  run cat "$D/chunk-01.txt"
  assert_output --partial "ar-3 [doing] normal epic:ar-1"
  refute_output --partial "ar-20"
  run cat "$D/chunk-02.txt"
  assert_output --partial "fix(dispatch): lost item #of/ar-2 #requested"
  assert_output --partial "  | seen twice"
  run awk -F'\t' '$1 == "ar-20" { print $6 }' "$D/rows.tsv"
  assert_output yes
}

@test "export: the context names the KPIs past threshold and each live red once" {
  export_fixture
  run cat "$D/context.md"
  assert_output --partial "- buzzes_per_day 20.0 (max 15)"
  assert_output --partial "- ci_red_per_pr 0.569 (max 0.5)"
  refute_output --partial "revert_rate"
  refute_output --partial "nightly"
  assert_output --partial "- ar-9 watch chain-lag (still red)"
  refute_output --partial "came back"
  refute_output --partial "ar-8"
}

@test "export: --repo puts each origin/main commit that names a row under that row, and only there" {
  git init -q --bare "$HOME/origin.git"
  git clone -q "$HOME/origin.git" "$HOME/w" 2>/dev/null
  git -C "$HOME/w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix(dispatch): lost item found (ar-20) (#7)"
  git -C "$HOME/w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "docs: unrelated ar-200 note"
  git -C "$HOME/w" push -q origin HEAD:main
  git -C "$HOME/w" fetch -q origin
  run "$RV" export --board "$HOME/board.json" --scorecard "$HOME/latest.md" --reds-cmd "" --repo "$HOME/w" --chunk 5 "$D"
  assert_success
  run grep -A3 '^ar-20 ' "$D/chunk-01.txt"
  assert_output --partial "  merged: w "
  assert_output --partial "lost item found (ar-20) (#7)"
  run grep -c '  merged:' "$D/chunk-01.txt"
  assert_output 1
  run "$RV" export --board "$HOME/board.json" --scorecard "" --reds-cmd "" --repo "$HOME/nope" "$D"
  assert_failure 1
  assert_output --partial "git fetch in $HOME/nope failed"
}

@test "export: a missing scorecard or a failed reds command fails instead of an empty context" {
  run "$RV" export --board "$HOME/board.json" --reds-cmd "" "$D"
  assert_failure 1
  assert_output --partial "no scorecard at $HOME/.notes/lab/projects/current/agent-runtime/docs/bench/latest.md"
  run "$RV" export --board "$HOME/board.json" --project other --reds-cmd "" "$D"
  assert_failure 1
  assert_output --partial "projects/current/other/docs/bench/latest.md"
  run "$RV" export --board "$HOME/board.json" --scorecard "$HOME/latest.md" --reds-cmd false "$D"
  assert_failure 1
  assert_output --partial "reds-cmd 'false' failed (1)"
  [ ! -e "$D/context.md" ]
  run "$RV" export --board "$HOME/board.json" --scorecard "" --reds-cmd "" "$D"
  assert_success
  run cat "$D/context.md"
  assert_output --partial "(not read: --scorecard '')"
  assert_output --partial "(not read: --reds-cmd '')"
}

@test "merge: every row judged once in the rubric's words writes verdicts.tsv and counts" {
  export_fixture
  {
    judge ar-3 kpi buzzes_per_day work keep - "live item"
    judge ar-10 none - polish park - "tidy only"
  } >"$D/judge-01.tsv"
  judge ar-20 red "lost item" work merge ar-3 "same cause" >"$D/judge-02.tsv"
  run "$RV" merge "$D"
  assert_success
  assert_output --partial "3 rows judged"
  assert_output --partial "verdict: keep 1, park 1, merge 1"
  run head -1 "$D/verdicts.tsv"
  assert_output "$(printf 'id\ttarget\tref\tkind\tverdict\tinto\twhy')"
  export_fixture
  [ ! -e "$D/judge-01.tsv" ] && [ ! -e "$D/verdicts.tsv" ]
}

@test "merge: the rubric's bounds hold: doing is keep, requested never drop or park, merge only into a kept row" {
  export_fixture
  {
    judge ar-3 none - polish park - "tidy"
    judge ar-10 none - dup merge ar-20 "same"
    judge ar-20 red - superseded drop - "done"
  } >"$D/judge-01.tsv"
  run "$RV" merge "$D"
  assert_failure 1
  assert_output --partial "ar-3 is doing (a live queue item), so keep, not park"
  assert_output --partial "ar-20 was requested by the human, so never drop"
  assert_output --partial "ar-10 merges into ar-20, which is drop, not keep"
  [ ! -e "$D/verdicts.tsv" ]
}

@test "merge: a missing row, a twice-judged row, a word outside the lists or a bad merge fails and writes nothing" {
  export_fixture
  {
    judge ar-3 kpi - work keep - ok
    judge ar-3 kpi - work keep - again
    judge ar-10 vibes - work toss - bad
    judge ar-99 none - work drop - unknown
  } >"$D/judge-01.tsv"
  run "$RV" merge "$D"
  assert_failure 1
  assert_output --partial "ar-3 judged twice"
  assert_output --partial "target 'vibes' is not in the rubric's list"
  assert_output --partial "verdict 'toss' is not in the rubric's list"
  assert_output --partial "ar-99 is not an exported row"
  assert_output --partial "1 rows not judged: ar-20"
  [ ! -e "$D/verdicts.tsv" ]
  judge ar-20 red - work merge ar-20 self >"$D/judge-02.tsv"
  run "$RV" merge "$D"
  assert_output --partial "merge into 'ar-20', not another exported row"
}

@test "merge: the lists come from the rubric file" {
  export_fixture
  printf '%s\n' 'target: none' 'kind: work' 'verdict: keep' >"$HOME/rubric.md"
  { judge ar-3 none - work keep - a; judge ar-10 none - work keep - b; judge ar-20 none - work keep - c; } >"$D/judge-01.tsv"
  run "$RV" merge --rubric "$HOME/rubric.md" "$D"
  assert_success
  printf 'kind: work\n' >"$HOME/rubric.md"
  run "$RV" merge --rubric "$HOME/rubric.md" "$D"
  assert_failure 1
  assert_output --partial "no list line for target, verdict"
}

@test "compare: agreement, kappa, confusion and each disagreement, with other column names and words" {
  printf 'id\tverdict\nar-1\tkeep\nar-2\tdrop\nar-3\tpark\nar-4\tkeep\n' >"$HOME/mine.tsv"
  printf 'row\tact\nar-1\tKEEP\nar-2\tremove\nar-3\tkeep\nar-5\tkeep\n' >"$HOME/theirs.tsv"
  run "$RV" compare --id row --verdict act --map remove=drop "$HOME/mine.tsv" "$HOME/theirs.tsv"
  assert_success
  assert_output --partial "mine 4, theirs 4, both 3, only mine 1, only theirs 1"
  assert_output --partial "agree 2/3 (66.7%)"
  assert_output --partial "$(printf 'ar-3\tpark\tkeep')"
  refute_output --partial "$(printf 'ar-1\tkeep')"
  printf 'id\tverdict\tkind\nar-1\tkeep\twork\nar-2\tdrop\tdup\n' >"$HOME/mine.tsv"
  printf 'id\tlabel\nar-1\twork\nar-2\tstale\n' >"$HOME/theirs.tsv"
  run "$RV" compare --mine-verdict kind --verdict label "$HOME/mine.tsv" "$HOME/theirs.tsv"
  assert_success
  assert_output --partial "agree 1/2 (50.0%)"
  assert_output --partial "$(printf 'ar-2\tdup\tstale')"
  run "$RV" compare --id nope "$HOME/mine.tsv" "$HOME/theirs.tsv"
  assert_failure 1
  assert_output --partial "no column 'nope'"
}
