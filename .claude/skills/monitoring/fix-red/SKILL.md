---
name: fix-red
description: >-
  Take one red to a fix: evidence, reproduce, fix the cause, re-run the probe, merge. Coordinate every red at once with an ETA per owner. Use for "fix this red", "why did this watch trip", "why is everything red", a `red` item. Why CI keeps failing: ci-failures.
metadata:
  category: monitoring
  tags: [fleet, triage, watches, runners, reds]
  reviewed: "2026-11-10"
---

# fix-red

A red is a watch tripped, a runner failed, a unit failed, or an error signature in a runner's log. `fleet-bench triage` turns each into a row, and `~/.config/agentctl/triage-routes` says where the row goes. An `agent` route queues the row as a `red` item, and that session works to this skill. A human can also run it on any red by hand.

## Scope and triggers

Use it for one red, from evidence to a merged fix or a stated reason there is no fix. Started by a `red` queue item, or by a human asking why something tripped. When the human asks about reds in general, or several are tripped, coordinate them all (section 7).

Out of scope: why CI keeps failing across runs (`ci-failures`), the red checks on one PR (`/my:fix-ci`), the playground nightly (`playground-nightly-fix`, named by its route), adding or changing a watch (`sentinel`), and spend or pace trips, which are the human's decision (`alert` route).

## 1. Read the evidence

Start from what the red wrote down, not from the row title, which stays stable on purpose and says little.

| Red | Row starts | Evidence |
| --- | --- | --- |
| Watch | `check(watch): <name> tripped` | `~/.local/state/watch-companion/<name>.out` (redacted probe tail), `watch-companion-loop list --long <name>`, and the `what`, `why`, `where` and `action` fields of `~/.agent/watches/<name>.yaml` |
| Runner | `fix(runner): <name> is` | `~/.config/agentctl/agents/<name>.conf`, then the `fleet-runners` skill |
| Unit | `fix(unit): <name> failed` | `systemctl --user status <name>`, `journalctl --user -u <name> -n 50` |
| Log error | `fix(logs): <name> error <sig>:` | the sample on the row, and that runner's `~/.local/log/<name>.log` |
| Cleanup hold | `fix(hold): <name> went red` | the row names each cleanup merge the red could be (item, PR, SHA) and what went red: the failed bats files of main's first red run, or fleet-liveness, whose evidence is its watch row above |

A watch's `action` field is the owner's own first step: do that before inventing one. If the route line names a skill, read it now at `~/.claude/skills/<skill>/SKILL.md`. It knows this cause better than this page does.

## 2. Reproduce

For a watch, run `watch-companion-loop recheck <name>` with the Bash timeout set past `SENTINEL_LOCK_WAIT` (it waits for a daemon pass to finish): it probes now, whatever the interval, and writes the state and evidence the badges read. Exit 75 means another pass held the lock, not a red: run it again. An ERROR state is the manifest failing to load, not the probe: fix the yaml first. For any other red, run the check that failed by hand. The probe is read-only; recheck writes only the watch's own state and may send its recovery page. Skip a probe that does anything else and say so.

- Green now: the red is over. Find out what cleared it, and if nothing explains it, say it is transient in the proof. Close the item with no PR.
- Still red: go on.
- Cannot run it from here: say what is missing and stop. Do not guess a cause.

## 3. Find the cause

Name the cause in one sentence, with the evidence, before editing anything. A `fix(hold)` row names suspects, not a proven cause: find which merge did it, then revert that merge in a PR or fix forward, whichever is smaller. No merge did it: say so, and fix the red itself. A second red with the same cause is one fix. `fleet-bench triage --dry-run` lists what is red right now.

Use `root-cause-analyst` when the cause is not clear after one pass over the evidence.

## 4. Fix it

Fix the thing that is broken, in the repo that owns it (`dotfiles-land` decides between the two dotfiles repos). Add the test that would have caught it.

Never make a red go away by changing the alarm: no widening a threshold, editing a probe, pausing a watch, raising a timeout, adding a retry, or deleting a row. If the watch itself is wrong, that is a real finding: say so in the PR, and change the watch only with the evidence that it is wrong.

Never touch auth tokens, logs, sqlite or other runtime state, and never restart a daemon on a guess.

## 5. Prove it, review it, merge it

Re-run the same probe or check from step 2 and put the before and after in the PR body. A fix that only takes effect after a merge or a deploy says what to re-run then; for a watch that is `watch-companion-loop recheck <name>` once it is live (merged and pulled into the main checkout, since stow links point there), so the red clears that minute and not on the watch's interval.

A red fix merges itself, at any hour, because a fix held at a PR keeps the fleet red too (`~/.config/fleet-dispatch/policy.md`). Nobody watches it merge, so it gets one more check than other work:

1. Run `/code-review high` on the diff. Fix each finding it confirms, or say in the PR why it does not apply, and put the line `Review: /code-review high, <what it found and what you did>` in the PR body.
2. Merge with `agent-land <N>`. On a tier-3 item (a harness project, or a `tier3` tag) it refuses a body without that `Review: /code-review <level>, ...` line (`n/a` or empty counts as none) or checks that never ran. The line is a claim; CI and the post-merge hold check are what catch a bad merge. It waits for every check, merges only that head and records the merge on the item. A red check is fixed, never re-run: after two failed attempts, stop and go to step 6.
3. Once the merge is live (the project's post-land step), re-run the probe. Still red is a finding: say so on the board row.

`fleet-bench reds` records whether each fix held: `fixed` while the red stays clear, `still red` or `came back` if not. `reds_unfixed` on `fleet-bench chain` counts the misses. It records each merged cleanup item the same way: `holding`, `held`, `went red` or `recovered`.

## 6. When there is no fix

A failed fix is not retried: triage skips a cause closed in the last 7 days, so an item closed as failed stays closed that long. Say what was tried and what is left, on the item.

- The fix is a decision or needs hands: file an ask or a human-sheet row (`fleet-asks`).
- The fix is larger than this session: a board row with its size, and leave the red open.
- The route is wrong: the fix is a line in `~/.config/agentctl/triage-routes`, whose header lists the routes. Every standing watch and runner must keep a line: `fleet-bench triage --coverage` lists any that lost one.

## 7. Coordinate every red

The coordinator owns the whole set until every watch's own probe reads OK, and stays open until then. It fixes nothing itself; each red has its own owner working sections 1 to 6.

1. **List every red.** It is every watch whose `~/.local/state/watch-companion/<name>.state` is not `OK`, read from the files. `watch-companion-loop tripped` showed 5 of 12 on 2026-11-10. Add failed runners and units from `fleet-bench triage --dry-run`.
2. **One owner each, running now.** For each red, find its item in `~/.agent/queue/{queued,running,waiting,review}`. If there is none, queue `red-<watch>` with `--tags red` and the evidence from its `.out` in the brief. A queued item that has not started gets `fleet-dispatch start --item <slug>`. The playground nightly is one row, owned by `playground-nightly-fix`.
3. **An ETA per owner, written down.** Write a plan, `~/.claude/plans/red-coordinator-<date>.md`, with one row per red: owner session, ETA, the basis for it, and a Scored column. Base the ETA on measured times: the item's start, plus the work, plus one probe interval, plus the CI run time where a run proves it. Do not use `fleet-bench eta`'s project median, which is sized for plan phases, not red fixes. A red that waits on something outside the fleet (a quota reset, an upstream release, the human's choice) says what it waits for and when, not a fake time.
4. **Hear each landing, never poll.** Run one `Monitor` with `inotifywait` on the watch-companion state dir and on `~/.agent/queue/{review,done,waiting}`. It emits a line when a `.state` changes or one of the set's items moves.
5. **Check each closed item against its probe.** Run `watch-companion-loop recheck <watch>`. If the watch is still red, queue `red-<watch>-2` with the merged PR, the fresh evidence and "done = the recheck exits OK", then start it. On 2026-11-10, 3 of 5 red items closed ok with their watch still red.
6. **Score and report.** At each landing, fill the Scored column (cleared at, or late by how long) and tell the human which reds cleared, which slipped and why, and the new ETA. A slip is reported when it happens, not at the end.
7. **Stop the cause, too.** If reds sat with no owner, the defect is in the routing (`triage-routes`, `fleet-bench triage`). Queue that fix as its own item; do not keep coordinating by hand.

Starting many owners at once raises load and spend, and can trip `source-pace` itself. Say that when you do it.
