# agentctl — config-driven Claude agent supervisor

`agentctl` manages named long-running agents (e.g. `dream`, `monitor`) by
translating per-agent config files into `systemd --user` units. systemd
handles process supervision, restart-on-crash, scheduling, and log
capture; `agentctl` is a thin CLI on top.

## One-time setup

1. Stow `.dotfiles` so the binary, template unit, and configs land in
   `~/.local/bin/`, `~/.config/systemd/user/`, and `~/.config/agentctl/`.
2. Allow agents to keep running after logout:
   ```sh
   loginctl enable-linger "$USER"
   ```
3. Reload systemd and let `agentctl` install the example agents:
   ```sh
   systemctl --user daemon-reload
   agentctl reload
   ```
4. Verify:
   ```sh
   agentctl list
   ```

## Adding an agent

Drop a `.conf` file in `~/.config/agentctl/agents/`, then `agentctl reload`.
The filename stem must match `NAME=`.

### Schema

Required fields: `NAME`, `KIND`, `COMMAND`.

| Field         | Required | Default                         | Notes                                                   |
| ------------- | -------- | ------------------------------- | ------------------------------------------------------- |
| `NAME`        | yes      | —                               | Must match filename stem; `[a-z0-9_-]+`                 |
| `KIND`        | yes      | —                               | `oneshot` or `persistent`                               |
| `COMMAND`     | yes      | —                               | The command line to run (parsed by bash)                |
| `DESCRIPTION` | no       | empty                           | Human-readable description                              |
| `SCHEDULE`    | oneshot  | empty                           | systemd `OnCalendar=` expression (e.g. `*-*-* 03:00:00`)|
| `AUTOSTART`   | persist  | `no`                            | `yes` to enable on boot                                 |
| `INBOX`       | no       | `$HOME/.notes/inbox/<name>`     | Directory for the agent's own activity log             |

### Example: oneshot

```sh
# ~/.config/agentctl/agents/dream.conf
NAME=dream
KIND=oneshot
DESCRIPTION='Distill eval corpus to lessons + mem0 entries'
COMMAND='claude --print /dream'
SCHEDULE='*-*-* 03:00:00'
INBOX="$HOME/.notes/inbox/dream"
```

### Example: persistent

```sh
# ~/.config/agentctl/agents/monitor.conf
NAME=monitor
KIND=persistent
DESCRIPTION='Watch foo, alert on bar'
COMMAND="$HOME/.local/bin/my-monitor-loop"
AUTOSTART=yes
INBOX="$HOME/.notes/inbox/monitor"
```

## Subcommands

```
agentctl list                  Tabular state of all agents
agentctl status <name>         Detail view: state, pid, uptime, log tails
agentctl start <name>          Run now (oneshot) or spawn (persistent)
agentctl stop <name>           Stop a running agent
agentctl restart <name>
agentctl enable <name>         Arm timer (oneshot) or autostart (persistent)
agentctl disable <name>
agentctl logs <name> [-f]      Tail stdout + stderr + inbox/activity.log
agentctl reload                Rescan configs, regenerate timers, daemon-reload
agentctl watch                 Refreshing dashboard via watch(1)
```

## What `agentctl reload` does

1. Scans `~/.config/agentctl/agents/*.conf` and validates each.
2. For every `oneshot` with a `SCHEDULE`: writes
   `~/.config/systemd/user/agentctl-<name>.timer` and arms it.
3. For every `persistent` with `AUTOSTART=yes`: enables and starts
   `agentctl@<name>.service`.
4. Removes timer files for agents whose configs were deleted.
5. Runs `systemctl --user daemon-reload`.

The generated `agentctl-<name>.timer` files are NOT in dotfiles — they
live directly in `~/.config/systemd/user/` and are regenerated on every
reload.

## Where things live

| Concern        | Path                                                          |
| -------------- | ------------------------------------------------------------- |
| CLI            | `~/.local/bin/agentctl` (stowed)                              |
| Service template | `~/.config/systemd/user/agentctl@.service` (stowed)         |
| Per-agent configs | `~/.config/agentctl/agents/*.conf` (stowed)                |
| Generated timers | `~/.config/systemd/user/agentctl-<name>.timer` (machine-local) |
| Captured stdout/stderr | `~/.local/state/agentctl/<name>.{stdout,stderr}.log`     |
| Agent inboxes  | `~/.notes/inbox/<name>/activity.log` (agent-written)          |

## Inbox convention

The template unit sets `AGENTCTL_INBOX=$HOME/.notes/inbox/<name>`. Your
agent script can write whatever it likes there. The recommended pattern
is one append-only `activity.log`:

```sh
#!/bin/sh
# my agent's loop
while :; do
    do_some_work
    printf '[%s] did some work\n' "$(date -Is)" >> "$AGENTCTL_INBOX/activity.log"
    sleep 60
done
```

`agentctl status <name>` and `agentctl logs <name>` show the tail of
this file alongside captured stdout/stderr.

## Picking a harness

Each agent's `COMMAND` invokes a harness — the runtime that runs the LLM
with tools. `agentctl` is harness-agnostic; pick per agent based on what
tools/MCPs the agent needs.

| Harness  | How to invoke                                       | Tools available on this machine                                                                                                | When to use                                                                                                              |
| -------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| opencode | `opencode run -m '<model>' "<prompt>"`              | `serena` MCP (semantic code search), `filesystem` MCP, Bash, Read, Write — sessions in `~/.local/share/opencode/opencode.db`   | New agents that don't need Claude-specific slash commands. Lightweight, headless-friendly. Specify `-m` model explicitly. |
| claude   | `echo "<prompt>" \| claude --print --allowedTools "..."` | All Claude Code MCPs + slash commands (`/dream`, `/remember`, etc.)                                                            | When the agent needs Claude-specific slash commands or MCPs that opencode doesn't have. Used by `nightly-sync` today.    |
| openclaw | `openclaw exec ...` (kubectl exec into home-k3s pod) | Whatever's wired in the remote pod                                                                                             | Offload claude+tools to the home-k3s cluster (free up local box).                                                         |
| binks    | `binks "<task>"`                                    | MCP tools configured in `binks-agent-orchestrator`                                                                             | Local Rust orchestrator. Use for tasks where binks's specific tool set fits.                                              |

### Wiring patterns

**File-reading + LLM + curl (typical mem0/journal agent):**

```bash
COMMAND="$HOME/.local/bin/my-agent-wrapper"
```

The wrapper builds a prompt, invokes a harness, tees output to the agent's
inbox. See `~/.local/bin/agentctl-nightly-sync` for a worked example.

**Single-prompt headless invocation:**

```bash
COMMAND='opencode run -m '\''litellm/reasoning (Qwen3.6-35B-A3B-4bit)'\'' "summarize today and write to ~/.notes/inbox/<agent>/today.md"'
```

**Heavy-tools claude invocation (when slash commands or stock tools are needed):**

```bash
COMMAND='echo "<prompt>" | claude --print --allowedTools "Bash,Read,Write,Glob,Grep,mcp__serena__*"'
```

**Never include `mcp__linear__*` or `mcp__memory__*`** in `--allowedTools` — those families are deprecated on this machine. Use mem0 (via curl) for cross-project memory and `gh` CLI (via the `gh-workflows` skill) for GitHub.

### mem0 is the memory layer

For any agent that needs to read or write durable user-level memory:

```bash
# Read existing memories
curl -s 'https://mem0.kblab.me/memories?user_id=kblack0610' | jq -r '.[].memory'

# Write a new memory
curl -s -X POST https://mem0.kblab.me/memories \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"<fact>"}],"user_id":"kblack0610"}'
```

Auth is currently disabled (LAN/Tailscale only). See
`~/.dotfiles/.claude/skills/mem0-ops/SKILL.md` for the full contract.

### Harness gotcha — opencode tool-use (May 2026)

opencode's `run` mode is currently unreliable for tool-using agents:
premium claude models (`litellm/premium (claude-*)`) hit "Anthropic credit
too low" errors via the LiteLLM gateway, and local Qwen models
(`litellm/code`, `litellm/reasoning`) don't reliably invoke tools when
called via `opencode run` (they respond to plain text but skip tool
loops). For agents that need real tool use today, prefer `claude --print`
until opencode is fixed. Plain text-in / text-out tasks (e.g., a
distillation step where the wrapper handles file IO and curl in shell)
work fine on opencode's local models.

## Custom restart policy

The template unit uses `Restart=on-failure` by default. To override per
agent, drop in a unit override:

```sh
mkdir -p ~/.config/systemd/user/agentctl@<name>.service.d
cat > ~/.config/systemd/user/agentctl@<name>.service.d/restart.conf <<EOF
[Service]
Restart=always
RestartSec=30s
EOF
systemctl --user daemon-reload
```

## Limits & roadmap

v1 trades features for code surface (~400 LOC of bash). Tripwires that
push toward a Python rewrite:

- Need an interactive watch UI with key bindings
- Need cross-agent SQL-style queries
- Need to parse agent stdout structurally (JSONL → status field)
- Need a feature systemd doesn't expose cleanly

Until then: drop a `.conf`, `agentctl reload`, ship.
