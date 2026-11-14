---
name: fix-red
description: >-
  Take one red to a fix: evidence, reproduce, fix the cause, re-run the probe, review, merge; or coordinate every red: shared cause, owner, ETA, why the system tripped it. Use for "fix this red", "why did this watch trip", "take care of the reds", a `red` item. CI reds: ci-failures.
metadata:
  category: monitoring
  tags: [fleet, triage, watches, runners, reds]
  reviewed: "2026-11-14"
---

# fix-red

A red is a watch tripped, a runner failed, a unit failed, or an error signature in a runner's log. `fleet-bench triage` turns each into a row, and `~/.config/agentctl/triage-routes` says where the row goes. An `agent` route queues the row as a `red` item, and that session works to this skill. A human can also run it on any red by hand.

## Scope and triggers

Use it for one red, from evidence to a merged fix or a stated reason there is no fix. Started by a `red` queue item, or by a human asking why something tripped. A session with no red item of its own, asked about many tripped watches at once, coordinates them instead (section 7); a session holding a `red` item fixes that one red.

Out of scope: why CI keeps failing across runs (`ci-failures`), the red checks on one PR (`fix-ci`), the playground nightly (`playground-nightly-fix`, named by its route), adding or changing a watch (`sentinel`), and spend or pace trips, which are the human's decision (`alert` route).

## 1. Read the evidence

Start from what the red wrote down, not from the row title, which stays stable on purpose and says little.

| Red | Row starts | Evidence |
| --- | --- | --- |
| Watch | `check(watch): <name> tripped` | `~/.local/state/watch-companion/<name>.out` (redacted probe tail), `watch-companion-loop list --long <name>`, and the `what`, `why`, `where` and `action` fields of `~/.agent/watches/<name>.yaml` |
| Runner | `fix(runner): <name> is` | `~/.config/agentctl/agents/<name>.conf`, then the `fleet-runners` skill |
| Unit | `fix(unit): <name> failed` | `systemctl --user status <name>`, `journalctl --user -u <name> -n 50` |
| Log error | `fix(logs): <name> error <sig>:` | the sample on the row, and that runner's `~/.local/state/agentctl/<name>.stderr.log`, each run's byte range in `runs.jsonl` `err` (what triage reads) |
| Cleanup hold | `fix(hold): <name> went red` | the row names each cleanup merge the red could be (item, PR, SHA) and what went red: the failed bats files of main's first red run, or fleet-liveness, whose evidence is its watch row above; a liveness hold names only merges that changed the conf or a COMMAND file of a runner its probe names, so a red from a shared lib or another repo files no hold row, only its runner row |

A watch's `action` field is the owner's own first step: do that before inventing one. If the route line names a skill, read it now at `~/.claude/skills/<skill>/SKILL.md`. It knows this cause better than this page does.

## 2. Reproduce

For a watch, run `watch-companion-loop recheck <name>` with the Bash timeout set past `SENTINEL_LOCK_WAIT` (it waits for a daemon pass to finish): it probes now, whatever the interval, and writes the state and evidence the badges read. Exit 75 means another pass held the lock, not a red: run it again. An ERROR state is the manifest failing to load, not the probe: fix the yaml first. For any other red, run the check that failed by hand. The probe is read-only; recheck writes only the watch's own state and may send its recovery page. Skip a probe that does anything else and say so.

- Green now: the red is over. Find out what cleared it, and if nothing explains it, say it is transient in the proof. Close the item with no PR.
- Still red: go on.
- Cannot run it from here: say what is missing and stop. Do not guess a cause.

## 3. Find the cause

Name the cause in one sentence, with the evidence, before editing anything. A `fix(hold)` row names suspects, not a proven cause: find which merge did it, then revert that merge in a PR or fix forward, whichever is smaller. No merge did it: say so, and fix the red itself. A second red with the same cause is one fix. `fleet-bench triage --dry-run` lists what is red right now.

When the cause is not clear after one pass over the evidence, work it through `debug` from Prove the target to Root cause (steps 2 to 6).

## 4. Fix it

Fix the thing that is broken, in the repo that owns it (`dotfiles-land` decides between the two dotfiles repos). Add the test that would have caught it.

Never make a red go away by changing the alarm: no widening a threshold, editing a probe, pausing a watch, raising a timeout, adding a retry, or deleting a row. If the watch itself is wrong, that is a real finding: say so in the PR, and change the watch only with the evidence that it is wrong.

Never touch auth tokens, logs, sqlite or other runtime state, and never restart a daemon on a guess.

## 5. Prove it, review it, merge it

Re-run the same probe or check from step 2 and put the before and after in the PR body. A fix that only takes effect after a merge or a deploy says what to re-run then; for a watch that is `watch-companion-loop resolve <name> --pr <owner/repo#N>` once it is live (merged and pulled into the main checkout, since stow links point there): it records the merge as the watch's watermark, so a windowed probe (a 24h or 7d count) counts only events after the fix, and rechecks, so the red clears that minute and not when the window ages out. A new event after the merge still trips it.

A red fix merges itself, at any hour, because a fix held at a PR keeps the fleet red too (`~/.config/fleet-dispatch/policy.md`). Nobody watches it merge, so it gets one more check than other work:

1. Run `/code-review high` on the diff. Fix each finding it confirms, or say in the PR why it does not apply, and put the line `Review: /code-review high, <what it found and what you did>` in the PR body.
2. Merge with `agent-land <N>`. On a tier-3 item (a harness project, or a `tier3` tag) it refuses a body without that `Review: /code-review <level>, ...` line (`n/a` or empty counts as none) or checks that never ran. The line is a claim; CI and the post-merge hold check are what catch a bad merge. It waits for every check, merges only that head and records the merge on the item. A red check is fixed, never re-run: after two failed attempts, stop and go to step 6.
3. Once the merge is live (the project's post-land step), re-run the probe. Still red is a finding: say so on the board row.

`fleet-bench reds` records whether each fix held: `fixed` while the red stays clear, `still red` or `came back` if not, and `alert route` when `triage-routes` sends its red to `alert` (a watch that pages on a KPI past its bound, which no merge clears). `reds_unfixed` on `fleet-bench chain` counts the misses, never an `alert route`. It records each merged cleanup item the same way: `holding`, `held`, `went red` or `recovered`.

## 6. When there is no fix

Triage counts a cause as owned only while an item tagged with its `cause:` is open (`cause_tries` in `fleet-bench`). Once that item closes with the red still there, it queues a retry, tagged `retry:<earlier slugs>`, up to `TRIAGE_FIX_TRIES` items in `TRIAGE_FIX_DAYS`, and after that it files a human-sheet row saying the fixes did not hold. Say what was tried and what is left, on the item.

- Another queue item owns the fix (another project's work, or an item held on an ask): add this item's `cause:` tag to that item (`agent-queue set <owner> tags="<its tags> cause:<hash>"`), then close this one. Without the tag, triage cannot see the owner and files the red again.
- The fix is a decision or needs hands: file an ask or a human-sheet row (`fleet-asks`).
- The fix is larger than this session: a board row with its size, and leave the red open.
- The route is wrong: the fix is a line in `~/.config/agentctl/triage-routes`, whose header lists the routes. Every standing watch and runner must keep a line: `fleet-bench triage --coverage` lists any that lost one.

## 7. Coordinate every red

Only for a session with no `red` item of its own. "Take care of the reds" means the reds get fixed in this session. The goal is the global health rollup `cc:overall_status` out of red (2) before the session ends, then each yellow item on its way to green. Queueing owners and closing stale items moves nothing the human sees.

1. **Read what holds the rollup red.** Prometheus is `CC_PROM_URL` in `~/.config/command-center/env`. `cc:watch_state == 2` and `cc:component_status == 2` name the items at red; `cc:watch_state == 1` the yellow ones. Those red items come first, whatever the count of tripped watches says: one watch at 2 holds the rollup red while a dozen sit at 1. A watch that aggregates (`alertmanager-fleet`) names what it counts in its manifest, `~/.agent/watches/<name>.yaml`: run its probe to list each alert. An empty `cc:overall_status` means the rules are not loaded, never green.
2. **List every red** from the files, not from `watch-companion-loop tripped`, which can show fewer: each `~/.local/state/watch-companion/<name>.state` reading `TRIP` or `ERROR`. Add failed runners and units from `fleet-bench triage --dry-run`.
3. **Group by cause, then ask why the system tripped.** Reds that share a signature in their `why` (an `Unauthorized` on every kubectl probe, one host in several alerts) are one cause: one fixer, and the rest close on its recheck. Put each group in one class, in a table in the plan file (step 6):
   - **Real fault**: the probe read its source and the source is broken. Fix it now (step 4).
   - **Blind probe**: the probe could not read its source (expired credential, unreachable API, too little history) and reported a fault. Fix the access, then queue one item so the probe says `unreadable` instead of naming a fault, unless one exists.
   - **Owner never started**: the red's item has sat in `queued/` past an hour. A red the red floor should have started is a dispatch bug, fixed in `fleet-dispatch` with a test. Proof is a live pass in `~/.local/state/agentctl/fleet-dispatch/activity.log` that starts it, never a dry run that says it would: a dry run reads the gates at one moment, and a live pass can take an earlier branch.
   - **Alert route**: spend, pace, a provider outage. The human's call, and fix nothing. Before asking, read the number fresh from its source (a cap from `~/.local/state/fleet/budget.json`, not an older note) and the project anchor's Decisions log: a choice the human already made is reported as expected yellow, not asked again. Otherwise file its ask (`agent-ask post`).
4. **Fix every real fault in this session.** One fixer subagent per cause (Agent tool, run in the background, one brief each with the evidence and sections 1 to 6), all started in one message, no more at once than the red floor line of `fleet-dispatch headroom` allows; the coordinator takes the cause nearest its own context. Before a fixer starts on a red's queue item, the coordinator claims it (`agent-queue claim <slug>`), so dispatch does not start a second owner, and closes it when the fixer's PR lands. Queue a red for dispatch only when this session cannot reach its fix (another machine's access, a long CI cycle), and say so. The playground nightly is one row, owned by `playground-nightly-fix`: check a session is on it, else start one.
5. **One owner each.** Find the red's item first: the triage item (`check(watch): <name> tripped`) or any item in `~/.agent/queue/{queued,running,waiting,review}` naming the watch. Queue `red-<watch>` (`--tags red`, the `.out` evidence in the brief) only when none exists. A red with no item means triage missed it: queue that routing fix too (`triage-routes`, `fleet-bench triage`). An item whose watch now reads OK is stale: close it with the recheck as its note.
6. **An ETA per red, written down.** Keep `~/.claude/plans/red-coordinator-<date>.md` with one row per red: class, owner, ETA, basis. A fixer of this session: its expected finish. A queued item: the start-to-finish times of recently closed `red` items in `~/.agent/queue/done/`, plus one probe interval, plus its proving CI run. A red that waits outside the fleet (a quota reset, an upstream release, an ask) names what it waits for and when.
7. **Check each fix against its probe.** Run `watch-companion-loop resolve <watch> --pr <its merged PR>` (or `recheck <watch>` with no PR) and read the printed state (exit 75 means another pass held the lock: run it again). Still `TRIP` means the fix missed: read the fresh evidence and fix again. After two misses, write the diagnosis into the plan. Hear queued owners land with one `Monitor` on the state dir and `~/.agent/queue/{review,done,waiting}` (`inotifywait -m -r`), never a poll.
8. **Finish on the rollup.** Re-read `cc:overall_status`. The coordinator is not done while it reads 2, unless every item at 2 waits on a filed ask, reset or upstream release, named with its date in the plan. Report to the human: the rollup before and after, each cause and its fix (PR), what is still yellow and what clears it.

Starting many fixers at once raises load and spend, and can trip `source-pace` itself. Say so when you do it.
