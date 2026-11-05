"use strict";
// Infra's Jobs section (agent-web's Jobs tab until phase 4): every job that runs on its own (agentctl runners, user timers, Unity gates,
// CI, k8s CronJobs), from /api/jobs, and one run's log from /api/jobs/log.

// Most sources are files and journald, which push nothing to a browser, so the open tab
// re-reads on the Infra board's cadence while Infra is open; the server folds reads inside 15s into one.
const JOBS_REFRESH_MS = 60e3;
const JOB_SOURCES = ["agentctl", "timer", "unity", "ci", "k8s"];
const JOB_STATES = ["running", "queued", "done"];
// Unity gates alone finish about a thousand runs a day, so the table stops here until asked.
const JOBS_OPEN = 200;
// `hist` is the one job whose every run is listed instead of the folded list.
const jst = { data: null, err: null, src: "", state: "", hist: null, sel: null, log: null, all: false };

const jobKey = (j) => `${j.source}|${j.name}|${j.started ?? ""}|${j.finished ?? ""}|${j.state}`;

const refreshJobs = coalesce(async () => {
  const q = jst.hist ? `?name=${encodeURIComponent(jst.hist)}` : "";
  try { jst.data = await api("/api/jobs" + q); jst.err = null; } catch (e) { jst.err = e.message; }
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

function chips(list, cur, attr) {
  return ["", ...list].map((v) => `<button class="btn sm${v === cur ? " primary" : ""}" ${attr}="${v}">${v || "all"}</button>`).join(" ");
}

function renderJobs() {
  const el = $("jobs");
  const d = jst.data;
  if (!d) { el.innerHTML = `<div class="empty">${jst.err ? esc(jst.err) : "Loading..."}</div>`; return; }
  const all = d.jobs || [];
  const n = (f) => all.filter(f).length;
  const shown = all.filter((j) => (!jst.src || j.source === jst.src) && (!jst.state || j.state === jst.state));
  const hours = Math.round((d.window_secs || 86400) / 3600);
  let html = `<h2 class="sec" id="sec-jobs">Jobs ${jst.hist ? `<span>every run of <b>${esc(jst.hist)}</b> <a href="#" data-hist="">back to all</a></span>` : ""}` +
    ` <span class="muted">running ${n((j) => j.state === "running")}, queued ${n((j) => j.state === "queued")}, failed ${n((j) => j.ok === false)} in ${hours}h, read ${d.at ? clock(d.at * 1e3) : "-"}</span></h2>`;
  if (jst.err) html += `<div class="panel down">${esc(jst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  html += `<div class="fold">${chips(JOB_SOURCES, jst.src, "data-src")} &nbsp; ${chips(JOB_STATES, jst.state, "data-state")}</div>`;
  const rows = jst.all ? shown : shown.slice(0, JOBS_OPEN);
  const more = shown.length - rows.length;
  html += shown.length
    ? `<div class="panel scroll"><table class="tbl"><tr><th>state</th><th>source</th><th>name</th><th class="n">started</th><th class="n">took</th><th>result</th><th>detail</th></tr>${rows.map(jobRow).join("")}</table>` +
      (more ? `<button class="btn sm" data-all="1">+${more} older</button>` : "") + `</div>`
    : `<div class="panel">No jobs match.</div>`;
  html += `<div class="muted fold">A runner or timer that ran more than once shows its latest run plus every failure; xN lists them all. Click a row for its log.</div>`;
  if (jst.log) html += `<h2 class="sec">Log <span class="muted">${esc(jst.log.title)}</span></h2><pre class="panel joblog">${esc(jst.log.text)}</pre>`;
  paint(el, html);
  seekSection();
}

async function openLog(j) {
  jst.sel = jobKey(j);
  const title = `${j.source} ${j.name} ${when(j.started)}`;
  if (!j.log) { jst.log = { title, text: j.url ? `No log here; the job's page: ${j.url}` : "This job keeps no log." }; renderJobs(); return; }
  jst.log = { title, text: "Loading..." };
  renderJobs();
  try {
    jst.log.text = await api("/api/jobs/log?ref=" + encodeURIComponent(JSON.stringify(j.log))) || "(empty)";
  } catch (e) {
    jst.log.text = "Could not read the log: " + e.message;
  }
  if (st.tab === "infra") renderJobs();
}

$("jobs").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a[target]")) return;
  const h = t.closest("[data-hist]");
  if (h) { e.preventDefault(); jst.hist = h.dataset.hist || null; jst.data = null; renderJobs(); refreshJobs(); return; }
  if (t.dataset.all) { jst.all = true; renderJobs(); return; }
  if (t.dataset.src != null) { jst.src = t.dataset.src; renderJobs(); return; }
  if (t.dataset.state != null) { jst.state = t.dataset.state; renderJobs(); return; }
  const row = t.closest("tr.jr");
  if (!row) return;
  const j = (jst.data.jobs || []).find((x) => jobKey(x) === row.dataset.key);
  if (j) openLog(j);
});

// Shown and refreshed by TABS.infra (infra.js).
const pollJobs = poll("infra", refreshJobs, JOBS_REFRESH_MS);
