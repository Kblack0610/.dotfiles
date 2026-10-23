---
name: night-shift
description: Queue agent tasks during the day to run unattended overnight, then read what happened in the morning. Each queued task becomes one headless `/one-shot --pr-only` run at 01:00 (agentctl runner `night-shift`), one at a time, deciding its own questions with its own recommendation and stopping at an open PR. Hard gates go to `agent-ask` for the morning. Use when the user says "do this tonight", "run it overnight", "queue this for later", "have agents work on it while I sleep", "what did the night shift do", "show me the overnight agents", or "/night-shift queue|list|report|cancel". The live view is tmux prefix M-n. Other skills cover the neighbours: a task to run now is `one-shot`, a batch of tracker tickets is `/captain`, a release is `release-coordinator`, and watching a running wave is `wave-overseer`.
metadata:
  category: workstreams
  tags: [delivery, autonomy, scheduling, overnight]
  reviewed: "2026-10-22"
---

# night-shift

Turns "do this tonight" into a queued task that runs while the human sleeps and leaves a result they can read over coffee. The task procedure (worktree, gate, PR, board row, wind-down note) is `one-shot`'s. This skill only queues tasks, runs them one at a time, and reports. Everything goes through the `night-shift` CLI (`~/.local/bin/night-shift --help`).

## When to Use

- The user hands over work and wants it done later tonight.
- The user asks what the overnight agents did, or wants to see them.

Not for work to do right now (`one-shot`), a ticket batch (`/captain`), or anything that must merge or deploy unattended. A night-shift run always stops at the PR.

## Steps

### queue

1. Write the task as the brief a fresh agent will get with nobody to ask: the goal, the plan file if there is one (`~/.agent/plans/<project>/...`), the merge gate to run, and what "done" means. A task that only makes sense with this conversation's context will come back `blocked` or wrong.
2. `night-shift queue <repo> "<brief>" --slug <short-name> --project <ptask project>`. Add `--after <slug>` when the task depends on another one: it runs only if that one ended `ok`. Use `--data-class work` for client work (the route interlock refuses personal data on a client route). `--model` and `--max-turns` override the runner defaults.
3. Say what will happen before bed: the timer fires at 01:00, the human's own prerequisites (installs, logins, editor closed) need doing first, and `prefix M-n` shows it live. Do not add an agent-board row yourself: one-shot adds and closes its own.

### list / report / cancel

- `night-shift list` is the TSV of queued, running and the latest night's results. `night-shift report [date]` gives the same night as markdown, which is what to paste back to the user.
- `night-shift cancel <slug>` drops a task that has not started.
- For each `blocked` or `failed` row, read `~/.agent/night/done/<night>/<slug>.result.md`. Its header has `session:`, so `claude --resume <id>` from the repo continues the run, and `log:` points at the readable transcript. Pending questions are in `agent-ask list --all --pending`.

### The morning view

- The 06:45 briefing (daily note refs) has a `Night shift` section, and a `blocked` or `failed` task also appears under Needs you.
- tmux `prefix M-n` opens the `night-shift` session. The top pane is the board, the bottom pane follows the running task's log, and both redraw on file events.

## How a run works

`agentctl` fires `night-shift run` at 01:00 (`~/.config/agentctl/agents/night-shift.conf`). With an empty queue it publishes NOOP and spends no tokens. Otherwise it takes tasks in queue order under a `flock`, and for each one:

- `queue/<stamp>-<slug>.md` moves to `running/`. The file is `key: value` lines (slug, repo, project, after, data_class, model, max_turns), then `---`, then the brief.
- It runs `agentctl-run --role build` with `/one-shot --pr-only <brief>`, plus the overnight rules: decide reversible forks yourself and log `assumed:`, do not merge, post hard gates with `agent-ask`, and end with a `NIGHT-SHIFT-RESULT` block. Output is stream-json, saved to `<slug>.jsonl` and formatted into `<slug>.log` under `~/.local/state/agentctl/night-shift/`. A 5h timeout guards each task.
- The result block becomes `done/<night>/<slug>.result.md` (status ok|blocked|failed|skipped, pr, asks, summary, exit, session, log, then the final text). If the block is missing, the status is `failed`, never `ok`.
- A task left in `running/` by a crash or reboot is reported `failed` (interrupted) on the next run.

## Do NOT

- Queue anything that must merge, deploy, tag, rotate secrets or message people. The run stops at the PR by design, and those are the human's gates.
- Queue a task that depends on another one without `--after`. Both would run, the second on a base that is not ready.
- Read `ok` as merged. It means a PR is open and its gate passed. The human still reviews and merges.
- Add a timer, a poll loop or a second scheduler for this. The agentctl conf is the only schedule, and `agentctl list` and the cockpit already show it.
