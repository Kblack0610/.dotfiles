---
description: Scan recent activity (git, notes, journal) and persist durable user-level facts to mem0 + Serena
allowed-tools: Bash, Read, Write, Glob, Grep, mcp__serena__*
---

# /remember — On-Demand Memory Sync

Manually trigger memory consolidation from recent activity. Complements the
scheduled nightly run (`agentctl-nightly-sync.timer` at 23:00) — use this
when you've just done something significant and want to capture it now,
not at the end of the day.

Memory layer: self-hosted **mem0** at `mem0.kblab.me` (per the `mem0-ops`
skill) for cross-project user-level facts; **Serena** for project-specific
context; the user's `~/.notes/` system as the source of activity.

## Workflow

### Step 1 — Gather activity

**Git** (across active project dirs the user has touched recently):
```bash
# Adjust the path list if needed; covers common roots
for d in ~/.dotfiles ~/dev/home/* ~/dev/bnb/*; do
    [ -d "$d/.git" ] && {
        echo "=== $d ==="
        git -C "$d" log --oneline --since="24 hours ago" --all --no-merges
    }
done
```

**GitHub PRs** (via `gh-workflows` skill):
```bash
gh search prs --author=@me --updated=">=$(date -d yesterday +%Y-%m-%d)" \
  --json number,title,repository,state,mergedAt,url
gh pr list --author=@me --state=open --json number,title,headRefName,reviewDecision
```

**Notes inbox** (today + yesterday — catches late-night entries):
```bash
for d in $(date +%Y-%m-%d) $(date -d yesterday +%Y-%m-%d); do
    [ -f ~/.notes/inbox/$d.md ] && cat ~/.notes/inbox/$d.md
done
```

**Daily journal** (today + yesterday):
```bash
for d in $(date +%Y-%m-%d) $(date -d yesterday +%Y-%m-%d); do
    [ -f ~/.notes/journal/daily/$d.md ] && cat ~/.notes/journal/daily/$d.md
done
```

### Step 2 — Compare against existing memories

**mem0** (cross-project user-level — checks user_id=kblack0610):
```bash
curl -s 'https://mem0.kblab.me/memories?user_id=kblack0610' | jq -r '.[].memory'
```

**Serena** (project-specific, only if a project is active):
```
mcp__serena__list_memories
```
Read any that look topically relevant before deciding whether to add or
update.

### Step 3 — Decide what's worth capturing

For each candidate observation, route it to the right home:

| Type of fact | Goes to | Example |
|---|---|---|
| User preferences, tooling choices, repo paths, conventions | **mem0** | "user prefers Oxlint over ESLint in bnb-platform" |
| Cross-project facts ("project A uses framework X") | **mem0** (optionally `agent_id=<project>`) | "binks is migrating from Rust to TypeScript" |
| Project-specific technical details (architecture, internal APIs, gotchas) | **Serena** | "gheegle uses tRPC + zod end-to-end; types flow from server schemas" |
| Project-specific corrections / lessons | **NOT here** — those go in `~/.agent/lessons/<project>.md` (file-based, auto-loaded) | — |
| Project runbook docs (auth flow, deploy steps) | **NOT here** — those belong in the project repo | — |

Skip:
- Ephemera, single-conversation noise, vague items ("fixed a bug")
- Anything already captured (check Step 2 output before writing)
- Implementation details that belong in code/docs, not memory

### Step 4 — Write to mem0 + Serena

**mem0 writes** (per the `mem0-ops` skill — REST only, no auth, LAN/Tailscale):
```bash
curl -s -X POST https://mem0.kblab.me/memories \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"<fact>"}],"user_id":"kblack0610"}'
```
Add `"agent_id":"<project-name>"` if the fact is project-scoped (e.g.,
`"agent_id":"bnb-platform"`).

**Serena writes** (project-active only):
```
mcp__serena__write_memory(name, content)   # for new entries
mcp__serena__edit_memory(name, content)    # for updates to existing
```
Use clear topical names: `architecture-trpc-end-to-end`, not `note-1`.

### Step 5 — Generate report

Write a brief summary directly to the user's notes inbox (no MCP — just
a shell write per the `notes-system` skill conventions):
```bash
INBOX="$HOME/.notes/inbox/$(date +%Y-%m-%d).md"
mkdir -p "$(dirname "$INBOX")"
cat >> "$INBOX" <<EOF

## $(date +%H:%M) — /remember sync

### Added to mem0
- {one line per write, with the fact text}

### Added to Serena
- {one line per write, with the memory name + summary}

### Skipped (already captured)
- {one line per skip with the reason}
EOF
```

Then output the same summary to stdout for the user to scan.

## Guidelines

- **Be selective.** Quality over quantity. Aim for 0–5 mem0 writes per
  invocation. Better to skip a marginal fact than write noise.
- **Specificity wins.** "Switched gheegle from REST to tRPC for type
  safety" beats "worked on auth."
- **Capture decisions, not activity.** Tech choices, architecture
  pivots, stated preferences — not "I had a meeting."
- **Avoid duplicates.** Step 2 is mandatory. If a fact looks similar to
  an existing memory, prefer to UPDATE the existing one (mem0 PUT, or
  Serena `edit_memory`) over adding a duplicate.
- **Project-scoped facts on mem0 should set `agent_id`.** That keeps
  cross-project search useful without polluting the global view.

## Routing reminder (from CLAUDE.md)

| Knowledge type | Home |
|---|---|
| User prefs / cross-project facts | mem0 (user_id=kblack0610) |
| Project corrections / lessons | `~/.agent/lessons/{project}.md` — DO NOT write here |
| Project runbooks (deploy, auth flow) | Project repo markdown — DO NOT write here |
| Project-specific technical context | Serena memory |
| Workflow rules (this command, CLAUDE.md) | dotfiles, not memory |

If the fact doesn't fit mem0 or Serena, it probably doesn't belong in
memory at all. Surface it to the user instead.

## Relationship to nightly-sync

`/remember` is the manual trigger. The nightly batch
(`agentctl-nightly-sync.timer` at 23:00) runs the same logic
unattended, reading the same sources and writing to the same mem0.
Run `/remember` ad-hoc when you want to capture something significant
right now without waiting for 23:00.

$ARGUMENTS
