#!/usr/bin/env bats
# release-guard.py: no agent session cuts a release (ucp-2709 P15). The origin is a fixture bare
# repo holding v0.5.2, so the re-send check runs a real `git ls-remote`; nothing reaches GitHub.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$BATS_TEST_DIRNAME/../.."
  GUARD="$ROOT/.claude/hooks/release-guard.py"
  T="$BATS_TEST_TMPDIR"
  g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
  g init --bare -b main "$T/origin.git"
  g init -b main "$T/game"
  g -C "$T/game" commit --allow-empty -m init
  g -C "$T/game" remote add origin "$T/origin.git"
  g -C "$T/game" tag v0.5.2
  g -C "$T/game" push origin main v0.5.2
  g -C "$T/game" branch fix-v1.2-bug
  mkdir -p "$T/game/scripts/release"
  printf '{"paths": {"%s": "game"}}' "$T/game" >"$T/project-map.json"
  export PROJECT_MAP_FILE="$T/project-map.json"
}

at() { jq -nc --arg c "$2" --arg d "$1" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | python3 "$GUARD"; }

denied() { assert_success; assert_output --partial '"deny"'; assert_output --partial 'release-guard:'; }
allowed() { assert_success; assert_output ''; }

@test "the design's probe: a release tag made and pushed from a session is denied" {
  run at "$T/game" 'git tag v0.0.0-guard && git push origin v0.0.0-guard'
  denied
  assert_output --partial 'cut.yml'
  assert_output --partial 'gh workflow run release.yml --ref <tag> -f tag=<tag>'
}

@test "every way to make or push a release tag is denied" {
  local c
  for c in 'git tag v0.5.5' 'git tag -a v0.5.5 -m "cut"' 'git tag -am cut v0.5.5' 'git tag -s v0.5.5-dodginballs1' \
           'git tag someapp-v1.9.1' 'git tag --no-sign v0.5.5' 'git -C . tag v0.5.5' \
           'git push origin v0.5.5' 'git push origin refs/tags/v0.5.5' 'git push origin HEAD:refs/tags/v0.5.5' \
           'git push origin tag v0.5.5' 'git push --tags' 'git push origin main --follow-tags' 'git push --mirror' \
           'git push origin :refs/tags/v0.5.2' 'git push --delete origin v0.5.2' \
           'bash -c "git push origin v0.5.5"' 'cd /tmp && cd - && git push origin v0.5.5' 'timeout 60 git push --tags' \
           'gh release create v0.5.5' 'gh release create v0.5.5 --title x --notes y' \
           "git push origin 'refs/tags/*'" "git push origin 'refs/tags/*:refs/tags/*'" 'git tag -a v0.5.5 -m -l' \
           "timeout 120 bash -c 'git tag v0.5.5 && git push origin v0.5.5'" 'nice -n 5 git push --tags' 'setsid git push origin v0.5.5' \
           'gh api repos/o/game/git/refs -f ref=refs/tags/v0.5.5 -f sha=abc' 'gh api -X PATCH repos/o/game/git/refs/tags/v0.5.2 -f sha=abc' \
           'gh api repos/o/game/git/tags -f tag=v0.5.5 -f object=abc' 'gh api repos/o/game/releases -f tag_name=v9.9.9' \
           'gh api repos/o/game/releases --input -'; do
    run at "$T/game" "$c"
    denied
  done
}

@test "a cut by workflow or script, and the untested override, are denied" {
  local c
  for c in 'gh workflow run cut.yml -f version=0.5.5 -f sha=abc' 'gh workflow run .github/workflows/cut.yml' \
           'scripts/release/ship.sh all' './scripts/release/ship.sh v0.5.5' 'bash scripts/release/ship.sh all' \
           'scripts/release.sh v0.5.5 linux' 'scripts/publish.sh 0.5.5' 'infra/scripts/release.sh someapp 1.0.0' \
           'cd scripts/release && ./ship.sh all' \
           'RELEASE_UNTESTED="red Multi" scripts/release-gate.sh v0.5.2' 'export RELEASE_UNTESTED=x' 'env RELEASE_UNTESTED=x make' \
           'gh workflow run release.yml -f tag=v0.5.2 -f untested-reason="Multi red"' 'gh workflow run 12345' \
           'gh workflow run Cut -f version=0.5.5' 'gh workflow run "Release (tag)"' 'gh workflow run cut.yml --ref main -f version=0.0.0-test'; do
    run at "$T/game" "$c"
    denied
  done
}

@test "a release workflow is allowed only as a re-send of a tag already on origin" {
  run at "$T/game" 'gh workflow run release.yml -f tag=v0.5.2'
  allowed
  run at "$T/game" 'gh workflow run steam.yml --ref v0.5.2 -f game=dodginballs -f run-id=1'
  allowed
  run at "$T/game" 'gh -R o/game workflow run release.yml -f tag=v0.5.2 -f game=x'
  allowed
  # the release skill's upload step: steam.yml takes a release.yml run, which built an existing tag
  run at "$T/game" 'gh workflow run steam.yml -f run-id=44630195233 -f game=dodginballs -f build=game -f steam-branch=beta'
  allowed
  run at "$T/game" 'gh workflow run steam.yml -f game=dodginballs -f steam-branch=beta'
  denied
  run at "$T/game" 'gh workflow run steam.yml -f run-id=1 -f untested-reason=red'
  denied
  run at "$T/game" 'gh workflow run release.yml -f tag=v9.9.9'
  denied
  assert_output --partial 'v9.9.9, a release tag not on origin'
  run at "$T/game" 'gh workflow run release.yml --ref main'
  denied
  assert_output --partial 'names no existing tag'
  run at "$T/game" 'gh workflow run phone-release.yml -f tag=v0.5.2 --ref v9.9.9'
  denied
  # an origin that does not answer cannot tell a re-send from a cut
  git -C "$T/game" remote set-url origin "$T/gone.git"
  run at "$T/game" 'gh workflow run release.yml -f tag=v0.5.2'
  denied
  assert_output --partial 'origin did not answer'
}

@test "writes to rulesets, environments and keys are denied; reads pass" {
  local c
  for c in 'gh api -X PUT repos/o/r/rulesets/27685858 --input r.json' 'gh api -X PUT repos/o/unity-core-playground/rulesets/27685858 --input key.json' 'gh api repos/o/r/rulesets -f name=x' \
           'gh api --method DELETE repos/o/r/environments/cut' 'gh api -X POST repos/o/r/keys -f key=ssh-ed25519' \
           'curl -X PATCH https://api.github.com/repos/o/r/rulesets/1 -d @r.json' 'gh repo deploy-key add k.pub -w' \
           'gh repo deploy-key delete 123' 'gh secret set STEAM_TOKEN --env cut' 'gh variable set GATE -e cut --body off' \
           'gh secret delete X --env=steam'; do
    run at "$T/game" "$c"
    denied
  done
  for c in 'gh api repos/o/r/rulesets' 'gh api repos/o/r/environments/steam' 'gh api repos/o/r/keys' 'gh repo deploy-key list' \
           'gh api -X POST repos/o/r/issues -f title=keys' 'curl -X POST https://example.com/keys' 'gh secret set NPM_TOKEN' \
           'gh variable list -e cut' 'gh api repos/o/r/git/refs -f ref=refs/heads/fix -f sha=abc' 'gh api repos/o/r/git/refs/tags/v0.5.2'; do
    run at "$T/game" "$c"
    allowed
  done
}

@test "Claude's settings.json and Codex's hooks.json run the guard on every Bash call, fail-open" {
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("release-guard"))' "$ROOT/.claude/settings.json"
  assert_output 'python3 ~/.claude/hooks/release-guard.py || true'
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("release-guard"))' "$ROOT/.config/codex/hooks.json"
  assert_output 'python3 $HOME/.claude/hooks/release-guard.py || true'
}

@test "negative control: ordinary pushes, tags and reruns pass" {
  local c
  for c in 'git push origin HEAD' 'git push -u origin feat/x' 'git push origin fix-v1.2-bug' 'git tag -l "v*"' 'git tag --contains HEAD' \
           'git tag -d v0.5.5' 'git tag wip-snapshot' 'git tag --list' 'git ls-remote --tags origin' 'gh run rerun 44630195233 --failed' \
           'gh workflow run checks.yml --ref main' 'scripts/shots/publish.sh site v1' 'scripts/release-gate.sh v0.5.2' \
           'rg RELEASE_UNTESTED scripts/' 'gh release view v0.5.2' 'gh release create v0.5.2 --notes x' 'git log --tags' \
           "git push origin 'refs/heads/*'" 'timeout 60 git push origin HEAD' "timeout 60 bash -c 'git push origin HEAD'" 'gh workflow run checks' \
           'gh api repos/o/game/releases -f tag_name=v0.5.2 -f name=x' 'git tag -m "-l" wip-x'; do
    run at "$T/game" "$c"
    allowed
  done
}
