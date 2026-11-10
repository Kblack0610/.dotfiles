"use strict";
// The Projects tab: one table row per lab project on the shared table (/api/projects applies
// the view, hub_core::projects, the rows the hub TUI's Projects tab draws) with its open
// version's progress by size, its pace and ETA, and its queue, in flight first. A click opens
// the project: its card, the opened record, its page (/api/projects/{name}/page, hub_core::page,
// read only then), then that project's rows with every row action board.js has; every project's
// rows are the Board tab. The numbers are counted, never judged: every line is hub_core's, word
// for word. Two tables, one at a time, share st.views.projects: this one owns it when nothing is
// open, the rows when a project is.

// page: the opened card's page by project name, {data} or {err}; folds: which of its folds are open;
// viewed: the view pst.data was read under; leaf: the task a click asked for, {id, feed}, until a
// newer read than feed answers it (pLeaf).
// The read is the tab's own (refreshProjects): with something open it reads every card.
const pst = tblTab({
  tab: "projects", id: "projects", el: "p-cards", refresh: () => refreshProjects(),
  shown: () => st.tab === "projects" && !pst.open, wait: "Reading notes projects...", hint: "search, or stage:alpha profile:personal -prio:low",
  state: { open: null, unlinked: false, page: {}, folds: {}, viewed: "", leaf: null },
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
// The Timeline fold: its notes, then one line per event newest first, colored by its level,
// linked to its PR, run or deploy when it has one, then how many older ones the cap left out.
const pTimeline = (t) => pLines(t.notes, "muted") + t.lines.map((l) => {
  const text = /^https?:\/\//.test(l.url || "") ? `<a href="${esc(l.url)}" target="_blank" rel="noopener">${esc(l.line)}</a>` : esc(l.line);
  return `<div class="ptl${l.level === "ok" ? "" : ` ${esc(l.level)}`}">${text}</div>`;
}).join("") + older(t.older);

// Build by system, always shown: one fold per system with an epic, its head carrying its percent,
// each epic a fold of its own over its tasks. An open task is a link that opens its row below
// (pLeaf); a done one is only a line.
const pLeafLine = (l) => l.done ? `<div class="pleaf muted">${esc(l.line)}</div>`
  : `<div class="pleaf"><a href="#" data-leaf="${esc(l.id)}">${esc(l.line)}</a></div>`;
const pSystems = (pg) => `<h2 class="sec">Build by system <span class="muted">${esc(pg.systems_says)}</span></h2>` +
  `<div class="card pcard">${pg.systems.map((s) => {
    const head = `<b>${esc(s.head)}</b>`;
    if (!s.epics.length && !s.closed) return `<div class="psys">${head}</div>`;
    return cfold(`pg:sys:${s.id}`, head, s.epics.map((e) =>
      cfold(`pg:ep:${e.id}`, `<span class="pep${e.behind ? " qlate" : ""}">${esc(e.line)}</span>`,
        e.leaves.length ? e.leaves.map(pLeafLine).join("") : `<div class="pleaf muted">no tasks yet</div>`, pst.folds)).join("") +
      (s.closed ? `<div class="pep muted">${esc(s.closed)}</div>` : ""), pst.folds);
  }).join("")}</div>`;

// The opened card, over its rows: the card, its goal and Flow, Build by system and what needs the
// human (both always shown), then Next stage, Shipped, Timeline, In flight and the Agent note as
// folds whose heads carry their counts, the TUI's opened card word for word.
function pOpened(c) {
  let html = `<div class="card qitem pcard">` + pTop(c, [cchip("", esc(c.stage || "no stage"))]) +
    `<div class="pgoal">${c.goal ? esc(c.goal) : `<span class="muted">no goal set</span>`}</div>`;
  const got = pst.page[c.name];
  if (!got) return html + `<div class="muted">Reading the page...</div></div>`;
  if (got.err) return html + `<div class="panel down">${esc(got.err)}</div></div>`;
  const pg = got.data;
  if (pg.flow_line) html += `<div class="cline">flow: ${esc(pg.flow_line)}</div>`;
  if (pg.releases) html += `<div class="cline">releases: <a class="${pg.releases.level === "ok" ? "" : pg.releases.level}" href="#releases?q=${encodeURIComponent("project:" + c.name)}">${esc(pg.releases.says)}</a></div>`;
  html += pg.errors.map((e) => `<div class="panel down">${esc(e)}</div>`).join("") + `</div>`;
  html += pSystems(pg);
  html += `<h2 class="sec">Needs you <span class="muted">${pg.needs.length || "nothing"}</span></h2>`;
  if (pg.needs.length) html += `<div class="card">${pLines(pg.needs, "qlate")}</div>`;
  html += pFold("next", "Next stage", pg.next_says,
    pg.next_rows.map((r) => `<div${r.result === "FAIL" ? ` class="qlate"` : ""}><b>${esc(r.result)}</b> ${esc(r.requirement)} <span class="muted">(${esc(r.stage)})</span></div>`).join(""));
  html += pFold("shipped", "Shipped", pg.shipped_says, pLines(pg.shipped));
  if (pg.timeline) html += pFold("timeline", "Timeline", pg.timeline.says, pTimeline(pg.timeline));
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

// The list's head: how many the view keeps and how many fly, and what progress counts.
function pHead(t) {
  const flying = t.states.find((c) => c.name === "in flight").n;
  return `<div class="muted qstats">${t.shown === t.total ? t.total : `${t.shown} of ${t.total}`} projects, ${flying} in flight; ` +
    `progress is the open version's rows by size (#size/s 1, m 3, l 8)</div>`;
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
// project's rows, once the cards say which project the name is.
function pDeep() {
  const want = st.arg;
  if (!want) return;
  const c = pst.data && pst.data.cards.find((x) => pKey(x) === want || x.name === want);
  if (c && pst.open !== pKey(c)) pOpen(pKey(c));
}

// The rows view: the card on top, then board.js's rows and controls. The rows are read for this
// project, under the view already in the URL.
function pOpen(key) {
  pst.open = key;
  bst.draft.key = key;
  const c = pst.data && pst.data.cards.find((x) => pKey(x) === key);
  if (c) { delete pst.page[c.name]; pReadPage(c.name); }
  bst.feed = null; bst.sel = null; bst.form = null; bst.msg = ""; bst.all = false; bst.controlsKey = "";
  pst.leaf = null;
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
    pst.open = null; bst.feed = null; pst.leaf = null;
    if (pst.viewed) pst.data = null;
    renderProjects(); refreshProjects(); refreshBoard();
  } else pOpen(key);
}

function renderProjects() {
  const cardsEl = $("p-cards"), rowsEl = $("p-rows");
  cardsEl.hidden = !!pst.open;
  rowsEl.hidden = !pst.open;
  if (!pst.open) { pst.render(); return; }
  const c = pst.data && pst.data.cards.find((x) => pKey(x) === pst.open);
  if (pst.leaf && bst.feed && bst.feed !== pst.leaf.feed) {
    // Only the read that has the row answers: one already in flight when the click came may not.
    const r = bst.feed.rows.find((x) => x.id === pst.leaf.id);
    if (r) { bst.sel = bSel(r); pst.leaf = null; }
  }
  paint($("p-head"), `<div class="opts"><button class="btn sm" id="p-back">Back to projects</button></div>` +
    (c ? pOpened(c) : ""), pst.folds);
  renderBoard();
}

// A task under an epic: the rows filter to its id, and the read that answers opens its row.
function pLeaf(id) {
  pst.leaf = { id, feed: bst.feed };
  setQuery(tblSet(st.views.projects, { q: "id:" + id }));
  refreshBoard();
}

$("projects").addEventListener("click", (e) => {
  if (e.target.id === "p-back") { pGo(null); return; }
  const leaf = e.target.closest("[data-leaf]");
  if (leaf) { e.preventDefault(); pLeaf(leaf.dataset.leaf); return; }
  const o = e.target.closest("[data-open]");
  if (o && !e.target.closest("#b-root")) pGo(o.dataset.open);
});
$("p-cards").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && e.target.matches?.("tr[data-open]")) pGo(e.target.dataset.open);
});
$("projects").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k === "unlinked") pst.unlinked = e.target.open;
}, true);

TABS.projects = {
  // Back on the tab, what was open stays open and the URL names it again.
  show() { bMount("p-rows"); if (pst.open && !st.arg) st.arg = pst.open; pDeep(); renderProjects(); refreshProjects(); refreshBoard(); },
  onEvent(ev) {
    if (st.tab !== "projects") return;
    if (["watch", "queue", "resync"].includes(ev.kind)) refreshProjects();
    if (ev.kind === "resync") refreshBoard();
  },
};
