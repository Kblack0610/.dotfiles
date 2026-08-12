---
name: <skill-name>
description: <What it does AND when to use it, key use case first. Include the trigger phrases a user would actually type. Say what it is NOT for and which sibling skill covers that instead - the router picks between 60 of these on description alone. Hard cap 1536 chars: past that the tail is silently truncated away, so do not let the "differs from" clause be the part that gets cut.>
metadata:
  category: <authoring|memory|messaging|monitoring|ops|reference|research|tickets|workstreams>
  tags: [<tag>, <tag>]
  reviewed: "<YYYY-MM-DD>"
---

# <Skill Title>

<One paragraph: what problem this solves and what outcome it produces. Concrete, not aspirational.>

## When to Use

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

Copy it to `.claude/skills/<category>/<skill-name>/SKILL.md` in **one** of the two repos, then
delete this trailing section.

**Which repo.** The filesystem decides, never taste. Run the token list over your draft:
anything matching `.githooks/sensitive-tokens.txt` (client names, private hostnames, internal
IPs) goes in `~/.dotfiles-private`; everything else can be public, and public also needs a
line adding to the `.gitignore` allowlist. See the `dotfiles-land` skill.

**Deploying.** `skill-deploy` links it into `~/.claude/skills/<name>/`, flat. Categories exist
in the repo only - Claude Code reads personal skills one level down, so the deployed tree
cannot be nested. Never hand-write a symlink, and never reference a skill by its **repo** path
from anything else: use `~/.claude/skills/<name>/`, which survives re-categorisation and a move
between the two repos.

**Frontmatter.** The four keys above are required and CI enforces them (`skill-drift --lint`).
There is deliberately **no version field** - git answers "what changed when" per skill, and
`reviewed` answers the thing git cannot: when someone last checked these instructions still
match reality. Bump `reviewed` only when you have actually verified that, not when you edit a
typo. A date that lies is worse than a date that is old.

`status: draft` plus `disable-model-invocation: true` keeps an unfinished skill out of the
model's context entirely, so it costs nothing and cannot misfire. Absent means stable.

**House rules.** Plain ASCII only - no em/en dash, arrows, ellipsis, `>=`/`<=` glyphs. Keep
SKILL.md under 500 lines and push detail into `references/`; the body stays in context for the
rest of the session once loaded, so every line is a recurring cost. Supporting files go in
`references/` (docs the agent reads on demand), `assets/` (templates it copies) or a script
beside SKILL.md.

**Before you open the PR.** `skill-drift --lint .` locally, and check the PR template's skills
checklist.
