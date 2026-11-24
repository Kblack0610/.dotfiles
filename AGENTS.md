# dotfiles

Rules for this repo only, read by every CLI (Claude imports this file from `CLAUDE.md`; Codex, opencode and agy read it directly). Which layer any other rule goes in, and the sync, is the `update-rules` skill.

## Two repos, both stowed

- This public repo (`~/.dotfiles`) and the private overlay (`~/.dotfiles-private`) are both stowed into `$HOME`. Which repo a file belongs in is decided by the public `.gitignore` (`git check-ignore`) plus a grep for private content, not by taste; `dotfiles-land` routes a change, and `.githooks/sensitive-tokens.txt` is the pre-commit leak scan that backs it. The private repo has its own pre-commit, a secret scan (`.githooks/secret-patterns.txt`), wired by `setup_dotfiles_private`. A change that touches both is two PRs, always.
- Global rule content is private: the global `CLAUDE.md`, the private repo's own `AGENTS.md` and the rulesync tree all live in `~/.dotfiles-private`.
- Stow links point at the main checkout, so edits made in a worktree are NOT deployed. Run a script by its path inside the worktree, and do not assume the one on PATH is the one you just edited.
- This file and `CLAUDE.md` are in `.stow-local-ignore`. Deployed to `~/AGENTS.md` or `~/CLAUDE.md`, they would load into every session under `$HOME`.

## Operating model

- Shared rules and MCP definitions for non-Claude tools: `~/.dotfiles-private/.config/rulesync-global/`, fanned out by `.config/codex/sync-ai-global-config.sh` to Codex, Gemini, opencode and agy (it skips Claude by design).
- Machine-local runtime state stays in each tool's home (`~/.codex`, `~/.claude`, `~/.gemini`, `~/.config/opencode`), and agent runtime state in `~/.agent/`, never in this tree.

## Path-scoped rules

- `.claude/rules/agent-runtime.md` (agentctl, fleet-*, budgets, pipelines, outcomes, dream) and `.claude/rules/skill-corpus.md` (skills, commands, agents) load on their own only in Claude; any other CLI working in those parts reads them first.

## Tests: CI is the gate

- An agent session never runs a test on the workstation: the PR's CI run of what `tests/pick.sh` picks is the test run, and `agent-land` waits for it (the `shell-test-harness` skill; its `metadata.replaces` rows are the guard `hand_methods.py` applies). Why: agent bats runs held the workstation at load 40 and held dispatch (2026-11-23, ar-4846).

## Hard limits on budgets

- Do not refuse `cl`, a hand start or a running session, or add a deny or a blanket model or effort downgrade; choosing a model per task by the `model-lane` skill is fine, and so is lowering a lane's budget in its conf. Why: the human's asks (2026-10-20, 11-01, 11-05): limits never cut off their own work, and every automated call runs on a computed budget so no lane overspends. The budget mechanism is in `.claude/rules/agent-runtime.md`.
