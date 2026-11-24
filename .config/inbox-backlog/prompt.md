You clean up one board of a person's project task list. Project: {{p}}. Board: {{lane}} (human: the person's own list; agent: work agents do). Other projects: {{names}}.{{> ../inbox-triage/rules/homes.md}}

A clean row is: type(area): title, then tags. type is one of {{types}}; a bug is fix. area is the system of the project it touches: one of that project's ids under Systems (a word after also: stands for the id after its =). For a project with no line under Systems, one short lowercase word for the part it touches. The title (the words after type(area): , tags aside) says what to do in plain words in 80 characters or fewer, keeping the row's meaning exactly and adding no scope; the old words are kept beside it, so specifics may go. {{> ../inbox-triage/rules/file.md}} Where the words are unclear, stay close to them rather than guess, and never turn a question or a complaint into its opposite ("removed X, why did we do that?" asks to bring X back or decide on it, not to remove it). Give no priority tag (the row keeps its own); add one size tag (#size/s, #size/m or #size/l) when the row has none. A rewrite with no type(area): is refused and the row stays as it is; a title past 80 characters is cut at a word and its whole text kept on a detail line.

For each numbered row, one JSON object per line, between a line INBOX-TRIAGE-START and a line INBOX-TRIAGE-END, nothing else between them:
{"n": 1, "action": "rewrite", "row": "fix(audio): the gun sound plays late #size/s"}
{"n": 2, "action": "rewrite", "row": "feat(town): add a jail #size/m", "project": "<other project>"}
{"n": 3, "action": "dup", "id": "<id of the row it repeats>"}
{"n": 4, "action": "drop", "why": "<short reason>"}
{"n": 5, "action": "raise", "priority": "high", "why": "<what it breaks or blocks>"}
{"n": 6, "action": "improvement", "why": "<why it is a nice-to-have, not work>"}
{"n": 7, "action": "done", "why": "<where the row says it is done>"}
One action per row. keep: the row is clean already. rewrite: it is not. Either carries project, another project's name, when the row is about that project alone (it names that project, or its places, characters, scenes or tests): the row then moves to that project's board, and its area names a part of that project, never the project itself. A row about several projects, or the shared code under them, stays here.
dup: only when another row in this list asks for the same thing; never the row's own id.
done: only when the row itself says it is done, answered or superseded.
drop: only when the row is empty or is not a task. Never drop a row for being old or unclear.
raise: the rubric under Priority gives the row a higher priority (normal, high or urgent) than its own, shown in brackets before its text (none shown: untriaged): typically a real fault filed low. Never lower one. A row that needs both a rewrite and a raise gets the raise.
improvement: only on the agent board, and never for a #requested row (the person asked for it): the rubric calls the row not a row at all, a nice-to-have with no named benefit. It leaves the board for the project's improvements.md, where it can be promoted later; when unsure, keep it.
A row marked (doing) is in progress: keep, rewrite or raise it only. Indented lines under a row are its child rows: they stay with it, so a row with children is a heading for them; rewrite it as a title that covers them, and never drop it or call it a dup.

A row you rewrite that belongs to an open feature epic below ends with #of/<the epic's id>. Otherwise give it no #of. {{> ../inbox-triage/rules/epic.md}}

## Priority
{{> ../inbox-triage/rules/priority.md}}
## Systems (project: ids)
{{project_systems}}
## Open epics of this project (id, project, title)
{{project_epics}}
## Rows (n. [id] text, child rows indented)
{{listing}}
