---
name: fleet-runners
description: >-
  Operate agentctl runners (conf, verdicts, why one is failed or BLOCKED, re-run) and read Claude account room (was fleet-accounts). Use for "why is X failed", "runner BLOCKED", "no account has room", "which account has room", "lift the cap".
paths:
  - ".config/agentctl/**"
  - ".local/bin/agentctl*"
  - ".local/src/agent-run/**"
  - ".local/bin/claude-acct"
  - ".local/bin/fleet-dispatch"
  - ".local/src/agent-run/lib/budget.sh"
metadata:
  category: monitoring
  tags: [agentctl, runners, verdicts, budgets, systemd, claude-acct, accounts, pace]
  system: [dispatch]
  reviewed: "2026-11-23"
---

# fleet-runners

An agentctl runner is one `.conf` in `~/.config/agentctl/agents/` that becomes a systemd user unit pair (`agentctl@<name>.service` plus `agentctl-<name>.timer`). This skill is the operator path: read the verdict, find the reason, fix the cause, run it once. The docs own the schema and the catalog; do not copy them here.

## Scope and triggers

- A watch or page says a runner is failed, STALLED or BLOCKED, or `agentctl list` shows it so.
- You must change a runner's conf (schedule, caps, `ENABLED`) or run one by hand.
- A `KIND=call` conf (a judge called from a script) misbehaves.
- A dispatch pass or page says "no account has room", queue items sit queued with free run units, or someone asks which account has headroom, what the run floor is, or what the reserve is ("Account room", below).

Not for a spend alert (`sentinel`), why one queue item is not starting (`fleet-queue`), dispatch selection (`fleet-dispatch`), or machine load and holds (`fleet-pace`).

## Read first

- `~/.config/agentctl/README.md` for the conf schema (KIND oneshot, persistent or call; lane; `EFFECT` none, draft, shadow or acts) and the verdicts. `~/.config/agentctl/PIPELINES.md` for the catalog. `ARCHITECTURE.md` only for design questions.
- Confs live in the private repo (`~/.config/agentctl` is a symlink into `~/.dotfiles-private`), so a conf fix is a private-repo PR (`dotfiles-land`). The scripts are public, in `.local/bin`.

## Steps

1. `agentctl list` shows each runner by lane with state, last verdict, age and next run. A conf that does not parse shows under "invalid"; `agentctl reload` skips it and says why. `PENDING` on a running oneshot is normal.
2. `agentctl status <name>` prints the outcome and its reason. The verdicts are `WORKED NOOP BLOCKED FAILED STALLED`, kept in `~/.local/state/agentctl/<name>/last-outcome`. The agent seeds PENDING at start and promotes it to STALLED if the runner never reports.
3. Read the reason: `tail -n 20 ~/.local/state/agentctl/<name>/activity.log`. A FAILED, STALLED or BLOCKED line ends with `why: <reason>` or `why: unrecorded`. Then `agentctl logs <name>` (merged stdout, stderr, inbox), or `tail -n 40 ~/.local/state/agentctl/<name>.stderr.log`.
4. Map the reason to a cause.
   - `budget: ... (BUDGET_DAY_USD)` or exit 75: a cap stopped the call. `agentctl budget` lists spend against caps. `agentctl budget <name> raise <usd> [calls]` lifts the day cap until midnight; the hour cap (`MAX_CALLS_HOUR`) rises only by the `[calls]` count, so a rate stop needs `raise <usd> <calls>`. A cap is a checkpoint, and the first stop of the day pages once. A runner at its cap reads BLOCKED with a clean unit: a wrapper passes the 75 on and the oneshot drop-in counts it as success, so a failed unit with a budget reason is a wrapper bug.
   - Exit 78: `agentctl-run` refused a role, route or harness. `agentctl-run --agent <name> --explain` prints the resolved invocation and runs nothing; fix the conf.
   - `held_why` file set: a gate holds runnable work (for example dispatch on "no account has room", or an `agent-hold dispatch`, whose reason names who set it). That is BLOCKED by design, not a fault. Find the gate with `fleet-dispatch stopped`.
   - `STALLED`: the runner exited without reporting. Read the stderr log, then fix the script.
5. Fix at the cause: a conf edit (private repo), a script fix (public repo), or a raise for a cap that is too tight for real work. Lowering a lane's budget in its conf is fine.
6. Re-run once: `agentctl start <name>` runs a oneshot now. Confirm `agentctl status <name>` reads WORKED or NOOP and the `held_since` and `held_why` files are gone (a good run clears them).

## Other verbs

- `agentctl stop|restart <name>`; `start` and `restart` refuse `KIND=call` (its caller starts it).
- `agentctl disable <name>` and `enable <name>` write `ENABLED` into the tracked conf and reload, so they dirty the private repo.
- `agentctl pause [reason]` stops every oneshot from starting until `agentctl resume`, except `CRITICAL=yes` ones (the RAM and disk reapers). The `PAUSED` file is under `~/.local/state/agentctl/`.
- `agentctl liveness` exits 1 with one line per runner that is not running at its times (timer not armed, a fire with no run after it, STALLED or FAILED) and for a pause over a day; it is the `fleet-liveness` probe.
- Every named model call is one line in `~/.local/state/agentctl/calls.jsonl`; budgets are computed from it. Defaults: 2 dollars a call, 10 dollars a day, 20 calls an hour.

## Account room (was fleet-accounts)

Automated starts (dispatch, queue sessions, runners) go to a Claude account only when it is under its weekly pace. When none is, a pass says "no account has room" and starts nothing. Spend alerts are `sentinel` (`~/.config/agentctl/SENTINEL.md`, "Spend alerts").

### Read the room

1. `claude-acct room` prints the account dir to use and exits 0. Exit 1 means none has room; exit 2 means none has room and one account is unreadable. When refused, the last stderr line names the closest account, its points over pace, and when it runs out at this rate.
2. `claude-acct status` (or `--json`) is the table: 5H, WEEK, GONE (share of the week elapsed), RUNS-OUT, RESETS, LIVE sessions, 24H-$, ON-PACE, ROOM (ok, or the reason). There is no `pace` verb and no over or under word: the ROOM column is the gate. The hub Fleet and Costs tabs and agent-web print the same verdict from the `claude_account_room*` series, and say `stale` when the textfile is over an hour old (the `claude-acct-usage` timer has stopped).
3. The verdict is each account's `room` object in `claude-acct status --json` and in `claude-acct room --json` (`{pick, why, accounts}`: `pick` is the best account with room, null when none; `why` is the refusal sentence). A `room` object has `ok`, `reason` (`unread`, `capped`, `reserve`, `pace`, `five_hour`, `committed`, or `ok`, the first that refuses), `reasons` (every one, in that order), `why`, `over_points` past the pace line after the slack, `headroom_points` (signed) and `capped`. The rule is written once, in `usage_json`: week used at most week gone plus the slack, week used under 100 minus the reserve, the 5 hour window under 100 minus the reserve, and the working sessions (busy or in a shell; an idle or waiting one spends nothing) not already using the rest of the week. The reserve is kept for the human's own work. An account with an expired token counts as having room, so check `claude-acct check usage` when `status` looks odd. The machine-mode level scales slack and reserve; the mid numbers are in `.config/claude-acct/pace.conf`, read by `claude-acct` only, with no env override. `fleet-dispatch` and `fleet-shepherd` read `room --json` and never re-derive the verdict.
4. Sources that are not Claude accounts (Codex Plus, the LiteLLM keys, the Lazer pool) are rows of `~/.config/claude-acct/sources` (header gives the grammar). `status` lists them below the accounts with the same ROOM verdict; `claude-acct room --source <name>` prints one row's verdict (exit 0 room, 1 refused, 2 unread, 3 no such source); `room` and `pick` stay Claude-only. A dollar budget has no pace line: its reasons are `capped`, `reserve`, `parent` (the pool it spends inside is spent) and `max_live` (live items at the row's cap, `rpm` over `run_rpm` when lower, canaries too); with `--model`, also `route` and `route_pace`. Dispatch reads these through `claude-acct`, never from the gateway or `agent-codex`.
5. Dispatch side: `fleet-dispatch stopped` (add `--json`) and `fleet-dispatch run --dry-run` name every gate in one line each: account room, `fleet-assess` HOLD, load against `DISPATCH_MAX_LOAD`, run units.

### What lifts it

- Time. Pace is a share of the week, so a held account comes back under pace as the week goes by, or when it resets (`RESETS`). Usually that is the only honest fix.
- The run floor. `DISPATCH_RUN_FLOOR` (conf: 15; script default 0) keeps that many run sessions going: while live run sessions plus starts this pass are under it, an account whose only reason is `pace` may start. It does not lift load, a `fleet-assess` HOLD, the reserve, the 5 hour window, committed burn or `agent-hold`. If the floor is already met (`fleet-dispatch headroom`), a pace refusal is expected. Red items have `DISPATCH_RED_FLOOR` (2), which also lifts load and a HOLD; an urgent `from: human` item has a human floor that lifts the pace reason alone.
- A hand start (`cl`, `claude-acct pick`) is told which account is closest and is never refused.
- Another account is a human step: `claude-acct setup-token <name>` mints its token into rbw. There is no /login: renew with `setup-token --renew` (once a year; `claude-acct check tokens` shows expiry), and never edit a credentials file (`docs/operations/claude-acct-tokens.md`).
- "Not logged in" on a session: its account has no setup token, the token expired, or rbw was locked on a machine with no pushed copy. `claude-acct check tokens` names which (hourly `claude-acct-tokens` watch); the fix is `rbw unlock`, `claude-acct token push <host>`, or the human's `setup-token --renew <name>`, then resume the session.
- Runner day caps: `agentctl budget <name> raise <usd> [calls]` (Steps, 4). Read why it was spent first; an over-cap `ask-judge` leaves asks with the human, which is safe, and over-cap dispatch work means sessions do not start.

## Do NOT

- Do not raise the slack or reserve in `.config/claude-acct/pace.conf`, or `DISPATCH_RUN_FLOOR`, to make a refusal go away: they set how much of the week the fleet may spend, the human's call and a conf PR.
- Do not refuse or block `cl`, a hand start or a running session on pace, and do not add a deny or a blanket model downgrade.
- Do not hand-edit account token files or `budget-raise` files; use `claude-acct` and `agentctl budget`.
- Do not start a probe session to see if an account works; `claude-acct check usage` reads usage without one.
- Do not edit `last-outcome`, `activity.log`, `calls.jsonl` or any file in the state dir to turn a runner green. That is runtime state; fix the cause and re-run.
- Do not raise a cap before reading why the spend happened. A raise on a looping runner just spends more.
- Do not call `claude -p` directly to test a runner; go through `agentctl-run`, which applies the budget and the role contract.
- Do not add a pipeline outside `agentctl-run` without a row in `PIPELINES.md` (`tests/unit/pipelines_doc.bats` fails on it).
