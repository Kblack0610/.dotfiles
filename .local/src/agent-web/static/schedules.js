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
  tab: "schedules", id: "sched", el: "schedules", api: "/api/schedules", hint: "search, or kind:ci state:failing -name:dream",
  head: (t) => schedulesHead(t.data), body: (t) => schedulesBody(t.data),
  tiles: (t) => schedulesTiles(t.data),
});
// When the schedules were read, after the state tiles.
const schedulesTiles = (d) => tile("READ", d.at ? clock(d.at * 1e3) : "-", "var(--c-other)");

const schedKey = (r) => `${r.kind}|${r.name}`;

const SCHED_COLS = { kind: ["kind"], name: ["name"], state: ["state"], schedule: ["schedule"], next: ["next", "n"], last: ["last", "n"], took: ["took", "n"], passed: ["passed", "n"], failed: ["failed", "n"], streak: ["streak"], triage: ["triage"] };
// A job state's hue by its level (hub_core::reading::JobState::level); off is plain and dim.
const SCHED_HUE = { bad: "bad", warn: "warn", ok: "" };
const schedState = (r) => `<td class="${r.state === "off" ? "muted" : SCHED_HUE[r.state_level] ?? ""}" title="${esc(r.state_why || r.status || "")}">${esc(r.state)}</td>`;


// A start as the time alone when it is today, else the day too: the TUI's clock().
function nextStart(t) {
  if (!t) return "-";
  const d = new Date(t * 1e3), p = (n) => String(n).padStart(2, "0"), hm = `${p(d.getHours())}:${p(d.getMinutes())}`;
  return d.toDateString() === new Date().toDateString() ? hm : `${p(d.getMonth() + 1)}-${p(d.getDate())} ${hm}`;
}

function scheduleRow(r) {
  const open = schedKey(r) === schst.sel;
  const none = r.purpose ? "" : ` <span class="warn" title="this schedule does not say why it exists">no purpose</span>`;
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(schedKey(r))}">` +
    `<td class="muted">${esc(r.kind)}</td><td class="wrap">${esc(r.name)}${none}</td>${schedState(r)}<td>${esc(r.schedule)}</td>` +
    `<td class="n">${nextStart(r.next)}</td><td class="n">${r.last ? when(r.last) : "-"}</td><td class="n">${secs(r.took)}</td>` +
    `<td class="n">${r.ok_at ? when(r.ok_at) : "-"}</td><td class="n${r.state === "failing" ? " bad" : ""}">${r.fail_at ? when(r.fail_at) : "-"}</td>` +
    `<td class="${r.streak < 0 ? "bad" : ""}">${esc(r.streak_word)}</td><td class="wrap muted">${esc(r.triage)}</td></tr>`;
  return open ? row + scheduleDetail(r) : row;
}

const runLine = (u) => `<div>${u.at ? when(u.at) : "-"} <span class="${u.ok === false ? "bad" : ""}">${esc(u.result)}</span>` +
  (u.took != null ? ` <span class="muted">in ${secs(u.took)}</span>` : "") +
  (u.failed.length ? `<span class="muted">: ${esc(u.failed.join(", "))}</span>` : "") +
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
  return `<tr class="wdet"><td colspan="${Object.keys(SCHED_COLS).length}"><div class="sdet"><div class="muted">${esc(r.status)}</div>` +
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
  const t = d.table;
  let html = secHead("", "Schedules", tblCount(t));
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
