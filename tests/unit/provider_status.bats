#!/usr/bin/env bats
# provider-status: only incidents on components we use trip the watch, and a status page
# that cannot be read is never read as all clear.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # curl answers each host from $SANDBOX/feeds/<host>.json; a missing file is a dead page
  mkdir -p "$SANDBOX/feeds"
  cat > "$SANDBOX/bin/curl" <<CURL
#!/usr/bin/env bash
url="\${*: -1}"; host="\${url#https://}"; host="\${host%%/*}"
cat "$SANDBOX/feeds/\$host.json" 2>/dev/null
CURL
  chmod +x "$SANDBOX/bin/curl"
  for h in www.githubstatus.com status.claude.com www.cloudflarestatus.com; do feed "$h" '[]'; done
}

# feed <host> <incidents json array>
feed() { printf '{"incidents":%s}' "$2" > "$SANDBOX/feeds/$1.json"; }
inc() { printf '{"name":"%s","impact":"%s","components":[%s]}' "$1" "$2" "$3"; }

@test "no incidents anywhere is all clear" {
  run "$REPO_ROOT/.local/bin/provider-status"
  assert_success
  assert_output ''
}

@test "incidents on components we do not use stay clear" {
  feed www.githubstatus.com "[$(inc 'Copilot down' critical '{"name":"Copilot"}')]"
  feed status.claude.com "[$(inc 'Gmail connector' minor '{"name":"claude.ai"},{"name":"Claude Code"}')]"
  feed www.cloudflarestatus.com "[$(inc 'R2 latency' minor '{"name":"R2"}')]"
  run "$REPO_ROOT/.local/bin/provider-status"
  assert_success
  assert_output ''
}

@test "an incident on a component we use trips, named by provider" {
  feed www.githubstatus.com "[$(inc 'Actions delayed' minor '{"name":"Actions"}')]"
  feed status.claude.com "[$(inc 'Elevated errors' major '{"name":"Claude API (api.anthropic.com)"}')]"
  feed www.cloudflarestatus.com "[$(inc 'Network issues' major '')]"
  run "$REPO_ROOT/.local/bin/provider-status"
  assert_failure 1
  assert_line 'GitHub: Actions delayed (minor)'
  assert_line 'Claude: Elevated errors (major)'
  assert_line 'Cloudflare: Network issues (major)'
}

@test "an unreadable page is UNREACHABLE, never clear, and an incident outranks it" {
  rm "$SANDBOX/feeds/status.claude.com.json"
  echo 'not json' > "$SANDBOX/feeds/www.cloudflarestatus.com.json"
  run "$REPO_ROOT/.local/bin/provider-status"
  assert_failure 2
  assert_line 'UNREACHABLE Claude: status.claude.com'
  assert_line 'UNREACHABLE Cloudflare: www.cloudflarestatus.com'

  feed www.githubstatus.com "[$(inc 'Git down' critical '{"name":"Git Operations"}')]"
  run "$REPO_ROOT/.local/bin/provider-status" --quiet
  assert_failure 1
  assert_output ''
}
