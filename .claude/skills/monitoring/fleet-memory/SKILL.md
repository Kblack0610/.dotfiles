---
name: fleet-memory
description: >-
  Front door for memory consolidation: dream (03:00), nightly-sync (23:00), mem0 proposals. Use for "did dream run", "run a sweep now", "why no new lessons", "dream proposed a fact". Procedure: DREAMING.md.
paths:
  - ".local/bin/agentctl-dream"
  - ".local/bin/agentctl-nightly-sync"
  - ".config/agentctl/DREAMING.md"
  - ".claude/commands/dream.md"
metadata:
  category: monitoring
  tags: [dream, nightly-sync, memory, lessons, mem0, consolidation]
  reviewed: "2026-11-07"
---

# fleet-memory

Three jobs turn the day's work into memory, and none of them is a skill of its own. This one points at the runbook `~/.config/agentctl/DREAMING.md`, which owns the procedure, the scoring and every gate; read it for detail and do not copy it here.

## Scope and triggers

- A question about whether a nightly job ran, or why a lesson, `memory/` entry or mem0 proposal did or did not appear.
- A sweep wanted now, before tomorrow's sessions start.
- A mem0 proposal from `dream` waiting for a decision.

Not for a correction to file (that goes in `~/.agent/lessons/{project}.md`), for user preferences (`mem0-ops`), or for the lab feed's release facts (`lab-sync`).

## Which job

| Job | When | Flow |
|---|---|---|
| `nightly-sync` | 23:00 | notes -> mem0 |
| `dream` | 03:00 | agent corpus -> lessons, `memory/`, mem0 proposals |
| `lab-sync` | weekly | git and `~/.agent` -> lab `summary.md` (`lab-sync`) |

## Verbs

- Did it run: `agentctl status dream`, `systemctl --user list-timers | grep -E 'dream|nightly'`; the diary is `~/.agent/dreams/{project}/DREAMS.md`.
- Sweep one project now: `agentctl-dream --project <name>` in the background; it is a headless model call, and `--dry-run` only skips promotion, it still costs one. Interactive: `/dream --project <name>`.
- Open mem0 proposals: `agent-propose list --stream dream`; decide with `agent-propose accept|reject <id>`.
- A lesson that landed twice or a `memory/` file a lesson already covers: DREAMING.md "Safety" (the dedupe check moves it to `memory-refused/`).

## Do NOT

- Do not edit `~/.agent/dreams/` or the checkpoint by hand; run the verb.
- Do not accept a proposal on the human's behalf; mem0 stays human-gated.
- Do not start a sweep, `--dry-run` included, to test a change; each is a model call. The stubbed tests are `tests/dream-*.sh` in `~/.config/agentctl/`.
