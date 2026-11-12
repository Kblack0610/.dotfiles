"use strict";
// The Projects tab: one table row per lab project on the shared table (/api/projects applies
// the view, hub_core::projects, the rows the hub TUI's Projects tab draws) with its open
// version's progress by size, its pace and ETA, and its queue, in flight first. A click opens
// the project: its header, then its page (/api/projects/{name}/page, hub_core::page, read only
// then) as inner tabs (PROJECT_PAGE, `#projects/<profile>/<name>/<inner>`): Overview, its Rows
// with every row action board.js has, Build (Deliverables scoped to it), Stage and Activity.
// Its inner tabs (INNER_TABS.projects) are this list, All rows (every project's rows, board.js
// scoped to all) and Deliverables, each read only while it shows; an opened project's page sits
// under the list's. The numbers are counted, never judged: every line is hub_core's, word for
// word. The list and the rows (All rows, or an opened project's) share st.views.projects, one at
// a time, so a move between them leaves the view behind.

// page: the opened card's page by project name, {data} or {err}; folds: which of its folds are open;
// viewed: the view pst.data was read under; inner: the opened page's inner tab (PROJECT_PAGE).
// The read is the tab's own (refreshProjects): with something open it reads every card.
const pst = tblTab({
  tab: "projects", id: "projects", el: "p-cards", refresh: () => refreshProjects(),
  shown: () => st.tab === "projects" && !pst.open && pTab() === "list", wait: "Reading notes projects...", hint: "search, or stage:alpha profile:personal -prio:low",
  state: { open: null, inner: "overview", unlinked: true, page: {}, folds: {}, viewed: "" },
  head: (t) => `<h2 class="sec" id="sec-cards">Projects</h2>` + pHead(t.data.table) + (t.data.errors || []).map((e) => `<div class="panel down">${esc(e)}</div>`).join(""),
  body: () => pList(),
});

// Deliverables: one row per open feature epic across every project (/api/deliverables,
// hub_core::deliverables, the rows and words the hub TUI draws), the Deliverables inner tab, and an
// opened project's Build inner tab (`scope`), the element moved there (dMount). Its view keys are
// d-prefixed (dq, ds, dsort, ddir) because the list and the rows keep the plain ones. On the list
// a row opens its project's Build at that epic; on Build it opens the epic's rows (pOpenAt).
const D_COLS = { project: ["project"], epic: ["epic"], sys: ["sys"], done: ["done", "n"], eta: ["eta", "n"], track: ["track"] };
const dst = tblTab({
  tab: "projects", id: "p-del", el: "p-deliv", pre: "d", api: "/api/deliverables", hint: "search, or sys:ui track:behind -project:x",
  shown: () => dShown(), wait: "Reading fleet-bench epics (about 10s when cold)...",
  params: (p) => { if (pst.open) p.set("scope", pst.open); },
  got: (t) => { if (!new URLSearchParams(t.q).has("scope")) pCountSet("deliverables", t.data?.table?.total); },
  draw: (html) => paint($("p-deliv"), `<div data-tbl="d">${html}</div>`),
  head: (t) => (pst.open ? pSec("p-build", "Build", t.data.says) : `<h2 class="sec" id="sec-deliverables">${esc(t.data.says)}</h2>`),
  body: (t) => dBody(t.data),
});

// Deliverables shows on its inner tab, and on an opened project's Build.
const dShown = () => st.tab === "projects" && (pst.open ? pst.inner === "build" : pTab() === "deliverables");

const dLine = (r) => `<tr class="jr" tabindex="0" data-open="${esc(r.profile + "/" + r.project)}" data-epic="${esc(r.id)}" data-sys="${esc(r.system)}">` +
  `<td>${esc(r.project)}</td><td class="wrap" title="${esc(r.id)}">${esc(r.title)}</td><td>${pDash(r.system)}</td>` +
  `<td class="n" title="${r.done} of ${r.total} rows done; the percent is by size">${esc(r.done_says)}</td>` +
  `<td class="n">${pDash(r.eta_day)}</td><td${r.track === "behind" ? ` class="warn"` : ""}>${pDash(r.track)}</td></tr>`;

// The rows (or why there are none), then the coverage line.
function dBody(d) {
  const t = d.table;
  return (d.rows.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, D_COLS)}${d.rows.map(dLine).join("")}</table></div>`
    : `<div class="card muted">${t.total ? "No deliverable matches." : "No open feature epics."}</div>`) +
    `<div class="muted qstats">${esc(d.coverage_says)}; ${esc(d.legend)}</div>`;
}

// With something open, or a deep link on its way, the URL's view is the rows', so every card is
// read: pDeep and the opened card need theirs whatever the list was showing. An answer for what
// is no longer on screen is dropped (another inner tab of the same project is still it), and the
// move that replaced it reads again.
const refreshProjects = coalesce(async () => {
  const arg = pProj(), q = (arg ? new URLSearchParams() : tblParams(st.views.projects)).toString();
  const same = () => !!arg === !!pProj() && pSplit(arg).key === pSplit(pProj()).key;
  try {
    const got = await api("/api/projects" + (q ? "?" + q : ""));
    if (same()) { pst.data = got; pst.err = null; pst.viewed = q; }
  } catch (e) { if (same()) pst.err = e.message; }
  if (st.tab === "projects") { pDeep(); renderProjects(); }
});

// The inner tab the URL has open: a bare inner id (innerRoute makes a section one); anything else
// is a project's path, on the list's. A project named like an inner tab opens as <profile>/<name>.
const P_TABS = INNER_TABS.projects.tabs.map((t) => t[0]);
const pTab = () => (P_TABS.includes(st.arg) ? st.arg : "list");
const pProj = () => (P_TABS.includes(st.arg) ? "" : st.arg);
// Each inner tab's total, its table's once read: a count, not a flag, so it is never amber.
const pCount = { all: null, deliverables: null };
function pStrip() {
  const tabs = INNER_TABS.projects.tabs.map(([id, title, secs]) =>
    [id, title + (pCount[id] == null ? "" : ` <span class="muted">${pCount[id]}</span>`), secs]);
  return stripHtml(tabs, pTab(), "itab");
}
// The strip's words as last drawn ("" while hidden): it is rebuilt only when a count changes,
// and otherwise flips its marks in place, so a focused button (ArrowRight, an SSE re-read) keeps focus.
let pStripSaid = "";
function pStripPaint() {
  const el = $("p-strip"), said = pst.open ? "" : JSON.stringify(pCount);
  if (said !== pStripSaid) {
    const at = document.activeElement, had = at && el.contains?.(at) && at.dataset?.itab;
    el.innerHTML = said ? pStrip() : "";
    pStripSaid = said;
    if (had) el.querySelector(`[data-itab="${had}"]`)?.focus?.();
  } else stripMark(el, "itab", pTab());
  stripInView(el);
}
// A read's total for inner tab `id`: a number only, and the strip redrawn when it moved.
function pCountSet(id, n) {
  if (typeof n !== "number" || pCount[id] === n) return;
  pCount[id] = n;
  pStripPaint();
}
// Each inner tab's own view (its URL query), kept while another shows, so a filter set on All
// rows is still there after a look at Deliverables. pOn is the inner tab last drawn; pOpenQ the
// opened project's view as last drawn, which closing it drops (pClose).
const pViews = {};
let pOn = "list", pOpenQ = null;

const pKey = (c) => c.profile + "/" + c.name;
// The card `want` names, by `<profile>/<name>` or the name alone.
const pCard = (want) => pst.data && pst.data.cards.find((x) => pKey(x) === want || x.name === want);
const P_INNER = PROJECT_PAGE.map((t) => t[0]);
// Projects' URL arg as the project and its inner tab: `<key>/<inner>` when the last word is an
// inner tab and the whole arg is no project's name, else the arg alone on Overview.
function pSplit(arg) {
  const at = arg.lastIndexOf("/"), tail = arg.slice(at + 1).toLowerCase();
  return at > 0 && P_INNER.includes(tail) && !pCard(arg) ? { key: arg.slice(0, at), inner: tail } : { key: arg, inner: "overview" };
}
// The arg naming what is open: the project, and its inner tab unless that is Overview.
const pArg = () => pst.open + (pst.inner === "overview" ? "" : "/" + pst.inner);
// A section of the opened page: its sec- anchor (the sidebar outline lists it) and head.
const pSec = (id, title, says) => `<h2 class="sec" id="sec-${id}">${esc(title)}${says === "" || says == null ? "" : ` <span class="muted">${esc(says)}</span>`}</h2>`;

// One running item: its title (two lines at most), then its phases and estimate.
function pRunning(r) {
  const meta = [esc(phasesText(r)), etaText(r.phases)].filter(Boolean).join(", ");
  return `<li><span class="prt">${esc(r.title)}</span>${meta ? `<span class="prm">${meta}</span>` : ""}</li>`;
}

// The opened card's top: its name and chips, profile and prio, then the open version's progress
// (hub_core's summary word for word under the meter, every number named).
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

const pLines = (lines, cls) => lines.map((l) => `<div${cls ? ` class="${cls}"` : ""}>${esc(l)}</div>`).join("");
// The Timeline fold: its notes, then one line per event newest first, colored by its level,
// linked to its PR, run or deploy when it has one, then how many older ones the cap left out.
const pTimeline = (t) => pLines(t.notes, "muted") + t.lines.map((l) => {
  const text = /^https?:\/\//.test(l.url || "") ? `<a href="${esc(l.url)}" target="_blank" rel="noopener">${esc(l.line)}</a>` : esc(l.line);
  return `<div class="ptl${l.level === "ok" ? "" : ` ${esc(l.level)}`}">${text}</div>`;
}).join("") + older(t.older);

// The opened project's header: the card, its goal, Flow, releases, checks, alerts and the next stage's
// gate (a link to Stage), then the inner tab strip, the count on Overview being what needs the
// human and on Stage the failing checks.
function pOpened(c) {
  let html = `<div class="card qitem pcard">` + pTop(c, [cchip("", esc(c.stage || "no stage"))]) +
    `<div class="pgoal">${c.goal ? esc(c.goal) : `<span class="muted">no goal set</span>`}</div>`;
  const got = pst.page[c.name], pg = got && got.data;
  if (pg) {
    if (pg.flow_line) html += `<div class="cline">flow: ${esc(pg.flow_line)}</div>`;
    if (pg.releases) html += `<div class="cline">releases: <a class="${pg.releases.level === "ok" ? "" : pg.releases.level}" href="#releases?q=${encodeURIComponent("project:" + c.name)}">${esc(pg.releases.says)}</a></div>`;
    if (pg.checks) html += `<div class="cline">checks: <a class="${pg.checks.level === "ok" ? "" : pg.checks.level}" href="#releases/apps/${encodeURIComponent(c.name)}">${esc(pg.checks.says)}</a></div>`;
    if (pg.alerts) html += `<div class="cline">alerts: <a class="${pg.alerts.level === "ok" ? "" : pg.alerts.level}" href="#alerts?q=${encodeURIComponent("project:" + c.name)}">${esc(pg.alerts.says)}</a></div>`;
    html += `<div class="cline${pg.gate && pg.gate.fail ? " warn" : ""}">next stage: <a href="#" data-pgo="stage">${esc(pg.next_says)}</a></div>`;
    html += pg.errors.map((e) => `<div class="panel down">${esc(e)}</div>`).join("");
  } else if (got && got.err) html += `<div class="panel down">${esc(got.err)}</div>`;
  const counts = pg ? { overview: pNeedCount(pg), stage: pg.gate ? pg.gate.fail : 0 } : {};
  return html + `</div>` + stripHtml(PROJECT_PAGE, pst.inner, "ptab", [], counts);
}

// What needs the human, grouped by kind (hub_core::page::need_groups, the next stage's failing and
// human checks last); a stage group links to Stage. Verify links nowhere: its epics include closed
// ones, which Build (open epics) lacks.
const P_NEED_GO = { stage: { pgo: "stage" } };
const pNeedGroups = (pg) => pg.need_groups.map((g) => ({ ...g, go: P_NEED_GO[g.kind] || null }));
const pNeedCount = (pg) => pNeedGroups(pg).reduce((n, g) => n + g.items.length, 0);
// A link that moves the page to an inner tab.
const pGoLink = (go, text) => `<a href="#" data-pgo="${go.pgo}">${esc(text)}</a>`;
const P_GO_TEXT = { stage: "open Stage" };

// Overview: what needs the human (each kind one shut fold of its items, with the inner tab that
// acts on it), what is in flight, and one table row per system; a system opens Build filtered to it.
function pOverview(c, pg) {
  let html = "";
  if (pg) {
    const groups = pNeedGroups(pg), n = pNeedCount(pg);
    html += pSec("p-needs", "Needs you", n || "nothing");
    if (groups.length) html += `<div class="card">` + groups.map((g) => cfold(`pg:need:${g.kind}`,
      `<b>${esc(g.says)}</b>${g.go ? ` ${pGoLink(g.go, P_GO_TEXT[g.go.pgo])}` : ""}`, pLines(g.items), pst.folds)).join("") + `</div>`;
  }
  html += pSec("p-flight", "In flight", c.counts) +
    `<div class="card">${c.running.length ? `<ul class="prun">${c.running.map(pRunning).join("")}</ul>` : `<div class="muted">nothing running</div>`}` +
    `<div class="cline"><a href="#queue?q=${encodeURIComponent("project:" + c.name)}">this project's queue</a></div></div>`;
  if (pg) html += pSec("p-systems", "Systems", pg.systems_says) + pSysTable(pg.systems);
  return html;
}
const P_SYS_HEAD = ["system", "done", "features", "standard", "open rows", "behind", "criteria", "current wave"];
// One row per system: its percent, features done of counted, open standard epics, open rows,
// epics behind, criteria met and its current wave.
function pSysTable(systems) {
  if (!systems.length) return `<div class="card muted">No systems.</div>`;
  const row = (s) => `<tr class="jr"${s.id ? ` tabindex="0" data-psys="${esc(s.id)}"` : ""}><td>${esc(s.id || "no system")}</td>` +
    `<td class="n">${s.percent == null ? "-" : s.percent + "%"}</td><td class="n">${s.features ? `${s.features_done} of ${s.features}` : "-"}</td>` +
    `<td class="n">${s.standing || "-"}</td><td class="n">${s.open_rows || "-"}</td><td class="n${s.behind ? " warn" : ""}">${s.behind || "-"}</td>` +
    `<td class="n">${s.criteria_total == null ? "-" : `${s.criteria_met} of ${s.criteria_total}`}</td>` +
    `<td class="wrap">${s.wave ? esc(s.wave.title) + (s.wave.percent == null ? "" : ` ${s.wave.percent}%`) + (s.wave.more ? ` <span class="muted">+${s.wave.more}</span>` : "") : "-"}</td></tr>`;
  return `<div class="panel scroll"><table class="tbl"><tr>${P_SYS_HEAD.map((h, i) => `<th${i && i < 7 ? ` class="n"` : ""}>${h}</th>`).join("")}</tr>${systems.map(row).join("")}</table></div>`;
}

// Stage: the next stage's requirements not met, failing first, then a human's, then the rest.
const P_RESULT = { FAIL: 0, HUMAN: 1 };
function pStage(pg) {
  const rows = [...pg.next_rows].sort((a, b) => (P_RESULT[a.result] ?? 2) - (P_RESULT[b.result] ?? 2));
  return pSec("p-stage", "Next stage", pg.next_says) + (rows.length
    ? `<div class="card">${rows.map((r) => `<div${r.result === "FAIL" ? ` class="qlate"` : ""}><b>${esc(r.result)}</b> ${esc(r.requirement)} <span class="muted">(${esc(r.stage)})</span></div>`).join("")}</div>`
    : "");
}

// Activity: shipped versions, the dev timeline and the agent's status note.
function pActivity(c, pg) {
  let html = "";
  if (pg) {
    html += pSec("p-shipped", "Shipped", pg.shipped_says) + (pg.shipped.length ? `<div class="card">${pLines(pg.shipped)}</div>` : "");
    if (pg.timeline) html += pSec("p-timeline", "Timeline", pg.timeline.says) + `<div class="card">${pTimeline(pg.timeline)}</div>`;
  }
  return html + pSec("p-note", "Agent note", c.note_says) + (c.status ? `<div class="card"><div class="pstat">${esc(c.status)}</div></div>` : "");
}

// The inner tabs' own panes, each in its data-pin group, around the board's (Rows) and
// Deliverables' (Build) elements so the outline lists them in the strip's order: `p-pane` holds
// Overview and the Rows head, `p-pane2` Stage and Activity. One that needs the page says it is
// reading or why it failed.
function pPanes(c) {
  const got = pst.page[c.name], pg = got && got.data;
  // A failed read is the header's to say, once.
  const wait = got && got.err ? "" : `<div class="muted">Reading the page...</div>`;
  const pin = (id, html) => `<div data-pin="${id}"${pst.inner === id ? "" : " hidden"}>${html}</div>`;
  return [pin("overview", pOverview(c, pg) + (pg ? "" : wait)) +
    pin("rows", pSec("p-rows", "Rows", `${c.progress.open} open; select one for its actions`)),
  pin("stage", pg ? pStage(pg) : wait) + pin("activity", pActivity(c, pg) + (pg ? "" : wait))];
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

// `#projects/<name>` (a `#p:<name>` link on Daily) or `#projects/<profile>/<name>`, with an
// inner tab after it or not, opens that project's page, once the cards say which project it is.
function pDeep() {
  if (!pProj()) return;
  const { key, inner } = pSplit(pProj()), c = pCard(key);
  if (!c) return;
  if (pst.open !== pKey(c)) pOpen(pKey(c), inner);
  else if (pst.inner !== inner) pInner(inner);
}

// The opened page: the card and strip on top, then the inner tab's pane. The rows are read for
// this project, under the view already in the URL, and Build for it when it shows.
function pOpen(key, inner) {
  pst.open = key;
  pst.inner = inner || "overview";
  bst.draft.key = key;
  const c = pCard(key);
  if (c) { delete pst.page[c.name]; pReadPage(c.name); }
  bst.feed = null; bst.sel = null; bst.form = null; bst.msg = ""; bst.all = false; bst.controlsKey = "";
  dst.data = null;
  paint($("p-deliv"), "");
  $("projects").scrollTop = 0;
  renderProjects();
  refreshBoard();
  if (pst.inner === "build") dst.refresh();
}

// Show inner tab `id` of the opened page in place: the URL follows (no history entry, as a tab
// button), the panes flip without a repaint, and Build reads its rows for this project.
function pInner(id) {
  pst.inner = P_INNER.includes(id) ? id : "overview";
  st.arg = lastInner.projects = pArg();
  showUrl();
  pShow();
  if (pst.inner === "build") dst.refresh();
  if (pst.inner === "rows") renderBoard();
}
function pShow() {
  for (const e of $("p-rows").querySelectorAll("[data-pin]")) e.hidden = e.dataset.pin !== pst.inner;
  stripMark($("p-head"), "ptab", pst.inner);
}

// A click moves the tab: the URL names what is open and the old view's query goes with it, and
// so do cards read under it. A deep link is the other way in, and keeps its own (pDeep).
function pGo(key, inner, query) {
  st.arg = lastInner.projects = key === null ? "" : key + (inner && inner !== "overview" ? "/" + inner : "");
  setQuery(query || "");
  if (key === null) {
    pClose();
    renderProjects(); pRead();
  } else pOpen(key, inner);
}
// Back to the inner tabs: the opened project's rows and Build go, and cards read under its view,
// and so does its view: a query still the project's is cleared, as Back clears it (pGo(null));
// a link that brought its own (`#board?q=...`) keeps that.
function pClose() {
  if (pst.open && st.views.projects && st.views.projects === pOpenQ) setQuery("");
  pst.open = null; pOpenQ = null; bst.feed = null; dst.data = null;
  if (pst.viewed) pst.data = null;
}
// Read what shows: the list (or an opened project's card), the rows, Deliverables.
function pRead() {
  const top = pTab();
  if (top === "list") refreshProjects();
  if (top === "all" || pst.open) refreshBoard();
  if (dShown()) dst.refresh();
}

// Deliverables is its own inner tab, and the opened page's Build pane.
function dMount() {
  const d = $("p-deliv"), home = pst.open ? $("p-build") : $("p-dtop");
  if (d.parentNode !== home) home.appendChild(d);
}

// The strip, then the inner tab that shows; an opened project's page replaces all of it.
function renderProjects() {
  dMount();
  bMount(pst.open ? "p-board" : "p-all");
  pStripPaint();
  innerHide("projects", "cards", $("p-cards"));
  innerHide("projects", "board", $("p-all"));
  innerHide("projects", "deliverables", $("p-dtop"));
  $("p-rows").hidden = !pst.open;
  if (!pst.open) {
    const top = pOn = pTab();
    if (top === "all") renderBoard();
    if (top === "list") pst.render(); else if (top === "deliverables") dst.render();
    return;
  }
  $("p-cards").hidden = true;
  pOpenQ = st.views.projects || "";
  const c = pCard(pst.open);
  paint($("p-head"), `<div class="opts"><button class="btn sm" id="p-back">Back to projects</button></div>` +
    (c ? pOpened(c) : ""), pst.folds);
  const [top, rest] = c ? pPanes(c) : ["", ""];
  paint($("p-pane"), top, pst.folds);
  paint($("p-pane2"), rest, pst.folds);
  pShow();
  renderBoard();
  dst.render();
}

$("projects").addEventListener("click", (e) => {
  if (e.target.id === "p-back") { pGo(null); return; }
  const tab = e.target.closest("[data-ptab]");
  if (tab) { pInner(tab.dataset.ptab); return; }
  const go = e.target.closest("[data-pgo]");
  if (go) {
    e.preventDefault();
    pInner(go.dataset.pgo);
    return;
  }
  const sys = e.target.closest("[data-psys]");
  if (sys) { pSys(sys.dataset.psys); return; }
  const o = e.target.closest("[data-open]");
  if (o && !e.target.closest("#b-root")) pOpenAt(o);
});
// A system row: Build, filtered to that system's epics.
function pSys(id) {
  setQuery(tblSet(st.views.projects, { q: "sys:" + id, s: "" }, "d"));
  pInner("build");
}
// On the list a row's project opens, a deliverable's at Build searched to its epic. On a
// project's Build an epic's row opens Rows filtered to that epic's rows (tag of/<epic>).
function pOpenAt(o) {
  const epic = o.dataset.epic;
  if (pst.open && epic) {
    setQuery(tblSet(st.views.projects, { q: "tag:=of/" + epic }));
    pInner("rows");
    refreshBoard();
    return;
  }
  pGo(o.dataset.open, epic ? "build" : "overview", epic ? tblSet("", { q: epic }, "d") : "");
}
for (const id of ["p-deliv", "p-cards", "p-pane"]) $(id).addEventListener("keydown", (e) => {
  if (e.key !== "Enter") return;
  if (e.target.matches?.("tr[data-open]")) pOpenAt(e.target);
  else if (e.target.matches?.("tr[data-psys]")) pSys(e.target.dataset.psys);
});
$("projects").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k === "unlinked") pst.unlinked = e.target.open;
}, true);

TABS.projects = {
  // Back on the tab, what was open stays open and the URL names it again; a link to All rows or
  // Deliverables (`#board`) leaves it.
  show() {
    if (pst.open && P_TABS.includes(st.arg)) pClose();
    if (pst.open && !st.arg) st.arg = pArg();
    pDeep(); renderProjects(); pRead();
  },
  // A strip click: the view stays with the inner tab it was set on, the one now showing gets its
  // own back, and only that one reads.
  inner(id) {
    if (pst.open) pClose();
    pViews[pOn] = st.views.projects || "";
    setQuery(pViews[id] || "");
    renderProjects(); pRead();
  },
  // A section on another inner tab of the opened page (an outline click) shows that tab first.
  pin: (id) => { if (pst.open) pInner(id); },
  onEvent(ev) {
    if (st.tab !== "projects") return;
    if (["watch", "queue", "resync"].includes(ev.kind)) {
      if (pTab() === "list") refreshProjects();
      if (dShown()) dst.refresh();
    }
    if (ev.kind === "resync") refreshBoard();
  },
};
