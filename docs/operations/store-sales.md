# store-sales

`store-sales` answers "what did the app stores and Steam make yesterday". The morning briefing's Money section prints one line per store from it (hub-core `money.rs`).

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
| `store_sales_play` | The service-account JSON, minified, plus `"bucket": "pubsite_prod_<id>"` | Play Console account permissions, read-only only: "View financial data" and "View app information and download bulk reports (read-only)", which brings "View app quality information" with it. The bucket is the Cloud Storage URI on Download reports, Financial: `pubsite_prod_<id>` on newer accounts, `pubsite_prod_rev_<id>` on older ones, so copy it, never build it |
| `store_sales_steam` | The bare Web API key, one line | The key of a Steamworks Financial API Group (Users and Permissions, Manage Groups). Such a group has no users and no apps: the key reads sales and nothing else. It is not release-state's publisher key `release_state_steam` |

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
| Google Play `HTTP 403` in the first two days after the invite | Google takes about a day to apply a Play Console invite to the reports bucket, sometimes longer. Wait, then run `store-sales` again |
| Google Play `HTTP 403` after two days | The service account's grants are short. Check Play Console, Users and permissions: it needs "View financial data", and guides say reading the bucket also takes "View app information and download bulk reports (read-only)". GCP IAM roles on the bucket are reported not to help |
| Steam `no rbw entry store_sales_steam` | The Financial API key is not made yet: see Store credentials |
| Steam `report did not parse` | A row lacks `net_sales_usd`, `gross_sales_usd` or `net_units_sold`, or is dated another day than the one asked. Steam changed its answer: fix the parser in `store-sales`, never default the field |
| Any store `HTTP 429` or `HTTP 5xx` | The store still refused after two retries (`STORE_RETRIES` in `.local/lib/store-auth.sh`, each after its Retry-After). The next run reads it again |
| Steam `HTTP 403` | The key is not a Financial API Group key, or the group's IP allow list does not hold this machine's address. Check the group's page in Steamworks |
| Steam `more than 20 pages of sales` | The day's sales cursor did not stop. `STEAM_PAGES` in `store-sales` is the cap; raise it only when a real day is that long |
