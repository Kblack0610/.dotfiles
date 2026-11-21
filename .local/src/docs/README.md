# Cross-repo doctrine

This directory, deployed as `~/.local/src/docs/`, holds the rules that span more than one repo, one doc per subject. A repo's own doc keeps only its specifics (where its picker lives, its runners, its store accounts) and links to the doc here for the rest, never restating a rule. The knowledge base (`~/.notes/knowledge/`) holds hubs that link to these docs plus what we learned that they do not say.

The front door to the agentic system is `~/.config/agentctl/ARCHITECTURE.md`: the map of every plane, flow and instrument. Start there for a question about the fleet. Start here for a rule a change must meet.

| Doc | Its one job |
| --- | --- |
| [analysis-streams.md](analysis-streams.md) | The method every analysis stream and cleanup pass follows: baseline, finding, fix at the cause, re-measure, report |
| [api-clients.md](api-clients.md) | How every repo calls a third-party API: one paced client per provider, shared budget, backoff, bounded retries |
| [ci.md](ci.md) | CI doctrine for every repo: tiers, the merge gate's budget, what a red gets |
| [dashboards.md](dashboards.md) | What a dashboard shows and how to add or change a tab, section or tile (hub, agent-web, waybar, Grafana) |
| [fleet-states.md](fleet-states.md) | The fleet state document and its words: buckets, activity, the close verdict ([fleet-close-flow.svg](fleet-close-flow.svg) is its picture) |
| [judges.md](judges.md) | How a judge or scored runner is graded against each lane's ground truth |
| [layout.md](layout.md) | Where code, tooling, config, tests and docs go in a repo; `repo-layout-check` checks it |
| [lifecycle.md](lifecycle.md) | Which step a piece of work is at, from idea to verified, and each step's template and check |
| [machine-mode.md](machine-mode.md) | How much of the workstation background work may use, in four modes |
| [planning.md](planning.md) | What every plan answers, per project type; `plan-standard.sh` checks it |
| [release.md](release.md) | What every release is held to across repos: gates, tags and versions, proof of live, rollback, who takes each public step, per store |
| [skills.md](skills.md) | What every skill, command and agent file holds to; `skill-drift` checks it |
| [stages.md](stages.md) | How mature a project is, what each stage must have, and the check that proves it |
| [standards.md](standards.md) | The agent runtime's rules, each invariant or provisional, with the test that fails when it breaks |
| [systems.md](systems.md) | What each part of a project is and the criteria that say it is built to standard |
| [ui.md](ui.md) | How every UI we build looks, web and TUI |

A new doc gets its row here in the same PR; `tests/unit/lsd_index.bats` fails on a doc with no row and on a row with no doc.
