# release-state

`release-state` answers "what is pinned and what is live on each project's deploy channels, and what was deployed there before". It reads the declared targets from the registry, probes each one, and writes a snapshot that the hub's Releases tab reads. Plan: `~/.claude/plans/we-need-reaseleases-twinkling-frog.md`.

## Commands

| Command | What it does |
|---|---|
| `release-state refresh [project...]` | Probe every target (or only these projects, merged into the snapshot) and write `~/.agent/releases/state.json` |
| `release-state show [--json] [project]` | The snapshot, drift and unknown first |
| `release-state changelog [--json\|--list] <project> [tag]` | One tag's changelog (the newest release when no tag): that version's `CHANGELOG.md` section, else the merged PRs between it and the previous tag of the line. `--list` prints the project's tags, newest first |
| `release-state released <project> <sha>...` | One JSON line per commit: `{sha, tag, at}`, the oldest tag of the project's line that holds it and that tag's creatordate epoch (a lightweight tag records none, so it is the tagged commit's date, a lower bound), `null` when no tag does yet, and an `error` when the checkout lacks the commit. `fleet-bench`'s `request_to_live_h` reads it |
| `release-state check [--grace 30] [--max-age 60]` | Exit 1 naming each drift older than grace minutes, each floating prod target, and a snapshot older than max-age minutes. The `release-drift` Sentinel watch runs it; the links between stores are `hub releases check` (Relationships) |

The agentctl runner `release-state` refreshes every 15 minutes. Clusters and stores offer no event we can subscribe to, so this is a poll. A release skill runs `release-state refresh <project>` at the end of a cut.

## Declaring a target

Targets live in `project-map.json` under `trackers.<project>.targets`, one object per line. The registry holds locators only: the pinned value stays in the manifest that owns it.

```json
{"id": "shop-web-prod", "channel": "prod", "where": "prod-cluster",
 "pinned": {"repo": "infra", "branch": "main", "path": "apps/prod/shop/helmrelease-web.yaml", "key": "tag"},
 "live": {"k8s": {"context": "prod-cluster", "namespace": "shop", "deployment": "shop-web"}},
 "telemetry": ["shop-api-health"], "deps": []}
```

| Field | Meaning |
|---|---|
| `id` | Unique across the registry, lowercase and `-`. Also the GitHub Deployments environment its deploy workflow records under |
| `channel` | A key of the registry's top-level `channels` map (`alpha`, `preview`, `internal`, `beta`, `prod`), which names the stage rung each serves (`alpha` and above; `~/.local/src/docs/stages.md`, The ladder). `project-map-doctor` 4c checks both |
| `where` | Free text for the UI: the cluster or store |
| `pinned` | `{"tag": true}` (the project's newest release tag), `{"deployed": true}` (a store channel: the newest successful GitHub Deployment under the target id, because no file pins a store, with that Deployment's `build` when it recorded one), `{"deployed": "manual", "reason": "..."}` (a channel moved by hand, such as Steam `default` set live in Steamworks: nothing records its deploys, so the pin reads `manual`, the row is `released` with live alone, and the doctor wants the reason), or `repo` (a registry key) + `path` + one of `key` (first `<key>:` line, default `tag`) or `image` (a kustomize `images:` `newTag` for that name, else `image: <name>:<tag>`). `branch` defaults to the repo's registry `branch`, then `origin/HEAD`. A `repo` pin also carries `at` (when the value took effect: the newest commit on that branch whose diff of the file adds or removes the value, the gitops PR's merge) and `prev` (the value the file held before that commit) |
| `live` | `{"k8s": {context, namespace, deployment, container?}}` (the running image tag), `{"health": {url, field?}}` (a served commit SHA, default field `commit`), `{"steam": {app, branch}}` (the default branch is `public` here), `{"play": {package, track}}`, `{"testflight": {app}}` (the numeric Apple ID), or absent |
| `telemetry` | Sentinel watch names that watch the target; `hub releases check` fails one with no `~/.agent/watches/<name>.yaml` |
| `deps` | Registry projects this one depends on |

A shipping app (`type: app`) with no targets gets one implicit `release` row: its newest release tag. Games get their rows from their store targets. `project-map-doctor` check 4c validates every target.

`deployWorkflows` (on the tracker of the app repo, `trackers.<repo>.deployWorkflows`) maps each deploy workflow file to what it deploys: a full path (`.github/workflows/deploy-production.yml`, `.forgejo/workflows/<f>.yml`) to a list of target ids, or to a string giving the reason it deploys none (`"seeds the preview DB"`). `refresh` flags a file as a deploy by a word in its name (`DEPLOY_NAMES` in `release-state`: deploy, release, publish, promote, submit, steam, upload, rollout) or a deploy step in it (`DEPLOY_MARKERS`); `hub releases check` fails a flagged file the map does not name, a mapped path that is not a workflow on the default branch, and an id that is no target. A flagged file whose name holds a project of that repo below alpha reads `ahead of its stage` instead.

## Deploy history

The workflow that deploys a target records one GitHub Deployment: `environment` is the target id, `description` the version, and its status carries the run as `log_url`. `release-state` reads the newest 10 per target from the project's repo (`trackers.<p>.repo`, its checkout's `origin` on github.com), into the row's `deploys`:

| Field | Meaning |
|---|---|
| `history` | The newest deployments, each `{version, state, at, url, sha, build}`; `state` is `ok`, `fail` or GitHub's word for one not finished, `sha` the Deployment's commit (the recorder's `ref`, the tag it shipped), `build` the store build number its payload carried (`{"build": "..."}`), else null |
| `last` | The newest that finished, success or not: the LAST DEPLOY column. A failure makes the row amber |
| `prev` | The version that succeeded before the newest success: the PREV column |
| `error` | Why the read failed; PREV and LAST DEPLOY then say `?` |

A target nothing records under, or a project whose repo is not on GitHub, has an empty history and `-` in both columns. The target ids are stable before their row exists: a store target's workflow records under `<game>-steam-<branch>`, `<game>-play-<track>`, `<game>-testflight`, `pmp-android-<track>` (`prod` for production), `pmp-ios-testflight` or `pmp-ios-prod`, so a registry row added later reads its whole history. The platform records `pmp-api-prod` and `pmp-web-prod`: a success from `verify-flux-rollout.yml` once the pods are Ready, a failure from `deploy-production.yml`. Recording is one `record-deployment` action, in unity-core-playground, which the platform pins by commit; it never gates a deploy, and it uses `auto_inactive: false` because GitHub's default rewrites each earlier success to `inactive`, which would erase PREV.

## Release history

`refresh` also writes a top-level `releases` map, one entry per project with a target row, read straight from git and joined to nothing:

| Field | Meaning |
|---|---|
| `line` | `release` (the project's own release family: its `tagGlob`, else the monorepo `name-v*` ladder or `v*`), `build` (the registry's `buildTags` globs, read only while the project has no release tag), or `none` |
| `glob` | The glob or globs the tags were listed with |
| `repo` | The checkout's origin as the PR store names it: `owner/repo`, a non-GitHub host as `host/owner/repo`; null with no checkout or origin |
| `tags` | The newest `HISTORY_TAGS` (20) tags, each `{tag, version, sha, at, prev, prs}`: `sha` is the commit the tag points at, `at` git's creatordate (the tagger date, or a lightweight tag's commit date), `prev` the tag before it by ancestry, the changelog's range start, `prs` the `(#N)` merge subjects in `prev..tag` (the changelog's own read, at most `HISTORY_PRS`, 500) |
| `error` | Why the read failed: `no checkout`. History reads the local tags and never fetches, so a tag the checkout has not fetched is simply absent |

`buildTags` (`trackers.<p>.buildTags`, a list of globs such as `["v*-shapecity*", "v*-barrage*"]`) names the per-build tags of a project with no release family, a game built from the playground. They feed only this history and the changelog: `project_version_owner` and the version roll never read them, so a build tag never becomes the game's version (see "A game shows no row"). `project-map-doctor` check 4c names a `buildTags` that is not a list of single globs.

## Stage facts

`refresh` also writes a top-level `stages` map: for each registry project visible on this machine, what its lab stage (`notes projects --stats --json`) asks of its deploys. It is computed from the merged rows, so a refresh of one project still judges every project on all its channels:

| Field | Meaning |
|---|---|
| `stage` | The lab stage, `null` when the sheet names none on the ladder (then `needs` and `ahead` are empty) |
| `rungs` | The rungs its live (read, non-implicit) targets serve, low to high, through the `channels` map; a channel the map does not name serves none |
| `needs` | The rungs from `alpha` up to the stage that no live target serves; empty for `infra`, which deploys by stow or Flux |
| `ahead` | The target ids live on a rung above the stage: at `draft` and `dev`, every live target |

When `notes` cannot answer, `stages` is `{}` and `stages_error` says why; the Releases tab shows that as an error, never as every app having no stage. The stage gate's deploy rows in `stages.md` read `rungs` against the stage being checked, so a project setting its first stage is judged too, and the Releases tab shows each app's stage with `needs` and `ahead` (`draft: CI only, no deploy expected`, `draft: live above it: bnb-studios-prod`).

## Relationships

The collector writes raw facts only, and every link between two of them is computed in one place, `hub_core::release_graph`, which both surfaces read. A link is never stored, so it cannot drift from the facts it joins.

| Fact | Its one store | Read by `refresh` from |
|---|---|---|
| Release: tag, sha, date, the tag before it | the git tag | `git_tags`, `git_prev_tag` in `git-release.sh` |
| Deploy on a channel | a GitHub Deployment under the target id | the project's repo (Deploy history) |
| CI run: workflow, run name, status, start and end | the run ledger `~/.local/state/ci/runs.jsonl` | `schedules-sync` (the graph reads it, never `refresh`) |
| The tag a run's log named, for runs whose name carries none | `~/.local/state/ci/run-tags.jsonl` (`SCHEDULES_RUN_TAGS`) | `schedules-sync run-tags <repo> <workflow path>...` (a backfill; the ledger is never rewritten) |
| Gitops pin, when it moved, what it held before | the manifest in the gitops repo | `git log -S` on the pinned file |
| PRs a release carried | the merge subjects in `prev..tag` | `changelog` |

PRs have one store of their own, read by the graph (never by `refresh`): `~/.agent/prs/<owner>__<repo>.jsonl` (a Forgejo repo `<host>__<owner>__<repo>`), one row per PR with its canonical repo (`owner/repo`, Forgejo `host/owner/repo`), number, head branch, base, state, `merged_at` (UTC), merge sha, title and author. `schedules-sync` writes it on every pass for each repo in `~/.config/agentctl/day-log-ci`, where a `prs-only:` line names a work or client repo read for its PRs alone (GitHub's first page ETag-conditional, Forgejo paged by update), and `agent-land` refreshes the landed repo with `schedules-sync sync-prs` after a merge. Every PR list is read with `schedules-sync prs <repo|all>` (exit 1 when the store is older than 30 minutes, 3 for a repo it does not list), never a script's own `gh pr list`; a single PR checked at land time (`agent-land`, `agent-queue` `pr_state`, `fleet-dispatch reap`) stays a live read. A run's PRs are not stored on the run: that link is a join against this store. A missing store is an error line on the runs tables (Infra, CI, Runs and Releases, Release runs), never a blank.

| Link | Join | Computed in |
|---|---|---|
| release -> previous release | tag ancestry | `git-release.sh` (`git_prev_tag`) |
| release -> PRs | `(#N)` subjects in `prev..tag` | `git-release.sh` (the changelog), written as each tag's `prs` |
| release -> channels it reached | a successful Deployment or the current pin whose version is the tag, or its version with or without `v`; then a Deployment whose version names no tag of the line, by its commit; the earliest successful deploy per channel; else a channel whose live reading names the tag, shown as `(live)` with no time | `hub_core::release_graph::reached` |
| run -> PRs | the PR whose merge sha is the run's commit; else, off a shared branch (`main`, `master`, `develop`), the PRs on the run's head branch in its repo not closed before the run started | `Graph::run_prs` |
| run -> release | the Deployment whose URL names the run (`.../actions/runs/<id>`); else a run on a tag of the line; else the tag its run name carries (`Release builds of <tag>`, `Phone release of <tag>`) or its log named; else, for a Steam upload (`Steam (<game> of <run id>)`), the release of the run it uploads | `Graph::release` |
| run -> owner | the live session on the run's branch; else the session of the queue item that names one of the run's PRs | `Graph::owner` |
| PR -> queue item -> row | an item's `pr:` refs (`owner/repo#N`, a bare `N` read in the item's project's one repo), the item that merged it first; its `row:` | `Graph::new` |
| release -> rows | each of its PRs' items' rows | `Graph::history` |
| dependency -> pinned version | the dependency's prod channel pin, else another channel's | `release_graph::deps_text` |

`hub releases --json` prints the Releases read with every join, the graph's one output for shell tools (fleet-bench's lead time reads each tag's first deploy from it). `hub releases check` prints one line per place the stores disagree inside the ledger's 30 days: a PR an item or a tag names that the PR store lacks (in a repo the store holds), a bare `pr:N` on a project with no single repo, a Deployment naming a run of a ledger repo that the ledger lacks, a tag in two projects' lines, a `deployed: true` target with no Deployment recorded, a `deployed: "manual"` with no reason, a telemetry watch that does not exist, and a PR store repo that failed or has not synced in 30 minutes. From the enforcement date on it also checks the links below. It exits 1 when it prints a line or a store could not be read; the `release-links` Sentinel watch runs it, and its trip routes to an agent (`fix-red`). `agent-land` closes a row with proof `pr:<owner>/<repo>#N`, so the join needs no project lookup.

An opened app on the Releases tab lists its releases newest first with when each was released, the one before it, where each reached (`not recorded` when no channel says so), its PRs (`none merged`) and their board rows (`not recorded`, or `before 2026-11-11`); a release opens its changelog. Below them are its build runs, newest first: the builds read's runs the graph tied to one of its tags (the same rows Release runs lists, `Releases::with_builds`), each with tag, workflow, state (queued or in progress with the time so far, success, failed, cancelled), started and finished, and a link to the run. The RELEASED column is the newest tag and its date, plus `building <tag>` while a run is in progress. Every history cell carries its date, today's too.

### Link facts

`refresh` writes `links` into the snapshot, the raw facts the link checks read: per app repo the GitHub environments that hold a recorded Deployment and each workflow file on the default branch with its deploy flag, per lab project its versions (the roll stamp of each `versions/<v>.md` and the PRs of its frozen rows; a project whose profile has `automation = false` has no roll and carries none), the stage ladder, and `since`, the enforcement date (`RELEASE_NOTES_SINCE`, 2026-11-11). A part that could not be read carries `error`, which the check prints as a store it could not read.

| Check | Fails on |
|---|---|
| environments | an environment holding recorded Deployments that no target is named |
| deploy workflows | an unmapped deploy file, a mapped path that is not a file, an unknown target id (`deployWorkflows` above) |
| deploy runs | a successful run since the date, of a workflow mapped to a `deployed: true` target, that resolves to no release |
| tag globs | a `tagGlob` that matches no tag while the lab has shipped versions |
| tags | a release tag since the date with no lab version of its number, and a PR in it (not a bot's) with no board row |
| versions | a version rolled since the date with no tag of the line, and a row whose PR shipped in another tag or in none |

A gap older than the date is history nobody recorded: it is never a red, and the Releases tab says `before 2026-11-11` where its rows would be.

### Blank cells

A cell with nothing to show names why, in one of these words (`hub_core::releases::BLANKS`), so a blank never reads as a broken read:

| Word | Means |
|---|---|
| `none declared` | The registry declares nothing to read: no live probe, no telemetry, no channel past the implicit release row |
| `not recorded` | It should be there and nothing wrote it: a `deployed: true` target with no Deployment, a release whose channels and items name nothing |
| `manual` | A channel moved by hand (`deployed: "manual"`) |
| `not read` | The read failed; the row's `error` says why |
| `none merged` | A tag with no merged PRs since the one before it |

History cells also say `first tag` for a release with none before it, and `before 2026-11-11` (above). Each app, and the Apps head, carries counted coverage per column (`prev 2/2, deployed 0/1 (1 none declared), reached 1/2`): how many of its channels or releases hold a value, with the causes of the rest counted.


## Project identity

Every fact above is filed under a project key, and each source spells the project its own way: a checkout basename (`.dotfiles`), a forge slug (`Kblack0610/.dotfiles`), a name the project had before a rename. One name index in the registry maps every spelling to its key, and every reader joins through it, so no reader keeps its own alias table.

| Registry field | What it adds to the index |
|---|---|
| `trackers.<key>` and each `paths` value | the key itself |
| `trackers.<key>.names` | other spellings: retired names, the repo's name where it differs from the key |
| `trackers.<key>.github`, `.forgejo` | the `owner/repo` slug, and each `/`-suffix of it (`.dotfiles`, `dotfiles`) |
| each `paths` key (a checkout) | its basename |

The index is lowercased and built in that order, trackers sorted by key and paths by path, and the first entry for a spelling wins; `default` and the `_comment` strings are not projects. A lookup tries the spelling's `/`-suffixes, longest first, each also without a leading dot. A spelling the index does not hold keeps its last path segment, leading dot stripped, case kept.

The shell lookup is `project_canonical` (and `project_lookup`, `project_of_repos_json`, `project_index_json`) in `.config/shared-hooks/project-name.sh`; the Rust one is the `project-map` crate (`project_map::canonical`, `Registry`), which notes-cli, hub-core and through it hub-tui and agent-web use. `tests/fixtures/project-names.tsv` is read by `tests/unit/project_names.bats` and by the crate's cargo test, so the two cannot drift.

`project-map-doctor` check 4 fails on a `names` that is not a list of names, a slug that is not `owner/repo`, and a spelling two keys claim (the loser would silently lose its rows). Check 4d reads the spellings the runtime has already written (the queue's `project:`, CI's `runs.jsonl` `repo`, each outcome's PR `repo`) and names each one the index does not resolve, with where it was seen: add it to its project's `names`, or its forge slug to the tracker.

## Store channels

| Store | Live value | Compared with the pin |
|---|---|---|
| Steam | The tag in the description of the build the branch is on (`<build> <tag> <sha>`, written by the upload), with the BuildID in `live.build`. A build with no tag shows its BuildID | Exactly |
| Play | The name of the published release with the highest version code, from the edit-free `tracks.releases.list`, with the code in `live.build`. Never `edits.insert`: an open edit can invalidate an upload running at the same time | The build when the upload recorded one, else exactly; a release named only `x.y.z` compares as TestFlight does |
| TestFlight | `<marketing version> (<build>)` of the newest processed iOS build | The build number when the upload recorded one; else the pin's first `x.y.z` against the marketing version, so two tags that share a version compare equal |

### Store credentials

Each store has its own read-only credential in rbw, read once per refresh and only when a target needs it. Never point these at the release keys the upload workflows use. A locked vault is not unlocked: every store row says `rbw is locked`.

| rbw entry (password field, one line) | Contents | Scope |
|---|---|---|
| `release_state_steam` | The publisher Web API key | Key of a Steamworks group with no edit or publish rights |
| `release_state_play` | The service-account JSON, minified | Play Console "View app information", no release rights |
| `release_state_asc` | `{"key_id", "issuer_id", "p8"}`, with `p8` the `.p8` file in base64 | App Store Connect Developer role |

## Statuses

| Status | Meaning |
|---|---|
| `drift` | Pinned and live differ. `drift_since` carries across refreshes, so `check` waits out a rollout in progress |
| `unknown` | A probe failed (fetch, kubectl, health); the row says which in `pinned.error` or `live.error`. The Releases tab draws it `not read` and counts it in the app's CHANNELS and the gap line, but it never sets the app's word |
| `floating` | Pinned or live is `latest`, so no version can be named |
| `ok` | Live equals pinned, the served SHA is the pinned tag's commit, or the store's build is the build the upload recorded |
| `released` | Nothing to compare: a tag-only row (the newest tag, no live source), a store channel with no recorded upload (the store's value, pin `-`), or a channel moved by hand (pin `manual`) |
| `unreleased` | An app with no release tag yet |

The platform repo has a second drift reader by design: `release-drift.yml` and `mobile-release-drift.yml` post drift to the team's ntfy `ship` feed, which teammates outside the fleet read, and the mobile one also opens GitHub issues. They stay as the team's view; `release-state` and the `release-drift` Sentinel watch are the fleet's.

## Changelog for a version

`changelog` takes any tag of the project's own line (its `tagGlob`, the monorepo `name-v*` ladder or `v*`, or, for a project with no release tag, its `buildTags`; a name that is not one of its tags is refused). The previous tag is the highest tag of the line that is an ancestor of the tag, skipping prereleases when the tag is a stable release. The source is the first `CHANGELOG.md` found at the tag, then at `origin/<branch>`, under the registry `path`, and the repo root too when the project is its repo or has no `path` (a monorepo product never reads a root file that may be another product's), holding a heading with the version (`## [1.1.0] - date`; `1.1.0` does not match `1.1.01`). With none, the text is the merged PRs in `prev..tag` that touch the registry `path`, the newest 100, with a last line saying older ones are not shown; a product in a monorepo then lists the range's other merged PRs, counted, under `<N> merged PRs elsewhere in the repo, touching nothing under <path>`, so a release built from repo-wide changes never reads as empty. The Releases tab shows it in an opened app: agent-web has a tag picker, the TUI has `[` (older) and `]` (newer).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| A row is `unknown` with `fetch failed` | The checkout's `origin` is unreachable (VPN, ssh agent). Fix the remote; the snapshot never reuses an older ref |
| A row is `unknown` with `kubectl get failed` | The context is missing from `kubectl config get-contexts`, or the deployment name is wrong |
| PREV and LAST DEPLOY say `?` | `gh` is not logged in where the runner runs, or the API was down; the row's `deploys.error` says which call failed |
| PREV and LAST DEPLOY say `not recorded` on a target that deployed | Its workflow has not recorded under the target id yet: check `gh api "repos/<owner>/<repo>/deployments?environment=<id>"` and that the id matches the registry exactly |
| A store row is `unknown` with `rbw is locked` | The vault locked; run `rbw unlock`. The collector never unlocks it or raises pinentry |
| A store row is `unknown` with `no rbw entry <name>` | The read-only credential is not made yet: see Store credentials |
| A Steam row is `unknown` with `build <id> is not in the last 50 builds` | The branch has not moved in longer than `STEAM_BUILDS` covers. Raise that constant in `release-state` |
| A Steam row is `unknown` with `no branch <name> on the app` | The branch does not exist on that app yet, or the registry says `default` where Steam says `public` |
| A row is `unknown` with `no checkout for repo` | The repo key has no `paths` entry in the registry on this machine |
| A TestFlight or Play row is `drift` while the versions match | The store's newest build is not the build the upload recorded: a second build of that version was uploaded by hand or by another workflow. `release-state show --json \| jq '.rows[] \| select(.id == "<id>") \| [.pinned.build, .live.build]'` shows both |
| An app's build runs miss an older Release builds or Steam run | Its run name carries no tag (runs before the playground's `run-name:`). Run `schedules-sync run-tags <owner>/<game repo> .github/workflows/release.yml .github/workflows/steam.yml .github/workflows/phone-release.yml .github/workflows/ios-release.yml`: it reads each such run's log once and appends the tag to `run-tags.jsonl` |
| The doctor says `tag <t> in <repo> is listed by <a> and <b>` | Two projects' release lines (`tagGlob`, or the bare `v*` fallback of a key with no `tagGlob`) or `buildTags` match one real tag, so both histories and version rolls would claim it. Narrow one glob; a repo-only key (no `lab`, no `targets`) is not counted |
| A game shows no row | It has no store target in the registry. Playground tags (`v0.5.0-barrage5`) number playground builds; a game's own version lives on its sheet, so a playground tag glob on a game makes the doctor report its sheet as behind. Its build tags belong in `buildTags`, which feed its history and changelog only |
| An app's release history says `no tags read` | The project has no release tag and no `buildTags`, or the checkout has not fetched its tags. `release-state show --json \| jq '.releases["<p>"]'` gives the glob and any error |
| `changelog` says `<tag> is not a release tag of <project>` | The tag is not on the project's line (a candidate of another product, or not fetched). `release-state changelog --list <project>` shows the ones it offers; fetch the checkout if a new tag is missing |
| A version shows the merged PRs list | The tag has no `CHANGELOG.md` section for it. Add one under a heading holding the version and it is used from the next tag on (the file is read at the tag, then at the branch tip) |
| A release's ROWS says `not recorded` while PRS lists PRs | No queue item names those PRs: the work predates the queue, or its item recorded a bare `pr:N` in a project with several repos. `hub releases check` names the second |
| A run's OWNER is `-` | No session sits on its branch and no item names its PR, or the PR store does not hold the PR yet (`schedules-sync` polls every 10 minutes; `hub releases check` names an item PR the store lacks) |
| An app's stage says `live above it: <target>` | A target is live on a rung its lab stage has not reached (a draft site live in prod). Either raise the stage through its gate (`notes projects --stage <p> --set <s>`, which runs `project-stage-check`) or remove the target and its deploy pipeline. Stage moves are the human's |
| An app's stage says `no alpha target live` | Its stage needs a rung nothing serves: no target on that channel, or the target's probe failed (`unknown` serves no rung). Declare the target, or fix the probe |
