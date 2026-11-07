#!/usr/bin/env bats
# pool-test-failures: the runner pool's failing-test ledger, read from red Tests runs' summary
# artifacts (ar-171). gh is a stub on PATH that serves a canned run list, artifact list and
# artifact downloads, and logs each call, so a run read once is never downloaded again.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/pool-test-failures"
  LEDGER="$XDG_STATE_HOME/unity-test-runs/pool-failures.tsv"
  GHD="$SANDBOX/gh"
  mkdir -p "$GHD"
  export GHD
  # The playground checkout, with feat/x checked out in a worktree.
  git init -q -b main "$SANDBOX/pg"
  git -C "$SANDBOX/pg" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/pg" worktree add -q -b feat/x "$SANDBOX/pg-agent-1" 2>/dev/null
  export PROJECT_MAP_FILE="$SANDBOX/project-map.json"
  printf '{"paths":{"%s":"unity-core-playground"}}\n' "$SANDBOX/pg" > "$PROJECT_MAP_FILE"
  cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GHD/calls.log"
case "$1 $2" in
  "run list") [ -f "$GHD/list.fail" ] && exit 1
    while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
    jq -r "$2" "$GHD/runs.json" ;;
  "api "*) id="${2#*runs/}"; id="${id%%/*}"
    while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
    jq -r "$2" "$GHD/artifacts.$id.json" ;;
  "run download") id="$3"; [ -f "$GHD/download.$id.fail" ] && exit 1
    while [ $# -gt 0 ]; do
      case "$1" in
        -D) dir="$2"; shift 2 ;;
        -n) mkdir -p "$dir/$2"; cp "$GHD/$id.$2.txt" "$dir/$2/summary.txt"; shift 2 ;;
        *) shift ;;
      esac
    done ;;
esac
SH
  chmod +x "$SANDBOX/bin/gh"
}

# artifacts <run id> <name>...: the run's artifact list, with an expired one that is never read.
artifacts() {
  local id="$1"; shift
  jq -n --args '{artifacts: ([$ARGS.positional[] | {name: ., expired: false}] + [{name: "playmode-shard-9", expired: true}])}' "$@" > "$GHD/artifacts.$id.json"
}

@test "cases: each failed case once, from FAIL lines only, across a full run's summary and its shards" {
  mkdir -p "$SANDBOX/a/playmode-summary" "$SANDBOX/a/playmode-shard-1"
  printf 'ok    APlayTests  ==> 3/3 passed\nFAIL  BPlayTests  ==> 1/3 passed\tcases:\tP.B.One\tP.B.Two\nFAIL  CPlayTests  crashed\nUNCONFIRMED DPlayTests  did not pass in its batch\nNOT RUN EPlayTests  after the first FAIL\n' > "$SANDBOX/a/playmode-summary/summary.txt"
  # no final newline: the next file's first line must not run into it
  printf 'FAIL  BPlayTests  ==> 1/3 passed\tcases:\tP.B.One' > "$SANDBOX/a/playmode-shard-1/summary.txt"
  mkdir -p "$SANDBOX/a/playmode-shard-2"
  printf 'FAIL  FPlayTests  ==> 0/1 passed\tcases:\tP.F.One\n' > "$SANDBOX/a/playmode-shard-2/summary.txt"
  run "$SUBJECT" cases "$SANDBOX/a"
  assert_success
  assert_output $'P.B.One\nP.B.Two\nP.F.One'
}

@test "sync: each red run's failed cases land once, keyed by branch and its worktree here" {
  local now t1 t2
  now="$(date +%s)" t1=$((now - 1200)) t2=$((now - 600))
  # a nightly (schedule) is NIGHTLY's, and a run past MAX_AGE_H is not read: neither is asked about
  jq -n --arg a "$(date -u -d "@$t1" +%FT%TZ)" --arg b "$(date -u -d "@$t2" +%FT%TZ)" --arg old "$(date -u -d "@$((now - 90000))" +%FT%TZ)" \
    '[{databaseId: 202, attempt: 1, event: "workflow_dispatch", headBranch: "feat/y", updatedAt: $b},
      {databaseId: 101, attempt: 1, event: "workflow_dispatch", headBranch: "feat/x", updatedAt: $a},
      {databaseId: 505, attempt: 1, event: "schedule", headBranch: "main", updatedAt: $b},
      {databaseId: 606, attempt: 1, event: "workflow_dispatch", headBranch: "feat/w", updatedAt: $old}]' > "$GHD/runs.json"
  artifacts 101 playmode-shard-1 playmode-shard-2 test-runs-playmode-1 playmode-plan
  artifacts 202 editmode-summary
  printf 'FAIL  BPlayTests  ==> 1/3 passed\tcases:\tP.B.One\n' > "$GHD/101.playmode-shard-1.txt"
  printf 'ok    CPlayTests  ==> 2/2 passed\n' > "$GHD/101.playmode-shard-2.txt"
  printf 'FAIL  EditMode  ==> 9/10 passed\tcases:\tP.E.One\n' > "$GHD/202.editmode-summary.txt"

  run "$SUBJECT" sync
  assert_success
  # oldest first; a branch with no worktree here is -
  [ "$(cat "$LEDGER")" = "$(printf '%s\tpg-agent-1\tfeat/x\tP.B.One\n%s\t-\tfeat/y\tP.E.One' "$t1" "$t2")" ]
  # only the summary artifacts are downloaded, never the logs, the plan or an expired one
  run grep 'run download 101' "$GHD/calls.log"
  assert_output --partial '-n playmode-shard-1 -n playmode-shard-2'
  refute_output --partial 'test-runs'
  refute_output --partial 'playmode-plan'
  refute_output --partial 'shard-9'
  run grep -E 'runs/(505|606)|download (505|606)' "$GHD/calls.log"
  assert_failure

  # a second sync reads no run again
  : > "$GHD/calls.log"
  run "$SUBJECT" sync
  assert_success
  [ "$(wc -l < "$LEDGER")" = 2 ]
  run grep -c 'run download\|api ' "$GHD/calls.log"
  assert_output 0
}

@test "sync: a run whose artifacts could not be read is tried again, up to TRIES; a red with no summary is read as none" {
  local at; at="$(date -u -d '-10 min' +%FT%TZ)"
  jq -n --arg at "$at" '[{databaseId: 303, attempt: 1, event: "workflow_dispatch", headBranch: "feat/z", updatedAt: $at},
          {databaseId: 404, attempt: 1, event: "workflow_dispatch", headBranch: "feat/z", updatedAt: $at},
          {databaseId: 707, attempt: 1, event: "workflow_dispatch", headBranch: "feat/v", updatedAt: $at}]' > "$GHD/runs.json"
  artifacts 707 playmode-shard-1
  touch "$GHD/download.707.fail"
  artifacts 303 playmode-shard-1
  artifacts 404 playmode-plan
  printf 'FAIL  BPlayTests  ==> 1/3 passed\tcases:\tP.B.One\n' > "$GHD/303.playmode-shard-1.txt"
  touch "$GHD/download.303.fail"
  run "$SUBJECT" sync
  assert_success
  [ ! -s "$LEDGER" ]
  rm "$GHD/download.303.fail"; : > "$GHD/calls.log"
  run "$SUBJECT" sync
  assert_success
  [ "$(cut -f3,4 "$LEDGER")" = "$(printf 'feat/z\tP.B.One')" ]
  # 404 left no summary, so it was marked read and is not asked about again
  run grep -c 'runs/404' "$GHD/calls.log"
  assert_output 0
  # 707 never downloads: its third failed read gives it up, and a fourth sync does not ask
  run "$SUBJECT" sync
  assert_output --partial 'run 707 unreadable 3 times, given up'
  : > "$GHD/calls.log"
  run "$SUBJECT" sync
  run grep -c 'runs/707' "$GHD/calls.log"
  assert_output 0
}

@test "sync: a failed run list exits 1 and writes nothing; no checkout exits 2" {
  echo '[]' > "$GHD/runs.json"
  touch "$GHD/list.fail"
  run "$SUBJECT" sync
  assert_failure 1
  [ ! -s "$LEDGER" ]
  POOL_FAILURES_PROJECT=nope run "$SUBJECT" sync
  assert_failure 2
  assert_output --partial 'no checkout of nope'
}
