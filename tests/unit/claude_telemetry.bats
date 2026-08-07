#!/usr/bin/env bats
# claude-telemetry.sh — the ONE definition of Claude Code's OTel export env, sourced by
# both .ai-rc (interactive) and the agentctl systemd unit (headless).
#
# The guard here is a CONTENT-PRIVACY control, not a convenience: the OTEL_LOG_* vars send
# real prompt and response text to self-hosted Langfuse, and `getent hosts hp-victus` is
# the only thing keeping corporate-VDI sessions from exporting it. A regression is silent
# in the worst direction — everything keeps working, it just also ships your prompts.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SNIP="$BATS_TEST_DIRNAME/../../.config/shared-hooks/claude-telemetry.sh"
  FAKEBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKEBIN"
}

# Source the snippet in a pristine env with a stubbed `getent`, and dump what it exported.
# $1 = the exit code the fake getent returns (0 = on-LAN, 1 = off-LAN)
telemetry_env() {
  printf '#!/bin/sh\nexit %s\n' "$1" > "$FAKEBIN/getent"
  chmod +x "$FAKEBIN/getent"
  env -i HOME="$HOME" PATH="$FAKEBIN:/usr/bin:/bin" ${2:+"$2"} bash -c \
    ". '$SNIP' >/dev/null 2>&1; env | grep -E '^(OTEL_|CLAUDE_CODE_ENABLE|CLAUDE_CODE_ENHANCED)' | sort"
}

@test "on-LAN it exports the full telemetry env" {
  run telemetry_env 0
  assert_output --partial 'CLAUDE_CODE_ENABLE_TELEMETRY=1'
  assert_output --partial 'OTEL_EXPORTER_OTLP_ENDPOINT='
  assert_output --partial 'OTEL_METRICS_EXPORTER=otlp'
}

@test "cumulative temporality is set, or Prometheus silently drops every counter" {
  # Claude Code defaults to delta; otelcol.exporter.prometheus only forwards cumulative.
  # Without this only target_info lands — the pipeline looks healthy and carries no data.
  run telemetry_env 0
  assert_output --partial 'OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative'
}

@test "off-LAN it exports NOTHING — the content-privacy gate" {
  # The paired positive is the on-LAN test above; without it a snippet that exported
  # nothing under any condition would pass this one.
  run telemetry_env 1
  assert_output ''
}

@test "off-LAN it exports no prompt-content flag in particular" {
  # Named separately because this is the one that actually leaks: OTEL_LOG_USER_PROMPTS
  # puts prompt text into ClickHouse.
  run telemetry_env 1
  refute_output --partial 'OTEL_LOG_USER_PROMPTS'
  run telemetry_env 0
  assert_output --partial 'OTEL_LOG_USER_PROMPTS=1'
}

@test "a hanging resolver cannot stall the caller" {
  # `timeout 0.3` exists because off-LAN the resolver blocks ~8s on this name. Interactive
  # shells would hang on every launch; the headless runner fires every 12 minutes.
  printf '#!/bin/sh\nsleep 8\nexit 1\n' > "$FAKEBIN/getent"
  chmod +x "$FAKEBIN/getent"
  local start end
  start=$(date +%s%N)
  env -i HOME="$HOME" PATH="$FAKEBIN:/usr/bin:/bin" bash -c ". '$SNIP'" >/dev/null 2>&1
  end=$(date +%s%N)
  [ $(( (end - start) / 1000000 )) -lt 2000 ]
}

@test "service.name defaults to claude-code and is overridable for runners" {
  # The override is what makes "what is the poll loop costing me" answerable at all: without
  # it every unattended run lands in the same bucket as work you are sitting in front of.
  run telemetry_env 0
  assert_output --partial 'service.name=claude-code,'

  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/getent"; chmod +x "$FAKEBIN/getent"
  run env -i HOME="$HOME" PATH="$FAKEBIN:/usr/bin:/bin" CLAUDE_TELEMETRY_SERVICE=claude-agentctl \
    bash -c ". '$SNIP' >/dev/null 2>&1; echo \$OTEL_RESOURCE_ATTRIBUTES"
  assert_output --partial 'service.name=claude-agentctl,'
}

@test ".ai-rc sources the snippet rather than redefining the env inline" {
  # The whole point of the split: two copies would drift, and the copy that drifts is the
  # one enforcing the privacy guard.
  local airc="$BATS_TEST_DIRNAME/../../.ai-rc"
  run grep -c 'claude-telemetry.sh' "$airc"
  assert_success
  refute_output '0'
  # ...and the inline block is really gone, not merely shadowed.
  run grep -c 'export OTEL_LOG_USER_PROMPTS' "$airc"
  assert_output '0'
}
