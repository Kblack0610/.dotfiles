# store-reviews and playtest-feedback

These are the two Support numbers of the department tabs (plan `can-we-add-aspsecae-hashed-cloud`, P8): what users say in the stores, and what playtesters said that is still open. Both are deterministic agentctl runners with no model. Each publishes a `.prom` file through `.local/lib/prom-textfile.sh` (node_exporter textfile, job `workstation`). home-config's `prometheus-rules-kb-project.yaml` turns them into `kb_project_number{dept="support"}` and `kb_project_source_up`. Both are rows in `~/.config/agentctl/departments.tsv`.

## store-reviews

`store-reviews` prints one JSON document; `store-reviews publish` also writes `store_reviews.prom`. The runner `store-reviews` runs `publish` every 6 hours.

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

`playtest-feedback` prints one JSON document; `playtest-feedback publish` also writes `playtest_feedback.prom`. The runner `playtest-feedback` runs `publish` hourly.

Testers send `/feedback` to playtest-bot. Its `scripts/feedback-to-ptask` files each point on the game's `playtest.md`, ending in `(playtest <session title>, <author>)`. An open row with that ending is open feedback. Every lab project with a `playtest.md` (`notes projects --stats --json`) is counted. A project without one writes nothing.

| Series | Labels | Meaning |
|---|---|---|
| `playtest_feedback_open` | `project` | open feedback rows |
| `playtest_feedback_up` | none | 1 when every sheet read |
| `playtest_feedback_generated_seconds` | none | the last run |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Play or App Store apps say `rbw is locked` | Run `rbw unlock`. The runner never unlocks the vault, so `store_reviews_up{store}` is 0 until the next run after unlock. Steam needs no key and still reads |
| Steam app `listed: false` | Steam answered 302: the app has no public store page yet. It is not an error, and nothing is written for it |
| An app says `more than 5 pages of reviews in the window` | Over 500 Steam, 1,000 App Store or 500 Play reviews in a week. Raise `PAGES` in `.local/bin/store-reviews` |
| An app says `review answer could not be counted` | The store answered 200, but a review lacks the date the window needs. Look at the raw answer with `store-reviews` |
| Play `HTTP 403` | The service account in `release_state_play` lacks app-information access for the package. Check Play Console, Users and permissions |
| App Store `HTTP 403` | The `release_state_asc` key's role cannot read customer reviews |
| `kb_project_source_up{source="store-reviews"}` 0 | The last run is over a day old (runner not armed: `agentctl reload`), or a store did not read |
| `playtest-feedback` says `notes projects --stats --json failed` | The notes CLI failed; `playtest_feedback_up` is 0 until it reads. Run `notes doctor` |
| A tester's feedback is not counted | The row was not filed by `feedback-to-ptask`, or its ending was edited. Re-file it with the script |
