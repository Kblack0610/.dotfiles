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
printf '%s\n' "\$@" > "$SANDBOX/$h-argv.txt"
printf '%s\n' "\${GH_TOKEN:-<unset>}" "\${GITHUB_TOKEN:-<unset>}" "\${GH_TOKEN_FILE:-<unset>}" > "$SANDBOX/$h-token.txt"
cat >/dev/null
echo '{"result":"ok","session_id":"s-1"}'
EOF
    chmod +x "$SANDBOX/bin/$h"
  done
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
