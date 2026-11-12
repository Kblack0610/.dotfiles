#!/usr/bin/env bats
# opencode-perm-check: the fake model drives one shell call per command and the verdict reads the
# tool result opencode sends back. A stub opencode plays the client here (it denies a command that
# contains DENYME the way opencode 2.x does), so the protocol and the verdict are pinned without
# the real binary; one test runs the real opencode when it is installed.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  CHECK="$REPO_ROOT/.local/bin/opencode-perm-check"
  CFG="$SANDBOX/opencode.json"
  cat >"$CFG" <<'JSON'
// JSONC, like the real one
{
  "permissions": [
    {"action": "shell", "resource": "*", "effect": "allow"},
    {"action": "shell", "resource": "*git*push*--force*", "effect": "deny"},
  ],
  "agents": {"title": {"model": "litellm/other"}},
  "mcp": {"servers": {"x": {"type": "local", "command": ["false"]}}},
  "providers": {"litellm": {"package": "aisdk:@ai-sdk/openai-compatible", "settings": {"baseURL": "https://example.invalid/v1"},
                            "models": {"m1": {"name": "m1"}}}}
}
JSON
  STUB="$SANDBOX/bin/opencode-stub"
  cat >"$STUB" <<'PY'
#!/usr/bin/env python3
# Stub opencode client: read the config the check wrote, ask the fake model with a shell tool,
# answer its call with opencode's refusal (DENYME) or the command's output, then ask again.
import json, os, sys, urllib.request
cfg = json.load(open(os.path.join(os.environ["XDG_CONFIG_HOME"], "opencode", "opencode.json")))
open(os.path.join(os.environ["XDG_CONFIG_HOME"], "..", "seen.json"), "w").write(json.dumps({"argv": sys.argv[1:], "cfg": cfg}))
if os.environ.get("STUB_MODE") == "silent":
    sys.exit(1)
url = cfg["providers"]["litellm"]["settings"]["baseURL"] + "/chat/completions"
tool = {"type": "function", "function": {"name": "shell", "parameters": {"properties": {"command": {}}}}}
def ask(messages):
    req = urllib.request.Request(url, json.dumps({"model": "m1", "stream": True, "messages": messages, "tools": [tool]}).encode(),
                                 {"Content-Type": "application/json"})
    first = urllib.request.urlopen(req).read().decode().split("\n\n")[0]
    return json.loads(first.removeprefix("data: "))["choices"][0]["delta"]
call = ask([{"role": "user", "content": "go"}])["tool_calls"][0]
cmd = json.loads(call["function"]["arguments"])["command"]
out = json.dumps({"error": {"type": "permission.rejected", "message": "Permission denied: shell"}, "content": []}) \
    if "DENYME" in cmd else "permission denied"
ask([{"role": "user", "content": "go"}, {"role": "assistant", "tool_calls": [call]},
     {"role": "tool", "tool_call_id": call["id"], "content": out}])
PY
  chmod +x "$STUB"
}

@test "a refused call reads DENIED and an output that only says so reads ran" {
  run "$CHECK" --config "$CFG" --opencode "$STUB" 'git push DENYME' 'echo permission denied'
  assert_success
  assert_line --index 0 --regexp '^DENIED +git push DENYME$'
  assert_line --index 1 --regexp '^ran +echo permission denied$'
  run ls -d "$TMPDIR"/opencode-perm-check.*
  assert_failure  # no --keep, so the scratch dir is gone
}

@test "the copy points litellm and every agent at the fake and starts no MCP server" {
  # --keep leaves the scratch dir, where the stub wrote what it was started with.
  run "$CHECK" --keep --config "$CFG" --opencode "$STUB" 'true'
  assert_success
  seen="$(ls -d "$TMPDIR"/opencode-perm-check.*/seen.json)"
  run jq -r '[(.argv[:4] | join(" ")), (.cfg.providers.litellm.settings.baseURL | test("^http://127.0.0.1:[0-9]+/v1$")),
              .cfg.agents.title.model, .cfg.model, (.cfg | has("mcp")), (.cfg.permissions | length)] | @tsv' "$seen"
  assert_output "$(printf 'run --standalone --auto --model\ttrue\tlitellm/m1\tlitellm/m1\tfalse\t2')"
}

@test "no tool result is NO-RESULT and exit 1; a config with no litellm model is exit 2" {
  STUB_MODE=silent run "$CHECK" --config "$CFG" --opencode "$STUB" 'true'
  assert_failure 1
  assert_output --regexp '^NO-RESULT +true$'
  echo '{"providers": {}}' >"$SANDBOX/empty.json"
  run "$CHECK" --config "$SANDBOX/empty.json" --opencode "$STUB" 'true'
  assert_failure 2
  assert_output --partial 'no litellm model'
}

@test "the real opencode refuses a denied command and runs an allowed one" {
  real="$(PATH=/usr/bin:/usr/local/bin:$PATH command -v opencode || true)"
  [ -n "$real" ] || skip "opencode not installed"
  run "$CHECK" --config "$CFG" --opencode "$real" 'git push --force origin main' 'true'
  assert_success
  assert_line --index 0 --regexp '^DENIED +git push --force origin main$'
  assert_line --index 1 --regexp '^ran +true$'
}
