---
name: fleet-accounts
description: >-
  Claude account room and weekly pace: claude-acct room and status, "no account has room", the run floor, agentctl budget raise. Use for "why is dispatch blocked", "which account has room", "lift the cap". Spend alerts: sentinel.
paths:
  - ".local/bin/claude-acct"
  - ".local/bin/fleet-dispatch"
  - ".config/agentctl/agents/fleet-dispatch.conf"
  - ".local/src/agent-run/lib/budget.sh"
metadata:
  category: monitoring
  tags: [claude-acct, accounts, pace, budget, dispatch]
  reviewed: "2026-11-06"
---

# fleet-accounts

Automated starts (dispatch, queue sessions, runners) go to a Claude account only when it is under its weekly pace. When none is, a pass says "no account has room" and starts nothing. This skill reads that refusal and says what lifts it. Dispatch selection stays in `fleet-dispatch`, CPU load and holds in `fleet-pace`, spend alerts in `sentinel` (runbook `~/.config/agentctl/SENTINEL.md`, "Spend alerts").

## Scope and triggers

- A dispatch pass or page says "no account has room", or queue items sit queued with free run units.
- You must pick which account has headroom, or lift a runner's day cap.
- Someone asks what the run floor or the reserve is.

Not for a runner's own failure (`fleet-runners`) or why one queue item is not starting (`fleet-queue`).

## Read the room

1. `claude-acct room` prints the account dir to use and exits 0. Exit 1 means none has room; exit 2 means none has room and one account is unreadable. When refused, the last stderr line names the closest account, its points over pace, and when it runs out at this rate.
2. `claude-acct status` (or `--json`) is the table: 5H, WEEK, GONE (share of the week elapsed), PACE (points over or under), RUNS-OUT, RESETS, LIVE sessions, 24H-$. There is no `pace` verb; pace is that column and the `room` rule.
3. The rule, per account: week used at most week gone plus the slack (`CLAUDE_ACCT_PACE_SLACK_PCT`, 5), week used under 100 minus the reserve (`CLAUDE_ACCT_RESERVE_PCT`, 15), and the 5 hour window under 100 minus the reserve. The reserve is kept for the human's own work. An account with an expired token counts as having room, so check `claude-acct check usage` when `status` looks odd. The machine-mode level scales slack and reserve. Both are set in `~/.config/agentctl/agents/fleet-dispatch.conf`.
4. For the dispatch side run `fleet-dispatch stopped` (add `--json` for a parse) and `fleet-dispatch run --dry-run`. They name every gate in one line each: account room, `fleet-assess` HOLD, load against `DISPATCH_MAX_LOAD`, the idle floor, run units. "Clears when an account is back under its pace" is the line for this gate.

## What lifts it

- Time. Pace is a share of the week, so a held account comes back under pace as the week goes by, or when its week resets (`RESETS`). Usually that is the only honest fix.
- The run floor. `DISPATCH_RUN_FLOOR` (conf: 2; script default 0) keeps that many run sessions going: while live run sessions plus starts this pass are under it, the weekly pace slack and the idle gate do not hold a start. It does not lift load, a `fleet-assess` HOLD, the reserve, the 5 hour window or `agent-hold`. If the floor is already met (`fleet-dispatch headroom` prints it), a pace refusal is expected. Red items have a floor of their own, `DISPATCH_RED_FLOOR` (2), which also lifts load and a `fleet-assess` HOLD (fleet-dispatch skill, "A pass").
- A hand start (`cl`, `claude-acct pick`) is told which account is closest and is never refused. The human's own work is not gated by pace.
- Another account: `claude-acct status` shows who has room. Adding an account is a human login step, not an agent task.

## Runner caps

- `agentctl budget` lists each named runner's spend against its caps for today.
- `agentctl budget <name> raise <usd> [calls]` writes `<name>/budget-raise`, which lifts that runner's day cap until midnight. The hour cap rises only by `[calls]` (default 0), so a rate stop needs `raise <usd> <calls>`. The per-call cap has no raise. Defaults are $2 a call, $10 a day, 20 calls an hour; a conf sets `BUDGET_CALL_USD`, `BUDGET_DAY_USD`, `MAX_CALLS_HOUR`.
- Read why it was spent (`fleet-runners`, "Steps" 3 and 4) before a raise. An over-cap `ask-judge` leaves asks with the human, which is safe. Over-cap dispatch work means sessions do not start.

## Do NOT

- Do not raise `CLAUDE_ACCT_PACE_SLACK_PCT`, the reserve or `DISPATCH_RUN_FLOOR` to make a refusal go away. They set how much of the week the fleet may spend; changing one is the human's call and a private-repo conf PR.
- Do not refuse or block `cl`, a hand start or a running session on pace, and do not add a deny or a blanket model downgrade.
- Do not hand-edit account token files or `budget-raise` files. Use `claude-acct` and `agentctl budget`.
- Do not start a probe session to see if an account works; `claude-acct check usage` reads usage without one.
