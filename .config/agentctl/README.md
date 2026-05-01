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
