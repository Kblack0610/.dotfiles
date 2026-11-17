# event-catalogue

The Analytics tab of a product page (plan `can-we-add-aspsecae-hashed-cloud`, P5) shows which events the product sends. `event-catalogue` builds that list: one JSON file per product at `~/.agent/event-catalogue/<project>.json`, written by the runner `event-catalogue` once a day and by hand with `event-catalogue build`. It reads source files, so it needs no credentials and no network.

```json
{"project": "beta", "generated_epoch": 1794766592,
 "sources": ["bnb-platform:packages/game-platform/analytics/src/shared/types.ts"],
 "events": [{"name": "app_banner_shown", "group": "Mobile app install banner on the web", "props": ["platform"]}]}
```

`event-catalogue show <project>` prints one file; `event-catalogue check <project>` exits 0 when the file has an event, and is the check of the alpha stage row "An event catalogue" in `stages.md`.

## Sources

A source is an `analytics` row of kind `file` in `departments.tsv` (the department catalog in `~/.config/agentctl/`), written `<repo-key>:<path>`. A product with several rows gets one file with all their events. The file name picks the reader.

| Source | Reader | Events | Props |
|---|---|---|---|
| `*.ts` | the `AnalyticsEvents` const, the PostHog names in the platform's analytics package | each `NAME: 'value'` line; a `// Heading` comment is its group | only a heading that says "(all carry a `p` property)" gives its events `p`; the file maps no other event to its properties |
| `*.md` | the table under `## Usage events` (Kind, When, Props) | each backticked name in the Kind cell | the backticked names in the Props cell up to its first colon, for every event of the row |

A group headed "<Product> specific events" goes to that product only (squashed to lowercase letters and digits, `Alpha` is `alpha`); every other group goes to each product that names the file. Unity's six session events sit in `unity-core-playground`'s `docs/operations/online.md`, so that row, not `UsageSharing.cs`, is the source. The table gives a Props cell per row, so `session_start` carries `seconds` here although only the end event does.

A product whose rows include a source that cannot be read gets no file at all, and its last good file is removed: a catalogue missing some of its events is worse than none, and `check` then fails instead of passing on a stale file. A Props or When cell holding a literal `|` shifts the table columns; none does today.

To add a product: add its `analytics` file row to `departments.tsv`. To add a reader: a function in `.local/bin/event-catalogue` and a case on the file's suffix.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `cannot read <source>` | The repo is not cloned here, or the path moved. Check the `paths` entry in `project-map.json` and the row in `departments.tsv` |
| `no events in <source>` | The const or the `## Usage events` heading was renamed. The reader looks for `export const AnalyticsEvents =` and the exact heading |
| `no reader for <source>` | The row names a file that is neither `.ts` nor `.md`; point it at the doc that lists the events |
| The files are missing or a day old | The runner `event-catalogue` (private overlay, `.config/agentctl/agents/event-catalogue.conf`) is not armed: `agentctl reload`. A hand run is `event-catalogue build` |
| `check` fails for a product | No file yet (run `event-catalogue build`), the product has no analytics row, or one of its sources could not be read (the build says which) |

## Not built yet

Per-event counts need the PostHog exporter (a personal API key and a project id per product, not in rbw yet), and feature-level Unity events are a change in `unity-core-playground`.
