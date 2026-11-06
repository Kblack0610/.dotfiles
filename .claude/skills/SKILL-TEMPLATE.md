---
name: <skill-name>
description: >-
  <A trigger line: what it is in a few words, the main "use when" phrases a user would type, and the one sibling it is not. Detail goes in the body.>
metadata:
  category: <authoring|memory|messaging|monitoring|ops|reference|research|tickets|workstreams>
  tags: [<tag>, <tag>]
  reviewed: "<YYYY-MM-DD>"
---

# <Skill Title>

<One paragraph: what problem this solves and what outcome it produces. Concrete, not aspirational.>

## Scope and triggers

- When <specific, matchable scenario>
- When <another>

Not for <adjacent case> - that is `<sibling-skill>`.

## Steps

1. <What to do, and how. An agent follows this literally.>
2. <...>

## Do NOT

- <The mistake this skill exists to prevent, and why it is a mistake.>

---

## How to use this template

Copy it to `.claude/skills/<category>/<skill-name>/SKILL.md`, in the repo the `dotfiles-land` skill picks, then delete this trailing section. A new public skill also needs a line in the `.gitignore` allowlist. Run `skill-deploy` to link it, and never hand-write the symlink.

**House rules.** `~/.local/src/docs/skills.md` is the standard: frontmatter, the description budget, `reviewed`, the required heading, body size, ASCII. `skill-drift --lint .` checks what it can, and CI runs the same command.
