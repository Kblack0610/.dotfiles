// Unit tests for the shared table (.local/src/agent-web/static/table.js) on its first caller,
// Infra's Jobs (jobs.js), run by `node --test` from tests/unit/agent_web_queue.bats. The page's
// real scripts load into one vm context, as the browser loads them; only the DOM is a stub.
// What a query keeps and how it sorts is hub_core::table, tested in Rust; this checks that the
// page draws the server's summary and turns each click into the view keys it sends back.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const on = {};
const fire = (e) => on[e.type].forEach((f) => f(e));
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ??= []).push(f); } });
const parts = { "jobs-head": part(), "jobs-facets": part(), "jobs-chips": part(), "jobs-body": part(), "jobs-tail": part() };
const doc = { getElementById: (id) => (id === "jobs" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
let asked = [];
let body = {};
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: { pathname: "/", hash: "" },
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "infra.js", "actions.js", "jobs.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const jst = run("jst");

const col = (key, sort = null, next = [key, "desc"]) => ({ key, sort, next_sort: next[0], next_dir: next[1] });
// The shape hub_core::table::Summary serializes to, for `source:ci` sorted by start, oldest first.
const table = {
  q: "source:ci", state: "", sort: "started", dir: "asc", total: 3, shown: 2,
  states: [{ name: "all", n: 2 }, { name: "running", n: 1 }, { name: "waiting", n: 0 }, { name: "done", n: 1 }, { name: "failed", n: 1 }],
  columns: [col("state"), col("source"), col("name"), col("started", "asc", ["", "desc"]), col("took"), col("result"), col("detail")],
  facets: [
    { key: "source", on: ["ci"], clear: "", values: [{ value: "agentctl", n: 1, on: false, q: "source:ci source:agentctl" }, { value: "ci", n: 2, on: true, q: "" }] },
    { key: "result", on: [], clear: "source:ci", values: [{ value: "failure", n: 1, on: false, q: "source:ci result:failure" }] },
  ],
};
const job = (name, o = {}) => ({ source: "ci", name, state: "done", ok: true, result: "success", started: 1793942659, finished: null, secs: 60, detail: "", runs: 1, ...o });
const data = { at: 1793942700, window_secs: 86400, errors: [], jobs: [job("playground / Tests", { ok: false, result: "failure" }), job("platform / e2e", { state: "running", ok: null, result: "" })], table };

const target = (attrs) => ({ dataset: attrs, closest: (sel) => (sel === "[data-tsort]" && "tsort" in attrs) || (sel === "[data-ts]" && "ts" in attrs) ? { dataset: attrs } : null });

test("the table draws the server's rows, sort, chips and dropdowns", () => {
  run("st.tab = 'infra'");
  Object.assign(jst, { data, err: null, hist: null, log: null, all: false });
  run("jst.render()");
  const h = box.innerHTML;
  assert.match(h, /<h2 class="sec" id="sec-jobs">Jobs <span class="n">2 of 3<\/span><\/h2>/, "the head is its title and the view's count");
  // When the list was read, and over what window, is a tile after the state tiles (the tblTab's tiles).
  assert.match(run("jobsTiles")(data), /<span class="tl">READ<\/span><span class="tv">\d\d:\d\d<\/span><span class="ts1">last 24h<\/span>/);
  assert.doesNotMatch(h, /in 24h, read/, "no sentence after the title");
  assert.match(h, /<th class="n" aria-sort="ascending"[^>]*><button class="thsort" data-tsort="" data-tdir="desc" title="sort by started">started \^<\/button><\/th>/, "the sorted header says its direction and that a click goes back to the default");
  assert.match(h, /<th[^>]*><button class="thsort" data-tsort="name" data-tdir="desc"[^>]*>name<\/button><\/th>/, "every other header sorts");
  assert.match(h, /<button class="on" data-ts="">all <span class="n">2<\/span><\/button>/, "no chip is every row");
  assert.match(h, /<button class="" data-ts="failed">failed <span class="n">1<\/span><\/button>/);
  assert.match(h, /<tr class="tfilters" data-phone="filters"><td><\/td><th><details class="tfacet on" data-fkey="source" data-fq="source:ci">/, "the filter row sits under the headers, a cell per column");
  assert.match(h, /<details class="tfacet on" data-fkey="source"[^>]*><summary[^>]*>source: ci<\/summary>/, "a filtering column's pill is tinted and names its pick");
  assert.match(h, /<button type="button" class="tfclear" data-tqc="">clear source<\/button>/, "a filtering column can be cleared");
  assert.match(h, /<input type="checkbox" data-tq data-fv="ci" value="" checked> <span>ci<\/span> <span class="n">2<\/span>/, "the picked value is ticked and unticking it is the query without it");
  assert.match(h, /<input type="checkbox" data-tq data-fv="agentctl" value="source:ci source:agentctl"> /, "ticking another adds it to the column's picks");
  assert.match(h, /<details class="tfacet" data-fkey="result" data-fq="source:ci"><summary[^>]*>result<\/summary><div class="tfmenu"><label>/, "a column not filtering has no clear item");
  assert.doesNotMatch(parts["jobs-facets"]?.innerHTML ?? "", /tfacet/);
  assert.equal((h.match(/data-fkey="source"/g) || []).length, 1, "a facet whose column is drawn is not also in the bar");
  assert.match(h, /id="jobs-q" data-tsearch placeholder="[^"]*" value="source:ci"/);
  assert.ok(h.indexOf("playground / Tests") < h.indexOf("platform / e2e"), "the server's order is kept");
});

test("an opened log is headed Log, with the job it is from as a fact in its panel", () => {
  run("st.tab = 'infra'");
  Object.assign(jst, { data, err: null, hist: null, log: { title: "ci gate 10:00", text: "ok" }, all: false });
  run("jst.render()");
  assert.match(box.innerHTML, /<h2 class="sec">Log<\/h2><div class="panel"><div class="pgrow"><span class="pgk">Job<\/span><span class="pgv">ci gate 10:00<\/span><\/div><pre class="joblog">ok<\/pre><\/div>/);
  jst.log = null;
});

test("a job not started reads waiting in STATE, the word its chip and legend use", () => {
  run("st.tab = 'infra'");
  const waiting = job("gate", { state: "queued", ok: null, result: "", secs: 90 });
  Object.assign(jst, { data: { ...data, jobs: [waiting], table: { ...table, legend: "waiting: the job has not started" } }, err: null, hist: null, log: null, all: false });
  run("jst.render()");
  const h = box.innerHTML;
  assert.match(h, /<td>waiting<\/td><td class="muted">ci<\/td>/);
  assert.doesNotMatch(h, /<td>queued<\/td>/);
  assert.match(h, /tlegend">waiting: the job has not started</);
});

test("CI runs are one count line that links to Infra's CI runs", () => {
  run("st.tab = 'infra'");
  Object.assign(jst, { data: { ...data, ci: { says: "9 runs in 30 days: 1 running, 0 queued, 2 red", level: "bad" } }, err: null, hist: null, log: null, all: false });
  run("jst.render()");
  assert.match(box.innerHTML, /CI: <a class="bad" href="#infra\/runs">9 runs in 30 days: 1 running, 0 queued, 2 red<\/a>/);
  Object.assign(jst, { data });
  run("jst.render()");
  assert.doesNotMatch(box.innerHTML, /CI: <a/, "a list with no ledger read draws no line");
});

test("a click or a keystroke becomes the view keys the server reads", () => {
  const patch = (type, attrs, value) => JSON.parse(JSON.stringify(run("tblPatch")({ type, target: { ...target(attrs), value } })));
  assert.deepEqual(patch("click", { tsort: "started", tdir: "asc" }), { sort: "started", dir: "asc" });
  assert.deepEqual(patch("click", { tsort: "", tdir: "desc" }), { sort: "", dir: "" }, "back to the default drops both keys");
  assert.deepEqual(patch("click", { ts: "failed" }), { s: "failed" });
  assert.deepEqual(patch("input", { tsearch: "" }, "nightly -source:k8s"), { q: "nightly -source:k8s" });
  assert.deepEqual(patch("change", { tq: "" }, "source:ci result:failure"), { q: "source:ci result:failure" });
  assert.equal(patch("click", {}), null);
});

test("a view change lands in the URL and the API asks the server for it", async () => {
  asked = [];
  body = data;
  run("st.views.infra = 'q=source%3Aci&sort=started'");
  fire({ type: "click", target: target({ ts: "failed" }) });
  await new Promise((r) => setImmediate(r));
  assert.equal(ctx.history.url, "#infra?q=source%3Aci&sort=started&s=failed");
  assert.equal(asked.at(-1), "/api/jobs?q=source%3Aci&s=failed&sort=started");
  fire({ type: "click", target: target({ tsort: "", tdir: "desc" }) });
  await new Promise((r) => setImmediate(r));
  assert.equal(ctx.history.url, "#infra?q=source%3Aci&s=failed", "the plain sort is a bare URL");
  run('st.tab = "infra"; st.page = "jobs/dream"; jst.refresh()');
  await new Promise((r) => setImmediate(r));
  assert.equal(asked.at(-1), "/api/jobs?q=source%3Aci&s=failed&name=dream", "a history keeps the view");
  run('st.page = ""');
});

test("a refresh while the search box has focus leaves the box alone", () => {
  Object.assign(jst, { data, err: null });
  box.innerHTML = "KEEP";
  doc.activeElement = { id: "jobs-q" };
  run("jst.render()");
  doc.activeElement = null;
  assert.equal(box.innerHTML, "KEEP");
  assert.match(parts["jobs-body"].innerHTML, /playground \/ Tests/);
  assert.match(parts["jobs-chips"].innerHTML, /data-ts="failed"/);
  assert.match(parts["jobs-facets"].innerHTML, /data-tsv/, "the bar keeps its sort dropdown");
  assert.doesNotMatch(parts["jobs-facets"].innerHTML, /tfacet/, "the facets are in the body's filter row");
  assert.match(parts["jobs-body"].innerHTML, /data-fkey="source"/);
});

test("a failed collection says why instead of drawing an empty table", () => {
  Object.assign(jst, { data: { jobs: [], errors: ["gh: rate limited"] }, err: null });
  run("jst.render()");
  assert.match(box.innerHTML, /<div class="card err">gh: rate limited<\/div>/);
});

test("a job's page is its URL: every run of it is read by name, and its host cell opens the machine", async () => {
  asked = [];
  body = { ...data, table: { ...table, links: [{ name: "#infra/jobs/gate", host: "#infra/machines/workstation" }] }, jobs: [job("gate", { source: "unity", runs: 4, host: "workstation" })] };
  run('st.tab = "infra"; st.views.infra = ""; st.page = "jobs/gate"; showJobs()');
  await new Promise((r) => setImmediate(r));
  assert.equal(asked.at(-1), "/api/jobs?name=gate");
  const h = box.innerHTML;
  assert.match(h, /<h2 class="sec" id="sec-jobs">Jobs <span class="n">2 of 3<\/span><\/h2>/);
  assert.match(h, /<div class="cline">Every run of <b>gate<\/b> <a class="btn sm" href="#infra\/jobs">All jobs<\/a><\/div>/, "a job's page keeps its way back to every job");
  assert.match(h, /<a href="#infra\/jobs\/gate" class="muted" title="every run of this job">4 runs<\/a>/);
  assert.match(h, /<td class="muted"><a class="tl" href="#infra\/machines\/workstation">workstation<\/a><\/td>/);
  run('st.page = ""; showJobs()');
  assert.equal(jst.hist, "", "leaving the page drops the rows read for it");
  assert.equal(jst.data, null);
});
