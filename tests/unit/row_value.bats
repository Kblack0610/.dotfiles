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
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-20","priority":"high","parent":"ar-2","prio_why":"fault","since":"2026-11-20","text":"fix(dispatch): lost item","tags":["of/ar-2"],"details":["seen twice","see docs/plans/index.md"],"requested":true},
 {"project":"agent-runtime","lane":"agent","state":"doing","id":"ar-3","priority":"normal","parent":"ar-1","prio_why":null,"since":"2026-11-21","text":"feat(bench): a KPI","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-10","priority":"low","parent":"ar-3","prio_why":"upkeep","since":"2026-11-22","text":"chore(notes): tidy","tags":["after/ar-3"],"details":["Phase 2 of the plan /h/.agent/plans/_live/tidy-plan.md: tidy"]},
 {"project":"agent-runtime","lane":"agent","state":"done","id":"ar-4","text":"done row","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"human","state":"open","id":"ar-5","parent":"ar-3","text":"human row","tags":[],"details":[]},
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

# id target ref kind verdict into bucket system project evidence why
judge() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

# The three rows judged so merge passes: ar-3 is ar-10's parent, ar-20 checked fixed at HEAD.
judge_ok() {
  {
    judge ar-3 kpi buzzes_per_day work keep - container telemetry agent-runtime - "live item"
    judge ar-10 none - polish park - improvement notes trader - "tidy only"
  } >"$D/judge-01.tsv"
  judge ar-20 red "lost item" work keep - fault dispatch agent-runtime - "lost item" >"$D/judge-02.tsv"
  printf 'ar-20\tfixed\tabc123 dispatch.py:40\tgone at HEAD\n' >"$D/check-01.tsv"
}

@test "export: only the project's open and doing agent rows, sorted by epic, in chunks" {
  export_fixture
  assert_output --partial "3 rows in 2 chunks"
  run cut -f1 "$D/rows.tsv"
  assert_output "$(printf 'id\nar-3\nar-20\nar-10')"
  run cat "$D/chunk-01.txt"
  assert_output --partial "ar-3 [doing] normal epic:ar-1"
  assert_output --partial "plan:- after:- children:2"
  assert_output --partial "fix(dispatch): lost item #of/ar-2 #requested"
  assert_output --partial "  | seen twice"
  refute_output --partial "ar-10"
  run cat "$D/chunk-02.txt"
  assert_output --partial "ar-10 [open] low epic:ar-3 why:upkeep since:2026-11-22 plan:tidy-plan after:ar-3 children:0"
  run awk -F'\t' '$1 == "ar-20" { print $6 }' "$D/rows.tsv"
  assert_output yes
  # ar-3's children count its human-lane child ar-5; a repo docs/plans/ path is no plan.
  run awk -F'\t' '$1 != "id" { print $1, $8, $9, $10, $11 }' "$D/rows.tsv"
  assert_output "$(printf 'ar-3 - - 2 1\nar-20 - - 0 0\nar-10 tidy-plan ar-3 0 0')"
}

@test "export: --inflow gives each row its source from fleet-bench inflow --json, - when unnamed" {
  printf '%s' '{"project":"agent-runtime","sources":[{"source":"from: dream","open_ids":["ar-3","ar-10"]},{"source":"pre-log","open_ids":[]}]}' > "$HOME/inflow.json"
  run "$RV" export --board "$HOME/board.json" --scorecard "$HOME/latest.md" --reds-cmd "" --inflow "$HOME/inflow.json" --chunk 2 "$D"
  assert_success
  run awk -F'\t' '{ print $1, $12 }' "$D/rows.tsv"
  assert_output "$(printf 'id source\nar-3 from: dream\nar-20 -\nar-10 from: dream')"
  run cat "$D/chunk-02.txt"
  assert_output --partial "children:0 source:from: dream"
  printf '%s' '{"project":"game","sources":[]}' > "$HOME/inflow.json"
  run "$RV" export --board "$HOME/board.json" --scorecard "$HOME/latest.md" --reds-cmd "" --inflow "$HOME/inflow.json" "$D"
  assert_failure 1
  assert_output --partial "is for 'game', not agent-runtime"
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
    judge ar-3 kpi buzzes_per_day work keep - container telemetry agent-runtime - "live item"
    judge ar-10 none - polish park - improvement notes agent-runtime - "tidy only"
  } >"$D/judge-01.tsv"
  judge ar-20 red "lost item" work merge ar-3 drop dispatch agent-runtime - "same cause" >"$D/judge-02.tsv"
  run "$RV" merge "$D"
  assert_success
  assert_output --partial "3 rows judged"
  assert_output --partial "verdict: keep 1, park 1, merge 1"
  assert_output --partial "bucket: container 1, improvement 1, drop 1"
  run head -1 "$D/verdicts.tsv"
  assert_output "$(printf 'id\ttarget\tref\tkind\tverdict\tinto\tbucket\tsystem\tproject\tevidence\twhy')"
  export_fixture
  [ ! -e "$D/judge-01.tsv" ] && [ ! -e "$D/verdicts.tsv" ]
}

@test "merge: a check line replaces a fault row's bucket, evidence and why; a fault with none fails" {
  export_fixture
  judge_ok
  run "$RV" merge "$D"
  assert_success
  run awk -F'\t' '$1 == "ar-20" { print $7 "|" $10 "|" $11 }' "$D/verdicts.tsv"
  assert_output "fixed|abc123 dispatch.py:40|gone at HEAD"
  rm "$D/check-01.tsv"
  run "$RV" merge "$D"
  assert_failure 1
  assert_output --partial "ar-20 is fault with no evidence"
  printf 'ar-99\tfault\tx\ty\nar-3\tchain\tx\ty\nar-20\tfault\ta.py:1\tthere\nar-20\tfixed\tb\tz\nar-10\tfault\nar-10\tfixed\tc\tw\n' >"$D/check-01.tsv"
  run "$RV" merge "$D"
  assert_failure 1
  assert_output --partial "ar-99 is not a judged row"
  assert_output --partial "a HEAD check says fault or fixed, not 'chain'"
  assert_output --partial "ar-20 checked twice"
  assert_output --partial "check-01.tsv:5: 2 fields, want 4"
  assert_output --partial "ar-10 is improvement, not a fault row to check"
  [ ! -e "$D/verdicts.tsv" ]
}

@test "merge: a bucket fits its verdict and the row: container is a parent, chain has #after/, red a ref" {
  export_fixture
  {
    judge ar-3 kpi - work keep - sot telemetry agent-runtime a.py:1 x
    judge ar-10 none - polish keep - improvement notes 'Trader!' - y
  } >"$D/judge-01.tsv"
  judge ar-20 red - work keep - chain dispatch agent-runtime - z >"$D/judge-02.tsv"
  run "$RV" merge "$D"
  assert_failure 1
  assert_output --partial "ar-3 has 2 open children, so container, not sot"
  assert_output --partial "ar-3 is sot, so evidence is -, not 'a.py:1'"
  assert_output --partial "bucket improvement takes verdict park, not keep"
  assert_output --partial "project 'Trader!' is not a project name"
  assert_output --partial "ar-20 is chain with no #after/ tag"
  judge ar-20 red - work keep - container dispatch agent-runtime - z >"$D/judge-02.tsv"
  run "$RV" merge "$D"
  assert_output --partial "ar-20 has 0 open children, so not container"
  {
    judge ar-3 kpi - work drop - container telemetry agent-runtime - x
    judge ar-10 none - polish drop - drop notes agent-runtime - y
  } >"$D/judge-01.tsv"
  judge ar-20 red - work keep - red dispatch agent-runtime - z >"$D/judge-02.tsv"
  run "$RV" merge "$D"
  assert_output --partial "ar-20 is red with no ref naming the red"
  # Its exported child ar-10 drops, but its human-lane child ar-5 stays.
  assert_output --partial "ar-3 drops with open children that stay"
  [ ! -e "$D/verdicts.tsv" ]
}

@test "report: counts per bucket, system and epic, then every row with its tie and evidence" {
  export_fixture
  run "$RV" report "$D"
  assert_failure 1
  assert_output --partial "verdicts.tsv missing"
  printf 'id\ttarget\tref\tkind\tverdict\tinto\twhy\n' >"$D/verdicts.tsv"
  run "$RV" report "$D"
  assert_failure 1
  assert_output --partial "lacks bucket, system, project, evidence: run row-value merge again"
  judge_ok
  run "$RV" merge "$D"
  assert_success
  run "$RV" report --tsv "$HOME/ledger.tsv" "$D"
  assert_success
  assert_output --partial "# Row ledger, 3 open agent-runtime rows"
  assert_output --partial "Misfiled (served project is not agent-runtime): 1."
  assert_output --partial "| dispatch | 1 |"
  assert_output --partial "| ar-20 | fixed | keep | epic:ar-2 | abc123 dispatch.py:40 |"
  assert_output --partial "| ar-10 | improvement | park | epic:ar-3 plan:tidy-plan move:trader | - |"
  run awk -F'\t' '$1 == "ar-10" { print $NF }' "$HOME/ledger.tsv"
  assert_output "epic:ar-3 plan:tidy-plan move:trader"
}

@test "merge: the rubric's bounds hold: doing is keep, requested never drop or park, merge only into a kept row" {
  export_fixture
  {
    judge ar-3 none - polish park - container views agent-runtime - "tidy"
    judge ar-10 none - dup merge ar-20 drop notes agent-runtime - "same"
    judge ar-20 red - superseded drop - drop dispatch agent-runtime - "done"
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
    judge ar-3 kpi - work keep - container other agent-runtime - ok
    judge ar-3 kpi - work keep - container other agent-runtime - again
    judge ar-10 vibes - work toss - drop other agent-runtime - bad
    judge ar-99 none - work drop - drop other agent-runtime - unknown
  } >"$D/judge-01.tsv"
  run "$RV" merge "$D"
  assert_failure 1
  assert_output --partial "ar-3 judged twice"
  assert_output --partial "target 'vibes' is not in the rubric's list"
  assert_output --partial "verdict 'toss' is not in the rubric's list"
  assert_output --partial "ar-99 is not an exported row"
  assert_output --partial "1 rows not judged: ar-20"
  [ ! -e "$D/verdicts.tsv" ]
  judge ar-20 red - work merge ar-20 drop other agent-runtime - self >"$D/judge-02.tsv"
  run "$RV" merge "$D"
  assert_output --partial "merge into 'ar-20', not another exported row"
}

@test "merge: the lists come from the rubric file" {
  export_fixture
  printf '%s\n' 'target: none' 'kind: work' 'verdict: keep' 'bucket: container sot' 'system: other' >"$HOME/rubric.md"
  {
    judge ar-3 none - work keep - container other agent-runtime - a
    judge ar-10 none - work keep - sot other agent-runtime - b
    judge ar-20 none - work keep - sot other agent-runtime - c
  } >"$D/judge-01.tsv"
  run "$RV" merge --rubric "$HOME/rubric.md" "$D"
  assert_success
  printf 'kind: work\n' >"$HOME/rubric.md"
  run "$RV" merge --rubric "$HOME/rubric.md" "$D"
  assert_failure 1
  assert_output --partial "no list line for bucket, system, target, verdict"
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
