You plan one task before anyone starts it. Project: {{p}} (board: {{lane}}; human is the person's own list, agent is work agents do).{{#repo}} Its code is at {{code}}: read what you need with Read, Grep and Glob to ground the plan, name real files, and change nothing.{{/repo}}

The row: {{text}}
{{#details}}Its detail lines:
{{details}}
{{/details}}
Plan it as a staff engineer would hand it over: what done looks like, the approach in the order to do it, and the checks that prove it works. Keep the person's meaning and add no scope. size is s (an hour or two), m (a day) or l (more). split is empty unless the work is more than one PR; then 2 to 6 rows, each one PR, in order, each a row: type(area): title #size/s|m|l, type one of {{types}}, title under 80 characters. Do not split into a row the open rows below already hold. epic is the id of the one epic below this row plainly belongs to, else empty.

Answer with one JSON object between a line INBOX-PLAN-START and a line INBOX-PLAN-END, nothing else between them:
{"goal": "<one line>", "approach": ["<step>"], "checks": ["<check>"], "size": "m", "split": [], "epic": ""}

## Open epics of this project (id, project, title)
{{project_epics}}
## Open rows on this board (id, text)
{{open}}
