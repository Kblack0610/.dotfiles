"use strict";
// The Alerts tab: what is firing, who owns its fix, what fired lately and every watch, from
// /api/alerts (hub_core::alerts, which joins Prometheus, the watches' state files, fleet-bench
// reds and the agent-notify ledger). The page is the layout's inner tabs (hub_core::layout, app.js
// INNER_TABS): the strip, Health pinned under it, then Firing, Fixes, Watches and History, each
// label counted by the reader (`strip`). Firing, Watches and History are each the shared table
// (table.js), so the server filters and sorts them; a firing row opens what the watch checks, where, what to do and its
// last probe output, and a rule firing in many places opens its alerts. A source that could not
// be read is an error line, never an empty section.

// A watch's state change and a queue change push (main.rs classify); Prometheus does not, so the
// open tab also re-reads on its rules' cadence, as Infra does.
const ALERTS_REFRESH_MS = 60e3;
const ALERT_COLS = { sev: ["sev"], what: ["what"], project: ["project"], source: ["source"], since: ["since", "n"], owner: ["owner"], state: ["state"] };
// Each section's fold, kept across the redraw on every read; a section with no entry is open.
const alertsOpen = {};
// Three tables share the tab, so Watches' view keys carry this prefix (wq, ws, wsort, wdir) in the
// URL and in /api/alerts, and History's `h`; Firing came first and keeps the plain ones, so links
// to it stay valid.
const WATCH_PRE = "w", HIST_PRE = "h";
// One read draws all three: Firing's tblTab reads and paints the page, the other two draw after
// Fixes inside it.
const alst = tblTab({
  tab: "alerts", id: "al", el: "alerts", api: "/api/alerts", hint: "search, or project:dotfiles source:sentinel state:no owner",
  open: () => alertsOpen,
  lead: () => innerStrip("alerts"),
  params: (p) => { for (const pre of [WATCH_PRE, HIST_PRE]) for (const [k, v] of tblParams(st.views.alerts, pre)) p.set(k, v); },
  head: (t) => alertsHead(t.data), wrap: (html) => innerWrap("alerts", "firing", alertsFold("firing", "Firing", alst.data?.counts?.firing, ALERT_HUE[alst.data?.level], html)),
  body: (t) => alertsBody(t.data), tail: (t) => alertsFixes(t.data),
  draw: (html) => paint($("alerts"), html + watT.html() + hisT.html(), alertsOpen),
});
const watT = tblTab({
  tab: "alerts", id: "al-w", el: "alerts", pre: WATCH_PRE, hint: "search, or project:dotfiles severity:high", open: () => alertsOpen,
  refresh: () => alst.refresh(), render: () => alst.render(), table: () => alst.data?.watches_table,
  wrap: (html) => alertsWatches(alst.data, html), body: () => watchesBody(alst.data),
});
const hisT = tblTab({
  tab: "alerts", id: "al-h", el: "alerts", pre: HIST_PRE, hint: "search, or verb:tripped", open: () => alertsOpen,
  refresh: () => alst.refresh(), render: () => alst.render(), table: () => alst.data?.history_table,
  wrap: (html) => alertsHistory(alst.data, html), body: () => historyBody(alst.data),
});
// A search or dropdown in use in one table keeps its focus: only that table repaints around it,
// and the other two redraw, so a search in one never leaves the others stale (Home's renderHome).
const alertsPaint = alst.render;
alst.render = () => {
  const all = [alst, watT, hisT], busy = all.find((t) => t.repaint());
  if (!busy) { alertsPaint(); return; }
  for (const t of all) if (t !== busy) t.redraw();
};

// A section as a fold, open unless the human folded it. The id is the `#alerts/<id>` anchor;
// title, its count n and its level make the head.
function alertsFold(k, title, n, level, inner) {
  const on = alertsOpen[k] ?? true;
  return `<details class="sec-d" id="sec-${k}" data-k="${k}"${on ? " open" : ""}><summary>${secHead("", title, n, level)}</summary>${inner}</details>`;
}

const ALERT_HUE = { red: "bad", warn: "warn", ok: "ok", nodata: "" };
const ALERT_LEVEL = { red: "FIRING", warn: "WARN", ok: "ALL CLEAR", nodata: "NO DATA" };
// A health chip's level as Home's strip words it.
const HEALTH_WORD = { red: "RED", warn: "WARN", ok: "OK", nodata: "NO DATA" };
const alertState = (s) => (s === "error" || s === "no owner" || s === "unfixed" ? "bad" : s === "fixing" || s === "queued" ? "running" : "");
// Source, what and where: one Alertmanager rule fires once per place, under one summary.
const alertKey = (a) => `${a.source}|${a.what}|${a.place}`;

// The inner tabs, the tab's level, then each source it could not read. When it was read is a fact
// in Health's box.
function alertsHead(d) {
  const lvl = d.level || "nodata";
  let html = innerStrip("alerts", [], d.strip) + `<div class="bhead"><span>${cchip(ALERT_HUE[lvl], ALERT_LEVEL[lvl])}</span></div>`;
  if (alst.err) html += `<div class="panel down">${esc(alst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  const chips = d.health || [];
  const worst = chips.some((c) => c.level === "red") ? "bad" : chips.some((c) => c.level !== "ok") ? "warn" : "";
  return html + innerWrap("alerts", "health", alertsFold("health", "Health", chips.length || null, worst, alertsHealthChips(d)));
}

// Every domain with its hue, the not-green ones first, then why: each component that is not green.
function alertsHealthChips(d) {
  const chips = d.health || [], read = `<div class="cline"><b>read</b> ${d.at ? clock(d.at * 1e3) : "-"}</div>`;
  if (!chips.length) return `<div class="panel muted">No health: Prometheus did not answer.${read}</div>`;
  const rank = { red: 0, warn: 1, nodata: 2, ok: 3 };
  const line = [...chips].sort((a, b) => rank[a.level] - rank[b.level]).map((c) => cchip(ALERT_HUE[c.level], `${esc(c.name)} ${HEALTH_WORD[c.level]}`)).join(" ");
  const why = (d.components || []).map((c) => `<div>${cchip(ALERT_HUE[c.level], HEALTH_WORD[c.level])} ${esc(c.domain)}/${esc(c.name)}</div>`).join("");
  return `<div class="panel"><div class="cline">${line}</div>${why}${read}</div>`;
}

function alertRow(a) {
  const open = alertKey(a) === alst.sel;
  const owner = a.slug ? `<a href="${esc("#queue?q=" + encodeURIComponent(a.slug))}">${esc(a.owner)}</a>` : esc(a.owner);
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(alertKey(a))}">` +
    `<td class="${a.sev === "urgent" || a.sev === "high" ? "bad" : "muted"}">${esc(a.sev || "-")}</td><td class="wrap">${esc(a.what)}${alertCount(a)}</td>` +
    `<td class="muted">${esc(a.project || "-")}</td><td class="muted">${esc(a.source)}</td><td class="n">${a.since ? ago(a.since) : "-"}</td><td class="wrap">${owner}</td>` +
    `<td>${cchip(alertState(a.state), esc(a.state))}</td></tr>`;
  return open ? row + alertDetail(a) : row;
}

// An Alertmanager rule beside its name: its one alert's summary, or how many alerts it has.
function alertCount(a) {
  const pages = a.pages || [];
  if (pages.length > 1) return ` <span class="muted">(${pages.length} alerts)</span>`;
  return pages.length && pages[0].what !== a.what ? ` <span class="muted">${esc(pages[0].what)}</span>` : "";
}

function alertDetail(a) {
  if ((a.pages || []).length) return alertPages(a);
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${esc(v)}</div>` : "");
  const pr = a.pr_url ? `<div class="cline"><a href="${esc(a.pr_url)}" target="_blank" rel="noopener">Open the fix PR</a></div>` : "";
  const ev = a.evidence ? `<pre class="joblog">${esc(a.evidence)}</pre>` : "";
  const none = a.about || a.place || a.action || ev ? "" : `<div class="muted">No watch file says more: ${esc(a.source)} reports only that it is red.</div>`;
  return `<tr class="wdet"><td colspan="7"><div class="sdet">` + line("What it checks", a.about) + line("Where", a.place) +
    line("What to do", a.action) + pr + ev + none + `</div></td></tr>`;
}

function alertsBody(d) {
  const t = d.table, rows = d.rows || [];
  return rows.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, ALERT_COLS)}${rows.map(alertRow).join("")}</table></div>`
    : `<div class="panel">${t.total ? "No firing row matches." : "Nothing is firing."}</div>`;
}

// An opened rule: what its alerts all say (hub_core::alerts::am_rows), then each place it fires,
// worst first, with the description and what to do that are that alert's own.
function alertPages(a) {
  const own = (p) => [!a.about && p.about, !a.action && p.action].filter(Boolean).map((t) => `<div class="muted">${esc(t)}</div>`).join("");
  const rows = a.pages.map((p) => `<tr><td class="${p.sev === "high" ? "bad" : "muted"}">${esc(p.sev)}</td><td class="wrap">${esc(p.what)}${own(p)}</td>` +
    `<td class="wrap muted">${esc(p.place || "-")}</td><td class="n">${p.since ? ago(p.since) : "-"}</td></tr>`).join("");
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${esc(v)}</div>` : "");
  return `<tr class="wdet"><td colspan="7"><div class="sdet">` + line("What it checks", a.about) + line("What to do", a.action) +
    `<table class="tbl"><tr><th data-role="glance">sev</th><th data-role="lead">alert</th><th>where</th><th class="n" data-role="glance">since</th></tr>${rows}</table></div></td></tr>`;
}

// Fixes: each red the triage queued as a fix in the window, open worst first; the settled fold to a count.
const ALERTS_FIX_COLOR = { "came back": "var(--b-needs)", "still red": "var(--b-needs)", "no fix": "var(--b-needs)", "needs merge": "var(--b-stalled)",
  fixing: "var(--b-working)", queued: "var(--b-working)", fixed: "var(--b-done)", cleared: "var(--b-done)" };
function alertsFixRow(r) {
  const pr = !r.pr ? "" : r.pr_url ? `<a href="${esc(r.pr_url)}" target="_blank" rel="noopener">PR ${esc(r.pr)}</a>` : `<span class="by">PR ${esc(r.pr)}</span>`;
  return `<div class="pr"><span class="chip sm" style="--c:${ALERTS_FIX_COLOR[r.outcome] || "var(--c-other)"}">${esc(r.outcome.toUpperCase())}</span>` +
    `<span class="pt">${esc(r.red)}</span>${r.project ? `<span class="by">${esc(r.project)}</span>` : ""}<span class="by">${esc(r.slug)}</span>${pr}<span class="by">${r.queued ? ago(r.queued) : "-"}</span></div>`;
}

function alertsFixes(d) {
  const r = d.fixes, failed = (d.errors || []).some((e) => e.startsWith("fleet-bench reds:"));
  const open = r.open.length ? `<div class="panel">${r.open.slice(0, LOG_ROWS).map(alertsFixRow).join("")}</div>` +
    (r.open.length > LOG_ROWS ? `<div class="muted more">+${r.open.length - LOG_ROWS} more</div>` : "") : "";
  const settled = r.settled.length ? `<details class="sec-d" data-k="fixes-settled"${alertsOpen["fixes-settled"] ? " open" : ""}><summary class="muted fold">+${r.settled.length} settled</summary><div class="panel">${r.settled.map(alertsFixRow).join("")}</div></details>` : "";
  const empty = failed ? `<div class="panel down">Could not read the fixes.</div>` : open || settled ? "" : `<div class="panel muted">No red was queued as a fix this week.</div>`;
  return innerWrap("alerts", "fixes", alertsFold("fixes", "Fixes", failed ? null : r.open.length, failed ? "bad" : "", open + settled + empty));
}

// History: Sentinel's pages of the window, newest first; every sender's are on Log's Actions. The
// head counts the window, the table the pages the reader kept.
const HIST_COLS = { when: ["when", "n"], verb: ["verb"], text: ["text"] };
function historyBody(d) {
  const t = d.history_table, rows = d.history || [], older = d.counts.history_older;
  const more = older ? `<div class="muted more">+${older} older on <a href="#log/actions">Log</a></div>` : "";
  return (rows.length ? `<div class="panel scroll"><table class="tbl">${tblHead(t, HIST_COLS)}${rows.map((a) =>
    `<tr><td class="n">${stamp(a.at)}</td><td class="muted">${esc(a.verb)}</td><td class="wrap">${esc(a.text)}</td></tr>`).join("")}</table></div>`
    : `<div class="panel muted">${t.total ? "No page matches." : "No alert paged this week."}</div>`) + more;
}
const alertsHistory = (d, html) => innerWrap("alerts", "history",
  alertsFold("history", "History", d.counts.history + d.counts.history_older, "", `<div data-tbl="${HIST_PRE}">${html}</div>`));

// Watches: every one, tripped and failing first (the reader's order). The state tiles say how many
// tripped or failed and filter to them, so the head is its title and count alone.
const WATCH_COLS = { name: ["watch"], state: ["state"], severity: ["severity"], project: ["project"], since: ["since", "n"], lastrun: ["last run", "n"], place: ["where"] };
function watchesBody(d) {
  const t = d.watches_table, rows = d.watches || [];
  const cls = (w) => (w.state === "TRIP" || w.state === "ERROR" ? "bad" : w.state === "OK" ? "" : "muted");
  return rows.length ? `<div class="panel scroll"><table class="tbl">${tblHead(t, WATCH_COLS)}` +
    rows.map((w) => `<tr><td>${esc(w.name)}</td><td class="${cls(w)}">${esc(w.state)}</td><td class="muted">${esc(w.severity || "-")}</td><td class="muted">${esc(w.project || "-")}</td>` +
      `<td class="n">${when(w.since)}</td><td class="n">${when(w.lastrun)}</td><td class="wrap muted">${esc(w.place || "-")}</td></tr>`).join("") + `</table></div>`
    : `<div class="panel muted">${t.total ? "No watch matches." : "No watch defined."}</div>`;
}
function alertsWatches(d, html) {
  const c = d.counts;
  return innerWrap("alerts", "watches", alertsFold("watches", "Watches", c.watches, c.watches_tripped || c.watches_error ? "warn" : "", `<div data-tbl="${WATCH_PRE}">${html}</div>`));
}

$("alerts").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest("details:not(.sec-d)") || t.closest("summary")) return;
  const tr = t.closest("tr.jr");
  if (!tr || !alst.data) return;
  alst.sel = alst.sel === tr.dataset.key ? null : tr.dataset.key;
  alst.render();
});

const pollAlerts = poll("alerts", alst.refresh, ALERTS_REFRESH_MS);
const ALERTS_KINDS = ["alerts", "actions", "queue", "resync"];
TABS.alerts = {
  show() { alst.render(); pollAlerts(); },
  onEvent(ev) { if (ALERTS_KINDS.includes(ev.kind) && st.tab === "alerts") alst.refresh(); },
};
