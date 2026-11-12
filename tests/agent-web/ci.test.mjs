// Unit tests for Infra's CI runs and Tests sections (.local/src/agent-web/static/ci.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm
// context, as the browser loads them; only the DOM is a stub. What a run row says is
// hub_core::builds and a suite hub_core::junit, tested in Rust; this checks that the page draws
// them and turns each click into the read or view it asks for.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : (() => el())),
  set: (t, k, v) => { t[k] = v; return true; },
});
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [], dataset: {} });
// Each section's element keeps its own listeners, as the page's #ci-runs, #ci-pipelines and #ci-tests do.
const boxOf = () => { const on = {}; return Object.assign(part(), { on, addEventListener: (ev, f) => { (on[ev] ||= []).push(f); } }); };
const runs = boxOf(), pipes_ = boxOf(), tests_ = boxOf();
const fire = (box, ev, e) => (box.on[ev] || []).forEach((f) => f(e));
const parts = { "ci-runs": runs, "ci-pipelines": pipes_, "ci-tests": tests_, "infra-main": part(), jobs: part() };
const doc = { body: el(), getElementById: (id) => (parts[id] ||= part()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, activeElement: null, hidden: false };
const asked = [];
let builds = {};
let tests = {};
let cases = {};
let detail = {};
let pipes = {};
let pdetail = {};
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
    const json = url.startsWith("/api/tests/cases") ? cases : url.startsWith("/api/tests") ? tests : url.startsWith("/api/builds/detail") ? detail : url.startsWith("/api/builds") ? builds
      : url.startsWith("/api/pipelines/detail") ? pdetail : url.startsWith("/api/pipelines") ? pipes : {};
    return { ok: true, status: 200, headers: { get: () => (text ? "text/plain" : "application/json") }, json: async () => json, text: async () => "FAIL: step 3 exited 1" };
  },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "infra.js", "actions.js", "jobs.js", "ci.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const settled = () => new Promise((r) => setImmediate(r));
const NOW = () => Math.round(Date.now() / 1e3);

const bcol = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const red = {
  forge: "github.com", repo: "binks", id: 77, attempt: 2, workflow: "Tests", title: "fix the gate", branch: "agent-3/gate", event: "pull_request", sha: "abc", status: "completed",
  conclusion: "failure", prs: [12], url: "https://github.com/o/binks/actions/runs/77", owner: "agent-3", state: "red", level: "bad", started: NOW() - 300, took: 125, release: null,
};
const bdata = (o = {}) => ({
  at: NOW() - 60, summary: "2 runs in 30 days: 0 running, 0 queued, 1 red", stale_after: 1800, rows: [red], more: 0, errors: [],
  table: { q: "", state: "", sort: "", dir: "", total: 2, shown: 1, states: [{ name: "all", n: 2 }, { name: "red", n: 1 }], columns: ["started", "state", "repo", "workflow", "branch", "took", "owner", "release", "forge", "event", "title"].map(bcol), facets: [] },
  ...o,
});
const prow = (o = {}) => ({
  state: "red", why: "the last 2 runs failed", forge: "github.com", repo: "o/play", project: "unity-core-playground", pipeline: "Tests (all)", file: ".github/workflows/test.yml",
  trigger: "night", nightly: "on", schedule: "nightly 02:00 on playground-night", next: NOW() + 3600, runner: "playground-night", last: NOW() - 7200, last_id: 41, last_result: "failure",
  pass: 60, runs: 5, usual: 1500, p90: 2400, running: 0, ...o,
});
const pdata = (o = {}) => ({
  at: NOW() - 60, summary: "2 pipelines in 1 repo: 1 red", red: 1, errors: [],
  rows: [prow(), prow({ state: "green", why: "passing", pipeline: "Lint", file: ".github/workflows/lint.yml", trigger: "push", nightly: "", schedule: "", next: null, last_result: "success", pass: 100, running: 1 })],
  table: { q: "", state: "", sort: "", dir: "", total: 2, shown: 2, states: [{ name: "all", n: 2 }, { name: "red", n: 1 }], facets: [],
    columns: ["state", "repo", "pipeline", "trigger", "nightly", "schedule", "next", "last", "pass", "runs", "usual", "p90"].map(bcol),
    links: [{ repo: "#projects/unity-core-playground", next: "#schedules/playground-night", last: "#infra/runs/o%2Fplay%2F41" }, { repo: "#projects/unity-core-playground" }] },
  ...o,
});
pipes = pdata(); // every Infra show reads the pipelines too
const showPipes = (d = pdata()) => { run("st.tab = 'infra'; st.arg = 'pipelines'"); Object.assign(run("pip"), { data: d, err: null, sel: null, detail: null }); run("pip.render()"); };
const prowEl = (key) => ({ dataset: { pkey: key }, closest: (sel) => (sel === "tr.pipr" ? { dataset: { pkey: key } } : null) });
const showBuilds = (d = bdata()) => { run("st.tab = 'infra'; st.arg = 'runs'"); Object.assign(run("bld"), { data: d, err: null, sel: null, log: null, detail: null }); run("bld.render()"); };
const brow = (key) => ({ dataset: { bkey: key }, closest: (sel) => (sel === "tr.br" ? { dataset: { bkey: key } } : null) });
const BKEY = "github.com|binks|77|2";

test("the CI runs section lists each run's state, owner and the release it ran on", () => {
  showBuilds(bdata({ rows: [red, { ...red, id: 78, release: { project: "binks", tag: "v1.2.0" } }] }));
  const b = runs.innerHTML;
  assert.match(b, /<div data-tbl="b"><div id="bld-head"><h2 class="sec" id="sec-runs">Runs <span class="muted">2 runs in 30 days: 0 running, 0 queued, 1 red/);
  assert.match(b, /<td class="bad">red<\/td><td>binks<\/td><td class="wrap">Tests<\/td>/);
  assert.match(b, /<td class="muted">agent-3<\/td><td class="muted">-<\/td><\/tr>/, "no release draws a dash");
  assert.match(b, /<td class="muted">v1.2.0<\/td><\/tr>/);
});

test("a run with no owning session draws a dash, and an empty ledger says so", () => {
  showBuilds(bdata({ rows: [{ ...red, owner: "" }] }));
  assert.match(runs.innerHTML, /<td class="muted">-<\/td><td class="muted">-<\/td>/);
  showBuilds(bdata({ rows: [], table: { ...bdata().table, total: 0, shown: 0 } }));
  assert.match(runs.innerHTML, /No runs in the ledger\./);
});

test("a ledger that is not being refreshed is amber", () => {
  showBuilds(bdata({ at: NOW() - 7200 }));
  assert.match(runs.innerHTML, /class="warn">ledger older than 30m/);
});

test("the runs draw only while Infra is the open tab", () => {
  runs.innerHTML = "";
  run("st.tab = 'releases'");
  Object.assign(run("bld"), { data: bdata() });
  run("bld.render()");
  assert.equal(runs.innerHTML, "");
});

test("opening a run reads its log then, and only then; clicking again closes it", async () => {
  showBuilds(bdata({ rows: [{ ...red, release: { project: "binks", tag: "v1.2.0" } }] }));
  asked.length = 0;
  fire(runs, "click", { type: "click", target: brow(BKEY) });
  await settled();
  const q = "forge=github.com&repo=binks&run_id=77&attempt=2";
  assert.deepEqual(asked, [`/api/builds/detail?${q}`, `/api/builds/log?${q}`]);
  const b = runs.innerHTML;
  assert.match(b, /<pre class="joblog">FAIL: step 3 exited 1<\/pre>/);
  assert.match(b, /<b>Run<\/b> github.com binks #77 attempt 2/);
  assert.match(b, /<b>PRs<\/b> #12/);
  assert.match(b, /<b>Release<\/b> binks v1.2.0/);
  assert.match(b, /<td colspan="10">/, "the detail spans every column, release included");
  fire(runs, "click", { type: "click", target: brow(BKEY) });
  assert.doesNotMatch(runs.innerHTML, /joblog/);
});

const job = (i, o = {}) => ({
  name: `PlayMode ${i}`, class: "aws/on-demand", wait_text: "1m", took_text: "32m45", runner: "aws-burst-1-pool-2",
  price: { usd: 0.2, basis: "on-demand", text: "$0.20 (1/5 of $1.855/h)" }, steps_text: "checkout 2s, PlayMode 32m40", ...o,
});
const rdetail = (o = {}) => ({
  key: { forge: "github.com", repo: "binks", id: 77, attempt: 2 }, title: "#77 Tests red 46m $0.20 + no rate",
  header: "end to end 46m | before first job 2m | runner time 1h42 | tested abc1234 | partial", coverage: "partial",
  coverage_text: "partial: the archive holds 2 of the run's jobs so far", attempts: [1, 2],
  jobs: [job(1), job(2, { class: "hosted", runner: "github-hosted", price: { usd: null, basis: "", text: "no rate" } })], rates_error: null, ...o,
});

test("an opened run shows its header, every job with its price, the steps and the coverage", async () => {
  detail = rdetail({ jobs: Array.from({ length: 130 }, (_, i) => job(i)) });
  showBuilds();
  fire(runs, "click", { type: "click", target: brow(BKEY) });
  await settled();
  const b = runs.innerHTML;
  assert.match(b, /<b>#77 Tests red 46m \$0.20 \+ no rate<\/b>/);
  assert.match(b, /end to end 46m \| before first job 2m/);
  assert.equal((b.match(/<td data-label="job"/g) || []).length, 130, "every job, none capped");
  assert.match(b, /<td data-label="\$" class="n">\$0.20 \(1\/5 of \$1.855\/h\)<\/td>/);
  assert.match(b, /<b>Steps<\/b>/);
  assert.match(b, /<b>Coverage<\/b> <span class="muted">partial<\/span>/);
  assert.match(b, /<b>Attempts<\/b> 1, 2/);
  fire(runs, "click", { type: "click", target: brow(BKEY) });
  detail = rdetail();
  fire(runs, "click", { type: "click", target: brow(BKEY) });
  await settled();
  assert.match(runs.innerHTML, /<td data-label="runner" class="wrap muted">github-hosted<\/td><td data-label="\$" class="n">no rate<\/td>/);
  fire(runs, "click", { type: "click", target: brow(BKEY) });
});

// The Run times fold went to Pipelines (usual, p90, pass); the runs are the table alone.
test("the runs carry no Run times fold, and their counts are Runners' failed 24h link to the red runs", () => {
  showBuilds(bdata({ counts: { total: 2, running: 0, queued: 0, red: 1, recent_red: 3 } }));
  assert.doesNotMatch(runs.innerHTML, /Run times/);
  assert.equal(run("failed24h()"), ', <a href="#infra/runs?bs=red" title="the red runs, newest first">failed 24h 3</a>');
  Object.assign(run("bld").data, { counts: { total: 2, running: 0, queued: 0, red: 0, recent_red: 0 } });
  assert.equal(run("failed24h()"), "", "none failed draws nothing");
});

test("the runs carry no Quarantine fold: the quarantine is Tests' table", () => {
  showBuilds(bdata({ quarantine: [{ repo: "o/play", level: "bad", says: "play: 5 quarantined", rows: [] }] }));
  assert.doesNotMatch(runs.innerHTML, /bld-quar|Quarantine/);
});

test("the runs table sorts and filters under its own view keys", () => {
  showBuilds();
  const patch = run("tblPatch")({ type: "input", target: { dataset: { tsearch: "" }, value: "repo:binks" } });
  assert.deepEqual({ ...patch }, { q: "repo:binks" });
  run("st.views.infra = 'bq=repo%3Abinks&bsort=took'");
  assert.equal(run("tblParams(st.views.infra, RUNS_PRE).toString()"), "bq=repo%3Abinks&bsort=took");
  run("st.views.infra = ''");
});

test("a builds event re-reads the runs, the pipelines and the tests, and only while Infra is open", async () => {
  builds = bdata();
  run("st.tab = 'infra'");
  asked.length = 0;
  run("TABS.infra").onEvent({ kind: "builds" });
  await settled();
  assert.deepEqual(asked, ["/api/builds", "/api/pipelines", "/api/tests"]);
  // A state.json write re-reads the pipelines alone: a night's schedule changed, no run did.
  asked.length = 0;
  run("TABS.infra").onEvent({ kind: "pipelines" });
  await settled();
  assert.deepEqual(asked, ["/api/pipelines"]);
  run("st.tab = 'home'");
  asked.length = 0;
  run("TABS.infra").onEvent({ kind: "builds" });
  await settled();
  assert.equal(asked.length, 0);
});

test("Infra shown before its reads answer says reading in Runs, Pipelines and Tests, never a blank tab", async () => {
  run("bld.data = null; bld.err = null; pip.data = null; pip.err = null; tst.data = null; tst.err = null; st.tab = 'infra'");
  for (const b of [runs, pipes_, tests_]) b.innerHTML = "";
  run("TABS.infra.show()");
  // Before any read settles: each section already holds its heading and the word.
  for (const [name, b] of [["Runs", runs], ["Pipelines", pipes_], ["Tests", tests_]]) assert.match(b.innerHTML, new RegExp(`${name} <span class="muted">reading\\.\\.\\.`), name);
  await settled();
  run("st.tab = 'home'");
});

const tcol = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const suite = (o) => ({ tier: "unit", suite: "a.bats", tests: 4, passed: 2, failed: 1, quarantined: 0, skipped: 1, time: 1.25, state: "failed", level: "bad", ...o });
const pickRun = (id, o = {}) => ({ repo: "o/binks", id, attempt: 1, branch: "main", sha: "abc1234", title: "t", state: "red", level: "bad", started: NOW() - 600, prs: [], url: `https://github.com/o/binks/actions/runs/${id}`, ...o });
const tdata = (o = {}) => ({
  at: NOW() - 60, stale_after: 1800, runs: [pickRun(9), pickRun(8, { state: "green", branch: "feat/x" })], run: pickRun(9),
  summary: "main abc1234: 5 tests in 2 suites: 1 failed, 1 skipped, 3 passed", totals: { suites: 2, tests: 5, passed: 3, failed: 1, skipped: 1, failed_suites: 1, time: 2 },
  rows: [suite(), suite({ tier: "ui", suite: "c.bats", tests: 1, passed: 1, failed: 0, skipped: 0, state: "passed", level: "ok", time: 70 })], more: 0, fold: null, note: null, errors: [],
  table: { q: "", state: "", sort: "", dir: "", total: 2, shown: 2, states: [{ name: "all", n: 2 }, { name: "failed", n: 1 }, { name: "quarantined", n: 0 }, { name: "skipped", n: 0 }, { name: "passed", n: 1 }], columns: ["state", "tier", "suite", "tests", "failed", "quarantined", "skipped", "time"].map(tcol), facets: [] },
  ...o,
});
const held = (o) => ({ test: "P.Yard.Each(\"a\")", repo: "unity-core-playground", row: "db-265", owner: "db-265 fix(yard): x", ends: "2026-11-20", days_left: 8, left: "8d", level: "ok", nightly: "failing", ...o });
const qdata = (o = {}) => ({
  lanes: [{ repo: "unity-core-playground", says: "unity-core-playground: 2 quarantined over 2 owner rows, 1 ended; nightly 11-12: 8 known red, 1 now pass", level: "bad", url: "https://github.com/o/play/actions/runs/43215863750" }],
  rows: [held({ test: "P.Gone", row: "ucp-1", ends: "2026-11-10", days_left: -2, left: "ended", level: "bad" }), held({ nightly: "now passing" })], more: 0, error: null,
  table: { q: "", state: "", sort: "", dir: "", total: 2, shown: 2, states: [{ name: "all", n: 2 }, { name: "ended", n: 1 }, { name: "ending", n: 0 }, { name: "held", n: 1 }], columns: ["test", "repo", "row", "ends", "left", "nightly"].map(tcol), facets: [],
    links: [{ repo: "#projects?q=unity-core-playground", row: "#board?q=id:=ucp-1" }, { repo: "#projects?q=unity-core-playground", row: "#board?q=id:=db-265" }] },
  ...o,
});
const showTests = (d = tdata()) => { run("st.tab = 'infra'; st.arg = 'tests'"); Object.assign(run("tst"), { data: d, err: null, sel: null, cases: null, res: "" }); run("tst.render()"); };
const srow = (key) => ({ dataset: { skey: key }, closest: (sel) => (sel === "tr.sr" ? { dataset: { skey: key } } : null) });

test("the Tests section draws the run's totals, its picker and each suite", () => {
  showTests();
  const b = tests_.innerHTML;
  assert.match(b, /<div data-tbl="t"><div id="tst-head"><h2 class="sec" id="sec-tests">Tests <span class="muted">main abc1234: 5 tests in 2 suites: 1 failed/);
  assert.match(b, /<select data-twin="run" aria-label="CI run"><option value="9" selected>main abc1234 red, [^<]* ago<\/option><option value="8">feat\/x abc1234 green/);
  assert.match(b, /<td class="bad">failed<\/td><td>unit<\/td><td class="wrap">a\.<wbr>bats<\/td><td class="n">4<\/td><td class="n bad">1<\/td><td class="n muted">0<\/td><td class="n muted">1<\/td><td class="n">1.25s<\/td>/);
  assert.match(b, /<td class="n muted">0<\/td><td class="n">1m<\/td>/);
});

test("a suite whose failures are all quarantined is amber, and its tests say quarantined", async () => {
  showTests(tdata({ rows: [suite({ failed: 0, quarantined: 1, state: "quarantined", level: "warn" })] }));
  assert.match(tests_.innerHTML, /<td class="warn">quarantined<\/td><td>unit<\/td><td class="wrap">a\.<wbr>bats<\/td><td class="n">4<\/td><td class="n muted">0<\/td><td class="n warn">1<\/td>/);
  cases = { more: 0, cases: [{ name: "held one", fullname: "A.held", result: "quarantined", time: 0.2, message: "Expected 1" }] };
  fire(tests_, "click", { type: "click", target: srow("unit|a.bats") });
  await settled();
  assert.match(tests_.innerHTML, /<span class="warn">quarantined<\/span> held one/);
  assert.match(tests_.innerHTML, /data-cres="quarantined">quarantined <span class="n">1<\/span>/);
  assert.match(tests_.innerHTML, /<td colspan="8">/, "the detail spans every column");
});

test("the Quarantine table lists each held test under each lane's line with its nightly link", () => {
  showTests(tdata({ quarantine: qdata() }));
  const b = tests_.innerHTML;
  assert.ok(b.indexOf('data-tbl="t"') < b.indexOf('id="sec-quarantine"'), "below the suites");
  assert.match(b, /<div class="cline bad">unity-core-playground: 2 quarantined[^<]*<a href="https:\/\/github.com\/o\/play\/actions\/runs\/43215863750"[^>]*>nightly<\/a>/);
  assert.match(b, /<div data-tbl="q">.*id="qtn-q"/s);
  assert.match(b, /<td class="wrap">P\.<wbr>Gone<\/td><td><a [^>]*href="#projects\?q=unity-core-playground"[^>]*>unity-core-playground<\/a><\/td><td><a [^>]*href="#board\?q=id:=ucp-1"[^>]*>ucp-1<\/a><\/td><td>2026-11-10<\/td><td class="n bad">ended<\/td><td class="muted">failing<\/td>/);
  assert.match(b, /<td class="n ">8d<\/td><td class="">now passing<\/td>/);
  assert.match(b, /data-ts="ended"/);
  // no run picked still lists the quarantine
  showTests(tdata({ run: null, runs: [], rows: [], quarantine: qdata() }));
  assert.match(tests_.innerHTML, /id="sec-quarantine"/);
  // a bad file is the table's red line; no repo with a quarantine draws nothing
  showTests(tdata({ quarantine: qdata({ lanes: [], rows: [], error: "quarantine.json: EOF", table: { ...qdata().table, total: 0, links: [] } }) }));
  assert.match(tests_.innerHTML, /<div class="panel down">quarantine.json: EOF<\/div>/);
  showTests(tdata({ quarantine: qdata({ lanes: [], rows: [], table: { ...qdata().table, total: 0, links: [] } }) }));
  assert.doesNotMatch(tests_.innerHTML, /sec-quarantine/);
});

test("a Quarantine chip re-reads the tests under the q keys, and the suites' keys ride along", async () => {
  showTests(tdata({ quarantine: qdata() }));
  run("st.views.infra = 'tq=tier%3Aui&trun=8'");
  tests = tdata({ quarantine: qdata() });
  asked.length = 0;
  const chip = { dataset: {}, closest: (sel) => (sel === "[data-tbl]" ? { dataset: { tbl: "q" } } : sel === "[data-ts]" ? { dataset: { ts: "ended" } } : null) };
  fire(tests_, "click", { type: "click", target: chip });
  await settled();
  assert.deepEqual(asked, ["/api/tests?tq=tier%3Aui&trun=8&qs=ended"]);
  assert.equal(run("tblParams(st.views.infra, QTN_PRE).toString()"), "qs=ended");
  run("st.views.infra = ''");
  tests = {};
});

test("the repo picker sits before the run picker, and a new repo drops the picked run", () => {
  showTests(tdata({ repos: ["o/play", "o/binks"], repo: "o/binks" }));
  assert.match(tests_.innerHTML, /<select data-twin="repo" data-tclear="run" aria-label="repo"><option value="o\/play">o\/play<\/option><option value="o\/binks" selected>o\/binks<\/option><\/select> <select data-twin="run"/);
  assert.match(tests_.innerHTML, /<option value="9" selected>main abc1234 red/, "a run is named by branch, commit and result, its repo is the picker's");
  const pick = run("tblPatch")({ type: "change", target: { dataset: { twin: "repo", tclear: "run" }, value: "o/play" } });
  assert.deepEqual({ ...pick }, { repo: "o/play", run: "" });
  assert.equal(run("tblSet('trun=8', { repo: 'o/play', run: '' }, 't')"), "trepo=o%2Fplay");
});

test("a green run is one line that lists its suites through the passed chip", () => {
  showTests(tdata({ rows: [], fold: "All green: 5 tests in 2 suites: 0 failed, 1 skipped, 4 passed" }));
  assert.match(tests_.innerHTML, /<button class="btn sm" data-ts="passed"[^>]*>All green: 5 tests in 2 suites/);
  assert.doesNotMatch(tests_.innerHTML, /<tr class="sr/);
});

test("a run with no artifacts says why, and no run at all names the declared workflows", () => {
  showTests(tdata({ rows: [], note: "this run uploaded no junit-* artifact", summary: "main abc1234: no results", table: { ...tdata().table, total: 0, shown: 0 } }));
  assert.match(tests_.innerHTML, /<div class="panel muted">this run uploaded no junit-\* artifact/);
  showTests(tdata({ run: null, runs: [], rows: [], summary: "no finished run of a declared test workflow in the ledger" }));
  assert.match(tests_.innerHTML, /No finished run of a declared test workflow in the ledger \(testWorkflows in the project map\)\./);
  assert.doesNotMatch(tests_.innerHTML, /<select data-twin="run"/);
});

test("opening a suite reads its tests then, failed first with a result filter, and again closes it", async () => {
  showTests();
  cases = { more: 0, cases: [{ name: "fails here", result: "failed", time: 0.2, message: "line 2: [ 1 -gt 2 ] failed" }, { name: "skipped one", result: "skipped", time: 0, message: "not on CI" }, { name: "passes", result: "passed", time: 0.1, message: "" }] };
  asked.length = 0;
  fire(tests_, "click", { type: "click", target: srow("unit|a.bats") });
  await settled();
  assert.deepEqual(asked, ["/api/tests/cases?run=9&tier=unit&suite=a.bats"]);
  let b = tests_.innerHTML;
  assert.match(b, /<span class="bad">failed<\/span> fails here <span class="muted">0.20s<\/span><pre class="joblog">line 2: \[ 1 -gt 2 \] failed<\/pre>/);
  assert.match(b, /data-cres="failed">failed <span class="n">1<\/span>/);
  fire(tests_, "click", { type: "click", target: { closest: (sel) => (sel === "[data-cres]" ? { dataset: { cres: "skipped" } } : null) } });
  b = tests_.innerHTML;
  assert.match(b, /skipped one/);
  assert.doesNotMatch(b, /fails here|passes/);
  fire(tests_, "click", { type: "click", target: srow("unit|a.bats") });
  assert.doesNotMatch(tests_.innerHTML, /skipped one/);
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
  run("st.views.infra = 'bq=x&tq=tier%3Aui&tsort=time&trun=8'");
  assert.equal(run("tblParams(st.views.infra, TESTS_PRE).toString()"), "tq=tier%3Aui&tsort=time");
  const pick = run("tblPatch")({ type: "change", target: { dataset: { twin: "run" }, value: "8" } });
  assert.deepEqual({ ...pick }, { run: "8" });
  assert.equal(run("tblSet('q=1', { run: '8' }, 't')"), "q=1&trun=8");
  asked.length = 0;
  await run("tst.refresh()");
  assert.deepEqual(asked, ["/api/tests?tq=tier%3Aui&tsort=time&trun=8"]);
  run("st.views.infra = ''");
});

test("the Pipelines table states each pipeline with its why, its night's schedule link and its times", () => {
  showPipes();
  const b = pipes_.innerHTML;
  assert.match(b, /<div id="pip-head"><h2 class="sec" id="sec-pipelines">Pipelines <span class="muted">2 pipelines in 1 repo: 1 red<\/span><\/h2><\/div><div data-tbl="l">/, "the bar and rows sit in the l table");
  assert.match(b, /<td class="bad" title="the last 2 runs failed">red<\/td><td><a class="tl" href="#projects\/unity-core-playground">unity-core-playground<\/a><\/td><td class="wrap" title=".github\/workflows\/test.yml">Tests \(all\)<\/td>/);
  assert.match(b, /<td class="wrap muted"><a class="tl" href="#schedules\/playground-night">nightly 02:00 on playground-night<\/a><\/td><td class="n" title="[^"]+"><a class="tl" href="#schedules\/playground-night">/, "a night member's schedule and next start open its runner's row");
  assert.match(b, /<td class="bad" title="[^"]+"><a class="tl" href="#infra\/runs\/o%2Fplay%2F41">failure \d+[mhd]<\/a>/, "the last run is its result and age, the stamp its tooltip");
  assert.match(b, /<td class="n bad">60%<\/td><td class="n">5<\/td><td class="n muted">25m<\/td><td class="n muted">40m<\/td>/);
  assert.match(b, /<td class="" title="passing">green <span class="muted">1 running<\/span><\/td>/);
  assert.match(b, /<td class="wrap muted">-<\/td><td class="n">-<\/td>/, "no schedule and no next start draw a dash");
});

test("opening a pipeline reads its detail then, and only then, and shows why, purpose, crons, jobs and its last runs", async () => {
  showPipes();
  pdetail = { row: prow(), purpose: "Every test, nightly", crons: ["0 2 * * *"], jobs: "EditMode, PlayMode", night_title: "Tests (all) night",
    runs: [{ id: 41, attempt: 1, started: NOW() - 7200, branch: "main", event: "schedule", title: "nightly", state: "red", conclusion: "failure", took: 1500, link: "#infra/runs/o%2Fplay%2F41" }] };
  const KEY = "o/play|.github/workflows/test.yml";
  asked.length = 0;
  fire(pipes_, "click", { type: "click", target: prowEl(KEY) });
  assert.match(pipes_.innerHTML, /<tr class="wdet"><td colspan="12"><div class="sdet"><div class="cline bad">the last 2 runs failed<\/div><div class="cline"><b>File<\/b> .github\/workflows\/test.yml<\/div><div class="cline muted">reading/);
  await settled();
  assert.deepEqual(asked, ["/api/pipelines/detail?repo=o%2Fplay&file=.github%2Fworkflows%2Ftest.yml"]);
  const b = pipes_.innerHTML;
  assert.match(b, /<b>Purpose<\/b> Every test, nightly/);
  assert.match(b, /<b>Crons<\/b> 0 2 \* \* \*/);
  assert.match(b, /<b>Jobs<\/b> EditMode, PlayMode/);
  assert.match(b, /<b>Night title<\/b> Tests \(all\) night/);
  assert.match(b, /<td data-label="started" class="n"><a class="tl" href="#infra\/runs\/o%2Fplay%2F41">[^<]+<\/a><\/td><td data-label="result" class="bad">failure<\/td><td data-label="branch" class="wrap muted">main<\/td>/);
  // A click on the open row closes it.
  fire(pipes_, "click", { type: "click", target: prowEl(KEY) });
  assert.doesNotMatch(pipes_.innerHTML, /wdet/);
  pdetail = {};
});

test("the Pipelines table filters under its own l keys, apart from the Pools table's p", () => {
  showPipes();
  run("st.views.infra = 'pq=pool&lq=repo%3Aplay&ls=red'");
  assert.equal(run("tblParams(st.views.infra, PIP_PRE).toString()"), "lq=repo%3Aplay&ls=red");
  const pre = Object.values(run("INFRA_TABLES")).concat([run("RUNS_PRE"), run("PIP_PRE"), run("TESTS_PRE"), run("QTN_PRE")]);
  assert.equal(new Set(pre).size, pre.length, `every Infra table has its own view-key prefix: ${pre}`);
  run("st.views.infra = ''");
});

// Runs, Pipelines and Tests are inner tabs of their own; the old Releases URLs open them.
test("the old Releases Builds and Tests URLs open Infra's Runs and Tests", () => {
  for (const [hash, inner, section] of [["#releases/builds", "runs", "runs"], ["#releases/tests", "tests", "tests"], ["#infra/runs", "runs", undefined], ["#infra/tests", "tests", undefined], ["#infra/quarantine", "tests", "quarantine"]]) {
    const r = ctx.route(hash);
    assert.deepEqual([r.tab, r.arg, r.section], ["infra", inner, section], hash);
  }
  assert.equal(run("innerOf('infra', 'runs')")[0], "runs");
  assert.equal(run("innerOf('infra', 'pipelines')")[0], "pipelines");
  assert.equal(run("innerOf('infra', 'quarantine')")[0], "tests");
  assert.equal(run("innerOf('infra', 'ci')")[0], "runners", "the retired CI tab is Runners");
});

test("Infra's strip counts runs needing a look on Runs, a red pipeline on Pipelines and a failed suite on Tests", () => {
  showBuilds(bdata({ look: true }));
  showTests();
  Object.assign(run("pip"), { data: pdata(), err: null });
  run("ist.data = null; st.arg = 'machines'; renderInfra()");
  const strip = () => parts["infra-main"].innerHTML;
  assert.match(strip(), /data-itab="runs" [^>]*>Runs <span class="pill warn">1<\/span>/);
  assert.match(strip(), /data-itab="pipelines" [^>]*>Pipelines <span class="pill warn">1<\/span>/);
  assert.match(strip(), /data-itab="tests" [^>]*>Tests <span class="pill warn">1<\/span>/);
  // Each element joins its own inner tab, hidden on another.
  assert.equal(runs.dataset.in, "runs");
  assert.equal(pipes_.dataset.in, "pipelines");
  assert.equal(tests_.hidden, true);
  run("st.arg = 'runs'; renderInfra()");
  assert.equal(runs.hidden, false);
  assert.equal(tests_.hidden, true);
  Object.assign(run("bld").data, { look: false });
  Object.assign(run("tst").data.totals, { failed_suites: 0 });
  Object.assign(run("pip").data, { red: 0 });
  run("renderInfra()");
  assert.match(strip(), /data-itab="runs" [^>]*>Runs<\/button>/);
  assert.match(strip(), /data-itab="pipelines" [^>]*>Pipelines<\/button>/);
  assert.match(strip(), /data-itab="tests" [^>]*>Tests<\/button>/);
  run("st.arg = ''");
});

test("a run's workflow cell opens its record and its repo cell its project", () => {
  showBuilds(bdata({ table: { ...bdata().table, links: [{ workflow: "#infra/runs/binks%2F77", repo: "#projects/binks" }] } }));
  assert.match(runs.innerHTML, /<td><a class="tl" href="#projects\/binks">binks<\/a><\/td><td class="wrap"><a class="tl" href="#infra\/runs\/binks%2F77">Tests<\/a><\/td>/);
});

test("a run's page reads the run by its repo and id, shows its newest attempt with its jobs and log, and says so when the ledger has none", async () => {
  builds = bdata({ rows: [red, { ...red, attempt: 1, started: red.started - 600 }] }); // the ledger order: newest attempt first
  detail = rdetail();
  asked.length = 0;
  run('st.tab = "infra"; st.page = "runs/binks/77"; showRunPage()');
  for (let i = 0; i < 4; i++) await settled();
  assert.equal(asked[0], "/api/builds?bq=repo%3A%3Dbinks+id%3A%3D77", "a Forgejo run id is an index within its repo");
  assert.ok(asked.includes("/api/builds/log?forge=github.com&repo=binks&run_id=77&attempt=2"), "the newest attempt's log");
  let h = run("runPage()");
  assert.match(h, /CI run <span class="muted">binks\/77<\/span> <a href="#infra\/runs">all runs<\/a>/);
  assert.match(h, /<b>Run<\/b> github.com binks #77 attempt 2/);
  assert.match(h, /<pre class="joblog">FAIL: step 3 exited 1<\/pre>/);
  builds = bdata({ rows: [] });
  // The retired #infra/ci/<id> still opens the run.
  run('st.page = "ci/99"; showRunPage()');
  for (let i = 0; i < 4; i++) await settled();
  assert.equal(asked.at(-1), "/api/builds?bq=id%3A%3D99", "a bare id is that id in any repo");
  h = run("runPage()");
  assert.match(h, /No CI run 99 in the ledger's 30 days\./);
  run('st.page = ""; showRunPage()');
  builds = {};
});

test("a run read still in flight when its page resets fills its own objects, not the reset ones", async () => {
  detail = rdetail();
  const o = { log: null, detail: null };
  const read = run("readRun")(o, red);
  Object.assign(o, { log: null, detail: null }); // runFresh on a page change
  await read;
  assert.deepEqual([o.log, o.detail], [null, null]);
});
