---
name: fleet-runners
description: >-
  Operate agentctl runners: conf, list, verdicts, why one is failed or BLOCKED, fix and re-run. Use for "why is X failed", "runner BLOCKED", "re-run a runner", "inbox-plan failed". Day caps: fleet-accounts.
paths:
  - ".config/agentctl/**"
  - ".local/bin/agentctl*"
  - ".local/src/agent-run/**"
metadata:
  category: monitoring
  tags: [agentctl, runners, verdicts, budgets, systemd]
  reviewed: "2026-11-06"
---

# fleet-runners

An agentctl runner is one `.conf` in `~/.config/agentctl/agents/` that becomes a systemd user unit pair (`agentctl@<name>.service` plus `agentctl-<name>.timer`). This skill is the operator path: read the verdict, find the reason, fix the cause, run it once. The docs own the schema and the catalog; do not copy them here.

## Scope and triggers

- A watch or page says a runner is failed, STALLED or BLOCKED, or `agentctl list` shows it so.
- You must change a runner's conf (schedule, caps, `ENABLED`) or run one by hand.
- A `KIND=call` conf (a judge called from a script) misbehaves.

Not for a spend alert (`sentinel`), a day cap you want lifted for an account (`fleet-accounts`), or machine load (`fleet-pace`).

## Read first

- `~/.config/agentctl/README.md` for the conf schema (KIND oneshot, persistent or call; lane; `EFFECT` none, draft, shadow or acts) and the verdicts. `~/.config/agentctl/PIPELINES.md` for the catalog. `ARCHITECTURE.md` only for design questions.
- Confs live in the private repo (`~/.config/agentctl` is a symlink into `~/.dotfiles-private`), so a conf fix is a private-repo PR (`dotfiles-land`). The scripts are public, in `.local/bin`.

## Steps

1. `agentctl list` shows each runner by lane with state, last verdict, age and next run. A conf that does not parse shows under "invalid"; `agentctl reload` skips it and says why. `PENDING` on a running oneshot is normal.
2. `agentctl status <name>` prints the outcome and its reason. The verdicts are `WORKED NOOP BLOCKED FAILED STALLED`, kept in `~/.local/state/agentctl/<name>/last-outcome`. The agent seeds PENDING at start and promotes it to STALLED if the runner never reports.
3. Read the reason: `tail -n 20 ~/.local/state/agentctl/<name>/activity.log`. A FAILED, STALLED or BLOCKED line ends with `why: <reason>` or `why: unrecorded`. Then `agentctl logs <name>` (merged stdout, stderr, inbox), or `tail -n 40 ~/.local/state/agentctl/<name>.stderr.log`.
4. Map the reason to a cause.
   - `budget: ... (BUDGET_DAY_USD)` or exit 75: a cap stopped the call. `agentctl budget` lists spend against caps. `agentctl budget <name> raise <usd> [calls]` lifts the day cap until midnight; the hour cap (`MAX_CALLS_HOUR`) rises only by the `[calls]` count, so a rate stop needs `raise <usd> <calls>`. A cap is a checkpoint, and the first stop of the day pages once.
   - Exit 78: `agentctl-run` refused a role, route or harness. `agentctl-run --agent <name> --explain` prints the resolved invocation and runs nothing; fix the conf.
   - `held_why` file set: a gate holds runnable work (for example dispatch on "no account has room"). That is BLOCKED by design, not a fault. Find the gate with `fleet-dispatch stopped`.
   - `STALLED`: the runner exited without reporting. Read the stderr log, then fix the script.
5. Fix at the cause: a conf edit (private repo), a script fix (public repo), or a raise for a cap that is too tight for real work. Lowering a lane's budget in its conf is fine.
6. Re-run once: `agentctl start <name>` runs a oneshot now. Confirm `agentctl status <name>` reads WORKED or NOOP and the `held_since` and `held_why` files are gone (a good run clears them).

## Other verbs

- `agentctl stop|restart <name>`; `start` and `restart` refuse `KIND=call` (its caller starts it).
- `agentctl disable <name>` and `enable <name>` write `ENABLED` into the tracked conf and reload, so they dirty the private repo.
- `agentctl pause [reason]` stops every oneshot from starting until `agentctl resume`. The `PAUSED` file is under `~/.local/state/agentctl/`.
- Every named model call is one line in `~/.local/state/agentctl/calls.jsonl`; budgets are computed from it. Defaults: $2 a call, $10 a day, 20 calls an hour.

## Do NOT

- Do not edit `last-outcome`, `activity.log`, `calls.jsonl` or any file in the state dir to turn a runner green. That is runtime state; fix the cause and re-run.
- Do not raise a cap before reading why the spend happened. A raise on a looping runner just spends more.
- Do not call `claude -p` directly to test a runner; go through `agentctl-run`, which applies the budget and the role contract.
- Do not add a pipeline outside `agentctl-run` without a row in `PIPELINES.md` (`tests/unit/pipelines_doc.bats` fails on it).
