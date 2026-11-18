#!/usr/bin/env bats
# hosted-runner-guard.py: a GitHub-hosted runner label written into a personal repo's workflow is denied.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/hosted-runner-guard.py"
  export PROJECT_MAP_FILE="$BATS_TEST_TMPDIR/project-map.json"
  jq -n '{github_runners: {self_hosted_only: ["acme-personal"], allow: {"acme-personal/app:.github/workflows/mac.yml": "needs a hosted macOS image"}}}' >"$PROJECT_MAP_FILE"
  mkrepo() {
    git init -q "$BATS_TEST_TMPDIR/$1"
    git -C "$BATS_TEST_TMPDIR/$1" remote add origin "$2"
    mkdir -p "$BATS_TEST_TMPDIR/$1/.github/workflows"
  }
  mkrepo app git@github.com:acme-personal/app.git
  mkrepo work https://github.com/acme-work/svc.git
  mkrepo forge git@git.example.org:acme-personal/forged.git
}

# decision <tool> <file> <text>: allow, or the deny reason. The hook prints nothing to allow.
decision() {
  local ti out
  case "$1" in
    Write) ti=$(jq -nc --arg p "$2" --arg t "$3" '{file_path:$p, content:$t}') ;;
    Edit) ti=$(jq -nc --arg p "$2" --arg t "$3" '{file_path:$p, old_string:"x", new_string:$t}') ;;
    MultiEdit) ti=$(jq -nc --arg p "$2" --arg t "$3" '{file_path:$p, edits:[{old_string:"x", new_string:"a: 1"}, {old_string:"y", new_string:$t}]}') ;;
  esac
  out=$(jq -nc --arg tool "$1" --argjson ti "$ti" '{tool_name:$tool, tool_input:$ti}' | python3 "$HOOK")
  if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out"; fi
}

@test "a hosted label in a personal repo's workflow is denied by every write tool, naming the var" {
  for tool in Write Edit MultiEdit; do
    run decision "$tool" "$BATS_TEST_TMPDIR/app/.github/workflows/ci.yml" $'jobs:\n  t:\n    runs-on: ubuntu-latest'
    assert_output --partial 'hosted-runner-guard: acme-personal/app'
    assert_output --partial 'vars.LINUX_RUNNER_LIGHT'
  done
}

@test "a versioned image, a fallback and a matrix entry are hosted labels too" {
  for t in 'runs-on: ubuntu-24.04' "runs-on: \${{ fromJSON(vars.LINUX_RUNNER_LIGHT || '\"ubuntu-latest\"') }}" 'os: [macos-14, windows-2022]' 'runs-on: ubuntu-24.04-arm' 'runs-on: macos-14-large' 'runs-on: macos-13-xlarge' 'runs-on: ubuntu-latest-4-cores'; do
    run decision Write "$BATS_TEST_TMPDIR/app/.github/workflows/ci.yml" "$t"
    assert_output --partial 'hosted-runner-guard:'
  done
}

@test "self-hosted labels, comments and container images pass" {
  for t in 'runs-on: ${{ fromJSON(vars.LINUX_RUNNER_LIGHT) }}' 'runs-on: [self-hosted, macOS]' '    runs-on: [self-hosted, linux] # was ubuntu-latest' 'container: ubuntu:24.04' '# never ubuntu-latest here'; do
    run decision Write "$BATS_TEST_TMPDIR/app/.github/workflows/ci.yml" "$t"
    assert_output allow
  done
}

@test "a work org, an allowlisted workflow and a file outside workflows pass" {
  run decision Write "$BATS_TEST_TMPDIR/work/.github/workflows/ci.yml" 'runs-on: ubuntu-latest'
  assert_output allow
  run decision Write "$BATS_TEST_TMPDIR/app/.github/workflows/mac.yml" 'runs-on: macos-14'
  assert_output allow
  run decision Write "$BATS_TEST_TMPDIR/app/docs/ci.md" 'runs-on: ubuntu-latest'
  assert_output allow
}

@test "a listed owner on another forge passes: there ubuntu-latest is that forge's own runner label" {
  run decision Write "$BATS_TEST_TMPDIR/forge/.github/workflows/ci.yml" 'runs-on: ubuntu-latest'
  assert_output allow
}

@test "an allowlisted workflow reached through a symlinked checkout still matches its key" {
  ln -s "$BATS_TEST_TMPDIR/app" "$BATS_TEST_TMPDIR/app-link"
  run decision Write "$BATS_TEST_TMPDIR/app-link/.github/workflows/mac.yml" 'runs-on: macos-14'
  assert_output allow
}

@test "a new workflow in a directory that does not exist yet still resolves its checkout" {
  rm -rf "$BATS_TEST_TMPDIR/app/.github"
  run decision Write "$BATS_TEST_TMPDIR/app/.github/workflows/new.yml" 'runs-on: windows-latest'
  assert_output --partial 'acme-personal/app'
}

@test "a missing project map fails open" {
  rm "$PROJECT_MAP_FILE"
  run decision Write "$BATS_TEST_TMPDIR/app/.github/workflows/ci.yml" 'runs-on: ubuntu-latest'
  assert_output allow
}
