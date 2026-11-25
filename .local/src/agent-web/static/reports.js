"use strict";
// The Reports tab: what agents filed for the human, from /api/reports (hub_core::reports, the one
// reader; notes-cli `notes report` owns the files). Today is the tiles, then Needs you, Today's
// stream, Digests and Your notes (those two folded); Archive is every other report by day, a fold
// each. A row opens in place: its body is the note `/api/focus` reads, and opening an unread report
// marks it read (`POST /api/reports/read`). `#reports/<id>` opens that report and `#reports/<date>`
// that day (Daily's Refs line), each link served by hub_core::links.

// Nothing watches ~/.notes (dashboards.md rule 9 is open on it), so the open tab re-reads on a
// timer; a report lands a few times a day.
const REPORTS_REFRESH_MS = 60e3;
const REPORT_DATE = /^\d{4}-\d{2}-\d{2}$/;
// What an empty section says; a folded one with nothing in it is not drawn.
const REPORTS_EMPTY = { needs: "Nothing needs you.", stream: "No reports today." };
// data: the view; open: each fold's state; sel: the open report's id; body: each opened report's
// body html (or its read error) by id; marked: the ids a read was sent for; seen: the arg openArg
// last acted on, so a re-read never pulls the reader back to it.
const rps = { data: null, err: null, open: {}, sel: null, body: {}, marked: new Set(), seen: "" };

// The arg when it names a record (a report id or a day) rather than an inner tab.
const reportArg = () => (INNER_TABS.reports.tabs.some((t) => t[0] === st.arg) ? "" : st.arg || "");

const allReports = (d) => [...d.sections.flatMap((s) => s.rows), ...d.archive.flatMap((a) => a.rows)];

function reportBody(r) {
  const b = rps.body[r.id];
  const inner = !b ? `<div class="empty">reading</div>` : b.err ? readPanel(b.err) : `<div class="md">${b.html}</div>`;
  return `<tr class="rdet"><td colspan="4">${inner}</td></tr>`;
}

function reportRow(r) {
  const open = r.id === rps.sel;
  const row = `<tr class="rr${open ? " sel" : ""}${r.unread ? " unread" : ""}" id="sec-r-${esc(r.id)}" data-href="${esc(r.link)}">` +
    `<td>${rec2(esc(r.title), r.title, esc(r.lead), r.summary)}</td><td class="muted">${esc(r.from || r.kind)}</td>` +
    `<td>${statePill(r.state, r.level)}</td><td class="n">${when(r.at)}</td></tr>`;
  return open ? row + reportBody(r) : row;
}

const reportTable = (rows) => `<table class="rec rrep">${rows.map(reportRow).join("")}</table>`;

// A section of Today: its head, its rows; Digests and Your notes start folded, and any fold stays
// as the reader leaves it.
function reportSection(s) {
  const n = s.rows.length;
  if (!n && s.folded) return "";
  const head = secHead(s.folded ? "" : s.id, s.title, n, s.id === "needs" && n ? "warn" : "");
  const inner = n ? reportTable(s.rows) : `<div class="empty">${esc(REPORTS_EMPTY[s.id] || "")}</div>`;
  if (!s.folded) return head + inner;
  return fold("sec-d", head, inner, { k: "sec:" + s.id, id: `sec-${s.id}`, open: rps.open["sec:" + s.id] ?? false });
}

// Today: the tiles and the moved line over Needs you, then each section in Today's group.
function reportsToday(d) {
  const hue = (t) => (t.level === "warn" && t.n ? "var(--b-needs)" : "var(--c-other)");
  const tiles = `<div class="tiles">${d.tiles.map((t) => tile(esc(t.label.toUpperCase()), t.n, hue(t))).join("")}</div>`;
  const moved = d.moved ? `<div class="muted">${esc(d.moved)}</div>` : "";
  const sec = (id) => { const s = d.sections.find((x) => x.id === id); return s ? reportSection(s) : ""; };
  return innerWrap("reports", "needs", tiles + moved + sec("needs")) + innerWrap("reports", "stream", sec("stream")) +
    innerWrap("reports", "digests", sec("digests")) + innerWrap("reports", "captures", sec("captures"));
}

// Archive: a fold per day, shut unless the reader opened it or a link names it.
function reportsArchive(d) {
  let html = secHead("archive", "Archive", d.archive.length);
  if (!d.archive.length) return html + `<div class="empty">No older reports.</div>`;
  html += d.archive.map((a) => fold("sec-d", `<b>${esc(a.date)}</b> <span class="muted">${esc(a.count)}</span>`, reportTable(a.rows),
    { k: "day:" + a.date, id: `sec-day-${a.date}`, open: rps.open["day:" + a.date] ?? false })).join("");
  if (d.older_days) html += `<div class="muted more">+${d.older_days} older days</div>`;
  return html;
}

function renderReports() {
  const el = $("reports"), d = rps.data;
  if (!d) { paint(el, innerStrip("reports") + readPanel(rps.err, "reading the reports"), rps.open); return; }
  const needs = d.sections.find((s) => s.id === "needs");
  paint(el, innerStrip("reports", [], { today: needs ? needs.rows.length : 0 }) + (rps.err ? readPanel(rps.err) : "") +
    reportsToday(d) + innerWrap("reports", "archive", reportsArchive(d)), rps.open);
  seekSection();
}

function reportsBadge() {
  const n = rps.data ? rps.data.unread : 0;
  $("reports-badge").innerHTML = n ? `<span class="badge">${n}</span>` : "";
}

const refreshReports = coalesce(async () => {
  try { rps.data = await api("/api/reports"); rps.err = null; } catch (e) { rps.err = e.message; }
  reportsBadge();
  if (st.tab === "reports") { openArg(); renderReports(); }
});

// A report's body, read once per open: the note's sections as the Daily tab's reader splits them.
async function readBody(r) {
  try {
    const v = await api("/api/focus?t=" + encodeURIComponent(r.target));
    rps.body[r.id] = { html: v.sections.map((s) => (s.title ? `<h3>${esc(s.title)}</h3>` : "") + md(s.markdown, { notes: true })).join("") };
  } catch (e) { rps.body[r.id] = { err: e.message }; }
  if (st.tab === "reports" && rps.sel === r.id) renderReports();
}

// Opening an unread report marks it read, once; the answer is the view as it is after.
async function markRead(r) {
  if (!r.unread || rps.marked.has(r.id)) return;
  rps.marked.add(r.id);
  try { rps.data = await post("/api/reports/read", { id: r.id }); reportsBadge(); } catch (e) { rps.err = e.message; rps.marked.delete(r.id); }
  if (st.tab === "reports") renderReports();
}

// What the URL names: a report opens (on Archive when it left Today, its day's fold open), a past
// day opens its fold on Archive, today's date is Today's top.
function openArg() {
  const a = reportArg(), d = rps.data;
  if (!a) rps.seen = "";
  if (!a || !d || a === rps.seen) return;
  rps.seen = a;
  if (REPORT_DATE.test(a)) {
    rps.sel = null;
    if (a === d.today) { innerGo("reports", "today"); return; }
    rps.open["day:" + a] = true;
    st.section = "day-" + a;
    innerGo("reports", "archive");
    return;
  }
  const r = allReports(d).find((x) => x.id === a);
  if (!r) return;
  rps.sel = r.id;
  st.section = "r-" + r.id;
  const day = d.archive.find((x) => x.rows.some((y) => y.id === r.id));
  if (day) { rps.open["day:" + day.date] = true; innerGo("reports", "archive"); }
  if (!rps.body[r.id]) readBody(r);
  markRead(r);
}

$("reports").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest("summary") || t.closest("tr.rdet")) return;
  const tr = t.closest("tr.rr");
  if (!tr) return;
  // The open row shuts in place; another opens through its link, so Back returns to the list.
  if (tr.classList.contains("sel")) { rps.sel = null; rps.seen = ""; innerGo("reports", innerOf("reports", st.arg)[0]); renderReports(); return; }
  location.hash = tr.dataset.href;
});

$("reports").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k) rps.open[e.target.dataset.k] = e.target.open;
}, true);

const pollReports = poll("reports", refreshReports, REPORTS_REFRESH_MS);
TABS.reports = {
  show() { openArg(); renderReports(); pollReports(); },
  onEvent(ev) { if (ev.kind === "resync" && st.tab === "reports") refreshReports(); },
};
// The nav's badge counts unread reports from the first load, before the tab is opened.
refreshReports();
