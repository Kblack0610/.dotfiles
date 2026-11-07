---
paths:
  - ".claude/skills/**"
  - ".claude/commands/**"
  - ".claude/agents/**"
  - ".local/src/docs/skills.md"
---

# Skill corpus

- The standard for skills, commands and agents is `.local/src/docs/skills.md`, enforced by `skill-drift --lint` through `.github/workflows/skill-lint.yml`, which the private repo and game repos call too.
- New skill: copy `.claude/skills/SKILL-TEMPLATE.md`. `skill-refine` decides what needs changing in an existing one.
