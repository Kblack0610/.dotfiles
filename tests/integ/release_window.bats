#!/usr/bin/env bats
# The release-window runner: release-cut, then wave-roll, in one agentctl-steps pass. release-cut
# waits on the cut run it dispatches, so the wave-roll step after it sees the run's tag and rolls
# the sprint in the same pass (stages.md "Release windows"). Both steps are the real scripts; gh,
# gh-run-wait, notes and notes-roll are stubs, and the tag lands in a local bare repo that
# origin's ssh is pointed at, so wave-roll's tag fetch is real.

# The runner's STEPS, in the order the private conf (`.config/agentctl/agents/release-window.conf`)
# lists them.
STEPS_ORDER='release-cut=agentctl-release-cut; wave-roll=agentctl-wave-roll'

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  STEPS_BIN="$REPO_ROOT/.local/bin/agentctl-steps"
  export PATH="$SANDBOX/bin:$REPO_ROOT/.local/bin:$PATH"
  export FX="$SANDBOX/fx" AGENTCTL_NAME=release-window AGENTCTL_INBOX="$SANDBOX/inbox"
  export AGENT_PROOF_LIB="$REPO_ROOT/.local/lib/agent-proof.sh" RELEASE_CUT_NOW=2026-11-20T22:30
  mkdir -p "$FX" "$AGENTCTL_INBOX"

  # The game's repo: origin is on GitHub by its URL, and ssh serves it from a local bare repo.
  export ORIGIN="$SANDBOX/origin.git" REPO="$SANDBOX/game"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$REPO"
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git -C "$REPO" push -q "$ORIGIN" main
  git -C "$REPO" remote add origin git@github.com:acme/game.git
  printf '#!/usr/bin/env bash\nexec git-upload-pack "$ORIGIN"\n' > "$SANDBOX/bin/fake-ssh"
  # git runs this through a shell, and the sandbox path has a space in it.
  GIT_SSH_COMMAND="$(printf %q "$SANDBOX/bin/fake-ssh")"
  export GIT_SSH_COMMAND

  export RELEASE_CUT_HOOKS="$SANDBOX/hooks.sh" WAVE_ROLL_HOOKS="$SANDBOX/hooks.sh"
  cat > "$SANDBOX/hooks.sh" <<'EOF'
. "$REPO_ROOT/.config/shared-hooks/project-name.sh"
project_repo_path() { [ "$1" = game ] && printf '%s' "$REPO"; }
project_release_version() { git -C "$REPO" tag -l 'v*' --sort=-v:refname | head -n 1; }
project_release_tags_since() { git -C "$REPO" tag -l 'v*'; }
project_field() { return 0; }
EOF
  export RELEASE_CUT_CONF="$FX/conf.json"
  echo '{"game": {"cut_workflow": "cut.yml", "cut_hour": "22:00", "tests": {"workflow": "test.yml", "title": "Tests (all)"}}}' > "$RELEASE_CUT_CONF"

  # notes: one profile, the game's sheet at v1.2.0, its sprint past its cut time with one row
  # open, and two open rows on the sheet to carry.
  LAB="$SANDBOX/lab/game"
  mkdir -p "$LAB"
  printf '# game\nVersion: v1.2.0 #beta\n' > "$LAB/README.md"
  printf 'personal\n' > "$NOTES_FIXTURE/profiles"
  printf 'game\t%s/summary.md\tactive\tv1.2.0\n' "$LAB" > "$NOTES_FIXTURE/projects.personal"
  echo v1.2.0 > "$NOTES_FIXTURE/version-of.game"
  echo '[{"profile":"personal","name":"game","epics":[]}]' > "$NOTES_FIXTURE/stats.json"
  echo '{"sprints":[{"profile":"personal","project":"game","version":"v1.2.0","due":"2026-11-20","cut":"2026-11-20T22:00","tasks":[{"id":"g-1","text":"row g-1","state":"done"},{"id":"g-2","text":"row g-2","state":"open"}]}]}' > "$NOTES_FIXTURE/board.json"
  printf 'p\t1\tg-2\trow g-2\np\t2\tg-3\trow g-3\n' > "$NOTES_FIXTURE/ptask.personal.game"

  # gh: GitHub's answers through the real jq; the tag exists once it is in the bare repo.
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
q=.; a=("$@")
for i in "${!a[@]}"; do [ "${a[$i]}" = --jq ] && q="${a[$((i + 1))]}"; done
case "$*" in
  "workflow run"*) echo "$*" >> "$FX/dispatched"; echo https://github.com/acme/game/actions/runs/99; exit 0 ;;
  *contents/.github/ci-budgets.json*) echo '{"workflows":{"cut":{"jobs":{"cut":{"p90":5}}}}}'; exit 0 ;;
  *matching-refs/tags/*) j="$(git -C "$ORIGIN" tag -l v1.2.0 | jq -Rsc 'split("\n") | map(select(. != "") | {ref: "refs/tags/\(.)"})')" ;;
  "run list"*cut.yml*) j='[]' ;;
  "run list"*test.yml*) j='[{"databaseId":5,"displayTitle":"Tests (all)","headSha":"aaa"}]' ;;
  *runs/5/artifacts*) j='{"artifacts":[]}' ;;
  *) echo "gh stub: $*" >&2; exit 1 ;;
esac
jq -r "$q" <<<"$j"
EOF
  # gh-run-wait: the cut run ends as $FX/cutrun says; a green one pushes the tag, as cut.yml does.
  cat > "$SANDBOX/bin/gh-run-wait" <<'EOF'
#!/usr/bin/env bash
echo "$GH_REPO $*" >> "$FX/waited"
[ "$(cat "$FX/cutrun" 2>/dev/null)" = failure ] && exit 1
git -C "$ORIGIN" tag v1.2.0 main
EOF
  # notes-roll: logs the roll it was asked for and prints what notes would.
  cat > "$SANDBOX/bin/notes-roll" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FX/rolled"
echo "released game: v1.2.0 -> v1.2.1"
EOF
  export WAVE_ROLL_BIN="$SANDBOX/bin/notes-roll"
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/paged"\n' > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/"*
}

@test "a green cut run is rolled in the same pass, carrying the open rows" {
  run "$STEPS_BIN" "$STEPS_ORDER"
  assert_success
  assert_equal "$(cat "$FX/waited")" 'acme/game 99 cut.yml game v1.2.0'
  assert_equal "$(cat "$FX/rolled")" '--tag v1.2.0 personal game v1.2.1 carry'
  grep -qF 'rolled game v1.2.0 -> v1.2.1 (tag v1.2.0, carried 2)' "$AGENTCTL_INBOX/activity.log"
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/wave-roll/last-outcome")" WORKED
}

@test "a failed cut run rolls nothing and pages" {
  echo failure > "$FX/cutrun"
  run "$STEPS_BIN" "$STEPS_ORDER"
  assert_failure
  assert_output --partial 'the cut.yml run 99 ended without success and made no tag'
  [ ! -e "$FX/rolled" ]
  grep -qF -- '-d release-cut:cutfailed-game@v1.2.0' "$FX/paged"
}

@test "NEGATIVE CONTROL: with wave-roll first, the same green cut waits a whole pass for its roll" {
  run "$STEPS_BIN" 'wave-roll=agentctl-wave-roll; release-cut=agentctl-release-cut'
  assert_success
  [ -e "$FX/waited" ]
  [ ! -e "$FX/rolled" ]
}
