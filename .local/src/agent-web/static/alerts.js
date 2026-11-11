"use strict";
// The Alerts tab: what is firing, who owns its fix, what fired lately and every watch, from
// /api/alerts (hub_core::alerts, which joins Prometheus, the watches' state files, fleet-bench
// reds and the agent-notify ledger). The firing rows are the shared table (table.js), so the
// server filters and sorts them; a row opens what the watch checks, where, what to do and its
// last probe output. A source that could not be read is an error line, never an empty section.

// A watch's state change and a queue change push (main.rs classify); Prometheus does not, so the
// open tab also re-reads on its rules' cadence, as Infra does.
const ALERTS_REFRESH_MS = 60e3;
const ALERT_COLS = { sev: ["sev"], what: ["what"], source: ["source"], since: ["since", "n"], owner: ["owner"], state: ["state"] };
// Each section's fold, kept across the redraw on every read; a section with no entry is open.
const alertsOpen = {};
const alst = tblTab({
  tab: "alerts", id: "al", el: "alerts", api: "/api/alerts", hint: "search, or source:sentinel state:no owner",
  open: () => alertsOpen,
  head: (t) => alertsHead(t.data), wrap: (html) => alertsFold("firing", alertsFiringTitle(alst.data), html, true),
  body: (t) => alertsBody(t.data), tail: (t) => alertsTail(t.data),
});

// A section as a fold: open unless the human folded it, or `open` is false (Watches with nothing
// tripped). The id is the `#alerts/<id>` anchor.
function alertsFold(k, title, inner, open) {
  const on = alertsOpen[k] ?? open;
  return `<details class="sec-d" id="sec-${k}" data-k="${k}"${on ? " open" : ""}><summary><h2 class="sec">${title}</h2></summary>${inner}</details>`;
}

const ALERT_HUE = { red: "bad", warn: "warn", ok: "ok", nodata: "" };
const ALERT_LEVEL = { red: "FIRING", warn: "WARN", ok: "ALL CLEAR", nodata: "NO DATA" };
// A health chip's level as Home's strip words it.
const HEALTH_WORD = { red: "RED", warn: "WARN", ok: "OK", nodata: "NO DATA" };
const alertState = (s) => (s === "error" || s === "no owner" || s === "unfixed" ? "bad" : s === "fixing" || s === "queued" ? "running" : "");
// Source, what and where: one Alertmanager rule fires once per place, under one summary.
const alertKey = (a) => `${a.source}|${a.what}|${a.place}`;

function alertsFiringTitle(d) {
  const c = d?.counts;
  if (!c) return "Firing";
  return `Firing <span class="muted">${c.firing}: ${c.tripped} trip, ${c.errors} error, ${c.no_owner} no owner, ${c.alertmanager} alertmanager</span>`;
}

function alertsHead(d) {
  const c = d.counts, lvl = d.level || "nodata";
  let html = `<div class="bhead"><span>${cchip(ALERT_HUE[lvl], ALERT_LEVEL[lvl])} <span class="muted">read ${d.at ? clock(d.at * 1e3) : "-"}</span></span>` +
    `<span class="muted">${c.fixes_open} open fixes, ${c.watches} watches</span></div>`;
  if (alst.err) html += `<div class="panel down">${esc(alst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html + alertsFold("health", `Health <span class="muted">${alertsHealthWord(d.health)}</span>`, alertsHealthChips(d), true);
}

// Every domain with its hue, the not-green ones first, then why: each component that is not green.
function alertsHealthWord(chips) {
  const bad = (chips || []).filter((c) => c.level !== "ok").length;
  return chips?.length ? (bad ? `${bad} not green of ${chips.length}` : `all green (${chips.length})`) : "no data";
}

function alertsHealthChips(d) {
  const chips = d.health || [];
  if (!chips.length) return `<div class="panel muted">No health: Prometheus did not answer.</div>`;
  const rank = { red: 0, warn: 1, nodata: 2, ok: 3 };
  const line = [...chips].sort((a, b) => rank[a.level] - rank[b.level]).map((c) => cchip(ALERT_HUE[c.level], `${esc(c.name)} ${HEALTH_WORD[c.level]}`)).join(" ");
  const why = (d.components || []).map((c) => `<div>${cchip(ALERT_HUE[c.level], HEALTH_WORD[c.level])} ${esc(c.domain)}/${esc(c.name)}</div>`).join("");
  return `<div class="panel"><div class="cline">${line}</div>${why}</div>`;
}

function alertRow(a) {
  const open = alertKey(a) === alst.sel;
  const owner = a.slug ? `<a href="${esc("#queue?q=" + encodeURIComponent(a.slug))}">${esc(a.owner)}</a>` : esc(a.owner);
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(alertKey(a))}">` +
    `<td class="${a.sev === "urgent" || a.sev === "high" ? "bad" : "muted"}">${esc(a.sev || "-")}</td><td class="wrap">${esc(a.what)}</td>` +
    `<td class="muted">${esc(a.source)}</td><td class="n">${a.since ? ago(a.since) : "-"}</td><td class="wrap">${owner}</td>` +
    `<td>${cchip(alertState(a.state), esc(a.state))}</td></tr>`;
  return open ? row + alertDetail(a) : row;
}

function alertDetail(a) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${esc(v)}</div>` : "");
  const pr = a.pr_url ? `<div class="cline"><a href="${esc(a.pr_url)}" target="_blank" rel="noopener">Open the fix PR</a></div>` : "";
  const ev = a.evidence ? `<pre class="joblog">${esc(a.evidence)}</pre>` : "";
  const none = a.about || a.place || a.action || ev ? "" : `<div class="muted">No watch file says more: ${esc(a.source)} reports only that it is red.</div>`;
  return `<tr class="wdet"><td colspan="6"><div class="sdet">` + line("What it checks", a.about) + line("Where", a.place) +
    line("What to do", a.action) + pr + ev + none + `</div></td></tr>`;
}

function alertsBody(d) {
  const t = d.table, rows = d.rows || [];
  return rows.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, ALERT_COLS)}${rows.map(alertRow).join("")}</table></div>`
    : `<div class="panel">${t.total ? "No firing row matches." : "Nothing is firing."}</div>`;
}

// Fixes: each red the triage queued as a fix in the window, open worst first; the settled fold to a count.
const ALERTS_FIX_COLOR = { "came back": "var(--b-needs)", "still red": "var(--b-needs)", "no fix": "var(--b-needs)", "needs merge": "var(--b-stalled)",
  fixing: "var(--b-working)", queued: "var(--b-working)", fixed: "var(--b-done)", cleared: "var(--b-done)" };
function alertsFixRow(r) {
  const pr = !r.pr ? "" : r.pr_url ? `<a href="${esc(r.pr_url)}" target="_blank" rel="noopener">PR ${esc(r.pr)}</a>` : `<span class="by">PR ${esc(r.pr)}</span>`;
  return `<div class="pr"><span class="chip sm" style="--c:${ALERTS_FIX_COLOR[r.outcome] || "var(--c-other)"}">${esc(r.outcome.toUpperCase())}</span>` +
    `<span class="pt">${esc(r.red)}</span><span class="by">${esc(r.slug)}</span>${pr}<span class="by">${r.queued ? ago(r.queued) : "-"}</span></div>`;
}

function alertsFixes(d) {
  const r = d.fixes, failed = (d.errors || []).some((e) => e.startsWith("fleet-bench reds:"));
  const title = `Fixes <span class="muted">${failed ? "read failed" : esc(r.summary || `${r.open.length} open`)}</span>`;
  const open = r.open.length ? `<div class="panel">${r.open.slice(0, LOG_ROWS).map(alertsFixRow).join("")}</div>` +
    (r.open.length > LOG_ROWS ? `<div class="muted more">+${r.open.length - LOG_ROWS} more</div>` : "") : "";
  const settled = r.settled.length ? `<details class="sec-d" data-k="fixes-settled"${alertsOpen["fixes-settled"] ? " open" : ""}><summary class="muted fold">+${r.settled.length} settled</summary><div class="panel">${r.settled.map(alertsFixRow).join("")}</div></details>` : "";
  const empty = failed ? "" : open || settled ? "" : `<div class="panel muted">No red was queued as a fix this week.</div>`;
  return alertsFold("fixes", title, open + settled + empty, true);
}

// History: Sentinel's pages of the window, newest first; every sender's are on Log's Actions.
function alertsHistory(d) {
  const c = d.counts, rows = d.history || [];
  const body = rows.length ? `<div class="panel scroll"><table class="tbl"><tr><th class="n" data-role="glance">when</th><th data-role="glance">verb</th><th data-role="lead">text</th></tr>${rows.map((a) =>
    `<tr><td class="n">${stamp(a.at)}</td><td class="muted">${esc(a.verb)}</td><td class="wrap">${esc(a.text)}</td></tr>`).join("")}</table></div>` +
    (c.history_older ? `<div class="muted more">+${c.history_older} older on <a href="#log/actions">Log</a></div>` : "")
    : `<div class="panel muted">No alert paged this week.</div>`;
  return alertsFold("history", `History <span class="muted">${c.history + c.history_older} pages in 7 days</span>`, body, true);
}

// Watches: every one, tripped and failing first; folded to its count when none is.
function alertsWatches(d) {
  const c = d.counts, cls = (w) => (w.state === "TRIP" || w.state === "ERROR" ? "bad" : w.state === "OK" ? "" : "muted");
  const rows = (d.watches || []).map((w) => `<tr><td>${esc(w.name)}</td><td class="${cls(w)}">${esc(w.state)}</td><td class="muted">${esc(w.severity || "-")}</td>` +
    `<td class="n">${when(w.since)}</td><td class="n">${when(w.lastrun)}</td><td class="wrap muted">${esc(w.place || "-")}</td></tr>`).join("");
  const body = rows ? `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">watch</th><th data-role="glance">state</th><th>severity</th><th class="n" data-role="glance">since</th><th class="n">last run</th><th>where</th></tr>${rows}</table></div>`
    : `<div class="panel muted">No watch defined.</div>`;
  const title = `Watches <span class="muted">${c.watches}: ${c.watches_tripped} tripped, ${c.watches_error} error, ${c.watches_ok} ok, ${c.watches_new} new</span>`;
  return alertsFold("watches", title, body, !d.watches_folded);
}

const alertsTail = (d) => alertsFixes(d) + alertsHistory(d) + alertsWatches(d);

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
