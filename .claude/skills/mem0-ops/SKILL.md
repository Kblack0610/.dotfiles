---
name: mem0-ops
description: Cross-project, cross-tool long-term memory via self-hosted mem0-api-server at mem0.kblab.me. Use when the user mentions "remember", "preference", "recall", "memory layer", "what did I tell you about", "save this for later", or asks for context that should persist across projects/sessions/tools. Stores user-level facts (preferences, repo paths, tooling choices, conventions) and cross-project facts ("project A uses framework X"). Does NOT replace project-specific lessons (~/.agent/lessons/) or runbook docs (in-repo markdown) — see Memory Routing in ~/.claude/CLAUDE.md for the full split.
---

# mem0-ops

Self-hosted [mem0](https://github.com/mem0ai/mem0) (Apache-2.0) running on home-k3s at `mem0.kblab.me`. REST API directly callable from any tool — no MCP server, no third-party API keys.

Backed by `apps/mem0/` (mem0-api-server) + `apps/postgres/` (pgvector) on the home-k3s cluster.

## Quick reference

| Operation | Verb / endpoint |
|---|---|
| Add memory | `POST /memories` |
| Semantic search | `GET /memories?user_id=...&query=...` (search is folded into the list endpoint when `query` is set) |
| List all for user | `GET /memories?user_id=...` |
| Get one | `GET /memories/{memory_id}` |
| Update | `PUT /memories/{memory_id}` |
| Delete one | `DELETE /memories/{memory_id}` |
| Delete all for user | `DELETE /memories?user_id=...` |

`user_id` is the cross-project scope. Use **`kblack0610`** for everything user-level. For project-scoped memories that should only surface in project A, use `agent_id=<project-name>` alongside `user_id`.

## Endpoint and auth

```bash
export MEM0_BASE_URL=https://mem0.kblab.me
# Currently AUTH_DISABLED=true on the server (LAN-only ingress middleware
# does the access control). When auth flips on, add:
#   export MEM0_API_KEY="<bearer>"
#   curl -H "Authorization: Bearer $MEM0_API_KEY" ...
```

The host is reachable over the LAN and via Tailscale. From outside both networks, the Traefik `monitoring-local-network-only` middleware returns 403 — this is intentional.

## Common operations (curl)

### Add a user-level fact

```bash
curl -fsS -X POST "$MEM0_BASE_URL/memories" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "User prefers shell+neovim over Obsidian for notes."}
    ],
    "user_id": "kblack0610"
  }'
```

### Search before answering

When the user asks a question that could depend on stored context, search FIRST, then answer with the retrieved facts woven in:

```bash
curl -fsS "$MEM0_BASE_URL/memories?user_id=kblack0610&query=notes+editor+preference"
```

Response shape:

```json
{
  "results": [
    {"id": "...", "memory": "User prefers shell+neovim over Obsidian for notes.", "score": 0.89, ...}
  ]
}
```

### Add a project-scoped memory

```bash
curl -fsS -X POST "$MEM0_BASE_URL/memories" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "platform repo uses NextAuth, not Clerk — Clerk was ripped out 2026-Q1."}
    ],
    "user_id": "kblack0610",
    "agent_id": "bnb-platform"
  }'
```

### List + delete

```bash
curl -fsS "$MEM0_BASE_URL/memories?user_id=kblack0610" | jq '.results[] | {id, memory}'
curl -fsS -X DELETE "$MEM0_BASE_URL/memories/<memory-id>"
```

## When to write a memory

Write to mem0 when the fact is:
- **User-level** (preferences, conventions, tooling choices, "always" rules)
- **Cross-project** ("client X requires Y", "project A uses framework B")
- **Surprising or non-obvious** (would not be derivable from reading the code)
- **Stable** (won't decay on the next migration)

Don't write to mem0:
- Project-specific corrections you made this session → those go in `~/.agent/lessons/{project}.md` (the SessionStart hook auto-injects them).
- Runbook content (deploy steps, auth flow, architecture) → those belong in the project repo's markdown.
- Ephemeral session state → that's task tracking, not memory.
- **File-pointer "trigger" memories** ("the X runbook lives at Y/<topic>.md") — mem0's LLM extractor filters these out as not-memory-shaped (they're metadata about files, not user facts). Discovery happens via `ls docs/runbooks/` + `grep` in the repo, which is fast enough that the mem0 indirection adds no value. Keep runbook discovery file-system-native.

The full routing rule lives in `~/.claude/CLAUDE.md` Memory Routing section.

## When to read

Search mem0 EARLY in a session when:
- The user references prior context ("remember when we...", "you said X about Y")
- The work spans multiple projects or could conflict with a known preference
- A choice depends on user opinion that's been expressed before (editor, deploy strategy, framework)

The search is a single `curl` — run it, scan the top 3 results, ignore the rest.

## Operational notes

- **Server is at `apps/mem0/` on home-k3s.** Outage symptom: 5xx or connection-refused. Check `kubectl --context home-k3s -n memory get pods` (use `k8s-ops` skill).
- **Postgres is at `apps/postgres/` (shared cluster).** mem0 outage caused by Postgres downtime: `kubectl --context home-k3s -n databases get pods`.
- **Backups**: not yet wired. Loss of `apps/postgres/postgres-data` PVC = total memory loss. Tracking as a follow-up in `apps/postgres/README.md`.
- **Telemetry off**: `MEM0_TELEMETRY=false` is set in `apps/mem0/configmap.yaml`. No data leaves the cluster.

## Programmatic SDK (when curl isn't enough)

For more complex flows — batch retrieval-augmented generation, async memory updates from background jobs — use the Python SDK pointed at the self-hosted endpoint:

```python
from mem0 import MemoryClient
client = MemoryClient(api_key="not-needed", host="https://mem0.kblab.me")

client.add(
    messages=[{"role": "user", "content": "..."}],
    user_id="kblack0610",
)
results = client.search("query", user_id="kblack0610")
```

The upstream skill (Apache-2.0) at <https://github.com/mem0ai/mem0/tree/main/skills/mem0> has the full operations table for SDK usage. This skill scopes the operations to the self-hosted server and the user's actual `user_id`.

## Failure modes worth knowing

- **`{"detail": "Provider rejected the request as malformed.", "code": "provider_bad_request"}`** with LiteLLM logs showing `litellm.UnsupportedParamsError: Setting dimensions is not supported for OpenAI text-embedding-3 and later models` — mem0's openai embedder always passes `dimensions=` regardless of config. Fix: in `apps/litellm/configmap.yaml`, the embedding model entry needs `drop_params: true` + `additional_drop_params: ["dimensions"]` under `litellm_params`. Already wired; if it regresses check the configmap.
- **`{"detail": "Provider is unreachable or returned a server error.", "code": "provider_unavailable"}`** — LiteLLM is between rolls or unreachable. `kubectl --context home-k3s -n ai-gateway get pods` and wait for litellm pod 1/1 Ready before retrying.
- **5xx from `/memories` POST but `/docs` returns 200** — Postgres is reachable but the schema is missing. The init container (`alembic upgrade head`) didn't run successfully. `kubectl logs deploy/mem0 -c alembic-upgrade -n memory`.
- **`expected 1536 dimensions, got 768`** (or similar dim mismatch) — the pgvector table's `vector(N)` column is N=1536 (mem0 default for OpenAI text-embedding-3-small) but our embedder produces 768-dim vectors. Fix: drop the table (`kubectl --context home-k3s -n databases exec deploy/postgres -- psql -U postgres -d mem0 -c "DROP TABLE mem0_memories"`), POST `/configure` with `vector_store.config.embedding_model_dims=768`, then add a memory to recreate the table at the right dim. Or rebuild the mem0 image with a `MEM0_EMBEDDING_MODEL_DIMS` env var read in `main.py` (tracked follow-up).
- **"role mem0 does not exist"** — the postgres init script (`apps/postgres/init-configmap.yaml`) didn't run, which means Postgres came up against an existing data dir from before the script existed. Either re-init from scratch (destroys data) or run the SQL manually.

## Cross-tool reach (OpenCode, Codex CLI)

This skill is Claude-Code-native. For OpenCode + Codex CLI to use mem0, place an `AGENTS.md` at the working directory root (or `~/.dotfiles/AGENTS.md` for cross-repo) with a one-paragraph pointer:

```markdown
# Memory layer

Self-hosted mem0 at https://mem0.kblab.me (LAN-only). For user-level prefs
and cross-project facts, search before answering and add when learning
something new. See ~/.claude/skills/mem0-ops/SKILL.md for the full operations
table — same REST API works from any tool.
```

The skill content above is the contract; the AGENTS.md cross-reference makes it discoverable to non-Claude tools.
