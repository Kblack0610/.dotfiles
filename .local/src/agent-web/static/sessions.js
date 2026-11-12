"use strict";
// Sessions' Sessions inner tab, with no session open: the overview tiles, the capacity header, the
// table and the folds under it. Rows, counts, spend and the header come from hub-core (`session_table`, `capacity`)
// through /api/sessions/*, and the server filters and sorts by the view in the URL (table.js). Any
// row opens that session's conversation, `#sessions/<id>` (app.js); its Details page is hub-core's
// `session_page` through /api/sessions/page, and a session on a pane here also has its Screen.

// A day's ended sessions on a busy day run to hundreds, so the table stops here until asked.
const SESSIONS_OPEN = 200;
const sst = tblTab({
  tab: "sessions", id: "sessions", el: "ov-sessions", on: "scroll", api: "/api/sessions/table", hint: "search, or project:dotfiles pr:open item:none",
  wait: "Loading the sessions.", state: { cap: null, capErr: null, all: false, confirm: null },
  shown: () => !st.sel && sessShows("sessions"), got: (t) => setBuckets(t.data.buckets), after: () => renderSide(), open: () => wst.open,
  tiles: (t) => tile("SPEND", usd(t.data.spend_usd), "var(--accent)", `${t.data.table.shown} shown`), head: () => sessionsHead(), body: (t) => sessionsBody(t.data), tail: () => overviewFolds(),
});

const SESSION_COLS = { bucket: ["bucket"], activity: ["activity"], project: ["project"], task: ["task"], by: ["started by"], pr: ["PR/CI"], phases: ["phases", "n"], idle: ["idle", "n"], cost: ["cost", "n"], acct: ["acct"], harness: ["harness"], close: ["close"] };

const refreshCapacity = coalesce(async () => {
  try { sst.cap = await api("/api/sessions/capacity"); sst.capErr = null; } catch (e) { sst.capErr = e.message; }
  sst.render();
});
// The table's sources move only with what is on screen, so a session open reads only its page.
function refreshSessions() {
  if (st.sel) { if (st.view === "page") loadPage(); if (SPLIT.matches) sst.refresh(); return; }
  sst.refresh();
  refreshCapacity();
}

function capPart(p) {
  const asked = sst.confirm === p.start;
  const start = !p.start ? "" : asked
    ? ` <span class="capask">${esc(p.confirm)} <button class="btn sm" data-go="${esc(p.start)}">Start</button> <button class="btn sm" data-keep>Cancel</button></span>`
    : ` <button class="btn sm" data-start="${esc(p.start)}">Start</button>`;
  return `<span class="${p.warn ? "capwarn" : ""}">${esc(p.text)}</span>${start}`;
}

function sessionsHead() {
  const c = sst.cap;
  const line = c ? c.parts.map(capPart).join(" | ") : '<span class="muted">Reading capacity.</span>';
  const bad = [sst.err, sst.capErr, ...(sst.data?.errors || []), ...(c?.errors || [])].filter(Boolean);
  const unlinked = c && c.unlinked ? `<div class="capline muted">${c.unlinked} of ${c.live} live sessions have no queue item <button class="btn sm" data-unlinked>Show</button></div>` : "";
  return `<div class="capline">${line}</div>${unlinked}` + bad.map((e) => `<div class="card err">${esc(e)}</div>`).join("");
}

const sessionAgent = (r) => st.agents.find((a) => a.target === r.target || (r.session_id && a.session === r.session_id));

// What the row is beyond its columns: the human's own session, parked, a pending ask, no session
// here, and where an ended row came from.
function sessionTags(r, a) {
  const p = [];
  if (a && a.attached) p.push('<span class="pill here">you are here</span>');
  if (a && a.parked) p.push('<span class="pill parked">parked</span>');
  if (a && a.ask) p.push(`<span class="pill ask" title="pending ask">ask ${esc(a.ask)}</span>`);
  if (!a && r.source === "live") p.push('<span class="pill">no session</span>');
  if (r.source !== "live") p.push(`<span class="pill" title="where this row came from">${esc(r.source)}</span>`);
  return p.join(" ");
}

function sessionPr(r) {
  if (!r.pr) return "-";
  const ci = r.ci ? ` <b class="ci ${esc(r.ci.toLowerCase())}">${esc(r.ci)}</b>` : "";
  return `#${esc(r.pr)}${r.pr_state ? " " + esc(r.pr_state.toLowerCase()) : ""}${ci}`;
}

function sessionRow(r) {
  const a = sessionAgent(r);
  const idle = r.ended ? esc(r.ended) : r.idle_min == null ? "-" : dur(r.idle_min);
  const phases = r.phases_total ? `${r.phases_done}/${r.phases_total}` : "-";
  return `<tr class="click" data-key="${esc(r.key)}"><td><span class="chip sm" style="--c:${bucketColor(r.bucket)}">${esc(r.bucket)}</span></td><td class="muted">${esc(r.activity || "-")}</td>` +
    `<td>${esc(r.project)}</td><td class="wrap">${esc(r.task)} ${sessionTags(r, a)}</td><td class="muted">${esc(r.by || "-")}</td><td>${sessionPr(r)}</td><td class="n">${phases}</td>` +
    `<td class="n">${idle}</td><td class="n">${usd(r.cost_usd)}</td><td>${esc(r.account || "-")}</td><td>${esc(r.harness || "-")}</td><td>${esc(r.close || "-")}</td></tr>`;
}

function sessionsBody(d) {
  const t = d.table, shown = d.rows || [];
  const rows = sst.all ? shown : shown.slice(0, SESSIONS_OPEN);
  const more = shown.length - rows.length;
  return shown.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, SESSION_COLS)}${rows.map(sessionRow).join("")}</table>` +
      tblMore(more) + `</div>`
    : `<div class="panel">${t.total ? "No sessions match." : "No sessions, live or ended today."}</div>`;
}

async function startTimer(name) {
  sst.confirm = null;
  try { await post(`/api/sessions/timer/${encodeURIComponent(name)}/start`, {}); sst.capErr = null; } catch (e) { sst.capErr = e.message; }
  refreshCapacity();
}

const sessionId = (a) => a.session || a.target;

// A row is a link, so Back returns to the table as it was left.
function sessionClick(r) {
  const a = sessionAgent(r), q = st.views.sessions;
  location.hash = `#sessions/${encodeURIComponent(a ? sessionId(a) : r.session_id || r.key)}${q ? "?" + q : ""}`;
}

// Open a session from another tab: the URL names it, and the tab opens what the URL names.
function openAgent(a) {
  setTab("sessions", sessionId(a));
}

// What `#sessions/<id>` names: its session on a pane here, else one with no pane (it ended, or
// runs where this page cannot reach), which has its page and transcript and nothing to type into.
async function openSession(id) {
  if (st.sel && (sessionId(st.sel) === id || st.sel.target === id)) return;
  if (!st.agents.length) {
    await refreshAgents();
    if (st.arg !== id) return;
  }
  // An item's link names its session by the item (hub_core::queue Item::links), as session_page::find resolves it.
  const a = st.agents.find((x) => x.session === id || x.target === id) || st.agents.find((x) => (x.items || []).includes(id));
  select(a || { target: id, session: id, paneless: true, status: "", summary: "", actions: [] });
  sideShow(true);
}

// From 900px an open session keeps the list beside it (app.css): the same rows as the table, under
// the same view, one compact line each, so the human moves between sessions without going Back.
// Under 900px the list is not drawn and not read.
const SPLIT = matchMedia("(min-width: 900px)");
const isSel = (r) => !!st.sel && ((r.target && r.target === st.sel.target) || (r.session_id && r.session_id === st.sel.session));

function sideRow(r) {
  const idle = r.ended ? esc(r.ended) : r.idle_min == null ? "" : dur(r.idle_min);
  const pr = r.pr ? sessionPr(r) : "";
  return `<button class="srow${isSel(r) ? " on" : ""}" data-key="${esc(r.key)}"><span class="chip sm" style="--c:${bucketColor(r.bucket)}">${esc(r.bucket)}</span>` +
    `<span class="sn">${esc(r.task || r.target)}</span><span class="sx">${esc(r.project)}${pr ? " " + pr : ""}${idle ? " | " + idle : ""}</span></button>`;
}

function renderSide(scroll = false) {
  const el = $("side");
  if (!st.sel || !SPLIT.matches) { el.innerHTML = ""; return; }
  const d = sst.data;
  if (!d || !d.table) { el.innerHTML = `<div class="empty">${esc(sst.err || "Loading the sessions.")}</div>`; return; }
  const rows = (d.rows || []).slice(0, SESSIONS_OPEN);
  const more = (d.rows || []).length - rows.length;
  paint(el, `<div class="seg fseg">${tblChips(d.table)}</div>` + (rows.length ? rows.map(sideRow).join("") : '<div class="muted">No sessions match.</div>') +
    (more ? `<div class="muted">+${more} more on the table</div>` : ""));
  if (scroll) el.querySelector(".srow.on")?.scrollIntoView({ block: "nearest" });
}

// A session just opened, or the screen crossed 900px: draw the list, reading it if it is not read.
function sideShow(scroll) {
  if (!st.sel || !SPLIT.matches) return renderSide();
  if (sst.data) renderSide(scroll);
  else sst.refresh();
}
SPLIT.addEventListener("change", () => sideShow(true));

$("side").addEventListener("click", (e) => {
  const patch = tblPatch(e);
  if (patch) return sst.view(patch);
  const b = e.target.closest(".srow");
  const r = b && sst.data && sst.data.rows.find((x) => x.key === b.dataset.key);
  if (r) sessionClick(r);
});

// The Details view. The parts are hub-core's; what is drawn here is the card for a session still in
// the state document, and the folds, each open until the reader folds it.
function pageHtml(p) {
  const s = sessionsOf().find((x) => (p.session_id && x.session_id === p.session_id) || (p.target && x.target === p.target));
  const outcome = p.outcome ? fold("page-outcome", "Outcome card", `<pre class="joblog">${esc(p.outcome)}</pre>`) : pageRow("Outcome card", "after it ends");
  return `<div class="pghead"><span class="chip" style="--c:${bucketColor(p.bucket)}">${esc(p.bucket)}</span> <span class="muted">${esc(p.idle)}</span> ${esc(p.task)}</div>` +
    p.errors.map((e) => `<div class="card err">${esc(e)}</div>`).join("") +
    p.parts.map(pagePart).join("") +
    outcome + (s ? fold("page-state", "Fleet state", card(s, maxContext(), Date.now())) : "");
}

const loadPage = coalesce(async () => {
  const a = st.sel;
  if (!a || st.view !== "page") return;
  const id = sessionId(a);
  const still = () => st.sel && sessionId(st.sel) === id && st.view === "page";
  let html;
  try {
    const p = await api(`/api/sessions/page?t=${encodeURIComponent(id)}`);
    if (still() && st.sel.paneless) {
      Object.assign(st.sel, { name: p.name, summary: p.task, target: p.session_id || st.sel.target });
      renderHead();
    }
    html = pageHtml(p);
  } catch (e) { html = `<div class="empty">${esc(e.message)}</div>`; }
  if (still()) paint($("scroll"), html, wst.open);
});

$("scroll").addEventListener("click", (e) => {
  const d = e.target.dataset || {};
  if (st.sel) return;
  if (d.start) { sst.confirm = d.start; sst.render(); }
  else if (d.keep !== undefined) { sst.confirm = null; sst.render(); }
  else if (d.go) startTimer(d.go);
  else if (d.unlinked !== undefined) sst.view({ q: "item:none", s: "" });
  else {
    const tr = e.target.closest("tr[data-key]");
    const r = tr && sst.data && sst.data.rows.find((x) => x.key === tr.dataset.key);
    if (r) sessionClick(r);
  }
});

// The inner tab shown: an inner id, or Sessions while a session's record is open.
const sessInner = () => innerOf("sessions", st.arg)[0];
const sessShows = (id) => st.tab === "sessions" && sessInner() === id;
// The session `#sessions/<id>` names; "" on an inner tab.
const sessArg = () => (st.arg && !INNER_TABS.sessions.tabs.some((t) => t[0] === st.arg) ? st.arg : "");

// fleet-state writes every minute and the shepherd on each pass; only the inner tab shown reads
// its own (rule 10): a session's record reads the table's, for its side list and facts.
const watchFeed = pushed("sessions", ["watch"], refreshWatch, () => sessShows("sessions"));
const tableFeed = pushed("sessions", ["watch", "queue"], refreshSessions, () => sessShows("sessions"));
const shepFeed = pushed("sessions", ["shepherd", "sessions"], refreshShepherd, () => sessShows("shepherd"));
TABS.sessions = {
  show() {
    if (sessArg()) openSession(sessArg()); else overview();
    this.inner(sessInner());
  },
  inner(id) {
    if (id === "sessions") { sst.render(); watchFeed.show(!wst.data); tableFeed.show(true); }
    else if (id === "runners") runnersShow();
    else if (id === "shepherd") { renderShepherd(); shepFeed.show(!shst.data); }
  },
  onEvent(ev) { watchFeed.onEvent(ev); shepFeed.onEvent(ev); tableFeed.onEvent(ev); runnersEvent(ev); },
};
