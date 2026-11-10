// Unit tests for the Releases tab (.local/src/agent-web/static/releases.js), run by `node --test`
// from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. What a row says and what folds is hub_core::releases,
// tested in Rust; this checks that the page draws them and turns each click into the view it asks for.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : (() => el())),
  set: (t, k, v) => { t[k] = v; return true; },
});
const on = {};
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ||= []).push(f); } });
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
const parts = { "rel-head": part(), "rel-facets": part(), "rel-chips": part(), "rel-body": part(), "rel-tail": part(), "bld-head": part(), "bld-facets": part(), "bld-chips": part(), "bld-body": part(), "tst-head": part(), "tst-facets": part(), "tst-chips": part(), "tst-body": part() };
const doc = { body: el(), getElementById: (id) => (id === "releases" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, activeElement: null, hidden: false };
const asked = [];
let body = {};
let builds = {};
let tests = {};
let cases = {};
const loc = { pathname: "/", hash: "" };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: loc,
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async (url) => {
    asked.push(url);
    const text = url.startsWith("/api/builds/log");
    const json = url.startsWith("/api/tests/cases") ? cases : url.startsWith("/api/tests") ? tests : url.startsWith("/api/builds") ? builds : body;
    return { ok: true, status: 200, headers: { get: () => (text ? "text/plain" : "application/json") }, json: async () => json, text: async () => "FAIL: step 3 exited 1" };
  },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "table.js", "actions.js", "jobs.js", "schedules.js", "releases.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx);
const run = (src) => vm.runInContext(src, ctx);
const relst = run("relst");
const settled = () => new Promise((r) => setImmediate(r));

const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = {
  q: "", state: "", sort: "", dir: "", total: 3, shown: 2,
  states: [{ name: "all", n: 3 }, { name: "attention", n: 1 }, { name: "green", n: 2 }],
  columns: ["project", "channel", "pinned", "live", "status", "prev", "last_deploy", "telemetry", "deps", "id", "where"].map(col),
  facets: [],
};
const NOW = () => Math.round(Date.now() / 1e3);
const drift = {
  project: "binks", id: "binks-prod", label: "prod binks-prod", where: "home-k3s", tag: "v2", status: "drift", status_level: "bad", watch_level: "bad", level: "bad",
  pinned: { value: "v2", source: "manifest" }, live: { value: "v1", source: "k8s", image: "reg/binks:v1", error: null },
  pinned_text: "v2", live_text: "v1", telemetry_text: "0/1", deps_text: "unity-core v0.5.0", deps: ["unity-core"],
  telemetry: [{ watch: "binks-probe", state: "TRIP", level: "bad", since: 1793942659 }], drift_since: 1793942659, probed_at: 1793942700,
  prev_text: "v0", last_deploy_text: "11-06 15:00 fail", deploy_level: "warn",
  deploys: { source: "o/r", error: null, prev: "v0", history: [
    { version: "v2", state: "fail", at: 1793942659, url: "https://github.test/run/9" },
    { version: "v1", state: "ok", at: 1793942000, url: "javascript:alert(1)" },
  ] },
};
const data = (o = {}) => ({
  at: NOW() - 120, question: "What is building, and what is live where?", summary: "3 channels: 1 drift, 2 ok", stale_after: 3600, errors: [], table,
  rows: [drift], fold: "2 channels green: 2 ok (a-prod, b-prod)", ...o,
});

const target = (attrs, tr = null) => ({ dataset: attrs, closest: (sel) => (sel === "tr.jr" ? tr : sel === "[data-ts]" && "ts" in attrs ? { dataset: attrs } : null) });
const show = (d = data()) => {
  run("st.tab = 'releases'");
  Object.assign(relst, { data: d, err: null, sel: null });
  Object.assign(run("relcl"), { project: null, data: null, err: null });
  run("relst.render()");
};

test("the head asks the tab's question, counts the channels and says the snapshot's age", () => {
  show();
  const h = box.innerHTML;
  assert.match(h, /What is building, and what is live where\?/);
  assert.match(h, /3 channels: 1 drift, 2 ok/);
  assert.match(h, /refreshed .* \(2m ago\)/);
  assert.doesNotMatch(h, /class="warn">refreshed/);
});

test("a snapshot older than the collector's cadence is amber", () => {
  show(data({ at: NOW() - 7200 }));
  assert.match(box.innerHTML, /class="warn">refreshed/);
});

test("no snapshot names the error instead of drawing a stale table", () => {
  show(data({ at: 0, rows: [], fold: null, summary: "not read", errors: ["release-state show: no snapshot yet"], table: { ...table, total: 0 } }));
  assert.match(box.innerHTML, /release-state show: no snapshot yet/);
  assert.match(box.innerHTML, /No channels\./);
});

test("a row draws its cells and colours drift and a tripped watch red", () => {
  show();
  const b = box.innerHTML;
  assert.match(b, /prod binks-prod/);
  assert.match(b, /<td class="bad">v1<\/td><td class="bad">drift<\/td>/);
  assert.match(b, /<td class="bad">0\/1<\/td>/);
});

test("the fold is one line, and clicking it is the green chip's view", () => {
  show();
  const b = box.innerHTML;
  assert.match(b, /data-ts="green"[^>]*>2 channels green: 2 ok \(a-prod, b-prod\)</);
  assert.deepEqual({ ...run("tblPatch")({ type: "click", target: target({ ts: "green" }) }) }, { s: "green" });
});

test("when everything is green the table says so and keeps the fold", () => {
  show(data({ rows: [] }));
  const b = box.innerHTML;
  assert.match(b, /Nothing needs attention\./);
  assert.match(b, /2 channels green/);
});

test("clicking a row opens its versions, every watch and its deps, and clicking again closes it", () => {
  show();
  body = changelog();
  const tr = { dataset: { key: "binks|binks-prod" } };
  fire("click", { type: "click", target: target({}, tr) });
  const b = box.innerHTML;
  assert.match(b, /<b>Pinned<\/b> v2 <span class="muted">from manifest/);
  assert.match(b, /image reg\/binks:v1/);
  assert.match(b, /binks-probe <span class="bad">TRIP/);
  assert.match(b, /<b>Deps<\/b> unity-core v0.5.0/);
  fire("click", { type: "click", target: target({}, tr) });
  assert.doesNotMatch(box.innerHTML, /<b>Pinned/);
});

const changelog = (o = {}) => ({
  project: "binks", tag: "binks-v2", prev: "binks-v1", source: "merged PRs", range: "binks-v1..binks-v2",
  text: "- fix the **probe** (#7)", tags: ["binks-v3", "binks-v2", "binks-v1"], ...o,
});
const open = async (d = changelog()) => {
  show();
  body = d;
  asked.length = 0;
  fire("click", { type: "click", target: target({}, { dataset: { key: "binks|binks-prod" } }) });
  await settled();
};

test("opening a row reads its project's newest changelog and draws it under a tag picker", async () => {
  await open();
  assert.deepEqual(asked, ["/api/releases/changelog?project=binks"]);
  const b = box.innerHTML;
  assert.match(b, /<b>Changelog<\/b> <select class="rel-tag"[^>]*data-project="binks">/);
  assert.match(b, /<option>binks-v3<\/option><option selected>binks-v2<\/option><option>binks-v1<\/option>/);
  assert.match(b, /binks-v1\.\.binks-v2, from merged PRs/);
  assert.match(b, /fix the <strong>probe<\/strong> \(#7\)/);
});

test("picking another tag reads that tag, and a tag with nothing in it says so", async () => {
  await open();
  asked.length = 0;
  body = changelog({ tag: "binks-v1", prev: null, range: "binks-v1", text: "" });
  const select = { dataset: { project: "binks" }, value: "binks-v1" };
  fire("change", { type: "change", target: { closest: (sel) => (sel === "select.rel-tag" ? select : null) } });
  await settled();
  assert.deepEqual(asked, ["/api/releases/changelog?project=binks&tag=binks-v1"]);
  assert.match(box.innerHTML, /No merged PRs in binks-v1\./);
  // A change on anything else is not a pick.
  asked.length = 0;
  fire("change", { type: "change", target: { closest: () => null } });
  await settled();
  assert.equal(asked.length, 0);
});

test("a changelog the collector refused is said in the row, not left reading", async () => {
  show();
  const real = ctx.fetch;
  ctx.fetch = async () => ({ ok: false, status: 400, statusText: "Bad Request", text: async () => "release-state: binks has no release tags", headers: { get: () => "text/plain" } });
  fire("click", { type: "click", target: target({}, { dataset: { key: "binks|binks-prod" } }) });
  await settled();
  ctx.fetch = real;
  assert.match(box.innerHTML, /class="warn">Could not read releases \(HTTP 400\): release-state: binks has no release tags/);
});

test("a pick the collector refuses keeps the tag picker, so another tag can be tried", async () => {
  await open();
  const real = ctx.fetch;
  ctx.fetch = async () => ({ ok: false, status: 502, statusText: "Bad Gateway", text: async () => "release-state: gone", headers: { get: () => "text/plain" } });
  const select = { dataset: { project: "binks" }, value: "binks-v1" };
  fire("change", { type: "change", target: { closest: (sel) => (sel === "select.rel-tag" ? select : null) } });
  await settled();
  ctx.fetch = real;
  assert.match(box.innerHTML, /class="warn">Could not read releases \(HTTP 502\): release-state: gone/);
  assert.match(box.innerHTML, /<select class="rel-tag"[^>]*>.*<option>binks-v1<\/option>/);
  assert.doesNotMatch(box.innerHTML, /fix the/);
});

const bcol = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const red = {
  forge: "github.com", repo: "binks", id: 77, attempt: 2, workflow: "Tests", title: "fix the gate", branch: "agent-3/gate", event: "pull_request", sha: "abc", status: "completed",
  conclusion: "failure", prs: [12], url: "https://github.com/o/binks/actions/runs/77", owner: "agent-3", state: "red", level: "bad", started: NOW() - 300, took: 125,
};
const bdata = (o = {}) => ({
  at: NOW() - 60, summary: "2 runs in 30 days: 0 running, 0 queued, 1 red", stale_after: 1800, rows: [red], more: 0, errors: [],
  table: { q: "", state: "", sort: "", dir: "", total: 2, shown: 1, states: [{ name: "all", n: 2 }, { name: "red", n: 1 }], columns: ["started", "state", "repo", "workflow", "branch", "took", "owner", "forge", "event", "title"].map(bcol), facets: [] },
  ...o,
});
const showBuilds = (d = bdata()) => { show(); Object.assign(run("bld"), { data: d, err: null, sel: null, log: null }); run("relst.render()"); };
const brow = (key) => ({ dataset: { bkey: key }, closest: (sel) => (sel === "tr.br" ? { dataset: { bkey: key } } : null) });
const BKEY = "github.com|binks|77|2";

test("the Builds section sits under the channels with each run's owner and state", () => {
  showBuilds();
  const b = box.innerHTML;
  assert.match(b, /<div data-tbl="b"><div id="bld-head"><h2 class="sec" id="sec-builds">Builds <span class="muted">2 runs in 30 days: 0 running, 0 queued, 1 red/);
  assert.match(b, /<td class="bad">red<\/td><td>binks<\/td><td class="wrap">Tests<\/td>/);
  assert.match(b, /<td class="muted">agent-3<\/td>/);
  assert.ok(b.indexOf("Builds") > b.indexOf("prod binks-prod"), "after the channels");
});

test("a run with no owning session draws a dash, and an empty ledger says so", () => {
  showBuilds(bdata({ rows: [{ ...red, owner: "" }] }));
  assert.match(box.innerHTML, /<td class="muted">-<\/td>/);
  showBuilds(bdata({ rows: [], table: { ...bdata().table, total: 0, shown: 0 } }));
  assert.match(box.innerHTML, /No runs in the ledger\./);
});

test("a ledger that is not being refreshed is amber", () => {
  showBuilds(bdata({ at: NOW() - 7200 }));
  assert.match(box.innerHTML, /class="warn">ledger older than 30m/);
});

test("opening a run reads its log then, and only then; clicking again closes it", async () => {
  showBuilds();
  asked.length = 0;
  fire("click", { type: "click", target: brow(BKEY) });
  await settled();
  assert.deepEqual(asked, ["/api/builds/log?forge=github.com&repo=binks&id=77&attempt=2"]);
  const b = box.innerHTML;
  assert.match(b, /<pre class="joblog">FAIL: step 3 exited 1<\/pre>/);
  assert.match(b, /<b>Run<\/b> github.com binks #77 attempt 2/);
  assert.match(b, /<b>PRs<\/b> #12/);
  fire("click", { type: "click", target: brow(BKEY) });
  assert.doesNotMatch(box.innerHTML, /joblog/);
});

test("the Builds table sorts and filters under its own view keys", async () => {
  showBuilds();
  const patch = run("tblPatch")({ type: "input", target: { dataset: { tsearch: "" }, value: "repo:binks" } });
  assert.deepEqual({ ...patch }, { q: "repo:binks" });
  run("st.tab = 'releases'; st.views.releases = 'q=project%3Abinks&bq=repo%3Abinks&bsort=took'");
  assert.equal(run("tblParams(st.views.releases, BUILDS_PRE).toString()"), "bq=repo%3Abinks&bsort=took");
  assert.equal(run("tblParams(st.views.releases).toString()"), "q=project%3Abinks");
  run("st.views.releases = ''");
});

test("a builds event re-reads the builds alone, and only while the tab is open", async () => {
  builds = bdata();
  body = data();
  run("st.tab = 'releases'");
  asked.length = 0;
  run("TABS.releases").onEvent({ kind: "builds" });
  await settled();
  assert.deepEqual(asked, ["/api/builds", "/api/tests"]);
  run("st.tab = 'home'");
  asked.length = 0;
  run("TABS.releases").onEvent({ kind: "builds" });
  await settled();
  assert.equal(asked.length, 0);
});

const tcol = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const suite = (o) => ({ tier: "unit", suite: "a.bats", tests: 4, passed: 2, failed: 1, skipped: 1, time: 1.25, state: "failed", level: "bad", ...o });
const pickRun = (id, o = {}) => ({ repo: "o/binks", id, attempt: 1, branch: "main", sha: "abc1234", title: "t", state: "red", level: "bad", started: NOW() - 600, prs: [], url: `https://github.com/o/binks/actions/runs/${id}`, ...o });
const tdata = (o = {}) => ({
  at: NOW() - 60, stale_after: 1800, runs: [pickRun(9), pickRun(8, { state: "green", branch: "feat/x" })], run: pickRun(9),
  summary: "main abc1234: 5 tests in 2 suites: 1 failed, 1 skipped, 3 passed", totals: { suites: 2, tests: 5, passed: 3, failed: 1, skipped: 1, failed_suites: 1, time: 2 },
  rows: [suite(), suite({ tier: "ui", suite: "c.bats", tests: 1, passed: 1, failed: 0, skipped: 0, state: "passed", level: "ok", time: 70 })], more: 0, fold: null, note: null, errors: [],
  table: { q: "", state: "", sort: "", dir: "", total: 2, shown: 2, states: [{ name: "all", n: 2 }, { name: "failed", n: 1 }, { name: "skipped", n: 0 }, { name: "passed", n: 1 }], columns: ["state", "tier", "suite", "tests", "failed", "skipped", "time"].map(tcol), facets: [] },
  ...o,
});
const showTests = (d = tdata()) => { show(); Object.assign(run("tst"), { data: d, err: null, sel: null, cases: null, res: "" }); run("relst.render()"); };
const srow = (key) => ({ dataset: { skey: key }, closest: (sel) => (sel === "tr.sr" ? { dataset: { skey: key } } : null) });

test("the Tests section sits under Builds with the run's totals, its picker and each suite", () => {
  showBuilds();
  showTests();
  const b = box.innerHTML;
  assert.match(b, /<div data-tbl="t"><div id="tst-head"><h2 class="sec" id="sec-tests">Tests <span class="muted">main abc1234: 5 tests in 2 suites: 1 failed/);
  assert.ok(b.indexOf("sec-tests") > b.indexOf("sec-builds"), "after the Builds section");
  assert.match(b, /<select data-twin="run" aria-label="CI run"><option value="9" selected>main abc1234 red, [^<]* ago<\/option><option value="8">feat\/x abc1234 green/);
  assert.match(b, /<td class="bad">failed<\/td><td>unit<\/td><td class="wrap">a.bats<\/td><td class="n">4<\/td><td class="n bad">1<\/td><td class="n muted">1<\/td><td class="n">1.25s<\/td>/);
  assert.match(b, /<td class="n muted">0<\/td><td class="n">1m<\/td>/);
});

test("a green run is one line that lists its suites through the passed chip", () => {
  showTests(tdata({ rows: [], fold: "All green: 5 tests in 2 suites: 0 failed, 1 skipped, 4 passed" }));
  assert.match(box.innerHTML, /<button class="btn sm" data-ts="passed"[^>]*>All green: 5 tests in 2 suites/);
  assert.doesNotMatch(box.innerHTML, /<tr class="sr/);
});

test("a run with no artifacts says why, and no run at all says so", () => {
  showTests(tdata({ rows: [], note: "this run uploaded no junit-* artifact", summary: "main abc1234: no results", table: { ...tdata().table, total: 0, shown: 0 } }));
  assert.match(box.innerHTML, /<div class="panel muted">this run uploaded no junit-\* artifact/);
  showTests(tdata({ run: null, runs: [], rows: [], summary: "no finished run of the tests workflow in the ledger" }));
  assert.match(box.innerHTML, /No finished run of the tests workflow in the ledger\./);
  assert.doesNotMatch(box.innerHTML, /<select data-twin="run"/);
});

test("opening a suite reads its tests then, failed first with a result filter, and again closes it", async () => {
  showTests();
  cases = { more: 0, cases: [{ name: "fails here", result: "failed", time: 0.2, message: "line 2: [ 1 -gt 2 ] failed" }, { name: "skipped one", result: "skipped", time: 0, message: "not on CI" }, { name: "passes", result: "passed", time: 0.1, message: "" }] };
  asked.length = 0;
  fire("click", { type: "click", target: srow("unit|a.bats") });
  await settled();
  assert.deepEqual(asked, ["/api/tests/cases?run=9&tier=unit&suite=a.bats"]);
  let b = box.innerHTML;
  assert.match(b, /<span class="bad">failed<\/span> fails here <span class="muted">0.20s<\/span><pre class="joblog">line 2: \[ 1 -gt 2 \] failed<\/pre>/);
  assert.match(b, /data-cres="failed">failed <span class="n">1<\/span>/);
  fire("click", { type: "click", target: { closest: (sel) => (sel === "[data-cres]" ? { dataset: { cres: "skipped" } } : null) } });
  b = box.innerHTML;
  assert.match(b, /skipped one/);
  assert.doesNotMatch(b, /fails here|passes/);
  fire("click", { type: "click", target: srow("unit|a.bats") });
  assert.doesNotMatch(box.innerHTML, /skipped one/);
});

test("an opened suite is let go when the table is read for another run", async () => {
  showTests();
  run("tst.sel = 'unit|a.bats'; tst.cases = { key: 'unit|a.bats', run: 9, data: { cases: [], more: 0 } }");
  tests = tdata({ run: pickRun(8, { state: "green" }) });
  await run("tst.refresh()");
  assert.equal(run("tst.sel"), null);
  assert.equal(run("tst.cases"), null);
  tests = {};
});

test("the Tests table sorts under its own keys and the run picker names the run in the URL", async () => {
  showTests();
  run("st.tab = 'releases'; st.views.releases = 'bq=x&tq=tier%3Aui&tsort=time&trun=8'");
  assert.equal(run("tblParams(st.views.releases, TESTS_PRE).toString()"), "tq=tier%3Aui&tsort=time");
  const pick = run("tblPatch")({ type: "change", target: { dataset: { twin: "run" }, value: "8" } });
  assert.deepEqual({ ...pick }, { run: "8" });
  assert.equal(run("tblSet('q=1', { run: '8' }, 't')"), "q=1&trun=8");
  asked.length = 0;
  await run("tst.refresh()");
  assert.deepEqual(asked, ["/api/tests?tq=tier%3Aui&tsort=time&trun=8"]);
  run("st.views.releases = ''");
});

test("a new snapshot re-reads only while the tab is open", async () => {
  body = data();
  run("st.tab = 'releases'");
  asked.length = 0;
  run("TABS.releases").onEvent({ kind: "releases" });
  await settled();
  assert.equal(asked.filter((u) => u.startsWith("/api/releases")).length, 1);
  run("st.tab = 'home'");
  asked.length = 0;
  run("TABS.releases").onEvent({ kind: "releases" });
  await settled();
  assert.equal(asked.length, 0);
  run("TABS.releases").onEvent({ kind: "costs" });
  await settled();
  assert.equal(asked.length, 0);
});

test("showing the tab reads the view in the URL, which a Projects badge links to", async () => {
  body = data();
  run("st.tab = 'releases'; st.views.releases = 'q=project%3Abinks'");
  asked.length = 0;
  run("TABS.releases").show();
  await settled();
  assert.equal(asked[0], "/api/releases?q=project%3Abinks");
  run("st.views.releases = ''");
});

test("a row says what came before and how the last deploy ended, and opens on its runs", () => {
  show();
  const closed = box.innerHTML;
  assert.match(closed, />v0<\/td>/);
  assert.match(closed, /class="warn">11-06 15:00 fail</);
  relst.sel = "binks|binks-prod";
  run("relst.render()");
  const open = box.innerHTML;
  assert.match(open, /<a href="https:\/\/github\.test\/run\/9"[^>]*>run<\/a>/);
  assert.doesNotMatch(open, /javascript:/, "only an https run is a link");
  assert.match(open, /<td colspan="9">/);
});
