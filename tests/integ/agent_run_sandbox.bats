#!/usr/bin/env bats
# agentctl-run: a lane's SANDBOX_PROFILE becomes the harness's OS sandbox (lib/sandbox.sh).
# claude and codex are stubs that record their argv and the GitHub token they were handed; the
# profile is a fixture, because the real one lives in the private overlay. What the sandbox
# itself denies is proven against the real runtime by tests/container/sandbox-proof.sh.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  RUN="$REPO_ROOT/.local/src/agent-run/agentctl-run"
  mkdir -p "$HOME/.config/agentctl/roles" "$HOME/.config/agentctl/mcp" "$HOME/.config/agentctl/sandbox"
  printf '{"mcpServers":{}}\n' > "$HOME/.config/agentctl/mcp/none.json"
  cat > "$HOME/.config/agentctl/roles/build.role" <<'ROLE'
ROLE_DESC="fixture build"
ROLE_WRITE=yes
ROLE_BASH=yes
ROLE_TASK=yes
ROLE_MCP=none
ROLE_MCP_DENY=""
ROLE_APPROVE="Read"
ROLE
  # A profile that tries to switch every hard gate off: the harness must force them back on.
  cat > "$HOME/.config/agentctl/sandbox/lane.json" <<'JSON'
{"sandbox": {"enabled": false, "failIfUnavailable": false, "allowUnsandboxedCommands": true,
  "network": {"allowedDomains": ["github.com"], "strictAllowlist": false},
  "filesystem": {"denyRead": ["~/.ssh", "/etc/fake-cred"], "allowWrite": ["~/.agent"]}},
 "permissions": {"deny": ["Bash(rm -rf /)"]}}
JSON
  # What codex can hold: writes only, no hidden paths, no host list.
  printf '{"sandbox": {"filesystem": {"allowWrite": ["~/.agent"]}}}\n' > "$HOME/.config/agentctl/sandbox/writes.json"

  for h in claude codex; do
    cat > "$SANDBOX/bin/$h" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "mcp list" ]; then echo '[]'; exit 0; fi
if [ "\$1" = "--version" ]; then echo "\${FAKE_CLAUDE_VERSION:-2.1.319} (Claude Code)"; exit 0; fi
printf '%s\n' "\$@" > "$SANDBOX/$h-argv.txt"
printf '%s\n' "\${GH_TOKEN:-<unset>}" "\${GITHUB_TOKEN:-<unset>}" "\${GH_TOKEN_FILE:-<unset>}" > "$SANDBOX/$h-token.txt"
cat >/dev/null
echo '{"result":"ok","session_id":"s-1"}'
EOF
    chmod +x "$SANDBOX/bin/$h"
  done
  # What claude's sandbox needs on PATH (SANDBOX_CLAUDE_NEEDS); stubs, so the suite does not need them installed.
  for b in bwrap socat; do printf '#!/bin/sh\n' > "$SANDBOX/bin/$b"; chmod +x "$SANDBOX/bin/$b"; done
}

lane() { run "$RUN" --role build --data-class public "$@"; }
# settings -> the JSON claude got after --settings
settings() { awk 'f { print; exit } $0 == "--settings" { f = 1 }' "$SANDBOX/claude-argv.txt"; }

@test "a lane with no SANDBOX_PROFILE runs as before: no --settings, and --explain says it is unsandboxed (control)" {
  lane -p x
  assert_success
  run grep -cx -- '--settings' "$SANDBOX/claude-argv.txt"
  assert_output 0
  lane --explain
  assert_output --partial 'sandbox:     (none - this lane runs unsandboxed)'
}

@test "a runner drops the tools every automated start drops (CLAUDE_AUTO_DROP_TOOLS) beside the role's own denials; unset, it drops none (control)" {
  denied() { awk 'f { print; exit } $0 == "--disallowedTools" { f = 1 }' "$SANDBOX/claude-argv.txt"; }
  CLAUDE_AUTO_DROP_TOOLS=Workflow,ScheduleWakeup lane -p x
  assert_success
  run denied
  assert_output --regexp '(^|,)Workflow,ScheduleWakeup$'
  unset CLAUDE_AUTO_DROP_TOOLS
  lane -p x
  run grep -c Workflow "$SANDBOX/claude-argv.txt"
  assert_output 0
}

@test "a sandboxed claude lane gets the profile with every hard gate forced on, whatever the profile says" {
  SANDBOX_PROFILE=lane lane -p x
  assert_success
  run jq -c '[.sandbox.enabled, .sandbox.failIfUnavailable, .sandbox.allowUnsandboxedCommands, .sandbox.network.strictAllowlist, .sandbox.network.allowedDomains]' <<<"$(settings)"
  assert_output '[true,true,false,true,["github.com"]]'
  SANDBOX_PROFILE=lane lane --explain
  assert_line "sandbox:     lane  ($HOME/.config/agentctl/sandbox/lane.json)"
}

@test "each denyRead path is also a Read() and Edit() deny rule, an absolute one with the // prefix, beside the profile's own denies" {
  SANDBOX_PROFILE=lane lane -p x
  run jq -r '.permissions.deny[]' <<<"$(settings)"
  assert_line 'Bash(rm -rf /)'
  assert_line 'Read(~/.ssh)'
  assert_line 'Read(~/.ssh/**)'
  assert_line 'Read(//etc/fake-cred)'
  assert_line 'Read(//etc/fake-cred/**)'
  assert_line 'Edit(~/.ssh/**)'
  assert_line 'Edit(//etc/fake-cred)'
}

@test "run from a worktree, the lane may write the git common dir, so git commit works, but not its hooks or config" {
  git init -q "$SANDBOX/repo"
  git -C "$SANDBOX/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$SANDBOX/repo" worktree add -q "$SANDBOX/wt" -b lane
  cd "$SANDBOX/wt"
  SANDBOX_PROFILE=lane lane -p x
  assert_success
  run jq -c '.sandbox.filesystem.allowWrite' <<<"$(settings)"
  common="$(cd "$SANDBOX/repo/.git" && pwd -P)"
  assert_output "[\"~/.agent\",\"$common\"]"
  run jq -c '.sandbox.filesystem.denyWrite' <<<"$(settings)"
  assert_output "[\"$common/hooks\",\"$common/config\"]"
  run jq -r '.permissions.deny[]' <<<"$(settings)"
  assert_line "Edit(/$common/hooks/**)"
  assert_line "Edit(/$common/config)"
}

@test "a profile's own denyWrite paths are Edit() denies too, so Edit and Write cannot reach what Bash cannot" {
  printf '{"sandbox": {"filesystem": {"allowWrite": ["~/proj"], "denyWrite": ["~/proj/.github", "/srv/locked"]}}}\n' > "$HOME/.config/agentctl/sandbox/dw.json"
  mkdir -p "$SANDBOX/lane-cwd" && cd "$SANDBOX/lane-cwd"   # not a repo, and not $HOME or above it
  SANDBOX_PROFILE=dw lane -p x
  assert_success
  run jq -r '.permissions.deny[]' <<<"$(settings)"
  assert_line 'Edit(~/proj/.github/**)'
  assert_line 'Edit(//srv/locked)'
}

@test "claude older than the key that bounds Edit and Write refuses a sandboxed lane and never starts; unsandboxed is unaffected (negative control)" {
  FAKE_CLAUDE_VERSION=2.1.313 SANDBOX_PROFILE=lane lane -p x
  assert_failure 78
  assert_output --partial "Refusing to run unsandboxed"
  [ ! -e "$SANDBOX/claude-argv.txt" ] || ! grep -qx -- '-p' "$SANDBOX/claude-argv.txt"
  FAKE_CLAUDE_VERSION=2.1.313 lane -p x
  assert_success
}

@test "claude refuses a lane sandbox when a tool its sandbox needs is missing, and the refusal names it" {
  AGENTCTL_NAME=probe SANDBOX_CLAUDE_NEEDS="bwrap no-such-socat" SANDBOX_PROFILE=lane lane -p x
  assert_failure 78
  assert_output --partial "no-such-socat is not installed"
  [ ! -e "$SANDBOX/claude-argv.txt" ] || ! grep -qx -- '-p' "$SANDBOX/claude-argv.txt"
  run jq -r '.why' "$HOME/.local/state/agentctl/sandbox-refusals.jsonl"
  assert_output --partial "no-such-socat is not installed"
  SANDBOX_CLAUDE_NEEDS="bwrap no-such-socat" lane -p x
  assert_success
}

@test "the in-process Edit and Write tools are bounded to the writable set: blockWritesOutsideWorkingDirectories on, additionalDirectories is allowWrite with ~/ expanded, whatever the profile says" {
  git init -q "$SANDBOX/repo"
  git -C "$SANDBOX/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$SANDBOX/repo" worktree add -q "$SANDBOX/wt" -b lane
  cd "$SANDBOX/wt"
  jq '.permissions.blockWritesOutsideWorkingDirectories = false | .permissions.additionalDirectories = ["/srv/extra"]' \
    "$HOME/.config/agentctl/sandbox/lane.json" > "$HOME/.config/agentctl/sandbox/loose.json"
  SANDBOX_PROFILE=loose lane -p x
  assert_success
  common="$(cd "$SANDBOX/repo/.git" && pwd -P)"
  run jq -c '[.permissions.blockWritesOutsideWorkingDirectories, .permissions.additionalDirectories]' <<<"$(settings)"
  assert_output "[true,[\"$HOME/.agent\",\"$common\"]]"
}

@test "outside a repo the writable set is just allowWrite, and a profile with no allowWrite adds no directories" {
  mkdir -p "$SANDBOX/lane-cwd" && cd "$SANDBOX/lane-cwd"   # not a repo, and not $HOME or above it
  printf '{"sandbox": {"network": {"allowedDomains": ["github.com"]}}}\n' > "$HOME/.config/agentctl/sandbox/bare.json"
  SANDBOX_PROFILE=bare lane -p x
  assert_success
  run jq -c '[.permissions.blockWritesOutsideWorkingDirectories, .permissions.additionalDirectories]' <<<"$(settings)"
  assert_output '[true,[]]'
}

@test "a named profile that is missing refuses the run, and claude never starts (negative control)" {
  SANDBOX_PROFILE=nope lane -p x
  assert_failure 78
  assert_output --partial 'Refusing to run unsandboxed'
  [ ! -e "$SANDBOX/claude-argv.txt" ] || fail "claude ran without the sandbox it asked for"
}

@test "a profile name with a path in it is refused" {
  SANDBOX_PROFILE=../lane lane -p x
  assert_failure 78
  assert_output --partial 'is not a profile name'
}

@test "a profile the flag builder could not read right is refused: a list that is not an array, a relative path" {
  printf '{"sandbox": {"filesystem": {"allowWrite": "~/.agent"}}}\n' > "$HOME/.config/agentctl/sandbox/bad.json"
  SANDBOX_PROFILE=bad lane -p x
  assert_failure 78
  assert_output --partial 'not a valid profile'
  printf '{"sandbox": {"filesystem": {"denyRead": [".ssh"]}}}\n' > "$HOME/.config/agentctl/sandbox/bad.json"
  SANDBOX_PROFILE=bad lane -p x
  assert_failure 78
  [ ! -e "$SANDBOX/claude-argv.txt" ] || fail "claude ran on a profile it could not hold"
}

@test "a harness with no harness_sandbox refuses a sandboxed lane instead of running it open" {
  mkdir -p "$HOME/.config/agentctl/routes"
  printf 'ROUTE_DESC=fixture\nROUTE_TRANSPORT=openai-compatible\nROUTE_BASE_URL="http://origin.test/v1"\nROUTE_MODEL_RAW="fast (fixture)"\nROUTE_KEY_SOURCE=none\nROUTE_PAYER=none\nROUTE_PERSONAL_SAFE=yes\nROUTE_WORK_SAFE=yes\nROUTE_FALLBACK_SAFE=yes\nROUTE_VERIFY_MODEL=x\nROUTE_VERIFY_API_BASE=http://origin.test\nROUTE_HARNESSES=raw\n' \
    > "$HOME/.config/agentctl/routes/origin.route"
  run "$RUN" --role build --data-class public --harness raw --route origin -- touch "$SANDBOX/raw-ran"
  assert_success
  [ -e "$SANDBOX/raw-ran" ] || fail "control: the raw harness did not run its command"
  rm "$SANDBOX/raw-ran"
  SANDBOX_PROFILE=lane run "$RUN" --role build --data-class public --harness raw --route origin -- touch "$SANDBOX/raw-ran"
  assert_failure 78
  assert_output --partial "cannot enforce lane sandbox 'lane'"
  [ ! -e "$SANDBOX/raw-ran" ] || fail "the raw harness ran its command open"
}

@test "a sandboxed lane drops an ambient GitHub token; an unsandboxed one keeps it (control)" {
  GH_TOKEN=broad GITHUB_TOKEN=broad SANDBOX_PROFILE=lane lane -p x
  assert_success
  assert_equal "$(cat "$SANDBOX/claude-token.txt")" $'<unset>\n<unset>\n<unset>'
  GH_TOKEN=broad lane -p x
  assert_equal "$(head -1 "$SANDBOX/claude-token.txt")" broad
}

@test "GH_TOKEN_FILE hands the lane its own token, and an unreadable one refuses the run" {
  printf 'scoped-token\n' > "$SANDBOX/token"
  GH_TOKEN=broad GH_TOKEN_FILE="$SANDBOX/token" SANDBOX_PROFILE=lane lane -p x
  assert_success
  assert_equal "$(head -1 "$SANDBOX/claude-token.txt")" scoped-token
  assert_equal "$(sed -n 3p "$SANDBOX/claude-token.txt")" '<unset>'
  GH_TOKEN_FILE="$SANDBOX/missing" lane -p x
  assert_failure 78
  assert_output --partial 'GH_TOKEN_FILE'
}

@test "a sandboxed codex lane writes through workspace-write and its roots, never the bypass; unsandboxed keeps the bypass (control)" {
  git init -q "$SANDBOX/repo"
  cd "$SANDBOX/repo"
  SANDBOX_PROFILE=writes lane --harness codex -p x
  assert_success
  run cat "$SANDBOX/codex-argv.txt"
  assert_line 'workspace-write'
  assert_line "sandbox_workspace_write.writable_roots=[\"$HOME/.agent\",\"$(cd "$SANDBOX/repo/.git" && pwd -P)\"]"
  assert_line 'sandbox_workspace_write.network_access=false'
  refute_line -- '--dangerously-bypass-approvals-and-sandbox'
  lane --harness codex -p x
  run cat "$SANDBOX/codex-argv.txt"
  assert_line -- '--dangerously-bypass-approvals-and-sandbox'
}

@test "codex refuses a profile that hides paths or lists hosts, which it cannot enforce" {
  SANDBOX_PROFILE=lane lane --harness codex -p x
  assert_failure 78
  assert_output --partial 'codex has no read denial'
  [ ! -e "$SANDBOX/codex-argv.txt" ] || fail "codex ran with less isolation than its profile names"
}

@test "a recorded call names its lane sandbox in calls.jsonl" {
  AGENTCTL_NAME=probe SANDBOX_PROFILE=lane lane -p x
  assert_success
  run jq -r 'select(.agent == "probe") | .sandbox' "$HOME/.local/state/agentctl/calls.jsonl"
  assert_output lane
}

@test "a sandboxed lane started from \$HOME or above it refuses, since the cwd is writable; from its own directory it runs (control)" {
  mkdir -p "$HOME/.local/state/agentctl/probe"
  cd "$HOME/.local/state/agentctl/probe"
  SANDBOX_PROFILE=lane lane -p x
  assert_success
  rm "$SANDBOX/claude-argv.txt"
  for d in "$HOME" "$HOME/" /; do
    cd "$d"
    SANDBOX_PROFILE=lane lane -p x
    assert_failure 78
    assert_output --partial 'which holds all of $HOME'
    [ ! -e "$SANDBOX/claude-argv.txt" ] || fail "claude ran from $d with all of \$HOME writable"
  done
  cd "$HOME"
  lane -p x
  assert_success   # an unsandboxed lane has no write bound to lose
}

@test "a refused sandboxed call leaves a line in sandbox-refusals.jsonl and none in calls.jsonl; a hand run leaves none" {
  refusals="$HOME/.local/state/agentctl/sandbox-refusals.jsonl"
  calls="$HOME/.local/state/agentctl/calls.jsonl"
  SANDBOX_PROFILE=nope lane -p x
  assert_failure 78
  [ ! -s "$refusals" ] || fail "a hand run (no AGENTCTL_NAME) wrote a refusal line"
  AGENTCTL_NAME=probe SANDBOX_PROFILE=nope lane -p x
  assert_failure 78
  run jq -c '[.agent, .sandbox, (.why | test("not readable"))]' "$refusals"
  assert_output '["probe","nope",true]'
  mkdir -p "$HOME/.config/agentctl/routes"
  printf 'ROUTE_DESC=fixture\nROUTE_TRANSPORT=openai-compatible\nROUTE_BASE_URL="http://origin.test/v1"\nROUTE_MODEL_RAW="fast (fixture)"\nROUTE_KEY_SOURCE=none\nROUTE_PAYER=none\nROUTE_PERSONAL_SAFE=yes\nROUTE_WORK_SAFE=yes\nROUTE_FALLBACK_SAFE=yes\nROUTE_VERIFY_MODEL=x\nROUTE_VERIFY_API_BASE=http://origin.test\nROUTE_HARNESSES=raw\n' \
    > "$HOME/.config/agentctl/routes/origin.route"
  AGENTCTL_NAME=probe SANDBOX_PROFILE=lane run "$RUN" --role build --data-class public --harness raw --route origin -- true
  assert_failure 78
  assert_output --partial "cannot enforce lane sandbox 'lane'"
  run jq -c '[.harness, (.why | test("cannot enforce"))]' "$refusals"
  assert_line --index 1 '["raw",true]'
  [ ! -s "$calls" ] || fail "a refusal wrote a calls.jsonl line, which every reader counts as a call"
}

@test "srt: the cleared env keeps SANDBOX_ENV_KEEP alone, drops the master key, and an unset one reads empty under set -u" {
  source "$REPO_ROOT/.local/src/agent-run/lib/sandbox.sh"
  printf 'unset LC_ALL; export LITELLM_MASTER_KEY=sk-master GH_TOKEN=gh-x\n%s env\n' "$(sandbox_env_clear)" > "$SANDBOX/line.sh"
  run bash -u "$SANDBOX/line.sh"
  assert_success
  refute_output --partial 'LITELLM_MASTER_KEY'
  refute_output --partial 'GH_TOKEN'
  assert_output --partial 'LC_ALL='
  refute_output --partial 'TZ='
  assert_output --partial "HOME=$HOME"
  assert_output --partial "PATH=$PATH"
}

@test "srt: a missing tool it needs is the refusal, and its own package is readable inside so its seccomp helper runs" {
  source "$REPO_ROOT/.local/src/agent-run/lib/sandbox.sh"
  SANDBOX_FILE="$HOME/.config/agentctl/sandbox/lane.json"
  cd "$SANDBOX"   # outside any repo, so no git common dir joins the lists
  SANDBOX_SRT_NEEDS="srt" run sandbox_srt_refusal
  assert_output 'srt is not on PATH'
  # An npm install: the bin is a link to <package>/dist/cli.js. Not under $SANDBOX/lib, a link into the repo.
  mkdir -p "$SANDBOX/npm/srt/dist"
  printf '#!/bin/sh\n' > "$SANDBOX/npm/srt/dist/cli.js"; chmod +x "$SANDBOX/npm/srt/dist/cli.js"
  ln -s "$SANDBOX/npm/srt/dist/cli.js" "$SANDBOX/bin/srt"
  SANDBOX_SRT_NEEDS="srt" run sandbox_srt_refusal
  assert_output ''
  run sandbox_srt_settings --ro /etc/x --rw /var/y
  assert_success
  assert_equal "$(jq -c '.filesystem.allowRead' <<<"$output")" "[\".\",\"/etc/x\",\"/var/y\",\"~/.agent\",\"$SANDBOX/npm/srt\"]"
  assert_equal "$(jq -c '[.filesystem.allowWrite, .network.strictAllowlist]' <<<"$output")" '[[".","/var/y","~/.agent"],true]'
  run sandbox_srt_settings --bogus x
  assert_failure 2
  # The profile's allowRead is readable; in a repo, its git common dir is readable and never writable.
  jq '.sandbox.filesystem.allowRead = ["/opt/vendor"]' "$SANDBOX_FILE" > "$SANDBOX/p.json"; SANDBOX_FILE="$SANDBOX/p.json"
  git init -q "$SANDBOX/r" && cd "$SANDBOX/r"
  run sandbox_srt_settings
  assert_equal "$(jq -c '.filesystem.allowRead' <<<"$output")" "[\".\",\"$SANDBOX/r/.git\",\"/opt/vendor\",\"~/.agent\",\"$SANDBOX/npm/srt\"]"
  assert_equal "$(jq -c '[.filesystem.allowWrite, .filesystem.denyWrite]' <<<"$output")" '[[".","~/.agent"],[]]'
  jq -e "$SANDBOX_SHAPE" "$SANDBOX_FILE" >/dev/null
  jq '.sandbox.filesystem.allowRead = ["rel/path"]' "$SANDBOX_FILE" > "$SANDBOX/bad.json"
  run jq -e "$SANDBOX_SHAPE" "$SANDBOX/bad.json"
  assert_failure
}
