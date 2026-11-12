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

# --- Launch env every Claude start shares (outside the LAN guard) -----------
# This file is the one env that both .ai-rc and the agentctl unit source, so a launch
# setting that is not telemetry also lives here.
# The claude.ai connectors (Gmail, Calendar, Drive, Docs, artifacts) add about 2.7k tokens
# to every API call. Over 30 days, 2905 sessions made 10 connector calls. Off by default;
# `ENABLE_CLAUDEAI_MCP_SERVERS=true claude` turns them on for one session. Project or user
# settings `env` cannot do this: it is read after the connectors load (checked 2026-11-02).
: "${ENABLE_CLAUDEAI_MCP_SERVERS:=false}"
export ENABLE_CLAUDEAI_MCP_SERVERS
# The Artifact tool schema is about 13K tokens on every API call (the largest part of the
# first request, `agent-usage burn` first_request_parts); over 7 days 13 sessions used it.
# Off by default; `CLAUDE_CODE_ARTIFACT=1 claude` turns it on for a session that will
# publish (claude 2.1.318 reads 0/false/no/off as "artifact_env_off", checked 2026-11-05).
: "${CLAUDE_CODE_ARTIFACT:=0}"
export CLAUDE_CODE_ARTIFACT
# Tools every automated start runs without, as --disallowedTools: a queue start or resume
# (fleet-dispatch dropped_tools), an agentctl runner and a shepherd pass (agent-run's claude
# harness), and a claude-acct move carries the flag over. Their schemas ride on every turn of a
# session that never calls them: in the 7 days to 2026-11-06 Workflow had 1 call and ScheduleWakeup
# 43 (all /loop) across about 2,900 sessions, for about 10K chars a turn; Artifact (ask OaAlhA) had
# 11 calls a week, all from queue sessions. A plain claude start reads none of it. Empty keeps every
# tool, and so does a value that is not a comma list of tool names (it never reaches a command line).
: "${CLAUDE_AUTO_DROP_TOOLS=Workflow,ScheduleWakeup,Artifact}"
case "$CLAUDE_AUTO_DROP_TOOLS" in
    *[!A-Za-z0-9_,]* | ,* | *, | *,,*)
        printf 'claude-telemetry: CLAUDE_AUTO_DROP_TOOLS is not a comma list of tool names: %s; dropping none\n' "$CLAUDE_AUTO_DROP_TOOLS" >&2
        CLAUDE_AUTO_DROP_TOOLS= ;;
esac
export CLAUDE_AUTO_DROP_TOOLS

if timeout 0.3 getent hosts hp-victus >/dev/null 2>&1; then
    # claude_otel_attr <key> [value] -> OTEL_RESOURCE_ATTRIBUTES with <key> set to <value>, or
    # dropped when there is none, and every other attribute kept: a value someone else set
    # survives, and sourcing this twice never stacks copies.
    claude_otel_attr() {
        printf '%s' "${OTEL_RESOURCE_ATTRIBUTES:-}" | tr ',' '\n' | awk -F= -v k="$1" 'NF && $1 != k' |
            { cat; [ -z "${2:-}" ] || printf '%s=%s\n' "$1" "$2"; } | paste -sd, -
    }

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
    # The SDK default is one export per 60000 ms, so a run that ends sooner (a one-shot
    # `claude -p`, a short dispatched lane) exits before its first export and its cost is
    # never logged. Cumulative counters make the shorter period safe: a repeat export
    # restates the total, it does not double count.
    export OTEL_METRIC_EXPORT_INTERVAL="${OTEL_METRIC_EXPORT_INTERVAL:-5000}"

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
    # front of. Without it every runner lands in the same bucket as interactive work
    # and the one question this whole extraction exists to answer — "what is the poll loop
    # actually costing me" — stays unanswerable even with the metrics flowing.
    OTEL_RESOURCE_ATTRIBUTES="$(claude_otel_attr service.name "${CLAUDE_TELEMETRY_SERVICE:-claude-code}")"
    OTEL_RESOURCE_ATTRIBUTES="$(claude_otel_attr host.name "$(hostname)")"
    # `agentctl.runner` names which runner spent it (agentctl@.service sets AGENTCTL_NAME), so
    # the Fleet tab can show $ per runner. Dropped when unset, so nothing else carries one.
    OTEL_RESOURCE_ATTRIBUTES="$(claude_otel_attr agentctl.runner "${AGENTCTL_NAME:-}")"
    # `project` (the canonical name project-name.sh gives the directory Claude starts in, as
    # every hook names it) is added per launch by claude_telemetry_launch, which the .ai-rc
    # claude and cl wrappers call, and never exported here. This env is inherited by everything
    # the shell starts, a tmux server included, so a project resolved now would label a session
    # started later in another directory: missing is better than wrong. An inherited one is
    # dropped for the same reason. `queue.item` (the agent-queue item the session works,
    # AGENT_QUEUE_ITEM, which fleet-dispatch sets on its launch line) is per launch for the same
    # reason, so spend joins the item's chain log (`notes log --item`).
    OTEL_RESOURCE_ATTRIBUTES="$(claude_otel_attr project)"
    OTEL_RESOURCE_ATTRIBUTES="$(claude_otel_attr queue.item)"
    export OTEL_RESOURCE_ATTRIBUTES

    # claude_telemetry_launch -> OTEL_RESOURCE_ATTRIBUTES with project= for $PWD and queue.item=
    # for $AGENT_QUEUE_ITEM, each dropped when it has no value. A launch with an item is fleet-dispatch's
    # (service.name=claude-agentctl, agentctl.runner=fleet-dispatch) whoever ran the start: the caller's
    # runner leaked in before, so on 2026-11-11 16 of 24 queue sessions past 1h exported as shepherd,
    # inbox-plan or claude-code. `agent-usage export check` reads this label.
    claude_telemetry_launch() {
        local a="${OTEL_RESOURCE_ATTRIBUTES:-}"
        if [ -n "${AGENT_QUEUE_ITEM:-}" ]; then
            a="$(OTEL_RESOURCE_ATTRIBUTES="$a" claude_otel_attr service.name claude-agentctl)"
            a="$(OTEL_RESOURCE_ATTRIBUTES="$a" claude_otel_attr agentctl.runner fleet-dispatch)"
        fi
        a="$(OTEL_RESOURCE_ATTRIBUTES="$a" claude_otel_attr project "$(bash -c '. "$1" && resolve_project_name "$2"' _ \
            "$HOME/.config/shared-hooks/project-name.sh" "$PWD" 2>/dev/null)")"
        OTEL_RESOURCE_ATTRIBUTES="$a" claude_otel_attr queue.item "${AGENT_QUEUE_ITEM:-}"
    }
fi

# claude_launch_env -> the launch-line prefix for a claude started as a tmux pane command
# (fleet-dispatch): `env` dropping a parent Claude session's identity, then every variable this file
# exports, shell-quoted, with OTEL_RESOURCE_ATTRIBUTES from claude_telemetry_launch. No rc file runs in
# such a pane, and it gets the tmux server's environment; a server started from inside a Claude
# session holds that session's id, CHILD_SESSION and ATTENDED flags and messaging socket, and no
# telemetry endpoint. Measured 2026-11-08: 16 of 16 live queue sessions exported no cost.
# tests/unit/claude_telemetry.bats checks this list against every `export` above.
claude_launch_env() {
    local v val
    printf 'env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN '
    # CLAUDE_AUTO_DROP_TOOLS is read by the launcher (as --disallowedTools), never by claude.
    for v in ENABLE_CLAUDEAI_MCP_SERVERS CLAUDE_CODE_ARTIFACT; do
        val=$(printenv "$v") && printf '%s=%q ' "$v" "$val"
    done
    # The export, only where the guard above defined it: off the LAN nothing is added.
    command -v claude_telemetry_launch >/dev/null 2>&1 || return 0
    for v in CLAUDE_CODE_ENABLE_TELEMETRY OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL \
        OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE OTEL_METRIC_EXPORT_INTERVAL \
        CLAUDE_CODE_ENHANCED_TELEMETRY_BETA OTEL_TRACES_EXPORTER OTEL_LOG_USER_PROMPTS \
        OTEL_LOG_ASSISTANT_RESPONSES OTEL_LOG_TOOL_DETAILS OTEL_LOG_TOOL_CONTENT; do
        val=$(printenv "$v") && printf '%s=%q ' "$v" "$val"
    done
    printf 'OTEL_RESOURCE_ATTRIBUTES=%q ' "$(claude_telemetry_launch)"
}
