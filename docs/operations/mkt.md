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

## Verbs

- `mkt draft --project P --channel C --kind K [--title T] [--attach F]... <file>` opens an item and posts its review as an approval ask (`agent-ask post --kind approval --agent mkt`). The title defaults to the draft's first line. Image attachments (png, jpg, gif, webp) become the ask's `--preview` images, shown on the Waiting page above the answers and served by agent-web from `/api/asks/<id>/preview/<n>`, only for files inside the ledger. The ask's resume is `run: mkt answer <id>`, so `ask-resume` records the answer with no session waiting on it. The ask carries no session id, so no session gets the answer pasted back to it.
- `mkt answer <id> <ask>` reads the answer. Option `skip` skips the item, `post` sends it through the channel's adapter, `hand`, or a URL with at most two other words ("posted: <url>"), is a hand post whose URL is logged as the send, and other words mean revise. An item no longer in review is refused, so a second run changes nothing.
- `mkt log <id> <url> [--by who]` records a hand post of an approved item. An item already sent is refused.
- `mkt log --project P --channel C --kind K --title T [--by who] [--reviewed-by who] <url>` records something sent outside `mkt draft` as a new item, already sent. `store-console` and `mobile-store-metadata` call this after a store page or listing goes live.
- `mkt post <id> [--dry-run]` sends an item whose verdict is `post` through `post_<channel>`, a function in `mkt` that prints the public URL. No channel has an adapter yet, so every send is by hand and logged.
- `mkt skip <id> [--by who]` closes an item that will not go out: a revise once its new draft exists, or a draft whose ask was refused. A sent item is refused.
- `mkt list [--project P] [--state S] [--json]` and `mkt show <id>` read it.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `the review ask for <id> was not posted; the item stays a draft` | agent-ask refused the ask (its error is printed above, often a question over the cap). Fix the cause and draft again, then `mkt skip <id>` the draft left behind. |
| Marketing says `outbound ledger ... quiet` | `~/.agent/outbound/<project>` is not a readable directory. |
| An answered review stays in review | The ask's resume has not run: `ask-resume --dry-run` lists what it would run; `mkt answer <id> <ask>` by hand does the same. |
| A preview image shows broken on Waiting | The file is not under the ledger, or not an image; agent-web serves only those. `mkt draft` copies attachments there itself. |
