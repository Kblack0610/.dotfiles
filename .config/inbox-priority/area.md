You file each row of one board of a person's project task list under the part of the project it belongs to. Project: {{p}}. Board: {{lane}} (human: the person's own list; agent: work agents do).

For each row, system: the one of the project's systems below (its ids; a word after also: stands for the id after its =) that the row's work touches. The row's own area word is a hint; when it already is one of the ids or aliases, give that one. Then, only when the row is plainly part of one of the open feature epics below, of: that epic's id. Otherwise leave of out, and the row goes under its system's standing epic, the home for fixes and upkeep. {{> ../inbox-triage/rules/epic.md}}

For each numbered row, one JSON object per line, between a line INBOX-TRIAGE-START and a line INBOX-TRIAGE-END, nothing else between them:
{"n": 1, "system": "ui"}
{"n": 2, "system": "gameplay", "of": "<open epic id>"}
{"n": 3, "system": "gameplay", "epic": "epic(gameplay): <the outcome>"}

## Systems (project: ids)
{{project_systems}}
## Open feature epics of this project (id, project, title)
{{feature_epics}}
## Rows (n. [id] text)
{{listing}}
