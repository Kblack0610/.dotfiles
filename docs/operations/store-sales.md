# store-sales

`store-sales` answers "what did the app stores make yesterday". The morning briefing's Money section prints one line per store from it (hub-core `money.rs`). Plan: `~/.claude/plans/update-warm-dongarra.md`, P2.

## Command

`store-sales [YYYY-MM-DD]` prints one JSON document for the day (default yesterday, local time):

```json
{"date": "2026-11-09", "generated_epoch": 1794347194, "sources": [
  {"name": "App Store", "basis": "proceeds", "made": [{"currency": "USD", "amount": 7.0}], "sales": 2, "titles": ["Shape City"]},
  {"name": "Google Play", "basis": "charged", "error": "no rbw entry store_sales_play"}]}
```

A source that could not be read has `error` and no `made`. The briefing shows it as "not read" and lists it under Could not read. It never shows it as $0. `made` is summed per currency: neither store converts a day's sales.

| Source | Report | `basis` |
|---|---|---|
| App Store | Sales and Trends, daily `SALES`/`SUMMARY`, units times developer proceeds. Covers every app on the account | `proceeds`: after Apple's cut |
| Google Play | The month's `sales/salesreport_YYYYMM.zip` in the developer bucket, rows charged on the day | `charged`: what buyers paid, before Google's cut. Play's earnings report is monthly only |

## Store credentials

Each store has its own read-only rbw entry, read only while the vault is unlocked (a locked vault is never unlocked; both sources say `rbw is locked`). These are separate from release-state's keys (`docs/operations/release-state.md`, Store credentials) and from the release keys the upload workflows use. The signing code is shared with release-state in `.local/lib/store-auth.sh`.

| rbw entry (password field, one line) | Contents | Scope |
|---|---|---|
| `store_sales_asc` | `{"key_id", "issuer_id", "p8", "vendor_number"}`, `p8` the `.p8` file in base64 | App Store Connect API key with the Sales role. The vendor number is on Payments and Financial Reports |
| `store_sales_play` | The service-account JSON, minified, plus `"bucket": "pubsite_prod_rev_<id>"` | Play Console "View financial data" only. The bucket is the Cloud Storage URI on Download reports, Financial |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `no rbw entry store_sales_asc` or `store_sales_play` | The key is not made yet: see Store credentials |
| `rbw is locked` | Run `rbw unlock`. The collector never unlocks the vault |
| App Store `HTTP 403` | The key's role cannot read sales reports. It needs Sales, Finance or Admin. release-state's Developer key cannot |
| App Store `HTTP 400: Invalid vendor number` | `vendor_number` in the rbw entry is wrong |
| App Store `HTTP 404` without "no sales" | The day's report is not out yet. Apple publishes Americas daily reports by 5am Pacific |
| App Store "no sales yesterday" | Apple answered "There were no sales for the date specified" |
| Google Play `no sales/salesreport_YYYYMM.zip in the bucket yet` | No sale this month yet, or the first report of the month is not published yet |
| Google Play `HTTP 403` | The service account lacks "View financial data" in Play Console, Users and permissions |
