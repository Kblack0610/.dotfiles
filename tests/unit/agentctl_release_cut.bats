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
  "workflow run"*) echo "$*" >> "$FX/dispatched"; exit 0 ;;
  *matching-refs/tags/*) [ "$(cat "$FX/tag")" = 1 ] && j='[{"ref":"refs/tags/v1.2.0"}]' || j='[]' ;;
  "run list"*cut.yml*) j="$(cat "$FX/cutruns" 2>/dev/null || echo '[]')" ;;
  "run list"*test.yml*) j='[{"databaseId":7,"displayTitle":"Tests (affected)","headSha":"bbb"},{"databaseId":5,"displayTitle":"Tests (all)","headSha":"aaa"}]' ;;
  *runs/5/artifacts*) j='{"artifacts":[{"name":"tested-sha-ccc"}]}' ;;
  *"deployments?"*) j='[{"id":41,"payload":{"build":"777"}}]' ;;
  *deployments/41/statuses*) j="$(cat "$FX/deploy" 2>/dev/null || echo '[]')" ;;
  *) echo "gh stub: $*" >&2; exit 1 ;;
esac
jq -r "$q" <<<"$j"
EOF
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/queued"\nexit 5\n' > "$SANDBOX/bin/agent-queue"
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/paged"\n' > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/notes" "$SANDBOX/bin/gh" "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-notify"
}

# board CUT TASK...: the game's v1.2.0 sprint, due 2026-11-20, with `cut=` CUT (- for none) and
# each TASK as id:state[:priority].
board() {
  local cut="$1" t id st pr tasks=() ; shift
  for t in "$@"; do
    IFS=: read -r id st pr <<<"$t"
    tasks+=("{\"id\":\"$id\",\"text\":\"row $id\",\"state\":\"$st\"${pr:+,\"priority\":\"$pr\"}}")
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
  # Once per green SHA: the next pass, with no tag yet, does not dispatch again.
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

@test "a tag already on origin is a no-op, and a cut run in flight waits" {
  board - g-1:done
  echo 1 > "$F/tag"
  run "$BIN"
  assert_output --partial 'tag already on origin, nothing to cut'
  echo 0 > "$F/tag"
  echo '[{"status":"in_progress"}]' > "$F/cutruns"
  run "$BIN"
  assert_output --partial 'a cut.yml run is in flight'
  [ ! -e "$F/dispatched" ]
}

@test "--dry-run prints the dispatch and writes nothing" {
  board - g-1:done
  run "$BIN" --dry-run
  assert_success
  assert_output --partial 'would dispatch cut.yml on acme/game: version=1.2.0 sha=ccc (early'
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

@test "a dispatched cut run that failed with no tag fails the pass and pages once under its key" {
  board - g-1:done
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
