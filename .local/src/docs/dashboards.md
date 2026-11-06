# Dashboard standards

How we build and change a dashboard: the `hub` TUI (`../hub-tui`), agent-web (`../agent-web`), the waybar chips, Grafana boards in home-config, and any new one in any repo. Read this before adding a tab, a section, a tile or a new dashboard. The agent runtime's own invariants are in `standards.md` beside this file.

## Rules

Each rule has its why. A rule a test checks names the test.

1. One tab per question the human asks, never one tab per data source. Each tab title answers a question ("what needs me?", "where is each project?"). A new data source joins the tab whose question it answers. Why: tabs grouped by source left the same session on four tabs and the reader assembling the answer in their head.
2. Each fact has one home. Anywhere else it shows only as a count or badge that links to that home. Why: pending asks had six homes on agent-web and three in the TUI, and they disagreed whenever one lagged.
3. Summary first, details on demand. The summary goes at the top. Detail opens when a row is opened. Logs and audit trails sit behind a click or in a folded section, and trends live in Grafana (`o` on a TUI tab, a link on the web). Why: a 1000-row ledger at top level buries the three rows that need action.
4. Exceptions first. Red and amber sections start open; a green section collapses to one line ("CI ok: 8/10 slots, 0 failed in 24h"). Why: the glance is for what is wrong; green detail is noise until it is asked for.
5. Green, amber and red mean ok, needs attention and broken, and nothing else uses those hues. Categorical series take the chart palette in agent-web `static/charts.js`. Anything past its slots folds into "Other"; a hue is never generated. Why: a red that means "category 3" teaches the reader to ignore red.
6. Every number is counted; no model writes a tile or a card. A percent, ETA or status comes from a deterministic function over files, CLIs or metrics, and the card says what it counted. Why: the agent-written "where we are" note did not help the human (2026-11-05), and a model score cannot be checked.
7. A list is a data table, and a card is only the record you opened. The hub and agent-web are the developer console the human triages every system from. Any list of records is a table on the shared table component: every header sorts (descending, then ascending, then the default order), count chips filter by state, and the search takes several filters at once: terms are ANDed, `key:value` matches a column, a repeated key ORs, `-key:value` excludes, a bare word matches the text (`project:playground kind:fix -acct:k1 nightly`). The whole view lives in the URL, so a filtered view is a link. The component is `hub_core::table` (`Row` per table, one `View` that filters, sorts and counts); agent-web applies it on the server and `static/table.js` only draws its summary, the hub's `datatable.rs` maps keys to it (`/` query, `f` state, `s` sort column, `S` direction, `x` clear). Times and ids are exact (`1h05`, `#1688`, the ISO time on hover), never "a while ago". An opened record's first line says what it is, its state and since when, what it needs from the human, and when it will be done. Why: card lists hid the metadata the human triages by, and `agent-queue list` in a terminal told them more than the Queue tab did (2026-11-06); slug-headed cards with a comma-separated meta line were unreadable (agent-web #920).
8. Both hub surfaces show the same tabs in the same order with the same section names, from one reader in hub-core. A view that needs data the reader lacks adds it to hub-core; the view never reads a store's files itself. Why: two readers of one store drift; `hub-core` exists so the terminal and the browser cannot disagree.
9. Update on the store's own event and poll only what has none. Agent-web pushes on file change. Prometheus-backed tabs poll at one named cadence with a server-side cache. A hidden tab refetches only when it is shown again. Why: the global no-sleep-and-hope rule, and a phone on the web view.
10. Load heavy detail only when it is opened. Transcripts, logs and screens are fetched on select, never for every row up front. Why: the human asked that sessions not all load until clicked (2026-11-03).
11. It works at phone width and in an 80-column terminal. Tables scroll inside their own box and the page never scrolls sideways. Why: agent-web is mostly read from a phone, and the hub runs in a tmux pane.
12. Mock it up before you build it. A new tab or a reshaped one starts as an ASCII mockup the human approves, in the plan. Why: lesson 2026-10-15, where a board built without one missed what the human pictured.
13. A layout change says what moved, where to, and why. A PR that removes, merges, moves or renames a tab or section carries a "Moved and removed" table in its body: old place, new home, why. It updates the "Retired names" table below in the same PR, and the old name keeps working as an alias: `#old` on the web and `hub --tab old`. The table also lists every key and shortcut whose meaning changes (TUI digits, tmux bindings, waybar clicks). TUI digits follow the layout order, so moving a tab renumbers the ones after it. Why: a view that disappears without a note looks like a regression, and waybar, tmux and bookmarks still point at the old name.
14. Done means the human can see it. A dashboard change is done when it shows on the live surface (the agent-web site after the stowed main checkout rebuilds, `hub` in its tmux window), checked with a screenshot. Passing tests are not enough. Why: lesson 2026-10-15, and the 2026-11-03 note "does not close till I can see it".

## Patterns

- Tile: a label, one big number or word, and its colour by rule 5. Clicking it opens the section that explains it.
- Progress bar: counted done over total, with the raw counts beside the percent and the unit named ("17/25 rows, weighted by size"). An ETA is shown only when its rate is above zero, and it says which window it used.
- Needs-you list: one list, ranked by what each row holds and how long it waited (`hub_core::home::needs`), with what it holds shown on the row; every surface keeps that order. Each row is a kind (ask, plan, dialog, red), its owner, what to do, and the key or button that does it in place.
- Folded section: `<details data-k>` on the web, with its open state kept by `static/ui.js`. In the TUI, a section head with a `+`/`-` marker. A folded head shows its count.
- Long list: capped, with a "+N older" control ("+N more" when the list is not ordered by time). It is never unbounded at top level.

## Phone widget

The Companion app's Template widget is the main mobile view: Home, shortened to what fits at 4x4. `hub phone --json` (`hub_core::phone`) gives its rows from the same `home::build` join, `agent-mqtt-publish` sends them as `sensor.agent_overview`, and home-config's `phone_widget.jinja` lays them out, the only place with HTML or colours. The System block is read in the cluster, so it still shows with the workstation off. The widget clips at the bottom, so sections run most important first, a green section is one line and reds cap at 6. Row lengths are the `phone` channel in `channels.toml`.

## Hub layout

Both surfaces show the layout below, built in the phases of the plan `~/.agent/plans/dotfiles/any-veiw-that-can-effervescent-conway.md`. The list itself is `hub-core/src/layout.rs`: the TUI's `the_tabs_are_the_layout_and_each_digit_its_place` and agent-web's `tab_names_are_the_layout` fail when a surface drifts from it, and each surface's `log_folds_are_the_layout` holds Log's sections to it. TUI digits 1-8 are the order.

| # | Tab | Question | Status |
|---|---|---|---|
| 1 | Home | What needs me, and is everything ok? | landed (#929): `hub_core::home`, the TUI's front page; the landing page on both surfaces |
| 2 | Daily | What is my day? | landed: `hub_core::focus` over `notes show --json`, the daily note read clean on a phone (the Focus tab renamed and moved after Home, 2026-11-05). Web: one nav beside the note (a column on a wide screen, a sticky strip that scrolls sideways on a phone): the places, Daily first, then Outbox with its waiting count, Inbox and the day note's own links, each once, only the open view marked; then the open note's parts (lanes, Briefing, sections) to jump to. The head has the date, open and done counts, prev and next day, Refresh, Edit and Rendered or Raw; then each `## Focus` lane a card (Urgent, High, Low open; Done folded) whose tasks are rows with their tags as chips, the lane's own tag said once in its head; then the day's briefing as one open section; the note's other sections fold below. On a day note each task row is live: its box ticks or unticks it, `-` removes it with Undo, and a `+` line at the end of each lane but Done adds a task tagged as the lane, each the one line changed and written through `notes put --base` like Save. `[[wikilinks]]` open the linked note in the same view at `#daily/<target>` (Back returns); `#p:<name>` opens `#projects/<name>`. Edit and Save rewrite the note through `notes put --base` (a stale hash writes nothing and shows both versions; the draft stays on the device). `#daily/outbox` is the outbox (`hub_core::outbox`): the whole outbox as a textarea saved through `notes outbox put --base` (compare-and-swap; a 409 is merged line by line, the line under the cursor held back until Enter), Send (or Ctrl+Enter) sends it now, the held line too; then Handled today. Project rows stay on Projects; the Projects board lists no Focus rows, only a count linking here. TUI: read-only, `[` `]` step a day, `t` today, `o` shows the outbox in place of the note (Enter edits it in `$EDITOR`, `o` or Esc back); key 2, `hub --tab daily` or `hub --tab outbox` |
| 3 | Queue | What will agents do next? Add work. | landed (#920 cards); a pipeline line leads both surfaces (`hub_core::pipeline`, the `agent_chain_*` gauges; TUI `o` and the web link open Grafana Agents / Overview) |
| 4 | Projects | Where is each project, and its tasks? | landed: `hub_core::projects`, one card per lab project with its stage, queue counts and open version's progress by size, pace and ETA; Enter (TUI) or Open rows (web) opens the card, read then by `hub_core::page`: goal, Flow, Needs you open, then Build by system, Next stage, Shipped, In flight and Agent note as folds with counts (`f` in the TUI), over that project's rows. All shows every project's rows. |
| 5 | Sessions | What is each agent doing? Act on it. | landed (#961): one row per session, grouped by bucket on the web and ranked by bucket in the TUI, with task, PR and CI, phases, ETA, idle and account. TUI: Enter opens the detail pane with the session's forecast timeline, i p u m x c a act. Web: the shepherd's pass is the list's first line and its session is pinned first; with no session open the detail pane is the overview (bucket tiles that filter the list, then the last 24h and Shepherd, folded); an open session shows its fleet-state card folded above the transcript, which loads only then. |
| 6 | Infra | Is the machinery healthy? | landed (#971): `hub_core::infra` on both surfaces, sections health, red now, red fixes (`hub_core::reds` over `fleet-bench reds --json`: each red queued as a fix in 7 days, the open ones worst first, the settled ones folded to a count; a failed read says so), machines (one table in place of POOLS, CI by machine and the Machines tab), CI (running, queued, failed 24h; green is one line), jobs (TUI: 8 rows, Enter opens the table; web: the table), cloud runners, governor. |
| 7 | Log | What happened? | landed (#1077): the day from `day-log`, its history (TUI `h` lists the days; web the per-day bars), then folded sections, each read when it opens and capped at `FOLD_ROWS` (50) with a `+N older` line: Actions, Changes, Rundowns, Judges' verdicts, Forecast (TUI only: the web never had one) and Ranked sessions (a row opens the session's full card). TUI keys a c s v f w |
| 8 | Fleet | Who is working, on what, and can I afford it? | P4 of the Fleet plan: ONE table (`hub_core::table`, the Jobs table's component on both surfaces) of every agentctl runner and live session, by tier: tier 1 the runners that run the sessions (the shepherd, fleet-dispatch, the sentinel; a conf's `TIER=1` and `OVERSEES=sessions|dispatched` say which sessions each one folds), tier 2 the other runners, tier 3 the sessions, with state (failed, needs you, stalled first), since, doing now, under it, dollars in 24h and project. A row opens its record: a runner its page, `#fleet/<runner>` and `hub tab fleet <runner>`; a session the Sessions record, `#sessions/<target>` (TUI: Enter, which leaves for Sessions). A tier 1 row has a fold button (TUI `z`) that hides its sessions; a search or a state chip shows every match, folded or not. `/ f s S x` and the web bar, dropdowns, chips and headers are the shared table's (rule 7). Below it Claude accounts. The runner page keeps `#fleet/<runner>` as before (14 days of runs with their logs, status and activity, 24h and 7d calls, registry, conf and the extras block its `DETAIL=` picks); the judges' tiles and lists are on their pages and in Log's Judges' verdicts section |

### What moves, and why

| From | To | Why |
|---|---|---|
| TUI Overview header, web Infra header, web Waiting, Watch tiles, Today "waiting on you", Fleet NIGHTLY and ASKS | Home: Needs you, Numbers, Health | Asks had six homes (rule 2); the human's first question is "what needs me?" |
| TUI Overview body (pools, machines, queued, down) | Infra | One machines table instead of three |
| Board (both surfaces) | Projects: a project's rows, plus an All view | The human asked for project progress next to the tasks (2026-11-04) |
| Projects list card: goal, running list, queue counts, status note | The opened card: goal at its head, In flight and Agent note folds | The list answers where each project is in two lines; the rest loads on open (rules 7, 10) |
| TUI Fleet session controls and stage table, web Sessions and Watch | Sessions: one list with stages and actions | The same sessions were listed twice on one TUI tab and on two web tabs |
| TUI Forecast timeline | Sessions: ETA column and detail pane | A session's ETA belongs on its row |
| TUI CI and Machines, web Jobs | Infra sections | One question: is the machinery healthy (rule 1) |
| TUI Today and History | Log | One question: what happened |
| Web Focus "Add to outbox" box | Outbox tab: the whole outbox as an editable doc | One place writes the outbox from the hub, and it shows what intake did with each line (2026-11-05) |
| Outbox tab (both surfaces) | Daily: `#daily/outbox` on the web, second in Daily's nav after Daily; `o` on the TUI Daily tab | The human asked for a clean daily note view with a link to the outbox, not a tab of its own (2026-11-05) |
| Focus tab (both surfaces) | Daily, second after Home | It is the daily note, so it is named for it; Home is the landing page again (2026-11-05) |
| Web Daily links row (a chip per note link), "Links in this note" footer, the head's Back and Today, the outbox's Back to Daily and Inbox buttons | Daily's nav: the places (Daily first) and the note's parts | The links showed three times (chips, inline, footer) and Outbox looked selected while on Daily; asked 2026-11-06 for one clean nav, side on web, scrolling top on phone |
| Web Actions, Watch Changes, Shepherd rundowns, judge verdict lists, Forecast burn-up and baseline | Log, folded sections (#1077; folded at the bottom of Sessions from #961 until then) | Audit trails behind a click (rule 3) |
| Fleet Dispatch judge and Answer judge sections (their tiles and newest verdicts) | The judge's runner page, `#fleet/dispatch-judge` and `#fleet/ask-judge`, picked by `DETAIL=`, and its tier 2 row in the Fleet table; the lists stay in Log | A judge's numbers belong with its runner's runs and calls; the Fleet tab is one table (P4, rules 3 and 7) |
| Fleet Workers table (its own chips, lane list and sort), its expandable registry row, the `d` details key | Tier 1 and 2 rows of the one Fleet table; the registry is on the runner's page | Two tables with two filters on one tab; a row opens a record instead of unfolding in place (P4) |
| Fleet Tonight order (web button, TUI `t`) | The runner's next start in the `doing` cell (`next HH:MM`), and the Jobs table for the timers | Tonight was a second order of the same rows; the table sorts instead (P4, assumed) |
| Answer judge disagreements list | Log, Judges' verdicts: every answer verdict, its `wrong` filter is the old list | Asked for 2026-11-05: see what the judge said yes to and why, not only where it missed |
| New: ranked sessions and the session card (`agentctl-session-outcomes worst`, `card`) | Log, folded section (#1077) | Asked for 2026-11-04 (session telemetry); one reader, `hub_core::outcomes`, for both surfaces (rule 8) |
| New: red fixes (`fleet-bench reds --json`) | Infra, under Red now | Asked for 2026-11-06: see whether each auto-triaged red was fixed and stayed fixed; one reader, `hub_core::reds`, for both surfaces (rule 8) |
| Web Shepherd pass card | Sessions, one line | It is one status line, too small for a tab |
| Web Shepherd chat | Sessions: the shepherd session pinned first, opened like any session | The chat is that session's transcript and compose box, which Sessions already has |

### Retired names

Old tab names that still resolve, and where they land. Each phase adds its rows.

| Old name | Lands on | Since |
|---|---|---|
| `overview` (TUI, `hub --tab overview`) | Home | #929 |
| `waiting`, `asks` (agent-web `#waiting`, `#asks`) | Home | #929 |
| `board` (agent-web `#board`, `hub --tab board`, `hub tab board`) | Projects | #949 |
| `forecast` (TUI, `hub --tab forecast`) | Log, scrolled to the Forecast fold (Sessions from #961) | #1077 |
| `today`, `history` (TUI `hub --tab today`, `hub --tab history`, keys 7 and 8; agent-web `#today`, `#history`) | Log; `history` opens the TUI day list | #1077 |
| `actions` (agent-web `#actions`, the tab) | Log, its Actions section | #1077 |
| `watch`, `shepherd` (agent-web `#watch`, `#shepherd`; `hub --tab watch`, `hub --tab shepherd`) | Sessions | #961 |
| `UNCLEAR` (the bucket, on every surface) | CHAT for the human's own conversation, DONE when its queue item moved on, STALLED when its item still runs here with nothing on the branch | #1137 |
| `jobs`, `ci`, `machines` (TUI `hub --tab jobs`, `hub --tab ci`, `hub --tab machines`, keys 4 and 5; agent-web `#jobs`) | Infra, scrolled to that section; `jobs` opens the TUI jobs table | #971 |
| `outbox` (agent-web `#outbox`, `hub --tab outbox`) | Daily, showing the outbox (`#daily/outbox`) | #1075 |
| `focus` (agent-web `#focus`, `#focus/<note>`; `hub --tab focus`) | Daily (`#daily`, `#daily/<note>`) | #1075 |

### Log

- Merges by hour are per project, on both surfaces: one row (TUI) or one stacked colour (web) per project, the busiest first, with the hourly total last. Both draw `hub_core::boards::merges_by_hour` over the server's local hours; the web gets it in `/api/log` (`hours`, `projects`).
- Merged and Open PRs are grouped by project in the same order, each group with its count, its first 8 rows and the rest under "+N more". A PR's area and group stay as a short label on its row. Clicking a project in the web legend narrows both lists to that group.
- A PR's project is its repo's name in `project-map.json` (`project_of_repos_json` in `project-name.sh`, the same registry the Spend by project names come from); a record written before day-log stamped `project` falls back to the repo name without its leading dot.
