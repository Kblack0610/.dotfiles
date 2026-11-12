"use strict";
// Infra's CI runs and Tests sections, and the run table Releases' Release runs reuses.
// Runs: CI runs of the last 30 days from /api/builds (hub_core::builds), with the Run times and
// Quarantine folds above them; Releases reads the same with scope=release (Scope::Release).
// Tests: the suites of one finished run of a repo's declared test workflow from /api/tests
// (hub_core::junit), the newest unless the picker names another. Each is the shared table
// (table.js) under its own view keys (bq, bs, bsort, bdir; tq, ts, tsort, tdir, trun), so it sits
// beside another table on its tab. A run's jobs and log, and a suite's tests, are read when the
// row opens, never before.

const RUNS_PRE = "b";
const RUNS_HINT = "search, or repo:binks state:red owner:agent-3 workflow:Tests release:v1";
// Which folds are open on Infra's CI tables (Run times, Quarantine, a run's steps), so a repaint keeps them.
const CI_OPEN = {};
const BLD_COLS = { started: ["started", "n"], state: ["state"], repo: ["repo"], workflow: ["workflow"], branch: ["branch"], took: ["took", "n"], usual: ["usual", "n"], eta: ["eta", "n"], owner: ["owner"], release: ["release"] };
// A workflow's usual time as "median/p90", "-" below the runs a median needs.
const usualText = (u) => (u ? `${secs(u.median)}/${secs(u.p90)}` : "-");
// A running run's expected end, or once passed how far past it (a past clock reads as on time).
const runEta = (t) => (!t ? "-" : t * 1e3 < Date.now() ? `+${secs(Date.now() / 1e3 - t)}` : when(t));
const bldKey = (r) => `${r.forge}|${r.repo}|${r.id}|${r.attempt}`;

// One run table. `o.tab` and `o.el` are where it draws; `o.render` is the tab's own render when
// it draws inside the tab's page (Releases), else it paints `o.el`. `o.scope` is the read's cut,
// `o.title` its heading, `o.lead` a line under it, `o.folds` the map its folds keep their state in.
function runsTable(o) {
  const folds = o.folds || CI_OPEN, id = o.id;
  const t = tblTab({
    tab: o.tab, id, pre: RUNS_PRE, el: o.el, api: "/api/builds", hint: RUNS_HINT, state: { log: null, detail: null },
    params: (p) => { if (o.scope) p.set("scope", o.scope); },
    open: () => folds, head: () => head(t.data), body: () => body(t.data),
    render: o.render || (() => ciPaint(o.el, t)),
    after: o.after,
  });

  function row(r) {
    const open = bldKey(r) === t.sel;
    const wait = r.state === "queued" ? `wait ${secs(r.took)}` : secs(r.took);
    const tr = `<tr class="br${open ? " sel" : ""}" data-bkey="${esc(bldKey(r))}">` +
      `<td class="n">${when(r.started)}</td><td class="${levelClass(r.level)}">${esc(r.state)}</td><td>${esc(r.repo)}</td>` +
      `<td class="wrap">${esc(r.workflow)}</td><td class="wrap muted">${esc(r.branch)}</td><td class="n">${wait}</td>` +
      `<td class="n muted">${usualText(r.usual)}</td><td class="n">${runEta(r.eta)}</td>` +
      `<td class="muted">${esc(r.owner || "-")}</td><td class="muted">${esc(r.release?.tag || "-")}</td></tr>`;
    return open ? tr + detail(r) : tr;
  }

  function detail(r) {
    const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
    const prs = (r.prs || []).map((n) => `#${n}`).join(" ");
    const log = t.log && t.log.key === bldKey(r) ? `<pre class="joblog">${esc(t.log.text)}</pre>` : "";
    const link = r.url ? `<a href="${esc(r.url)}" target="_blank" rel="noopener">Open run</a>` : "";
    const rel = r.release ? `${esc(r.release.project)} ${esc(r.release.tag)}` : "";
    return `<tr class="wdet"><td colspan="10"><div class="sdet"><div class="muted">${esc(r.title || r.workflow)}</div>` +
      line("Run", `${esc(r.forge)} ${esc(r.repo)} #${r.id}${r.attempt > 1 ? " attempt " + r.attempt : ""} ${link}`) +
      line("Event", esc(r.event)) + line("Branch", esc(r.branch)) + line("Owner", esc(r.owner || "")) + line("PRs", esc(prs)) +
      line("Release", rel) + (t.detail && t.detail.key === bldKey(r) ? runJobs(t.detail, folds) : "") + log + `</div></td></tr>`;
  }

  function body(d) {
    const v = d.table, rows = d.rows || [];
    if (!rows.length) return `<div class="panel">${v && v.total ? "No runs match." : o.none}</div>`;
    return `<div class="panel scroll"><table class="tbl">${tblHead(v, BLD_COLS)}${rows.map(row).join("")}</table>` +
      (d.more > 0 ? `<div class="muted">${d.more} older not shown; narrow the search to list them.</div>` : "") + `</div>`;
  }

  function head(d) {
    const stale = d.at && Date.now() / 1e3 - d.at > d.stale_after;
    let html = `<h2 class="sec" id="sec-runs">${o.title} <span class="muted">${esc(d.summary || "")}</span>` +
      (stale ? ` <span class="warn">ledger older than ${dur(d.stale_after / 60)}</span>` : "") + `</h2>` + (o.lead || "");
    if (t.err) html += `<div class="panel down">${esc(t.err)}</div>`;
    if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
    // In the head, so a repaint while the search box has focus refreshes them too.
    return html + runTimes(d, folds) + runQuarantine(d, folds);
  }

  // The whole block, once it has been read.
  t.block = () => {
    if (!t.data) return t.err ? `<div class="panel down">${esc(t.err)}</div>` : "";
    if (!t.data.table) return `<div id="${id}-head">${head(t.data)}</div>`;
    const b = tblBodyFirst(t.data.table, () => body(t.data));
    return `<div data-tbl="${RUNS_PRE}"><div id="${id}-head">${head(t.data)}</div>${tblBar(id, t.data.table, RUNS_HINT)}<div id="${id}-body">${b}</div></div>`;
  };

  // A run's jobs and its failed-job log, read when its row opens and never before.
  async function openRun(key, r) {
    t.sel = key;
    t.log = { key, text: "Loading..." };
    t.detail = { key, d: null };
    t.render();
    const q = new URLSearchParams({ forge: r.forge, repo: r.repo, run_id: r.id, attempt: r.attempt });
    const got = api("/api/builds/detail?" + q).then((d) => { t.detail.d = d; }, (e) => { t.detail.err = e.message; });
    try { t.log.text = (await api("/api/builds/log?" + q)) || "(empty)"; } catch (e) { t.log.text = e.message; }
    await got;
    if (st.tab === o.tab && t.sel === key) t.render();
  }

  $(o.el).addEventListener("click", (e) => {
    const x = e.target;
    if (x.closest("a") || x.closest(".wdet") || x.closest("button")) return;
    const tr = x.closest("tr.br");
    if (!tr) return;
    const key = tr.dataset.bkey;
    if (t.sel === key) { t.sel = null; t.log = null; t.detail = null; t.render(); return; }
    const r = (t.data.rows || []).find((y) => bldKey(y) === key);
    if (r) openRun(key, r);
  });
  return t;
}

// An Infra CI element's own paint: its block, unless a repaint around a focused search box did it.
function ciPaint(el, t) {
  const e = $(el);
  if (!e || st.tab !== "infra") return;
  if (t.repaint()) return;
  paint(e, t.block(), CI_OPEN);
  seekSection();
}

// The opened run's header, jobs and their steps (/api/builds/detail, hub_core::run_detail), read
// when the row opens. Each cell carries its label, so a phone stacks a job into labelled lines.
function runJobs(o, folds) {
  if (o.err) return `<div class="cline down">${esc(o.err)}</div>`;
  const d = o.d;
  if (!d) return `<div class="cline">Loading jobs...</div>`;
  const k = o.key;
  const cell = (label, v, cls = "") => `<td data-label="${label}"${cls ? ` class="${cls}"` : ""}>${esc(v)}</td>`;
  const job = (j) => `<tr>${cell("job", j.name, "wrap")}${cell("class", j.class, "muted")}${cell("wait", j.wait_text, "n")}` +
    `${cell("took", j.took_text, "n")}${cell("runner", j.runner, "wrap muted")}${cell("$", j.price.text, "n")}</tr>`;
  const head = "<tr><th>job</th><th>class</th><th>wait</th><th>took</th><th>runner</th><th>$ basis</th></tr>";
  const jobs = (d.jobs || []).length
    ? `<table class="tbl rdjobs">${head}${d.jobs.map(job).join("")}</table>` : "";
  const steps = (d.jobs || []).filter((j) => j.steps_text).map((j) => `<div class="cline"><b>${esc(j.name)}</b> ${esc(j.steps_text)}</div>`).join("");
  const cover = `<div class="cline">${esc(d.coverage_text)}</div>` +
    ((d.attempts || []).length > 1 ? `<div class="cline"><b>Attempts</b> ${d.attempts.join(", ")}</div>` : "");
  return `<div class="cline"><b>${esc(d.title)}</b></div><div class="cline">${esc(d.header)}</div>` +
    (d.rates_error ? `<div class="cline warn">no rates: ${esc(d.rates_error)}</div>` : "") + jobs +
    (steps ? cfold(`bld-steps:${k}`, `<b>Steps</b>`, steps, folds) : "") +
    cfold(`bld-cover:${k}`, `<b>Coverage</b> <span class="muted">${esc(d.coverage)}</span>`, cover, folds);
}

// The Run times fold: each workflow's usual time over the window, from the same read. Money is a
// cloud machine's POWER cell on Machines (per host today) and Costs' (the month), so this has none.
function runTimes(d, folds) {
  const t = d.times || [];
  if (!t.length) return "";
  const row = (w) => `<tr><td>${esc(w.repo.split("/").pop())}</td><td class="wrap">${esc(w.workflow)}</td><td class="n">${w.runs}</td>` +
    `<td class="n">${w.usual ? secs(w.usual.median) : "-"}</td><td class="n">${w.usual ? secs(w.usual.p90) : "-"}</td>` +
    `<td class="n">${w.runs ? secs(w.longest) : "-"}</td><td class="n">${w.runs ? w.pass + "%" : "-"}</td><td class="n">${w.running || ""}</td></tr>`;
  const head = '<tr><th data-role="glance">repo</th><th data-role="lead">workflow</th><th>runs</th><th data-role="glance" data-named>usual</th><th>p90</th><th>longest</th><th data-role="glance" data-named>pass</th><th>running</th></tr>';
  return cfold("bld-times", `<b>Run times</b> <span class="muted">${t.length} workflows, 30 days, finished runs (cancelled left out); usual is the median, - under 3 runs</span>`,
    `<div class="panel scroll"><table class="tbl">${head}${t.map(row).join("")}</table></div>`, folds, true);
}

// Each repo's test quarantine: its line (entries, the nearest end, the last nightly's KNOWN and
// now-passing counts), then its owner rows, soonest end first. No repo with one draws nothing.
function runQuarantine(d, folds) {
  const q = d.quarantine || [];
  if (!q.length) return "";
  const row = (r) => `<tr><td>${esc(r.row)}</td><td class="n">${r.entries}</td><td>${esc(r.ends)}</td>` +
    `<td class="n ${levelClass(r.level)}">${esc(r.left)}</td></tr>`;
  const head = '<tr><th data-role="lead">owner row</th><th data-role="glance" data-named>entries</th><th data-role="glance" data-named>ends</th><th data-role="glance" data-named>left</th></tr>';
  const lane = (l) => `<div class="cline ${levelClass(l.level)}">${esc(l.says)}` +
    (/^https:/.test(l.url || "") ? ` <a href="${esc(l.url)}" target="_blank" rel="noopener">nightly</a>` : "") + `</div>` +
    (l.rows.length ? `<table class="tbl">${head}${l.rows.map(row).join("")}</table>` : "");
  const entries = q.reduce((n, l) => n + l.entries, 0);
  return cfold("bld-quar", `<b>Quarantine</b> <span class="${levelClass(d.quarantine_level) || "muted"}">${entries} entries in ${q.length} repo${q.length === 1 ? "" : "s"}</span>`,
    `<div class="panel scroll">${q.map(lane).join("")}</div>`, folds, true);
}

// Infra's CI runs: every run. A read repaints the Infra strip, whose CI count it carries.
const bld = runsTable({ tab: "infra", id: "bld", el: "ci-runs", title: "Runs", none: "No runs in the ledger.", after: () => renderInfra() });

// Infra's CI Tests: the suites of one finished run of a declared test workflow.
const TESTS_PRE = "t";
const TESTS_HINT = "search, or tier:unit state:failed suite:fleet, or a test's name";
const TEST_RESULTS = ["all", "failed", "skipped", "passed"];
const tst = tblTab({
  tab: "infra", id: "tst", pre: TESTS_PRE, el: "ci-tests", api: "/api/tests", hint: TESTS_HINT, state: { cases: null, res: "" },
  params: (p) => { const run = new URLSearchParams(st.views.infra || "").get("trun"); if (run) p.set("trun", run); },
  head: (t) => testsHead(t.data), body: (t) => testsBody(t.data),
  render: () => ciPaint("ci-tests", tst),
  after: () => renderInfra(),
  // An opened suite belongs to the run it was read from: another run shows none open.
  got: (t) => { if (t.cases && t.cases.run !== (t.data.run && t.data.run.id)) { t.sel = null; t.cases = null; t.res = ""; } },
});

const TST_COLS = { state: ["state"], tier: ["tier"], suite: ["suite"], tests: ["tests", "n"], failed: ["failed", "n"], skipped: ["skipped", "n"], time: ["time", "n"] };
const tstKey = (r) => `${r.tier}|${r.suite}`;
const testTime = (s) => (s >= 60 ? secs(s) : s > 0 ? `${s.toFixed(s < 10 ? 2 : 0)}s` : "-");
const testClass = (result) => (result === "failed" ? "bad" : "");

function suiteRow(r) {
  const open = tstKey(r) === tst.sel;
  const row = `<tr class="sr${open ? " sel" : ""}" data-skey="${esc(tstKey(r))}">` +
    `<td class="${levelClass(r.level)}">${esc(r.state)}</td><td>${esc(r.tier)}</td><td class="wrap">${esc(r.suite)}</td>` +
    `<td class="n">${r.tests}</td><td class="n ${r.failed ? "bad" : "muted"}">${r.failed}</td><td class="n muted">${r.skipped}</td><td class="n">${testTime(r.time)}</td></tr>`;
  return open ? row + suiteDetail(r) : row;
}

// The opened suite's tests, failed first, with the result chips filtering them in place.
function suiteDetail(r) {
  const c = tst.cases && tst.cases.key === tstKey(r) ? tst.cases : null;
  let inner = `<span class="muted">reading...</span>`;
  if (c && c.err) inner = `<span class="warn">${esc(c.err)}</span>`;
  else if (c && c.data) {
    const all = c.data.cases, n = (x) => (x === "all" ? all.length : all.filter((t) => t.result === x).length);
    const chips = TEST_RESULTS.map((x) => chipBtn(x === "all" ? !tst.res : tst.res === x, "data-cres", x === "all" ? "" : x, x, n(x))).join("");
    const list = all.filter((t) => !tst.res || t.result === tst.res);
    const lines = list.map((t) => `<div class="cline"><span class="${testClass(t.result)}">${esc(t.result)}</span> ${esc(t.name)} <span class="muted">${testTime(t.time)}</span>` +
      (t.message ? `<pre class="joblog">${esc(t.message)}</pre>` : "") + `</div>`).join("");
    inner = `<div class="seg fseg">${chips}</div>` + (lines || `<div class="muted">No ${esc(tst.res)} tests.</div>`) +
      (c.data.more > 0 ? `<div class="muted">${c.data.more} more not shown; search for a test's name to find it.</div>` : "");
  }
  return `<tr class="wdet"><td colspan="7"><div class="sdet"><div class="muted">${esc(r.tier)} ${esc(r.suite)}</div>${inner}</div></td></tr>`;
}

function testsBody(d) {
  const t = d.table, rows = d.rows || [];
  if (!d.run) return `<div class="panel">No finished run of a declared test workflow in the ledger (testWorkflows in the project map).</div>`;
  const note = d.note ? `<div class="panel muted">${esc(d.note)}</div>` : "";
  if (d.fold) return `<div class="panel"><button class="btn sm" data-ts="passed" title="list the passing suites">${esc(d.fold)}</button></div>`;
  if (!rows.length) return note || `<div class="panel">${t && t.total ? "No suites match." : "No suites in this run."}</div>`;
  return note + `<div class="panel scroll"><table class="tbl">${tblHead(t, TST_COLS)}${rows.map(suiteRow).join("")}</table>` +
    (d.more > 0 ? `<div class="muted">${d.more} more not shown; narrow the search to list them.</div>` : "") + `</div>`;
}

// The run picker: the finished runs of the declared workflows, each by branch, commit, result and age.
function testsPicker(d) {
  if (!d.run) return "";
  const many = new Set(d.runs.map((r) => r.repo)).size > 1;
  const opts = d.runs.map((r) => `<option value="${r.id}"${r.id === d.run.id ? " selected" : ""}>${esc(`${many ? r.repo + " " : ""}${r.branch} ${r.sha} ${r.state}, ${ago(r.started)} ago`)}</option>`).join("");
  const link = /^https:/.test(d.run.url || "") ? ` <a href="${esc(d.run.url)}" target="_blank" rel="noopener">Open run</a>` : "";
  return `<div class="cline"><select data-twin="run" aria-label="CI run">${opts}</select>${link}</div>`;
}

function testsHead(d) {
  let html = `<h2 class="sec" id="sec-tests">Tests <span class="muted">${esc(d.summary || "")}</span></h2>` + testsPicker(d);
  if (tst.err) html += `<div class="panel down">${esc(tst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

// The Tests block, once it has been read. The first look at a run waits on GitHub for its
// artifacts, so the heading shows before the rows do.
tst.block = () => {
  if (!tst.data) return tst.err ? `<div class="panel down">${esc(tst.err)}</div>` : `<h2 class="sec" id="sec-tests">Tests <span class="muted">reading...</span></h2>`;
  if (!tst.data.run) return `<div id="tst-head">${testsHead(tst.data)}</div><div id="tst-body">${testsBody(tst.data)}</div>`;
  const body = tblBodyFirst(tst.data.table, () => testsBody(tst.data));
  return `<div data-tbl="${TESTS_PRE}"><div id="tst-head">${testsHead(tst.data)}</div>${tblBar("tst", tst.data.table, TESTS_HINT)}` +
    `<div id="tst-body">${body}</div></div>`;
};

// A suite's tests, read when its row opens.
async function openSuite(key, r) {
  tst.sel = key;
  tst.res = "";
  const c = tst.cases = { key, run: tst.data.run.id };
  tst.render();
  const q = new URLSearchParams({ run: c.run, tier: r.tier, suite: r.suite });
  try { c.data = await api("/api/tests/cases?" + q); } catch (e) { c.err = e.message; }
  if (st.tab === "infra" && tst.cases === c) tst.render();
}

$("ci-tests").addEventListener("click", (e) => {
  const t = e.target, chip = t.closest("[data-cres]");
  if (chip) { tst.res = chip.dataset.cres; tst.render(); return; }
  if (t.closest("a") || t.closest(".wdet") || t.closest("button")) return;
  const tr = t.closest("tr.sr");
  if (!tr) return;
  const key = tr.dataset.skey;
  if (tst.sel === key) { tst.sel = null; tst.cases = null; tst.render(); return; }
  const r = (tst.data.rows || []).find((x) => tstKey(x) === key);
  if (r) openSuite(key, r);
});

for (const el of ["ci-runs", "ci-tests"]) $(el).addEventListener("toggle", (e) => { if (e.target.dataset?.k) CI_OPEN[e.target.dataset.k] = e.target.open; }, true);

// A new ledger line re-reads both while Infra is open; TABS.infra (infra.js) drives them.
const bldFeed = pushed("infra", ["builds"], bld.refresh);
const tstFeed = pushed("infra", ["builds"], tst.refresh);
