# Knowledge schema

_Written by `notes knowledge init` from the template inside the notes binary. Edit the template in the dotfiles repo (`notes-cli/src/knowledge_schema.md`), not this copy._

This is the contract for every article under `knowledge/`. The nightly knowledge engine follows it, and so can you. Articles are compiled: new information is merged into the article it belongs to, and an article gets better over time instead of longer.

## Layout

- `knowledge/<area>/<topic>.md`, one article per topic. Areas are the existing top-level folders (`software/`, `hardware/`, `home/`, `network/`, `business/`, ...). Create a new area only when no existing one fits.
- File names are lowercase slugs: `knowledge/software/infra/litellm-gateway.md`.
- `knowledge/_log/YYYY/MM/YYYY-MM-DD.md` is the engine's log for that date: what it read and what it changed. Logs are never edited.
- `knowledge/_log/originals/<path>` is a copy of a hand-written article taken the first time the engine restructured it.

## Frontmatter

```yaml
---
title: LiteLLM gateway
summary: One line that says what this article answers. It is what the catalog shows.
tags: [software, infra, reference]
created: 2026-10-14
updated: 2026-10-14
reviewed: 2026-10-14
sources: [2026-10-14]
---
```

- `title`, `summary`, `tags` and `updated` are required.
- `sources` lists the `_log` dates that contributed. The engine appends to it, never removes from it.
- `reviewed` is the last date the article was restructured as a whole. The daily curate pass picks the oldest first.

## Body

1. `# <title>`
2. Topic sections (`## Setup`, `## How it works`, `## Gotchas`, ...). New facts go into the section they belong to. Never append a dated "update" paragraph at the bottom.
3. When a new fact contradicts an old one, replace the claim and add `(changed YYYY-MM-DD, was: <old claim>)` after it.
4. `## Open questions` for things the sources raise but do not answer (optional).
5. `## Sources`, one bullet per contributing log: `- [[knowledge/_log/2026/10/2026-10-14]]`.

Keep the claims, numbers, commands, paths and decisions with their reasons. Drop chatter, task lists and anything that is only true for one day.

## Links

- Use plain vault-relative wikilinks with no alias: `[[knowledge/software/infra/litellm-gateway]]`. They resolve from any note.
- Link related articles from inside the sentence that relates them.

## Tags

Use one area tag and one or two kind tags. Add a new tag to this list (in the template) before using it.

Area: `software`, `infra`, `os`, `hardware`, `home`, `network`, `business`, `finance`, `health`, `ai`, `notes`, `work`.

Kind: `reference`, `howto`, `decision`, `concept`, `research`, `troubleshooting`, `project`, `person`.
