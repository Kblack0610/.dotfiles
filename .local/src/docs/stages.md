# Project stages

How mature a project is, what it must have at each stage, and which check proves it. One ladder for every project type and for every game inside the playground.

- The stage is a hashtag on the lab sheet's `Version:` line, for example `Version: v0.3.0 #alpha`. Its one writer is `notes projects --stage <name> --set <stage>`; a hand edit works too, and the nightly `project-map-doctor` catches a sheet that drifts.
- The ladder itself has one definition, `STAGES` in `.local/src/notes-cli/src/projects.rs`. Shell readers get it from `notes projects --stages` (or `lab_stages` and `lab_stage_at_least` in `.local/lib/lab-feed.sh`) and never keep a copy.
- The project type (`game`, `app`, `infra`) comes from `type` in `project-map.json`, the same field `planning.md` reads.

## The ladder

The deploy pipeline is built at the dev -> alpha gate. An alpha project already deploys itself to a private target on every merge, so the beta step only changes who uses it and on which channel.

| Stage | Means | Who uses it | Where it runs | What the tooling does |
| --- | --- | --- | --- | --- |
| `draft` | A concept with its type standard and target load named, already scaffolded on the shared stack | the human | CI only | Hidden behind `d` in the `Prefix+p` popup; fleet-dispatch skips it |
| `dev` | Built to its type standard, CI green, the core loop or flow being built | the human and agents | CI artifacts | fleet-dispatch starts agent sessions on its rows |
| `alpha` | Works start to finish and deploys itself to a private target on every merge | the human and the team | home-k3s preview, Play internal, Steam `development`, TestFlight internal, Forgejo registry, Quest sideload | One working list, no releases |
| `beta` | Versioned releases to outside testers, rollback proven, load tested | testers | TestFlight external, Play closed, Steam `beta`, a public preview URL | `projects --release` allowed; `agentctl-wave-roll` rolls it; STATUS goes STALE after 14 days |
| `prod` | Public, watched, with runbooks | the public | stores, Steam `default`, the prod cluster | As beta, plus the doctor FAILs it without a shipped tag |

A project with no stage sorts between dev and draft and is dispatched like a draft. The doctor WARNs on it.

## Requirements

Entering a stage means meeting its rows and every row of the stages below it. In `Applies`, `base` means every type. `Checked by` names the check that exists today; `not yet (ar-322)` rows are the standard the `notes projects --check` gate will enforce, and until then they are reviewed by hand when the stage is set. A row that starts with `human:` is something only the human can do or attest.

| Stage | Applies | Requirement | Checked by |
| --- | --- | --- | --- |
| draft | base | A `project-map.json` entry with a `type`, and a lab sheet | `project-map-doctor` |
| draft | base | A brief (`one-pager`) that names the type standard it will meet and a target load as a number: CCU, users, rows | not yet (ar-322) |
| draft | game | Repo or folder cut from the unity-core template on the `com.blacknbrown.*` packages | not yet (ar-322) |
| draft | app | Repo cut from the platform generator (`pnpm create:mobile-app`, `create:package`) on `packages/ui` and the shared config | not yet (ar-322) |
| dev | base | CI green on the default branch | not yet (ar-322) |
| dev | base | README with build, run and test; `docs/architecture.md`; a standards file or a link to the shared one | not yet (ar-322) |
| dev | game | A build profile in `scripts/build/games/<id>.json` and a headless test class | not yet (ar-322) |
| dev | app | Typecheck, lint and unit tests in the shared CI config | not yet (ar-322) |
| alpha | base | A deploy workflow green to the private target on every merge | not yet (ar-322) |
| alpha | base | Its secrets listed by name and synced to every destination | not yet (P4 `secrets-sync --check`) |
| alpha | base | A perf baseline measured on the real deploy target | not yet (ar-322) |
| alpha | base | `docs/overview.md` (what it is, its features, status) and `docs/operations/deploy.md` | not yet (ar-322) |
| alpha | game | Plays start to finish; `perf-round` numbers recorded; a multiplayer smoke if networked | not yet (ar-322) |
| alpha | app | Critical-path e2e in CI; a preview environment that deploys itself | not yet (ar-322) |
| alpha | game, app | Its store listing set up through the internal channel, by the procedure in `~/.notes/lab/bnb/practices/release/stores.md`; console forms go through the `store-console` skill | not yet (ar-322) |
| beta | base | Releases enabled | `notes projects --release` refuses below beta |
| beta | base | A CHANGELOG; the external-channel pipeline green; one rollback actually done; a load test at the brief's number | not yet (ar-322) |
| beta | base | A Sentinel health watch | not yet (ar-322) |
| beta | base | A STATUS line under 14 days old | `regen-anchor.sh` marks it STALE |
| beta | game | Content rating done (`content-rating`) | not yet (ar-322) |
| beta | game | human: a finished playtest on this version | not yet (ar-322) |
| beta | app | A privacy and compliance check when it holds regulated data; the store listing via `mobile-store-metadata` | not yet (ar-322) |
| beta | game, app | Its external tester channel live (TestFlight external, Play closed, Steam `beta`), by the same `stores.md` procedure | not yet (ar-322) |
| prod | base | A shipped version tag | `project-map-doctor` |
| prod | base | A prod smoke suite; an incident and rollback runbook; a credentials inventory with an expiry alarm | not yet (ar-322) |
| prod | base | human: approve the public publish | not yet (ar-322) |
| prod | game | Live on Steam `default` or a public store channel | not yet (ar-322) |

Infra projects (dotfiles, agent-runtime, home-config) skip the store rows: their alpha means deployed by stow or Flux from main, and beta and prod mean others depend on it, so a health watch and a runbook.

## Docs per stage

Each doc comes from an existing skill. There are no doc types beyond these.

| Stage | Doc | Written with |
| --- | --- | --- |
| draft | brief | `one-pager` |
| dev | README, `docs/architecture.md` | `docs-write` |
| alpha | `docs/overview.md`, `docs/operations/deploy.md` | `docs-write` |
| beta | CHANGELOG; for an app, the PRD and TSD | `changelog-draft`, `scope` |
| beta | content rating, store listing | `content-rating`, `mobile-store-metadata` |
| prod | incident and rollback runbook, credentials inventory | `docs-write` |

## What stays with the human

These are never automated; each one is a `human:` row, filed on the human sheet when the gate runs.

- Logins and 2FA on store consoles, payment, legal attestations, Apple and Play review, console dev-kit NDAs.
- A finished playtest before a game enters beta.
- The final public Publish or Submit click. The `store-console` skill fills a console up to it and stops. `stores.md` says which store steps are API, workflow, skill or person.

## Games: one ladder per game

A game in the playground carries the same ladder as its `status` field (`Draft`, `Dev`, `Alpha`, `Beta`, `Prod`). The rules for moving one game up live with the game code, in the playground's `docs/authoring/adding-a-game.md`; this doc does not repeat them.

A game project's lab stage must equal its game's `status` on the default branch. `project-map-doctor` compares the two (check 6d) and FAILs on a mismatch, naming both places to fix.

## Changing this doc

A row that will be checked must name its check, and a new row must cite the failure it prevents, as `planning.md` requires. Changing the ladder itself means changing `STAGES`, the playground's `GameStatus` and the registry admin dropdown in the same change; the doctor's 6d check catches a game that is left behind.
