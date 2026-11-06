"use strict";
// The Projects tab: one card per lab project (/api/projects, hub_core::projects, the cards the
// hub TUI's Projects tab draws) with its open version's progress by size, its pace and ETA, and
// its queue, in flight first. "Open rows" opens the card: its page (/api/projects/{name}/page,
// hub_core::page, read only then), then that project's rows with every row action board.js has;
// "All projects" shows every project's rows. The numbers are counted, never judged: every line
// is hub_core's, word for word.

// page: the opened card's page by project name, {data} or {err}; folds: which of its folds are open.
const pst = { data: null, err: null, open: null, unlinked: false, page: {}, folds: {} };

const refreshProjects = coalesce(async () => {
  try { pst.data = await api("/api/projects"); pst.err = null; } catch (e) { pst.err = e.message; }
  if (st.tab === "projects") { pDeep(); renderProjects(); }
});

const pKey = (c) => c.profile + "/" + c.name;

// One running item: its title (two lines at most), then its phases and estimate.
function pRunning(r) {
  const meta = [esc(phasesText(r)), etaText(r.phases)].filter(Boolean).join(", ");
  return `<li><span class="prt">${esc(r.title)}</span>${meta ? `<span class="prm">${meta}</span>` : ""}</li>`;
}

// A count chip, only when there is something to count.
const pCount = (n, what, cls) => (n ? cchip(cls || "", `${n} ${what}`) : "");

// A card's top, in the list and opened: its name and chips, profile and prio, then the open
// version's progress (hub_core's summary word for word under the meter).
const pTop = (c, chips) => cardHead(c.name, chips.filter(Boolean)) +
  cardLine([esc(c.profile)].concat(c.prio ? [`prio ${esc(c.prio)}`] : [])) +
  `<div class="pprog">${meter((c.percent || 0) / 100)}<span class="ppct">${Math.round(c.percent || 0)}%</span></div>` +
  `<div class="psum">${esc(c.summary)}</div>`;

// A project card in the list: its stage and queue over the top. The rest is the opened card's
// (pOpened).
function pCard(c) {
  const chips = [cchip("", esc(c.stage || "no stage")), pCount(c.running.length, "running", "running"),
    pCount(c.waiting, "waiting", "waiting"), pCount(c.queued, "queued")];
  return `<div class="card qitem pcard" data-open="${esc(pKey(c))}">` + pTop(c, chips) +
    `<div class="opts"><button class="btn sm" data-open="${esc(pKey(c))}">Open rows</button></div>` +
    `</div>`;
}

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

function pCards() {
  const d = pst.data, cards = d.cards;
  const flying = cards.filter((c) => c.in_flight).length;
  const open = bst.feed ? bst.feed.rows.filter((r) => r.state !== "done").length : null;
  let html = `<div class="muted qstats">${cards.length} projects, ${flying} in flight; ` +
    `progress is the open version's rows by size (#size/s 1, m 3, l 8)</div>`;
  html += (d.errors || []).map((e) => `<div class="panel down">${esc(e)}</div>`).join("");
  html += `<div class="card qitem pcard" data-open="all">` +
    cardHead("All projects", [cchip("", open == null ? "reading notes board" : `${open} open rows`)]) +
    cardLine(["every project's rows, filtered by text, #tag, lane or priority"]) +
    `<div class="opts"><button class="btn sm" data-open="all">Open rows</button></div></div>`;
  html += cards.map(pCard).join("");
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

// The rows view: the card (or the All heading) on top, then board.js's rows and controls.
function pOpen(key) {
  pst.open = key;
  const all = key === "all";
  bst.filter.project = all ? "" : key;
  bst.filter.q = "";
  if (!all) {
    bst.draft.key = key;
    const c = pst.data && pst.data.cards.find((x) => pKey(x) === key);
    if (c) { delete pst.page[c.name]; pReadPage(c.name); }
  }
  bst.form = null; bst.msg = ""; bst.controlsKey = "";
  $("projects").scrollTop = 0;
  renderProjects();
}

function renderProjects() {
  const cardsEl = $("p-cards"), rowsEl = $("p-rows");
  cardsEl.hidden = !!pst.open;
  rowsEl.hidden = !pst.open;
  if (!pst.open) {
    if (!pst.data) { cardsEl.innerHTML = `<div class="empty">${pst.err ? esc(pst.err) : "Reading notes projects..."}</div>`; return; }
    paint(cardsEl, pCards());
    return;
  }
  const c = pst.open !== "all" && pst.data && pst.data.cards.find((x) => pKey(x) === pst.open);
  paint($("p-head"), `<div class="opts"><button class="btn sm" id="p-back">Back to projects</button></div>` +
    (c ? pOpened(c) : `<h2 class="sec">All projects</h2>`), pst.folds);
  renderBoard();
}

$("projects").addEventListener("click", (e) => {
  if (e.target.id === "p-back") {
    pst.open = null;
    if (st.arg) { st.arg = ""; try { history.replaceState(null, "", "#projects"); } catch (err) { /* not fatal */ } }
    renderProjects(); refreshProjects(); return;
  }
  const o = e.target.closest("[data-open]");
  if (o && !e.target.closest("#board")) pOpen(o.dataset.open);
});
$("projects").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k === "unlinked") pst.unlinked = e.target.open;
}, true);

TABS.projects = {
  show() { pDeep(); renderProjects(); refreshProjects(); refreshBoard(); },
  onEvent(ev) {
    if (st.tab !== "projects") return;
    if (["watch", "queue", "resync"].includes(ev.kind)) refreshProjects();
    if (ev.kind === "resync") refreshBoard();
  },
};
