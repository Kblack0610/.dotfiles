"use strict";
// Infra's Jobs section (agent-web's Jobs tab until phase 4): every job that runs on its own (agentctl runners, user timers, Unity gates,
// k8s CronJobs; CI runs are one count line linking to Infra's CI runs), from /api/jobs, and one run's log from /api/jobs/log. The table is the
// shared one (table.js): the server filters and sorts by the view in Infra's URL query.

// Most sources are files and journald, which push nothing to a browser, so the open tab
// re-reads on the Infra board's cadence while Infra is open; the server folds reads inside 15s into one.
const JOBS_REFRESH_MS = 60e3;
// Unity gates alone finish about a thousand runs a day, so the table stops here until asked.
const JOBS_OPEN = 200;
// `#infra/jobs/<name>` (hub_core::links Kind::Job) lists every run of that one job instead of the
// folded list; `hist` is the name the rows on hand were read for.
const jobName = () => pageId("infra", "jobs");
const jst = tblTab({
  tab: "infra", id: "jobs", api: "/api/jobs", hint: "search, or source:unity result:fail host:workstation",
  state: { hist: "", log: null, all: false },
  params: (p) => { if (jobName()) p.set("name", jobName()); },
  head: (t) => jobsHead(t.data), body: (t) => jobsBody(t.data), tail: () => jobsTail(),
  tiles: (t) => jobsTiles(t.data),
});
// When the list was read and the window it covers, after the state tiles.
const jobsTiles = (d) => tile("READ", d.at ? clock(d.at * 1e3) : "-", "var(--c-other)", `last ${Math.round((d.window_secs || 86400) / 3600)}h`);

const jobKey = (j) => `${j.source}|${j.name}|${j.started ?? ""}|${j.finished ?? ""}|${j.state}`;


function resultCell(j) {
  if (j.state === "running") return `<td class="muted">running</td>`;
  if (j.state === "queued") return `<td class="warn">${esc(j.result || "waiting")}</td>`;
  const cls = j.ok === false ? "bad" : j.ok === true ? "" : "muted";
  return `<td class="${cls}">${esc(j.result || "-")}</td>`;
}

function jobRow(j, n) {
  const k = jobKey(j), L = tblLinks(jst.data.table, n);
  const dur = j.state === "queued" ? `wait ${secs(j.secs)}` : secs(j.secs);
  const runs = j.runs > 1 && L.name ? ` <a href="${esc(L.name)}" class="muted" title="every run of this job">${j.runs} runs</a>` : "";
  const next = j.next ? ` <span class="muted">next ${when(j.next)}</span>` : "";
  const link = j.url ? ` <a href="${esc(j.url)}" target="_blank" rel="noopener">Open run</a>` : "";
  return `<tr class="jr${k === jst.sel ? " sel" : ""}${j.log ? " haslog" : ""}" data-key="${esc(k)}">` +
    `<td>${j.state === "queued" ? "waiting" : esc(j.state)}</td><td class="muted">${esc(j.source)}</td><td class="wrap">${esc(j.name)}${runs}${link}</td>` +
    `<td class="n">${when(j.started)}</td><td class="n">${dur}</td>${resultCell(j)}` +
    `<td class="muted">${tblLink(L.host, j.host)}</td><td class="wrap muted">${esc(j.detail || "")}${next}</td></tr>`;
}

const JOB_COLS = { state: ["state"], source: ["source"], name: ["name"], started: ["started", "n"], took: ["took", "n"], result: ["result"], host: ["host"], detail: ["detail"] };

// A job's page names the job it lists, with the way back to every job.
function jobsBody(d) {
  const t = d.table, shown = d.jobs || [];
  const rows = jst.all ? shown : shown.slice(0, JOBS_OPEN);
  const more = shown.length - rows.length;
  const page = jobName() ? `<div class="cline">Every run of <b>${esc(jobName())}</b> <a class="btn sm" href="#infra/jobs">All jobs</a></div>` : "";
  return page + (shown.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, JOB_COLS)}${rows.map(jobRow).join("")}</table>` +
      tblMore(more) + `</div>`
    : `<div class="panel">${t.total ? "No jobs match." : "No jobs in the window."}</div>`);
}

function jobsHead(d) {
  const t = d.table;
  let html = secHead("jobs", "Jobs", tblCount(t));
  if (d.ci) html += `<div class="cline">CI: <a class="${d.ci.level === "ok" ? "" : d.ci.level}" href="#infra/runs">${esc(d.ci.says)}</a></div>`;
  if (jst.err) html += `<div class="panel down">${esc(jst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

const jobsTail = () => `<div class="muted fold">A runner or timer that ran more than once shows its latest run plus every failure; its N runs lists them all. Click a row for its log.</div>` +
  (jst.log ? `${secHead("", "Log")}<div class="panel">${pageRow("Job", esc(jst.log.title))}<pre class="joblog">${esc(jst.log.text)}</pre></div>` : "");

// A job's log through /api/jobs/log (its byte range for an agentctl run), or why it has none.
// A runner's page (Sessions, Runners) reads its runs' logs here too.
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
  jst.render();
  log.text = await jobLogText(j);
  if (st.tab === "infra") jst.render();
}

$("jobs").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a")) return;
  const row = t.closest("tr.jr");
  if (!row) return;
  const j = (jst.data.jobs || []).find((x) => jobKey(x) === row.dataset.key);
  if (j) openLog(j);
});

// Shown and refreshed by TABS.infra (infra.js): another job's page drops the rows read for the last.
const pollJobs = poll("infra", jst.refresh, JOBS_REFRESH_MS);
function showJobs() {
  if (jobName() !== jst.hist) Object.assign(jst, { hist: jobName(), data: null, sel: null, log: null, all: false });
  jst.render();
  pollJobs();
}
