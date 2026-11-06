"use strict";
// Sessions with no session open: the capacity header, the table and the folds under it. Rows and
// the header come from hub-core (`session_table`, `capacity`) through /api/sessions/*, and the
// server filters and sorts by the view in the URL (table.js). A row with a session here opens it
// (app.js); any other row unfolds in place, to its fleet-state card or its outcome card.

// A day's ended sessions on a busy day run to hundreds, so the table stops here until asked.
const SESSIONS_OPEN = 200;
const sst = { data: null, err: null, cap: null, capErr: null, all: false, open: null, cards: {}, confirm: null };

const SESSION_COLS = { bucket: ["bucket"], project: ["project"], task: ["task"], pr: ["PR/CI"], phases: ["phases", "n"], idle: ["idle", "n"], cost: ["cost", "n"], acct: ["acct"] };

const refreshTable = coalesce(async () => {
  const q = tblParams(st.views.sessions).toString();
  try { sst.data = await api("/api/sessions/table" + (q ? "?" + q : "")); setBuckets(sst.data.buckets); sst.err = null; } catch (e) { sst.err = e.message; }
  renderOverview();
});
const refreshCapacity = coalesce(async () => {
  try { sst.cap = await api("/api/sessions/capacity"); sst.capErr = null; } catch (e) { sst.capErr = e.message; }
  renderOverview();
});
// The table's sources move only with what is on screen, so a session open reads neither.
function refreshSessions() {
  if (st.sel) return;
  refreshTable();
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

// The unfolded row: a fleet-state row's card, else the outcome card, which only exists once the
// nightly run has seen the session.
function sessionFold(r) {
  const s = r.source === "live" && sessionsOf().find((x) => x.target === r.target);
  if (s) return card(s, maxContext(), Date.now());
  const said = r.item ? `<div class="muted">queue item ${esc(r.item)}</div>` : "";
  if (!r.session_id) return said;
  const text = sst.cards[r.session_id];
  return `${said}<pre class="joblog">${text == null ? "Loading the card." : esc(text)}</pre>`;
}

function sessionRow(r) {
  const a = sessionAgent(r);
  const idle = r.ended ? esc(r.ended) : r.idle_min == null ? "-" : dur(r.idle_min);
  const phases = r.phases_total ? `${r.phases_done}/${r.phases_total}` : "-";
  const open = sst.open === r.key;
  const row = `<tr class="click" data-key="${esc(r.key)}"><td><span class="chip sm" style="--c:${bucketColor(r.bucket)}">${esc(r.bucket)}</span></td>` +
    `<td>${esc(r.project)}</td><td class="wrap">${esc(r.task)} ${sessionTags(r, a)}</td><td>${sessionPr(r)}</td><td class="n">${phases}</td>` +
    `<td class="n">${idle}</td><td class="n">${usd(r.cost_usd)}</td><td>${esc(r.account || "-")}</td></tr>`;
  return open ? row + `<tr><td colspan="8" class="wrap">${sessionFold(r)}</td></tr>` : row;
}

function sessionsBody(d) {
  const t = d.table, shown = d.rows || [];
  const rows = sst.all ? shown : shown.slice(0, SESSIONS_OPEN);
  const more = shown.length - rows.length;
  return shown.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, SESSION_COLS)}${rows.map(sessionRow).join("")}</table>` +
      (more ? `<button class="btn sm" data-all="1">+${more} older</button>` : "") + `</div>`
    : `<div class="panel">${t.total ? "No sessions match." : "No sessions, live or ended today."}</div>`;
}

function renderOverview() {
  if (st.sel || st.tab !== "sessions") return;
  const el = $("scroll"), d = sst.data;
  if (!d || !d.table) {
    const why = sst.err || (d?.errors || [])[0];
    el.innerHTML = `<div class="empty">${why ? esc(why) : "Loading the sessions."}</div>`;
    return;
  }
  // A refresh must not take the search box from under the human, so everything around it repaints and it stays.
  if (document.activeElement?.id === "sessions-q") {
    paint($("sessions-head"), sessionsHead());
    paint($("sessions-facets"), tblFacets(d.table));
    paint($("sessions-chips"), tblChips(d.table));
    paint($("sessions-body"), sessionsBody(d));
    paint($("sessions-folds"), overviewFolds(), wst.open);
    return;
  }
  paint(el, `<div id="sessions-head">${sessionsHead()}</div>${tblBar("sessions", d.table, "search, or project:dotfiles pr:open item:none")}` +
    `<div id="sessions-body">${sessionsBody(d)}</div><div id="sessions-folds">${overviewFolds()}</div>`, wst.open);
}

// The view changed: the URL follows it and the server applies it.
function sessionsView(patch) {
  setQuery(tblSet(st.views.sessions, patch));
  sst.all = false;
  refreshTable();
}

async function startTimer(name) {
  sst.confirm = null;
  try { await post(`/api/sessions/timer/${encodeURIComponent(name)}/start`, {}); sst.capErr = null; } catch (e) { sst.capErr = e.message; }
  refreshCapacity();
}

async function openOutcome(sid) {
  try { sst.cards[sid] = await api(`/api/outcomes/card?sid=${encodeURIComponent(sid)}`); } catch (e) { sst.cards[sid] = `No outcome card yet: ${e.message}`; }
  renderOverview();
}

function sessionClick(r) {
  const a = sessionAgent(r);
  if (a) { select(a); return; }
  sst.open = sst.open === r.key ? null : r.key;
  if (sst.open && r.source !== "live" && r.session_id) openOutcome(r.session_id);
  renderOverview();
}

$("scroll").addEventListener("click", (e) => {
  if (st.sel) return;
  const patch = tblPatch(e), d = e.target.dataset || {};
  if (patch) sessionsView(patch);
  else if (d.start) { sst.confirm = d.start; renderOverview(); }
  else if (d.keep !== undefined) { sst.confirm = null; renderOverview(); }
  else if (d.go) startTimer(d.go);
  else if (d.unlinked !== undefined) sessionsView({ q: "item:none", s: "" });
  else if (d.all) { sst.all = true; renderOverview(); }
  else {
    const tr = e.target.closest("tr[data-key]");
    const r = tr && sst.data && sst.data.rows.find((x) => x.key === tr.dataset.key);
    if (r) sessionClick(r);
  }
});
for (const kind of ["input", "change"]) {
  $("scroll").addEventListener(kind, (e) => {
    const patch = !st.sel && tblPatch(e);
    if (patch) sessionsView(patch);
  });
}

// fleet-state writes every minute and the shepherd on each pass; only the open tab reads them.
const watchFeed = pushed("sessions", ["watch"], refreshWatch);
const shepFeed = pushed("sessions", ["shepherd", "sessions"], refreshShepherd);
const tableFeed = pushed("sessions", ["watch", "queue"], refreshSessions);
TABS.sessions = {
  show() {
    if (!st.sel) overview();
    watchFeed.show(!wst.data); shepFeed.show(!shst.data); tableFeed.show(!sst.data);
  },
  onEvent(ev) { watchFeed.onEvent(ev); shepFeed.onEvent(ev); tableFeed.onEvent(ev); },
};
