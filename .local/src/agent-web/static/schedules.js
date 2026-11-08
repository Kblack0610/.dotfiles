"use strict";
// The Schedules tab: everything scheduled and why, from /api/schedules (hub_core::schedules). The
// table is the shared one (table.js): the server filters and sorts by the view in the URL. A row
// opens its purpose, what runs inside it, what reads its result and its runs; an agentctl row
// opens the runner's Fleet page instead, which already says all that.

// Nothing here pushes to a browser, and a schedule changes by the hour.
const SCHEDULES_REFRESH_MS = 60e3;
// Runs a detail shows before folding the rest behind "+N older".
const SCHEDULE_RUNS_OPEN = 2;
const schst = tblTab({
  tab: "schedules", id: "sched", el: "schedules", api: "/api/schedules", hint: "search, or kind:ci result:failure -name:dream",
  head: (t) => schedulesHead(t.data), body: (t) => schedulesBody(t.data),
});

const schedKey = (r) => `${r.kind}|${r.name}`;

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

$("schedules").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest("details")) return;
  const tr = t.closest("tr.jr");
  if (!tr) return;
  const r = (schst.data.rows || []).find((x) => schedKey(x) === tr.dataset.key);
  if (!r) return;
  if (r.page) { location.hash = "fleet/" + encodeURIComponent(r.page); return; }
  schst.sel = schst.sel === schedKey(r) ? null : schedKey(r);
  schst.render();
});

const pollSchedules = poll("schedules", schst.refresh, SCHEDULES_REFRESH_MS);
TABS.schedules = {
  show() { schst.render(); pollSchedules(); },
  onEvent(ev) { if (ev.kind === "resync" && st.tab === "schedules") schst.refresh(); },
};
