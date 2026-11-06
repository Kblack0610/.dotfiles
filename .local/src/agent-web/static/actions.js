"use strict";
// Log's Actions section: what the fleet's machinery did (shepherd nudges, skips and escalations,
// dispatch starts and reaps, pages, failed runs, queue adds and finishes), newest first.
// /api/actions reads the ledgers each writer already keeps, through the same reader as `hub
// actions`. The list is the shared table (table.js): the server filters and sorts by the view in
// Log's URL query, which also holds the window (`#log?q=actor:shepherd&hours=72`).

const ACTION_WINDOWS = [[12, "12h"], [24, "24h"], [72, "3d"], [168, "7d"]];
const ACTION_HOURS = 24;
// `read` is the view the data answers; `all` shows past the first LOG_ROWS.
const ast = { data: null, err: null, read: null, all: false };

const actionHours = () => Number(new URLSearchParams(st.views.log || "").get("hours")) || ACTION_HOURS;

const refreshActions = coalesce(async () => {
  const view = st.views.log || "", p = tblParams(view);
  p.set("hours", actionHours());
  try { ast.data = await api("/api/actions?" + p); ast.err = null; ast.read = view; } catch (e) { ast.err = e.message; }
  if (st.tab === "log") renderActions();
});

// Open Log at its Actions section filtered to one actor (and verb), from another tab's link.
function showActions(actor, verb) {
  st.section = "actions";
  const q = [actor && `actor:${actor}`, verb && `verb:${verb}`].filter(Boolean).join(" ");
  setTab("log", undefined, tblSet(st.views.log, { q, s: "", sort: "", dir: "" }));
}

const chipBtn = (on, attr, val, label, n) =>
  `<button class="${on ? "on" : ""}" ${attr}="${esc(val)}">${esc(label)} <span class="n">${n}</span></button>`;

const ACTION_COLS = { when: ["when", "n"], actor: ["actor"], verb: ["verb"], prio: ["prio"], source: ["source"], text: ["text"] };

const actionRow = (a) => `<tr><td class="n" title="${esc(new Date(a.at * 1e3).toISOString())}">${stamp(a.at)}</td>` +
  `<td>${esc(a.actor)}</td><td><b>${esc(a.verb)}</b></td><td>${esc(a.priority || "")}</td>` +
  `<td class="muted">${esc(a.source)}</td><td class="wrap">${esc(a.text)}</td></tr>`;

function actionsHead(d) {
  const inWindow = sumOf(Object.values(d.counts).map(sumOf));
  const hours = actionHours();
  const newest = d.table.total < inWindow ? `, newest ${d.table.total}` : "";
  const errs = [ast.err, ...d.errors.map((e) => `unread: ${e}`)].filter(Boolean).map((e) => `<div class="card err">${esc(e)}</div>`).join("");
  return `<div class="bhead"><span>what the machinery did, ${d.table.shown} of ${inWindow} in ${hours}h${newest}</span></div>` +
    `<div class="seg fseg">` + ACTION_WINDOWS.map(([h, l]) => `<button class="${hours === h ? "on" : ""}" data-hours="${h}">${l}</button>`).join("") + `</div>${errs}`;
}

function actionsBody(d) {
  const shown = d.actions, rows = ast.all ? shown : shown.slice(0, LOG_ROWS), more = shown.length - rows.length;
  return shown.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(d.table, ACTION_COLS)}${rows.map(actionRow).join("")}</table>` +
      tblMore(more) + `</div>`
    : `<div class="empty">${d.table.total ? "No action matches." : "Nothing recorded in the window."}</div>`;
}

function renderActions() {
  const el = $("actions"), d = ast.data;
  if (!d || !d.table) { paint(el, `<div class="${ast.err ? "card err" : "empty"}">${esc(ast.err || "Loading.")}</div>`); return; }
  tblPaint(el, "actions", d.table, "search, or actor:shepherd verb:nudge -actor:dispatch", { head: actionsHead(d), body: actionsBody(d) });
}

// The view changed: the URL follows it and the server applies it.
function actionsView(patch) {
  setQuery(tblSet(st.views.log, patch));
  ast.all = false;
  refreshActions();
}

$("actions").addEventListener("click", (e) => {
  const t = e.target;
  if (t.dataset.all) { ast.all = true; renderActions(); return; }
  const h = t.closest("[data-hours]");
  if (h) { actionsView({ hours: h.dataset.hours === String(ACTION_HOURS) ? "" : h.dataset.hours }); return; }
});
tblBind($("actions"), actionsView);

// The shepherd's log and agent-notify's push "actions"; the dispatch log and the run ledger
// arrive as "fleet", the queue as "queue".
const actionsFeed = pushed("log", ["actions", "fleet", "queue"], refreshActions);
LOG_PARTS.push({
  show() {
    // A view this page has not read asks the server, and when it came by a link opens its section.
    const view = st.views.log || "", fresh = ast.read !== view;
    if (fresh && view) $("sec-actions").open = true;
    renderActions();
    actionsFeed.show(fresh);
  },
  onEvent: actionsFeed.onEvent,
});
