"use strict";
// Infra's Jobs section (agent-web's Jobs tab until phase 4): every job that runs on its own (agentctl runners, user timers, Unity gates,
// CI, k8s CronJobs), from /api/jobs, and one run's log from /api/jobs/log. The table is the
// shared one (table.js): the server filters and sorts by the view in Infra's URL query.

// Most sources are files and journald, which push nothing to a browser, so the open tab
// re-reads on the Infra board's cadence while Infra is open; the server folds reads inside 15s into one.
const JOBS_REFRESH_MS = 60e3;
// Unity gates alone finish about a thousand runs a day, so the table stops here until asked.
const JOBS_OPEN = 200;
// `hist` is the one job whose every run is listed instead of the folded list.
const jst = { data: null, err: null, hist: null, sel: null, log: null, all: false };

const jobKey = (j) => `${j.source}|${j.name}|${j.started ?? ""}|${j.finished ?? ""}|${j.state}`;

const refreshJobs = coalesce(async () => {
  const p = tblParams(st.views.infra);
  if (jst.hist) p.set("name", jst.hist);
  const q = p.toString();
  try { jst.data = await api("/api/jobs" + (q ? "?" + q : "")); jst.err = null; } catch (e) { jst.err = e.message; }
  if (st.tab === "infra") renderJobs();
});


function resultCell(j) {
  if (j.state === "running") return `<td class="muted">running</td>`;
  if (j.state === "queued") return `<td class="warn">${esc(j.result || "waiting")}</td>`;
  const cls = j.ok === false ? "bad" : j.ok === true ? "" : "muted";
  return `<td class="${cls}">${esc(j.result || "-")}</td>`;
}

function jobRow(j) {
  const k = jobKey(j);
  const dur = j.state === "queued" ? `wait ${secs(j.secs)}` : secs(j.secs);
  const runs = j.runs > 1 ? ` <a href="#" class="muted" data-hist="${esc(j.name)}" title="every run of this job">${j.runs} runs</a>` : "";
  const next = j.next ? ` <span class="muted">next ${when(j.next)}</span>` : "";
  const link = j.url ? ` <a href="${esc(j.url)}" target="_blank" rel="noopener">Open run</a>` : "";
  return `<tr class="jr${k === jst.sel ? " sel" : ""}${j.log ? " haslog" : ""}" data-key="${esc(k)}">` +
    `<td>${esc(j.state)}</td><td class="muted">${esc(j.source)}</td><td class="wrap">${esc(j.name)}${runs}${link}</td>` +
    `<td class="n">${when(j.started)}</td><td class="n">${dur}</td>${resultCell(j)}` +
    `<td class="wrap muted">${esc(j.detail || "")}${next}</td></tr>`;
}

const JOB_COLS = { state: ["state"], source: ["source"], name: ["name"], started: ["started", "n"], took: ["took", "n"], result: ["result"], detail: ["detail"] };

function jobsBody(d) {
  const t = d.table, shown = d.jobs || [];
  const rows = jst.all ? shown : shown.slice(0, JOBS_OPEN);
  const more = shown.length - rows.length;
  return shown.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, JOB_COLS)}${rows.map(jobRow).join("")}</table>` +
      (more ? `<button class="btn sm" data-all="1">+${more} older</button>` : "") + `</div>`
    : `<div class="panel">${t.total ? "No jobs match." : "No jobs in the window."}</div>`;
}

function jobsHead(d) {
  const hours = Math.round((d.window_secs || 86400) / 3600);
  let html = `<h2 class="sec" id="sec-jobs">Jobs ${jst.hist ? `<span>every run of <b>${esc(jst.hist)}</b> <a href="#" data-hist="">back to all</a></span>` : ""}` +
    ` <span class="muted">${d.table.shown} of ${d.table.total} in ${hours}h, read ${d.at ? clock(d.at * 1e3) : "-"}</span></h2>`;
  if (jst.err) html += `<div class="panel down">${esc(jst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

const jobsTail = () => `<div class="muted fold">A runner or timer that ran more than once shows its latest run plus every failure; xN lists them all. Click a row for its log.</div>` +
  (jst.log ? `<h2 class="sec">Log <span class="muted">${esc(jst.log.title)}</span></h2><pre class="panel joblog">${esc(jst.log.text)}</pre>` : "");

function renderJobs() {
  const el = $("jobs");
  const d = jst.data;
  if (!d || !d.table) {
    const why = jst.err || (d?.errors || [])[0];
    el.innerHTML = `<div class="empty">${why ? esc(why) : "Loading..."}</div>`;
    return;
  }
  if (tblRepaint("jobs", d.table, () => jobsBody(d))) {
    paint($("jobs-head"), jobsHead(d));
    paint($("jobs-tail"), jobsTail());
    return;
  }
  paint(el, `<div id="jobs-head">${jobsHead(d)}</div>${tblBar("jobs", d.table, "search, or source:ci result:fail -name:dream")}` +
    `<div id="jobs-body">${jobsBody(d)}</div><div id="jobs-tail">${jobsTail()}</div>`);
  seekSection();
}

// The view changed: the URL follows it and the server applies it.
function jobsView(patch) {
  setQuery(tblSet(st.views.infra, patch));
  jst.all = false;
  refreshJobs();
}

// A job's log through /api/jobs/log (its byte range for an agentctl run), or why it has none.
// The Fleet tab's runner page reads its runs' logs here too.
async function jobLogText(j) {
  if (!j.log) return j.url ? `No log here; the job's page: ${j.url}` : "This job keeps no log.";
  try {
    return await api("/api/jobs/log?ref=" + encodeURIComponent(JSON.stringify(j.log))) || "(empty)";
  } catch (e) {
    return "Could not read the log: " + e.message;
  }
}

async function openLog(j) {
  jst.sel = jobKey(j);
  const log = jst.log = { title: `${j.source} ${j.name} ${when(j.started)}`, text: "Loading..." };
  renderJobs();
  log.text = await jobLogText(j);
  if (st.tab === "infra") renderJobs();
}

$("jobs").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a[target]")) return;
  const h = t.closest("[data-hist]");
  if (h) { e.preventDefault(); jst.hist = h.dataset.hist || null; jst.data = null; renderJobs(); refreshJobs(); return; }
  if (t.dataset.all) { jst.all = true; renderJobs(); return; }
  const v = tblPatch(e);
  if (v) { jobsView(v); return; }
  const row = t.closest("tr.jr");
  if (!row) return;
  const j = (jst.data.jobs || []).find((x) => jobKey(x) === row.dataset.key);
  if (j) openLog(j);
});
tblListen($("jobs"), jobsView);

// Shown and refreshed by TABS.infra (infra.js).
const pollJobs = poll("infra", refreshJobs, JOBS_REFRESH_MS);
