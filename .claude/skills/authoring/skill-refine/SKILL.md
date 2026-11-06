---
name: skill-refine
description: >-
  Audit and polish the skill corpus: stale paths, lesson contradictions, overlaps, missing skills. Use for "audit the skills", "are my skills stale", "what skills am I missing". Propose-only when headless. Rules: update-rules.
metadata:
  category: authoring
  tags: [skills, maintenance, drift]
  reviewed: "2026-08-11"
---

# skill-refine

A `SKILL.md` is prose an agent obeys. It has no compiler, no test, and no import that breaks when the world moves under it - so when a path changes, a host is decommissioned, or a sibling skill is retired, nothing fails loudly. The agent opens a file that is not there, improvises, and the session quietly gets worse.

This skill is the maintenance pass for that corpus. It never trusts a skill's own account of itself; it checks against the filesystem, then against what the memory layers have since learned.

## Who changes a skill

Skills are instructions, not code. An auto-rewrite that is subtly wrong does not throw - it changes how every future session behaves, invisibly. So no change reaches a skill without a reviewable diff:

- **Nightly** (`docs-cleanup`): the runner counts `skill-drift` findings and queues a session that fixes the mechanical ones (a moved path, a renamed command) one area per PR, CI on each.
- **Interactive** (`audit`, `apply`): the judgment layer below, a human confirming each change.

The weekly propose-only `agentctl@skill-refine` run was retired on 2026-11-05: six reports in six weeks while DEADPATH rose from 25 to 31, because a report nobody applies fixes nothing.

## Verbs

### `audit` (default, read-only)

Four layers, in order. The first is ground truth; the rest are judgment.

**1. Filesystem - run the deterministic checker.**

```bash
skill-drift --json
```

**Environmental** (need a real machine, so they are yours alone to act on): `DEADPATH` (a `~/` path in a SKILL.md that does not exist), `NOCMD` (a command it tells you to run that is not on PATH), `UNDEPLOYED` (a skill dir in a repo with no link in `~/.claude/skills/`), `GHOST` (bulleted in CLAUDE.md, absent from disk), `STALE` (`metadata.reviewed` older than 180d), `UNUSED` (never invoked in 90d of transcripts), `LISTBUDGET` (the whole listing over its budget).

**Static** (`skill-drift --lint .`, the checks `~/.local/src/docs/skills.md` names): CI gates every PR on these, so a finding here is debt frozen in `tests/skill-lint.baseline` or something that landed before the gate existed.

`skill-drift` reports **all** findings and marks which are `new` relative to `~/.agent/skill-drift.baseline`. Read the whole set in an audit; the baseline marks what is new, not so old debt disappears.

Two of these need judgment rather than a fix:

- **`STALE` is not fixed by editing the date.** It says nobody has checked the skill against reality in six months. Re-verify the claims - open the paths, run the commands, confirm the hosts - and only then bump `metadata.reviewed`. Bumping it without checking converts an honest "unknown" into a false "verified", which is strictly worse.
- **`UNUSED` is a signal, not a verdict.** A release runbook fires per release and is *supposed* to look idle; that is not the same as a skill the router never picks because a neighbour's description shadows it. Cross-reference against layer 3 (overlap) before proposing anything, and never propose deleting a skill on `UNUSED` alone.

Do not accept a `DEADPATH` at face value - find where the file actually went (`fd`/`find` across **both** repos) before proposing a fix. Most of them are the public/private overlay migration: a path that reads `~/.dotfiles/...` now lives at `~/.dotfiles-private/...`.

**2. Lessons + evals - where a skill gave wrong guidance.**

Read `~/.agent/lessons/{project}.md` and `~/.agent/evals/{project}/` (an archive since 2026-10-28; nothing new lands there). Look for:
- A correction whose root cause was a skill saying something untrue. That is a skill bug, not just a lesson - patch the source, per the skill self-repair rule in CLAUDE.md.
- The same multi-step manual workflow recurring 3+ times with no skill covering it -> a `propose` candidate.
- A lesson that contradicts a skill's stated procedure.

**3. mem0 - durable facts that outdate a skill.**

Via the `mem0-ops` skill, search for the domain of any skill you are auditing. A stored preference ("we use X now, not Y") that a skill still contradicts is a finding.

**4. Description quality - does the router pick the right skill?**

The `description` is the only thing the model sees when deciding whether to invoke. Check for:
- Two skills with overlapping trigger phrases and no "Differs from X" clause to separate them.
- Triggers that do not match how the user actually phrases the request.
- A stale "Do NOT" clause prohibiting something now standard.
- A description that describes the *implementation* rather than *when to reach for it*.

**Output.** Write `~/.agent/plans/dotfiles/skill-refine-{YYYY-MM-DD}.md`:

- A findings table: skill | type | severity | what | proposed fix. A proposed fix tries, in order: delete the stale text, merge it into a sibling, replace it with a pointer to the doc that owns it; new text only when none of those works (global CLAUDE.md, Subtract First).
- Proposed diffs for the mechanical ones, as fenced blocks - not applied.
- A "skill candidates" section from layer 2.
- An explicit "verified / unverified" split. A finding you could not check live is labelled as such, never asserted.

Rank by blast radius: a skill invoked constantly with a dead path outranks a rarely-used one with a clumsy description.

### `apply` (interactive only)

1. Read the latest report. **Re-verify each finding before acting** - the report may be up to a week old and the world moves.
2. Walk findings in rank order. For each: show the diff, confirm, edit.
3. Route the fix to the right tool:
   - Skill prose -> edit the `SKILL.md` directly.
   - CLAUDE.md registration (`GHOST`) -> the `update-rules` skill.
   - `UNDEPLOYED` -> create the symlink into `~/.claude/skills/`.
4. Re-run `skill-drift` to confirm the finding is gone and nothing new appeared.
5. If the fixed set is now the accepted state, refresh the baseline: `skill-drift --write-baseline`.
6. Land via `dotfiles-land` - public skills and private skills/CLAUDE.md are **two PRs**.

### `propose`

Turn a recurring workflow into a new skill, per the skill-candidate rule in CLAUDE.md (same multi-step manual workflow 3+ times).

1. Name the evidence: which sessions/lessons show the repetition.
2. Confirm scope and name with the user. **Never auto-create a skill file.**
3. Copy `~/.dotfiles/.claude/skills/SKILL-TEMPLATE.md` to `.claude/skills/{category}/{name}/SKILL.md`. `dotfiles-land` decides which repo.
4. Run `skill-deploy` - never hand-write the symlink. A skill that is not linked is invisible. Its description is its index entry; CLAUDE.md names it only when it collides with or replaces an existing skill (`update-rules`, "A new skill and CLAUDE.md"), and a skill it replaces is deleted in the same PR.
5. `skill-drift --lint .` before opening the PR. CI runs the same command, so a miss here is a red PR rather than a bad skill.

## Hard rules

- **Never edit a `SKILL.md` in a headless run.** The weekly job proposes; a human applies.
- **Never invent or delete a skill without confirmation.**
- **`*.example.internal` hostnames are deliberate sanitization** for the public repo (see `dotfiles-land`), not drift. Same for `AcmeCorp` and `YYYY-MM-DD` placeholders. Do not "fix" them into real hostnames - that leaks infra into a public repo.
- **Do not silence a finding by weakening the check.** If `skill-drift` is wrong, fix its logic or use the `skill-drift: ignore` line marker with a stated reason.
- **A skill is not stale just because it is old.** Verify against the filesystem before proposing a rewrite.
- **Hold every edit to `~/.local/src/docs/skills.md`**, and do not hard-wrap.

## Cadence

| Piece | Runs | Does |
|---|---|---|
| `skill-drift` | on demand; `--lint` in CI on every PR | deterministic, zero-token |
| `agentctl@docs-cleanup` | nightly 05:00 | counts drift, queues a `docs-cleanup` pass that lands fixes by PR |
| `/skill-refine audit`, `apply` | when you choose | judgment: overlaps, lesson contradictions, missing skills |

There is no sentinel watch on skill-drift: it was deleted on 2026-11-02 after 84 days red on UNUSED signals and false positives. The nightly runner reads the same findings.

## Verification

- `skill-drift` exits 0 on a clean corpus and 1 on new drift; `--json` and the human report agree on the count.
- After an `apply` pass, the specific findings addressed no longer appear.
- After a headless run, `git status` in **both** skills dirs is clean - that is the propose-only guarantee, and it is worth checking rather than assuming.
