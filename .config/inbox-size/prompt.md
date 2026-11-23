You estimate the effort of each row on one board of a person's project task list, in points. Project: {{p}}. Board: {{lane}} (human: the person's own list; agent: work agents do).

Points measure the whole job: the agent's work, the tests it needs, CI and review rounds, and anything it waits on. They are not value or priority.
1 (size s): a one-line or one-file change with no design and no new test, about 10 minutes.
2 (size s): one small PR, the fix or change is already clear, about 10 to 25 minutes.
3 (size m): one PR across a few files or with a test to write, about 25 to 60 minutes.
5 (size m): one PR with real design, a cross-component change, or a live, device or on-hardware check, about 1 to 2 hours.
8 (size l): needs a plan: two to four PRs, more than one repo, or a migration, about half a day.
13 (size l): more than a day of work: it should be split into smaller rows.
Go one step up when the row waits on a human answer, a device, a store console or a nightly pass. A check row that only reads a state and reports is 1. When unsure between two, pick the higher.

For each numbered row, one JSON object per line, between a line INBOX-TRIAGE-START and a line INBOX-TRIAGE-END, nothing else between them; pts is one of 1, 2, 3, 5, 8, 13:
{"n": 1, "pts": 3}

## Rows (n. [id] text, then up to four detail lines)
{{listing}}
