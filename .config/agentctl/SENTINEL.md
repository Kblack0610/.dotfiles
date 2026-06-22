# Sentinel 🛰️ — always-on, observe-only monitoring companion

Sentinel is a persistent `agentctl` agent that watches whatever you point it at and pings you when
something changes. It is the third observe-only persona beside **Argus** (sprint-overseer) and
**Mercer** (release-coordinator): it observes, judges, and notifies — it **never** executes fixes,
mutates anything, or touches release gates.

- **Service:** `agentctl@sentinel.service` (this dir's `agents/sentinel.conf`), runs
  `watch-companion-loop daemon`. `AUTOSTART=yes`, survives logout via `loginctl enable-linger`.
- **Loop:** `~/.dotfiles/.local/bin/watch-companion-loop` (`run` = one pass, `daemon` = loop).
- **Registry:** `~/.agent/watches/*.yaml` — one manifest per watch (runtime axis, not git-tracked).
- **Front door:** the `sentinel` skill — `watch | list | status | stop | pause | resume`.
- **Notify:** `agent-notify` → ntfy (`NTFY_URL`) + Slack (`SLACK_WEBHOOK_URL`) + desktop.
- **Templates:** `sentinel-watches.examples/` in this dir (copy-ready).

## The cost model (why "always-on" is affordable)

| Tier | What | Cost | When it runs |
|---|---|---|---|
| **Deterministic** | http / metric / kubectl / command probes (plain bash + curl/kubectl) | **0 tokens** | every due watch, every pass |
| **Agent** | a bounded `claude -p` reasoning pass | tokens | only (1) a deterministic **TRIP** on an `agent_evaluate: true` watch, or (2) a `probe: agent` watch on its (slow) interval |

A per-hour `SENTINEL_AGENT_BUDGET` (default 20) hard-stops any storm; over budget, a watch reports
"budget exhausted" instead of spending. With every watch deterministic, Sentinel's running cost is
literally zero no matter how many watches or how fast the tick.

**Notify only on state change.** A persistently-broken or flapping watch pings once on the edge,
then stays silent until it changes (per-watch `.state` dedupe). Recovery (TRIP→OK) pings once.

## Manifest schema (flat YAML, parsed in pure bash — no `yq` dependency)

```yaml
name: <stem>                 # == filename stem; [a-z0-9-]+; unique
description: <human text>
probe: http                  # http | metric | kubectl | command | agent
target: <probe-specific>     # see per-probe table below
interval: 5m                 # min time between runs: 30s / 5m / 1h / 2d (bare number = seconds)
expiry: null                 # null/empty = forever; OR a duration from `created` (e.g. 60m); OR an ISO ts
severity: high               # low | normal | high  → agent-notify priority
agent_evaluate: false        # true ⇒ a deterministic TRIP escalates to a claude -p diagnosis
created: 2026-06-18T11:00:00-07:00   # ISO-8601; stamped on write; expiry duration is relative to this
source: user                 # user | release-coordinator | sprint-overseer | bug-bash (provenance)
# optional notify overrides:
notify_priority: high        # defaults to `severity`
notify_title: "Sentinel: …"  # defaults to "Sentinel: <name>"
```

Notes: values may be quoted or bare; **no inline `#` comments on value lines** (the whole line after
`key:` is the value). Repeated keys (`signal:`) collect into a list. Paused watches are renamed
`<name>.yaml.paused` (the loop's `*.yaml` glob skips them).

### Per-probe fields

| `probe` | `target` | expectation fields | TRIP when |
|---|---|---|---|
| `http` | URL | `expect_status` (default 200), optional `expect_body_contains` | status ≠ expected, or body missing the substring; connection failure ⇒ ERROR |
| `metric` | a Prometheus-text URL | `expect_metric`, `expect_op` (`< <= > >= == !=`), `expect_threshold` | the comparison is false; metric absent ⇒ ERROR |
| `kubectl` | `context/namespace/selector` | `expect_rollout: ready` **or** `expect_restarts_max: N` | rollout not ready, or summed restartCount > N |
| `command` | — | `expect_cmd`, `expect_exit` (default 0) | the command's exit ≠ expected |
| `agent` | context hint | `agent_question`, repeatable `signal:`, `agent_max_turns` (default 12) | the verdict doesn't start with `HEALTHY` |

### States & notifications

- `OK` — healthy. Startup (`unknown→OK`) is **silent**. `TRIP→OK` / `ERROR→OK` ⇒ one RECOVERED ping.
- `TRIP` — expectation violated. `→TRIP` ⇒ one ping (the agent verdict if `agent_evaluate`, else the
  raw detail).
- `ERROR` — the probe itself couldn't run (curl failed, metric absent). Sent at `low` priority so a
  transient network blip doesn't page; also deduped.

## Examples

See `sentinel-watches.examples/`:
- `pmp-api-health.yaml` — http liveness.
- `pmp-fanout-backlog.yaml` — metric threshold.
- `pmp-bake.yaml` — fuzzy agent bake-watch with `expiry: 60m` (what release-coordinator drops).

Copy one into `~/.agent/watches/` to activate, or just ask the `sentinel` skill: *"watch the prod
API and ping me if it goes down."*

## Operate

```sh
agentctl status sentinel        # active? pid? uptime? + activity.log tail
agentctl logs sentinel -f       # live tail
agentctl restart sentinel       # after editing watch-companion-loop
watch-companion-loop run        # one manual pass (same registry/state as the daemon)
ls ~/.agent/watches/            # the live registry
```

Tunables (env, set in `sentinel.conf` or the service): `SENTINEL_TICK` (daemon cadence, default 60s),
`SENTINEL_AGENT_BUDGET` (agent passes/hour, default 20), `SENTINEL_MODEL` (default
`claude-sonnet-4-6`), `SENTINEL_WATCHES`, `SENTINEL_STATE`.

## Other agents registering watches

Any agent can write a manifest directly (no skill call): set `source: <agent>` and **always** an
`expiry` for temporary watches so they self-clean. release-coordinator's `monitor` verb is the first
customer (60-min bake watch). Sentinel stays the single notification voice for whatever it watches.

## Risks & how the design handles them

- **Token runaway** → deterministic-first (default cost 0); model only on state-change/slow agent
  watches; `--max-turns` cap; hourly `SENTINEL_AGENT_BUDGET`.
- **Notification spam** → notify only on state change; transient ERROR at `low`, deduped.
- **Zombie watches** → first-class `expiry`; the loop deletes the manifest + state every pass and
  sends a low-prio "expired" notice. Always set `expiry` on temporary watches.

## Phase-2 (not yet built)

Offload the loop to home-k3s as a CronJob (à la the openclaw-watchdog plan) so it runs independent
of the workstation being awake. The manifest format and loop are host-agnostic; only the harness
location changes.
