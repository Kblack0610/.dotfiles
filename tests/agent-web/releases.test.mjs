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
const parts = { "rel-head": part(), "rel-facets": part(), "rel-chips": part(), "rel-body": part(), "rel-tail": part() };
const doc = { body: el(), getElementById: (id) => (id === "releases" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, activeElement: null, hidden: false };
const asked = [];
let body = {};
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
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body, text: async () => "" }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "table.js", "actions.js", "jobs.js", "schedules.js", "releases.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx);
const run = (src) => vm.runInContext(src, ctx);
const relst = run("relst");
const settled = () => new Promise((r) => setImmediate(r));

const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = {
  q: "", state: "", sort: "", dir: "", total: 3, shown: 2,
  states: [{ name: "all", n: 3 }, { name: "attention", n: 1 }, { name: "green", n: 2 }],
  columns: ["project", "channel", "pinned", "live", "status", "telemetry", "deps", "id", "where"].map(col),
  facets: [],
};
const NOW = () => Math.round(Date.now() / 1e3);
const drift = {
  project: "binks", id: "binks-prod", label: "prod binks-prod", where: "home-k3s", tag: "v2", status: "drift", status_level: "bad", watch_level: "bad", level: "bad",
  pinned: { value: "v2", source: "manifest" }, live: { value: "v1", source: "k8s", image: "reg/binks:v1", error: null },
  pinned_text: "v2", live_text: "v1", telemetry_text: "0/1", deps_text: "unity-core v0.5.0", deps: ["unity-core"],
  telemetry: [{ watch: "binks-probe", state: "TRIP", level: "bad", since: 1793942659 }], drift_since: 1793942659, probed_at: 1793942700,
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
  assert.doesNotMatch(h, /class="warn"/);
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
  assert.match(b, /<td class="opt bad">0\/1<\/td>/);
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

test("the Builds slot sits under the channels and draws nothing yet", () => {
  show();
  assert.match(box.innerHTML, /<div id="rel-tail"><\/div>$/);
  assert.equal(run("releaseBuilds()"), "");
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
