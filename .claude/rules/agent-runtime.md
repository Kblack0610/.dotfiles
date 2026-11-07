---
paths:
  - ".local/bin/agentctl*"
  - ".local/bin/agent-queue"
  - ".local/bin/fleet-*"
  - ".local/bin/claude-acct"
  - ".local/lib/session-outcomes.sh"
  - ".local/src/agent-run/**"
  - ".config/systemd/user/**"
  - ".config/fleet-bench/**"
  - ".config/claude-acct/**"
  - ".claude/hooks/spawn-watch.sh"
  - ".claude/hooks/stop-post.d/90-session-spend.sh"
  - "tests/**/agent_*.bats"
  - "tests/**/agentctl_*.bats"
  - "tests/**/fleet_*.bats"
  - "tests/unit/session_*.bats"
  - "tests/unit/pipelines_doc.bats"
---

# Agent runtime

- Session evals are deterministic, never a model's score of a transcript. `agentctl-session-outcomes` records each session nightly in `~/.agent/outcomes/{project}/` from transcript structure, git and gh, and the `fleet-bench` scorecard turns those into KPIs; `agentctl-session-outcomes worst` lists the sessions to look at first, and `agentctl-session-outcomes lessons` says whether a lesson with a sig changed behaviour. Why: the per-Stop LLM judge (retired 2026-10-28) failed on 59% of turns in 30 days and scored 78% of the rest 10/10. `~/.agent/evals/` is its read-only archive.
- Automated lanes run on budgets and stop themselves at them; human sessions get alerts. A runner's conf sets `BUDGET_CALL_USD` (claude's `--max-budget-usd` on each print call), `BUDGET_DAY_USD` and `MAX_CALLS_HOUR`, which `agentctl-run` checks against `calls.jsonl` before the call (lib/budget.sh, defaults $2, $10, 20; over one it reports BLOCKED and exits 75; `tests/integ/agent_run_budget.bats`). A cap is a checkpoint: the first stop of the day pages once, and `agentctl budget <name> raise <usd>` lifts that name's caps until midnight; `agentctl budget` lists spend against each. A queue session is held to its item's budget by `#size/` tag (`FLEET_SHEPHERD_BUDGET_*`, $12/$25/$50, unsized $25) as checkpoints: the shepherd lets one still WORKING carry on to 3x and parks one stalled or past that, paging once (`tests/integ/fleet_shepherd.bats`). A `fleet-dispatch run` pass starts only on an account `claude-acct room` says is under its weekly pace, except up to `DISPATCH_RUN_FLOOR` run sessions, which the pace and idle gates do not hold, and up to `DISPATCH_RED_FLOOR` red items, which load and `fleet-assess` do not hold either (`tests/unit/fleet_dispatch.bats` "run floor"). Spend is watched by the `claude-spend-hourly`, `claude-spend-daily`, `claude-acct-usage` and `claude-account-pace` Sentinel watches, per-session fan-out by `spawn-watch.sh`, and a hand-started session's spend by `stop-post.d/90-session-spend.sh` (`CLAUDE_SESSION_ALERT_USD`, $60, then 2x, 4x; `tests/unit/session_spend.bats`) (runbook: `~/.config/agentctl/SENTINEL.md` "Spend alerts"). The hard limits on what a budget may do are in the repo `CLAUDE.md`.
- Every pipeline is catalogued from its source: a runner's trigger, model and `EFFECT` live in its conf (`agentctl list --md`), and a systemd timer, path unit or model call outside `agentctl-run` gets a row in `~/.config/agentctl/PIPELINES.md`. `tests/unit/pipelines_doc.bats` fails on a missing or dead row. Why: no doc listed every pipeline, and the hand-kept table in the 2026-11 architecture review went stale in two days.
- Memory consolidation: `nightly-sync` (23:00) ingests notes into mem0, `dream` (03:00) promotes durable signal into lessons and `memory/` and proposes facts about the human for mem0 on Home (`agent-propose`, accept posts), and `lab-sync` (weekly) mirrors git and `~/.agent` into the lab bus. Runbook: `~/.config/agentctl/DREAMING.md`.
