#!/usr/bin/env bats
# agentctl-release-cut: the open sprint decides the cut (stages.md "Release windows", Cut). The
# board, the stats and GitHub are stubs: `notes` serves fixture JSON, `gh` serves canned API
# answers through the real jq (as gh --jq does) and logs each dispatch, so no test reaches GitHub.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  BIN="$REPO_ROOT/.local/bin/agentctl-release-cut"
  F="$SANDBOX/fx"
  mkdir -p "$F"
  export AGENTCTL_INBOX="$SANDBOX/state" FX="$F" RELEASE_CUT_CONF="$F/conf.json" RELEASE_CUT_HOOKS="$F/hooks.sh"
  export AGENT_PROOF_LIB=/nonexistent
  unset AGENTCTL_NAME
  git init -q "$F/repo" && git -C "$F/repo" remote add origin git@github.com:acme/game.git
  printf 'project_repo_path() { [ "$1" = game ] && echo "%s"; }\n' "$F/repo" > "$F/hooks.sh"
  cat > "$F/conf.json" <<'EOF'
{"_doc": "x", "game": {"cut_workflow": "cut.yml", "cut_hour": "22:00",
  "tests": {"workflow": "test.yml", "title": "Tests (all)"},
  "promote": {"deployment": "game-steam-beta", "item": "promote {tag} build {build}"}}}
EOF
  echo '[{"profile":"p","name":"game","epics":[{"id":"g-9","verified":false},{"id":"g-8","verified":true}]}]' > "$F/stats.json"
  echo 0 > "$F/tag"
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "board --json") cat "$FX/board.json" ;;
  "projects --stats --json") [ -e "$FX/nostats" ] && exit 1; cat "$FX/stats.json" ;;
  "--profile p projects --version-of game") cat "$FX/ver" 2>/dev/null || echo v1.2.0 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
q=.; a=("$@")
for i in "${!a[@]}"; do [ "${a[$i]}" = --jq ] && q="${a[$((i + 1))]}"; done
case "$*" in
  "workflow run"*) echo "$*" >> "$FX/dispatched"; echo https://github.com/acme/game/actions/runs/99; exit 0 ;;
  *contents/.github/ci-budgets.json*) [ -e "$FX/budgets" ] || exit 1; cat "$FX/budgets"; exit 0 ;;
  *matching-refs/tags/*) [ "$(cat "$FX/tag")" = 1 ] && j='[{"ref":"refs/tags/v1.2.0"}]' || j='[]' ;;
  "run list"*cut.yml*) j="$(cat "$FX/cutruns" 2>/dev/null || echo '[]')" ;;
  "run list"*test.yml*) j='[{"databaseId":7,"displayTitle":"Tests (affected)","headSha":"bbb"},{"databaseId":5,"displayTitle":"Tests (all)","headSha":"aaa"}]' ;;
  *runs/5/artifacts*) j='{"artifacts":[{"name":"tested-sha-ccc"}]}' ;;
  *compare/*) j="{\"status\":\"$(cat "$FX/compare" 2>/dev/null || echo ahead)\"}" ;;
  *"deployments?"*) j='[{"id":41,"payload":{"build":"777"}}]' ;;
  *deployments/41/statuses*) j="$(cat "$FX/deploy" 2>/dev/null || echo '[]')" ;;
  *) echo "gh stub: $*" >&2; exit 1 ;;
esac
jq -r "$q" <<<"$j"
EOF
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/queued"\nexit 5\n' > "$SANDBOX/bin/agent-queue"
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/paged"\n' > "$SANDBOX/bin/agent-notify"
  # The cut workflow's budget: 5 + 2 minutes, so a 21-minute (1260 s) wait on its run.
  echo '{"workflows":{"cut":{"jobs":{"cut":{"p90":5},"verify":{"p90":2}}}}}' > "$F/budgets"
  # gh-run-wait: logs the run it was asked to wait on, then exits with $FX/runend (default 0, a
  # success, which pushes the tag as the cut workflow does unless $FX/notag exists).
  cat > "$SANDBOX/bin/gh-run-wait" <<'EOF'
#!/usr/bin/env bash
echo "$GH_REPO $*" >> "$FX/waited"
rc="$(cat "$FX/runend" 2>/dev/null || echo 0)"
[ "$rc" != 0 ] || [ -e "$FX/notag" ] || echo 1 > "$FX/tag"
exit "$rc"
EOF
  chmod +x "$SANDBOX/bin/notes" "$SANDBOX/bin/gh" "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-notify" "$SANDBOX/bin/gh-run-wait"
}

# board CUT TASK...: the game's v1.2.0 sprint, due 2026-11-20, with `cut=` CUT (- for none) and
# each TASK as id:state[:priority[:commit[:i]]], `i` for a row that entered as an #interrupt.
board() {
  local cut="$1" t id st pr cm it tasks=() ; shift
  for t in "$@"; do
    IFS=: read -r id st pr cm it <<<"$t"
    tasks+=("{\"id\":\"$id\",\"text\":\"row $id\",\"state\":\"$st\",\"interrupt\":$([ "$it" = i ] && echo true || echo false)${pr:+,\"priority\":\"$pr\"}${cm:+,\"commit\":\"$cm\"}}")
  done
  local c=""; [ "$cut" = - ] || c="\"cut\":\"$cut\","
  printf '{"sprints":[{"profile":"p","project":"game","version":"v1.2.0","due":"2026-11-20",%s"tasks":[%s]}]}\n' \
    "$c" "$(IFS=,; echo "${tasks[*]}")" > "$F/board.json"
}

@test "past its cut time, a window with a plain open row cuts at the newest green full run's tested commit and names the carried row" {
  board 2026-11-20T21:59 g-1:done g-2:open g-3:doing:low
  RELEASE_CUT_NOW=2026-11-20T22:00 run "$BIN"
  assert_success
  assert_output --partial 'dispatched cut.yml for game v1.2.0 at ccc (on time: cut time 2026-11-20T21:59, carrying 2 open row(s))'
  assert_output --partial 'g-2 [open] row g-2'
  assert_equal "$(cat "$F/dispatched")" 'workflow run cut.yml -R acme/game --ref main -f version=1.2.0 -f sha=ccc'
  # Once per green SHA: a later pass that sees no tag does not dispatch again.
  echo 0 > "$F/tag"
  RELEASE_CUT_NOW=2026-11-20T22:30 run "$BIN"
  assert_output --partial 'already dispatched at ccc'
  assert_equal "$(wc -l < "$F/dispatched")" 1
}

@test "an open #urgent row holds the cut past its time, and pages under one dedupe key" {
  board 2026-11-20T21:59 g-1:done g-2:open:urgent g-3:open
  RELEASE_CUT_NOW=2026-11-21T09:00 run "$BIN"
  assert_success
  assert_output --partial 'held by open #urgent row(s): g-2'
  [ ! -e "$F/dispatched" ]
  # agent-notify sends one page per key; every pass names the same one.
  RELEASE_CUT_NOW=2026-11-21T09:30 run "$BIN"
  assert_equal "$(sort -u "$F/paged" | cut -d' ' -f1-4)" '-p high -d release-cut:held-game@v1.2.0'
  # NEGATIVE CONTROL: the same row closed, the window cuts and carries g-3.
  board 2026-11-20T21:59 g-1:done g-2:done:urgent g-3:open
  RELEASE_CUT_NOW=2026-11-21T09:00 run "$BIN"
  assert_output --partial 'carrying 1 open row(s)'
  assert [ -e "$F/dispatched" ]
}

@test "every committed row closed cuts early, before its time; an unverified epic row keeps it off until the cut time" {
  board - g-1:done g-8:done g-4:dropped g-5:deferred
  RELEASE_CUT_NOW=2026-11-19T08:00 run "$BIN"
  assert_success
  assert_output --partial 'dispatched cut.yml for game v1.2.0 at ccc (early: all 4 committed rows closed)'
  rm -f "$F/dispatched" && rm -rf "$AGENTCTL_INBOX"
  board - g-1:done g-9:done
  RELEASE_CUT_NOW=2026-11-19T08:00 run "$BIN"
  assert_output --partial 'epic(s) g-9 closed without proof of the outcome; cuts at 2026-11-20T22:00'
  [ ! -e "$F/dispatched" ]
}

@test "before its time with open rows it is not ready and names them (negative control: nothing dispatched)" {
  board - g-1:open g-2:done
  RELEASE_CUT_NOW=2026-11-20T21:59 run "$BIN"
  assert_success
  assert_output --partial 'not ready: 1 of 2 committed rows open; cuts at 2026-11-20T22:00'
  assert_output --partial 'g-1 [open] row g-1'
  [ ! -e "$F/dispatched" ]
}

@test "a tag already on origin is a no-op, and a cut run in flight is waited on only when this lane dispatched it" {
  board - g-1:done
  echo 1 > "$F/tag"
  run "$BIN"
  assert_output --partial 'tag already on origin, nothing to cut'
  [ ! -e "$F/waited" ]
  echo 0 > "$F/tag"
  echo '[{"status":"in_progress","databaseId":98}]' > "$F/cutruns"
  # Not this lane's dispatch of v1.2.0 (no mark): left alone.
  run "$BIN"
  assert_success
  assert_output --partial 'a cut.yml run is in flight'
  [ ! -e "$F/waited" ]
  # This lane dispatched v1.2.0 on an earlier pass: the run in flight is waited on.
  mkdir -p "$AGENTCTL_INBOX/cuts" && printf 'ccc\t2026-11-20T22:00\n' > "$AGENTCTL_INBOX/cuts/game@v1.2.0"
  run "$BIN"
  assert_success
  assert_output --partial 'the cut.yml run 98 for game v1.2.0 succeeded'
  assert_equal "$(cat "$F/waited")" 'acme/game 98 cut.yml game v1.2.0'
  [ ! -e "$F/dispatched" ]
}

@test "a dispatch waits on the run gh printed, bounded by 3x the cut workflow's budget" {
  board - g-1:done
  run "$BIN"
  assert_success
  assert_equal "$(cat "$F/waited")" 'acme/game 99 cut.yml game v1.2.0'
  assert_output --partial 'the cut.yml run 99 for game v1.2.0 succeeded; the roll follows its tag'
  # The run ends badly: the pass fails and pages under the same key the next pass would use.
  rm -rf "$AGENTCTL_INBOX" "$F/waited"
  echo 0 > "$F/tag"
  echo 1 > "$F/runend"
  run "$BIN"
  assert_failure
  assert_output --partial 'FAILED game v1.2.0: the cut.yml run 99 ended without success and made no tag'
  grep -qF -- '-d release-cut:cutfailed-game@v1.2.0' "$F/paged"
  # Still running when the wait ends (timeout's 124): a failure, and no high page.
  rm -rf "$AGENTCTL_INBOX" "$F/paged"
  echo 124 > "$F/runend"
  run "$BIN"
  assert_failure
  assert_output --partial 'still runs after 21 min, 3 times its budget; the next pass waits on it'
  run grep -c -- "-p high" "$F/paged"; assert_output 0
  # A green run that left no tag for this version is not a cut.
  rm -rf "$AGENTCTL_INBOX"
  echo 0 > "$F/runend" && touch "$F/notag"
  run "$BIN"
  assert_failure
  assert_output --partial 'the cut.yml run 99 succeeded, but no v1.2.0 tag is on origin'
}

@test "no budget row, or a wait past STEP_TIMEOUT, refuses the dispatch; a dry run names the missing row" {
  board - g-1:done
  STEP_TIMEOUT=1500 run "$BIN"
  assert_failure
  assert_output --partial 'takes up to 1260s, more than the'
  assert_output --partial 'STEP_TIMEOUT=1500s leaves after 300s headroom'
  grep -qF -- '-d release-cut:nofit-game@v1.2.0' "$F/paged"
  [ ! -e "$F/dispatched" ]
  rm "$F/budgets"
  run "$BIN" --dry-run
  assert_success
  assert_output --partial 'would dispatch cut.yml on acme/game: version=1.2.0 sha=ccc, then wait ?s on it'
  assert_output --partial '; no cut.yml budget in acme/game .github/ci-budgets.json'
  run "$BIN"
  assert_failure
  assert_output --partial 'has no cut.yml budget in .github/ci-budgets.json on main'
  grep -qF -- '-d release-cut:nobudget-game@v1.2.0' "$F/paged"
  [ ! -e "$F/dispatched" ]
  # NEGATIVE CONTROL: the row back and a STEP_TIMEOUT the wait fits, it dispatches.
  echo '{"workflows":{"cut":{"jobs":{"cut":{"p90":7}}}}}' > "$F/budgets"
  STEP_TIMEOUT=1600 run "$BIN"
  assert_success
  assert [ -e "$F/dispatched" ]
}

@test "--dry-run prints the dispatch and writes nothing" {
  board - g-1:done
  run "$BIN" --dry-run
  assert_success
  assert_output --partial 'would dispatch cut.yml on acme/game: version=1.2.0 sha=ccc, then wait 1260s on it (early'
  [ ! -e "$F/dispatched" ]
  [ ! -e "$AGENTCTL_INBOX" ]
}

@test "after the tag's beta deployment succeeds, the promotion item is filed once" {
  board - g-1:done
  run "$BIN"
  echo 1 > "$F/tag"
  run "$BIN"
  [ ! -e "$F/queued" ]
  echo '[{"state":"success"}]' > "$F/deploy"
  run "$BIN"
  assert_output --partial 'filed game v1.2.0 promotion: promote v1.2.0 build 777'
  run "$BIN"
  assert_equal "$(wc -l < "$F/queued")" 1
  assert_equal "$(cat "$F/queued")" 'add --project game --from auto:release-cut --slug steam-default-game-v1.2.0 --priority high promote v1.2.0 build 777'
}

@test "a beta deployment that failed files no promotion; the rerun's success files it once" {
  board - g-1:done
  run "$BIN"
  echo '[{"state":"failure"}]' > "$F/deploy"
  run "$BIN"
  assert_success
  [ ! -e "$F/queued" ]
  echo '[{"state":"success"}]' > "$F/deploy"
  run "$BIN"
  assert_equal "$(wc -l < "$F/queued")" 1
}

@test "a closed #urgent interrupt fix cuts a patch before the cut time, once a green full run contains its commit" {
  export RELEASE_CUT_NOW=2026-11-19T10:00
  board - g-1:open g-2:done:urgent:fff0001:i
  echo behind > "$F/compare"
  run "$BIN"
  assert_success
  assert_output --partial 'game v1.2.0: #urgent fix g-2 (fff0001) is not in the newest green run at ccc (behind)'
  assert_output --partial 'game v1.2.0: not ready'
  [ ! -e "$F/dispatched" ]
  rm "$F/compare"
  run "$BIN"
  assert_success
  assert_output --partial 'dispatched cut.yml for game v1.2.0 at ccc (patch: #urgent fix g-2 closed, carrying 1 open row(s))'
  assert_output --partial '  g-1 [open] row g-1'
  grep -qF 'version=1.2.0 -f sha=ccc' "$F/dispatched"
}

@test "no patch cut for a plain fix, an #urgent row in the snapshot, or while another #urgent row is open (negative control)" {
  export RELEASE_CUT_NOW=2026-11-19T10:00
  local rows
  for rows in "g-2:done::fff0001:i" "g-2:done:urgent:fff0001" "g-2:done:urgent::i" "g-3:open:urgent g-2:done:urgent:fff0001:i"; do
    # shellcheck disable=SC2086
    board - g-1:open $rows
    run "$BIN"
    assert_success
    assert_output --partial 'game v1.2.0: not ready'
  done
  [ ! -e "$F/dispatched" ]
}

@test "a fix the green run lacks, or cannot compare, leaves the on-time cut to happen" {
  export RELEASE_CUT_NOW=2026-11-20T23:00
  board - g-1:open g-2:done:urgent:fff0001:i
  echo diverged > "$F/compare"
  run "$BIN"
  assert_success
  assert_output --partial 'is not in the newest green run at ccc (diverged)'
  assert_output --partial '(on time: cut time 2026-11-20T22:00, carrying 1 open row(s))'
  assert_equal "$(wc -l < "$F/dispatched")" 1
}

@test "a dispatched cut run that failed with no tag fails the pass and pages once under its key" {
  board - g-1:done
  echo 124 > "$F/runend"
  run "$BIN"
  echo '[{"status":"completed","conclusion":"failure"}]' > "$F/cutruns"
  run "$BIN"
  assert_failure
  assert_output --partial 'FAILED game v1.2.0: the cut.yml run dispatched at ccc ended failure with no tag'
  assert_equal "$(wc -l < "$F/dispatched")" 1
  grep -qF -- '-d release-cut:cutfailed-game@v1.2.0' "$F/paged"
}

@test "no stats, no early cut: the pass fails instead of skipping the epic check" {
  board - g-1:done g-9:done
  touch "$F/nostats"
  run "$BIN"
  assert_failure
  assert_output --partial 'FAILED notes projects --stats --json gave no stats'
  [ ! -e "$F/dispatched" ]
}

@test "0.0.0 is never cut; --dry-run counts after the project name; a date-only cut= is cut at cut_hour" {
  board - g-1:done
  echo v0.0.0-test > "$F/ver"
  sed -i 's/"v1.2.0"/"v0.0.0-test"/' "$F/board.json"
  run "$BIN"
  assert_failure
  assert_output --partial "0.0.0 is the cut workflow's proof version"
  rm "$F/ver"
  board - g-1:done
  run "$BIN" game --dry-run
  assert_output --partial 'would dispatch cut.yml'
  [ ! -e "$F/dispatched" ]
  board 2026-11-20 g-1:open
  RELEASE_CUT_NOW=2026-11-20T21:00 run "$BIN"
  assert_output --partial 'cuts at 2026-11-20T22:00'
}
