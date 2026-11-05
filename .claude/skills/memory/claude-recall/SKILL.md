---
name: claude-recall
description: >-
  Verbatim search and counts over raw Claude Code transcripts via `claude-recall`. Use for "what did we decide about X", "find the session where we debugged Y", "what do I keep asking for", "which skills and agents get used", "where do our tokens go". Curated recall is mem0-ops.
metadata:
  category: memory
  tags: [memory, recall, session]
  reviewed: "2026-11-04"
---

# claude-recall

Verbatim search over Claude Code's own session record. Every Code session is
appended to `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`; this tool reads
those files directly. No database, no embeddings, no daemon, nothing uploaded.

## Scope and triggers

On-demand pull-recall over the RAW verbatim Claude Code session transcripts (~/.claude/projects/**/*.jsonl) via the `claude-recall` CLI. Use when you need to retrieve something that was actually SAID in a past session but was never distilled into a lesson / wind-down / mem0 / anchor - "what did we decide about X", "find the session where we debugged Y", "what was that command/path/error from last week", "show me that earlier conversation". This is the lossless raw layer BELOW the curated recall stack: lessons/dreams/mem0/anchors are push-based distilled signal injected at SessionStart; this is pull-based verbatim search you invoke on demand. Local-only, no index, no cloud - reads the .jsonl on each call (full scan ~0.3s). The skill-and-script equivalent of local-claude-chat-history-mcp, reached via Bash instead of a standing MCP so it costs zero session context until used. Do NOT use for curated/summarized recall (that's mem0-ops / lessons / the anchor) or for searching the current live conversation (you already have that in context).

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

# Counts: typed /commands, Skill calls, subagent spawns, intents, repeated prompts
claude-recall stats --days 30                                  # every kind, top 20 each
claude-recall stats --kind intent --origin interactive         # asks a skill should have caught
claude-recall stats --kind prompt --origin interactive --min 3 # skill candidates (3+ sessions)
claude-recall stats --kind agent --by week --json              # agent use per ISO week

# Token use: API usage per response, and the tool output behind it
claude-recall tool-output --by command --days 7                # which Bash commands fill the context
claude-recall tool-output --by method --since 2026-11-05       # token-filter trial, per method window
```

Search filters: `--project` (substring on cwd basename), `--branch` (exact
gitBranch), `--since YYYY-MM-DD`, `--role user|assistant`, `--regex`, `-i`,
`--thinking` (include thinking blocks; excluded by default), `--context N`
(snippet width, default 120), `--limit N` (`0` = all).

## stats: counting what recurs

`stats` is the one counter for "how often": skill-drift, skill-refine and the Monday briefing read it, so do not grep transcripts for a count elsewhere.

- SESSIONS is the headline column. A `/loop` that fires a command 200 times in one session is one session.
- `inter` vs `auto`: `turnOrigin` decides where present (`human` is interactive; a /loop fire, a peer message or a task notification is auto); older records fall back to `entrypoint == sdk-cli` and `isMeta`. Interactive is not proof a person typed it: a session fleet-dispatch starts gets its task as an interactive turn.
- A subagent's Skill and Agent calls count toward its parent session; its dispatch prompt is not a typed prompt.
- Prompts: only the first line, only when it opens with a letter or digit (pasted output does not), harness text skipped. Normalised (paths, URLs, SHAs, numbers masked, filler words dropped, first 8 words) and clustered with typo tolerance. Exact repeats are rare, which is why intents exist.
- Intents: `~/.config/claude-recall/intents.tsv` (override with `CLAUDE_RECALL_INTENTS`) maps phrases to the skills that cover them. Each intent row says in how many of its sessions a covering skill actually ran; a low share means the task gets asked for in words and the skill never fires. Tune the phrases there; it is data, not code.
- `CLAUDE_TRANSCRIPTS` (colon-separated) replaces the transcript roots; the bats suite uses it.

## tool-output: where the tokens go

`tool-output` is the one token counter: it sums `message.usage` per API response (deduplicated by message id) and every tool result's size, so do not write another transcript scanner for token questions.

- Totals: input, cache write, cache read and output tokens; context per response; tool result chars (about 4 chars a token).
- `carried` weights each tool result by how many later responses re-read it before a compaction drops it. It is the cost a big result really has, since the whole context is re-read on every turn.
- `--by tool|command` ranks what produces output (`command` is the Bash command head, past env, `cd` and wrappers, with git/gh subcommands; an `rtk` rewrite counts under the tool it ran). `--by method|day|week|project` splits usage over time; `method` reads the `token-filter` switch log (`.claude/hooks/README.md` "Token filter"), and `filtered` counts rewritten calls.

## Notes

- Reads `~/.claude/projects` and `~/.claude-work/projects`, plus Claude Cowork's `local-agent-mode-sessions`
  on macOS when that directory exists.
- Filenames ARE session ids; `show` accepts a unique prefix.
- No index means results are always current - a session you closed a minute ago
  is already searchable. Cost is a fresh read each call; that's ~0.3s over the
  whole corpus, so no caching is needed.
- Script: `~/.dotfiles/.local/bin/claude-recall` (generic, public repo). It
  reads only the local transcript files and never writes them.
