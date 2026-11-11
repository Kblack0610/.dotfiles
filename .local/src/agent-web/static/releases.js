"use strict";
// The Releases tab: every app, what is live where it matters most and its worst status, from
// /api/releases (hub_core::releases). The table is the shared one (table.js): the server filters
// and sorts by the view in the URL. An opened app lists its headline env's channels, the other
// envs in a fold under them, then its changelog. A new snapshot pushes the `releases` event.
// The page is the layout's inner tabs (hub_core::layout, app.js INNER_TABS): Apps (the head, the
// table and an opened app), Builds, Tests, the strip above them.

// Only the "2m ago" changes between snapshots, so this redraws without reading.
const RELEASES_AGE_MS = 60e3;
// Which folds on the tab are open (an app's other envs, the Run times fold), so a repaint keeps them as they were.
const REL_OPEN = {};
const relst = tblTab({
  tab: "releases", id: "rel", el: "releases", api: "/api/releases", hint: "search, or project:binks channel:prod status:drift",
  open: () => REL_OPEN,
  head: (t) => innerStrip("releases", relFlagged()) + innerWrap("releases", "table", releasesHead(t.data)),
  lead: () => innerStrip("releases", relFlagged()),
  body: (t) => releasesBody(t.data),
  wrap: (html) => innerWrap("releases", "table", html),
  tail: () => innerWrap("releases", "builds", releaseBuilds()) + innerWrap("releases", "tests", releaseTests()),
});
// The sections needing a look, the strip's counts: each read says its own (Releases::needs_look,
// Builds::needs_look, a failed suite in the run on show).
const relFlagged = () => [relst.data?.look && "table", bld.data?.look && "builds", tst.data?.totals?.failed_suites > 0 && "tests"].filter(Boolean);

const relKey = (a) => a.project;
const relClass = (level) => (level === "bad" ? "bad" : level === "warn" ? "warn" : "");
// The channel whose detail is open inside an opened app, `project|id`.
let relCh = null;
const chKey = (r) => `${r.project}|${r.id}`;

const REL_COLS = { project: ["app"], live: ["live"], status: ["status"], channels: ["channels"], released: ["released"], last_deploy: ["last deploy"] };

function releaseRow(a) {
  const open = relKey(a) === relst.sel;
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(relKey(a))}">` +
    `<td>${esc(a.project)}</td><td class="wrap">${esc(a.live_text)}</td><td class="${relClass(a.level)}">${esc(a.status_text)}</td>` +
    `<td class="wrap${a.unread ? " warn" : ""}">${esc(a.channels_text)}</td><td class="muted">${esc(a.released_text)}</td>` +
    `<td class="${relClass(a.deploy_level)}">${esc(a.last_deploy_text)}</td></tr>`;
  return open ? row + appDetail(a) : row;
}

// One channel of an opened app; its own detail opens under it on a click.
function channelRow(r) {
  const open = chKey(r) === relCh;
  const where = r.status === "unknown" ? `<span class="warn">${esc(r.live.error || r.pinned.error || "")}</span>` : esc(r.where || "");
  const row = `<tr class="rc${open ? " sel" : ""}" data-ch="${esc(chKey(r))}"><td>${esc(r.channel)}</td><td class="wrap">${esc(r.id)}</td>` +
    `<td class="${r.status === "drift" ? "bad" : ""}">${esc(r.live_text)}</td><td>${esc(r.pinned_text)}</td>` +
    `<td class="${relClass(r.status_level)}">${esc(r.status_text)}</td><td class="wrap muted">${where}</td></tr>`;
  return open ? row + releaseDetail(r) : row;
}

const CH_HEAD = "<tr><th>channel</th><th>id</th><th>live</th><th>pinned</th><th>status</th><th>where</th></tr>";
const chTable = (rows) => `<div class="scroll"><table class="tbl">${CH_HEAD}${rows.map(channelRow).join("")}</table></div>`;

// The opened app: its headline env's channels, the other envs in a fold that starts open, its
// release history, then what the picked tag shipped.
function appDetail(a) {
  const lead = a.channels.slice(0, a.lead), rest = a.channels.slice(a.lead);
  const others = rest.length
    ? cfold(`rel-env:${a.project}`, `<b>${rest.length} other channel${rest.length === 1 ? "" : "s"}</b> <span class="muted">${esc(a.others_text)}</span>`, chTable(rest), REL_OPEN, true)
    : "";
  return `<tr class="wdet"><td colspan="6"><div class="sdet">${chTable(lead)}${others}${releaseHistory(a)}` +
    `<div class="cline"><b>Changelog</b> ${releaseChangelog(a)}</div></div></td></tr>`;
}

// Which tags a history lists, as the collector named the line.
const LINE_SAYS = { release: "release tags", build: "build tags (no release tag yet)" };

// The opened app's releases, newest first: when each was tagged, the one before it, and the
// channels it reached (hub_core::release_graph). A click shows that tag's changelog below.
function releaseHistory(a) {
  const h = a.history || [];
  if (!h.length) return `<div class="cline"><b>Releases</b> <span class="muted">no tags read</span></div>`;
  const shown = relcl.project === a.project ? relcl.data?.tag : null;
  const rows = h.map((s) => `<tr class="rh${s.tag === shown ? " sel" : ""}" data-project="${esc(a.project)}" data-tag="${esc(s.tag)}">` +
    `<td>${esc(s.tag)}</td><td class="n">${esc(s.at_text)}</td><td class="muted">${esc(s.prev || "-")}</td>` +
    `<td class="wrap${s.reached.length ? "" : " muted"}">${esc(s.reached_text)}</td></tr>`).join("");
  const body = `<div class="scroll"><table class="tbl"><tr><th>release</th><th>released</th><th>prev</th><th>reached</th></tr>${rows}</table></div>`;
  return cfold(`rel-hist:${a.project}`, `<b>Releases</b> <span class="muted">${h.length} ${esc(LINE_SAYS[a.line] || "tags")}</span>`, body, REL_OPEN, true);
}

function releaseSide(s, text) {
  return esc(text) + ` <span class="muted">from ${esc(s.source)}${s.image ? ", image " + esc(s.image) : ""}` +
    `${s.build ? ", build " + esc(s.build) : ""}${s.reason ? ": " + esc(s.reason) : ""}</span>` +
    (s.error ? ` <span class="warn">${esc(s.error)}</span>` : "");
}

function releaseWatch(w) {
  return `<div>${esc(w.watch)} <span class="${relClass(w.level)}">${esc(w.state)}</span>${w.since ? ` <span class="muted">since ${when(w.since)}</span>` : ""}</div>`;
}

// The opened app's changelog: one read at a time, and the newest answer wins, so a slow read for
// an app closed since cannot overwrite the one now open.
const relcl = { project: null, data: null, err: null, loading: false, seq: 0 };

async function loadChangelog(project, tag = "") {
  const mine = ++relcl.seq;
  if (relcl.project !== project) relcl.data = null;
  Object.assign(relcl, { project, err: null, loading: true });
  relst.render();
  try {
    const d = await api(`/api/releases/changelog?project=${encodeURIComponent(project)}${tag ? "&tag=" + encodeURIComponent(tag) : ""}`);
    if (mine === relcl.seq) relcl.data = d;
  } catch (e) {
    if (mine === relcl.seq) relcl.err = e.message;
  }
  if (mine !== relcl.seq) return;
  relcl.loading = false;
  relst.render();
}

// What the tag shipped, with every tag of the project to pick from, newest first.
function releaseChangelog(r) {
  const c = relcl, d = c.data;
  if (c.project !== r.project) return "";
  const warn = c.err ? `<span class="warn">${esc(c.err)}</span>` : "";
  if (!d) return warn || `<span class="muted">reading...</span>`;
  const opts = d.tags.map((t) => `<option${t === d.tag ? " selected" : ""}>${esc(t)}</option>`).join("");
  const says = warn || `<span class="muted">${esc(d.range)}, from ${esc(d.source)}${c.loading ? ", reading..." : ""}</span>`;
  const text = c.err ? "" : d.text ? `<div class="md rel-cl">${md(d.text)}</div>` : `<div class="muted">No merged PRs in ${esc(d.range)}.</div>`;
  return `<select class="rel-tag" aria-label="Changelog tag" data-project="${esc(r.project)}">${opts}</select> ${says}${text}`;
}

function releaseDeploy(d) {
  const run = /^https:/.test(d.url || "") ? ` <a href="${esc(d.url)}" target="_blank" rel="noopener">run</a>` : "";
  return `<div>${when(d.at)} ${esc(d.version)}${d.build ? ` <span class="muted">build ${esc(d.build)}</span>` : ""} <span class="${d.state === "fail" ? "warn" : ""}">${esc(d.state)}</span>${run}</div>`;
}

// An opened channel: both sides with their sources, its deploys, watches and deps.
function releaseDetail(r) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const status = [r.drift_since ? `drift since ${when(r.drift_since)}` : "", r.probed_at ? `probed ${when(r.probed_at)}` : ""].filter(Boolean).join(", ");
  return `<tr class="rcd"><td colspan="6"><div class="sdet"><div class="muted">${status || esc(r.status_text)}</div>` +
    line("Pinned", releaseSide(r.pinned, r.pinned_text)) + line("Live", releaseSide(r.live, r.live_text)) +
    line("Tag", esc(r.tag || "")) + line("Where", esc(r.where || "")) +
    line("Prev", esc(r.deploys.prev || "")) + line("Last deploy", r.deploys.last ? esc(r.last_deploy_text) : "") +
    line("Deploys", r.deploys.error ? `<span class="warn">${esc(r.deploys.error)} (${esc(r.deploys.source)})</span>` : r.deploys.history.map(releaseDeploy).join("")) +
    line("Watches", r.telemetry.map(releaseWatch).join("")) + line("Deps", r.deps.length ? esc(r.deps_text) : "") + `</div></td></tr>`;
}

function releasesBody(d) {
  const t = d.table, rows = d.rows || [];
  if (rows.length) return `<div class="panel scroll"><table class="tbl">${tblHead(t, REL_COLS)}${rows.map(releaseRow).join("")}</table></div>`;
  return `<div class="panel">${t && t.total ? "No apps match." : "No apps."}</div>`;
}

function releasesHead(d) {
  const age = d.at ? Date.now() / 1e3 - d.at : 0, stale = d.at && age > d.stale_after;
  const read = d.at ? `refreshed ${clock(d.at * 1e3)} (${ago(d.at)} ago)` : "no snapshot read";
  let html = `<h2 class="sec">Releases <span class="muted">${esc(d.question || "")}</span></h2>` +
    `<div class="cline">${esc(d.summary || "")} <span class="${stale ? "warn" : "muted"}">${esc(read)}</span></div>`;
  if (d.gaps) html += `<div class="cline warn">${esc(d.gaps)}</div>`;
  if (relst.err) html += `<div class="panel down">${esc(relst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

// The Builds inner tab: CI runs of the last 30 days from /api/builds
// (hub_core::builds), its own table with its own view keys (bq, bs, bsort, bdir). It draws inside
// this tab's page, so its render is the tab's and its refresh reads only its own rows.
const BUILDS_PRE = "b";
const BUILDS_HINT = "search, or repo:binks state:red owner:agent-3 workflow:Tests";
const bld = tblTab({
  tab: "releases", id: "bld", pre: BUILDS_PRE, el: "releases", api: "/api/builds", hint: BUILDS_HINT, state: { log: null, detail: null },
  head: (t) => buildsHead(t.data), body: (t) => buildsBody(t.data),
  render: () => relst.render(),
});
// A refresh must not take the focus from either search box: the section repaints when it holds it.
const relRepaint = relst.repaint;
relst.repaint = () => relRepaint() || bld.repaint() || tst.repaint();

const BLD_COLS = { started: ["started", "n"], state: ["state"], repo: ["repo"], workflow: ["workflow"], branch: ["branch"], took: ["took", "n"], usual: ["usual", "n"], eta: ["eta", "n"], owner: ["owner"] };
// A workflow's usual time as "median/p90", "-" below the runs a median needs.
const usualText = (u) => (u ? `${secs(u.median)}/${secs(u.p90)}` : "-");
// A running run's expected end, or once passed how far past it (a past clock reads as on time).
const runEta = (t) => (!t ? "-" : t * 1e3 < Date.now() ? `+${secs(Date.now() / 1e3 - t)}` : when(t));
$("releases").addEventListener("toggle", (e) => { if (e.target.dataset?.k) REL_OPEN[e.target.dataset.k] = e.target.open; }, true);
const bldKey = (r) => `${r.forge}|${r.repo}|${r.id}|${r.attempt}`;

function buildRow(r) {
  const open = bldKey(r) === bld.sel;
  const wait = r.state === "queued" ? `wait ${secs(r.took)}` : secs(r.took);
  const row = `<tr class="br${open ? " sel" : ""}" data-bkey="${esc(bldKey(r))}">` +
    `<td class="n">${when(r.started)}</td><td class="${relClass(r.level)}">${esc(r.state)}</td><td>${esc(r.repo)}</td>` +
    `<td class="wrap">${esc(r.workflow)}</td><td class="wrap muted">${esc(r.branch)}</td><td class="n">${wait}</td>` +
    `<td class="n muted">${usualText(r.usual)}</td><td class="n">${runEta(r.eta)}</td>` +
    `<td class="muted">${esc(r.owner || "-")}</td></tr>`;
  return open ? row + buildDetail(r) : row;
}

function buildDetail(r) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const prs = (r.prs || []).map((n) => `#${n}`).join(" ");
  const log = bld.log && bld.log.key === bldKey(r) ? `<pre class="joblog">${esc(bld.log.text)}</pre>` : "";
  const link = r.url ? `<a href="${esc(r.url)}" target="_blank" rel="noopener">Open run</a>` : "";
  return `<tr class="wdet"><td colspan="9"><div class="sdet"><div class="muted">${esc(r.title || r.workflow)}</div>` +
    line("Run", `${esc(r.forge)} ${esc(r.repo)} #${r.id}${r.attempt > 1 ? " attempt " + r.attempt : ""} ${link}`) +
    line("Event", esc(r.event)) + line("Branch", esc(r.branch)) + line("Owner", esc(r.owner || "")) + line("PRs", esc(prs)) +
    (bld.detail && bld.detail.key === bldKey(r) ? runJobs(bld.detail) : "") + log + `</div></td></tr>`;
}

// The opened run's header, jobs and their steps (/api/builds/detail, hub_core::run_detail), read
// when the row opens. Each cell carries its label, so a phone stacks a job into labelled lines.
function runJobs(o) {
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
  const shas = d.tested_sha && d.workflow_sha && d.tested_sha !== d.workflow_sha
    ? `tested ${esc(d.tested_sha.slice(0, 7))}, workflow from ${esc(d.workflow_sha.slice(0, 7))}` : "";
  const cover = `<div class="cline">${esc(d.coverage_text)}</div>` + (shas ? `<div class="cline">${shas}</div>` : "") +
    ((d.attempts || []).length > 1 ? `<div class="cline"><b>Attempts</b> ${d.attempts.join(", ")}</div>` : "");
  return `<div class="cline"><b>${esc(d.title)}</b></div><div class="cline">${esc(d.header)}</div>` +
    (d.rates_error ? `<div class="cline warn">no rates: ${esc(d.rates_error)}</div>` : "") + jobs +
    (steps ? cfold(`bld-steps:${k}`, `<b>Steps</b>`, steps, REL_OPEN) : "") +
    cfold(`bld-cover:${k}`, `<b>Coverage</b> <span class="muted">${esc(d.coverage)}</span>`, cover, REL_OPEN);
}

function buildsBody(d) {
  const t = d.table, rows = d.rows || [];
  if (!rows.length) return `<div class="panel">${t && t.total ? "No runs match." : "No runs in the ledger."}</div>`;
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, BLD_COLS)}${rows.map(buildRow).join("")}</table>` +
    (d.more > 0 ? `<div class="muted">${d.more} older not shown; narrow the search to list them.</div>` : "") + `</div>`;
}

// The Run times fold: each workflow's usual time over the window, from the same read.
function buildTimes(d) {
  const t = d.times || [];
  if (!t.length) return "";
  const c = d.costs || {}, cost = c.times || [];
  const row = (w, i) => `<tr><td>${esc(w.repo.split("/").pop())}</td><td class="wrap">${esc(w.workflow)}</td><td class="n">${w.runs}</td>` +
    `<td class="n">${w.usual ? secs(w.usual.median) : "-"}</td><td class="n">${w.usual ? secs(w.usual.p90) : "-"}</td>` +
    `<td class="n">${w.runs ? secs(w.longest) : "-"}</td><td class="n">${w.runs ? w.pass + "%" : "-"}</td><td class="n">${w.running || ""}</td><td class="n">${esc(cost[i] || "-")}</td></tr>`;
  const head = "<tr><th>repo</th><th>workflow</th><th>runs</th><th>usual</th><th>p90</th><th>longest</th><th>pass</th><th>running</th><th>$ per run</th></tr>";
  const money = (c.idle || []).map((l) => `<div class="cline">${esc(l)}</div>`).join("") +
    (c.month ? `<div class="cline${c.month_off ? " warn" : ""}">${esc(c.month)}</div>` : "") +
    (c.rates_error ? `<div class="cline warn">no rates: ${esc(c.rates_error)}</div>` : "");
  return cfold("bld-times", `<b>Run times</b> <span class="muted">${t.length} workflows, 30 days, finished runs (cancelled left out); usual is the median, - under 3 runs</span>`,
    `<div class="panel scroll"><table class="tbl">${head}${t.map(row).join("")}</table>${money}</div>`, REL_OPEN, true);
}

// Each repo's test quarantine: its line (entries, the nearest end, the last nightly's KNOWN and
// now-passing counts), then its owner rows, soonest end first. No repo with one draws nothing.
function buildQuarantine(d) {
  const q = d.quarantine || [];
  if (!q.length) return "";
  const row = (r) => `<tr><td>${esc(r.row)}</td><td class="n">${r.entries}</td><td>${esc(r.ends)}</td>` +
    `<td class="n ${relClass(r.level)}">${esc(r.left)}</td></tr>`;
  const head = "<tr><th>owner row</th><th>entries</th><th>ends</th><th>left</th></tr>";
  const lane = (l) => `<div class="cline ${relClass(l.level)}">${esc(l.says)}` +
    (/^https:/.test(l.url || "") ? ` <a href="${esc(l.url)}" target="_blank" rel="noopener">nightly</a>` : "") + `</div>` +
    (l.rows.length ? `<table class="tbl">${head}${l.rows.map(row).join("")}</table>` : "");
  const entries = q.reduce((n, l) => n + l.entries, 0);
  return cfold("bld-quar", `<b>Quarantine</b> <span class="${relClass(d.quarantine_level) || "muted"}">${entries} entries in ${q.length} repo${q.length === 1 ? "" : "s"}</span>`,
    `<div class="panel scroll">${q.map(lane).join("")}</div>`, REL_OPEN, true);
}

function buildsHead(d) {
  const stale = d.at && Date.now() / 1e3 - d.at > d.stale_after;
  let html = `<h2 class="sec" id="sec-builds">Builds <span class="muted">${esc(d.summary || "")}</span>` +
    (stale ? ` <span class="warn">ledger older than ${dur(d.stale_after / 60)}</span>` : "") + `</h2>`;
  if (bld.err) html += `<div class="panel down">${esc(bld.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  // In the head, so a repaint while the search box has focus refreshes it too.
  return html + buildTimes(d) + buildQuarantine(d);
}

// The channels' tail: the Builds block, once it has been read.
function releaseBuilds() {
  if (!bld.data) return bld.err ? `<div class="panel down">${esc(bld.err)}</div>` : "";
  if (!bld.data.table) return `<div id="bld-head">${buildsHead(bld.data)}</div>`;
  const body = tblBodyFirst(bld.data.table, () => buildsBody(bld.data));
  return `<div data-tbl="${BUILDS_PRE}"><div id="bld-head">${buildsHead(bld.data)}</div>${tblBar("bld", bld.data.table, BUILDS_HINT)}` +
    `<div id="bld-body">${body}</div></div>`;
}

// A run's jobs and its failed-job log, read when its row opens and never before.
async function openBuild(key, r) {
  bld.sel = key;
  bld.log = { key, text: "Loading..." };
  bld.detail = { key, d: null };
  relst.render();
  const q = new URLSearchParams({ forge: r.forge, repo: r.repo, run_id: r.id, attempt: r.attempt });
  const detail = api("/api/builds/detail?" + q).then((d) => { bld.detail.d = d; }, (e) => { bld.detail.err = e.message; });
  try { bld.log.text = (await api("/api/builds/log?" + q)) || "(empty)"; } catch (e) { bld.log.text = e.message; }
  await detail;
  if (st.tab === "releases" && bld.sel === key) relst.render();
}

$("releases").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest(".wdet") || t.closest("button")) return;
  const tr = t.closest("tr.br");
  if (!tr) return;
  const key = tr.dataset.bkey;
  if (bld.sel === key) { bld.sel = null; bld.log = null; bld.detail = null; relst.render(); return; }
  const r = (bld.data.rows || []).find((x) => bldKey(x) === key);
  if (r) openBuild(key, r);
});

// The Tests inner tab: the suites of one finished tests.yml run from /api/tests
// (hub_core::junit), the newest unless the picker names another. Its own view keys are tq, ts,
// tsort and tdir, and the run is trun. A suite's tests are read when its row opens, never before.
const TESTS_PRE = "t";
const TESTS_HINT = "search, or tier:unit state:failed suite:fleet, or a test's name";
const TEST_RESULTS = ["all", "failed", "skipped", "passed"];
const tst = tblTab({
  tab: "releases", id: "tst", pre: TESTS_PRE, el: "releases", api: "/api/tests", hint: TESTS_HINT, state: { cases: null, res: "" },
  params: (p) => { const run = new URLSearchParams(st.views.releases || "").get("trun"); if (run) p.set("trun", run); },
  head: (t) => testsHead(t.data), body: (t) => testsBody(t.data),
  render: () => relst.render(),
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
    `<td class="${relClass(r.level)}">${esc(r.state)}</td><td>${esc(r.tier)}</td><td class="wrap">${esc(r.suite)}</td>` +
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
  if (!d.run) return `<div class="panel">No finished run of the tests workflow in the ledger.</div>`;
  const note = d.note ? `<div class="panel muted">${esc(d.note)}</div>` : "";
  if (d.fold) return `<div class="panel"><button class="btn sm" data-ts="passed" title="list the passing suites">${esc(d.fold)}</button></div>`;
  if (!rows.length) return note || `<div class="panel">${t && t.total ? "No suites match." : "No suites in this run."}</div>`;
  return note + `<div class="panel scroll"><table class="tbl">${tblHead(t, TST_COLS)}${rows.map(suiteRow).join("")}</table>` +
    (d.more > 0 ? `<div class="muted">${d.more} more not shown; narrow the search to list them.</div>` : "") + `</div>`;
}

// The run picker: the finished runs of the workflow, each by branch, commit, result and age.
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

// The Builds block's tail: the Tests block, once it has been read. The first look at a run waits
// on GitHub for its artifacts, so the heading shows before the rows do.
function releaseTests() {
  if (!tst.data) return tst.err ? `<div class="panel down">${esc(tst.err)}</div>` : `<h2 class="sec" id="sec-tests">Tests <span class="muted">reading...</span></h2>`;
  if (!tst.data.run) return `<div id="tst-head">${testsHead(tst.data)}</div><div id="tst-body">${testsBody(tst.data)}</div>`;
  const body = tblBodyFirst(tst.data.table, () => testsBody(tst.data));
  return `<div data-tbl="${TESTS_PRE}"><div id="tst-head">${testsHead(tst.data)}</div>${tblBar("tst", tst.data.table, TESTS_HINT)}` +
    `<div id="tst-body">${body}</div></div>`;
}

// A suite's tests, read when its row opens.
async function openSuite(key, r) {
  tst.sel = key;
  tst.res = "";
  const c = tst.cases = { key, run: tst.data.run.id };
  relst.render();
  const q = new URLSearchParams({ run: c.run, tier: r.tier, suite: r.suite });
  try { c.data = await api("/api/tests/cases?" + q); } catch (e) { c.err = e.message; }
  if (st.tab === "releases" && tst.cases === c) relst.render();
}

$("releases").addEventListener("click", (e) => {
  const t = e.target, chip = t.closest("[data-cres]");
  if (chip) { tst.res = chip.dataset.cres; relst.render(); return; }
  if (t.closest("a") || t.closest(".wdet") || t.closest("button")) return;
  const tr = t.closest("tr.sr");
  if (!tr) return;
  const key = tr.dataset.skey;
  if (tst.sel === key) { tst.sel = null; tst.cases = null; relst.render(); return; }
  const r = (tst.data.rows || []).find((x) => tstKey(x) === key);
  if (r) openSuite(key, r);
});

$("releases").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest("button") || t.closest("summary") || t.closest("select") || t.closest("tr.rcd")) return;
  const rh = t.closest("tr.rh");
  if (rh) { loadChangelog(rh.dataset.project, rh.dataset.tag); return; }
  const ch = t.closest("tr.rc");
  if (ch) { relCh = relCh === ch.dataset.ch ? null : ch.dataset.ch; relst.render(); return; }
  if (t.closest(".wdet")) return;
  const tr = t.closest("tr.jr");
  if (!tr) return;
  relst.sel = relst.sel === tr.dataset.key ? null : tr.dataset.key;
  relCh = null;
  if (relst.sel) loadChangelog(relst.sel);
  else relst.render();
});

$("releases").addEventListener("change", (e) => {
  const pick = e.target.closest("select.rel-tag");
  if (pick) loadChangelog(pick.dataset.project, pick.value);
});

const relFeed = pushed("releases", ["releases"], relst.refresh);
const bldFeed = pushed("releases", ["builds"], bld.refresh);
const tstFeed = pushed("releases", ["builds"], tst.refresh);
const ageReleases = poll("releases", () => relst.render(), RELEASES_AGE_MS);
TABS.releases = {
  // Always read: a link from a Projects card arrives here with a new view in the URL.
  show() { relFeed.show(true); bldFeed.show(true); tstFeed.show(true); ageReleases(); },
  onEvent(ev) { relFeed.onEvent(ev); bldFeed.onEvent(ev); tstFeed.onEvent(ev); },
};
