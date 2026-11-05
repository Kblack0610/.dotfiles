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
| `stop_at` | regex: from the first line it matches, nothing more is linted (a Details section) |
| `item`, `max_items`, `max_item` | regex for a list item line, how many items, how long each one |
| `require` | `[[regex, name], ...]`: each regex must match somewhere |
| `forbid` | `[[regex, why], ...]`: none may match, and the why is the finding |
| `quiet` | `[regex, ...]`: a message that matches goes at normal or lower (`quiet-buzzed`) |
| `max_title` | characters in a page title, when `--title` is given |
| `source` | where `comms-lint report` finds past messages (below) |

Source kinds:
- `{kind = "ledger", path = ...}`: agent-notify's TSV ledger (time, priority, title, message). The report counts buzzes per day by sender from the title.
- `{kind = "files", glob = ...}`: one message per file, dated by its mtime.
- `{kind = "section", glob = ..., heading = ...}`: the named section of each file, such as the `## Morning` block of each daily note.

`[ids] patterns` lists regexes for names meant for machines (watch tags, ask ids, `hub/<repo>:<n>`, `agent-<n>`, `<repo>#<n>`, paths, queue slugs). `[report]` sets which priorities buzz and the buzzes-per-day target.
