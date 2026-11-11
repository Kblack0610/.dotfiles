# release-state

`release-state` answers "what is pinned and what is live on each project's deploy channels, and what was deployed there before". It reads the declared targets from the registry, probes each one, and writes a snapshot that the hub's Releases tab reads. Plan: `~/.claude/plans/we-need-reaseleases-twinkling-frog.md`.

## Commands

| Command | What it does |
|---|---|
| `release-state refresh [project...]` | Probe every target (or only these projects, merged into the snapshot) and write `~/.agent/releases/state.json` |
| `release-state show [--json] [project]` | The snapshot, drift and unknown first |
| `release-state changelog [--json\|--list] <project> [tag]` | One tag's changelog (the newest release when no tag): that version's `CHANGELOG.md` section, else the merged PRs between it and the previous tag of the line. `--list` prints the project's tags, newest first |
| `release-state released <project> <sha>...` | One JSON line per commit: `{sha, tag, at}`, the oldest tag of the project's line that holds it and that tag's creatordate epoch (a lightweight tag records none, so it is the tagged commit's date, a lower bound), `null` when no tag does yet, and an `error` when the checkout lacks the commit. `fleet-bench`'s `request_to_live_h` reads it |
| `release-state check [--grace 30] [--max-age 60]` | Exit 1 naming each drift older than grace minutes, each floating prod target, each missing or tripped telemetry watch, and a snapshot older than max-age minutes |

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
| `channel` | `prod`, `beta`, `alpha`, `preview` or `internal` |
| `where` | Free text for the UI: the cluster or store |
| `pinned` | `{"tag": true}` (the project's newest release tag), `{"deployed": true}` (a store channel: the newest successful GitHub Deployment under the target id, because no file pins a store), or `repo` (a registry key) + `path` + one of `key` (first `<key>:` line, default `tag`) or `image` (a kustomize `images:` `newTag` for that name, else `image: <name>:<tag>`). `branch` defaults to the repo's registry `branch`, then `origin/HEAD`. A `repo` pin also carries `at` (when the value took effect: the newest commit on that branch whose diff of the file adds or removes the value, the gitops PR's merge) and `prev` (the value the file held before that commit) |
| `live` | `{"k8s": {context, namespace, deployment, container?}}` (the running image tag), `{"health": {url, field?}}` (a served commit SHA, default field `commit`), `{"steam": {app, branch}}` (the default branch is `public` here), `{"play": {package, track}}`, `{"testflight": {app}}` (the numeric Apple ID), or absent |
| `telemetry` | Sentinel watch names that must exist and be OK |
| `deps` | Registry projects this one depends on |

A shipping app (`type: app`) with no targets gets one implicit `release` row: its newest release tag. Games get their rows from their store targets. `project-map-doctor` check 4c validates every target.

## Deploy history

The workflow that deploys a target records one GitHub Deployment: `environment` is the target id, `description` the version, and its status carries the run as `log_url`. `release-state` reads the newest 10 per target from the project's repo (`trackers.<p>.repo`, its checkout's `origin` on github.com), into the row's `deploys`:

| Field | Meaning |
|---|---|
| `history` | The newest deployments, each `{version, state, at, url}`; `state` is `ok`, `fail` or GitHub's word for one not finished |
| `last` | The newest that finished, success or not: the LAST DEPLOY column. A failure makes the row amber |
| `prev` | The version that succeeded before the newest success: the PREV column |
| `error` | Why the read failed; PREV and LAST DEPLOY then say `?` |

A target nothing records under, or a project whose repo is not on GitHub, has an empty history and `-` in both columns. The target ids are stable before their row exists: a store target's workflow records under `<game>-steam-<branch>`, `<game>-play-<track>`, `<game>-testflight`, `pmp-android-<track>` (`prod` for production), `pmp-ios-testflight` or `pmp-ios-prod`, so a registry row added later reads its whole history. Recording is the `record-deployment` action in each repo; it uses `auto_inactive: false` because GitHub's default rewrites each earlier success to `inactive`, which would erase PREV.

## Release history

`refresh` also writes a top-level `releases` map, one entry per project with a target row, read straight from git and joined to nothing:

| Field | Meaning |
|---|---|
| `line` | `release` (the project's own release family: its `tagGlob`, else the monorepo `name-v*` ladder or `v*`), `build` (the registry's `buildTags` globs, read only while the project has no release tag), or `none` |
| `glob` | The glob or globs the tags were listed with |
| `tags` | The newest `HISTORY_TAGS` (20) tags, each `{tag, version, sha, at, prev}`: `sha` is the commit the tag points at, `at` git's creatordate (the tagger date, or a lightweight tag's commit date), `prev` the tag before it by ancestry, the changelog's range start |
| `error` | Why the read failed: `no checkout`. History reads the local tags and never fetches, so a tag the checkout has not fetched is simply absent |

`buildTags` (`trackers.<p>.buildTags`, a list of globs such as `["v*-shapecity*", "v*-barrage*"]`) names the per-build tags of a project with no release family, a game built from the playground. They feed only this history and the changelog: `project_version_owner` and the version roll never read them, so a build tag never becomes the game's version (see "A game shows no row"). `project-map-doctor` check 4c names a `buildTags` that is not a list of single globs.

## Relationships

The collector writes raw facts only, and every link between two of them is computed in one place, `hub_core::release_graph`, which both surfaces read. A link is never stored, so it cannot drift from the facts it joins.

| Fact | Its one store | Read by `refresh` from |
|---|---|---|
| Release: tag, sha, date, the tag before it | the git tag | `git_tags`, `git_prev_tag` in `git-release.sh` |
| Deploy on a channel | a GitHub Deployment under the target id | the project's repo (Deploy history) |
| Gitops pin, when it moved, what it held before | the manifest in the gitops repo | `git log -S` on the pinned file |
| PRs a release carried | the merge subjects in `prev..tag` | `changelog` |

| Link | Join | Computed in |
|---|---|---|
| release -> previous release | tag ancestry | `git-release.sh` (`git_prev_tag`) |
| release -> PRs | `(#N)` subjects in `prev..tag` | `git-release.sh` (the changelog) |
| release -> channels it reached | a successful Deployment or the current pin whose version is the tag, or its version with or without `v`; the earliest successful deploy per channel | `hub_core::release_graph::reached` |

An opened app on the Releases tab lists its releases newest first with when each was released, the one before it, and where each reached (`not recorded` when no channel says so); a release opens its changelog. The RELEASED column is the newest tag and its date.

## Store channels

| Store | Live value | Compared with the pin |
|---|---|---|
| Steam | The tag in the description of the build the branch is on (`<build> <tag> <sha>`, written by the upload), with the BuildID in `live.build`. A build with no tag shows its BuildID | Exactly |
| Play | The name of the published release with the highest version code, from the edit-free `tracks.releases.list`, with the code in `live.build`. Never `edits.insert`: an open edit can invalidate an upload running at the same time | Exactly; a release named only `x.y.z` compares as TestFlight does |
| TestFlight | `<marketing version> (<build>)` of the newest processed iOS build | The pin's first `x.y.z` against the marketing version, so two tags that share a version compare equal |

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
| `ok` | Live equals pinned, or the served SHA is the pinned tag's commit |
| `released` | Nothing to compare: a tag-only row (the newest tag, no live source), or a store channel with no recorded upload (the store's value, pin `-`) |
| `unreleased` | An app with no release tag yet |

## Changelog for a version

`changelog` takes any tag of the project's own line (its `tagGlob`, the monorepo `name-v*` ladder or `v*`, or, for a project with no release tag, its `buildTags`; a name that is not one of its tags is refused). The previous tag is the highest tag of the line that is an ancestor of the tag, skipping prereleases when the tag is a stable release. The source is the first `CHANGELOG.md` found at the tag, then at `origin/<branch>`, under the registry `path`, and the repo root too when the project is its repo or has no `path` (a monorepo product never reads a root file that may be another product's), holding a heading with the version (`## [1.1.0] - date`; `1.1.0` does not match `1.1.01`). With none, the text is the merged PRs in `prev..tag`, filtered to the registry `path`, the newest 100, with a last line saying older ones are not shown. The Releases tab shows it in an opened app: agent-web has a tag picker, the TUI has `[` (older) and `]` (newer).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| A row is `unknown` with `fetch failed` | The checkout's `origin` is unreachable (VPN, ssh agent). Fix the remote; the snapshot never reuses an older ref |
| A row is `unknown` with `kubectl get failed` | The context is missing from `kubectl config get-contexts`, or the deployment name is wrong |
| PREV and LAST DEPLOY say `?` | `gh` is not logged in where the runner runs, or the API was down; the row's `deploys.error` says which call failed |
| PREV and LAST DEPLOY say `-` on a target that deployed | Its workflow has not recorded under the target id yet: check `gh api "repos/<owner>/<repo>/deployments?environment=<id>"` and that the id matches the registry exactly |
| A store row is `unknown` with `rbw is locked` | The vault locked; run `rbw unlock`. The collector never unlocks it or raises pinentry |
| A store row is `unknown` with `no rbw entry <name>` | The read-only credential is not made yet: see Store credentials |
| A Steam row is `unknown` with `build <id> is not in the last 50 builds` | The branch has not moved in longer than `STEAM_BUILDS` covers. Raise that constant in `release-state` |
| A Steam row is `unknown` with `no branch <name> on the app` | The branch does not exist on that app yet, or the registry says `default` where Steam says `public` |
| A row is `unknown` with `no checkout for repo` | The repo key has no `paths` entry in the registry on this machine |
| A game shows no row | It has no store target in the registry. Playground tags (`v0.5.0-barrage5`) number playground builds; a game's own version lives on its sheet, so a playground tag glob on a game makes the doctor report its sheet as behind. Its build tags belong in `buildTags`, which feed its history and changelog only |
| An app's release history says `no tags read` | The project has no release tag and no `buildTags`, or the checkout has not fetched its tags. `release-state show --json \| jq '.releases["<p>"]'` gives the glob and any error |
| `changelog` says `<tag> is not a release tag of <project>` | The tag is not on the project's line (a candidate of another product, or not fetched). `release-state changelog --list <project>` shows the ones it offers; fetch the checkout if a new tag is missing |
| A version shows the merged PRs list | The tag has no `CHANGELOG.md` section for it. Add one under a heading holding the version and it is used from the next tag on (the file is read at the tag, then at the branch tip) |
