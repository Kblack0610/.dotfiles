"use strict";
// Log's Actions section: what the fleet's machinery did (shepherd nudges, skips and escalations,
// dispatch starts and reaps, pages, failed runs, queue adds and finishes), newest first and
// grouped by local day. /api/actions reads the ledgers each writer already keeps, through the
// same reader as `hub actions`. The chips filter by actor, then verb; their counts cover the
// whole window, the list its newest rows.

const ACTION_WINDOWS = [[12, "12h"], [24, "24h"], [72, "3d"], [168, "7d"]];
// A page at one of these priorities gets a pill; normal and low ones do not.
const ACTION_LOUD = ["high", "urgent"];
const ast = { data: null, err: null, hours: 24, actor: "", verb: "" };

const refreshActions = coalesce(async () => {
  try { ast.data = await api("/api/actions?hours=" + ast.hours); ast.err = null; } catch (e) { ast.err = e.message; }
  if (st.tab === "log") renderActions();
});

// Open Log at its Actions section filtered to one actor (and verb), from another tab's link.
function showActions(actor, verb) {
  ast.actor = actor || "";
  ast.verb = verb || "";
  st.section = "actions";
  setTab("log");
}

const chipBtn = (on, attr, val, label, n) =>
  `<button class="${on ? "on" : ""}" ${attr}="${esc(val)}">${esc(label)} <span class="n">${n}</span></button>`;

function actionChips(counts) {
  const actors = Object.keys(counts).sort((a, b) => sumOf(counts[b]) - sumOf(counts[a]) || a.localeCompare(b));
  const all = actors.reduce((s, a) => s + sumOf(counts[a]), 0);
  let html = `<div class="seg fseg">${chipBtn(!ast.actor, "data-actor", "", "all", all)}` +
    actors.map((a) => chipBtn(ast.actor === a, "data-actor", a, a, sumOf(counts[a]))).join("") + `</div>`;
  const verbs = counts[ast.actor];
  if (verbs) {
    const vs = Object.keys(verbs).sort((a, b) => verbs[b] - verbs[a] || a.localeCompare(b));
    html += `<div class="seg fseg">${chipBtn(!ast.verb, "data-verb", "", "every verb", sumOf(verbs))}` +
      vs.map((v) => chipBtn(ast.verb === v, "data-verb", v, v, verbs[v])).join("") + `</div>`;
  }
  return html;
}

function actionRow(a) {
  const loud = ACTION_LOUD.includes(a.priority) ? `<span class="pill ask">${esc(a.priority)}</span>` : "";
  return `<div class="frow" title="${esc(a.source)}"><span class="ft">${clock(a.at * 1e3)}</span>` +
    `<span class="pill">${esc(a.actor)}</span><b>${esc(a.verb)}</b>${loud}<span class="fx">${esc(a.text)}</span></div>`;
}

// Rows under one heading per local day, in the order given (newest first).
function byDay(rows) {
  let day = null, html = "";
  for (const a of rows) {
    const d = new Date(a.at * 1e3);
    const k = d.toDateString();
    if (k !== day) {
      if (day) html += `</div>`;
      day = k;
      html += `<h3 class="sub">${esc(d.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" }))}</h3><div class="card flist">`;
    }
    html += actionRow(a);
  }
  return day ? html + `</div>` : "";
}

function renderActions() {
  const el = $("actions");
  const d = ast.data;
  const windows = `<div class="seg fseg">` + ACTION_WINDOWS.map(([h, l]) =>
    `<button class="${ast.hours === h ? "on" : ""}" data-hours="${h}">${l}</button>`).join("") + `</div>`;
  if (ast.err) { paint(el, windows + `<div class="card err">${esc(ast.err)}</div>`); return; }
  if (!d) { paint(el, windows + `<div class="empty">Loading.</div>`); return; }
  if (ast.actor && !d.counts[ast.actor]) ast.verb = "";
  const rows = d.actions.filter((a) => (!ast.actor || a.actor === ast.actor) && (!ast.verb || a.verb === ast.verb));
  const verbs = d.counts[ast.actor] || {};
  const total = !ast.actor ? Object.values(d.counts).reduce((s, v) => s + sumOf(v), 0)
    : ast.verb ? verbs[ast.verb] || 0 : sumOf(verbs);
  const shown = rows.length < total ? ` <span class="muted">newest ${rows.length} of ${total} in the window</span>` : "";
  const errs = d.errors.map((e) => `<div class="card err">unread: ${esc(e)}</div>`).join("");
  const list = rows.length ? byDay(rows.slice(0, LOG_ROWS)) + older(rows.length - LOG_ROWS)
    : `<div class="empty">Nothing recorded${ast.actor ? " for this filter" : ""} in the window.</div>`;
  paint(el, `<div class="bhead"><span>what the machinery did${shown}</span></div>${windows}${actionChips(d.counts)}${errs}${list}`);
}

$("actions").addEventListener("click", (e) => {
  const b = e.target.closest("button");
  if (!b) return;
  if (b.dataset.hours) { ast.hours = Number(b.dataset.hours); refreshActions(); return; }
  if (b.dataset.actor !== undefined) { ast.actor = b.dataset.actor; ast.verb = ""; }
  else if (b.dataset.verb !== undefined) ast.verb = b.dataset.verb;
  else return;
  renderActions();
});

// The shepherd's log and agent-notify's push "actions"; the dispatch log and the run ledger
// arrive as "fleet", the queue as "queue".
const actionsFeed = pushed("log", ["actions", "fleet", "queue"], refreshActions);
LOG_PARTS.push({
  show() { renderActions(); actionsFeed.show(!ast.data); },
  onEvent: actionsFeed.onEvent,
});
