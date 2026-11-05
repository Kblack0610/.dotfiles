# channels.toml keys

`~/.config/comms-lint/channels.toml` has one `[channel.<name>]` table per surface. `[defaults]` fills any key a channel leaves out. `comms-lint` rejects unknown keys, so a typo fails loudly.

| Key | Meaning |
|---|---|
| `ascii` | true: a non-ASCII character fails (emoji pass only when `emoji` is true) |
| `emoji`, `max_emoji` | emoji allowed, at most `max_emoji` per message (0 = any number) |
| `max_chars` | the whole message (0 = no limit) |
| `max_lines` | non-blank lines (0 = no limit) |
| `max_line` | characters per line (0 = no limit) |
| `max_lead` | characters in the lead: the first line up to the end of its first sentence |
| `lead_ids` | true: the lead, and each item, may not open with an id from `[ids]` |
| `prose` | true: run de-ai-writing's `check.py`, whose hard rules fail the message (`COMMS_PROSE_CHECK` overrides the path) |
| `items_under` | regex for a heading: `max_items` counts only the items under it (the briefing's Needs you); every other check still reads the whole message |
| `item`, `max_items`, `max_item` | regex for a list item line, how many items, how long each one |
| `require` | `[[regex, name], ...]`: each regex must match somewhere |
| `forbid` | `[[regex, why], ...]`: none may match, and the why is the finding |
| `quiet` | `[regex, ...]`: a message that matches goes at normal or lower (`quiet-buzzed`) |
| `max_title` | characters in a page title, when `--title` is given |
| `source` | where `comms-lint report` finds past messages (below) |
| `group` | `messages` (default) or `rows`: rows grade as `rows_pass_pct`, apart from the messages' `pass_pct` |
| `refs` | true: the text must cite a reference from `[ids] refs` (a PR, a sha, a URL), else `no-ref` (board proofs) |

Source kinds:
- `{kind = "ledger", path = ...}`: agent-notify's TSV ledger (time, priority, title, message). The report counts buzzes per day by sender from the title.
- `{kind = "files", glob = ..., fields = [...]?}`: one message per file, dated by its mtime. With `fields`, only those `key: value` lines are linted (the ask files).
- `{kind = "section", glob = ..., heading = ...}`: the named section of each file, such as the `## Morning` block of each daily note.
- `{kind = "gh", query = ...}`: bodies of PRs merged in the window, from `gh search prs <query> --merged-at >=<day>`. A gh failure is one stderr line and an empty source, never a crash.
- `{kind = "command", cmd = [...], ...}`: a reader that prints JSONL, one record per row. The row format lives in that reader's parser, never here. `{since}`, `{since_date}` and `{days}` in `cmd` are filled from the window; `ts`, `text` and `path` name the record fields to use (defaults `ts`, `text`, `path`; `ts` is epoch or ISO); `select = {field = value}` keeps only matching records and `skip = {field = value}` drops them; `timeout` defaults to 120 s. A record with a `reject` field is a line the reader could not parse: it becomes a `shape` finding with that reason, and no other rule runs on it. A reader that fails with no output is one stderr line and an empty source.

The ledger kind reports a line with fewer than four fields (a message written with a raw newline) as a `shape` finding instead of skipping it.

`[ids] refs` lists what a `refs` channel may cite, searched anywhere in the text; it is separate from `patterns` because those are anchored for the lead and would false-match mid-text. `[ids] patterns` lists regexes for names meant for machines (watch tags, ask ids, `hub/<repo>:<n>`, `agent-<n>`, `<repo>#<n>`, paths, queue slugs). `[report]` sets which priorities buzz. The buzzes-per-day target is `buzzes_per_day_max` in `~/.config/agentctl/kpi-thresholds`, beside `comms_pass_pct_min` and `rows_pass_pct_min`.
