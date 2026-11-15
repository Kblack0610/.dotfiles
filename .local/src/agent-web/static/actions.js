"use strict";
// Log's Actions section: what the fleet's machinery did (shepherd nudges, skips and escalations,
// dispatch starts and reaps, pages, failed runs, queue adds and finishes), newest first.
// /api/actions reads the ledgers each writer already keeps, through the same reader as `hub
// actions`. The list is the shared table (table.js): the server filters and sorts by the view in
// Log's URL query, which also holds the window (`#log?q=actor:shepherd&hours=72`).

const ACTION_WINDOWS = [["12", "12h"], ["", "24h"], ["72", "3d"], ["168", "7d"]];
const ACTION_HOURS = 24;
// `read` is the view the data answers; `all` shows past the first LOG_ROWS.
const ast = tblTab({
  tab: "log", id: "actions", api: "/api/actions", hint: "search, or actor:shepherd verb:nudge -actor:dispatch",
  shown: () => logShows("actions"),
  wait: "Loading.", state: { read: null, all: false },
  params: (p, t) => { p.set("hours", actionHours()); t.asked = actionsView(); }, got: (t) => { t.read = t.asked; },
  days: () => ({ key: "hours", on: actionHours() === ACTION_HOURS ? "" : String(actionHours()), windows: ACTION_WINDOWS }),
  head: (t) => actionsHead(t.data), body: (t) => actionsBody(t.data),
});

// The URL's window, when it is one of the buttons: what the server is asked for.
function actionHours() {
  const h = new URLSearchParams(st.views.log || "").get("hours");
  return h && ACTION_WINDOWS.some(([w]) => w === h) ? Number(h) : ACTION_HOURS;
}

// This table's keys of Log's URL query: the Work table shares that query.
function actionsView() {
  const v = tblParams(st.views.log), h = new URLSearchParams(st.views.log || "").get("hours");
  if (h) v.set("hours", h);
  return v.toString();
}

// Open Log at its Actions section filtered to one actor (and verb), from another tab's link.
function showActions(actor, verb) {
  st.section = "actions";
  const q = [actor && `actor:${actor}`, verb && `verb:${verb}`].filter(Boolean).join(" ");
  setTab("log", "actions", tblSet(st.views.log, { q, s: "", sort: "", dir: "" }));
}

const ACTION_COLS = { when: ["when", "n"], actor: ["actor"], verb: ["verb"], prio: ["prio"], source: ["source"], text: ["text"] };

const actionRow = (a) => `<tr><td class="n" title="${esc(new Date(a.at * 1e3).toISOString())}">${stamp(a.at)}</td>` +
  `<td>${esc(a.actor)}</td><td><b>${esc(a.verb)}</b></td><td>${esc(a.priority || "")}</td>` +
  `<td class="muted">${esc(a.source)}</td><td class="wrap">${esc(a.text)}</td></tr>`;

// Log's Actions fold carries the title (index.html); the window buttons and the state chips count
// the rows, so the head is only what could not be read.
function actionsHead(d) {
  return [ast.err, ...d.errors.map((e) => `unread: ${e}`)].filter(Boolean).map((e) => `<div class="card err">${esc(e)}</div>`).join("");
}

function actionsBody(d) {
  const shown = d.actions, rows = ast.all ? shown : shown.slice(0, LOG_ROWS), more = shown.length - rows.length;
  return shown.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(d.table, ACTION_COLS)}${rows.map(actionRow).join("")}</table>` +
      tblMore(more) + `</div>`
    : `<div class="empty">${d.table.total ? "No action matches." : "Nothing recorded in the window."}</div>`;
}

// The shepherd's log and agent-notify's push "actions"; the dispatch log and the run ledger
// arrive as "fleet", the queue as "queue", the ingest record as "outbox".
const actionsFeed = pushed("log", ["actions", "fleet", "queue", "outbox"], ast.refresh, () => logShows("actions"));
LOG_PARTS.push({
  sec: "actions",
  show() {
    // A view this page has not read asks the server, and when it came by a link opens its section.
    const view = actionsView(), fresh = ast.read !== view;
    if (fresh && view) $("sec-actions").open = true;
    ast.render();
    actionsFeed.show(fresh);
  },
  onEvent: actionsFeed.onEvent,
});
