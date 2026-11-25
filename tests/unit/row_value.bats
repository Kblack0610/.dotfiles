#!/usr/bin/env bats
# row-value: export a board's open agent rows for the value judges, check and merge their
# verdicts against the rubric's lists and rules, compare two judges, apply the cut. Fixtures are
# files: a saved board JSON, a scorecard and a stub reds command; no judge runs, and the notes
# that apply calls is a stub that logs its arguments.

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
  assert_output --partial "1 rows are not in $HOME/inflow.json (not open on the board it was computed from)"
  run awk -F'\t' '{ print $1, $12 }' "$D/rows.tsv"
  assert_output "$(printf 'id source\nar-3 from: dream\nar-20 -\nar-10 from: dream')"
  printf '%s' '{"project":"game","sources":[]}' > "$HOME/inflow.json"
  run "$RV" export --board "$HOME/board.json" --scorecard "$HOME/latest.md" --reds-cmd "" --inflow "$HOME/inflow.json" "$D"
  assert_failure 1
  assert_output --partial "is for 'game', not agent-runtime"
  # an inflow saved before open_ids existed fails, so a stale file cannot leave every source -
  printf '%s' '{"project":"agent-runtime","sources":[{"source":"pre-log","open":3}]}' > "$HOME/inflow.json"
  run "$RV" export --board "$HOME/board.json" --scorecard "$HOME/latest.md" --reds-cmd "" --inflow "$HOME/inflow.json" "$D"
  assert_failure 1
  assert_output --partial "has no open_ids"
  : > "$HOME/inflow.json"
  run "$RV" export --board "$HOME/board.json" --scorecard "$HOME/latest.md" --reds-cmd "" --inflow "$HOME/inflow.json" "$D"
  assert_failure 1
  assert_output --partial "row-value: --inflow $HOME/inflow.json:"
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
  run grep -A4 '^ar-20 ' "$D/chunk-01.txt"
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
  assert_output --partial "## Per source"
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

# apply and cut-report: a stub notes logs each call; agent-runtime and trader have a board, pad none.
apply_fixture() {
  mkdir -p "$HOME/bin" "$HOME/plans/_live"
  cat >"$HOME/bin/notes" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$HOME/calls"
case "$*" in
  "ptask agent-runtime --agent list"|"ptask trader --agent list"|"ptask agent-runtime list"|"ptask trader list") exit 0 ;;
  "ptask "*" list") exit 1 ;;
  "improve --check"*health*) exit 3 ;;
  "improve --check"*) exit 0 ;;
  *"drop ar-37 "*) echo "refused: open children" >&2; exit 1 ;;
  *"drop ar-33 "*) if [ -e "$HOME/refuse33" ]; then echo "refused: locked" >&2; exit 1; fi ;;
esac
EOF
  chmod +x "$HOME/bin/notes"
  NOTES="$HOME/bin/notes"
  cat >"$HOME/board2.json" <<'EOF'
{"today":"2026-11-25","rows":[
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-30","text":"fix(x): gone at head #size/s","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-31","text":"fix(x): a dup","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-32","text":"fix(x): the kept one","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-33","text":"feat(views): a nicer tile #pts/3","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-34","text":"feat(views): health shaped","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-35","text":"fix(trader): a trader fault","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-36","text":"check(watch): a red for the playground","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"doing","id":"ar-37","text":"fix(x): live item","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-38","text":"feat(dispatch): Live plan (plan live-plan)","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-39","text":"feat(dispatch): Orphan plan (plan orphan-plan)","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-40","text":"feat(dispatch): Done plan (plan done-plan)","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-41","text":"chore(x): new since the ledger","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-42","text":"fix(x): pad fault","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-43","text":"chore(x): a check","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"done","id":"ar-44","text":"closed already","tags":[],"details":[]}
]}
EOF
  # id state epic plan after children source bucket system project target ref kind verdict into evidence why text tie
  led() { printf '%s\topen\t-\t-\t-\t0\t-\t%s\t%s\t%s\tnone\t-\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$@"; }
  {
    printf 'id\tstate\tepic\tplan\tafter\tchildren\tsource\tbucket\tsystem\tproject\ttarget\tref\tkind\tverdict\tinto\tevidence\twhy\ttext\ttie\n'
    led ar-30 fixed dispatch agent-runtime work keep - abc123 "gone at HEAD" "fix(x): gone at head #size/s"
    led ar-31 drop dispatch agent-runtime dup merge ar-32 - "same as ar-32" "fix(x): a dup"
    led ar-32 fault dispatch agent-runtime work keep - "x.py:1" "still there" "fix(x): the kept one"
    led ar-33 improvement views agent-runtime polish park - - "polish only" "feat(views): a nicer tile #pts/3"
    led ar-34 improvement views agent-runtime polish park - - "polish" "feat(views): health shaped"
    led ar-35 fault ci trader work keep - "t.py:2" "trader bug" "fix(trader): a trader fault"
    led ar-36 red telemetry unity-core-playground check keep - - "live red" "check(watch): a red for the playground"
    led ar-37 fixed dispatch agent-runtime work keep - def456 "gone" "fix(x): live item"
    led ar-38 drop dispatch agent-runtime plan-bookkeeping drop - - "finish plan" "feat(dispatch): Live plan (plan live-plan)"
    led ar-39 drop dispatch agent-runtime plan-bookkeeping drop - - "finish plan" "feat(dispatch): Orphan plan (plan orphan-plan)"
    led ar-40 drop dispatch agent-runtime plan-bookkeeping drop - - "finish plan" "feat(dispatch): Done plan (plan done-plan)"
    led ar-42 fault ci pad work keep - "p.py:3" "pad bug" "fix(x): pad fault"
    led ar-43 drop ci agent-runtime check drop - - "check with no change" "chore(x): a check"
    led ar-44 drop ci agent-runtime check drop - - "gone" "closed already"
  } >"$HOME/led.tsv"
  printf '# Live\n\n## Phases\n\n- [ ] P1 a\n' >"$HOME/plans/_live/live-plan.md"
  printf '# Orphan\n\n## Phases\n\n- [x] P1 a\n- [ ] P2 b\n' >"$HOME/plans/_live/orphan-plan.md"
  printf '# Done\n\n## Phases\n\n- [x] P1 a\n' >"$HOME/plans/_live/done-plan.md"
  printf '%s\n' '#!/bin/sh' "echo '{\"slug\":\"live-p1\",\"task\":\"Phase 1 of the plan ~/.agent/plans/_live/live-plan.md\"}'" >"$HOME/queue"
  chmod +x "$HOME/queue"
  APPLY=(apply --board "$HOME/board2.json" --plans "$HOME/plans" --queue-cmd "$(printf %q "$HOME/queue")" --notes "$NOTES")
}

@test "export: --except leaves out the rows a ledger already judged" {
  printf 'id\tbucket\nar-3\tred\nar-20\tfault\n' >"$HOME/old.tsv"
  run "$RV" export --board "$HOME/board.json" --scorecard "" --reds-cmd "" --except "$HOME/old.tsv" "$D"
  assert_success
  assert_output --partial "1 rows in 1 chunks"
  run cut -f1 "$D/rows.tsv"
  assert_output "$(printf 'id\nar-10')"
  printf 'id\nar-3\nar-20\nar-10\n' >"$HOME/old.tsv"
  run "$RV" export --board "$HOME/board.json" --scorecard "" --reds-cmd "" --except "$HOME/old.tsv" "$D"
  assert_failure 1
  assert_output --partial "no open agent rows on agent-runtime beyond"
}

@test "apply: a dry run writes nothing and logs each open row's action" {
  apply_fixture
  run "$RV" "${APPLY[@]}" --log "$HOME/log.tsv" "$HOME/led.tsv"
  assert_success
  assert_output --partial "14 open rows -> $HOME/log.tsv (dry run: nothing written)"
  run grep -E 'done|drop|move|improve [^-]' "$HOME/calls"
  assert_failure
  run awk -F'\t' 'NR > 1 { print $1, $2, $3 }' "$HOME/log.tsv"
  assert_output "$(printf '%s\n' 'ar-35 move planned' 'ar-30 done planned' 'ar-31 dup planned' 'ar-32 keep -' 'ar-33 improve planned' \
    'ar-34 keep -' 'ar-36 keep -' 'ar-37 keep -' 'ar-38 drop planned' 'ar-39 orphan -' \
    'ar-40 drop planned' 'ar-41 unjudged -' 'ar-42 keep -' 'ar-43 drop planned')"
  run awk -F'\t' '{ print $1": "$4 }' "$HOME/log.tsv"
  assert_output --partial "ar-34: notes improve calls it health work: stays"
  assert_output --partial "ar-36: red: a fleet watch, stays here though it serves unity-core-playground"
  assert_output --partial "ar-37: doing: a live queue item, untouched"
  assert_output --partial "ar-38: finish plan; plan live-plan: chain live (item live-p1)"
  assert_output --partial "ar-39: plan orphan-plan: open phases and no live chain"
  assert_output --partial "ar-40: finish plan; plan done-plan: no open phase"
  assert_output --partial "ar-42: pad has no agent board: stays until the human names one"
}

@test "apply --write: runs each write through notes, parks an orphan's plan, and fails on a refused write" {
  apply_fixture
  printf 'id\tdecision\twhy\tplan\nar-39\tpark\tfeature work\t\n' >"$HOME/orph.tsv"
  run "$RV" "${APPLY[@]}" --orphans "$HOME/orph.tsv" --write --log "$HOME/log.tsv" "$HOME/led.tsv"
  assert_success
  run grep -vE ' list$|^improve --check' "$HOME/calls"
  assert_output "$(printf '%s\n' \
    'ptask agent-runtime --agent move ar-35 --project trader' \
    'ptask agent-runtime --agent done ar-30 --proof head-check abc123' \
    'ptask agent-runtime --agent drop ar-31 --dup ar-32' \
    'improve agent-runtime --why polish only -- feat(views): a nicer tile (was ar-33)' \
    'ptask agent-runtime --agent drop ar-33 --why moved to improvements: agent-runtime' \
    'ptask agent-runtime --agent drop ar-38 --why finish plan; plan live-plan: chain live (item live-p1)' \
    'ptask agent-runtime --agent drop ar-39 --why plan orphan-plan parked: feature work' \
    'ptask agent-runtime --agent drop ar-40 --why finish plan; plan done-plan: no open phase' \
    'ptask agent-runtime --agent drop ar-43 --why check with no change')"
  run sed -n 3p "$HOME/plans/_live/orphan-plan.md"
  assert_output --partial "Parked: "
  assert_output --partial ", feature work; its board row ar-39 was dropped."
  # Run again: the Parked line is written once.
  run "$RV" "${APPLY[@]}" --orphans "$HOME/orph.tsv" --write --log "$HOME/log.tsv" "$HOME/led.tsv"
  run grep -c "^Parked: " "$HOME/plans/_live/orphan-plan.md"
  assert_output 1
  # A refused write is logged failed and the exit is 1.
  sed -i 's/"state":"doing","id":"ar-37"/"state":"open","id":"ar-37"/' "$HOME/board2.json"
  printf 'id\tstate\tepic\tplan\tafter\tchildren\tsource\tbucket\tsystem\tproject\ttarget\tref\tkind\tverdict\tinto\tevidence\twhy\ttext\ttie\nar-37\topen\t-\t-\t-\t0\t-\tdrop\tci\tagent-runtime\tnone\t-\tcheck\tdrop\t-\t-\tstale\tfix(x): live item\t-\n' >"$HOME/led2.tsv"
  run "$RV" "${APPLY[@]}" --write --log "$HOME/log.tsv" "$HOME/led.tsv" "$HOME/led2.tsv"
  assert_failure 1
  run awk -F'\t' '$1 == "ar-37" { print $2, $3 }' "$HOME/log.tsv"
  assert_output "drop failed 1: refused: open children"
}

@test "apply: decides every row before a write, a dup of a row this run closes gets a why, and a re-run files no improvement twice" {
  apply_fixture
  # A later ledger wins: ar-43 becomes a dup of ar-30, which this run closes; ar-40's plan has no file.
  {
    head -1 "$HOME/led.tsv"
    printf 'ar-43\topen\t-\t-\t-\t0\t-\tdrop\tci\tagent-runtime\tnone\t-\tdup\tmerge\tar-30\t-\tsame\tchore(x): a check\t-\n'
    printf 'ar-40\topen\t-\t-\t-\t0\t-\tdrop\tdispatch\tagent-runtime\tnone\t-\tplan-bookkeeping\tdrop\t-\t-\tfinish plan\tfeat(dispatch): Gone (plan gone-plan)\t-\n'
  } >"$HOME/led2.tsv"
  touch "$HOME/refuse33"
  run "$RV" "${APPLY[@]}" --write --log "$HOME/log.tsv" "$HOME/led.tsv" "$HOME/led2.tsv"
  assert_failure 1
  run awk -F'\t' '$1 ~ /^ar-(33|40|43)$/ { print $1, $2, $3, $4 }' "$HOME/log.tsv"
  assert_output "$(printf '%s\n' 'ar-33 improve failed 1: refused: locked (improvement filed) agent-runtime' \
    "ar-40 orphan - plan gone-plan: no plan file under $HOME/plans" \
    'ar-43 drop ok dup of ar-30, closed in this run')"
  run grep -F 'drop ar-43 --why same (dup of ar-30, closed in this run)' "$HOME/calls"
  assert_success
  # A dry run keeps the mark, and the re-run drops ar-33 without filing its improvement again.
  run "$RV" "${APPLY[@]}" --log "$HOME/log.tsv" "$HOME/led.tsv" "$HOME/led2.tsv"
  run awk -F'\t' '$1 == "ar-33" { print $3 }' "$HOME/log.tsv"
  assert_output "planned (improvement filed)"
  rm "$HOME/refuse33"
  : >"$HOME/calls"
  run "$RV" "${APPLY[@]}" --write --log "$HOME/log.tsv" "$HOME/led.tsv" "$HOME/led2.tsv"
  assert_success
  run grep -c '^improve agent-runtime ' "$HOME/calls"
  assert_output 0
  run grep -c 'drop ar-33 --why moved to improvements' "$HOME/calls"
  assert_output 1
  # A --orphans park whose plan has no file dies before any write; so does a missing --plans.
  printf 'id\tdecision\twhy\tplan\nar-40\tpark\tfeature work\t\n' >"$HOME/orph.tsv"
  : >"$HOME/calls"
  run "$RV" "${APPLY[@]}" --orphans "$HOME/orph.tsv" --write --log "$HOME/log.tsv" "$HOME/led.tsv" "$HOME/led2.tsv"
  assert_failure 1
  assert_output --partial "parks ar-40, whose plan gone-plan has no file to mark"
  run grep -E 'done|drop|move|improve [^-]' "$HOME/calls"
  assert_failure
  run "$RV" apply --board "$HOME/board2.json" --plans "$HOME/nope" --queue-cmd "$(printf %q "$HOME/queue")" --notes "$NOTES" --log "$HOME/log.tsv" "$HOME/led.tsv"
  assert_failure 1
  assert_output --partial "is not a directory"
}

@test "apply: a row whose fix is in dotfiles does not move, and a parent with an open child stays, logged after it" {
  apply_fixture
  # ar-45 is a child of ar-43 filed after the ledger; ar-35's evidence now names a dotfiles file.
  sed -i 's|^ {"project":"agent-runtime","lane":"agent","state":"done","id":"ar-44"| {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-45","text":"fix(x): a child #of/ar-43","tags":["of/ar-43"],"details":[]},\n&|' "$HOME/board2.json"
  {
    head -1 "$HOME/led.tsv"
    printf 'ar-35\topen\t-\t-\t-\t0\t-\tfault\tci\ttrader\tnone\t-\twork\tkeep\t-\tdotfiles:.local/bin/fleet-dispatch:12\ttrader bug\tfix(trader): a trader fault\t-\n'
  } >"$HOME/led2.tsv"
  run "$RV" "${APPLY[@]}" --log "$HOME/log.tsv" "$HOME/led.tsv" "$HOME/led2.tsv"
  assert_success
  run awk -F'\t' '$1 ~ /^ar-(35|43|45)$/ { print $1, $2": "$4 }' "$HOME/log.tsv"
  assert_output "$(printf '%s\n' 'ar-35 keep: serves trader, but its fix is in dotfiles (dotfiles:.local/bin/fleet-dispatch:12): stays' \
    'ar-45 unjudged: not in any ledger' 'ar-43 keep: open children ar-45: stays until they close')"
}

@test "apply: a row an open row waits on with #after/ is not closed undelivered unless the waiter closes too" {
  apply_fixture
  # ar-47 (unjudged, stays) waits on ar-33 (improvement) and ar-48 on ar-30 (fixed); ar-43 (dropped) waits on ar-31 (dup);
  # ar-35, which moves to trader, waits on ar-38 (dropped): a move keeps the gate, so ar-38 stays.
  sed -i 's|"id":"ar-43","text":"chore(x): a check","tags":\[\]|"id":"ar-43","text":"chore(x): a check","tags":["after/ar-31"]|' "$HOME/board2.json"
  sed -i 's|"id":"ar-35","text":"fix(trader): a trader fault","tags":\[\]|"id":"ar-35","text":"fix(trader): a trader fault","tags":["after/ar-38"]|' "$HOME/board2.json"
  sed -i 's|^ {"project":"agent-runtime","lane":"agent","state":"done","id":"ar-44"| {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-47","text":"feat(views): P2 #after/ar-33","tags":["after/ar-33"],"details":[]},\n {"project":"trader","lane":"agent","state":"open","id":"tr-48","text":"fix(trader): after #after/AR-30","tags":["after/AR-30"],"details":[]},\n&|' "$HOME/board2.json"
  run "$RV" "${APPLY[@]}" --log "$HOME/log.tsv" "$HOME/led.tsv"
  assert_success
  run awk -F'\t' '$1 ~ /^ar-(30|31|33|38|43)$/ { print $1, $2, $3": "$4 }' "$HOME/log.tsv"
  assert_output "$(printf '%s\n' 'ar-30 done planned: abc123' 'ar-31 dup planned: dup of ar-32' \
    'ar-33 keep -: open #after/ waiters ar-47: stays until they close' 'ar-38 keep -: open #after/ waiters ar-35: stays until they close' \
    'ar-43 drop planned: check with no change')"
}

@test "apply: two bookkeeping rows for one plan are no proof of each other, and a child moves after its parent" {
  apply_fixture
  # ar-40 now names orphan-plan too; ar-46 is a trader child of ar-35, which moves to trader.
  sed -i 's|(plan done-plan)|(plan orphan-plan)|' "$HOME/board2.json"
  sed -i 's|^ {"project":"agent-runtime","lane":"agent","state":"done","id":"ar-44"| {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-46","text":"fix(trader): its child #of/ar-35","tags":["of/ar-35"],"details":[]},\n&|' "$HOME/board2.json"
  {
    head -1 "$HOME/led.tsv"
    printf 'ar-40\topen\t-\t-\t-\t0\t-\tdrop\tdispatch\tagent-runtime\tnone\t-\tplan-bookkeeping\tdrop\t-\t-\tfinish plan\tfeat(dispatch): Orphan again (plan orphan-plan)\t-\n'
    printf 'ar-46\topen\tar-35\t-\t-\t0\t-\tfault\tci\ttrader\tnone\t-\twork\tkeep\t-\tt.py:9\ttrader child\tfix(trader): its child\t-\n'
  } >"$HOME/led2.tsv"
  run "$RV" "${APPLY[@]}" --log "$HOME/log.tsv" "$HOME/led.tsv" "$HOME/led2.tsv"
  assert_success
  run awk -F'\t' 'NR > 1 && NR < 4 { print $1, $2 }' "$HOME/log.tsv"
  assert_output "$(printf '%s\n' 'ar-35 move' 'ar-46 move')"
  run awk -F'\t' '$1 ~ /^ar-(39|40)$/ { print $1, $2": "$4 }' "$HOME/log.tsv"
  assert_output "$(printf '%s\n' 'ar-39 orphan: plan orphan-plan: open phases and no live chain' 'ar-40 orphan: plan orphan-plan: open phases and no live chain')"
}

@test "cut-report: before and after counts, then Cut and Remains grouped by system with the rubric's line" {
  apply_fixture
  run "$RV" "${APPLY[@]}" --write --log "$HOME/log.tsv" "$HOME/led.tsv"
  assert_success
  cat >"$HOME/after.json" <<'EOF'
{"today":"2026-11-25","rows":[
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-32","text":"fix(x): the kept one","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-36","text":"check(watch): a red for the playground","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-41","text":"chore(x): new since the ledger","tags":[],"details":[]}
]}
EOF
  run "$RV" cut-report --board "$HOME/after.json" --log "$HOME/log.tsv" "$HOME/led.tsv"
  assert_success
  assert_output --partial "Before: 14 open rows. After: 3 open rows. Cut: 7."
  # A re-run's log wins per row: ar-32 closed on the second pass counts as cut.
  printf 'id\taction\tresult\tdetail\twhy\nar-32\tdone\tok\tabc\tstill there\n' >"$HOME/log2.tsv"
  run "$RV" cut-report --board "$HOME/after.json" --log "$HOME/log.tsv" --log "$HOME/log2.tsv" "$HOME/led.tsv"
  assert_output --partial "Before: 14 open rows. After: 3 open rows. Cut: 8."
  run "$RV" cut-report --board "$HOME/after.json" --log "$HOME/log.tsv" "$HOME/led.tsv"
  assert_output --partial "### dispatch"
  assert_output --partial "Rows about dispatch, the queue, landing, agent-land, chains and plans."
  assert_output --partial "| ar-30 | fix(x): gone at head | closed done, proof abc123 | gone at HEAD |"
  assert_output --partial "| ar-35 | fix(trader): a trader fault | moved to another board (trader) | trader bug |"
  assert_output --partial "| ar-32 | fix(x): the kept one | fault | - | still there |"
  assert_output --partial "| ar-36 | check(watch): a red for the playground | red | - | red: a fleet watch, stays here though it serves unity-core-playground; live red |"
  assert_output --partial "| ar-41 | chore(x): new since the ledger | - | - | filed after the ledger: judged by the next pass |"
  refute_output --partial "| ar-39 |"
  run "$RV" cut-report --board "$HOME/after.json" --log "$HOME/led.tsv" "$HOME/led.tsv"
  assert_failure 1
  assert_output --partial "is not a row-value apply log"
  printf 'id\taction\tresult\tdetail\twhy\nar-99\tdrop\tok\t-\t-\n' >"$HOME/log3.tsv"
  run "$RV" cut-report --board "$HOME/after.json" --log "$HOME/log3.tsv" "$HOME/led.tsv"
  assert_failure 1
  assert_output --partial "the logs name rows no LEDGER holds: ar-99"
  # --scope limits the counts and both tables to one pass's ids.
  printf 'id\nar-30\nar-32\nar-35\n' >"$HOME/scope.tsv"
  run "$RV" cut-report --board "$HOME/after.json" --scope "$HOME/scope.tsv" --log "$HOME/log.tsv" "$HOME/led.tsv"
  assert_success
  assert_output --partial "Before: 3 open rows. After: 1 open rows. Cut: 2."
  assert_output --partial "| ar-30 |"
  assert_output --partial "| ar-32 |"
  refute_output --partial "| ar-36 |"
  refute_output --partial "| ar-41 |"
}

# focus: a saved board and a ledger; the stub notes logs each call.
focus_fixture() {
  mkdir -p "$HOME/bin"
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"$HOME/calls"' \
    'case "$*" in *"tag --why runtime-fault ar-61"*) echo "refused: locked" >&2; exit 1 ;; esac' >"$HOME/bin/notes"
  chmod +x "$HOME/bin/notes"
  cat >"$HOME/board3.json" <<'EOF2'
{"today":"2026-11-25","rows":[
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-50","priority":"normal","text":"fix(dispatch): a live red #normal","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-51","priority":"low","text":"check(watch): only names a red","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-52","priority":"high","text":"fix(dispatch): lost item on a requeue","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-53","priority":"normal","text":"fix(dispatch): wrong page text","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-54","priority":"high","text":"fix(sessions): wind-down loses a note","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-55","priority":"normal","text":"refactor(ci): one reader for the budget","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-56","priority":"normal","text":"fix(dispatch): the human asked","tags":[],"details":[],"requested":true},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-57","priority":"normal","text":"feat(dispatch): a chained phase","tags":["after/ar-52"],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"doing","id":"ar-58","priority":"high","text":"fix(dispatch): live item","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-59","text":"chore(x): new since the ledger","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-60","priority":"normal","text":"fix(views): a tile shows a stale count","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-61","priority":"low","text":"fix(telemetry): a watch pages twice","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-62","priority":"low","prio_why":"requested","requested":true,"text":"fix(notes): the human asked, a red","tags":[],"details":[]},
 {"project":"agent-runtime","lane":"agent","state":"open","id":"ar-63","priority":"normal","text":"fix(trader): a trader fault","tags":[],"details":[]}
]}
EOF2
  # id state epic plan after children source bucket system project target ref kind verdict into evidence why text tie
  fled() { printf '%s\topen\t%s\t-\t-\t0\t-\t%s\t%s\tagent-runtime\tnone\t-\t%s\tkeep\t-\t-\t-\t%s\t-\n' "$@"; }
  {
    printf 'id\tstate\tepic\tplan\tafter\tchildren\tsource\tbucket\tsystem\tproject\ttarget\tref\tkind\tverdict\tinto\tevidence\twhy\ttext\ttie\n'
    fled ar-50 ar-1 red dispatch work "fix(dispatch): a live red #normal"
    fled ar-51 ar-1 red telemetry check "check(watch): only names a red"
    fled ar-52 ar-2 fault dispatch work "fix(dispatch): lost item on a requeue"
    fled ar-53 ar-2 fault dispatch work "fix(dispatch): wrong page text"
    fled ar-54 ar-3 fault sessions work "fix(sessions): wind-down loses a note"
    fled ar-55 ar-4 sot ci work "refactor(ci): one reader for the budget"
    fled ar-56 ar-2 requested dispatch work "fix(dispatch): the human asked"
    fled ar-57 ar-2 chain dispatch work "feat(dispatch): a chained phase"
    fled ar-58 ar-2 fault dispatch work "fix(dispatch): live item"
    fled ar-60 ar-5 fault views work "fix(views): a tile shows a stale count"
    fled ar-61 ar-1 red telemetry work "fix(telemetry): a watch pages twice"
    fled ar-62 ar-1 red notes work "fix(notes): the human asked, a red"
    fled ar-63 ar-5 fault ci work "fix(trader): a trader fault" | sed 's/\tagent-runtime\tnone/\ttrader\tnone/'
  } >"$HOME/fled.tsv"
  FOCUS=(focus --board "$HOME/board3.json" --notes "$HOME/bin/notes" --out "$HOME/focus" --log "$HOME/focus.log")
}

@test "focus: each kept row goes to its group in rank order; chain, doing and unjudged rows are counted, not listed" {
  focus_fixture
  run "$RV" "${FOCUS[@]}" "$HOME/fled.tsv"
  assert_success
  assert_output --partial "focus groups -> $HOME/focus (dry run: nothing retagged)"
  assert_output --partial "sot: source-of-truth copy removal: 1 rows (red 0, requested 0, blocks landing or dispatch 0, fault 0, sot 1)"
  assert_output --partial "dispatch: dispatch and landing: 4 rows (red 1, requested 1, blocks landing or dispatch 1, fault 1, sot 0)"
  assert_output --partial "telemetry: telemetry and alerts: 2 rows (red 2, requested 0, blocks landing or dispatch 0, fault 0, sot 0)"
  assert_output --partial "rest: views, skills and the rest: 1 rows"
  assert_output --partial "not worked here: chain 1, doing 1, other board 1, unjudged 1"
  assert_output --partial "notes: notes: 1 rows (red 1,"
  run cut -f1-4 "$HOME/focus/focus-dispatch.tsv"
  assert_output "$(printf 'rank\tid\tbucket\tpriority\nred\tar-50\tred\tnormal\nrequested\tar-56\trequested\tnormal\nblocks landing or dispatch\tar-52\tfault\thigh\nfault\tar-53\tfault\tnormal')"
  # A session fault is high but blocks neither landing nor dispatch.
  run cut -f1,2 "$HOME/focus/focus-sessions.tsv"
  assert_output "$(printf 'rank\tid\nfault\tar-54')"
  # Dry run: the log plans the two tags, and notes is never called.
  run awk -F'\t' '$5 == "tag" { print $1, $6 }' "$HOME/focus.log"
  assert_output "$(printf 'ar-50 planned\nar-61 planned')"
  [ ! -e "$HOME/calls" ]
}

@test "focus --write: retags only a live work red below high, and exits 1 on a refused tag" {
  focus_fixture
  run "$RV" "${FOCUS[@]}" --write "$HOME/fled.tsv"
  assert_failure 1
  run cat "$HOME/calls"
  assert_output "$(printf '%s\n' 'ptask agent-runtime --agent tag --why runtime-fault ar-50' 'ptask agent-runtime --agent tag --why runtime-fault ar-61')"
  run awk -F'\t' '$5 == "tag" { print $1, $6 }' "$HOME/focus.log"
  assert_output "$(printf 'ar-50 ok\nar-61 failed 1: refused: locked')"
  # A retagged red reads high in its list and the log; a refused one keeps its old priority.
  run awk -F'\t' '$2 == "ar-50" { print $4 }' "$HOME/focus/focus-dispatch.tsv"
  assert_output high
  run awk -F'\t' '$2 == "ar-61" { print $4 }' "$HOME/focus/focus-telemetry.tsv"
  assert_output low
  run awk -F'\t' '$1 == "ar-62" { print "[" $5 "]" }' "$HOME/focus.log"
  assert_output "[-]"
  # The check row (ar-51) and the human's own row (ar-62) rank as reds but keep their tag.
  run cut -f1,2 "$HOME/focus/focus-telemetry.tsv"
  assert_output "$(printf 'rank\tid\nred\tar-51\nred\tar-61')"
}

@test "focus: a system with no group in the rubric fails" {
  focus_fixture
  cp "$REPO_ROOT/.config/row-value/rubric.md" "$HOME/rubric.md"
  sed -i '/^- `rest`:/d' "$HOME/rubric.md"
  run "$RV" "${FOCUS[@]}" --rubric "$HOME/rubric.md" "$HOME/fled.tsv"
  assert_failure 1
  assert_output --partial "ar-60: system views is in no Focus group"
}
