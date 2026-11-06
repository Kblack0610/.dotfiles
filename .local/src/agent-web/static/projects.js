"use strict";
// The Projects tab: one card per lab project (/api/projects, hub_core::projects, the cards the
// hub TUI's Projects tab draws) with its open version's progress by size, its pace and ETA, and
// what is in flight on it, in flight first. "Open rows" shows that project's rows under its
// card, with every row action board.js has; "All projects" shows every project's rows. The
// numbers are counted, never judged: the summary line is hub_core's, word for word.

const pst = { data: null, err: null, open: null, unlinked: false };

const refreshProjects = coalesce(async () => {
  try { pst.data = await api("/api/projects"); pst.err = null; } catch (e) { pst.err = e.message; }
  if (st.tab === "projects") { pDeep(); renderProjects(); }
});

const pKey = (c) => c.profile + "/" + c.name;

// The sessions running on a project, a card shows the first PRUNNING_SHOWN of; its rows view
// shows them all.
const PRUNNING_SHOWN = 3;

// One running item: its title (two lines at most), then its phases and estimate.
function pRunning(r) {
  const meta = [esc(phasesText(r)), etaText(r.phases)].filter(Boolean).join(", ");
  return `<li><span class="prt">${esc(r.title)}</span>${meta ? `<span class="prm">${meta}</span>` : ""}</li>`;
}

// A count chip, only when there is something to count.
const pCount = (n, what, cls) => (n ? cchip(cls || "", `${n} ${what}`) : "");

// A project card: its name and stage, the open version's progress (hub_core's summary word for
// word under the meter), its goal, what it holds as counts, then what runs on it.
function pCard(c, rowsOpen) {
  const chips = [cchip("", esc(c.stage || "no stage")), pCount(c.running.length, "running", "running"), pCount(c.waiting, "waiting", "waiting")];
  const counts = [pCount(c.queued, "queued"), pCount(c.requested, "#requested"), pCount(c.inbox, "in the inbox")].join("");
  const shown = rowsOpen ? c.running : c.running.slice(0, PRUNNING_SHOWN);
  const more = c.running.length - shown.length;
  return `<div class="card qitem pcard"${rowsOpen ? "" : ` data-open="${esc(pKey(c))}"`}>` +
    cardHead(c.name, chips.filter(Boolean)) +
    cardLine([esc(c.profile)].concat(c.prio ? [`prio ${esc(c.prio)}`] : [])) +
    `<div class="pprog">${meter((c.percent || 0) / 100)}<span class="ppct">${Math.round(c.percent || 0)}%</span></div>` +
    `<div class="psum">${esc(c.summary)}</div>` +
    (c.goal ? `<div class="pgoal">${esc(c.goal)}</div>` : "") +
    (counts ? `<div class="pcounts">${counts}</div>` : "") +
    (shown.length ? `<ul class="prun">${shown.map(pRunning).join("")}</ul>` : "") +
    (more ? `<div class="cline">+${more} more running; Open rows shows them all</div>` : "") +
    (c.status ? `<div class="pstat"><span class="muted">${esc(c.status_date)}</span> ${esc(c.status)}</div>` : "") +
    (rowsOpen ? "" : `<div class="opts"><button class="btn sm" data-open="${esc(pKey(c))}">Open rows</button></div>`) +
    `</div>`;
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
  html += cards.map((c) => pCard(c, false)).join("");
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
  if (!all) bst.draft.key = key;
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
  $("p-head").innerHTML = `<div class="opts"><button class="btn sm" id="p-back">Back to projects</button></div>` +
    (c ? pCard(c, true) : `<h2 class="sec">All projects</h2>`);
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
