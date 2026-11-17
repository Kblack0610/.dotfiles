# mkt: the outbound ledger

`mkt` (`.local/bin/mkt`) keeps the record of everything that goes out for a product: a post, a store listing, an email, a pitch. Each item runs from draft, through the human's review, to sent with its public URL. The Marketing department tab reads the same ledger (plan `can-we-add-aspsecae-hashed-cloud`, P4): open items are its needs, and the Outbound section lists the last 30 days.

## The ledger

One JSONL file per product and month, `~/.agent/outbound/<project>/<YYYY-MM>.jsonl` (`MKT_LEDGER_DIR` moves the root). Every line is an event `{ts, id, event, ...}`, and an item is its events folded by `id` in file order. `mkt` (jq) and hub-core `outbound.rs` (the web and TUI tabs) fold them the same way. An item's files (the draft and its attachments) are copied to `<project>/files/<id>/`, so the review shows what was approved even if the original changes later.

| Event | Written by | Fields |
|---|---|---|
| `draft` | `mkt draft`, `mkt log` for a new item | `project, channel, kind, title, draft, attachments, utm, by` |
| `review` | `mkt draft` once its ask is posted | `ask` |
| `verdict` | `mkt answer`, `mkt skip` | `verdict` (`hand`, `post`, `skip`, `revise`), `reviewed_by`, `note` |
| `sent` | `mkt answer` (an answer with a URL), `mkt log`, `mkt post` | `url, by` |

An item's id is `YYMMDD-xxxxxx`. Its `utm` is `utm_source=<channel>&utm_medium=<kind>&utm_campaign=<project>&utm_content=<id>`; add it to the links in the draft, so a visit can be traced to the item.

| State | Means |
|---|---|
| `draft` | written, review ask not posted (the ask was refused, or `--no-ask`) |
| `review` | waiting on the human's answer; 7 days or more turns Marketing amber |
| `approved` | answered `hand` with no URL yet (Marketing asks for `mkt log`), or `post` |
| `revise` | the answer was free words: a change to make, then a new draft, and `mkt skip <id>` closes this one |
| `skipped` | answered `skip`, or closed with `mkt skip`; never sent, and not listed under Outbound |
| `sent` | has its public URL |

Kinds: `post listing email pitch press-kit screenshots mockup` (`KINDS` in `mkt`). A channel is any lowercase word (`reddit`, `steam`, `bluesky`).

## Channels and calendar

What gets drafted, for which product and where, is content that lives in the marketing lab project: `channels.yaml` and `calendar.yaml` in the notes tree at `lab/bnb/projects/current/marketing/docs/` (project-map `marketing`, lab `bnb`). Neither file holds UTM tags, because `mkt` builds them per item as described above.

`channels.yaml`:

| Key | Holds |
|---|---|
| `accounts.<channel>` | `handle` (null when there is no account yet) and `owner`. The last post date is not kept here: `mkt list --project P --json` reads it from the ledger. |
| `products.<key>` | One entry per product. The key is the project-map tracker name, so it is also `--project` and `utm_campaign`. |
| `.shape` | `saas`, `mobile-app`, `pc-game` or `mobile-game`. It picks the pipeline in the bnb-studios marketing docs. |
| `.pitch` | The line a post opens with. It must be true on prod the day the post goes out. |
| `.links` | Public URLs a draft may link, by name (`home`, `steam`, `appstore`, `play`, `site`). |
| `.tag_prefix` | The release tag a new version is read from (`release-state`), when the product has one. |
| `.channels.<channel>` | The posting mode, quoted. `"draft"`: the human posts, then answers with the URL or runs `mkt log`. `"approve"`: `mkt post` sends it once the review is answered `post`, and only when the channel has a `post_<channel>`. `"off"`: nothing is drafted. A channel that is not listed is off. |
| `.notes` | What a drafter must know before writing for the product. |

Every channel that a product or an event names is a key of `accounts`. Reddit, HN, Product Hunt, Steam events and X stay `"draft"`: their rules ban automated posts, and X charges per post.

`calendar.yaml` holds `events` (`id`, `title`, `start`, `end` as inclusive `YYYY-MM-DD`, `products`, `channels`, `source`, `checked`, `notes`) and `recurring` (`id`, `title`, `rule` as `weekly: <day>` or `per-release`, `products`, `channels`, `notes`). The drafter writes for an event within 14 days of its start, on each product's channels that are not off.

## Verbs

- `mkt draft --project P --channel C --kind K [--title T] [--attach F]... <file>` opens an item and posts its review as an approval ask (`agent-ask post --kind approval --agent mkt`). The title defaults to the draft's first line. `--trigger KEY` stores what the draft answers (a tag, a week, an event) on the row, which is how `mkt-drafts` knows not to draft it twice. A `{utm}` in the copied draft is replaced by the item's UTM query string, so a drafter writes `<url>?{utm}`. Image attachments (png, jpg, gif, webp) become the ask's `--preview` images, shown on the Waiting page above the answers and served by agent-web from `/api/asks/<id>/preview/<n>`, only for files inside the ledger. The ask's resume is `run: mkt answer <id>`, so `ask-resume` records the answer with no session waiting on it. The ask carries no session id, so no session gets the answer pasted back to it.
- `mkt answer <id> <ask>` reads the answer. Option `skip` skips the item, `post` sends it through the channel's adapter, `hand`, or a URL with at most two other words ("posted: <url>"), is a hand post whose URL is logged as the send, and other words mean revise. An item no longer in review is refused, so a second run changes nothing.
- `mkt log <id> <url> [--by who]` records a hand post of an approved item. An item already sent is refused.
- `mkt log --project P --channel C --kind K --title T [--by who] [--reviewed-by who] <url>` records something sent outside `mkt draft` as a new item, already sent. `store-console` and `mobile-store-metadata` call this after a store page or listing goes live.
- `mkt post <id> [--dry-run]` sends an item whose verdict is `post` through `post_<channel>`, a function in `mkt` that prints the public URL. No channel has an adapter yet, so every send is by hand and logged.
- `mkt skip <id> [--by who]` closes an item that will not go out: a revise once its new draft exists, or a draft whose ask was refused. A sent item is refused.
- `mkt list [--project P] [--state S] [--json]` and `mkt show <id>` read it.
- `mkt scorecard [--project P] [--json]` is the channel scorecard, rendered from the ledger: one row per project, channel and kind with items sent, sent by hand vs through an adapter (a send `by: mkt`), items still open, the median hours from review ask to verdict, and the first and last send. Skipped items are left out. It replaces a hand-typed metrics sheet (board row mkt-5). Visits per item (UTM `utm_content`) join it once analytics reads them; until then a channel has no result to judge, so nothing asks to drop one.

## mkt-drafts

`mkt-drafts` (`.local/bin/mkt-drafts`, runner `agents/mkt-drafts.conf` in the private overlay, daily 07:40) opens a draft per product, channel and trigger through `mkt draft --by mkt-drafts`, so each lands in the ledger with its approval ask. It plans with no model and makes one call per item, on the conf's budget (`agentctl budget mkt-drafts`); an exit 75 from `agentctl-run` is a BLOCKED run that retries tomorrow. Nothing is sent: the human answers each ask.

Which items it plans, for every product in `channels.yaml` and every channel whose mode is not `"off"`:

| Trigger | When | Key stored on the row |
|---|---|---|
| release | the newest tag with the product's `tag_prefix` is under 14 days old (`release-state changelog --json`, its `at` and `text`) | `release:<tag>` |
| week | user-facing PRs merged in the last 7 days (`release-state merged`), on `bluesky` and `mastodon` only | `week:<ISO week>` |
| event | a `calendar.yaml` event for the product and channel starts within 14 days or is running | `event:<id>` |
| recurring | a `weekly: <day>` rule whose next day is within 3 days | `<id>:<date>` |

A row in the ledger in any state, skipped included, with the same project, channel and trigger counts as drafted, so a skipped draft is not asked again. A decline (the model finds nothing true to say) is a skipped row whose draft file holds the reason. `kind` follows the channel: `listing` for appstore, play and steam, `email` for newsletter, `post` for the rest. `mkt-drafts plan [--json]` prints what a run would do and calls no model.

Knobs, all env with defaults in the script: `RELEASE_DAYS` 14, `EVENT_DAYS` 14, `RECUR_DAYS` 3, `WEEKLY_CHANNELS`, `MAX_DRAFTS` 6 a run (the rest waits for the next run, so a first run on a long-tagged product is bounded). Not done: no image is attached, since nothing yet says which screenshot belongs to a release (`mkt draft --attach` takes them when something does), and a `per-release` calendar rule is covered by the release trigger instead of a second one.

## costs.csv check

`mkt costs <costs.csv> [--max-age-days N]` lists the marketing benchmark rows due a re-check, one per line (`id`, `item`, why), then a count. A row is due when its `last_checked` is older than N days (183, about 6 months) or not a date, or its `notes` do not open with `verified`. Exit 0 means none is due, 1 means some are, and 2 (with an `unreadable:` line) means the file or its header could not be read.

Sentinel runs it monthly as the watch `mkt-costs-stale` on `~/.notes/lab/bnb/projects/current/bnb-studios/docs/marketing/costs.csv`. It pages once when rows go due and once when they are clear again. A row is cleared by re-checking its source and updating `last_checked` and `notes`, which is the quarterly marketing research refresh's job.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| A channel mode reads as `false` instead of `off` | YAML 1.1 parses a bare `off` as a boolean. Quote every mode (`"off"`). |
| `the review ask for <id> was not posted; the item stays a draft` | agent-ask refused the ask (its error is printed above, often a question over the cap). Fix the cause and draft again, then `mkt skip <id>` the draft left behind. |
| Marketing says `outbound ledger ... quiet` | `~/.agent/outbound/<project>` is not a readable directory. |
| An answered review stays in review | The ask's resume has not run: `ask-resume --dry-run` lists what it would run; `mkt answer <id> <ask>` by hand does the same. |
| `mkt-drafts run` reports BLOCKED | The runner's budget stopped a call (`agentctl budget mkt-drafts`); the undrafted items stay planned and the next run takes them. Raise the day cap only after reading `calls.jsonl`. |
| A product gets no drafts | `mkt-drafts plan` shows why: every channel `"off"`, no tag under 14 days old, or the product has no `tag_prefix` in `channels.yaml`. |
| A preview image shows broken on Waiting | The file is not under the ledger, or not an image; agent-web serves only those. `mkt draft` copies attachments there itself. |
