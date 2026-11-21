# Priority

One meaning for every priority word the fleet uses, and the table of scales that keep their own field. A scale links here for what its levels mean and keeps only its own mechanics (who types it, which command, which reader). A scale whose level changes nothing is deleted.

## The four meanings

| Word | Means | Order it gives work | What it reaches, where a scale pages |
| --- | --- | --- | --- |
| urgent | Prod, money, data or a red on main is broken now, or the human asked for it today | Starts now | The human's phone |
| high | Blocks a release, a focus-project epic or another agent | Next in line | The phone, and the shepherd for a watch |
| normal | The default for real work | Waits its turn | Silent |
| low | Upkeep, cleanup or FYI | May wait or be dropped | Silent |

A work scale (queue, board) only orders work: it never pages. A paging scale (watch severity, page priority) adds the page rules of the `comms-standard` skill on top: a page goes out at high only when the human alone can unblock it, so a high queue item that blocks another agent is not a high page.

Why: nine scales grew apart, so "high" meant a page on one, a default on another and nothing on a third (2026-11-21 read: 68-72% of done queue items were high, 25.6 buzzes a day against a cap of 15). A level that most items carry ranks nothing.

- A scale with fewer words uses the nearest ones and says which in the table below. It never adds a fifth word.
- A level earns its place only by changing what a reader does. The "Reader and effect" column says what; an empty cell means the scale is a candidate for deletion.
- An agent never raises a label it set to urgent because its parent was urgent. Urgent comes from the human's own words or from a red; a plan phase an agent wrote is high at most.

## The scales

| Scale | Where | Levels | Maps to the four | Set by | Reader and effect |
| --- | --- | --- | --- | --- | --- |
| Queue item priority | `priority:` in an `agent-queue` item (`~/.config/agentctl/QUEUE.md`) | urgent, high, low; default high | urgent, high, low; no normal word, so default work reads high | `agent-queue add --priority`, `bump`; a session names its own | `agent-queue` order (`ORDER` in `.local/bin/agent-queue`): red, urgent, sprint, project `#prio`, then high before low; urgent runs now past the cap and the pace |
| Board row tag | `#urgent`, `#high` or `#low` on a row, exactly one (`notes-cli` README, "Row format") | urgent, high, low; untagged is untriaged and ranks as high | as the queue | the writer of the row; `agentctl-inbox-triage --backlog --priority` tags the rest | `notes-cli/src/rank.rs`: the one order rows are worked in, after a row due soon and before `#requested` |
| Retired row words | `#normal`, `#medium`, `#p0`..`#p3` | none | none | nobody: every `ptask` edit refuses to write one | no reader: a row carrying one ranks as untagged (`RETIRED_PRIORITIES` in `projects.rs`), and `notes doctor --projects` names it |
| Epic row | the same row tag on an epic row | as the board row | as the board row | as the board row | as the board row; no separate epic field exists |
| Project `#prio` | `#prio/<word>` on a project's `Version:` line | focus, high, normal (no tag), low | not a level of work: an ordering key for projects, so it maps to none | the human, `notes projects --prio <name> --set` | `agent-queue` order: ranks above an item's high or low, below red, urgent and sprint (focus, high, normal, low) |
| Runner `PRIORITY` | `PRIORITY=` in a runner conf (`~/.config/agentctl/README.md`) | must, low; required on a conf with a `ROLE`, refused on one without (no model, no reader); a runner is off by `ENABLED=no` | must is high, low is low | the runner's author | the Costs tab's Consumers (hub-core `gateway.rs`) lists each runner that has one, calls a must runner on a low team, key or source a MISMATCH and reads a stopped must runner as bad; nothing throttles on it (a consumer with its own gateway key declares `metadata.priority` on the key instead, where `off` stays a key level) |
| Runner `CRITICAL` | `CRITICAL=yes` in a runner conf | yes, no | a boolean flag only | the runner's author | the runner starts while `agentctl pause` is on (a reaper whose disk or RAM cannot wait) |
| Sentinel watch severity | `severity:` in `~/.agent/watches/<name>.yaml` (`SENTINEL.md`, "Paging") | low, normal, high, urgent | identical | the watch's author | high and urgent buzz the phone and reach the shepherd as a due line; `notify_priority:` overrides the page level; the red-watch item floor waits `TRIAGE_WATCH_HIGH_AFTER` at high or urgent |
| Alertmanager severity | `severity` label on a rule (home-config `apps/monitoring/helm-values.yaml` routes) | critical, warning, info | critical is urgent, warning is normal, info is low; a critical with `category = cost` is high, as its route already pages `ntfy-high` | the rule's author | routes: critical to `ntfy-critical` hourly (a stale-backup critical once a day), info dropped; topics `homelab-alerts`, `homelab-security` (digest) and `homelab-trading`, none of them the phone's `agents` topic |
| Ask impact | `level` of an ask (`.config/agent-ask/policy.md`, "Impact") | self, repo, fleet, critical | not a priority: it is how far a wrong answer reaches. `critical` is recorded when a human-stop rule fires (external, or not reversible) | the judge scores it; `agent-ask` adds `critical` | the judge's delay rows: a type answers itself up to its ceiling; `critical` always goes to the human |
| Page priority | `agent-notify -p low\|normal\|high\|urgent` | low, normal, high, urgent | identical | the sender, by the page table in the `comms-standard` skill ("Priority") | ntfy 2, 3, 4, 5; the phone subscribes at minimum High, so only high and urgent buzz |

Which scale to read for a question:

- What starts next: the `agent-queue` order, red, urgent, sprint, project `#prio`, then item priority.
- What the phone does: page priority; a watch's severity sets it unless `notify_priority:` says otherwise.
- What the judge answers alone: ask impact, never a priority.
- CI and release have no scale of their own. They take the four words through the table below: a red on main is urgent, a release-blocking check is high.

## What is critical, per system

DRAFT. The rows are proposed from the watches and routes that exist today, keyed by the ids in `systems.md`. They are not the rule until the human approves them in the ask filed with this doc; a changed row is edited here in the same PR that changes the watch or route it describes.

| System | Urgent: broken now | High: blocks a release or another agent | Low: may wait |
| --- | --- | --- | --- |
| ci | main red; the merge gate down for every PR | a required check red on a release branch; a quarantine entry about to expire | a flake in a non-required job |
| tests | the nightly `Tests (all)` red with no owner | a failing test in a release-blocking suite | a quarantined test with a live owner and expiry |
| deploy | a prod deploy failed or rolled back | a release run red before its promised date | deploy drift |
| telemetry | a prod health signal down (an API or a payout path returns errors) | an error or crash rate past its budget | a missing dashboard |
| docs | never | a doc that sends a release step wrong | stale wording |
| security | a leaked secret or a prod credential exposed | a critical CVE in a running image | an advisory in a dev dependency |
| auth | prod sign-in broken | a role or session bug blocking a feature | none |
| data | data loss, or a data invariant broken in prod | a stale backup; a migration blocking a release | retention tuning |
| payments | a payout wrong or failing | a purchase flow blocking a release | none |
| recovery | a host down with no restore path | a restore untested past its interval | runbook polish |
| store | a live listing pulled | a review or upload blocking a promised release | listing copy |
| save | player data lost or corrupted on update | a save migration blocking a release | none |
| netcode | the dedicated server down during a live playtest | a sync bug blocking a playtest date | none |
| gameplay, ui, input, audio, look, onboarding, perf | never | blocks a focus-project epic or a playtest date | everything else |

Fleet planes, by the same four words:

| Plane | Urgent | High | Low |
| --- | --- | --- | --- |
| queue | the human asked for it today, or a red on main | blocks a focus-project epic or another agent | upkeep; a plan phase an agent wrote is high at most |
| sessions and shepherd | a session holding a prod fix is stuck | a session another is waiting on is stuck | a session closing its own housekeeping |
| pages | prod down, overnight tests red | only the human can unblock it and waiting costs within the hour | recoveries and all-clears |
| asks | a human-stop ask on prod, money, data or secrets | a fleet-level rule change | a self-level choice the judge answers |

## Where the scales fall short today

Measured 2026-11-21; each line leaves this table when its fix lands (epic ar-4346, one phase each) and the doc then says only what is true.

| Gap | Phase |
| --- | --- |
| Agent plan phases inherit urgent; canary items file as both high and low; the done-item high share is 68-72% | P2 |
| The focus project runs 18% of done items and the low projects 78%: project `#prio` does not steer the fleet-share cap | P3 |
| Watches trader-paper-volume, neptune-health and queue-starved sit at high without meeting "high"; `alertmanager-fleet` is one fixed-high watch for every severity; session-close housekeeping pages at high; a manifest may say `severity: medium` | P4 |
| `critical` is a stop rule that reads as a level, so `judge_critical_live_pct` cannot trip | P5 |

## Checks

- A scale this doc misses shows up as a new hit of `rg -ln "^priority:|^severity:|^PRIORITY=|judge_level" ~/.agent/watches ~/.config/agentctl`: a file that is neither a watch manifest, a runner conf nor a queue item is a new scale and gets a row.
- The watch levels in use: `grep -h '^severity:' ~/.agent/watches/*.yaml | sort | uniq -c`. `SENTINEL.md` keeps no list of them.
- `fleet-bench kpi` carries `stale_urgent_d`, `buzzes_per_day` and `requested_unstarted_h`; their thresholds are in `~/.config/agentctl/kpi-thresholds`. This doc adds none.
- `tests/unit/lsd_index.bats` checks this doc has its row in `README.md`.
