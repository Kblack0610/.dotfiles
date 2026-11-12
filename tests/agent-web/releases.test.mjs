// Unit tests for the Releases tab (.local/src/agent-web/static/releases.js), run by `node --test`
// from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. What an app row says is hub_core::releases,
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
let detail = {};
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
    const json = url.startsWith("/api/tests/cases") ? cases : url.startsWith("/api/tests") ? tests : url.startsWith("/api/builds/detail") ? detail : url.startsWith("/api/builds") ? builds : body;
    return { ok: true, status: 200, headers: { get: () => (text ? "text/plain" : "application/json") }, json: async () => json, text: async () => "FAIL: step 3 exited 1" };
  },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "table.js", "actions.js", "jobs.js", "schedules.js", "releases.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx);
const run = (src) => vm.runInContext(src, ctx);
const relst = run("relst");
const settled = () => new Promise((r) => setImmediate(r));

const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = {
  q: "", state: "", sort: "", dir: "", total: 2, shown: 2,
  states: [{ name: "all", n: 2 }, { name: "attention", n: 1 }, { name: "ok", n: 1 }],
  columns: ["project", "live", "status", "channels", "last_deploy"].map(col),
  facets: [],
};
const NOW = () => Math.round(Date.now() / 1e3);
const drift = {
  project: "binks", channel: "prod", id: "binks-prod", label: "prod binks-prod", where: "home-k3s", tag: "v2", status: "drift", status_text: "drift", status_level: "bad", watch_level: "bad", level: "bad",
  pinned: { value: "v2", source: "manifest" }, live: { value: "v1", source: "k8s", image: "reg/binks:v1", error: null },
  pinned_text: "v2", live_text: "v1", telemetry_text: "0/1", deps_text: "unity-core v0.5.0", deps: ["unity-core"],
  telemetry: [{ watch: "binks-probe", state: "TRIP", level: "bad", since: 1793942659 }], drift_since: 1793942659, probed_at: 1793942700,
  prev_text: "v0", last_deploy_text: "11-06 15:00 fail", deploy_level: "warn",
  deploys: { source: "o/r", error: null, prev: "v0", last: { version: "v2", state: "fail", at: 1793942659 }, history: [
    { version: "v2", state: "fail", at: 1793942659, url: "https://github.test/run/9" },
    { version: "v1", state: "ok", at: 1793942000, url: "javascript:alert(1)" },
  ] },
};
const unread = {
  ...drift, channel: "beta", id: "binks-steam-beta", label: "beta binks-steam-beta", where: "steam", status: "unknown", status_text: "not read", status_level: "warn", level: "warn",
  pinned: { value: null, source: "tag" }, live: { value: null, source: "steam", image: null, error: "steam GetAppBetas failed" },
  pinned_text: "-", live_text: "?", telemetry: [], drift_since: null, deploys: { source: "o/r", error: null, prev: null, last: null, history: [] },
};
const binks = {
  project: "binks", live_text: "v1 prod", status: "drift", status_text: "drift", level: "bad", channels_text: "2: 1 drift, 1 not read", unread: 1,
  last_deploy_text: "11-06 15:00 fail", deploy_level: "warn", channels: [drift, unread], lead: 1, others_text: "beta 1 not read",
  stage: "draft", stage_text: "draft: live above it: binks-prod", stage_level: "warn",
  line: "release", released_text: "v2 11-05", history: [
    { tag: "binks-v2", version: "2", at: 1793900000, at_text: "11-05", prev: "binks-v1", reached: [{ id: "binks-prod", channel: "prod", at: 1793942000, how: "deploy" }], reached_text: "binks-prod 11-06", prs: [12, 14], prs_text: "#12, #14", rows: ["agent-runtime:ar-7"], rows_text: "ar-7" },
    { tag: "binks-v1", version: "1", at: 1793000000, at_text: "10-26", prev: null, reached: [], reached_text: "not recorded", prs: [], prs_text: "-", rows: [], rows_text: "-" },
  ],
};
const data = (o = {}) => ({
  at: NOW() - 120, question: "What is building, and what is live where?", summary: "2 apps: 1 drift, 1 ok", stale_after: 3600, errors: [], table,
  gaps: "1 channel not read: steam GetAppBetas failed (1)", rows: [binks], ...o,
});

const target = (attrs, tr = null, ch = null) => ({
  dataset: attrs,
  closest: (sel) => (sel === "tr.jr" ? tr : sel === "tr.rc" ? ch : sel === "[data-ts]" && "ts" in attrs ? { dataset: attrs } : null),
});
const show = (d = data()) => {
  run("st.tab = 'releases'; relCh = null");
  Object.assign(relst, { data: d, err: null, sel: null });
  Object.assign(run("relcl"), { project: null, data: null, err: null });
  run("relst.render()");
};
const APP = { dataset: { key: "binks" } };
const clickApp = () => fire("click", { type: "click", target: target({}, APP) });
const clickChannel = (id) => fire("click", { type: "click", target: target({}, null, { dataset: { ch: `binks|${id}` } }) });

test("the head asks the tab's question, counts the apps, names what it could not read and says the snapshot's age", () => {
  show();
  const h = box.innerHTML;
  assert.match(h, /What is building, and what is live where\?/);
  assert.match(h, /2 apps: 1 drift, 1 ok/);
  assert.match(h, /<div class="cline warn">1 channel not read: steam GetAppBetas failed \(1\)<\/div>/);
  assert.match(h, /refreshed .* \(2m ago\)/);
  assert.doesNotMatch(h, /class="warn">refreshed/);
});

test("a snapshot older than the collector's cadence is amber, and a full read draws no gap line", () => {
  show(data({ at: NOW() - 7200, gaps: "" }));
  assert.match(box.innerHTML, /class="warn">refreshed/);
  assert.doesNotMatch(box.innerHTML, /not read:/);
});

test("no snapshot names the error instead of drawing a stale table", () => {
  show(data({ at: 0, rows: [], gaps: "", summary: "not read", errors: ["release-state show: no snapshot yet"], table: { ...table, total: 0 } }));
  assert.match(box.innerHTML, /release-state show: no snapshot yet/);
  assert.match(box.innerHTML, /No apps\./);
});

test("an app is one row: what is live, its word, its channels amber when one was not read, its last deploy", () => {
  show();
  const b = box.innerHTML;
  assert.match(b, /<tr class="jr" data-key="binks"><td>binks <span class="warn">draft<\/span><\/td><td class="wrap">v1 prod<\/td><td class="bad">drift<\/td><td class="wrap warn">2: 1 drift, 1 not read<\/td><td class="muted">v2 11-05<\/td><td class="warn">11-06 15:00 fail<\/td><\/tr>/);
  assert.equal(b.match(/<tr class="jr"/g).length, 1, "one row per app, not one per channel");
  assert.doesNotMatch(b, /binks-prod/, "channels wait for the app to open");
});

test("an app names its stage, amber when its deploys do not match it, and the open app says what the stage asks", () => {
  show();
  clickApp();
  assert.match(box.innerHTML, /<div class="cline"><b>Stage<\/b> <span class="warn">draft: live above it: binks-prod<\/span><\/div>/);
  clickApp();
  show(data({ rows: [{ ...binks, stage: "", stage_text: "none on the lab sheet", stage_level: "ok" }] }));
  assert.match(box.innerHTML, /<td>binks<\/td>/, "no stage, no word");
  clickApp();
  assert.match(box.innerHTML, /<b>Stage<\/b> <span class="muted">none on the lab sheet<\/span>/);
  clickApp();
});

test("opening an app lists its headline env's channels, the other envs in a fold that starts open, and clicking again closes it", () => {
  show();
  body = changelog();
  clickApp();
  const b = box.innerHTML;
  assert.match(b, /<tr class="rc" data-ch="binks\|binks-prod"><td>prod<\/td><td class="wrap">binks-prod<\/td><td class="bad">v1<\/td><td>v2<\/td><td class="bad">drift<\/td><td class="wrap muted">home-k3s<\/td><\/tr>/);
  assert.match(b, /<details class="cfold" data-k="rel-env:binks" open><summary><b>1 other channel<\/b> <span class="muted">beta 1 not read<\/span><\/summary>/);
  assert.match(b, /<td class="warn">not read<\/td><td class="wrap muted"><span class="warn">steam GetAppBetas failed<\/span>/);
  assert.ok(b.indexOf("binks-prod") < b.indexOf("rel-env:binks"), "the headline env is above the fold");
  clickApp();
  assert.doesNotMatch(box.innerHTML, /binks-prod/);
});

test("a fold of other envs the reader closed stays closed across a repaint", () => {
  show();
  run("REL_OPEN['rel-env:binks'] = false; relst.sel = 'binks'; relst.render()");
  assert.match(box.innerHTML, /data-k="rel-env:binks"><summary>/);
  run("delete REL_OPEN['rel-env:binks']; relst.render()");
  assert.match(box.innerHTML, /data-k="rel-env:binks" open>/, "with no remembered state it is open");
  run("relst.sel = null");
});

test("the strip is the first element of the page, before the first read and after it", () => {
  Object.assign(relst, { data: null, err: null, sel: null });
  run("st.tab = 'releases'; st.arg = ''; relst.render()");
  assert.match(box.innerHTML, /^<div class="seg fseg istrip" role="tablist">.*Loading/, "loading");
  Object.assign(relst, { err: "fetch failed" });
  run("relst.render()");
  assert.match(box.innerHTML, /^<div class="seg fseg istrip" role="tablist">.*fetch failed/, "a failed read");
  relst.err = null;
  show();
  assert.match(box.innerHTML, /^<div id="rel-head"><div class="seg fseg istrip" role="tablist">/, "read");
});

test("clicking a channel opens its versions, every watch and its deps, and clicking again closes it", () => {
  show();
  body = changelog();
  clickApp();
  clickChannel("binks-prod");
  const b = box.innerHTML;
  assert.match(b, /<b>Pinned<\/b> v2 <span class="muted">from manifest/);
  assert.match(b, /image reg\/binks:v1/);
  assert.match(b, /binks-probe <span class="bad">TRIP/);
  assert.match(b, /<b>Deps<\/b> unity-core v0.5.0/);
  assert.match(b, /<a href="https:\/\/github\.test\/run\/9"[^>]*>run<\/a>/);
  assert.doesNotMatch(b, /javascript:/, "only an https run is a link");
  assert.match(b, /<tr class="rcd"><td colspan="6">/);
  clickChannel("binks-prod");
  assert.doesNotMatch(box.innerHTML, /<b>Pinned/);
  assert.match(box.innerHTML, /binks-prod/, "the app stays open");
});

const changelog = (o = {}) => ({
  project: "binks", tag: "binks-v2", prev: "binks-v1", source: "merged PRs", range: "binks-v1..binks-v2",
  text: "- fix the **probe** (#7)", tags: ["binks-v3", "binks-v2", "binks-v1"], ...o,
});
const open = async (d = changelog()) => {
  show();
  body = d;
  asked.length = 0;
  clickApp();
  await settled();
};

test("opening an app reads its newest changelog and draws it under a tag picker", async () => {
  await open();
  assert.deepEqual(asked, ["/api/releases/changelog?project=binks"]);
  const b = box.innerHTML;
  assert.match(b, /<b>Changelog<\/b> <select class="rel-tag"[^>]*data-project="binks">/);
  assert.match(b, /<option>binks-v3<\/option><option selected>binks-v2<\/option><option>binks-v1<\/option>/);
  assert.match(b, /binks-v1\.\.binks-v2, from merged PRs/);
  assert.match(b, /fix the <strong>probe<\/strong> \(#7\)/);
});

test("an opened app lists its releases newest first with when, the one before and where each reached", async () => {
  await open();
  const b = box.innerHTML;
  assert.match(b, /<details class="cfold" data-k="rel-hist:binks" open><summary><b>Releases<\/b> <span class="muted">2 release tags<\/span><\/summary>/);
  assert.match(b, /<tr class="rh sel" data-project="binks" data-tag="binks-v2"><td>binks-v2<\/td><td class="n">11-05<\/td><td class="muted">binks-v1<\/td><td class="wrap">binks-prod 11-06<\/td><td class="wrap">#12, #14<\/td><td class="wrap">ar-7<\/td><\/tr>/, "a release lists its PRs and their board rows");
  assert.match(b, /<tr class="rh" data-project="binks" data-tag="binks-v1"><td>binks-v1<\/td><td class="n">10-26<\/td><td class="muted">-<\/td><td class="wrap muted">not recorded<\/td><td class="wrap muted">-<\/td><td class="wrap muted">-<\/td><\/tr>/);
  assert.ok(b.indexOf("rel-hist:binks") < b.indexOf("<b>Changelog</b>"), "the history sits above the changelog");
  // Clicking a release reads its changelog, and the app stays open.
  asked.length = 0;
  const rh = { dataset: { project: "binks", tag: "binks-v1" } };
  fire("click", { type: "click", target: { dataset: {}, closest: (sel) => (sel === "tr.rh" ? rh : null) } });
  await settled();
  assert.deepEqual(asked, ["/api/releases/changelog?project=binks&tag=binks-v1"]);
  assert.equal(relst.sel, "binks");
});

test("an app with no tags read says so where its history would be", async () => {
  show(data({ rows: [{ ...binks, history: [], line: "none" }] }));
  body = changelog();
  clickApp();
  await settled();
  assert.match(box.innerHTML, /<b>Releases<\/b> <span class="muted">no tags read<\/span>/);
});

test("opening a channel inside the app does not read the changelog again", async () => {
  await open();
  asked.length = 0;
  clickChannel("binks-prod");
  await settled();
  assert.equal(asked.length, 0);
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

test("a changelog the collector refused is said in the app, not left reading", async () => {
  show();
  const real = ctx.fetch;
  ctx.fetch = async () => ({ ok: false, status: 400, statusText: "Bad Request", text: async () => "release-state: binks has no release tags", headers: { get: () => "text/plain" } });
  clickApp();
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
const showBuilds = (d = bdata()) => { show(); Object.assign(run("bld"), { data: d, err: null, sel: null, log: null, detail: null }); run("relst.render()"); };
const brow = (key) => ({ dataset: { bkey: key }, closest: (sel) => (sel === "tr.br" ? { dataset: { bkey: key } } : null) });
const BKEY = "github.com|binks|77|2";

test("the Builds section sits under the apps with each run's owner and state", () => {
  showBuilds();
  const b = box.innerHTML;
  assert.match(b, /<div data-tbl="b"><div id="bld-head"><h2 class="sec" id="sec-builds">Builds <span class="muted">2 runs in 30 days: 0 running, 0 queued, 1 red/);
  assert.match(b, /<td class="bad">red<\/td><td>binks<\/td><td class="wrap">Tests<\/td>/);
  assert.match(b, /<td class="muted">agent-3<\/td>/);
  assert.ok(b.indexOf("sec-builds") > b.indexOf(`data-key="binks"`), "after the apps");
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
  const q = "forge=github.com&repo=binks&run_id=77&attempt=2";
  assert.deepEqual(asked, [`/api/builds/detail?${q}`, `/api/builds/log?${q}`]);
  const b = box.innerHTML;
  assert.match(b, /<pre class="joblog">FAIL: step 3 exited 1<\/pre>/);
  assert.match(b, /<b>Run<\/b> github.com binks #77 attempt 2/);
  assert.match(b, /<b>PRs<\/b> #12/);
  fire("click", { type: "click", target: brow(BKEY) });
  assert.doesNotMatch(box.innerHTML, /joblog/);
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
  fire("click", { type: "click", target: brow(BKEY) });
  await settled();
  const b = box.innerHTML;
  assert.match(b, /<b>#77 Tests red 46m \$0.20 \+ no rate<\/b>/);
  assert.match(b, /end to end 46m \| before first job 2m/);
  assert.equal((b.match(/<td data-label="job"/g) || []).length, 130, "every job, none capped");
  assert.match(b, /<td data-label="\$" class="n">\$0.20 \(1\/5 of \$1.855\/h\)<\/td>/);
  assert.match(b, /<b>Steps<\/b>/);
  assert.match(b, /<b>Coverage<\/b> <span class="muted">partial<\/span>/);
  assert.match(b, /<b>Attempts<\/b> 1, 2/);
  fire("click", { type: "click", target: brow(BKEY) });
  detail = rdetail();
  fire("click", { type: "click", target: brow(BKEY) });
  await settled();
  assert.match(box.innerHTML, /<td data-label="runner" class="wrap muted">github-hosted<\/td><td data-label="\$" class="n">no rate<\/td>/);
  fire("click", { type: "click", target: brow(BKEY) });
});

test("the Run times fold prices each workflow and flags a month off the AWS actual", () => {
  showBuilds(bdata({
    times: [{ repo: "o/binks", workflow: "Tests", runs: 3, pass: 66, longest: 600, usual: { median: 300, p90: 500 } }],
    costs: { times: ["$0.20 (3 priced)"], idle: ["aws-burst-1: powered 2.0h today $3.71, jobs $1.00, idle $2.71"], month: "month to date: jobs priced $4.00, AWS actual $10.00, off by 60%", month_off: true },
  }));
  const b = box.innerHTML;
  assert.match(b, /<th>\$ per run<\/th>/);
  assert.match(b, /<td class="n">\$0.20 \(3 priced\)<\/td>/);
  assert.match(b, /aws-burst-1: powered 2.0h today/);
  assert.match(b, /<div class="cline warn">month to date: jobs priced \$4.00/);
});

test("the Quarantine fold says each repo's line, links its nightly and colours each owner row by its end", () => {
  showBuilds(bdata({
    quarantine_level: "bad",
    quarantine: [{ repo: "o/play", level: "bad", entries: 5, url: "https://github.com/o/play/actions/runs/9",
      says: "play: 5 quarantined over 2 owner rows, 2 ended; nightly 11-11: 12 known red, 3 now pass",
      rows: [{ row: "ucp-1", entries: 2, ends: "2026-11-10", days_left: -1, level: "bad", left: "ended" }, { row: "ucp-2", entries: 3, ends: "2026-11-30", days_left: 19, level: "ok", left: "19d" }] }],
  }));
  const b = box.innerHTML;
  assert.match(b, /data-k="bld-quar"[^>]*><summary><b>Quarantine<\/b> <span class="bad">5 entries in 1 repo<\/span>/);
  assert.match(b, /<div class="cline bad">play: 5 quarantined over 2 owner rows, 2 ended; nightly 11-11: 12 known red, 3 now pass <a href="https:\/\/github.com\/o\/play\/actions\/runs\/9"/);
  assert.match(b, /<td>ucp-1<\/td><td class="n">2<\/td><td>2026-11-10<\/td><td class="n bad">ended<\/td>/);
  assert.match(b, /<td>ucp-2<\/td><td class="n">3<\/td><td>2026-11-30<\/td><td class="n ">19d<\/td>/);
  assert.ok(b.indexOf("bld-quar") < b.indexOf("bld-body"), "in the head, above the runs");
  showBuilds(bdata({ quarantine: [] }));
  assert.doesNotMatch(box.innerHTML, /bld-quar/, "no repo with a quarantine draws no fold");
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


// Inner tabs: Apps (the table and an opened app), Builds and Tests, over hub_core::layout's groups.
const shownIn = (h, id) => !new RegExp(`data-in="${id}" hidden`).test(h) && new RegExp(`data-in="${id}"`).test(h);
const relOn = (arg) => { run(`st.arg = ${JSON.stringify(arg)}; st.section = null`); showBuilds(); Object.assign(run("tst"), { data: tdata(), err: null }); run("relst.render()"); return box.innerHTML; };

test("Releases opens on Apps, and a URL naming Builds or Tests opens that one with the others hidden", () => {
  // An empty arg is the first inner tab (Apps); a section id is the inner tab holding it.
  for (const [hash, arg] of [["#releases", ""], ["#releases/builds", "builds"], ["#releases/tests", "tests"], ["#releases/detail", "apps"], ["#releases/table", "apps"], ["#releases?q=project:binks", ""]]) {
    assert.equal(ctx.route(hash).arg, arg, hash);
  }
  const apps = relOn("");
  assert.ok(shownIn(apps, "apps") && !shownIn(apps, "builds") && !shownIn(apps, "tests"));
  assert.match(apps, /data-itab="apps" class="on" aria-selected="true"/);
  const b = relOn("builds");
  assert.ok(shownIn(b, "builds") && !shownIn(b, "apps") && !shownIn(b, "tests"));
  const t = relOn("tests");
  assert.ok(shownIn(t, "tests") && !shownIn(t, "builds"));
  run("st.arg = ''");
});

test("a count shows beside an inner tab needing a look: a bad app, a recent red build, a failed suite", () => {
  const h = relOn("");
  assert.doesNotMatch(h, />Apps <span class="pill/);
  assert.match(h, />Tests <span class="pill warn">1<\/span>/);
  assert.doesNotMatch(h, />Builds <span class="pill/, "a build without look set counts nothing");
  Object.assign(relst.data, { look: true });
  Object.assign(run("bld").data, { look: true });
  run("relst.render()");
  assert.match(box.innerHTML, />Apps <span class="pill warn">1<\/span>/);
  assert.match(box.innerHTML, />Builds <span class="pill warn">1<\/span>/);
  run("st.arg = ''");
});
