# Claude-acct usage and sources

`claude-acct` normalizes every model pool — Claude subscription accounts and non-Claude sources — into one usage row for `status`, `room`, `check pace`, `textfile` (`claude_acct.prom`) and the Costs tab. Claude accounts live in `~/.config/claude-acct/accounts` (token setup and usage reads: [claude-acct-tokens.md](claude-acct-tokens.md)); every other source lives in `~/.config/claude-acct/sources`. Pace baselines (`RESERVE_PCT`, `PACE_SLACK_PCT`, `UNDERUSE_HOURS`, `UNDERUSE_GAP_PCT`) live in `~/.config/claude-acct/pace.conf`.

## Source kinds

Each line in `~/.config/claude-acct/sources` is:

```
name kind ref [reserve=N] [max_live=N] [rpm=N run_rpm=N] [run_usd=N] [parent=name] [alert=off] [priority=must|low] [host=a,b]
```

| Kind | `ref` | Where usage comes from |
|---|---|---|
| `codex` | Codex sessions dir (e.g. `~/.codex/sessions`) | Rate limits in the newest rollout |
| `agy` | AI Pro quota group bucket stem (e.g. `gemini`) | `agy -p /usage` |
| `litellm-key` | Path to a LiteLLM virtual key file (`0600`) | Gateway `/key/info` (and `/v1/models` for `claude-acct models`) |
| `litellm-team` | Path to a member's LiteLLM key file (`0600`) | Gateway `/team/info?team_id=...` |

Options:
- `reserve=N`: percent of the window kept for the human (overrides `pace.conf` `RESERVE_PCT`).
- `max_live=N`: caps running queue items on the source.
- `rpm=N run_rpm=N`: provider's RPM limit over requests per minute one run draws; caps live items at the lower of `max_live` and `floor(rpm / run_rpm)` (minimum 1).
- `run_usd=N`: estimated USD cost of one run; paces a LiteLLM route with a deployment `budget_duration` to the starts that budget carries in a window (`route_paced`).
- `parent=name`: pool source this key spends inside; the source has room only when its parent also has room.
- `alert=off`: `check pace` never alerts on over-pace (unread still trips).
- `priority=must|low`: consumer class when the gateway does not label the source (`metadata.priority`); Costs tab's Consumers flags a `must` consumer on a `low` source as `MISMATCH`.
- `host=a,b`: row exists only on those hostnames (`CLAUDE_ACCT_HOST` overrides).

## Add a source

Adding a LiteLLM-backed provider (for example, `z.ai`) needs no new `claude-acct` source kind: it is a LiteLLM route plus a `litellm-key` row.

1. **Add the route and mint a key on the LiteLLM gateway.**
   Configure the provider's model route (and any deployment budget or RPM limit) in `home-config` `apps/litellm/config.yaml` per `apps/litellm/README.md`, and mint a virtual key for it. Place the key file on each host that will read or spend from it (for example `~/.local/state/agentctl/<name>.key`, `chmod 600`).

2. **Add the row to `~/.config/claude-acct/sources`.**
   ```
   <name> litellm-key ~/.local/state/agentctl/<name>.key [max_live=N] [rpm=N run_rpm=N] [run_usd=N] [reserve=N] [parent=...] [alert=off] [priority=low|must] [host=...]
   ```
   Set `max_live` (or `rpm` + `run_rpm`) to bound concurrent queue runs, and `run_usd` if the route carries a deployment budget. Use `priority=low` for fleet/batch pools, and `host=...` if the key file only lives on specific machines.

3. **Wire consumers (if dispatched or run headless).**
   - For `fleet-dispatch`: add or update the harness entry in `~/.config/agentctl/harnesses.json` (private overlay) with `"source": "<name>"`, its model map, key file, and (for free or prompt-training providers) `"sandbox"` and `"projects"`.
   - For `agentctl-run`: pass `SOURCE=<name>` in the runner environment so `route_source_room` checks it.

4. **Verify.**
   ```sh
   claude-acct models <name>                          # lists model ids from gateway /v1/models (exit 0)
   claude-acct room --source <name> [--model <id>]    # checks room, deployment budget, and 429 shed state
   claude-acct status                                 # confirms the source row renders alongside accounts
   claude-acct check pace                             # confirms the source is readable and within pace/reserve
   ```

## Usage and check commands

- `claude-acct status [--json]`: every account and source — window used, window gone, run-out, live sessions, 24h dollars, burn, sustainable rate, and the fleet line.
- `claude-acct room [--json]`: automatic-start verdict across Claude accounts; `--source <name> [--model <gateway-model>] [--json]` checks one source (exit `0` room, `1` refused, `2` unread, `3` unknown source).
- `claude-acct models <source>`: model ids a `litellm-key` source may call via `/v1/models` (exit `1` gateway unreadable, `3` not a `litellm-key` row).
- `claude-acct check usage`: live usage read of every Claude account (skips cache; used by the `claude-acct-usage` Sentinel watch).
- `claude-acct check pace`: exits `1` when any source is past its pace line or in its reserve (`alert=off` sources trip only when unread).
- `claude-acct check underuse [source...]`: exits `1` when a paced source resets within `UNDERUSE_HOURS` with use `UNDERUSE_GAP_PCT` points or more below week gone.
- `claude-acct gateway [--out FILE]`: snapshots gateway teams, keys, sources, aliases and fallbacks for the Costs tab's Consumers view.
- `claude-acct textfile [dir]`: writes `claude_acct.prom` on the fleet-lease holder.
