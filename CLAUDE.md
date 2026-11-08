# dotfiles

Rules for this repo only. Rules that span repos live in `~/.claude/CLAUDE.md`.

## Two repos, both stowed

- This public repo (`~/.dotfiles`) and the private overlay (`~/.dotfiles-private`) are both stowed into `$HOME`. Which repo a file belongs in is decided by the public `.gitignore` (`git check-ignore`) plus a grep for private content, not by taste; `dotfiles-land` routes a change, and `.githooks/sensitive-tokens.txt` is the pre-commit leak scan that backs it. The private repo has its own pre-commit, a secret scan (`.githooks/secret-patterns.txt`), wired by `setup_dotfiles_private`. A change that touches both is two PRs, always.
- Rule content is private: the global `CLAUDE.md`, `AGENTS.md` and the rulesync tree all live in `~/.dotfiles-private`. The `update-rules` skill picks the layer and runs the sync.
- Stow links point at the main checkout, so edits made in a worktree are NOT deployed. Run a script by its path inside the worktree, and do not assume the one on PATH is the one you just edited.
- This file is in `.stow-local-ignore`, like `AGENTS.md`. Deployed to `~/CLAUDE.md`, it would load into every session under `$HOME`.

## Operating model

- Shared rules and MCP definitions for non-Claude tools: `~/.dotfiles-private/.config/rulesync-global/`, fanned out by `.config/codex/sync-ai-global-config.sh` (it skips Claude by design).
- Machine-local runtime state stays in each tool's home (`~/.codex`, `~/.claude`, `~/.gemini`, `~/.config/opencode`), and agent runtime state in `~/.agent/`, never in this tree.

## Path-scoped rules

- Rules for one part of this repo live in `.claude/rules/*.md`, whose `paths:` frontmatter loads each only when a session reads or edits a matching file: `agent-runtime.md` (agentctl, fleet-*, budgets, pipelines, outcomes, dream) and `skill-corpus.md` (skills, commands, agents). This file keeps only what every session here needs. `.claude/rules` is in `.stow-local-ignore`, because stowed it would load as user rules in every project; `tests/unit/claude_rules.bats` checks each glob still matches a file. Why: this file loads on every turn here, and most of it applied to one subtree.

## Hard limits on budgets

- Do not refuse `cl`, a hand start or a running session, or add a deny or a blanket model or effort downgrade; choosing a model per task by the `model-lane` skill is fine, and so is lowering a lane's budget in its conf. Why: the human's asks (2026-10-20, 11-01, 11-05): limits never cut off their own work, and every automated call runs on a computed budget so no lane overspends. The budget mechanism is in `.claude/rules/agent-runtime.md`.
