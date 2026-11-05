# Plan standard

What every plan answers, at any scale, plus the sections a project's type adds. `.claude/hooks/plan-standard.sh` reads the tables below: it injects them while a plan forms and denies `ExitPlanMode` when a plan misses them, so changing a row here changes the check. Each row holds a real failure; a new row must cite one, and a row that catches nothing gets removed.

The type comes from `type` in `project-map.json`, or the one type shared by the projects under a repo. A project with no type gets the base only. Overlays only add sections.

## Sections

Backticked labels in `Must answer` are required in that section. In `Applies`, `base` means every plan.

| Section | Applies | Must answer | Why it earns a place |
| --- | --- | --- | --- |
| `## Context` | base | The ask restated, and what done looks like. A number only for capacity or performance work | Intent misreads: on 10-31 "full build" meant a release |
| `## Approach` | base | What we will do, the claims it rests on checked at HEAD, and a `Rejected:` line for the alternatives | Unverified premises: an 11-03 audit read a checkout 6 commits behind |
| `## Reviewed` | base | `Existing:` every reader, writer and pre-existing instance affected. `Overlap:` open rows, plans and PRs checked. `Standards:` docs read, as paths on that line. A plan with `## Phases` adds a Best practice line | 04-30: 4 of 6 PRs were redundant. 10-30: old saves had no migration |
| `## Risks` | base | What could go wrong, how reversible it is, and what the human must decide rather than the agent | 10-16: plan approval was not layout approval |
| `## Verification` | base | The real surface it is proved on, a negative control, and when it is actually live (merge is not live) | The highest failure count. 10-18: green but unusable. 09-17: fix ticked while prod stayed exposed |
| `## Source of truth` | infra, app | Which store owns each fact, the one writer, what this removes | 09-18: a retired database stayed online 74 days |
| `## Telemetry` | infra, app | The signal at each link of the chain, where it surfaces, what alerts. Reuse Sentinel, `fleet-bench` and the dashboards | 10-29: a gate starved 8 hours. 09-20: a gallery sat stale 24 days behind a 200 |
| `## Target` | infra | Which environment, which owning layer, and rollback if exposed or irreversible | 10-31: a DNS record survived the revert |
| `## Release` | app | Risk lane, regulated data, critical e2e paths, store impact | Skipped lanes reach users: `release-coordinator`, `compliance`, `bnb-quality-gates` |
| `## Playtest` | game | Which game, gate class, multiplayer proof, what only human play can judge, perf or look evidence, rating impact | 11-02: physics feel is only found by playing |

Scaling: a section that does not apply says `n/a: <reason>`, except Context and Verification, which always have content. A plan with `## Phases` may not use `n/a`.

Depth: a plan with phases or one that crosses systems runs the standards, telemetry and overlap checks as parallel Explore agents before writing, and cites what they found in `## Reviewed`.

Client work adds the rows in `~/.config/agentctl/PLANNING-CLIENT.md`, kept private. Their Applies column is the `client` value in `project-map.json`.

## Where to look

| Area | Read |
| --- | --- |
| Agent runtime | `~/.local/src/docs/standards.md`, `~/.local/src/docs/fleet-states.md`, `~/.config/agentctl/ARCHITECTURE.md`, `~/.config/agentctl/QUEUE.md` |
| Monitoring | `~/.config/agentctl/SENTINEL.md`, skill `sentinel` |
| Dashboards | `~/.local/src/docs/dashboards.md` |
| Claude hooks | `~/.dotfiles/.claude/hooks/README.md` |
| Tickets | `~/.dotfiles-private/.local/src/ticket/docs/contract.md` |
| Shell and provisioning | skills `shell-test-harness`, `provision-capture` |
| Infrastructure | `~/dev/home/home-config/CLAUDE.md`, `~/dev/home/home-config/docs/gitops.md` |
| Apps | `~/dev/bnb/platform/docs/testing/CRITICAL_PATHS.md`, `~/dev/bnb/platform/docs/compliance/`, skills `release-coordinator`, `bnb-quality-gates`, `compliance` |
| Games | In the playground repo: `docs/development/standards.md`, `docs/development/multiplayer-testing.md`, `docs/operations/ci.md`, `docs/operations/game-eval.md`, `docs/authoring/`; skills `game-eval`, `content-rating` |
