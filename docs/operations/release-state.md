# release-state

`release-state` answers "what is pinned and what is live on each project's deploy channels". It reads the declared targets from the registry, probes each one, and writes a snapshot that the hub's Releases tab reads. Plan: `~/.claude/plans/we-need-reaseleases-twinkling-frog.md`.

## Commands

| Command | What it does |
|---|---|
| `release-state refresh [project...]` | Probe every target (or only these projects, merged into the snapshot) and write `~/.agent/releases/state.json` |
| `release-state show [--json] [project]` | The snapshot, drift and unknown first |
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
| `id` | Unique across the registry, lowercase and `-`. Later phases use it as the GitHub Deployments environment name |
| `channel` | `prod`, `beta`, `alpha`, `preview` or `internal` |
| `where` | Free text for the UI: the cluster or store |
| `pinned` | `{"tag": true}` (the project's newest release tag), or `repo` (a registry key) + `path` + one of `key` (first `<key>:` line, default `tag`) or `image` (a kustomize `images:` `newTag` for that name, else `image: <name>:<tag>`). `branch` defaults to the repo's registry `branch`, then `origin/HEAD` |
| `live` | `{"k8s": {context, namespace, deployment, container?}}` (the running image tag), or `{"health": {url, field?}}` (a served commit SHA, default field `commit`), or absent |
| `telemetry` | Sentinel watch names that must exist and be OK |
| `deps` | Registry projects this one depends on |

A shipping app (`type: app`) with no targets gets one implicit `release` row: its newest release tag. Games get their rows from store channels in a later phase. `project-map-doctor` check 4c validates every target.

## Statuses

| Status | Meaning |
|---|---|
| `drift` | Pinned and live differ. `drift_since` carries across refreshes, so `check` waits out a rollout in progress |
| `unknown` | A probe failed (fetch, kubectl, health); the row says which in `pinned.error` or `live.error` |
| `floating` | Pinned or live is `latest`, so no version can be named |
| `ok` | Live equals pinned, or the served SHA is the pinned tag's commit |
| `released` | A tag-only row: the newest tag, with no live source |
| `unreleased` | An app with no release tag yet |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| A row is `unknown` with `fetch failed` | The checkout's `origin` is unreachable (VPN, ssh agent). Fix the remote; the snapshot never reuses an older ref |
| A row is `unknown` with `kubectl get failed` | The context is missing from `kubectl config get-contexts`, or the deployment name is wrong |
| A row is `unknown` with `no checkout for repo` | The repo key has no `paths` entry in the registry on this machine |
| A game shows no row | Expected until store channels land. Playground tags (`v0.5.0-barrage5`) number playground builds; a game's own version lives on its sheet, so a playground tag glob on a game makes the doctor report its sheet as behind |
