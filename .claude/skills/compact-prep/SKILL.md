---
name: compact-prep
description: Pre-flight for context compaction — before the window is summarized, prove that every load-bearing item (modified files, verification results, key decisions + why, task status, the single next step, active plan location, recurring error patterns) is captured in the durable memory layer, close the gaps, then hand the user a tailored `/compact <focus>` invocation. Use when the user says "should we compact", "compact first", "prep for compaction", "make sure everything's captured", "are we safe to compact", or "/compact-prep". Verbs: check | prep. Differs from wind-down (ends the session + closes the tmux window) and session-snapshot (host-reboot inventory) — compact-prep only guards the durable layer against the summarizer dropping in-flight work, and never issues `/compact` itself.
---

# compact-prep

Nothing is lost to compaction if it already lives in the durable layer. This skill reconciles
**this session's work** against that layer (anchor, plans, lessons, `memory/`, git/PR state)
*before* the conversation is summarized, closes any gap the user confirms, then hands the user a
`/compact` invocation steered at the load-bearing items. It does **not** run `/compact` itself —
the human issues it, keeping a person in the loop (same shape as `wind-down` deferring the kill).

## Why this exists

`~/.claude/CLAUDE.md` names a "Compact Handoff" (preserve modified files, verification results,
key decisions, task status, next step, active plan location, recurring error patterns) and the
Stop eval even scores it — but until now nothing *performed* it. Auto-compact fires unattended at
75% of the window (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75`), mid-task, with no chance to prepare.

**What survives compaction automatically** (re-injected/kept by the harness): project + user
CLAUDE.md, `MEMORY.md` (auto memory), skill descriptions, `.claude/rules/`. **What does NOT
survive** unless written to the durable layer: the raw conversation, mid-session findings,
in-flight task status, uncommitted decisions. This skill's whole job is to move the second list
into the first before the window is summarized.

Two backstops run without this skill (see `Related machinery` below): a **PreCompact hook**
archives the full transcript and drops a marker on every compaction, and the **SessionStart
preflight** re-injects the durable pointers + a "just compacted, run /compact-prep check" banner
afterward. This skill is the *intentional* path; the hooks are the *unattended* safety net.

## Verbs

- **check** (default) — read-only. Reconcile and report the captured/gap table. Propose the writes
  it *would* make, but write nothing. Use for "are we safe to compact?".
- **prep** — do the `check`, then after the user confirms, perform the gap-closing writes and print
  the tailored `/compact` invocation. Use for "prep for compaction / make sure everything's captured".

## Steps

### 1. Resolve the durable-layer paths

Get the paths from the executor so project resolution matches the hooks exactly (never re-derive
`{project}` by hand):

```bash
~/.config/shared-hooks/compact-prep.sh paths
```

It prints `KEY=VALUE` lines: `PROJECT`, `ANCHOR`, `PLAN_DIR`, `CLAUDE_PLAN_DIR`, `LESSONS`,
`ARCHIVE_DIR`, `MARKER`. The per-project `memory/` dir is the one named in your session's memory
system-reminder (`~/.claude/projects/<encoded-cwd>/memory/`) — use that directly.

### 2. Inventory the durable layer (read-only)

Read what is already persisted, so the diff in step 3 is accurate:

- **Anchor** — `ANCHOR` (`~/.agent/anchors/{project}.md`): the project front door.
- **Active plans** — files in `PLAN_DIR` and `CLAUDE_PLAN_DIR`. A plan is *active* if it has
  unchecked items or an open "Next step". The source of truth is `~/.claude/plans/`; the
  `~/.agent/plans/` copy is a cache.
- **Lessons** — `LESSONS` (`~/.agent/lessons/{project}.md`).
- **Memory** — the project `memory/MEMORY.md` index + `memory/*.md`.
- **Git / PR state** — `git status --short`, unpushed commits (`git log @{u}.. --oneline`, guard
  for no upstream), and open PRs (`gh pr list --state open` if `gh` is available).

### 3. Diff against this session's Compact-Handoff items

Enumerate what this session produced, one row per CLAUDE.md Compact-Handoff dimension, and mark
each **captured** (present in the durable layer from step 2) or **gap** (lives only in the chat):

| Dimension | This session | Captured? | Where / gap |
|---|---|---|---|
| Modified files | … | ✓ / gap | committed / uncommitted |
| Verification results | … | ✓ / gap | plan Results / chat only |
| Key decisions + why | … | ✓ / gap | memory/anchor / chat only |
| Task status | … | ✓ / gap | plan file / chat only |
| Next step (the single most useful one) | … | ✓ / gap | plan / inbox / chat only |
| Active plan location | … | ✓ / gap | path / none |
| Recurring error patterns + fixes | … | ✓ / gap | lessons / chat only |

Print this table — it is the core deliverable of `check`.

### 4. Remediate gaps — propose, then confirm

For every `gap` row, propose the **exact** write and its destination, using the standard memory
routing from `~/.claude/CLAUDE.md`:

- **A durable fact / key decision + why** → a `memory/<slug>.md` file + a one-line `MEMORY.md`
  pointer (the format in the CLAUDE.md memory section).
- **Task status / next step / verification result** → update the active plan file: check off items,
  append a `## Results` section, record the next step. Edit the source in `~/.claude/plans/`.
- **A correction the user made this session** → one line appended to `~/.agent/lessons/{project}.md`.
- **Uncommitted code that should persist** → surface it; suggest a commit/branch (do not auto-commit
  unless the user asks — that is the user's call).

List these as a numbered plan of writes. **On `check`, stop here — write nothing.** On `prep`, make
the writes only after the user confirms. Never auto-touch auth tokens, history, logs, or sqlite/
runtime state (CLAUDE.md guardrail); if a "gap" is ephemeral runtime state, note it and skip it.

### 5. Hand off the tailored /compact invocation

Print a `/compact` command whose focus instruction names the load-bearing items, so the summary the
model produces is steered at what matters:

```
/compact Preserve: next step = <…>; active plan = <path>; open decisions = <…>; in-flight task status = <…>. Modified files and verification results are captured in <where>.
```

Tell the user to issue it. **This skill never runs `/compact` itself** — the tailored focus string
is the only supported steer on the summarizer (the summary prompt and summarizer model are not
configurable), which is exactly why we hand it over rather than trying to reshape the summary.

If a `MARKER` file exists (an auto-compact already happened and the preflight surfaced it), this run
is a *post-hoc reconcile*: the archived transcript at the path in the marker is the ground truth —
read from it to recover anything the summary dropped, close the gaps, then clear the marker with
`~/.config/shared-hooks/compact-prep.sh marker --clear`.

## Related machinery (do not invoke directly)

- **PreCompact hook** — `~/.dotfiles/.config/shared-hooks/compact-prep.sh precompact`, wired in
  `settings.json` (matcher `""` = manual + auto). On every compaction it archives the full
  uncompacted transcript to `ARCHIVE_DIR` and drops the `MARKER`. Exits 0 always (never blocks —
  a blocked compaction can trap a full window).
- **SessionStart re-inject** — `session-preflight.sh` handles `source == compact`: re-injects the
  anchor + plans + lessons and, if `MARKER` exists, prepends a "context was just compacted; run
  /compact-prep check" banner pointing at the archived transcript, then leaves the marker for the
  reconcile run to clear.

## Notes / non-goals

- Not a session-end tool — that's `wind-down` (writes a wrap-up + closes the tmux window). Not a
  host-reboot inventory — that's `session-snapshot`. This one only guards the durable layer against
  the summarizer.
- Does not block compaction. The safety net is the transcript archive + marker, not an exit-2 gate.
