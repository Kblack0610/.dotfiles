# Plan standard

What every plan answers, at any scale, plus the sections a project's type adds. `.claude/hooks/plan-standard.sh` checks only the `Chain:`, `Phases:` and `Epic:` rules below: it injects them while a plan forms and denies `ExitPlanMode` when a plan breaks one. The Sections table is the written standard, read by the author and the human, and no hook checks it (the human released that gate, 2026-11-22). Each row holds a real failure; a new row must cite one, and a row whose failure has not recurred gets removed in a cleanup pass.

The type comes from `type` in `project-map.json`, or the one type shared by the projects under a repo. A project with no type gets the base only. Overlays only add sections.

## Sections

Backticked labels in `Must answer` belong in that section. In `Applies`, `base` means every plan.

| Section | Applies | Must answer | Why it earns a place |
| --- | --- | --- | --- |
| `## Changes` | base | What the plan changes, read first: `Adds:` and `Removes:` one line per file or kind with an approximate size, `Files:` the board rows, queue items, alerts and epics it files, `Net:` the size in one line. Approximate: the exact diff lives in the PR | 11-21: a retire-the-band-aids plan read as more work because the 10 rows it filed sat in step 4 |
| `## Context` | base | The ask restated, and what done looks like. A number only for capacity or performance work | Intent misreads: on 10-31 "full build" meant a release |
| `## Approach` | base | What we will do, the claims it rests on checked at HEAD, and a `Rejected:` line for the alternatives | Unverified premises: an 11-03 audit read a checkout 6 commits behind |
| `## Reviewed` | base | `Existing:` every reader, writer and pre-existing instance affected, and every other mechanism that already does this job: fold it, or say why it stays. `Overlap:` open rows, plans and PRs checked. `Standards:` docs read, as paths on that line. A plan with `## Phases` adds a Best practice line | 04-30: 4 of 6 PRs were redundant. 10-30: old saves had no migration. 11-07: queue_rank shipped beside #prio for the same job |
| `## Risks` | base | What could go wrong, how reversible it is, and what the human must decide rather than the agent | 10-16: plan approval was not layout approval |
| `## Verification` | base | The real surface it is proved on, a negative control, and when it is actually live (merge is not live); for a CLI or report the human reads, the agent-web page that shows it (`dashboards.md` rule 14) | The highest failure count. 10-18: green but unusable. 09-17: fix ticked while prod stayed exposed |
| `## Source of truth` | infra, app | Which store owns each fact, the one writer, what this removes | 09-18: a retired database stayed online 74 days |
| `## Telemetry` | infra, app | The signal at each link of the chain, where it surfaces, what alerts. Reuse Sentinel, `fleet-bench` and the dashboards | 10-29: a gate starved 8 hours. 09-20: a gallery sat stale 24 days behind a 200 |
| `## Target` | infra | Which environment, which owning layer, and rollback if exposed or irreversible | 10-31: a DNS record survived the revert |
| `## Release` | app, game | Store impact, risk lane, regulated data, critical e2e paths. A plan that cuts or uploads a build is held to the bar in `~/.claude/skills/release/SKILL.md` | Skipped lanes reach users: `release-coordinator`, `compliance`, `bnb-quality-gates`, `release` |
| `## Playtest` | game | Which game, gate class, multiplayer proof, what only human play can judge, perf or look evidence, rating impact | 11-02: physics feel is only found by playing |

Scaling (advisory, unchecked): a section that does not apply says `n/a: <reason>`, except Changes, Context and Verification, which always have content. A plan with more than one phase may not use `n/a`; a one-phase checklist (one-shot writes one on every plan) may.

Depth (advisory, unchecked): a plan with phases or one that crosses systems runs the standards, telemetry and overlap checks as parallel Explore agents before writing, and cites what they found in `## Reviewed`.

Chain: a plan with more than one open `- [ ]` phase runs as a chain, one fresh session per phase (`agent-queue add --plan`, `~/.local/src/docs/lifecycle.md`, "Taking an epic on"). A plan whose text says it runs or does its work in this session or one session is denied. Why: 2026-11-18 one session held four phases through 5 compactions, and another started five phases at once.

Phases: a plan with more than one phase carries a `## Phases` checklist, one line per phase: `- [ ] <name>` open, `- [x] <name> (#PR)` landed, `- [-] <name>: <why>, <board row>` deferred by the human. `fleet-sessions` reads it, and the session winds down when none is unchecked and no ask is open. A PR that supersedes a plan writes `Superseded by #N` as the first line under its title (`fleet-states.md`).

Found work: work a phase finds that the plan needs (a blocker, a missing piece) is a phase of that plan: a new `- [ ] P<N> <what> takes <row-id> (after N; needs ...)` line with a fresh `P<N>` label, placed above the phase that needs it, never a loose row under a standing epic. `agent-queue add --plan <plan>` run again files that line once and gates the phase below it on it, and `agent-land` refuses a phase whose item filed an open agent row that no phase line takes, until it is taken or the human drops it. Why: 2026-11-24 two rows the CI plan needed (hc-1014, hc-1012) sat under a standing epic, outside the plan, while its chain ran.

Epic: a plan names the epic it serves on a lowercase `epic: <id>` line, the id of an `epic(` row on a lab sheet; a fix or upkeep with no feature epic names its system's standing epic (`~/.local/src/docs/lifecycle.md`, "What an epic is"), and a plan with more than one phase is a feature, so it names its own epic, never a standing "to standard" one. A feature with no epic yet proposes one as `epic: new epic(<system>): <outcome>`, with no priority (an epic ranks as its most urgent open row), a system `project-stage-check <project> --list` lists, with every row `notes ptask similar` shows for it on both lanes named on `Overlap:` as other work; `plan-standard.sh` checks that, and on approval `plan-approved.sh` files it (a session the human opened) or sends it to inbox-triage (an unattended one), and `agent-queue add --plan` files no phase until it is settled. The project a plan is checked and filed on is the one its rows name (the `epic:` id's code, else the `Overlap:` ids when they share one), and the session's cwd only when they name none, so a session in one repo can plan another's work. A project with no board (client work tracked elsewhere) is exempt. Why: 2026-11-18 the ci-runner-governor reached 2036 lines across six plans, none of which named an epic, so nothing owned or verified the whole.

Client work adds the rows in `~/.config/agentctl/PLANNING-CLIENT.md`, kept private. Their Applies column is the `client` value in `project-map.json`.

## Where to look

| Area | Read |
| --- | --- |
| Agent runtime | `~/.local/src/docs/standards.md`, `~/.local/src/docs/fleet-states.md`, `~/.config/agentctl/ARCHITECTURE.md`, `~/.config/agentctl/QUEUE.md` |
| Monitoring | `~/.config/agentctl/SENTINEL.md`, skill `sentinel` |
| CI | `~/.local/src/docs/ci.md`, skill `ci-cleanup` |
| Dashboards | `~/.local/src/docs/dashboards.md` |
| Claude hooks | `~/.dotfiles/.claude/hooks/README.md` |
| Tickets | `~/.dotfiles-private/.local/src/ticket/docs/contract.md` |
| Shell and provisioning | skills `shell-test-harness`, `provision-capture` |
| Infrastructure | `~/dev/home/home-config/CLAUDE.md`, `~/dev/home/home-config/docs/gitops.md` |
| Apps | `~/dev/bnb/platform/docs/testing/CRITICAL_PATHS.md`, `~/dev/bnb/platform/docs/compliance/`, skills `release-coordinator`, `bnb-quality-gates`, `compliance` |
| Games | In the playground repo: `docs/development/standards.md`, `docs/development/multiplayer-testing.md`, `docs/operations/ci.md`, `docs/operations/game-eval.md`, `docs/authoring/`, `docs/operations/steam.md`; skills `game-eval`, `content-rating`, `release` |
