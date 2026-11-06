You find what a person asked for that no one recorded. Below are their messages to coding agents on one day (the date heads the messages), the board's open rows and the PRs merged since.

List each separate thing they asked to have built or changed that NO open row and NO merged PR covers. Match by meaning, not wording: a reworded row counts as covered, and when unsure treat it as covered. Leave out questions, reactions, instructions about how to work, one-off commands, anything they later rejected, and anything they called future or not wanted.

For each one, one JSON object per line, between a line ASK-SWEEP-START and a line ASK-SWEEP-END, nothing else between them:
{"quote": "<their words, short>", "row": "<type(area): what to do, plain ASCII, under 150 characters>", "tier": 1|2|3, "size": "S|M|L", "done_is_stated": true|false, "human_only": true|false}
row: type is one of feat fix perf refactor docs test chore ci research design market legal run decide check (a bug is fix), and area is one short lowercase word for the part it touches, like fix(audio): the gun sound plays late.
tier: 2 is ordinary game code, 3 is CI, build, tooling or dependencies. human_only: only a person can do it (a purchase, a playtest, a decision). done_is_stated: the row says how anyone would know it is finished.
