"use strict";
// The Schedules tab: everything scheduled and why, from /api/schedules (hub_core::schedules). The
// table is the shared one (table.js): the server filters and sorts by the view in the URL. A row
// opens its purpose, what runs inside it, what reads its result and its runs; an agentctl row
// opens the runner's Fleet page instead, which already says all that.

// Nothing here pushes to a browser, and a schedule changes by the hour.
const SCHEDULES_REFRESH_MS = 60e3;
// Runs a detail shows before folding the rest behind "+N older".
const SCHEDULE_RUNS_OPEN = 2;
const schst = { data: null, err: null, sel: null };

const schedKey = (r) => `${r.kind}|${r.name}`;

const refreshSchedules = coalesce(async () => {
  const q = tblParams(st.views.schedules).toString();
  try { schst.data = await api("/api/schedules" + (q ? "?" + q : "")); schst.err = null; } catch (e) { schst.err = e.message; }
  if (st.tab === "schedules") renderSchedules();
});

const SCHED_COLS = { kind: ["kind", "opt"], name: ["name"], schedule: ["schedule", "opt"], last: ["last", "n"], result: ["result"], streak: ["streak"], triage: ["triage"] };


function scheduleRow(r) {
  const cls = r.ok === false ? "bad" : r.ok === true ? "" : "muted";
  const open = schedKey(r) === schst.sel;
  const none = r.purpose ? "" : ` <span class="warn" title="this schedule does not say why it exists">no purpose</span>`;
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(schedKey(r))}">` +
    `<td class="muted opt">${esc(r.kind)}</td><td class="wrap">${esc(r.name)}${none}</td><td class="opt">${esc(r.schedule)}</td>` +
    `<td class="n">${r.last ? when(r.last) : "-"}</td><td class="${cls}">${esc(r.result || "-")}</td>` +
    `<td class="${r.streak < 0 ? "bad" : ""}">${esc(r.streak_word)}</td><td class="wrap muted">${esc(r.triage)}</td></tr>`;
  return open ? row + scheduleDetail(r) : row;
}

const runLine = (u) => `<div>${u.at ? when(u.at) : "-"} <span class="${u.ok === false ? "bad" : ""}">${esc(u.result)}</span>` +
  (u.failed.length ? ` <span class="muted">${esc(u.failed.join(", "))}</span>` : "") +
  (u.url ? ` <a href="${esc(u.url)}" target="_blank" rel="noopener">Open run</a>` : "") + `</div>`;

function scheduleRuns(runs) {
  const open = runs.slice(0, SCHEDULE_RUNS_OPEN), older = runs.slice(SCHEDULE_RUNS_OPEN);
  return open.map(runLine).join("") +
    (older.length ? `<details><summary class="muted">+${older.length} older</summary>${older.map(runLine).join("")}</details>` : "");
}

function scheduleDetail(r) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const list = (xs) => xs.map(esc).join("; ");
  const why = r.purpose ? esc(r.purpose) : `<span class="warn">no purpose written: it says what it is, not why it runs</span>`;
  return `<tr class="wdet"><td colspan="7"><div class="sdet"><div class="muted">${esc(r.status)}</div>` +
    line("Why it exists", why) + line("Inside", esc(r.inside)) + line("Before", esc(r.before)) +
    line("After", list(r.after)) + line("Open triage", list(r.open)) +
    line("Runs", r.runs.length ? scheduleRuns(r.runs) : "") + `</div></td></tr>`;
}

function schedulesBody(d) {
  const t = d.table, rows = d.rows || [];
  return rows.length
    ? `<div class="panel scroll sched"><table class="tbl">${tblHead(t, SCHED_COLS)}${rows.map(scheduleRow).join("")}</table></div>`
    : `<div class="panel">${t.total ? "No schedules match." : "Nothing is scheduled."}</div>`;
}

function schedulesHead(d) {
  let html = `<h2 class="sec">Schedules <span class="muted">${esc(d.summary)}, read ${d.at ? clock(d.at * 1e3) : "-"}</span></h2>`;
  if (schst.err) html += `<div class="panel down">${esc(schst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

function renderSchedules() {
  const el = $("schedules");
  const d = schst.data;
  if (!d || !d.table) {
    const why = schst.err || (d?.errors || [])[0];
    el.innerHTML = `<div class="empty">${why ? esc(why) : "Loading..."}</div>`;
    return;
  }
  // A refresh must not take the search box or an open dropdown from under the human.
  const f = document.activeElement;
  if (f?.id === "sched-q" || f?.dataset?.tq !== undefined) {
    paint($("sched-head"), schedulesHead(d));
    if (f.id === "sched-q") paint($("sched-facets"), tblFacets(d.table));
    paint($("sched-chips"), tblChips(d.table));
    paint($("sched-body"), schedulesBody(d));
    return;
  }
  paint(el, `<div id="sched-head">${schedulesHead(d)}</div>${tblBar("sched", d.table, "search, or kind:ci result:failure -name:dream")}` +
    `<div id="sched-body">${schedulesBody(d)}</div>`);
}

// The view changed: the URL follows it and the server applies it.
function schedulesView(patch) {
  setQuery(tblSet(st.views.schedules, patch));
  refreshSchedules();
}

$("schedules").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest("details")) return;
  const v = tblPatch(e);
  if (v) { schedulesView(v); return; }
  const tr = t.closest("tr.jr");
  if (!tr) return;
  const r = (schst.data.rows || []).find((x) => schedKey(x) === tr.dataset.key);
  if (!r) return;
  if (r.page) { location.hash = "fleet/" + encodeURIComponent(r.page); return; }
  schst.sel = schst.sel === schedKey(r) ? null : schedKey(r);
  renderSchedules();
});
// A picked dropdown lets go of focus, so the answer redraws it with the new counts.
for (const ev of ["input", "change"]) $("schedules").addEventListener(ev, (e) => { const v = tblPatch(e); if (!v) return; if (e.type === "change" && e.target.blur) e.target.blur(); schedulesView(v); });

const pollSchedules = poll("schedules", refreshSchedules, SCHEDULES_REFRESH_MS);
TABS.schedules = {
  show() { renderSchedules(); pollSchedules(); },
  onEvent(ev) { if (ev.kind === "resync" && st.tab === "schedules") refreshSchedules(); },
};
