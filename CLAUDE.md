# dotfiles

Rules for this repo only. Rules that span repos live in `~/.claude/CLAUDE.md`.

## Two repos, both stowed

- This public repo (`~/.dotfiles`) and the private overlay (`~/.dotfiles-private`) are both stowed into `$HOME`. Which repo a file belongs in is decided by `.githooks/sensitive-tokens.txt`, not by taste; `dotfiles-land` routes a change. A change that touches both is two PRs, always.
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
- Usage guards alert, and the one thing that waits on usage is an automatic start: a `fleet-dispatch run` pass starts only on an account `claude-acct room` says is under its weekly pace. Spend is watched by the `claude-spend-hourly`, `claude-spend-daily`, `claude-acct-usage` and `claude-account-pace` Sentinel watches and per-session fan-out by `spawn-watch.sh` (runbook: `~/.config/agentctl/SENTINEL.md` "Spend alerts"). Do not refuse `cl`, a hand start or a running session, or add a deny, a `--max-budget-usd`, a skipped scheduled run, or a blanket model or effort downgrade; choosing a model per task by the `model-lane` skill is fine. Why: the human asked for alerts only so that limits never cut off important work (2026-10-20), then for unattended starts to be limited to what the accounts can sustain (2026-11-01).
- Memory consolidation: `nightly-sync` (23:00) ingests notes into mem0, `dream` (03:00) promotes durable signal into lessons and `memory/` plus a human-gated `mem0-queue.md`, and `lab-sync` (weekly) mirrors git and `~/.agent` into the lab bus. Runbook: `~/.config/agentctl/DREAMING.md`.
