"use strict";
// Infra's Runs, Pipelines and Tests inner tabs, and the run table Releases' Release runs reuses.
// Runs: CI runs of the last 30 days from /api/builds (hub_core::builds); Releases reads the same
// with scope=release (Scope::Release).
// Pipelines: one row per workflow of each repo from /api/pipelines (hub_core::pipelines): its
// state and why, triggers, night membership, next start, last run and times; an opened row reads
// /api/pipelines/detail.
// Tests: one block per declared test workflow (lane) of the picked repo from /api/tests
// (hub_core::junit), each with the suites of its latest nightly unless its run picker names
// another, then the Quarantine table, one row per quarantined test (hub_core::quarantine), from the same read.
// Each is the shared table (table.js) under its own view keys (bq, bs, bsort, bdir; lq, ls, lsort,
// ldir; tq, ts, tsort, tdir, trepo, trun; qq, qs, qsort, qdir), so it sits beside another table
// on its tab. A run's jobs and log, a pipeline's detail and a suite's tests are read when the row
// opens, never before; a run's workflow opens its own page, `#infra/runs/<repo>/<run>`.

const RUNS_PRE = "b";
const RUNS_HINT = "search, or repo:binks state:red owner:agent-3 workflow:Tests release:v1";
// Which folds are open on Infra's CI tables (a run's steps and coverage), so a repaint keeps them.
const CI_OPEN = {};
const BLD_COLS = { started: ["started", "n"], state: ["state"], repo: ["repo"], workflow: ["workflow"], branch: ["branch"], took: ["took", "n"], usual: ["usual", "n"], eta: ["eta", "n"], owner: ["owner"], release: ["release"] };
// A workflow's usual time as "median/p90", "-" below the runs a median needs.
const usualText = (u) => (u ? `${secs(u.median)}/${secs(u.p90)}` : "-");
// A running run's expected end, or once passed how far past it (a past clock reads as on time).
const runEta = (t) => (!t ? "-" : t * 1e3 < Date.now() ? `+${secs(Date.now() / 1e3 - t)}` : when(t));
const bldKey = (r) => `${r.forge}|${r.repo}|${r.id}|${r.attempt}`;

// One run table. `o.tab` and `o.el` are where it draws; `o.render` is the tab's own render when
// it draws inside the tab's page (Releases), else it paints `o.el`. `o.scope` is the read's cut,
// `o.title` its heading, `o.folds` the map its folds keep their state in.
function runsTable(o) {
  const folds = o.folds || CI_OPEN, id = o.id;
  const t = tblTab({
    tab: o.tab, id, pre: RUNS_PRE, el: o.el, api: "/api/builds", hint: RUNS_HINT, state: { log: null, detail: null, jobLog: null },
    params: (p) => { if (o.scope) p.set("scope", o.scope); },
    open: () => folds, head: () => head(t.data), body: () => body(t.data),
    render: o.render || (() => ciPaint(o.el, t)),
    after: o.after,
  });

  function row(r, n) {
    const open = bldKey(r) === t.sel, L = tblLinks(t.data.table, n);
    const wait = r.state === "queued" ? `wait ${secs(r.took)}` : secs(r.took);
    const tr = `<tr class="br${open ? " sel" : ""}" data-bkey="${esc(bldKey(r))}">` +
      `<td class="n">${when(r.started)}</td><td class="${levelClass(r.level)}">${esc(r.state)}</td><td>${tblLink(L.repo, r.repo)}</td>` +
      `<td class="wrap">${tblLink(L.workflow, r.workflow)}</td><td class="wrap muted">${esc(r.branch)}</td><td class="n">${wait}</td>` +
      `<td class="n muted">${usualText(r.usual)}</td><td class="n">${runEta(r.eta)}</td>` +
      `<td class="muted">${esc(r.owner || "-")}</td><td class="muted">${r.release ? `<a href="${esc(r.release.href)}" title="this release as a pipeline">${esc(r.release.tag)}</a>` : "-"}</td></tr>`;
    return open ? tr + `<tr class="wdet"><td colspan="10">${runDetail(r, t, folds)}</td></tr>` : tr;
  }

  function body(d) {
    const v = d.table, rows = d.rows || [];
    if (!rows.length) return `<div class="panel">${v && v.total ? "No runs match." : o.none}</div>`;
    return `<div class="panel scroll"><table class="tbl">${tblHead(v, BLD_COLS)}${rows.map(row).join("")}</table></div>`;
  }

  function head(d) {
    const stale = d.at && Date.now() / 1e3 - d.at > d.stale_after, v = d.table;
    let html = secHead("runs", o.title, v && tblCount(v), stale ? "warn" : "");
    if (stale) html += `<div class="cline warn">ledger older than ${dur(d.stale_after / 60)}</div>`;
    if (t.err) html += `<div class="panel down">${esc(t.err)}</div>`;
    if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
    return html;
  }

  // The whole block, once it has been read.
  t.block = () => {
    if (!t.data) return t.err ? `<div class="panel down">${esc(t.err)}</div>` : secHead("", o.title) + `<div class="empty">Reading...</div>`;
    if (!t.data.table) return `<div id="${id}-head">${head(t.data)}</div>`;
    const b = tblPaged(t.data.table, () => body(t.data));
    return `<div data-tbl="${RUNS_PRE}"><div id="${id}-head">${head(t.data)}</div>${tblBar(id, t.data.table, RUNS_HINT)}<div id="${id}-body">${b}</div></div>`;
  };

  async function openRun(key, r) {
    t.sel = key;
    const read = readRun(t, r);
    t.render();
    await read;
    if (st.tab === o.tab && t.sel === key) t.render();
  }

  $(o.el).addEventListener("click", (e) => {
    const x = e.target;
    const jb = x.closest("[data-jobbox]");
    if (jb) {
      const r = (t.data.rows || []).find((y) => bldKey(y) === t.sel);
      if (r) openJob(t, r, Number(jb.dataset.jobbox), () => t.render());
      return;
    }
    if (x.closest("a") || x.closest(".wdet") || x.closest("button")) return;
    const tr = x.closest("tr.br");
    if (!tr) return;
    const key = tr.dataset.bkey;
    if (t.sel === key) { t.sel = null; t.log = null; t.detail = null; t.jobLog = null; t.render(); return; }
    const r = (t.data.rows || []).find((y) => bldKey(y) === key);
    if (r) openRun(key, r);
  });
  return t;
}

// A run's jobs and its failed-job log into o.detail and o.log, read when it opens and never before;
// both say Loading at once, so a paint straight after the call shows that.
async function readRun(o, r) {
  const key = bldKey(r);
  // The objects this read fills: a reset of o while it runs leaves them, not the new ones.
  const log = (o.log = { key, text: "Loading..." });
  const detail = (o.detail = { key, d: null });
  const q = new URLSearchParams({ forge: r.forge, repo: r.repo, run_id: r.id, attempt: r.attempt });
  const got = api("/api/builds/detail?" + q).then((d) => { detail.d = d; }, (e) => { detail.err = e.message; });
  try { log.text = (await api("/api/builds/log?" + q)) || "(empty)"; } catch (e) { log.text = e.message; }
  await got;
}

// The jobs of a run again into o.detail, keeping the last read on screen while it runs.
async function readDetail(o, r) {
  const detail = (o.detail = { key: bldKey(r), d: o.detail && o.detail.d });
  const q = new URLSearchParams({ forge: r.forge, repo: r.repo, run_id: r.id, attempt: r.attempt });
  try { detail.d = await api("/api/builds/detail?" + q); } catch (e) { detail.err = e.message; }
}

// One run's page (docs/dashboards.md, "Run page"): Summary, Changes, Tests, Jobs, Artifacts and Chain, in that
// order, each from the one read /api/builds/detail answers (o.detail, filled by readRun) and then the
// run's log. The table's open row and the run's own page draw the same.
function runDetail(r, o, folds) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const prs = (r.prs || []).map((n) => `#${n}`).join(" ");
  const log = o.log && o.log.key === bldKey(r) ? `<pre class="joblog">${esc(o.log.text)}</pre>` : "";
  const link = r.url ? `<a href="${esc(r.url)}" target="_blank" rel="noopener">Open run</a>` : "";
  const rel = r.release ? `<a href="${esc(r.release.href)}">${esc(r.release.project)} ${esc(r.release.tag)}</a>` : "";
  const read = o.detail && o.detail.key === bldKey(r) ? o.detail : null;
  const d = read && read.d, page = d && d.page;
  const summary = `<div class="muted">${esc(r.title || r.workflow)}</div>` +
    line("Run", `${esc(r.forge)} ${esc(r.repo)} #${r.id}${r.attempt > 1 ? " attempt " + r.attempt : ""} ${link}`) +
    line("Event", esc(r.event)) + line("Branch", esc(r.branch)) + line("Owner", esc(r.owner || "")) + line("PRs", esc(prs)) +
    line("Release", rel) + (read ? runHeader(read) : "");
  const own = o === runst ? "run" : "bld";
  return `<div class="sdet" data-own="${own}">${rsec("Summary", "", summary)}` +
    (page ? runChanges(page.changes) + runTests(page.tests) : "") +
    (read && !read.err && d ? runJobs(read, folds, page, o, r) : "") +
    (page ? runArtifacts(page.artifacts) + runChain(page.chain) : "") + log + `</div>`;
}

// A section of the run page: its name, what it is as of, then its body.
const rsec = (title, note, body) =>
  `<div class="rsec"><div class="rhead"><b>${title}</b>${note ? ` <span class="muted">${note}</span>` : ""}</div>${body}</div>`;
const rnote = (t, cls = "muted") => (t ? `<div class="cline ${cls}">${esc(t)}</div>` : "");

// Changes: the commits since the previous run of this workflow on the branch, with their PRs.
function runChanges(c) {
  const commit = (k) => `<div class="cline"><code>${esc(k.sha)}</code>${k.pr ? ` <span class="muted">#${k.pr}</span>` : ""} ${esc(k.subject)}</div>`;
  const prs = (c.prs || []).filter((p) => p.title).map((p) =>
    `<div class="cline muted">PR ${p.url ? `<a href="${esc(p.url)}" target="_blank" rel="noopener">#${p.number}</a>` : "#" + p.number} ${esc(p.title)}</div>`).join("");
  const more = c.more ? rnote(`and ${c.more} more commits`) : "";
  return rsec("Changes", c.since ? "since " + esc(c.since) : "", rnote(c.note) + (c.commits || []).map(commit).join("") + more + prs);
}

// Tests: the run's junit, folded to one line when nothing failed, else each failure with its message.
function runTests(t) {
  if (t.note) return rsec("Tests", "", rnote(t.note));
  const bad = (t.failed || []).map((f) =>
    `<div class="cline ${f.quarantined ? "muted" : "bad"}"><b>${f.quarantined ? "quarantined" : f.new ? "NEW" : "failed"}</b> ` +
    `${esc(f.tier)} ${esc(f.suite)} ${esc(f.name)}${f.message ? `<div class="muted">${esc(f.message)}</div>` : ""}</div>`).join("");
  return rsec("Tests", "", `<div class="cline${t.totals && t.totals.failed > 0 ? " bad" : ""}">${esc(t.says)}</div>` + bad +
    (t.more ? rnote(`and ${t.more} more failed`) : "") + rnote(t.compared) + (t.errors || []).map((e) => rnote(e, "warn")).join(""));
}

// Artifacts: what a build run built, one row per artifact with its size, where it is kept and when
// it goes; an expired one stays listed, muted.
function runArtifacts(a) {
  if (!a) return "";
  if (a.note) return rsec("Artifacts", "", rnote(a.note));
  const row = (x) => `<div class="cline${x.expired ? " muted" : ""}"><b>${esc(x.name)}</b> ${esc(x.size_text)} ${esc(x.place)} ` +
    `${x.expired ? "expired" : x.expires ? "until " + esc(x.expires.slice(0, 10)) : ""}</div>`;
  return rsec("Artifacts", esc(a.says), (a.items || []).map(row).join("") + (a.errors || []).map((e) => rnote(e, "warn")).join(""));
}

// Chain: what started the run, the release it fed and the channels that release reached.
function runChain(c) {
  const hop = (h) => (h.href ? `<a href="${esc(h.href)}">${esc(h.text)}</a>` : esc(h.text));
  const rows = [`<div class="cline"><b>Started by</b> ${esc(c.trigger)}</div>`];
  if (c.upstream) rows.push(`<div class="cline"><b>After</b> ${hop(c.upstream)}</div>`);
  if (c.release) rows.push(`<div class="cline"><b>Release</b> ${hop(c.release)}</div>`);
  if ((c.reached || []).length) rows.push(`<div class="cline"><b>Reached</b> ${c.reached.map(esc).join(", ")}</div>`);
  return rsec("Chain", "", rows.join("") + (c.notes || []).map((n) => rnote(n)).join("") + `<div class="cline">${hop(c.flow)}</div>`);
}

// Jobs: the staged graph (a column per depth of the workflow file's needs:), each job a box that
// opens its log once it has ended; a job still running re-reads the jobs when clicked.
function runStages(s, o, r) {
  const jl = o.jobLog && o.jobLog.key === bldKey(r) ? o.jobLog : null;
  const box = (j) => `<button type="button" class="rjob ${esc(j.state)}${jl && jl.id === j.id ? " on" : ""}" data-jobbox="${j.id}" ` +
    `title="${j.log ? "open this job's log" : "not ended: click to re-read the jobs"}">${esc(j.name)} <span class="muted">${esc(j.took_text)}</span>` +
    `${j.failing ? ` <span class="bad">at ${esc(j.failing)}</span>` : ""}</button>`;
  const col = (c) => `<div class="rcol"><div class="muted">${esc(c.label)}</div>${c.jobs.map(box).join("")}</div>`;
  return rnote(s.note, "warn") + ((s.columns || []).length ? `<div class="rgraph">${(s.columns).map(col).join("")}</div>` : "") +
    (jl ? `<div class="cline"><b>Log</b> ${esc(jl.name)}</div><pre class="joblog">${esc(jl.text)}</pre>` : "");
}

// `#infra/runs/<repo>/<run>` (hub_core::links Kind::CiRun, which the hub opens too): one run's
// record, found through the runs read (runQuery), its newest attempt with its jobs and log.
// infra.js draws it in place of the Runs table while the URL names it. `#infra/ci/...`, its old
// address (links::RETIRED_PAGES), still opens it.
const runFresh = (id) => ({ id, data: null, run: null, err: null, log: null, detail: null, jobLog: null });
const runst = runFresh("");
const ciRunId = () => pageId("infra", "runs") || pageId("infra", "ci");
// The runs query a run's page names, as hub_core::builds::run_query: `<repo>/<id>` is that repo's
// run (a Forgejo run id is an index within its repo), a bare id that id in any repo.
const runQuery = (page) => {
  const at = page.lastIndexOf("/");
  return at < 0 ? `id:=${page}` : `repo:=${page.slice(0, at)} id:=${page.slice(at + 1)}`;
};
const refreshRunPage = coalesce(async () => {
  const id = ciRunId();
  if (!id) return;
  try { runst.data = await api("/api/builds?" + new URLSearchParams({ [RUNS_PRE + "q"]: runQuery(id) })); runst.err = null; } catch (e) { runst.err = e.message; }
  if (ciRunId() !== id) return;
  // The ledger's own order (hub_core::builds, live then newest) puts the newest attempt first, the row the hub opens too.
  const run = runst.data?.rows?.[0];
  // A ledger line for another run leaves this one's jobs and log as they were read.
  const same = run && runst.run && bldKey(run) === bldKey(runst.run) && run.state === runst.run.state;
  runst.run = run || null;
  if (run && !same) { const read = readRun(runst, run); renderInfra(); await read; }
  // A run still going re-reads its jobs on each ledger event, never on a timer.
  else if (run && !["green", "red", "other"].includes(run.state)) await readDetail(runst, run);
  if (ciRunId() === id) renderInfra();
});
function showRunPage() {
  const id = ciRunId(), moved = id !== runst.id;
  if (moved) Object.assign(runst, runFresh(id));
  if (id) runFeed.show(moved);
}
function runPage() {
  const id = ciRunId();
  const h = `<div class="bhead" id="sec-run"><span>CI runs / <b>${esc(id)}</b></span><a class="btn sm" href="#infra/runs">All runs</a></div>`;
  if (runst.err) return h + `<div class="panel down">${esc(runst.err)}</div>`;
  if (!runst.data) return h + `<div class="empty">Loading...</div>`;
  if (!runst.run) return h + `<div class="panel">No CI run ${esc(id)} in the ledger's 30 days.</div>`;
  return h + `<div class="panel">${runDetail(runst.run, runst, CI_OPEN)}</div>`;
}

// The run's own page: a job box opens that job's log (the table's open row has its own handler).
$("infra-main").addEventListener("click", (e) => {
  const jb = e.target.closest("[data-jobbox]");
  if (jb && ciRunId() && runst.run) openJob(runst, runst.run, Number(jb.dataset.jobbox), renderInfra);
});

// An Infra CI element's own paint: its block, unless a repaint around a focused search box in it,
// in `t`'s bar or another table's drawn in the same block, did it.
function ciPaint(el, t, ...more) {
  const e = $(el);
  if (!e || st.tab !== "infra") return;
  if ([t, ...more].some((x) => x.repaint())) return;
  paint(e, t.block(), CI_OPEN);
  seekSection();
}

// The opened run's title and header line (/api/builds/detail, hub_core::run_detail): its Summary.
function runHeader(o) {
  if (o.err) return `<div class="cline down">${esc(o.err)}</div>`;
  const d = o.d;
  if (!d) return `<div class="cline">Loading jobs...</div>`;
  return `<div class="cline"><b>${esc(d.title)}</b></div><div class="cline">${esc(d.header)}</div>`;
}

// The opened run's Jobs: the stage graph, then every job and its steps (read when
// the row opens). Each cell carries its label, so a phone stacks a job into labelled lines.
function runJobs(o, folds, page, owner, r) {
  const d = o.d;
  const k = o.key;
  const cell = (label, v, cls = "") => `<td data-label="${label}"${cls ? ` class="${cls}"` : ""}>${esc(v)}</td>`;
  const job = (j) => `<tr>${cell("job", j.name, "wrap")}${cell("class", j.class, "muted")}${cell("wait", j.wait_text, "n")}` +
    `${cell("took", j.took_text, "n")}${cell("runner", j.runner, "wrap muted")}</tr>`;
  const head = "<tr><th>job</th><th>class</th><th>wait</th><th>took</th><th>runner</th></tr>";
  const jobs = (d.jobs || []).length
    ? `<table class="tbl rdjobs">${head}${d.jobs.map(job).join("")}</table>` : "";
  const steps = (d.jobs || []).filter((j) => j.steps_text).map((j) => `<div class="cline"><b>${esc(j.name)}</b> ${esc(j.steps_text)}</div>`).join("");
  const cover = `<div class="cline">${esc(d.coverage_text)}</div>` +
    ((d.attempts || []).length > 1 ? `<div class="cline"><b>Attempts</b> ${d.attempts.join(", ")}</div>` : "");
  const graph = page ? runStages(page.stages, owner, r) : "";
  return rsec("Jobs", page && page.stages.source ? esc(page.stages.source) : "", graph + jobs +
    (steps ? cfold(`bld-steps:${k}`, `<b>Steps</b>`, steps, folds) : "") +
    cfold(`bld-cover:${k}`, `<b>Coverage</b> <span class="muted">${esc(d.coverage)}</span>`, cover, folds));
}

// A job box: its log when the job has ended; a job still going re-reads the jobs (one gh call, kept
// 30 s by the server) and opens the log if it has ended by now. Never a timer: a click is the event.
async function openJob(o, r, id, render) {
  const key = bldKey(r);
  const find = () => ((((o.detail && o.detail.d && o.detail.d.page) || {}).stages || {}).columns || []).flatMap((c) => c.jobs).find((j) => j.id === id);
  let j = find();
  if (!j) return;
  if (!j.log) {
    const q = new URLSearchParams({ forge: r.forge, repo: r.repo, run_id: r.id, attempt: r.attempt });
    const detail = (o.detail = { key, d: o.detail.d });
    try { detail.d = await api("/api/builds/detail?" + q); } catch (e) { detail.err = e.message; }
    render();
    j = find();
    if (!j || !j.log) return;
  }
  const lg = (o.jobLog = { key, id, name: j.name, text: "Loading..." });
  render();
  const q = new URLSearchParams({ forge: r.forge, repo: r.repo, run: r.id, attempt: r.attempt, job: id });
  try { lg.text = (await api("/api/builds/joblog?" + q)) || "(empty)"; } catch (e) { lg.text = e.message; }
  render();
}

// Infra's Runs: every run. A read repaints the Infra strip, whose Runs count it carries, and
// Runners' head, whose `failed 24h` it counts.
const bld = runsTable({ tab: "infra", id: "bld", el: "ci-runs", title: "Runs", none: "No runs in the ledger.", after: () => renderInfra() });

// Infra's Pipelines: one row per workflow of each repo (hub_core::pipelines), red first. `why` is
// the state cell's tooltip and the opened row's first line; the opened row reads the pipeline's
// purpose, crons, jobs and last runs (/api/pipelines/detail) when it opens, never before.
const PIP_PRE = "l";
const PIP_HINT = "search, or repo:unity-core-playground trigger:cron nightly:on";
const PIP_COLS = { state: ["state"], repo: ["repo"], pipeline: ["pipeline"], trigger: ["trigger"], nightly: ["nightly"], schedule: ["schedule"], next: ["next", "n", true],
  last: ["last run"], pass: ["pass", "n", true], runs: ["runs", "n"], usual: ["usual", "n"], p90: ["p90", "n"] };
const pipKey = (r) => `${r.repo}|${r.file}`;
const pipClass = (state) => (state === "red" ? "bad" : state === "amber" ? "warn" : state === "off" ? "muted" : "");
const lastClass = (c) => (c === "failure" || c === "timed_out" || c === "startup_failure" ? "bad" : c === "success" ? "" : "warn");
// A next start within six days is its weekday and 24h time, as the schedule cell words it ("00:00
// daily"); the full stamp was wide enough to push USUAL and P90 off a 1400px page.
function nextAt(t) {
  const m = tms(t), today = new Date(m).toDateString() === new Date().toDateString();
  return today ? clock(m) : m - Date.now() < 6 * 864e5 ? `${new Date(m).toLocaleDateString([], { weekday: "short" })} ${clock(m)}` : stamp(t);
}
// The cells by column (Row::COLUMNS order); `L` is the row's links. A night member's next start
// and schedule open its runner's Schedules row (Kind::Schedule), a cron's its own.
const PIP_CELLS = {
  state: (r) => `<td class="${pipClass(r.state)}" title="${esc(r.why)}">${esc(r.state)}${r.running ? ` <span class="muted">${r.running} running</span>` : ""}</td>`,
  repo: (r, L) => td("", tblLink(L.repo, r.project)),
  pipeline: (r) => `<td class="wrap" title="${esc(r.file)}">${esc(r.pipeline)}</td>`,
  trigger: (r) => td("muted", esc(r.trigger) || "-"),
  nightly: (r) => td(r.nightly === "held" ? "warn" : "", esc(r.nightly) || "-"),
  schedule: (r, L) => td("wrap muted", r.schedule ? tblLink(L.next, r.schedule) : "-"),
  next: (r, L) => `<td class="n"${r.next ? ` title="${stamp(r.next)}"` : ""}>${r.next ? tblLink(L.next, nextAt(r.next)) : "-"}</td>`,
  // Its age, as the mockup's "fail 3d": a full stamp was the widest cell and pushed USUAL and P90
  // off a 1400px page; the stamp is the tooltip.
  last: (r, L) => `<td class="${lastClass(r.last_result)}" title="${r.last ? stamp(r.last) : ""}">${r.last ? tblLink(L.last, `${r.last_result || "?"} ${ageMin((Date.now() - tms(r.last)) / 6e4) || "now"}`) : "-"}</td>`,
  pass: (r) => td(`n ${r.pass == null ? "muted" : r.pass < 70 ? "bad" : r.pass < 90 ? "warn" : ""}`, r.pass == null ? "-" : r.pass + "%"),
  runs: (r) => td("n", r.runs),
  usual: (r) => td("n muted", secs(r.usual)),
  p90: (r) => td("n muted", secs(r.p90)),
};
const pip = tblTab({
  tab: "infra", id: "pip", pre: PIP_PRE, el: "ci-pipelines", api: "/api/pipelines", hint: PIP_HINT, state: { detail: null },
  wrap: (h) => `<div data-tbl="${PIP_PRE}">${h}</div>`,
  head: (t) => pipHead(t), body: (t) => pipBody(t),
  render: () => ciPaint("ci-pipelines", pip),
  after: () => renderInfra(),
  // An opened row whose pipeline the new read lacks closes.
  got: (t) => { if (t.sel && !(t.data.rows || []).some((r) => pipKey(r) === t.sel)) { t.sel = null; t.detail = null; } },
});
pip.block = () => (pip.data ? pip.html() : pip.err ? `<div class="panel down">${esc(pip.err)}</div>` : secHead("pipelines", "Pipelines") + `<div class="empty">Reading...</div>`);

function pipHead(t) {
  const d = t.data;
  let html = secHead("pipelines", "Pipelines", d.table && tblCount(d.table), d.red ? "bad" : "");
  if (t.err) html += `<div class="panel down">${esc(t.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

function pipBody(t) {
  const d = t.data, v = d.table, rows = d.rows || [];
  if (!rows.length) return `<div class="panel">${v && v.total ? "No pipeline matches." : "No pipelines: no repo in the ledger or state.json."}</div>`;
  const keys = v.columns.map((c) => c.key).filter((k) => PIP_COLS[k]);
  const row = (r, i) => {
    const open = pipKey(r) === t.sel, L = tblLinks(v, i);
    const tr = `<tr class="pipr${open ? " sel" : ""}" data-pkey="${esc(pipKey(r))}">${keys.map((k) => PIP_CELLS[k](r, L)).join("")}</tr>`;
    return open ? tr + `<tr class="wdet"><td colspan="${keys.length}">${pipDetail(r, t.detail)}</td></tr>` : tr;
  };
  return `<div class="panel scroll"><table class="tbl">${tblHead(v, PIP_COLS)}${rows.map(row).join("")}</table></div>`;
}

// The opened pipeline: why it is in its state, then what /api/pipelines/detail says once read.
function pipDetail(r, o) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  let html = `<div class="sdet"><div class="cline ${pipClass(r.state)}">${esc(r.why)}</div>` + line("File", esc(r.file));
  if (!o || o.key !== pipKey(r)) return html + `<div class="cline muted">reading...</div></div>`;
  if (o.err) return html + `<div class="cline down">${esc(o.err)}</div></div>`;
  if (!o.d) return html + `<div class="cline muted">reading...</div></div>`;
  const d = o.d;
  html += line("Purpose", esc(d.purpose || "")) + line("Crons", esc((d.crons || []).join("; "))) + line("Jobs", esc(d.jobs)) +
    line("Night title", esc(d.night_title || ""));
  const cell = (label, v, cls = "") => `<td data-label="${label}"${cls ? ` class="${cls}"` : ""}>${v}</td>`;
  const run = (x) => `<tr>${cell("started", tblLink(x.link, stamp(x.started)), "n")}${cell("result", esc(x.conclusion || x.state), lastClass(x.conclusion || ""))}` +
    `${cell("branch", esc(x.branch), "wrap muted")}${cell("event", esc(x.event), "muted")}${cell("title", esc(x.title), "wrap")}${cell("took", secs(x.took), "n")}</tr>`;
  const runs = (d.runs || []).length
    ? `<table class="tbl rdjobs"><tr><th data-role="glance">started</th><th data-role="glance">result</th><th>branch</th><th>event</th><th data-role="lead">title</th><th>took</th></tr>${d.runs.map(run).join("")}</table>`
    : `<div class="cline muted">No runs in the ledger's 30 days.</div>`;
  return html + `<div class="cline"><b>Last runs</b></div>${runs}</div>`;
}

async function openPipeline(key, r) {
  pip.sel = key;
  const o = pip.detail = { key, d: null };
  pip.render();
  const q = new URLSearchParams({ repo: r.repo, file: r.file });
  try { o.d = await api("/api/pipelines/detail?" + q); } catch (e) { o.err = e.message; }
  if (st.tab === "infra" && pip.detail === o) pip.render();
}

$("ci-pipelines").addEventListener("click", (e) => {
  const x = e.target;
  if (x.closest("a") || x.closest(".wdet") || x.closest("button")) return;
  const tr = x.closest("tr.pipr");
  if (!tr) return;
  const key = tr.dataset.pkey;
  if (pip.sel === key) { pip.sel = null; pip.detail = null; pip.render(); return; }
  const r = (pip.data.rows || []).find((y) => pipKey(y) === key);
  if (r) openPipeline(key, r);
});

// Infra's CI Tests: one block per declared test workflow (lane) of the picked repo, each with the
// suites of its run (the latest nightly unless the human picked another).
const TESTS_PRE = "t";
const TESTS_HINT = "search, or tier:unit state:failed suite:fleet, or a test's name";
const tst = tblTab({
  tab: "infra", id: "tst", pre: TESTS_PRE, el: "ci-tests", api: "/api/tests", hint: TESTS_HINT,
  // The Quarantine table's view rides the same read.
  params: (p) => {
    const v = new URLSearchParams(st.views.infra || "");
    for (const k of ["trepo", "trun"]) if (v.get(k)) p.set(k, v.get(k));
    for (const [k, v] of tblParams(st.views.infra, QTN_PRE)) p.set(k, v);
  },
  head: (t) => testsHead(t.data), body: (t) => testsBody(t.data), tiles: (t) => testsTiles(t.data),
  render: () => ciPaint("ci-tests", tst, qtn, cas),
  after: () => renderInfra(),
  // An opened suite belongs to the run it was read from: a run no lane shows any more has none open.
  got: (t) => { if (cas.run && !(t.data.lanes || []).some((l) => l.run && l.run.id === cas.run)) { t.sel = null; shutSuite(); } },
});

// The opened suite's tests: a table of their own (`c` keys), filtered on the server so the
// result tiles count every test of the suite, not only the page it sends.
const CASES_PRE = "c";
const cas = tblTab({
  tab: "infra", id: "cas", pre: CASES_PRE, el: "ci-tests", api: "/api/tests/cases", hint: "search a test's name, full name or failure",
  state: { run: null, tier: "", suite: "", key: null },
  params: (p, t) => { p.set("run", t.run); p.set("tier", t.tier); p.set("suite", t.suite); },
  // A read answers the suite it asked for, which a quick second open may have moved past.
  got: (t) => { const p = new URLSearchParams(t.q); t.key = `${p.get("run")}|${p.get("tier")}|${p.get("suite")}`; },
  render: () => tst.render(),
  wrap: (h) => `<div data-tbl="${CASES_PRE}">${h}</div>`,
  body: (t) => casesBody(t.data),
});
const shutSuite = () => Object.assign(cas, { run: null, tier: "", suite: "", key: null, data: null, err: null });

const TST_COLS = { state: ["state"], tier: ["tier"], suite: ["suite"], tests: ["tests", "n"], failed: ["failed", "n"], quarantined: ["quarantined", "n"], skipped: ["skipped", "n"], time: ["time", "n"] };
// A suite is opened by its run, tier and file: two lanes can run a file of the same name.
const tstKey = (run, r) => `${run.id}|${r.tier}|${r.suite}`;
// A dotted name (Playground.PlayTests.Suite.Case) has no space to wrap at, so one long name pushed
// the columns after it off a 1400px page: it may break after each dot.
const dotted = (s) => esc(s).replace(/\./g, ".<wbr>");
const testTime = (s) => (s >= 60 ? secs(s) : s > 0 ? `${s.toFixed(s < 10 ? 2 : 0)}s` : "-");
const testClass = (result) => (result === "failed" ? "bad" : result === "quarantined" ? "warn" : "");

// A class's recent results, oldest first, as one small block each (hub-core's `history` on the
// suite row: passed, failed, skipped or quarantined), with its flake rate (`flake`, percent).
// A lane draws the column only when one of its suites carries a history.
const hasHistory = (rows) => rows.some((r) => (r.history || []).length);
function histCell(r) {
  const h = r.history || [];
  if (!h.length) return `<td class="hist"></td>`;
  const strip = `<span class="hstrip" title="${esc(`last ${h.length} runs, oldest first: ${h.join(", ")}`)}">${h.map((x) => `<i class="${esc(x)}"></i>`).join("")}</span>`;
  const flake = r.flake > 0 ? ` <span class="warn" title="share of runs that failed then passed">${esc(r.flake)}% flaky</span>` : "";
  return `<td class="hist">${strip}${flake}</td>`;
}

function suiteRow(r, run, hist) {
  const key = tstKey(run, r), open = key === tst.sel;
  const row = `<tr class="sr${open ? " sel" : ""}" data-skey="${esc(key)}">` +
    `<td class="${levelClass(r.level)}">${esc(r.state)}</td><td>${esc(r.tier)}</td><td class="wrap">${dotted(r.suite)}</td>` +
    `<td class="n">${r.tests}</td><td class="n ${r.failed ? "bad" : "muted"}">${r.failed}</td><td class="n ${r.quarantined ? "warn" : "muted"}">${r.quarantined || 0}</td><td class="n muted">${r.skipped}</td><td class="n">${testTime(r.time)}</td>` +
    `${hist ? histCell(r) : ""}</tr>`;
  return open ? row + suiteDetail(r, run, hist) : row;
}

// The opened suite's tests, failed first, under their result tiles and search.
function suiteDetail(r, run, hist) {
  const open = cas.data && cas.key === tstKey(run, r) && cas.run === run.id;
  const inner = open ? cas.html() : cas.err ? `<span class="warn">${esc(cas.err)}</span>` : `<span class="muted">reading...</span>`;
  return `<tr class="wdet"><td colspan="${hist ? 9 : 8}"><div class="sdet"><div class="muted">${esc(r.tier)} ${dotted(r.suite)}</div>${inner}</div></td></tr>`;
}

function casesBody(d) {
  const lines = d.cases.map((t) => `<div class="cline"><span class="${testClass(t.result)}">${esc(t.result)}</span> ${dotted(t.name)} <span class="muted">${testTime(t.time)}</span>` +
    (t.message ? `<pre class="joblog">${esc(t.message)}</pre>` : "") + `</div>`).join("");
  return lines || `<div class="muted">${d.table.total ? "No test matches." : "No tests in this suite."}</div>`;
}

// The run picker of a lane: its finished runs, each by branch, commit, result and age. A pick
// is `trun`, one run id per lane: the lanes the human pinned keep theirs, the rest follow their
// default (the latest nightly).
function laneRuns(d, l) {
  const others = (d.lanes || []).filter((o) => o !== l && o.pinned && o.run).map((o) => o.run.id);
  const dflt = `<option value="${others.join(",")}"${l.pinned ? "" : " selected"}>default (latest nightly)</option>`;
  const opts = dflt + l.runs.map((r) => `<option value="${[...others, r.id].join(",")}"${l.pinned && r.id === l.run.id ? " selected" : ""}>${esc(`${r.branch} ${r.sha} ${r.event === "schedule" ? "nightly " : ""}${r.state}, ${ago(r.started)} ago`)}</option>`).join("");
  const link = /^https:/.test(l.run.url || "") ? ` <a href="${esc(l.run.url)}" target="_blank" rel="noopener">Open run</a>` : "";
  return `<div class="cline"><select data-twin="run" aria-label="CI run of ${esc(l.workflow)}">${opts}</select>${link}</div>`;
}

// One lane: its workflow, its run and what it counted, then its suites. A lane with no run, or
// none that left results, still shows its name and says why.
function laneBlock(d, l, i) {
  const t = l.table, rows = l.rows || [];
  let html = secHead(`tests-${i}`, l.workflow, l.run ? tblCount(t) : null, l.totals.failed_suites > 0 ? "bad" : "", "h3");
  if (!l.run) return html + `<div class="panel muted">${esc(l.note)}</div>`;
  html += laneRuns(d, l) + `<div class="cline ${l.totals.failed ? "bad" : ""}">${esc(l.says)}</div>`;
  if ((l.errors || []).length) html += `<div class="panel down">${l.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  const note = l.note ? `<div class="panel muted">${esc(l.note)}</div>` : "";
  if (l.fold) return html + `<div class="panel"><button class="btn sm" data-ts="passed" title="list the passing suites">${esc(l.fold)}</button></div>`;
  if (!rows.length) return html + (note || `<div class="panel">${t && t.total ? "No suites match." : "No suites in this run."}</div>`);
  const hist = hasHistory(rows);
  const head = tblHead(t, TST_COLS).replace("</tr>", hist ? `<th data-role="" data-label="history">history</th></tr>` : "</tr>");
  return html + note + `<div class="panel scroll"><table class="tbl">${head}${rows.map((r) => suiteRow(r, l.run, hist)).join("")}</table></div>` + tblPager(t);
}

// The lanes, each from the one read; none until a repo declares a test workflow that has run.
function testsBody(d) {
  const lanes = d.lanes || [];
  if (!lanes.length) return `<div class="panel">No repo has a finished run of a declared test workflow in the ledger (testWorkflows in the project map).</div>`;
  return lanes.map((l, i) => laneBlock(d, l, i)).join("");
}

// The repo picker (`trepo`: the repos with a finished run of a declared test workflow, the newest
// first). A new repo drops the picked runs (data-tclear), so each lane opens on its default.
function testsPicker(d) {
  if (!(d.lanes || []).length) return "";
  const repos = (d.repos || []).map((r) => `<option value="${esc(r)}"${r === d.repo ? " selected" : ""}>${esc(r)}</option>`).join("");
  return `<div class="cline"><select data-twin="repo" data-tclear="run" aria-label="repo">${repos}</select></div>`;
}

// The tests over every lane, after the suites' state tiles; none before a run has results.
const testsTiles = (d) => {
  const n = d.totals;
  return (d.lanes || []).length && n && n.tests ? tile("TESTS", n.tests, n.failed ? "var(--b-needs)" : "var(--b-done)", `${n.failed} failed, ${n.skipped} skipped`) : "";
};

function testsHead(d) {
  const v = d.table, has = (d.lanes || []).length;
  let html = secHead("tests", "Tests", v && has ? tblCount(v) : null, d.totals?.failed_suites > 0 ? "bad" : "") + testsPicker(d);
  if (tst.err) html += `<div class="panel down">${esc(tst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

// Tests' Quarantine: one row per quarantined test of every repo, under each lane's line, from the
// same read as the suites (its keys ride tst's params), so the builds event refreshes both.
const QTN_PRE = "q";
const QTN_HINT = "search, or repo:unity-core-playground row:ucp-1450 nightly:failing";
const QTN_COLS = { test: ["test"], repo: ["repo"], row: ["row"], ends: ["ends"], left: ["left", "n"], nightly: ["nightly"] };
const qtn = tblTab({
  tab: "infra", id: "qtn", pre: QTN_PRE, el: "ci-tests", hint: QTN_HINT,
  refresh: () => tst.refresh(), render: () => tst.render(), table: () => tst.data?.quarantine?.table,
  wrap: (h) => `<div data-tbl="${QTN_PRE}">${h}</div>`,
  head: () => qtnHead(tst.data.quarantine), body: () => qtnBody(tst.data.quarantine),
});

// Each lane's line (entries, the nearest end, the last nightly's KNOWN and now-passing counts)
// with its nightly's link.
function qtnHead(q) {
  const lane = (l) => `<div class="cline ${levelClass(l.level)}">${esc(l.says)}` +
    (/^https:/.test(l.url || "") ? ` <a href="${esc(l.url)}" target="_blank" rel="noopener">nightly</a>` : "") + `</div>`;
  return secHead("quarantine", "Quarantine") + (q.error ? `<div class="panel down">${esc(q.error)}</div>` : "") +
    q.lanes.map(lane).join("");
}

function qtnBody(q) {
  const t = q.table, rows = q.rows || [];
  if (!rows.length) return `<div class="panel">${t.total ? "No quarantined test matches." : "No quarantine lists its tests yet."}</div>`;
  const row = (r, i) => {
    const L = tblLinks(t, i);
    return `<tr><td class="wrap">${dotted(r.test)}</td><td>${tblLink(L.repo, r.repo)}</td><td>${r.row ? tblLink(L.row, r.row) : "-"}</td>` +
      `<td>${esc(r.ends)}</td><td class="n ${levelClass(r.level)}">${esc(r.left)}</td><td class="${r.nightly === "now passing" ? "" : "muted"}">${esc(r.nightly)}</td></tr>`;
  };
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, QTN_COLS)}${rows.map(row).join("")}</table></div>`;
}

// The Quarantine block: none until a repo has a quarantine.
const qtnBlock = (d) => {
  const q = d.quarantine;
  return q && q.table && (q.lanes.length || q.error) ? qtn.html() : "";
};

// The Tests block, once it has been read. The first look at a run waits on GitHub for its
// artifacts, so the heading shows before the rows do.
tst.block = () => {
  if (!tst.data) return tst.err ? `<div class="panel down">${esc(tst.err)}</div>` : secHead("tests", "Tests") + `<div class="empty">Reading...</div>`;
  if (!(tst.data.lanes || []).length) return `<div id="tst-head">${testsHead(tst.data)}</div><div id="tst-body">${testsBody(tst.data)}</div>` + qtnBlock(tst.data);
  const body = tblBodyFirst(tst.data.table, () => testsBody(tst.data));
  return `<div data-tbl="${TESTS_PRE}"><div id="tst-head">${testsHead(tst.data)}</div>${tblBar("tst", tst.data.table, TESTS_HINT, testsTiles(tst.data))}` +
    `<div id="tst-body">${body}</div></div>` + qtnBlock(tst.data);
};

// A suite's tests, read when its row opens, on all of them.
function openSuite(key, r, run) {
  tst.sel = key;
  shutSuite();
  Object.assign(cas, { run: run.id, tier: r.tier, suite: r.suite });
  setQuery(tblSet(st.views.infra, { q: "", s: "", sort: "", dir: "" }, CASES_PRE));
  tst.render();
  cas.refresh();
}

// The suite row a click named, with the run of the lane it is in.
function suiteOf(key) {
  for (const l of tst.data.lanes || []) {
    const r = l.run && (l.rows || []).find((x) => tstKey(l.run, x) === key);
    if (r) return [r, l.run];
  }
  return null;
}

$("ci-tests").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest(".wdet") || t.closest("button")) return;
  const tr = t.closest("tr.sr");
  if (!tr) return;
  const key = tr.dataset.skey;
  if (tst.sel === key) { tst.sel = null; shutSuite(); tst.render(); return; }
  const hit = suiteOf(key);
  if (hit) openSuite(key, ...hit);
});

for (const el of ["ci-runs", "ci-pipelines", "ci-tests"]) $(el).addEventListener("toggle", (e) => { if (e.target.dataset?.k) CI_OPEN[e.target.dataset.k] = e.target.open; }, true);

// A new ledger line re-reads each while Infra is open, and a state.json write Pipelines too;
// TABS.infra (infra.js) drives them.
const bldFeed = pushed("infra", ["builds"], bld.refresh);
const pipFeed = pushed("infra", ["pipelines", "builds"], pip.refresh);
const tstFeed = pushed("infra", ["builds"], tst.refresh);
const runFeed = pushed("infra", ["builds"], refreshRunPage);
