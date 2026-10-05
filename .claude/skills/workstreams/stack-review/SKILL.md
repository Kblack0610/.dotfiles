---
name: stack-review
description: >-
  Whole-repo, current-state health review of any codebase and any stack - what is broken
  right now, what is slow on the hot path, what is duplicated or has drifted between copies,
  where module boundaries and folder structure will not scale, and which quality gates are
  missing - with a file:line, a measured or first-hand-verified piece of evidence, and a
  concrete why for every finding, ranked by impact x effort. Use when the user asks "any
  cleanup we should do", "review the stack", "how healthy is this codebase", "what should we
  fix before this scales", "DRY this up", "is the folder structure right", "performance pass",
  "tech debt scan", or "make the components modular". Verbs - review (default, report only) |
  fix (land the safe tier as scoped PRs, only on request) | plan (rest into board rows and
  kb-architect specs). Differs from drift-audit (a time window of recent work), code-hygiene
  and simplify (one diff), bug-bash (functional bugs), ui-audit / delta-audit (screens), and
  sc:analyze (one generic focus, no verify pass). kb-architect's audit / debt-scan commands
  point here for the procedure; kb-architect designs the fixes this hands over.
metadata:
  category: workstreams
  tags: [audit, architecture, performance, refactor, tech-debt]
  reviewed: "2026-10-05"
---

# stack-review

A codebase rots in five ways that no diff review sees: wiring breaks silently (a unit points at a moved file and fails every hour), a hot path grows O(n) with data nobody prunes, the same helper is copied until one copy drifts, module and folder boundaries stop matching how the code is actually used, and the gates that would have caught all of it run at the wrong severity or not at all. This skill finds those, proves each one, and ranks them so the first fix is the one that matters most. The output is a report; fixes happen only when asked.

It is stack-agnostic. The procedure is fixed; the tools come from whatever the repo already uses (`references/tools.md`).

## When to Use

- "any cleanup we should do", "review the stack / codebase", "tech debt scan", "what breaks first when this grows"
- Before a big feature or a team scaling up on a repo, to know what to fix first
- When `kb-architect` is asked to `audit` or `debt-scan` (it points here)

Not for: work that landed in a recent window (`drift-audit`), one diff (`code-hygiene`, `simplify`, `code-review`), functional bugs (`bug-bash`), live UI (`ui-audit`, `delta-audit`), security review (`security-review` / `security-engineer`).

## Verbs

| Verb | Does | Edits? |
|---|---|---|
| `review` (default) | Steps 1-6, writes the report | No |
| `fix` | Lands the report's **safe tier** (below) as one PR per concern | Yes, only when asked |
| `plan` | Turns the remaining findings into agent-board rows; hands design-heavy ones to `kb-architect` as a spec request | Board only |

`fix` and `plan` take an existing report. If none exists for today, run `review` first.

## Steps

### 1. Fingerprint the stack (before any opinion)

Read, in this order, and note what each says:
- The repo's `CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md`; when it has none, the global ones that apply to it (`~/.claude/CLAUDE.md`, `~/AGENTS.md`). Also any quality-gate skill for it (e.g. `bnb-quality-gates`). These decide what counts as a finding - do not recommend a tool or pattern the repo has rejected on purpose.
- `~/.agent/lessons/{project}.md`: do not read it end to end (it can run to thousands of lines). Grep it in Step 5 for each dependency, framework or pattern you are about to recommend; a lesson that prohibits it wins.
- Sizes: `tokei` or `scc` if installed, else `git ls-files | xargs wc -l` per top-level dir and per language. List the 20 largest code files.
- Manifests and lockfiles (package.json/pnpm-workspace, Cargo.toml, go.mod, pyproject, Gemfile, build.gradle), CI workflows, lint/format/test config, and what each gate actually blocks on vs reports.
- Hot paths: code that runs per request, per event, per hook, per frame, per keystroke, or on every CI run. Name them explicitly.
- Deployment model: if the repo is deployed by copy or link (stow, chezmoi, an installer, a container image), "broken wiring" includes tracked files that never reach the deploy target. Note how to check that.

**Measure the hot paths now, before Step 3.** Parallel agents load the machine and skew timings; record the load average next to every number. Measure without mutating, in this order: (1) the system's own records - the tool's logs with timestamps, `journalctl`, systemd's "Consumed" CPU line, CI job durations; (2) a copy - `git archive HEAD` into a scratch dir, a scratch `HOME=`, copied data files; (3) stub binaries on `PATH` for anything that would touch live state (tmux, a database, the network). Fallbacks when `hyperfine` is missing: a `time` loop over N runs.

Record the fingerprint at the top of the report. It is also how a reader judges whether the findings fit the stack.

### 2. Run the stack's own tools

Use `references/tools.md` for the per-language table. Rules:
- Only tools already installed or already declared by the repo. Never add a dependency to the target repo in order to audit it; if a valuable tool is missing, that is itself a Gates finding.
- Run read-only modes only (`--check`, `--dry-run`, no `--fix`, no `--write`).
- Bound every run with `timeout` so one hung tool does not stall the review.
- Raw tool output is evidence to verify in Step 4. A `knip` "unused export" is a lead; whether it can be deleted is decided by tracing callers.

### 3. Fan out across the fixed dimensions

Launch Explore agents in parallel (one message, 3-4 agents). Each prompt carries:
- the fingerprint and the tool output relevant to its dimension
- a **known list**: everything Steps 1-2 already found, marked "do not re-report"
- the **ownership rules** below, so overlapping dimensions do not duplicate work
- "return findings as `file:line | what | evidence | measurement-if-any`, no fixes, no files written, no long scans left running in the background"

Ownership: a reference to a missing path or a failing unit belongs to 3a; two copies of anything, including two path encoders or two parsers, belong to 3b; size, placement and boundaries belong to 3c; anything with a timing belongs to 3d.

- 3a. Broken wiring + dead code: config, units, routes, imports, symlinks, scripts and docs that reference a path or symbol that no longer exists; services that fail on schedule (`systemctl --user --failed`, cron logs, CI history); files nothing references (trace callers, entry points, schedulers, keybinds, docs - all of them); retired dirs still present.
- 3b. Duplication + drift: the same helper, constant, path encoding, config read, or parser implemented in 2+ places; for each cluster, diff the copies and say whether they have **already drifted** (the highest-value finding in this dimension, because a drifted copy is a live bug). Also: shared libs that exist but are bypassed.
- 3c. Modularity + structure + conventions: files and functions far above the repo's own median; modules with mixed responsibilities (handlers + IO + parsing in one file); dependency direction violations and cycles (madge / dependency-cruiser / `cargo tree` / import graphs); programs living where siblings of their kind do not; a tool spread across many locations; naming and strict-mode inconsistencies that cause real confusion.
- 3d. Performance + scaling + gates: on each hot path from Step 1 - process spawns in loops, whole-file reads of unbounded files, O(n) work per event where n grows forever, caches and logs nothing prunes, network calls with no timeout, N+1 queries, re-parsing the same input many times. **Time** the worst ones with real data (`time`, `hyperfine`, a profiler) on a copy, never on live state. Gates: what runs advisory that should block, what is not installed where it is assumed, which hot paths have no test.

### 4. Verify adversarially

Agents will return more findings than you can re-check. Triage: every finding headed for High or for the safe tier gets re-checked first-hand by you rather than by the agent that reported it; the rest may stay `unverified`. Re-check means: read the line, run the command, query the unit, time the loop, grep for callers again. Write a verdict:

- `verified` - you reproduced it; say how in one clause
- `contradicted` - it is wrong; keep it in a short "contradicted" list so the next run does not re-report it
- `unverified` - plausible, could not check; never ranks above Medium

A suspected problem you measured and cleared (nobody claimed it, it was just a candidate) goes in "Leave alone" with the number, so the next run does not chase it.

An agent's confident paragraph is not evidence. A measurement or a line you read is.

### 5. Rank

Score each finding by impact (who or what is hurt, how often, how badly) and effort (S/M/L), then place it in a tier:

1. **Broken now** - wrong behavior today (failing units, drifted copies that compute the wrong answer, dangling references on a live path)
2. **Hot-path performance** - measured cost on something that runs constantly, or a cost that grows without bound
3. **DRY / one source of truth** - duplication, especially clusters that have drifted or will
4. **Structure for scaling** - boundaries, folder layout, monoliths, build topology
5. **Gates** - what would stop the next instance of tiers 1-4 from landing

Every finding carries a concrete **why**: the failure it causes or will cause, for whom, when. "Best practice", "cleaner" or "more modular" alone is not a why - if you cannot name the cost, it is not a finding. Also record **what to leave alone and why** (e.g. "split this 2,000-line file when a feature next touches it, not before") - a review that only adds work is not a judgment.

One finding, one tier: pick the tier of the harm. A red CI job nobody reads is Tier 1 if the thing it tests is broken, and the "nobody is told" half is a separate Tier 5 row that references it.

**Safe tier** (what `fix` may touch): verified, mechanical, behavior-preserving or a clear bug fix, small, inside one concern, and with a check that proves it. Everything else is a `plan` item.

### 6. Write the report

Path: `~/.agent/evals/{project}/stack-review-<YYYY-MM-DD>/report.md`. Never inside the target repo. Use `references/report-template.md`. Plain ASCII.

Run as a subagent, you may not be allowed to write files: return the full report as text and the parent writes it to the path. Skip the Artifact offer in that case too.

Run in the main session, offer in one line to publish it as an Artifact when the user will share it; publish without asking if they said a team or reviewer will read it.

In the chat reply give the top findings per tier with their why, the verified/unverified count, and the report path. The full report stays in the file.

## fix

1. Re-read the report; take only safe-tier rows with verdict `verified`.
2. Group by concern; one branch + PR per concern, cut from the remote tip in a worktree (`ingest-worktree` for a mixed tree; the repo's own landing rules otherwise).
3. Each fix lands with the check that proves it (a test, a timing, a unit that now starts). A perf fix states before/after numbers in the PR body.
4. Update the report's rows with the PR reference. Anything that turned out bigger than safe goes back to `plan`.

## plan

1. For each non-safe finding, one agent-board row (`notes ptask <project> --agent add "<short title>"`) or the repo's tracker, with the report path. Fold into existing rows; do not duplicate.
2. Findings that need a design (a module split, a workspace, a new shared lib with several callers) go to `kb-architect` as a spec request quoting the finding, its evidence and its why.
3. Never place rows into a planned release/wave - that is the human's call.

## Do NOT

- Edit anything in `review`. A report that quietly fixed things cannot be trusted as a report.
- Delete on a single "unused" signal. Static tools miss dynamic entry points (slash commands, systemd units, keybinds, reflection, string-built paths). Trace every caller class before calling something dead.
- Sweep-reformat or mass-rename a repo. That is an unreviewable diff with no defect behind it.
- Split a large file with no feature driving it. A split is risk; do it when the next real change pays for it.
- Add a tool, dependency or framework to the target repo to make the audit possible.
- Recommend a pattern the repo's rules or lessons reject, or a second copy of a config as a "fix". One source of truth: the fix for duplication is routing every caller to the canonical one.
- Report a performance problem you did not measure as High. Guessing at hot spots is how reviews send people to optimize the wrong thing.
- Run destructive or server-starting probes on the user's live machine; use a copy or the repo's container harness.
