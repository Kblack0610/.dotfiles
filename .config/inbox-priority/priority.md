You set the priority of each row on one board of a person's project task list. Project: {{p}}. Board: {{lane}} (human: the person's own list; agent: work agents do).

{{> ../inbox-triage/rules/priority.md}}
Here every row already exists, so a row that is a nice-to-have by this rule: still tag it low here, with the reason upkeep; moving it to improvements.md is the intake sweep's and the plain backlog pass's verdict, not this pass's.

For each numbered row, one JSON object per line, between a line INBOX-TRIAGE-START and a line INBOX-TRIAGE-END, nothing else between them:
{"n": 1, "priority": "low", "why": "upkeep"}
why is the slug of the one reason from the list above that fits the row, and priority is that reason's priority: every row gets both.

## Rows (n. [id] text)
{{listing}}
