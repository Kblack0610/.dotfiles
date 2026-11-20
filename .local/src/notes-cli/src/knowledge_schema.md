# Knowledge schema

_Written by `notes knowledge init` and `notes knowledge domain add` from the template inside the notes binary and the registry `knowledge/domains.toml`. Edit the template in the dotfiles repo (`notes-cli/src/knowledge_schema.md`) or add a domain with `notes knowledge domain add`, never this copy._

This is the contract for every article under `knowledge/`. The nightly knowledge engine follows it, and so can you. Articles are compiled: new information is merged into the article it belongs to, and an article gets better over time instead of longer.

## Layout

- `knowledge/<domain>/<topic>.md`, one article per topic, under one of the registered domains below. A new page anywhere else is refused. When nothing below fits, a new domain is registered first (`notes knowledge domain add <id> "<what belongs there>"`); it is never invented in a path.
- The kinds of domain:
  - `core/<x>`: how we work across every project. Each core page links its domain's canonical doc and holds only what we learned that the doc does not say.
  - `subjects/<x>`: anything researched, in any field.
  - `projects/<p>`: only what is true of that one project. A project page links the core hub it builds on and never restates a core topic.
  - `references`: one digest page per external source: its link and what matters in it.
- Each domain has a hub, `knowledge/<domain>/index.md`. Its `## Repo docs` section is generated (links to the repo docs exported to `.repos/` and routed to the domain): leave it as it is.
- File names are lowercase slugs that name the topic: `knowledge/subjects/software/litellm-gateway.md`. A slug with a date in it is refused; a date belongs in the body.
- `knowledge/_log/YYYY/MM/YYYY-MM-DD.md` is the engine's log for that date: what it read and what it changed. Logs are never edited.
- `knowledge/_log/originals/<path>` is a copy of a hand-written article taken the first time the engine restructured it.

## Domains

{{domains}}
## Frontmatter

```yaml
---
title: LiteLLM gateway
summary: One line that says what this article answers. It is what the catalog shows.
tags: [software, reference]
created: 2026-10-14
updated: 2026-10-14
reviewed: 2026-10-14
sources: [journal/daily/2026-10-14.md, journal/refs/2026-10-14/gateway.md]
---
```

- `title`, `summary`, `tags` and `updated` are required.
- `sources` lists the vault paths of the journal and ref notes the article was compiled from. Every vault source an op cites must be listed. The engine appends to it, never removes from it.
- `reviewed` is the last date the article was restructured as a whole. The daily curate pass picks the oldest first.

## Body

1. `# <title>`
2. Topic sections (`## Setup`, `## How it works`, `## Gotchas`, ...). New facts go into the section they belong to. Never append a dated "update" paragraph at the bottom.
3. When a new fact contradicts an old one, replace the claim and add `(changed YYYY-MM-DD, was: <old claim>)` after it.
4. `## Open questions` for things the sources raise but do not answer (optional).
5. `## Sources`, one bullet per contributing log: `- [[knowledge/_log/2026/10/2026-10-14]]`.

Keep the claims, numbers, commands, paths and decisions with their reasons. Drop chatter, task lists and anything that is only true for one day.

## Links

- Use plain vault-relative wikilinks with no alias: `[[knowledge/subjects/software/litellm-gateway]]`. They resolve from any note.
- Link related articles from inside the sentence that relates them.

## Tags

Use one area tag and one or two kind tags. A tag not listed here is refused: add it to this list (in the template) before using it.

Area: the last segment of a domain id (ops for core/ops), or one of `software`, `infra`, `os`, `hardware`, `home`, `network`, `business`, `finance`, `health`, `ai`, `notes`, `work`.

Kind: `reference`, `howto`, `decision`, `concept`, `research`, `troubleshooting`, `project`, `person`.
