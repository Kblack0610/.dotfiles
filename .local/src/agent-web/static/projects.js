"use strict";
// The Projects tab: one card per lab project (/api/projects, hub_core::projects, the cards the
// hub TUI's Projects tab draws) with its open version's progress by size, its pace and ETA, and
// what is in flight on it, in flight first. "Open rows" shows that project's rows under its
// card, with every row action board.js has; "All projects" shows every project's rows. The
// numbers are counted, never judged: the summary line is hub_core's, word for word.

const pst = { data: null, err: null, open: null, unlinked: false };

const refreshProjects = coalesce(async () => {
  try { pst.data = await api("/api/projects"); pst.err = null; } catch (e) { pst.err = e.message; }
  if (st.tab === "projects") renderProjects();
});

const pKey = (c) => c.profile + "/" + c.name;

function pRunning(r) {
  let t = r.title;
  const ph = r.phases;
  if (ph) t += ` (phase ${ph.done + 1} of ${ph.total}${ph.next ? ": " + ph.next : ""})`;
  return `<div class="pline"><span class="plead">running</span><span>${esc(t)} ${etaText(ph)}</span></div>`;
}

function pCard(c, rowsOpen) {
  const chips = [];
  if (c.running.length) chips.push(cchip("running", `${c.running.length} running`));
  if (c.waiting) chips.push(cchip("waiting", `${c.waiting} waiting`));
  const counts = `${c.running.length} running, ${c.waiting} waiting, ${c.queued} queued; ` +
    `${c.requested} rows #requested, ${c.inbox} in the inbox`;
  return `<div class="card qitem pcard"${rowsOpen ? "" : ` data-open="${esc(pKey(c))}"`}>` +
    cardHead(c.name.toUpperCase(), chips) +
    cardLine([esc(c.profile), esc(c.stage)]) +
    `<div class="pprog">${meter((c.percent || 0) / 100)}<span>${esc(c.summary)}</span></div>` +
    (c.goal ? `<div class="pline"><span class="plead">goal</span><span>${esc(c.goal)}</span></div>` : "") +
    c.running.map(pRunning).join("") +
    `<div class="pline"><span class="plead">queue</span><span>${esc(counts)}</span></div>` +
    (c.status ? `<div class="pline muted"><span class="plead">${esc(c.status_date)}</span><span>${esc(c.status)}</span></div>` : "") +
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
    cardHead("ALL PROJECTS", [cchip("", open == null ? "reading notes board" : `${open} open rows`)]) +
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
    (c ? pCard(c, true) : `<h2 class="sec">ALL PROJECTS</h2>`);
  renderBoard();
}

$("projects").addEventListener("click", (e) => {
  if (e.target.id === "p-back") { pst.open = null; renderProjects(); refreshProjects(); return; }
  const o = e.target.closest("[data-open]");
  if (o && !e.target.closest("#board")) pOpen(o.dataset.open);
});
$("projects").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k === "unlinked") pst.unlinked = e.target.open;
}, true);

TABS.projects = {
  show() { renderProjects(); refreshProjects(); refreshBoard(); },
  onEvent(ev) {
    if (st.tab !== "projects") return;
    if (["watch", "queue", "resync"].includes(ev.kind)) refreshProjects();
    if (ev.kind === "resync") refreshBoard();
  },
};
