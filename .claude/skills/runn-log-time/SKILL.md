---
name: runn-log-time
description: Reconstruct and submit a Gigantic Playground Runn time-sheet from the day's activity already captured in this account's MCPs (ClickUp, git, Runn). Use when the user says "log my time in Runn", "fill out Runn", "Runn time entries", "log my hours for today/this week", "fill the gaps in Runn", "Runn timesheet", or otherwise asks to back-fill Runn. Default algorithm per day is 8h target = 2h fixed Communications + ~6h distributed across substantive work derived from git commits (author = kenneth.black@giganticplayground.com) and ClickUp activity, mapped to Runn projects discovered live via Runn MCP. Always draft → review → confirm → submit; never write to Runn without explicit confirmation.
---

# runn-log-time

Reconstructs a Runn time-sheet from the activity the user already produces during the day (commits in local Gigantic repos + tasks touched in ClickUp) and proposes a fully filled-in draft. The user reviews, edits, then confirms — only then does the skill submit to Runn via MCP.

Runn instance: `runn.gp.gigaplayops.com` (Gigantic Playground).
User git identity for Gigantic work: `kenneth.black@giganticplayground.com`.

## When to invoke

- "log my time in Runn (for today / yesterday / this week / 2026-05-12)"
- "fill out my Runn timesheet"
- "fill the gaps in Runn" (back-fill unlogged days in the last ~2 weeks)
- End-of-day / end-of-week prompts where the user wants Runn filled
- The user mentions Runn + time entries / hours / billable

Don't auto-invoke on every Runn mention — only when the verb is *log / fill / track / submit time*. For "show my Runn forecast" or capacity questions, use Runn MCP directly without this skill.

## Algorithm

Per target day:

```
8h target
  − existing Runn entries already on that day        (idempotency)
  − Communications bucket (default 2h, flag override)
  = remaining hours to distribute across work groups
```

Work groups come from:

1. **Git commits** authored by the user in Gigantic repos that day.
2. **ClickUp activity** — tasks the user touched (created, commented, status-changed, time-tracked) that day.

Groups → Runn projects via runtime name-matching, with a prompt on ambiguity.

Hours distributed in 15-minute increments, weighted by `(commit_count + clickup_task_count)` per group, capped at 4h per single entry to avoid lopsided rows.

## Auth precheck

Runn MCP at `https://runn.gp.gigaplayops.com/mcp` is OAuth-gated. Until the OAuth flow completes in the current session, only `mcp__claude_ai_Runn_MCP__authenticate` and `mcp__claude_ai_Runn_MCP__complete_authentication` are exposed.

1. Attempt a read-only Runn call (e.g. list projects / list my time entries).
2. If the schema isn't available, call `mcp__claude_ai_Runn_MCP__authenticate`, surface the returned authorization URL to the user, wait for them to authorize, and ask them to paste the full `http://localhost:<port>/callback?code=...&state=...` URL.
3. Call `mcp__claude_ai_Runn_MCP__complete_authentication` with that callback URL, then re-attempt the read.
4. Don't cache auth across sessions — re-check each invocation.

## Inputs

All inputs are interpreted in-conversation; there is no shell entrypoint. Equivalent forms:

| Form | Behavior |
|---|---|
| (no arg) | Log today |
| `yesterday` | Log yesterday |
| `2026-05-12` (ISO date) | Log that specific date |
| `2026-05-12..2026-05-15` | Log each weekday in the inclusive range |
| `--week` / "this week" | Log current ISO week, Mon–Fri |
| `--gaps` / "fill the gaps" | Scan last 14 calendar days; propose entries for weekdays with < 8h logged in Runn |
| `--comms <hours>` | Override the default 2h Communications allocation (e.g. `--comms 1` for a quiet day, `--comms 3` for a heavy meeting day) |

## Per-day pipeline

### Step 1 — Pull activity (parallel where possible)

**Git** — auto-discover Gigantic repos and pull commits authored that day.

```bash
# Auto-discover candidate repos
find ~/dev/gigantic-playground ~/dev/gigantic* -maxdepth 2 -name .git -type d 2>/dev/null \
  | xargs -n1 dirname

# For each candidate, list user's commits for the target day
git -C <repo> log \
  --author='kenneth.black@giganticplayground.com' \
  --since="<DATE> 00:00" --until="<DATE> 23:59" \
  --pretty=format:'%h%x09%ad%x09%s' --date=iso-strict
```

Repos with zero matching commits in the window are dropped.

**ClickUp** — find tasks the user touched on the day, and any time already logged there.

- `mcp__claude_ai_ClickUp__clickup_resolve_assignees` with `"me"` → user ID (one-time per session)
- `mcp__claude_ai_ClickUp__clickup_search` with `filters.assignees=[<me>]`, `filters.created_date_from / created_date_to` set to the target day boundaries, `filters.asset_types=["task"]`, sort by `updated_at desc`
- `mcp__claude_ai_ClickUp__clickup_get_time_entries` with `assignee_id=<me>`, `start_date` / `end_date` = target day → ClickUp-logged time (visibility only; Runn is the system of record, not ClickUp)

**Runn** — list projects (for the mapping step) and list the user's existing time entries on the target day (for idempotency).

(Exact Runn MCP tool names become visible after auth; use whatever the server exposes for "list projects" and "list my time entries for date X". Treat their schemas as authoritative — don't assume field names from this doc.)

### Step 2 — Bucket into work groups

- Reserve `comms_hours` (default 2) → group **"Communications"**.
- Group git commits by repo: one group per repo that had commits.
- Group ClickUp tasks by their Space / List (whichever is the natural project granularity in this workspace; ask user on first ambiguous run and remember the choice for the rest of the session).
- Merge a git-repo group and a ClickUp-list group if their natural Runn project is the same (resolved in Step 3).

### Step 3 — Map groups → Runn projects

1. Pull Runn project list (post-auth).
2. For each group, attempt a name match against Runn projects:
   - Exact, case-insensitive match wins.
   - Substring or token-overlap match is a *candidate*, not a decision.
3. On ambiguity (multiple candidates or none), ask the user once and remember the chosen mapping for the rest of the run.
4. "Communications" maps to whatever Runn project the user uses for internal/admin time. Ask on first run; reuse thereafter.

### Step 4 — Distribute hours

```
remaining = 8 − existing_runn_hours_on_day − comms_hours
weights   = commit_count + clickup_task_count per group
hours_per_group = round_to_15min(remaining * weight / sum(weights))
```

- Round each row to 0.25h. Adjust the largest row up or down by 0.25h to make the day sum exactly to 8h.
- Cap any single row at 4h. Overflow spills into the next-largest group.
- If the user worked only on one thing (one group, one repo), don't force-split — let it take the full remaining bucket (still capped at 4h; the residual stays as a "Misc / context" row only if the user asks).

### Step 5 — Draft descriptions

One short line per group (target ≤ 80 chars):

- Lead with the dominant verb pattern from commit subjects + ClickUp task titles (e.g. `Scaffolding`, `BSN.Cloud sync debug`, `runn-log-time skill design`).
- If a *nuance* is visible in the raw activity, append it as a parenthetical:
  - Multi-repo session in one day → `(2 repos)`
  - Late first commit (e.g. after 11:00 local) → `(late start)`
  - High commit count with many `fix` / `revert` → `(N reverts — flaky)`
  - ClickUp task moved back from Done → In Progress → `(re-opened)`
  - Large gap between first and last commit with sparse middle → `(stretched session)`
- Skip the nuance line if nothing actually surfaces. Default to clinical.
- The phrase "hate-myself variation" from the original request is a joke; do not act on it literally. The signal is "surface nuances when they exist".

### Step 6 — Present the draft

Print a table per day; for multi-day runs, print each day's table separately, then a summary.

```
Date: 2026-05-15  (Friday)
─────────────────────────────────────────────────────────────────
Runn project          Hours   Description
─────────────────────────────────────────────────────────────────
Communications        2.00    Slack/email/standup
gp-knowledge          2.25    Scaffolding + brightsign-ops skill lift
brightsign-bdeploy    2.75    BSN.Cloud sync debug (3 reverts — flaky)
Internal R&D          1.00    runn-log-time skill design
─────────────────────────────────────────────────────────────────
Total                 8.00
```

Then ask:

> Submit, edit (which row + new hours/desc/project), or skip?

If the user edits, re-show the table with the change applied and ask again. Loop until `submit` or `skip`.

### Step 7 — Submit

Only on explicit `submit`:

- One Runn MCP create-entry call per row.
- Per-row success/failure report.
- On failure, leave the failed rows in a residual draft so the user can retry, fix mapping, or escalate.

Never submit a row that duplicates an existing Runn entry on that day (same project + same description). The idempotency check in Step 1 already filters most of this; this is the belt-and-suspenders check.

## Gap-fill mode (`--gaps`)

1. Query Runn for the user's time entries in the last 14 calendar days.
2. Compute logged hours per weekday (Mon–Fri only; skip weekends unless the user asks).
3. For each weekday with `< 8h logged`, run Steps 1–5 per day.
4. Present *all* candidate days as separate tables, then prompt `submit-all / submit-day <date> / edit <date> <row> / skip-day <date> / skip-all`.

Don't propose entries for today in `--gaps` mode unless the user explicitly asks — today is usually still in progress.

## Idempotency rules

- Read existing Runn entries for the target day *before* drafting. Subtract their hours from the 8h target.
- Never re-submit a row identical to one that already exists (same project + same date + description match).
- Re-running the skill twice on the same day should propose 0 hours on the second run (assuming the first submission succeeded).
- If the user submitted manually in the Runn UI between runs, the idempotency read picks it up; do not overwrite.

## Gotchas and assumptions

- **Git author filter** is hard-coded to `kenneth.black@giganticplayground.com`. Commits authored under a different identity (personal email, pair-programmed co-author trailer) will be missed. If the user reports missing work, check `git config user.email` in the relevant repo.
- **Repo discovery** scans `~/dev/gigantic-playground/*` and `~/dev/gigantic*`. If the user starts keeping Gigantic repos elsewhere (e.g. `~/work/`, `~/clients/gigantic/`), widen the glob in Step 1.
- **Default 2h Communications** is a flat allocation, not derived. If the user wants it data-driven, the Google Calendar MCP (`mcp__claude_ai_Google_Calendar__*`) and Slack MCP (`mcp__claude_ai_Slack__*`) are configured on this account and could be queried in a future revision; v1 keeps it flat.
- **Runn project mapping** is session-scoped, not persisted. If the user runs the skill across many sessions, they'll re-confirm ambiguous mappings each time. If this becomes annoying, persist the mapping to a small JSON sidecar in this skill's dir.
- **ClickUp time entries are not authoritative** — Runn is the system of record for billable hours. We *read* ClickUp time entries only as a hint for what the user worked on; we don't try to mirror them.
- **15-minute rounding** can leave the daily sum 0.25h off the 8h target after capping. Always adjust the largest row to make the sum exactly 8.00.
- **Multi-day runs** can be slow because each day needs its own MCP round-trip. Tell the user up front when a run will exceed ~5 days.
- **OAuth re-auth** happens silently on token expiry inside the MCP server; surface any auth errors to the user verbatim rather than retrying invisibly.

## Related

- `mcp__claude_ai_Runn_MCP__*` — target system (write path). Tools beyond `authenticate` only visible post-OAuth.
- `mcp__claude_ai_ClickUp__*` — primary read source for non-git activity. Key tools: `clickup_search`, `clickup_resolve_assignees`, `clickup_get_time_entries`.
- `mcp__claude_ai_Google_Calendar__*`, `mcp__claude_ai_Slack__*`, `mcp__claude_ai_Gmail__*` — configured but unused in v1; candidates for Communications-bucket data-driven refinement.
- `~/.claude/CLAUDE.md` — Memory Routing + "Prefer skills over raw tooling and MCPs". This skill is the canonical Runn time-log path; raw MCP calls should be reserved for non-time-logging Runn questions (capacity, forecasts).
- `~/.dotfiles/.claude/skills/placemyparents-release/SKILL.md` — pattern reference for in-conversation multi-step pipelines.
- Sister skills for the broader workflow: `notes-system` (daily journal often has the same activity signal), `mem0-ops` (if the user wants the Runn-project mapping persisted cross-session).
