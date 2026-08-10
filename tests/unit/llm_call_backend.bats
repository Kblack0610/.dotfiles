#!/usr/bin/env bats
# llm-call.sh: resolving a backend out of config.json, and reporting when one fails.
#
# This file had NO coverage, and it is the whole failover path for the eval judge.
#
# The bug it was written for: `.backends.${backend}.base_url` interpolates the backend
# NAME into the jq filter as syntax, so a name containing a hyphen parses as subtraction -
# `.backends.mlx-8bit` reads as `.backends.mlx - 8bit`. The judge's only fallback was
# named `mlx-8bit`, so the failover chain never had a second hop. bnb-platform recorded
# 446 sessions at 100% EVAL PENDING from 2026-08-05, every one of them blaming
# "All LLM backends failed" against an endpoint that was up the entire time.
#
# The file's own header documents an EARLIER bug of exactly this family (a hardcoded
# chain that pointed at keys the config did not declare, so "the failover would run and
# fail on every hop"). That was fixed in the discovery half and reintroduced in the use
# half. Hence a hyphenated name in every fixture here: it is the shape that fails.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic          # rewrites HOME, which is where CONFIG_FILE is resolved

  mkdir -p "$HOME/.config/llm-judge"
  cat > "$HOME/.config/llm-judge/config.json" <<'JSON'
{
  "backend": "alpha",
  "backends": {
    "alpha":       { "base_url": "http://stub/v1", "model": "m-alpha", "timeout_seconds": 11 },
    "beta-8bit":   { "base_url": "http://stub/v1", "model": "m-beta",  "timeout_seconds": 22 }
  }
}
JSON

  # A curl that always answers with a well-formed completion, so these tests are about
  # config resolution and error reporting rather than the network.
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"choices":[{"message":{"content":"OK-CONTENT"}}]}'
EOF
  chmod +x "$SANDBOX/bin/curl"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/.claude/hooks/lib/llm-call.sh"
}

# THE ONE THAT MATTERS. Every other test in this file runs in bats' own shell, which does
# NOT `set -u` - and under those conditions this library has always worked. llm-judge.sh,
# its only real caller, runs `set -uo pipefail`, and there `local ... api_key` (declared,
# never assigned) made `[[ -n "$api_key" ]]` abort the function on EVERY call.
#
# That is what the eval blackout actually was: bnb-platform, 446 sessions, 100% EVAL
# PENDING from 2026-08-05, deterministic rather than the intermittent endpoint fault it was
# diagnosed as four separate times. Each investigation sourced this file from an
# interactive shell, got a clean rc=0, and cleared the endpoint / model / config / timeout
# in turn. A test that does not reproduce the CALLER'S shell options cannot see it, which
# is why the rest of this file passed throughout.
@test "resolves under set -u, the mode llm-judge.sh actually runs in" {
  run bash -c 'set -uo pipefail
    source "$1"
    _call_backend alpha "sys" "usr"' _ "$REPO_ROOT/.claude/hooks/lib/llm-call.sh"
  assert_success
  assert_output --partial 'OK-CONTENT'
  refute_output --partial 'unbound variable'
}

@test "the whole failover chain survives set -u too" {
  run bash -c 'set -uo pipefail
    source "$1"
    call_judge_llm "sys" "usr"' _ "$REPO_ROOT/.claude/hooks/lib/llm-call.sh"
  assert_success
  refute_output --partial 'unbound variable'
}

@test "a plain backend name resolves" {
  run _call_backend alpha "sys" "usr"
  assert_success
  assert_output --partial 'OK-CONTENT'
}

# THE REGRESSION. A hyphen makes the name jq syntax rather than jq data.
@test "a HYPHENATED backend name resolves instead of dying in the jq filter" {
  run _call_backend beta-8bit "sys" "usr"
  assert_success
  assert_output --partial 'OK-CONTENT'
  refute_output --partial 'syntax error'
}

@test "the whole chain reaches a hyphenated fallback when the primary fails" {
  # A curl that fails for the primary's model and succeeds for the fallback's, so the
  # test proves the SECOND hop actually runs rather than that any one hop works.
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *m-alpha*) exit 7 ;; esac; done
printf '{"choices":[{"message":{"content":"FALLBACK-CONTENT"}}]}'
EOF
  chmod +x "$SANDBOX/bin/curl"

  run call_judge_llm "sys" "usr"
  assert_success
  assert_output --partial 'FALLBACK-CONTENT'
}

# A transport failure must NAME ITSELF. `curl ... 2>/dev/null` plus a bare `return 1`
# rendered refused-connection, DNS, TLS and timeout as one indistinguishable sentence,
# and the caller truncates to 200 chars - so 446 eval entries recorded the same text and
# no cause. Four investigations re-derived "the endpoint is healthy" from that silence.
@test "a transport failure reports curl's own reason instead of failing mute" {
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect to stub port 8090: Connection refused" >&2
exit 7
EOF
  chmod +x "$SANDBOX/bin/curl"

  run _call_backend alpha "sys" "usr"
  assert_failure
  assert_output --partial 'Connection refused'
  assert_output --partial 'rc=7'
}

# The failover's WARN has to carry the backend's own reason. Printing a fixed
# "failed, trying next..." is what made 446 eval entries record one sentence and no cause.
@test "the failover WARN carries the reason, not just the fact" {
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl: (6) Could not resolve host: stub" >&2
exit 6
EOF
  chmod +x "$SANDBOX/bin/curl"

  run call_judge_llm "sys" "usr"
  assert_failure
  assert_output --partial 'Could not resolve host'
  assert_output --partial "Backend 'alpha' failed"
  assert_output --partial "Backend 'beta-8bit' failed"
}

@test "an empty response still says something rather than nothing" {
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/bin/curl"

  run _call_backend alpha "sys" "usr"
  assert_failure
  refute_output ''
  assert_output --partial 'alpha'
}

@test "the per-backend timeout is read from that backend's own entry" {
  # Record argv to a file rather than echoing it: the payload contains quotes, and
  # returning it inside the JSON body would break the response the subject has to parse.
  cat > "$SANDBOX/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$SANDBOX/curl-argv.txt"
printf '{"choices":[{"message":{"content":"OK-CONTENT"}}]}'
EOF
  chmod +x "$SANDBOX/bin/curl"

  run _call_backend beta-8bit "sys" "usr"
  assert_success

  run cat "$SANDBOX/curl-argv.txt"
  assert_output --partial '22'      # this backend's own timeout, not the primary's 11
  assert_output --partial 'm-beta'
  refute_output --partial 'm-alpha'
}
