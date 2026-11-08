"use strict";
// The Projects tab: one table row per lab project on the shared table (/api/projects applies
// the view, hub_core::projects, the rows the hub TUI's Projects tab draws) with its open
// version's progress by size, its pace and ETA, and its queue, in flight first. A click opens
// the project: its card, the opened record, its page (/api/projects/{name}/page, hub_core::page,
// read only then), then that project's rows with every row action board.js has; All rows shows
// every project's rows. The numbers are counted, never judged: every line is hub_core's, word
// for word. Two tables, one at a time, share st.views.projects: this one owns it when nothing is
// open, the rows when a project is.

// page: the opened card's page by project name, {data} or {err}; folds: which of its folds are open;
// viewed: the view pst.data was read under.
// The read is the tab's own (refreshProjects): with something open it reads every card.
const pst = tblTab({
  tab: "projects", id: "projects", el: "p-cards", refresh: () => refreshProjects(),
  shown: () => st.tab === "projects" && !pst.open, wait: "Reading notes projects...", hint: "search, or stage:alpha profile:personal -prio:low",
  state: { open: null, unlinked: false, page: {}, folds: {}, viewed: "" },
  head: (t) => pHead(t.data.table) + (t.data.errors || []).map((e) => `<div class="panel down">${esc(e)}</div>`).join(""),
  body: () => pList(),
});

// With something open, or a deep link on its way, the URL's view is the rows', so every card is
// read: pDeep and the opened card need theirs whatever the list was showing. An answer for what
// is no longer on screen is dropped, and the move that replaced it reads again.
const refreshProjects = coalesce(async () => {
  const arg = st.arg, q = (arg ? new URLSearchParams() : tblParams(st.views.projects)).toString();
  try {
    const got = await api("/api/projects" + (q ? "?" + q : ""));
    if (arg === st.arg) { pst.data = got; pst.err = null; pst.viewed = q; }
  } catch (e) { if (arg === st.arg) pst.err = e.message; }
  if (st.tab === "projects") { pDeep(); renderProjects(); }
});

const pKey = (c) => c.profile + "/" + c.name;

// One running item: its title (two lines at most), then its phases and estimate.
function pRunning(r) {
  const meta = [esc(phasesText(r)), etaText(r.phases)].filter(Boolean).join(", ");
  return `<li><span class="prt">${esc(r.title)}</span>${meta ? `<span class="prm">${meta}</span>` : ""}</li>`;
}

// The opened card's top: its name and chips, profile and prio, then the open version's progress
// (hub_core's summary word for word under the meter).
const pTop = (c, chips) => cardHead(c.name, chips.filter(Boolean)) +
  cardLine([esc(c.profile)].concat(c.prio ? [`prio ${esc(c.prio)}`] : [])) +
  `<div class="pprog">${meter((c.percent || 0) / 100)}<span class="ppct">${Math.round(c.percent || 0)}%</span></div>` +
  `<div class="psum">${esc(c.summary)}</div>`;

const P_COLS = { project: ["project"], profile: ["profile"], stage: ["stage"], version: ["version"], prio: ["prio"], open: ["open", "n"], doing: ["doing", "n"], hot: ["hot", "n"], done: ["done", "n"], "7d": ["7d", "n"], pct: ["pct", "n"], pace: ["pace/wk", "n"], eta: ["eta", "n"], run: ["run", "n"], wait: ["wait", "n"], queued: ["queued", "n"], held: ["held", "n"], today: ["today", "n"], oldest: ["oldest", "n"] };
const pDash = (v) => esc(v == null || v === "" ? "-" : v);

// One line of the list; a click or Enter on it opens the project.
const pLine = (c) => `<tr class="jr" tabindex="0" data-open="${esc(pKey(c))}"><td>${esc(c.name)}</td><td>${esc(c.profile)}</td>` +
  `<td>${pDash(c.stage)}</td><td>${pDash(c.version)}</td><td>${pDash(c.prio)}</td>` +
  `<td class="n">${c.progress.open}</td><td class="n">${c.doing}</td><td class="n${c.hot ? " warn" : ""}">${c.hot}</td>` +
  `<td class="n">${c.progress.done}</td><td class="n">${c.progress.closed_7d}</td>` +
  `<td class="n">${c.percent == null ? "-" : c.percent + "%"}</td><td class="n">${c.pace.toFixed(1)}</td>` +
  `<td class="n">${c.eta_days == null ? "-" : c.eta_days + "d"}</td><td class="n">${c.running.length}</td>` +
  `<td class="n">${c.waiting}</td><td class="n">${c.queued}</td><td class="n">${c.held}</td>` +
  `<td class="n">${c.done_today}</td><td class="n">${pDash(c.oldest)}</td></tr>`;

// A fold of the opened card: its title and what it holds, kept open across redraws by pst.folds.
const pFold = (k, title, says, inner) =>
  cfold(`pg:${k}`, `<b>${esc(title)}</b> <span class="muted">${esc(says)}</span>`, `<div class="card pcard">${inner}</div>`, pst.folds);
const pLines = (lines, cls) => lines.map((l) => `<div${cls ? ` class="${cls}"` : ""}>${esc(l)}</div>`).join("");

// The opened card, over its rows: the card, its goal and Flow, what needs the human (always
// shown), then Build by system, Next stage, Shipped, In flight and the Agent note as folds whose
// heads carry their counts, the TUI's opened card word for word.
function pOpened(c) {
  let html = `<div class="card qitem pcard">` + pTop(c, [cchip("", esc(c.stage || "no stage"))]) +
    `<div class="pgoal">${c.goal ? esc(c.goal) : `<span class="muted">no goal set</span>`}</div>`;
  const got = pst.page[c.name];
  if (!got) return html + `<div class="muted">Reading the page...</div></div>`;
  if (got.err) return html + `<div class="panel down">${esc(got.err)}</div></div>`;
  const pg = got.data;
  if (pg.flow_line) html += `<div class="cline">flow: ${esc(pg.flow_line)}</div>`;
  html += pg.errors.map((e) => `<div class="panel down">${esc(e)}</div>`).join("") + `</div>`;
  html += `<h2 class="sec">Needs you <span class="muted">${pg.needs.length || "nothing"}</span></h2>`;
  if (pg.needs.length) html += `<div class="card">${pLines(pg.needs, "qlate")}</div>`;
  html += pFold("systems", "Build by system", pg.systems_says,
    pg.systems.map((s) => `<div><b>${esc(s.head)}</b></div>` +
      s.epics.map((e) => `<div class="pep${e.behind ? " qlate" : ""}">${esc(e.line)}</div>`).join("") +
      (s.closed ? `<div class="pep muted">${esc(s.closed)}</div>` : "")).join(""));
  html += pFold("next", "Next stage", pg.next_says,
    pg.next_rows.map((r) => `<div${r.result === "FAIL" ? ` class="qlate"` : ""}><b>${esc(r.result)}</b> ${esc(r.requirement)} <span class="muted">(${esc(r.stage)})</span></div>`).join(""));
  html += pFold("shipped", "Shipped", pg.shipped_says, pLines(pg.shipped));
  html += pFold("flight", "In flight", c.counts,
    c.running.length ? `<ul class="prun">${c.running.map(pRunning).join("")}</ul>` : `<div class="muted">nothing running</div>`);
  html += pFold("note", "Agent note", c.note_says,
    c.status ? `<div class="pstat">${esc(c.status)}</div>` : "");
  return html;
}

// Read the opened card's page, once per open (it runs fleet-bench and the stage check).
async function pReadPage(name) {
  try { pst.page[name] = { data: await api(`/api/projects/${encodeURIComponent(name)}/page`) }; }
  catch (e) { pst.page[name] = { err: e.message }; }
  if (st.tab === "projects" && pst.open) renderProjects();
}

// The list's head: how many the view keeps and how many fly, what progress counts, and the way
// to every project's rows.
function pHead(t) {
  const flying = t.states.find((c) => c.name === "in flight").n;
  const open = bst.feed ? bst.feed.table.total : null;
  return `<div class="muted qstats">${t.shown === t.total ? t.total : `${t.shown} of ${t.total}`} projects, ${flying} in flight; ` +
    `progress is the open version's rows by size (#size/s 1, m 3, l 8) ` +
    `<button class="btn sm" data-open="all">${open == null ? "All rows" : `All rows ${open}`}</button></div>`;
}

// The list, then what no card claims.
function pList() {
  const d = pst.data, t = d.table;
  let html = d.cards.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, P_COLS)}${d.cards.map(pLine).join("")}</table></div>`
    : `<div class="card muted">${t.total ? "No project matches." : "No projects."}</div>`;
  if (d.unlinked && d.unlinked.length) {
    html += `<details data-k="unlinked"${pst.unlinked ? " open" : ""}><summary><h2 class="sec">Not on a card ` +
      `<span class="muted">${d.unlinked.length} active queue items no project claims</span></h2></summary>` +
      `<div class="card">${d.unlinked.map((u) => `<div>${esc(u)}</div>`).join("")}</div></details>`;
  }
  return html;
}

// `#projects/<name>` (a `#p:<name>` link on Daily) or `#projects/<profile>/<name>` opens that
// project's rows, once the cards say which project the name is; `#projects/all` opens All.
function pDeep() {
  const want = st.arg;
  if (!want) return;
  if (want === "all") { if (pst.open !== "all") pOpen("all"); return; }
  const c = pst.data && pst.data.cards.find((x) => pKey(x) === want || x.name === want);
  if (c && pst.open !== pKey(c)) pOpen(pKey(c));
}

// The rows view: the card (or the All heading) on top, then board.js's rows and controls. The
// rows are read for this project, under the view already in the URL.
function pOpen(key) {
  pst.open = key;
  if (key !== "all") {
    bst.draft.key = key;
    const c = pst.data && pst.data.cards.find((x) => pKey(x) === key);
    if (c) { delete pst.page[c.name]; pReadPage(c.name); }
  }
  bst.feed = null; bst.sel = null; bst.form = null; bst.msg = ""; bst.all = false; bst.controlsKey = "";
  $("projects").scrollTop = 0;
  renderProjects();
  refreshBoard();
}

// A click moves the tab: the URL names what is open and the old view's query goes with it, and
// so do cards read under it. A deep link is the other way in, and keeps its own (pDeep).
function pGo(key) {
  st.arg = key === null ? "" : key;
  setQuery("");
  if (key === null) {
    pst.open = null; bst.feed = null;
    if (pst.viewed) pst.data = null;
    renderProjects(); refreshProjects(); refreshBoard();
  } else pOpen(key);
}

function renderProjects() {
  const cardsEl = $("p-cards"), rowsEl = $("p-rows");
  cardsEl.hidden = !!pst.open;
  rowsEl.hidden = !pst.open;
  if (!pst.open) { pst.render(); return; }
  const c = pst.open !== "all" && pst.data && pst.data.cards.find((x) => pKey(x) === pst.open);
  paint($("p-head"), `<div class="opts"><button class="btn sm" id="p-back">Back to projects</button></div>` +
    (c ? pOpened(c) : `<h2 class="sec">All projects</h2>`), pst.folds);
  renderBoard();
}

$("projects").addEventListener("click", (e) => {
  if (e.target.id === "p-back") { pGo(null); return; }
  const o = e.target.closest("[data-open]");
  if (o && !e.target.closest("#board")) pGo(o.dataset.open);
});
$("p-cards").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && e.target.matches?.("tr[data-open]")) pGo(e.target.dataset.open);
});
$("projects").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k === "unlinked") pst.unlinked = e.target.open;
}, true);

TABS.projects = {
  // Back on the tab, what was open stays open and the URL names it again.
  show() { if (pst.open && !st.arg) st.arg = pst.open; pDeep(); renderProjects(); refreshProjects(); refreshBoard(); },
  onEvent(ev) {
    if (st.tab !== "projects") return;
    if (["watch", "queue", "resync"].includes(ev.kind)) refreshProjects();
    if (ev.kind === "resync") refreshBoard();
  },
};
