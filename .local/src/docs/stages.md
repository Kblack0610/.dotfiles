# Project stages

How mature a project is, what it must have at each stage, and which check proves it. One ladder for every project type and for every game inside the playground.

- The stage is a hashtag on the lab sheet's `Version:` line, for example `Version: v0.3.0 #alpha`. Its one writer is `notes projects --stage <name> --set <stage>`; a hand edit works too, and the nightly `project-map-doctor` catches a sheet that drifts.
- The ladder itself has one definition, `STAGES` in `.local/src/notes-cli/src/projects.rs`. Shell readers get it from `notes projects --stages` (or `lab_stages` and `lab_stage_at_least` in `.local/lib/lab-feed.sh`) and never keep a copy.
- The project type (`game`, `app`, `infra`) comes from `type` in `project-map.json`, the same field `planning.md` reads.
- A project's type standard is its systems and their criteria, base plus its type's overlay, in `systems.md`; `project-system-check <name>` reports met/total per system.

## The ladder

The deploy pipeline is built at the dev -> alpha gate. An alpha project already deploys itself to a private target on every merge, so the beta step only changes who uses it and on which channel. The stage says what a project must have, never where it may deploy: a deploy is not the app being live, so a draft or dev project with a prod target is fine (the human, 2026-11-12). Each registry target's `channel` maps to the rung it serves in the `project-map.json` `channels` map (the Registry channels column); `release-state` turns that into each project's served rungs, and the Requirements rows below read them.

| Stage | Means | Who uses it | Where it runs | Registry channels | What the tooling does |
| --- | --- | --- | --- | --- | --- |
| `draft` | A concept with its type standard and target load named, already scaffolded on the shared stack | the human | CI only | none | Hidden behind `d` in the `Prefix+p` popup; fleet-dispatch skips it |
| `dev` | Built to its type standard, CI green, the core loop or flow being built | the human and agents | CI artifacts | none | fleet-dispatch starts agent sessions on its rows |
| `alpha` | Works start to finish and deploys itself to a private target on every merge | the human and the team | home-k3s preview, Play internal, Steam `development`, TestFlight internal, Forgejo registry, Quest sideload | `alpha`, `preview`, `internal` | Releases on its cadence (see Versions) |
| `beta` | Versioned releases to outside testers, rollback proven, load tested | testers | TestFlight external, Play closed, Steam `beta`, a public preview URL | `beta` | As alpha; STATUS goes STALE after 14 days |
| `prod` | Public, watched, with runbooks | the public | stores, Steam `default`, the prod cluster | `prod` | As beta, plus the doctor FAILs it without a shipped tag |

A project with no stage sorts between dev and draft and is dispatched like a draft. The doctor WARNs on it.

## Requirements

Entering a stage means meeting its rows and every row of the stages below it. In `Applies`, `base` means every type. `project-stage-check <name> [--stage s] [--json]` runs the rows (`--json` gives met, total, fail, human, todo, the gate and each row, for a page to read): `notes projects --stage <name> --set <s>` runs it on a move up and refuses to move the tag on a blocking FAIL (a move down is never gated), and `project-map-doctor` runs it for every staged project each night.

A gap becomes work with `--file`, a reconcile: each FAIL row is filed as a `#size/s` story on the agent board under the open epic for its target, and each open agent row whose title now PASSes is closed with the check as its proof. The target is `--stage s`, else the highest of the stage after the declared one (prod checks itself) and the stages open `epic(stage): <stage> to standard` rows name, so an epic opened for a later stage keeps its work coming and a leftover one for a passed stage holds nothing back. A row whose title both passes and fails (two rows sharing a text) counts as failing. With no open stage epic it files `epic(stage): <target> to standard` on the human sheet first; with `--systems` a row goes through `notes ptask add`, which links its system's standing epic. It never refiles a row already on either sheet under the same title, open, done or dropped. It runs when `notes projects --stage <p> --set <s>` moves a project up, and each night in the `project-index` pass for every project at dev or later; what runs first is dispatch's job, by `#prio`.

Enforced from: 2026-11-19

Before that date a FAIL is reported and blocks nothing, so a row that turns out too strict can be fixed before it stops real work.

The `Check` cell is one of three things:
- a backticked shell predicate, run in a subshell from the project's root with `NAME`, `TYPE`, `REPO`, `ROOT`, `LAB` and `STAGE` (the stage being checked, so a row judges a move up the same as today's stage) set, and `project-name.sh` and `lab-feed.sh` loaded. `ROOT` is the project's folder in its repo (`trackers.<name>.path`, as `apps/<app>` in a monorepo), else the repo; with no project folder it runs from an empty directory, so a project file reads as missing rather than matching a repo-root or lab file. A repo the map names but this machine has not cloned is not judged (exit 2). A missing project folder inside an available repo reports criteria gaps; predicates can still read `REPO` and `LAB`, and `ROOT` keeps its mapped path. Exit 0 is PASS. It reads local files, git and the `release-state` snapshot only, never the network, so a night run is quick and repeatable. Write a literal pipe as `\|`.
- `human`: only the human can attest it, so the gate lists it and never fails on it.
- anything else: no predicate yet. The gate lists it as TODO with this text, which names what checks it today, if anything.

| Stage | Applies | Requirement | Check |
| --- | --- | --- | --- |
| draft | base | A `project-map.json` entry with a `type`, and a lab sheet | `[ -n "$TYPE" ] && [ -f "$LAB/README.md" ]` |
| draft | base | A brief (`one-pager`) that names the type standard it will meet and a target load as a number: CCU, users, rows | `grep -qil 'target load' "$LAB"/docs/briefs/*.md` |
| draft | game | Repo or folder cut from the unity-core template on the `com.blacknbrown.*` packages | `grep -q '"com.blacknbrown\.' "$REPO/Packages/manifest.json"` |
| draft | app | Repo cut from the platform generator (`pnpm create:mobile-app`, `create:package`) on `packages/ui` and the shared config | not yet |
| dev | base | CI green on the default branch | not yet: needs the forge API |
| dev | base | The `docs` system meets its `systems.md` criteria: a README with build, run and test, `docs/architecture.md`, a standards file or a link to the shared one | `project-stage-check "$NAME" --system docs` |
| dev | game | A build profile in `scripts/build/games/<id>.json` and a headless test class | `[ "$ROOT" = "$REPO" ] \|\| { g="$(basename "$ROOT")"; [ -f "$REPO/scripts/build/games/$(printf %s "$g" \| tr '[:upper:]' '[:lower:]').json" ] && git -C "$REPO" ls-files \| grep -qi "/$g[a-z0-9]*PlayTests\.cs$"; }` |
| dev | app | Typecheck, lint and unit tests in the shared CI config | `jq -e '.scripts.typecheck and .scripts.lint and .scripts.test' "$REPO/package.json"` |
| alpha | base | A deploy workflow green to the private target on every merge | not yet: needs the forge API |
| alpha | base | Its secrets listed by name and synced to every destination | not yet: P4 `secrets-sync --check` |
| alpha | base | A perf baseline measured on the real deploy target | not yet |
| alpha | base | `docs/overview.md` (what it is, its features, status) and `docs/operations/deploy.md` | `[ -f docs/overview.md ] && [ -f docs/operations/deploy.md ]` |
| alpha | game | Plays start to finish; `perf-round` numbers recorded; a multiplayer smoke if networked | human |
| alpha | app | Critical-path e2e in CI; a preview environment that deploys itself | not yet |
| alpha | game | A title screen that starts the game on its own: `standalone` and `titleScreen.modes` in `Resources/Games/<id>.json`, with a pause and settings menu reached from it | `[ "$ROOT" = "$REPO" ] \|\| { g="$(basename "$ROOT" \| tr '[:upper:]' '[:lower:]')"; jq -e '.standalone == true and (.titleScreen.modes \| length > 0)' "Resources/Games/$g.json" >/dev/null; }` |
| alpha | game | An app icon and splash: `branding.icon` and `branding.splash` in its build profile, both files committed; `scripts/build/render-branding.sh` renders them | `[ "$ROOT" = "$REPO" ] \|\| { g="$(basename "$ROOT" \| tr '[:upper:]' '[:lower:]')"; b="$REPO/scripts/build/games/$g.json"; i="$(jq -r '.branding.icon // empty' "$b")"; s="$(jq -r '[.branding.splash // empty] \| flatten \| .[0] // empty' "$b")"; [ -n "$i" ] && [ -f "$REPO/$i" ] && [ -n "$s" ] && [ -f "$REPO/$s" ]; }` |
| alpha | game | A written taste, the look its art and UI are graded against: a `## Taste` section in its `docs/games/<id>-*.md` doc, by `game-eval` (taste) | `[ "$ROOT" = "$REPO" ] \|\| { g="$(basename "$ROOT" \| tr '[:upper:]' '[:lower:]')"; grep -qx '## Taste' "$REPO"/docs/games/"$g"-*.md; }` |
| alpha | app | A mobile app's icon and splash: `expo.icon` and `expo.splash.image` in `mobile/app.json`, both files committed | `[ ! -f mobile/app.json ] \|\| { i="$(jq -r '.expo.icon // empty' mobile/app.json)"; s="$(jq -r '.expo.splash.image // empty' mobile/app.json)"; [ -n "$i" ] && [ -f "mobile/$i" ] && [ -n "$s" ] && [ -f "mobile/$s" ]; }` |
| alpha | app | A brand sheet, `docs/brand.md` with `## Palette` and `## Logo` sections, by `docs-write` | `grep -qx '## Palette' docs/brand.md && grep -qx '## Logo' docs/brand.md` |
| alpha | game, app | A private target live: a registry target on an `alpha`, `preview` or `internal` channel | `release-state show --json \| jq -e --arg n "$NAME" '.stages[$n].rungs \| index("alpha")'` |
| alpha | game, app | Its store listing set up through the internal channel, by the procedure in `~/.notes/lab/bnb/practices/release/stores.md`; console forms go through the `store-console` skill. In the repo: `store/<id>/<store>/listing.json` for a game, `mobile/metadata.yaml` for an app | `{ [ "$TYPE" = game ] && [ "$ROOT" = "$REPO" ]; } \|\| ls "$REPO/store/$(basename "$ROOT" \| tr '[:upper:]' '[:lower:]')"/*/listing.json >/dev/null 2>&1 \|\| [ -f mobile/metadata.yaml ]` |
| alpha | game, app | A go-to-market entry in the marketing lab project's `docs/channels.yaml`: shape, pitch, channels and posting mode per channel | not yet: needs a `channels.yaml` validator |
| beta | base | A CHANGELOG | `[ -f CHANGELOG.md ]` |
| beta | base | The external-channel pipeline green; one rollback actually done; a load test at the brief's number | human |
| beta | base | A Sentinel health watch | not yet |
| beta | base | A STATUS line under 14 days old | `d="$(notes projects --stats --json \| jq -r --arg n "$NAME" '.[] \| select(.name == $n) \| .status_date')"; [ -n "$d" ] && [[ ! "$(date -d "$d 14 days" +%F)" < "$(date +%F)" ]]` |
| beta | game | Content rating done: `rating.answers` in `store/<id>/game.json`, by `content-rating` | `[ "$ROOT" = "$REPO" ] \|\| { g="$(basename "$ROOT" \| tr '[:upper:]' '[:lower:]')"; jq -e '.rating.answers \| length > 0' "$REPO/store/$g/game.json" >/dev/null; }` |
| beta | game | A finished playtest on this version | human |
| beta | app | A privacy and compliance check when it holds regulated data; the store listing via `mobile-store-metadata` | not yet |
| beta | app | A UI polish pass under 90 days old: a `docs/plans/<date>_<app>_ui_audit.md` report, by `ui-audit` | `f="$(ls "$REPO"/docs/plans/*_"$(basename "$ROOT")"_ui_audit.md 2>/dev/null \| sort \| tail -1)"; [ -n "$f" ] && [[ ! "$(date -d "$(basename "$f" \| cut -c1-10) 90 days" +%F)" < "$(date +%F)" ]]` |
| beta | game, app | Its external tester channel live (TestFlight external, Play closed, Steam `beta`), by the same `stores.md` procedure: a registry target on the `beta` channel | `release-state show --json \| jq -e --arg n "$NAME" '.stages[$n].rungs \| index("beta")'` |
| beta | game, app | A version tag: versioned releases start here | `[ -n "$(project_release_version "$NAME")" ]` |
| beta | game, app | A public page that collects wishlists or signups (a Steam Coming Soon page for a game), live early enough to build an audience before launch and before any Steam festival deadline | not yet: needs a store-page probe |
| beta | game, app | Each version tag gets a marketing drafts batch, and outreach has started (creators and curators for a game; launch sites, directories and partners for an app). An app with regulated data does this inside the compliance check of the beta app row | not yet: needs the marketing drafter |
| prod | base | A prod smoke suite; an incident and rollback runbook; a credentials inventory with an expiry alarm | not yet |
| prod | base | Approval of the public publish | human |
| prod | game, app | Live on a public channel (a store, Steam `default`, the prod cluster): a registry target on the `prod` channel | `release-state show --json \| jq -e --arg n "$NAME" '.stages[$n].rungs \| index("prod")'` |
| prod | game, app | The product's rows in the marketing lab project's `docs/metrics.md` scorecard dated within the last 30 days | not yet: needs the marketing scorecard |

Infra projects (dotfiles, agent-runtime, home-config) skip the store rows: their alpha means deployed by stow or Flux from main, and beta and prod mean others depend on it, so a health watch and a runbook.

## Docs per stage

Each doc comes from an existing skill. There are no doc types beyond these.

| Stage | Doc | Written with |
| --- | --- | --- |
| draft | brief | `one-pager` |
| dev | README, `docs/architecture.md` | `docs-write` |
| alpha | `docs/overview.md`, `docs/operations/deploy.md` | `docs-write` |
| alpha | a game's taste, an app's brand sheet | `game-eval` (taste), `docs-write` |
| beta | CHANGELOG; for an app, the PRD and TSD | `changelog-draft`, `scope` |
| beta | content rating, store listing | `content-rating`, `mobile-store-metadata` |
| prod | incident and rollback runbook, credentials inventory | `docs-write` |

## Versions

A version is one release: what reached the project's users or target in one cut. Its number follows from what is in it, so nobody picks it.

- Minor: the release holds a feature epic closed on proof (`lifecycle.md`, "What an epic is"). Patch: anything else, fixes, stories toward open epics, standing-epic work. Major: only the human; a project starts at 0.x and v1.0.0 is its first public release (the `prod` stage), a project already past 1.0 keeps its line, and a later major is a break the human names (a save or API break, a relaunch).
- Cadence comes from the stage: every 7 days at draft, dev, alpha and beta, every 14 at prod, as `[release] cadence_days` in the notes config. A window with no closed rows cuts nothing.
- A project that ships builds is versioned by its git tag and the sheet follows (`project_release_version`, `.config/shared-hooks/project-name.sh`). A game in the playground has its own tag family, `<game>-vX.Y.Z`, registered as its `tagGlob`. A project with no build (agent-runtime, home-config) uses the sheet's counter and has no tag.
- For a project its tag owns, the sheet's `Version:` line is the next open version, never a record of what shipped, and only the roll (`agentctl-wave-roll`) moves it. Each tag gets its own lab note, `versions/<tag version>.md`, named from the tag (`projects --release --tag`): the first tag at or above the open version freezes that version's rows under its own number, and a tag below it (a hotfix nobody planned) gets a note marked as having no planned rows. Tags from 2026-11-11 on (`RELEASE_NOTES_SINCE`, `project-name.sh`) must each have a note, which `hub releases check` checks (`docs/operations/release-state.md`, Link facts); an older tag without one is history the notes never recorded.
- Tooling: `projects --release` derives the bump from the closed rows at any stage (`--patch`, `--minor`, `--major` override it). `agentctl-wave-roll` rolls a tagged project's sheet when its tag ships, and cuts a sheet-counter project once its cadence has passed with done rows, the `release` facts in `projects --stats --json`. A game with no `<game>-vX.Y.Z` tag yet is cut by neither: the playground still tags builds `v<engine>-<game><N>` until queue item `systems-versions-p5-playground` moves it to the game tag. A project never cut, or a whole cadence past its due date, gets its history from `notes projects --backfill <name> --weekly [--repo <dir>]`: one version per ISO week of closed rows, dated by the notes git history, after a v0.1.0 baseline for older rows and commits. `fleet-bench chain` counts `release_overdue` and `version_tag_drift`.

## What stays with the human

These are never automated; each one is a `human` row, which the gate lists for the human to attest.

- Logins and 2FA on store consoles, payment, legal attestations, Apple and Play review, console dev-kit NDAs.
- A finished playtest before a game enters beta.
- The final public Publish or Submit click. The `store-console` skill fills a console up to it and stops. One exception: setting a beta-verified Steam build live on `default` is the agent's click (the person, 2026-11-06), in `store-console`'s standing permission. `stores.md` says which store steps are API, workflow, skill or person.

## Games: one ladder per game

A game in the playground carries the same ladder as its `status` field (`Draft`, `Dev`, `Alpha`, `Beta`, `Prod`). The rules for moving one game up live with the game code, in the playground's `docs/authoring/adding-a-game.md`; this doc does not repeat them.

A per-game row (a build profile, a play test) is judged on each game's own project, so the playground project, which is the whole repo, passes it. A game project's lab stage must equal its game's `status` on the default branch. `project-map-doctor` compares the two (check 6d) and FAILs on a mismatch, naming both places to fix.

## Changing this doc

A row that will be checked must name its check, and a new row must cite the failure it prevents, as `planning.md` requires. Changing the ladder itself means changing `STAGES`, the playground's `GameStatus` and the registry admin dropdown in the same change; the doctor's 6d check catches a game that is left behind.
