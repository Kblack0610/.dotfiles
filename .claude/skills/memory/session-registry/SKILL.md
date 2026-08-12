---
name: session-registry
description: Find, resume, or compact important past Claude sessions from the agent-facing session registry. Use when the user (or you) wants to revisit an earlier session's history - "what did I work on before", "reopen that session", "resume the session where we did X", "compact/summarize that old session", or when you need context from a prior meaningful session in this project. The registry auto-captures only sessions that did real work (edits or a dirty tree), one entry per session, on the agent axis (~/.agent/sessions), never the human notes inbox.
metadata:
  category: memory
  tags: [session, transcripts, resume]
  reviewed: "2026-07-13"
---

# session-registry

## What this is

Every meaningful Claude session in a project auto-registers itself into an agent-facing index so it can be revisited later. Capture is automatic (a Stop hook); this skill is the read/act side.

- **Registry:** `~/.agent/sessions/{project}/sessions.jsonl` - one JSON line per session:
  `{session_id, project, transcript, resume, first_prompt, edits, head_commit, updated}`.
- **Captured automatically** by `~/.claude/hooks/stop-post.d/80-session-register.sh` when a session made >=1 file edit (Edit/Write/MultiEdit/NotebookEdit) or left a dirty git tree. Pure Q&A / read-only sessions are NOT captured (low noise, on purpose). Upserted by `session_id`, so exactly one entry per session. Dead-transcript lines self-prune.
- **Never** written to `~/.notes/inbox` - this is the agent axis, not the user's triage queue.

## The `sessions` CLI (on PATH)

```
sessions list [project] [--all]     # registered sessions, newest first (default: current project)
sessions resume <id|--pick>         # reopen a session transcript (exec claude -r <id>)
sessions compact <id|--pick>        # distill a transcript into ~/.agent/sessions/{project}/<id>-digest.md
```

## How to use it

- **"What did we work on / find that earlier session"** -> `sessions list` (this project) or `sessions list --all`. Read the `first_prompt` + `updated` columns to locate it. You can also read the JSONL directly for scripting.
- **"Reopen / resume that session"** -> `sessions resume <id>`. This `exec`s `claude -r <id>` and replaces the current process, so only do it when the user genuinely wants to switch into that session. If you just need its content, read the transcript path from the registry instead.
- **"Compact / summarize that session"** -> `sessions compact <id>`. Spawns a headless `claude -p` that reads the transcript JSONL and writes a `<id>-digest.md` (what happened, files touched, decisions, next step). On-demand only - costs tokens, so run it when asked.
- **Reading a transcript yourself:** grab `.transcript` from the registry line; it is a JSONL file (one message per line) under `~/.claude/projects/<encoded>/<id>.jsonl`. These are large - grep or read selectively, do not slurp whole files into context.

## Notes

- The registry complements `wind-down` notes (human-authored `.md` summaries, no transcript pointer) and Dreaming (which now has a pointer to which raw transcripts are worth reading).
- If `sessions list` is empty for a project, no meaningful session has been captured there yet (or transcripts were pruned).
