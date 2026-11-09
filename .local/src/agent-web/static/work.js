"use strict";
// Log's Work table: everything done and not done across every project (hub_core::worklog, served
// by /api/log/work). The server applies the day window and the view, attention first until a
// header says otherwise; `wday` in Log's URL is the one day parameter (the stepper, the keys and
// the chart bars write it too), so a filtered view is a link.

const WORK_WINDOWS = [["today", "Today"], ["", "7d"], ["30d", "30d"], ["all", "All"]];
const WORK_COLS = { state: ["state"], when: ["when", "n"], project: ["project"], what: ["what"], kind: ["kind"], pr: ["pr"], cost: ["cost", "n"] };
const WORK_COLOR = { failed: "var(--b-needs)", waiting: "var(--b-stalled)", active: "var(--b-working)", open: "var(--b-working)", done: "var(--b-done)", cancelled: "var(--b-parked)", queued: "var(--b-chat)" };

const wrk = tblTab({
  tab: "log", id: "work", el: "log-work", pre: "w", api: "/api/log/work", pages: true, wait: "Loading.",
  hint: "search, or project:notes state:done when:2026-11-08",
  params: (p, t) => { if (workDay()) p.set("wday", workDay()); if (t.all) p.set("all", "1"); },
  days: () => ({ key: "day", on: workDay(), windows: WORK_WINDOWS, date: true }),
  reset: () => syncDay(),
  head: (t) => workHead(t), body: (t) => workBody(t.data), tail: (t) => workTail(t.data),
});

// A time today reads as its clock; an older one keeps its month and day. Today is the server's,
// the same day the windows are cut on, wherever the phone is.
function workWhen(w, today) {
  if (!w) return "";
  return w.startsWith(today) ? w.slice(11) : w.slice(5, 10) + " " + w.slice(11);
}

const workPr = (r) => (r.unproven ? qProof(r) : !r.pr ? "" : r.url ? `<a href="${esc(r.url)}" target="_blank" rel="noopener">${esc(r.pr)}</a>` : esc(r.pr));

const workRow = (r, today) => `<tr><td><span class="chip sm" style="--c:${WORK_COLOR[r.state] || "var(--b-chat)"}">${esc(r.state)}</span></td>` +
  `<td class="n" title="${esc(r.when || "")}">${esc(workWhen(r.when, today))}</td><td>${esc(r.project)}</td><td class="wrap">${esc(r.what)}</td>` +
  `<td class="muted">${esc(r.kind || "")}</td><td>${workPr(r)}</td><td class="n">${r.cost == null ? "" : usd(r.cost)}</td></tr>`;

function workHead(t) {
  const d = t.data, errs = [t.err, ...d.errors.map((e) => `unread: ${e}`)].filter(Boolean).map((e) => `<div class="card err">${esc(e)}</div>`).join("");
  return `<div class="bhead"><span>done and not done, every project, ${d.table.shown} of ${d.table.total}</span></div>${errs}`;
}

function workBody(d) {
  return d.rows.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(d.table, WORK_COLS)}${d.rows.map((r) => workRow(r, d.today)).join("")}</table>${tblMore(d.more, "more")}</div>`
    : `<div class="empty">${d.table.total ? "No work matches." : "Nothing in this window."}</div>`;
}

// How far back each source goes, since past that the table cannot say what was not merged.
function workTail(d) {
  const from = [d.items_from && `queue items from ${esc(d.items_from)}`, d.prs_from && `merged PRs from ${esc(d.prs_from)}`].filter(Boolean).join(", ");
  return `<div class="muted small">${from ? from + ". " : ""}Not started yet lives on the <a href="#board">Board</a>.</div>`;
}

const workFeed = pushed("log", ["queue", "log"], wrk.refresh);
LOG_PARTS.push({
  show() {
    const fresh = wrk.read !== st.views.log;
    // A link or Back changed the view, and "+N more" was asked of the last one.
    if (fresh) wrk.all = false;
    wrk.read = st.views.log;
    wrk.render();
    workFeed.show(fresh);
  },
  onEvent: workFeed.onEvent,
});
