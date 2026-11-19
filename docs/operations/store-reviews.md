# store-reviews, playtest-feedback and sentry-issues

These are the Support numbers of the department tabs (plan `can-we-add-aspsecae-hashed-cloud`, P8): what users say in the stores, what playtesters said that is still open, and what is broken in Sentry. All three are deterministic agentctl runners with no model. Each publishes a `.prom` file through `.local/lib/prom-textfile.sh` (node_exporter textfile, job `workstation`). home-config's `prometheus-rules-kb-project.yaml` turns them into `kb_project_number{dept="support"}` and `kb_project_source_up`. Each is a row in `~/.config/agentctl/departments.tsv`.

## store-reviews

`store-reviews` prints one JSON document; `store-reviews publish` also writes `store_reviews.prom`. The `product-metrics` runner runs `publish` as its `store-reviews` step every 6 hours.

```json
{"generated_epoch": 1794766592, "window_days": 7, "apps": [
  {"project": "shape-city", "store": "app_store", "app": "6830805897", "listed": true, "total": 0, "recent": 0, "recent_positive": 0},
  {"project": "shape-city", "store": "play", "app": "com.acme.shapecity", "listed": true, "recent": 0, "recent_positive": 0},
  {"project": "shape-city", "store": "steam", "app": "5553740", "listed": false},
  {"project": "dodginballs", "store": "play", "app": "...", "error": "rbw is locked"}]}
```

The apps are each product's store targets in `project-map.json` (`trackers.<p>.targets[].live`: `steam.app`, `play.package`, `testflight.app`), the list release-state probes. An app shared by two projects is read once for each. A product with two apps on one store (a game and its demo) gets their sum.

| Store | Endpoint | `recent` (last 7 days) | `total` | Positive |
|---|---|---|---|---|
| Steam | `store.steampowered.com/appreviews/<app>`, public, no key, 100 a page | yes | `query_summary.total_reviews` | thumbs up |
| Google Play | Android Publisher `applications/<pkg>/reviews`, which holds only the last week, and only reviews with text | yes, reviews with text only | none: Play gives no lifetime count | 4 or 5 stars |
| App Store | App Store Connect `apps/<id>/customerReviews`, 200 a page | yes | `meta.paging.total` (reviews with text) | 4 or 5 stars |

Each store is read newest first, page by page, until a page reaches past the 7 days, at most 5 pages an app; a week that needs more is that app's error, never a short count. The stores are read side by side and each store's apps one after another, so a run holds at most one call open per provider. Play counts only reviews with text, so its numbers run lower than Steam's for the same product; Play's API gives no star-only ratings.

Credentials are release-state's read-only app keys `release_state_play` and `release_state_asc` (`docs/operations/release-state.md`, Store credentials), read only while rbw is unlocked. Reviews are app information, so the sales keys are not used.

| Series | Labels | Meaning |
|---|---|---|
| `store_reviews` | `project, store, window` (`7d`, `all`) | review count, summed over the product's apps on the store |
| `store_reviews_positive` | as above | positive reviews |
| `store_reviews_up` | `store` | 1 when every app of the store read |
| `store_reviews_generated_seconds` | none | the last run |

A product and store with an unread app write no count, and an app with `listed: false` adds nothing, so its cell reads "off", never 0.

## Playtest feedback

`playtest-feedback` prints one JSON document; `playtest-feedback publish` also writes `playtest_feedback.prom`. The `product-metrics` runner runs `publish` as its `playtest-feedback` step every 6 hours.

Testers send `/feedback` to playtest-bot. Its `scripts/feedback-to-ptask` files each point on the game's `playtest.md`, ending in `(playtest <session title>, <author>)`. An open row with that ending is open feedback. Every lab project with a `playtest.md` (`notes projects --stats --json`) is counted. A project without one writes nothing.

| Series | Labels | Meaning |
|---|---|---|
| `playtest_feedback_open` | `project` | open feedback rows |
| `playtest_feedback_up` | none | 1 when every sheet read |
| `playtest_feedback_generated_seconds` | none | the last run |

## Sentry issues

`sentry-issues` prints one JSON document; `sentry-issues publish` also writes `sentry_issues.prom`. The `product-metrics` runner runs `publish` as its `sentry-issues` step every 6 hours.

The products are the `project-map.json` trackers that carry a `sentry` list, the slugs of their projects (`"sentry": ["shapecity"]`) in the Sentry org named by the map's top-level `sentry_org` (the map is private, so the org name is not written here; `SENTRY_ORG` overrides it). A product with no list is not read. Per slug the exporter asks Sentry for the project (`GET /projects/<org>/<slug>/`, scope `project:read`), then counts issues through `GET /organizations/<org>/issues/?project=<the project's id>` (scope `event:read`; the endpoint takes ids, not slugs), 100 a page, following the `Link` header's cursor, at most 30 pages (3,000 issues) a count. A count past that, or a full page with no `Link` header, is the slug's error, never a short count. Slugs are read one after another.

| Count | Query | Meaning |
|---|---|---|
| `unresolved` | `is:unresolved`, `statsPeriod=90d` | unresolved issues with activity in the last 90 days (an open issue quiet for longer is not counted) |
| `new` | `firstSeen:-7d`, `statsPeriod=7d` | issues first seen in the last 7 days, resolved or not |

A slug the org has no project for answers 404 and is `listed: false`: it adds nothing, so its cell reads "off", never 0. When every slug answers 404 the org or the token is wrong (Sentry words both the same way), so each slug carries that error and `sentry_issues_up` is 0. `first_event` is whether the project ever received an event. A project that exists with `first_event: false` is a game whose build has no DSN yet: set it in `Assets/Playground/Resources/CrashReports/crash-reports.json` of unity-core-playground (`docs/operations/crash-reports.md` there). On 2026-11-15 all four DSNs there (`playground`, `apociseum`, `shapecity`, `dodginballs`) were empty. A web or API product sets its DSN in the app's environment, which this exporter cannot read.

The credential is the rbw entry `sentry_read_only`: a Sentry token with only `project:read` and `event:read`, the whole entry password. It is read only while rbw is unlocked, and reaches curl on stdin, never argv. Sentry publishes no number for these endpoints: each has its own per-second cap and a concurrent cap, answered in `X-Sentry-Rate-Limit-*` headers (read 2026-11-15, docs.sentry.io/api/ratelimits). A run makes 3 to 6 calls a slug; a 429 or 5xx is retried by `store_fetch` after its `Retry-After`, else a doubling wait.

| Series | Labels | Meaning |
|---|---|---|
| `sentry_issues_unresolved` | `project` | unresolved issues active in the last 90 days, summed over the product's Sentry projects |
| `sentry_issues_new` | `project, window` (`7d`) | issues first seen in the window |
| `sentry_issues_up` | none | 1 when every slug read |
| `sentry_issues_generated_seconds` | none | the last run |

A product with an unread slug writes no count, and a slug that is `listed: false` adds nothing.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Play or App Store apps say `rbw is locked` | Run `rbw unlock`. The runner never unlocks the vault, so `store_reviews_up{store}` is 0 until the next run after unlock. Steam needs no key and still reads |
| Steam app `listed: false` | Steam answered 302: the app has no public store page yet. It is not an error, and nothing is written for it |
| An app says `more than 5 pages of reviews in the window` | Over 500 Steam, 1,000 App Store or 500 Play reviews in a week. Raise `PAGES` in `.local/bin/store-reviews` |
| An app says `review answer could not be counted` | The store answered 200, but a review lacks the date the window needs. Look at the raw answer with `store-reviews` |
| Play `HTTP 403` | The service account in `release_state_play` lacks app-information access for the package. Check Play Console, Users and permissions |
| App Store `HTTP 403` | The `release_state_asc` key's role cannot read customer reviews |
| `kb_project_source_up{source="store-reviews"}` 0 | The last run is over a day old (runner not armed: `agentctl reload`; `agentctl status product-metrics` names the step that failed), or a store did not read |
| `playtest-feedback` says `notes projects --stats --json failed` | The notes CLI failed; `playtest_feedback_up` is 0 until it reads. Run `notes doctor` |
| A tester's feedback is not counted | The row was not filed by `feedback-to-ptask`, or its ending was edited. Re-file it with the script |
| `sentry-issues` says `no rbw entry sentry_read_only` | The token is not in the vault. Mint a Sentry token with `project:read` and `event:read` only and save it as `sentry_read_only` |
| `sentry-issues` says `rbw is locked` | Run `rbw unlock`. The runner never unlocks the vault, so `sentry_issues_up` is 0 until the next run after unlock |
| Sentry `HTTP 401` or `403` | The token is wrong, revoked, or lacks `project:read` or `event:read` |
| `sentry-issues` says `every project answered 404` | `sentry_org` in the project-map is wrong, or the token belongs to another org. Fix the org or re-mint the token |
| A product reads "off" though it has Sentry | Its slug in `trackers.<p>.sentry` is not the project's slug in the org (the 404 is `listed: false`). Copy the slug from the project's Sentry URL |
| A game reads 0 issues for good | The project's `first_event` is false: the build has no DSN, so nothing is sent. See crash-reports.md |
| `kb_project_source_up{source="sentry-issues"}` 0 | The last run is over a day old (runner not armed: `agentctl reload`; `agentctl status product-metrics` names the step that failed), or a slug did not read |
