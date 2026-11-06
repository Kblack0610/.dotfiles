---
name: fix-red
description: >-
  Take one red to a fix: read its evidence, reproduce it, fix the cause, re-run the probe, review and merge it. Use for "fix this red", "why did this watch trip", "investigate this fault", or a `red` queue item. Why CI keeps failing: ci-failures.
metadata:
  category: monitoring
  tags: [fleet, triage, watches, runners, reds]
  reviewed: "2026-11-06"
---

# fix-red

A red is a watch tripped, a runner failed, a unit failed, or an error signature in a runner's log. `fleet-bench triage` turns each into a row, and `~/.config/agentctl/triage-routes` says where the row goes. An `agent` route queues the row as a `red` item, and that session works to this skill. A human can also run it on any red by hand.

## Scope and triggers

Use it for one red, from evidence to a merged fix or a stated reason there is no fix. Started by a `red` queue item, or by a human asking why something tripped.

Out of scope: why CI keeps failing across runs (`ci-failures`), the red checks on one PR (`/my:fix-ci`), the playground nightly (`playground-nightly-fix`, named by its route), adding or changing a watch (`sentinel`), and spend or pace trips, which are the human's decision (`alert` route).

## 1. Read the evidence

Start from what the red wrote down, not from the row title, which stays stable on purpose and says little.

| Red | Row starts | Evidence |
| --- | --- | --- |
| Watch | `check(watch): <name> tripped` | `~/.local/state/watch-companion/<name>.out` (redacted probe tail), `watch-companion-loop list --long <name>`, and the `what`, `why`, `where` and `action` fields of `~/.agent/watches/<name>.yaml` |
| Runner | `fix(runner): <name> is` | `~/.config/agentctl/agents/<name>.conf`, then the `fleet-runners` skill |
| Unit | `fix(unit): <name> failed` | `systemctl --user status <name>`, `journalctl --user -u <name> -n 50` |
| Log error | `fix(logs): <name> error <sig>:` | the sample on the row, and that runner's `~/.local/log/<name>.log` |

A watch's `action` field is the owner's own first step: do that before inventing one. If the route line names a skill, read it now at `~/.claude/skills/<skill>/SKILL.md`. It knows this cause better than this page does.

## 2. Reproduce

Run the watch's `expect_cmd`, or the check that failed, by hand. Probes are read-only, so this is safe. Skip a probe that does anything else and say so.

- Green now: the red is over. Find out what cleared it, and if nothing explains it, say it is transient in the proof. Close the item with no PR.
- Still red: go on.
- Cannot run it from here: say what is missing and stop. Do not guess a cause.

## 3. Find the cause

Name the cause in one sentence, with the evidence, before editing anything. A second red with the same cause is one fix. `fleet-bench triage --dry-run` lists what is red right now.

Use `root-cause-analyst` when the cause is not clear after one pass over the evidence.

## 4. Fix it

Fix the thing that is broken, in the repo that owns it (`dotfiles-land` decides between the two dotfiles repos). Add the test that would have caught it.

Never make a red go away by changing the alarm: no widening a threshold, editing a probe, pausing a watch, raising a timeout, adding a retry, or deleting a row. If the watch itself is wrong, that is a real finding: say so in the PR, and change the watch only with the evidence that it is wrong.

Never touch auth tokens, logs, sqlite or other runtime state, and never restart a daemon on a guess.

## 5. Prove it, review it, merge it

Re-run the same probe or check from step 2 and put the before and after in the PR body. A fix that only takes effect after a merge or a deploy says what to re-run then.

A red fix merges itself, at any hour, because a fix held at a PR keeps the fleet red too (`~/.config/fleet-dispatch/policy.md`). Nobody watches it merge, so it gets one more check than other work:

1. Run `/code-review high` on the diff. Fix each finding it confirms, or say in the PR why it does not apply.
2. Merge with `agent-land <N>`. It waits for every check, merges only that head and records the merge on the item. A red check is fixed, never re-run: after two failed attempts, stop and go to step 6.
3. Once the merge is live (the project's post-land step), re-run the probe. Still red is a finding: say so on the board row.

`fleet-bench reds` records whether each fix held: `fixed` while the red stays clear, `still red` or `came back` if not. `reds_unfixed` on `fleet-bench chain` counts the misses.

## 6. When there is no fix

A failed fix is not retried: triage skips a cause closed in the last 7 days, so an item closed as failed stays closed that long. Say what was tried and what is left, on the item.

- The fix is a decision or needs hands: file an ask or a human-sheet row (`fleet-asks`).
- The fix is larger than this session: a board row with its size, and leave the red open.
- The route is wrong: the fix is a line in `~/.config/agentctl/triage-routes`, whose header lists the routes. Every standing watch and runner must keep a line: `fleet-bench triage --coverage` lists any that lost one.
