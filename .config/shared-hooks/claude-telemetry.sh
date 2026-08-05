# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# claude-telemetry.sh — the ONE definition of Claude Code's OTel export env.
#
# Ships coding-session metrics + tool-call event logs to the home-k3s Alloy DaemonSet's
# OTLP receiver, which fans out to Prometheus (remote_write) and Loki. Claude Code calls
# Anthropic directly, so this is separate from the LiteLLM->Langfuse gateway tracing.
# Target hp-victus (always-on amd64 k3s node running Alloy; static DHCP lease, LAN-DNS
# name). Alloy binds the OTLP port as a hostPort on every node, so any node IP works;
# hp-victus is the stable pick. Cluster wiring: apps/alloy/{configmap,daemonset}.yaml in
# home-config.
#
# WHY THIS IS A FILE AND NOT A BLOCK IN .ai-rc.
#
# It lived inline in .ai-rc, which only interactive shells source. Systemd user services
# run `/bin/bash -c 'exec ${COMMAND}'` — non-interactive AND non-login — so no runner
# ever saw it. Measured over 7 days before this split: 835 of 886 registered sessions
# were headless agentctl runs, none of them exported anything, and 0 of 8 sampled ones
# existed in Prometheus. That is 655M tokens, 47% of the fleet's entire token volume,
# reporting no cost at all — which is why the cockpit's usage view read ~2% coverage and
# looked like telemetry was broken. It was not broken; it was never switched on for the
# processes doing most of the work.
#
# THE GUARD IS LOAD-BEARING FOR CONTENT PRIVACY — READ BEFORE WIDENING IT.
#
# The OTEL_LOG_* lines below put real prompt and response text into ClickHouse. That is
# fine for a self-hosted Langfuse on the home LAN and NOT fine anywhere else: work
# sessions on the corporate VDI must never export. `getent hosts hp-victus` is the only
# thing enforcing that. Extracting this block does not relax it — every consumer gets the
# same guard precisely because there is now one copy of it.
#
# The lookup is wrapped in `timeout 0.3` because off the home LAN the resolver blocks ~8s
# on this name before failing, which would hang EVERY new shell (.commonrc -> .ai-rc).
# On-LAN it resolves in a few ms (telemetry on); off-LAN it is killed at 0.3s and
# telemetry stays off, which is the intent. That timeout matters even more on the headless
# path: a runner fires every 12 minutes, and an 8s stall on each would be permanent.

if timeout 0.3 getent hosts hp-victus >/dev/null 2>&1; then
    export CLAUDE_CODE_ENABLE_TELEMETRY=1
    export OTEL_EXPORTER_OTLP_ENDPOINT=http://hp-victus:4318
    export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
    export OTEL_METRICS_EXPORTER=otlp
    export OTEL_LOGS_EXPORTER=otlp
    # REQUIRED for the Prometheus path: Claude Code defaults to delta temporality, but
    # otelcol.exporter.prometheus only forwards cumulative - without this, only
    # target_info lands and all counters are silently dropped. (Verified: cumulative
    # makes session/token/cost metrics appear.)
    export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative

    # --- Traces -> Langfuse (via the same Alloy receiver) --------------------
    # Metrics answer "what did this session cost"; traces answer "what it actually did".
    # claude_code.interaction is the per-prompt root span, with .llm_request / .tool /
    # .tool.execution / .hook beneath it. Tracing is beta and OFF unless the BETA flag is
    # set, hence both lines.
    export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
    export OTEL_TRACES_EXPORTER=otlp

    # Full-fidelity content: prompts, responses, tool names/args, tool IO. Without these
    # the spans carry structure and timing but every payload is redacted, which is enough
    # to see that a tool ran and useless for judging whether it did the right thing.
    # See the privacy note above before touching these.
    export OTEL_LOG_USER_PROMPTS=1
    export OTEL_LOG_ASSISTANT_RESPONSES=1
    export OTEL_LOG_TOOL_DETAILS=1
    export OTEL_LOG_TOOL_CONTENT=1

    # Lets one Langfuse project separate machines without a second exporter.
    #
    # `service.name` distinguishes an unattended runner from a session you are sitting in
    # front of. Without it every agentctl run lands in the same bucket as interactive work
    # and the one question this whole extraction exists to answer — "what is the poll loop
    # actually costing me" — stays unanswerable even with the metrics flowing.
    export OTEL_RESOURCE_ATTRIBUTES="service.name=${CLAUDE_TELEMETRY_SERVICE:-claude-code},host.name=$(hostname)"
fi
