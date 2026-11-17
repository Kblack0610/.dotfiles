# store-sales

`store-sales` answers "what did the app stores and Steam make yesterday". The morning briefing's Money section prints one line per store from it (hub-core `money.rs`), then one line per trader account (Trader, below).

## Command

`store-sales [YYYY-MM-DD]` prints one JSON document for the day (default yesterday, local time):

```json
{"date": "2026-11-09", "generated_epoch": 1794347194, "sources": [
  {"name": "App Store", "basis": "proceeds", "made": [{"currency": "USD", "amount": 7.0}], "sales": 2, "titles": ["Shape City"]},
  {"name": "Google Play", "basis": "charged", "error": "no rbw entry store_sales_play"},
  {"name": "Steam", "basis": "net", "made": [{"currency": "USD", "amount": 8.99}], "sales": 1, "titles": ["Apociseum"]}]}
```

A source that could not be read has `error` and no `made`. The briefing shows it as "not read" and lists it under Could not read. It never shows it as $0. `made` is summed per currency: neither store converts a day's sales.

| Source | Report | `basis` |
|---|---|---|
| App Store | Sales and Trends, daily `SALES`/`SUMMARY`, units times developer proceeds. Covers every app on the account | `proceeds`: after Apple's cut |
| Google Play | The month's `sales/salesreport_YYYYMM.zip` in the developer bucket, rows charged on the day | `charged`: what buyers paid, before Google's cut. Play's earnings report is monthly only |
| Steam | Partner financial API `IPartnerFinancialsService/GetDetailedSales` for the day, every page. Covers every app and package on the partner account. A row with no money (a retail key activation) does not count | `net`: in USD after refunds and tax, before Valve's cut. Steam's days are Pacific time and the day asked is the caller's local date, so a machine off Pacific time reads a day shifted by its offset. An answer with no rows reads as no sales, because Steam does not tell a quiet day from one not reported yet |

## Store credentials

Each store has its own read-only rbw entry, read only while the vault is unlocked (a locked vault is never unlocked; both sources say `rbw is locked`). These are separate from release-state's keys (`docs/operations/release-state.md`, Store credentials) and from the release keys the upload workflows use. The signing code is shared with release-state in `.local/lib/store-auth.sh`.

| rbw entry (password field, one line) | Contents | Scope |
|---|---|---|
| `store_sales_asc` | `{"key_id", "issuer_id", "p8", "vendor_number"}`, `p8` the `.p8` file in base64 | App Store Connect API key with the Sales role. The vendor number is on Payments and Financial Reports |
| `store_sales_play` | The service-account JSON, minified, plus `"bucket": "pubsite_prod_<id>"` | Play Console account permissions, all read-only: "View financial data" and "View app information and download bulk reports (read-only)", which brings "View app quality information" with it. The bucket is the Cloud Storage URI on Download reports, Financial: `pubsite_prod_<id>` on newer accounts, `pubsite_prod_rev_<id>` on older ones, so copy it, never build it |
| `store_sales_steam` | The bare Web API key, one line | The key of a Steamworks Financial API Group (Users and Permissions, Manage Groups). Such a group has no users and no apps: the key reads sales and nothing else. It is not release-state's publisher key `release_state_steam` |

## Per-product revenue (Money tab)

Each product's store revenue is stored in the home metrics database and shown on the Grafana project board and the agent web dashboard's Money tab, which sit on the LAN or behind Forgejo sign-in. Each source in the document also carries `apps`, the same amounts per app, keyed by the store's own id: the Apple identifier (an in-app purchase goes to its parent app, matched by SKU), the Play package, the Steam app id (a DLC or package sale goes to its primary app).

`store-sales publish [YYYY-MM-DD]` prints the same document and writes `store_sales.prom` through `.local/lib/prom-textfile.sh`. It maps the apps to products through `trackers.<p>.targets[].live` (`steam.app`, `play.package`, `testflight.app`) in `project-map.json`, the list `store-reviews` reads (`.local/lib/store-apps.sh`). The runner `store-sales` runs it every 6 hours, for yesterday: Apple publishes its daily report by 5am Pacific, and a run before then reads App Store as not read, never as 0. The runner is model-free.

| Series | Labels | Meaning |
|---|---|---|
| `store_sales_amount` | `project, store, currency` | what the product's apps made that day on the store, in the store's basis (table above); `currency` is lower case. A product with no sale on the store writes nothing, never 0 |
| `store_sales_units` | `project, store` | paid units |
| `store_sales_unattributed` | `store, currency` | amounts from apps no product lists in its targets: a new product that is not wired in project-map shows here instead of vanishing |
| `store_sales_up` | `store` | 1 when the store read on the last run. The source `store-sales` is up while any store read |
| `store_sales_day_seconds` | none | local midnight opening the day the amounts are for |
| `store_sales_generated_seconds` | none | the last run |

A store that could not be read, or read empty (Steam and Apple answer a day they have not reported the same way as a quiet one), writes no amount for any product, so its cells read "off", never 0. An in-app purchase whose parent app has no row of its own in that day's Apple report cannot be matched to the app: it lands in `store_sales_unattributed`. `publish` exits 1 when the pass is FAILED (no textfile directory, no store read). home-config's `prometheus-rules-kb-project.yaml` records `kb_project_number{dept="money", metric="revenue_<store>_<currency>_1d"}` (`revenue_steam_usd_1d`, `revenue_play_usd_1d`, `revenue_app_store_eur_1d`) and `kb_project_source_up{source="store-sales"}`. Different currencies are never added together. Play and Steam amounts are before the store's cut (`basis` above), so they are not what the studio receives.

## Trader

The Money section's trader lines come from Prometheus (`CC_PROM_URL`). Each says what one of the trader's paper accounts made yesterday: its equity at today's local midnight less its equity at yesterday's. The trader repo's exporter publishes the series from its own tables. It exports only paper accounts, so every trader line says paper. A live account needs its own reader once the trader's live guard lifts.

| Line | Series | Written by |
|---|---|---|
| Alpaca (paper) | `trader_broker_equity{broker="alpaca_paper"}`, age `trader_broker_read_age_seconds` | The hourly `trader-broker-read` CronJob (`broker_balances`) |
| Kalshi paper league | Summed over accounts: `trader_paper_equity` less `trader_paper_capital`, age `trader_paper_marked_age_seconds` | The paper league after each Kalshi recorder sweep (`paper_accounts`) |

A day is not read when either midnight has no reading, or its reading is older than `TRADER_STALE_SECS` (3h) in `money.rs`. Prometheus keeps 7 days.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `no rbw entry store_sales_asc` or `store_sales_play` | The key is not made yet: see Store credentials |
| `rbw is locked` | Run `rbw unlock`. The collector never unlocks the vault |
| App Store `HTTP 403` | The key's role cannot read sales reports. It needs Sales, Finance or Admin. release-state's Developer key cannot |
| App Store `HTTP 400: Invalid vendor number` | `vendor_number` in the rbw entry is wrong |
| App Store `HTTP 404` without "no sales" | The day's report is not out yet. Apple publishes Americas daily reports by 5am Pacific |
| App Store "no sales yesterday" | Apple answered "There were no sales for the date specified" |
| Google Play `no sales/salesreport_YYYYMM.zip in the bucket yet` | No sale this month yet, or the month's first report is not out. It also shows when `bucket` in the rbw entry is wrong, because GCS answers 404 for a bucket that does not exist: compare it with the URI in Play Console. An account with no paid app or in-app product has no sales report at all |
| Google Play `HTTP 403` in the first two days after an invite or a new permission | Google applies a Play Console grant to the reports bucket after a delay of up to about two days. Wait, then run `store-sales` again |
| Google Play `HTTP 403` after two days | The service account's grants are short. Check Play Console, Users and permissions, Account permissions: it holds the read-only permissions in Store credentials, and nothing else. The Play Console grant is what opens the bucket: no GCP IAM role on it is needed |
| Steam `no rbw entry store_sales_steam` | The Financial API key is not made yet: see Store credentials |
| Steam `report did not parse` | A row lacks `net_sales_usd`, `gross_sales_usd` or `net_units_sold`, or is dated another day than the one asked. Steam changed its answer: fix the parser in `store-sales`, never default the field |
| `store_sales_amount` missing for one product | The store did not read (`store_sales_up{store}` 0: see the rows above), or the product has no `trackers.<p>.targets[].live` entry for that store. A sale on an app no product lists is in `store_sales_unattributed` |
| `kb_project_source_up{source="store-sales"}` 0 | The last run is over a day old (runner not armed: `agentctl reload`), or no store read at all. One store down does not turn it: Play answers "no sales report" for an account with no paid sale, for good, so its products read "off" and `store_sales_up{store="play"}` is 0 |
| Any store `HTTP 429` or `HTTP 5xx` | The store still refused after two retries (`STORE_RETRIES` in `.local/lib/store-auth.sh`, each after its Retry-After). The next run reads it again |
| Steam `HTTP 403` | The key is not a Financial API Group key, or the group's IP allow list does not hold this machine's address. Check the group's page in Steamworks |
| Steam `more than 20 pages of sales` | The day's sales cursor did not stop. `STEAM_PAGES` in `store-sales` is the cap; raise it only when a real day is that long |
| Trader `no data at <time>` | Prometheus had no series then: the trader's exporter or its scrape was down, or the series is newer than the day (they began 2026-11-12). Check `trader_db_up` and the trader-web pod |
| Trader `the reading at <time> was Nh old` | The writer stopped: `trader-broker-read` for Alpaca, the markets recorder and paper league for Kalshi. Check those CronJobs in the trader's namespace |
| Trader `CC_PROM_URL is not set` or `<url> did not answer (curl exit status: N)` | The Prometheus endpoint is unset in `~/.config/command-center/env` or does not answer |
