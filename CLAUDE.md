@AGENTS.md

## Path-scoped rules (Claude only)

- Rules for one part of this repo live in `.claude/rules/*.md`, whose `paths:` frontmatter loads each only when a session reads or edits a matching file: `agent-runtime.md` (agentctl, fleet-*, budgets, pipelines, outcomes, dream) and `skill-corpus.md` (skills, commands, agents). `AGENTS.md` keeps only what every session here needs. `.claude/rules` is in `.stow-local-ignore`, because stowed it would load as user rules in every project; `tests/unit/claude_rules.bats` checks each glob still matches a file. Why: `AGENTS.md` loads on every turn here, and most of this applied to one subtree.
