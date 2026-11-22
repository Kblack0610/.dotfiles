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
  # The fixture sprint is due 2026-11-20 22:00: a test that reads the real clock goes red once that passes.
  # A test that needs another time sets RELEASE_CUT_NOW on its own run.
  export RELEASE_CUT_NOW=2026-11-19T08:00
  unset AGENTCTL_NAME
  git init -q "$F/repo" && git -C "$F/repo" remote add origin git@github.com:acme/game.git
  printf 'project_repo_path() { [ "$1" = game ] && echo "%s"; }\n' "$F/repo" > "$F/hooks.sh"
  cat > "$F/conf.json" <<'EOF'
{"_doc": "x", "game": {"cut_workflow": "cut.yml", "cut_hour": "22:00",
  "tests": {"workflow": "test.yml", "title": "Tests (all)"},
  "promote": {"deployment_suffix": "-steam-beta", "item": "promote {target} {tag} build {build}"}}}
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
  gh_script <<'EOF'
q=.; a=("$@")
for i in "${!a[@]}"; do [ "${a[$i]}" = --jq ] && q="${a[$((i + 1))]}"; done
case "$*" in
  "workflow run"*) echo "$*" >> "$FX/dispatched"; echo https://github.com/acme/game/actions/runs/99; exit 0 ;;
  *contents/.github/ci-budgets.json*) [ -e "$FX/budgets" ] || exit 1; cat "$FX/budgets"; exit 0 ;;
  # The version's tag, then $FX/gametags (a JSON array of the cut's game refs, v1.2.10 too).
  *matching-refs/tags/*) [ -e "$FX/norefs" ] && exit 1; [ "$(cat "$FX/tag")" = 1 ] && j="$(jq -c '[{ref: "refs/tags/v1.2.0"}] + .' "$FX/gametags" 2>/dev/null || echo '[{"ref":"refs/tags/v1.2.0"}]')" || j='[]' ;;
  # GitHub answers 404 for a commit the repo does not have ($FX/nocommit).
  *compare/*) [ -e "$FX/nocommit" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    j="$(cat "$FX/compare" 2>/dev/null || echo '{"status":"behind"}')" ;;
  "run list"*cut.yml*) j="$(cat "$FX/cutruns" 2>/dev/null || echo '[]')" ;;
  "run list"*test.yml*) j='[{"databaseId":7,"displayTitle":"Tests (affected)","headSha":"bbb"},{"databaseId":5,"displayTitle":"Tests (all)","headSha":"aaa"}]' ;;
  *runs/5/artifacts*) j='{"artifacts":[{"name":"tested-sha-ccc"}]}' ;;
  # Each tag's deployments, newest first: the version's beta (41) behind a newer non-beta one, and
  # the dodge2 game's beta ($FX/dodgeid, default 42; a game name that ends in a digit).
  *"deployments?ref=v1.2.0&"*) j='[{"id":40,"environment":"steam"},{"id":41,"environment":"game-steam-beta","payload":{"build":"777"}}]' ;;
  *"deployments?ref=v1.2.0-dodge21&"*) j="[{\"id\":$(cat "$FX/dodgeid" 2>/dev/null || echo 42),\"environment\":\"dodge2-steam-beta\",\"payload\":{\"build\":\"888\"}}]" ;;
  *"deployments?"*) j='[]' ;;
  *deployments/41/statuses*) j="$(cat "$FX/deploy" 2>/dev/null || echo '[]')" ;;
  *deployments/4[23]/statuses*) j="$(cat "$FX/deploy2" 2>/dev/null || echo '[]')" ;;
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
  chmod +x "$SANDBOX/bin/notes" "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-notify" "$SANDBOX/bin/gh-run-wait"
}

# board CUT TASK...: the game's v1.2.0 sprint, due 2026-11-20, with `cut=` CUT (- for none) and
# each TASK as id:state[:priority[:commit[:i[:pr_repo]]]], `i` for a row that entered as an
# interrupt, pr_repo the owner/name its `pr:` names.
board() {
  local cut="$1" t id st pr cm it rp tasks=() ; shift
  for t in "$@"; do
    IFS=: read -r id st pr cm it rp <<<"$t"
    tasks+=("{\"id\":\"$id\",\"text\":\"row $id\",\"state\":\"$st\",\"interrupt\":$([ "$it" = i ] && echo true || echo false)${pr:+,\"priority\":\"$pr\"}${cm:+,\"commit\":\"$cm\"}${rp:+,\"pr_repo\":\"$rp\"}}")
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

@test "an open #urgent row holds no cut: past its time the window cuts and carries it" {
  board 2026-11-20T21:59 g-1:done g-2:open:urgent g-3:open
  RELEASE_CUT_NOW=2026-11-21T09:00 run "$BIN"
  assert_success
  assert_output --partial 'carrying 2 open row(s) (#urgent: g-2)'
  assert_output --partial 'g-2 [open]'
  assert [ -e "$F/dispatched" ]
  refute_output --partial 'held by'
  # NEGATIVE CONTROL: before its cut time the same open #urgent row leaves the window not ready.
  rm -f "$F/dispatched"
  RELEASE_CUT_NOW=2026-11-20T09:00 run "$BIN"
  assert_output --partial 'not ready: 2 of 3 committed rows open (#urgent: g-2)'
  [ ! -e "$F/dispatched" ]
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
  assert_output --partial 'filed game v1.2.0 promotion: promote game v1.2.0 build 777'
  run "$BIN"
  assert_equal "$(wc -l < "$F/queued")" 1
  assert_equal "$(cat "$F/queued")" 'add --project game --from auto:release-cut --slug steam-default-game-v1.2.0 --priority high promote game v1.2.0 build 777'
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

@test "a closed #urgent interrupt whose merge commit a green full run contains cuts a patch before the cut time, carrying the open rows" {
  board - g-1:open g-5:done:urgent:abc1234:i
  echo '{"status":"ahead"}' > "$F/compare"
  run "$BIN"
  assert_success
  assert_output --partial 'dispatched cut.yml for game v1.2.0 at ccc (patch: #urgent fix(es) g-5 on a green full run, carrying 1 open row(s))'
  assert_output --partial 'g-1 [open] row g-1'
  assert_equal "$(cat "$F/dispatched")" 'workflow run cut.yml -R acme/game --ref main -f version=1.2.0 -f sha=ccc'
}

@test "an #urgent fix whose PR landed in another repo is no patch fix: no compare, and the cut on time goes ahead (ucp-2745)" {
  # The fix is a dotfiles merge on a game row; GitHub has no such commit in acme/game.
  : > "$F/nocommit"
  board 2026-11-20T21:59 g-1:open g-5:done:urgent:14e31f820667:i:Owner/tools
  RELEASE_CUT_NOW=2026-11-21T09:00 run "$BIN"
  assert_success
  refute_output --partial 'FAILED'
  assert_output --partial 'dispatched cut.yml for game v1.2.0 at ccc (on time: cut time 2026-11-20T21:59, carrying 1 open row(s))'
  # A short-name marker for another repo is skipped the same way.
  board 2026-11-20T21:59 g-1:open g-5:done:urgent:14e31f820667:i:tools
  RELEASE_CUT_NOW=2026-11-21T09:00 run "$BIN"
  refute_output --partial 'FAILED'
  # NEGATIVE CONTROL: the same row with its PR in the cut repo (any case, any owner, or its short
  # name) is a fix, and a commit GitHub cannot find there still fails the pass.
  for rp in ACME/Game other-owner/game game; do
    rm -f "$F/dispatched" && rm -rf "$AGENTCTL_INBOX"
    board 2026-11-20T21:59 g-1:open g-5:done:urgent:14e31f820667:i:$rp
    RELEASE_CUT_NOW=2026-11-21T09:00 run "$BIN"
    assert_output --partial 'FAILED game v1.2.0: cannot compare #urgent fix g-5 (14e31f820667) with green ccc'
  done
}

@test "no patch cut while the #urgent fix is not in a green run, for a plain or committed closed row, or while an #urgent row is open (negative controls)" {
  # The fix landed, but the newest green full run is behind it: it waits, naming the commit.
  board - g-1:open g-5:done:urgent:abc1234:i
  run "$BIN"
  assert_success
  assert_output --partial 'g-5 landed, waiting for a green full run that contains abc1234'
  assert_output --partial 'not ready: 1 of 2 committed rows open'
  echo '{"status":"ahead"}' > "$F/compare"
  # A closed interrupt that is not #urgent, and an #urgent row the snapshot committed, are not fixes.
  board - g-1:open g-5:done:high:abc1234:i g-6:done:urgent:abc1234
  run "$BIN"
  assert_output --partial 'not ready: 1 of 3 committed rows open'
  # An open #urgent row still holds: the patch ships every #urgent fix at once.
  board - g-1:open:urgent g-5:done:urgent:abc1234:i
  run "$BIN"
  assert_output --partial 'not ready: 1 of 2 committed rows open (#urgent: g-1)'
  [ ! -e "$F/dispatched" ]
}

@test "each target of the cut is promoted on its own beta proof; each failed beta deployment files no default and is logged not shipped once" {
  board - g-1:done
  echo '[{"ref":"refs/tags/v1.2.0-dodge21"},{"ref":"refs/tags/v1.2.10"}]' > "$F/gametags"
  run "$BIN"
  echo '[{"state":"success"}]' > "$F/deploy"
  echo '[{"state":"failure"}]' > "$F/deploy2"
  run "$BIN"
  assert_success
  assert_output --partial 'filed game v1.2.0 promotion: promote game v1.2.0 build 777'
  assert_output --partial 'v1.2.0-dodge21: the dodge2-steam-beta deployment 42 ended failure: dodge2 is not shipped on v1.2.0, and no default promotion is filed'
  run "$BIN"
  assert_equal "$(wc -l < "$F/queued")" 1
  assert_equal "$(grep -c 'dodge2 is not shipped' "$AGENTCTL_INBOX/activity.log")" 1
  # A rerun that fails again is a new deployment, logged once too.
  echo 43 > "$F/dodgeid"
  run "$BIN"
  assert_output --partial 'deployment 43 ended failure'
  # A rerun of the failed leg that goes green promotes it.
  echo '[{"state":"success"}]' > "$F/deploy2"
  run "$BIN"
  assert_output --partial 'filed game v1.2.0-dodge21 promotion: promote dodge2 v1.2.0-dodge21 build 888'
  assert_equal "$(wc -l < "$F/queued")" 2
  # NEGATIVE CONTROL: v1.2.10 shares the prefix but is another version, never a target of v1.2.0.
  ! grep -q 'v1.2.10' "$F/queued"
}

@test "a newer cut that made no tag does not hide the last tagged one from promotion; a tag list GitHub cannot give fails the pass" {
  board - g-1:done
  run "$BIN"
  mkdir -p "$AGENTCTL_INBOX/cuts" && printf 'ddd\t2026-11-27T22:00\n' > "$AGENTCTL_INBOX/cuts/game@v1.3.0"
  echo '[{"state":"success"}]' > "$F/deploy"
  touch "$F/norefs"
  run "$BIN"
  assert_failure
  assert_output --partial 'FAILED game v1.3.0: cannot list its tags on acme/game'
  [ ! -e "$F/queued" ]
  rm "$F/norefs"
  run "$BIN"
  assert_success
  assert_output --partial 'filed game v1.2.0 promotion'
}
