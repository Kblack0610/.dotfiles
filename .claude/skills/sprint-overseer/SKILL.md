---
name: sprint-overseer
description: >-
  Sprint Overseer — watchdog and single notification voice for /kb:sprint batch runs. Use when
  the user says "watch the sprint", "how's the batch going", "is the sprint stuck", "escalate
  that block", or "wrap up the sprint report" — and as the recurring half of a sprint via
  `/loop 10m /sprint-overseer watch`. Verbs: watch | status | escalate | report. It OBSERVES,
  VERIFIES, and NOTIFIES — it has no execution verb: it never dispatches agents, never merges or
  closes PRs, never flips tracker state, and never touches release gates. Execution belongs to
  the /kb:sprint dispatcher; queueing to kb-sprint-owner; release analysis to release-coordinator.
  Prefer /captain as the user entry point — this skill is internal watchdog machinery; the
  canonical loop line is `/loop 10m /captain watch` (which runs this skill's watch pass).
---

# sprint-overseer

The watchdog half of the sprint loop. The `/kb:sprint` dispatcher executes tickets; this skill
watches the shared blackboard, independently verifies what the dispatcher claims, and is the
**single notification voice** to the user via `agent-notify`. It composes, never duplicates:

| Concern | Owned by |
|---|---|
| Build/prioritize the queue | `kb-sprint-owner` agent |
| Execute tickets (kb-coordinator, CI monitor, merge, Done fallback) | `/kb:sprint` command |
| Watch the run, verify claims, detect stalls | **this skill** (`watch`) |
| Notify the user (merged / blocked / stall / batch done) | **this skill** (single voice) |
| Release analysis after the batch | `release-coordinator` skill (handoff only) |

The blackboard: `~/.agent/plans/{project}/sprint-{YYYY-MM-DD}.md` (newest file with non-terminal
rows is "the active sprint"). Delegate the legwork to the `sprint-overseer` agent (Argus 👁️) for
headless/loop runs.

## Hard constraints (read first, non-negotiable)

1. **Observe rung only.** Never dispatch agents, edit code, push, merge, close PRs, or flip
   tracker state. If an action is needed, the notification names the command for the human
   (`/kb:sprint resume`, the PR URL, the punch list).
2. **Release gates apply verbatim** (release-coordinator's constraints): never touch release tags,
   the Vikunja `HUMAN:` line, or GitHub approval issues.
3. **Only writes:** `agent-notify` calls, `notified: <ticket> <event>` markers in the Run log,
   and the `## Batch summary` section. Nothing else.
4. **Verify, don't trust — including "completed".** A row's Status is the dispatcher's claim, and an
   Agent "completed" event means only "no exception at the supervisor level", NOT that the work
   finished. Before notifying "merged", re-check `gh pr view <pr> --json state,mergedAt` and the
   ticket's done flag. For audit/fix rows, re-check the **disk sentinel**: the agent's
   `~/.agent/plans/{project}/checkpoints/{ticket}.md` must end with `STATUS: DONE`. The overseer's
   value is independent verification — if it parrots the dispatcher (or the "completed" event) it's
   dead weight.

## Event catalog (the ONLY notifications)

| Event | Priority | Verified trigger |
|---|---|---|
| ticket merged | normal | `mergedAt` set + tracker done flag (note if fallback `ticket done` was used) |
| ticket blocked/errored | high | row `blocked`/`error` + `## Blocks` entry; ping includes the punch-list head |
| stall | high | no Run-log append AND no observable change on the in-progress row (PR head SHA, check states, tracker labels) for **>30 min** → "dispatcher may be dead — resume with `/kb:sprint resume`" |
| false-completion | high | the Agent reported "completed" but the row's checkpoint sentinel is NOT `STATUS: DONE` (it's `FAILED`/`PARTIAL`/absent) and live `gh`/tracker doesn't prove done → "agent died mid-run, work unfinished — resume with `/captain resume`". This is the exact failure that hid a model-outage death behind a `completed · 16h` event. |
| batch complete | normal | all rows terminal **and sentinel-confirmed**; sent with the `report` summary |

Dedupe: every fired event appends `notified: <ticket> <event>` to the Run log. A pass fires only
unmarked events — re-running is always safe, and a missed event self-heals on the next pass.

## Verb: `watch`

One idempotent observation pass — designed to be the recurring half of a sprint:

```
/loop 10m /sprint-overseer watch
```

1. Find the active sprint file; if none, say so and stop (no notification).
2. For every non-terminal row and every terminal row without a `notified:` marker:
   verify against live systems (`gh pr view/checks`, tracker state via MCP or `ticket` CLI) **and the
   row's checkpoint sentinel** (`checkpoints/{ticket}.md` tail). A row claiming `done`/`completed`
   whose sentinel isn't `STATUS: DONE` is a **false-completion**, not a merge.
3. Fire `agent-notify` for each unmarked event per the catalog
   (`agent-notify -t "sprint" -p <prio> "<event>"`); append the marker.
4. Check stall: compare the Run log tail timestamp and the in-progress row's observable state
   (incl. the checkpoint mtime) against the previous pass; >30 min frozen → stall event.
5. If all rows are terminal **and sentinel-confirmed** and no `## Batch summary` exists → run `report`.

This pass is observe-only and idempotent, so it is safe to run headlessly on a schedule. The captain
arms the **autonomous watchdog** (`captain-watchdog`, a user systemd timer running `claude -p
"/captain watch"`) so these notifications fire without the user keeping a `/loop` session open; the
user-run `/loop 10m /captain watch` is an optional live-tail equivalent.

## Verb: `status`

Same dashboard printed to the session — queue table with verified states, Run-log tail, any
divergence between claimed and verified state. **No notifications, no markers.** Safe anytime.

## Verb: `escalate <ticket>`

Force a high-priority notify for a specific blocked ticket, regardless of markers: punch-list
head, what the human must decide, and the PR/ticket links. Marks `notified: <ticket> escalated`.

## Verb: `report`

End-of-batch (or on demand for a post-mortem of an aborted sprint):

1. Write `## Batch summary` into the sprint file: merged/blocked/skipped counts, PR list,
   duration (Started → last terminal event), blocks needing human decisions.
2. Send the batch-complete notification, ending with the handoff line:
   "next: `/release-coordinator status` or `plan`".
3. Does **not** invoke release-coordinator — the human (or a normal session) picks it up; merged PRs
   surface in the captain's `status` automatically via `git log $LAST_TAG..origin/develop`.

## Operational model

- Dispatcher (`/kb:sprint run`) lives in the **main session** — synchronously busy inside Task
  calls. The watch pass runs **out-of-band** so it survives dispatcher death — primarily via the
  captain's **autonomous watchdog** (`captain-watchdog` systemd timer, headless `claude -p`), and/or
  a user `/loop 10m /captain watch` second session. Stall + false-completion detection are the reason
  this is a separate process; the user is never required to host it.
- The dispatcher's only notification is its own terminal abort (it can't assume the overseer
  loop is running). Everything else is this skill's voice — never double-ping.
- `agent-notify` (`~/.dotfiles/.local/bin/agent-notify`) fans out to every configured channel:
  ntfy (`NTFY_URL`), Slack (`SLACK_WEBHOOK_URL`), desktop (`DISPLAY`). Always exits 0 — a
  notification must never fail a pass.

## Related

- `/kb:sprint` — dispatcher (plan/run/resume/status) + sprint plan file schema
- `kb-sprint-owner` agent — queue builder
- `~/.dotfiles/.claude/agents/sprint-overseer.md` — agent definition (delegate `watch` legwork
  to it as a subagent for headless/loop runs)
- `release-coordinator` — downstream handoff target; its hard constraints are inherited here
- `loop` skill — the recurrence mechanism
