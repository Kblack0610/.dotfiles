---
name: claude-recall
description: On-demand pull-recall over the RAW verbatim Claude Code session transcripts (~/.claude/projects/**/*.jsonl) via the `claude-recall` CLI. Use when you need to retrieve something that was actually SAID in a past session but was never distilled into a lesson / wind-down / mem0 / anchor - "what did we decide about X", "find the session where we debugged Y", "what was that command/path/error from last week", "show me that earlier conversation". This is the lossless raw layer BELOW the curated recall stack: lessons/dreams/mem0/anchors are push-based distilled signal injected at SessionStart; this is pull-based verbatim search you invoke on demand. Local-only, no index, no cloud - reads the .jsonl on each call (full scan ~0.3s). The skill-and-script equivalent of local-claude-chat-history-mcp, reached via Bash instead of a standing MCP so it costs zero session context until used. Do NOT use for curated/summarized recall (that's mem0-ops / lessons / the anchor) or for searching the current live conversation (you already have that in context).
---

# claude-recall

Verbatim search over Claude Code's own session record. Every Code session is
appended to `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`; this tool reads
those files directly. No database, no embeddings, no daemon, nothing uploaded.

## When to reach for it

Use it for the one recall mode the curated stack does NOT cover: **retrieving
something that was said in a past session but never got distilled** into a
lesson, wind-down note, mem0 fact, or anchor. Typical asks:

- "What did we decide about <X> a few weeks back?"
- "Find the session where we debugged <Y> / hit <error>."
- "What was that exact command / path / config value from last week?"
- "Show me the earlier conversation about <topic>."

Do NOT use it for:
- Curated / summarized recall - that's `mem0-ops`, `~/.agent/lessons/`, or the anchor.
- The current live conversation - it's already in your context.

## Where recall sits in the memory stack

| Layer | Shape | Reached by |
|---|---|---|
| lessons / dreams / mem0 / anchor | curated, distilled, **lossy** | pushed at SessionStart (or `mem0-ops` query) |
| **claude-recall (this)** | verbatim, **lossless** | pulled on demand via Bash |

Push-based distilled signal above; pull-based raw transcripts here. Prefer the
curated layer first; drop to raw recall when the distilled note doesn't have it.

## Commands

```bash
# Full-text / regex search across all transcripts (rg-prefiltered, ~0.3s full scan)
claude-recall search "privacy overlay" --project dotfiles --since 2026-07-01
claude-recall search "TODO|FIXME"  --regex --role assistant --limit 20
claude-recall search "cred expire" -i --context 160        # case-insensitive, wider snippet

# Recent sessions with their auto-titles (most-recent first)
claude-recall list --project brightsign --limit 20

# Print a full session by id or unique prefix (add --thinking to include reasoning)
claude-recall show 15eeee34
```

Search filters: `--project` (substring on cwd basename), `--branch` (exact
gitBranch), `--since YYYY-MM-DD`, `--role user|assistant`, `--regex`, `-i`,
`--thinking` (include thinking blocks; excluded by default), `--context N`
(snippet width, default 120), `--limit N` (`0` = all).

## Notes

- Reads Claude Code sessions, plus Claude Cowork's `local-agent-mode-sessions`
  on macOS when that directory exists.
- Filenames ARE session ids; `show` accepts a unique prefix.
- No index means results are always current - a session you closed a minute ago
  is already searchable. Cost is a fresh read each call; that's ~0.3s over the
  whole corpus, so no caching is needed.
- Script: `~/.dotfiles/.local/bin/claude-recall` (generic, public repo). It
  reads only the local transcript files and never writes them.
