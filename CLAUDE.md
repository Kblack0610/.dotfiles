# dotfiles

Rules for this repo only. Rules that span repos live in `~/.claude/CLAUDE.md`.

## Two repos, both stowed

- This public repo (`~/.dotfiles`) and the private overlay (`~/.dotfiles-private`) are both stowed into `$HOME`. Which repo a file belongs in is decided by the public `.gitignore` (`git check-ignore`) plus a grep for private content, not by taste; `dotfiles-land` routes a change, and `.githooks/sensitive-tokens.txt` is the pre-commit leak scan that backs it. A change that touches both is two PRs, always.
- Rule content is private: the global `CLAUDE.md`, `AGENTS.md` and the rulesync tree all live in `~/.dotfiles-private`. The `update-rules` skill picks the layer and runs the sync.
- Stow links point at the main checkout, so edits made in a worktree are NOT deployed. Run a script by its path inside the worktree, and do not assume the one on PATH is the one you just edited.
- This file is in `.stow-local-ignore`, like `AGENTS.md`. Deployed to `~/CLAUDE.md`, it would load into every session under `$HOME`.

## Operating model

- Shared rules and MCP definitions for non-Claude tools: `~/.dotfiles-private/.config/rulesync-global/`, fanned out by `.config/codex/sync-ai-global-config.sh` (it skips Claude by design).
- Machine-local runtime state stays in each tool's home (`~/.codex`, `~/.claude`, `~/.gemini`, `~/.config/opencode`), and agent runtime state in `~/.agent/`, never in this tree.

## Skill corpus

- Skills live at `.claude/skills/<category>/<name>/SKILL.md` in one of the two repos; `skill-deploy` flattens them into `~/.claude/skills/<name>/`, which is the ONLY path anything else should reference. A repo path breaks on re-categorisation and on a move between repos.
- Frontmatter is `name`, `description`, and `metadata.{category,tags,reviewed}`; CI enforces it (`skill-drift --lint`). There is no version field on purpose: git answers "what changed", `reviewed` answers "when was this last checked true".
- New skill: copy `.claude/skills/SKILL-TEMPLATE.md`. `skill-refine` decides what needs changing in an existing one.

## Agent runtime

- Session evals are deterministic, never a model's score of a transcript. `agentctl-session-outcomes` records each session nightly in `~/.agent/outcomes/{project}/` from transcript structure, git and gh, and the `fleet-bench` scorecard turns those into KPIs; `agentctl-session-outcomes worst` lists the sessions to look at first. Why: the per-Stop LLM judge (retired 2026-10-28) failed on 59% of turns in 30 days and scored 78% of the rest 10/10. `~/.agent/evals/` is its read-only archive.
- Automated lanes run on budgets and stop themselves at them; human sessions get alerts. A runner's conf sets `BUDGET_CALL_USD` (claude's `--max-budget-usd` on each print call), `BUDGET_DAY_USD` and `MAX_CALLS_HOUR`, which `agentctl-run` checks against `calls.jsonl` before the call (lib/budget.sh, defaults $2, $10, 20; over one it reports BLOCKED and exits 75; `tests/integ/agent_run_budget.bats`). A cap is a checkpoint: the first stop of the day pages once, and `agentctl budget <name> raise <usd>` lifts that name's caps until midnight; `agentctl budget` lists spend against each. A queue session is held to its item's budget by `#size/` tag (`FLEET_SHEPHERD_BUDGET_*`, $12/$25/$50, unsized $25) as checkpoints: the shepherd lets one still WORKING carry on to 3x and parks one stalled or past that, paging once (`tests/integ/fleet_shepherd.bats`). A `fleet-dispatch run` pass starts only on an account `claude-acct room` says is under its weekly pace, except up to `DISPATCH_RUN_FLOOR` run sessions, which the pace and idle gates do not hold (`tests/unit/fleet_dispatch.bats` "run floor"). Spend is watched by the `claude-spend-hourly`, `claude-spend-daily`, `claude-acct-usage` and `claude-account-pace` Sentinel watches, per-session fan-out by `spawn-watch.sh`, and a hand-started session's spend by `stop-post.d/90-session-spend.sh` (`CLAUDE_SESSION_ALERT_USD`, $60, then 2x, 4x; `tests/unit/session_spend.bats`) (runbook: `~/.config/agentctl/SENTINEL.md` "Spend alerts"). Do not refuse `cl`, a hand start or a running session, or add a deny or a blanket model or effort downgrade; choosing a model per task by the `model-lane` skill is fine, and so is lowering a lane's budget in its conf. Why: the human asked for alerts only so that limits never cut off their own work (2026-10-20), then for unattended starts to fit what the accounts can sustain (2026-11-01), then for a computed budget on every automated call so no lane overspends (2026-11-05).
- Every pipeline is catalogued from its source: a runner's trigger, model and `EFFECT` live in its conf (`agentctl list --md`), and a systemd timer, path unit or model call outside `agentctl-run` gets a row in `~/.config/agentctl/PIPELINES.md`. `tests/unit/pipelines_doc.bats` fails on a missing or dead row. Why: no doc listed every pipeline, and the hand-kept table in the 2026-11 architecture review went stale in two days.
- Memory consolidation: `nightly-sync` (23:00) ingests notes into mem0, `dream` (03:00) promotes durable signal into lessons and `memory/` plus a human-gated `mem0-queue.md`, and `lab-sync` (weekly) mirrors git and `~/.agent` into the lab bus. Runbook: `~/.config/agentctl/DREAMING.md`.
